import Foundation

/// Streaming HTTP for harness.js — mirrors HttpBridge.kt / http_bridge.cpp.
/// - {url, method, headers, body} → headers/chunk/done/fail events
/// - SSE-friendly chunked text via URLSession.AsyncBytes + UTF-8 boundary-safe decoding
/// - pending camera photos attach as image_url parts on /chat/completions (with
///   vision rerouting for open.bigmodel.cn coding endpoints)
final class HttpBridge {

    private let emit: (Int, String, String, String) -> Void
    private let session: URLSession
    private let lock = NSLock()
    private var active: [UUID: Task<Void, Never>] = [:]

    init(emit: @escaping (Int, String, String, String) -> Void) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 3600
        session = URLSession(configuration: cfg)
        self.emit = emit
    }

    func start(fetchId: Int, requestJson: String) {
        let uuid = UUID()
        let task = Task { [weak self] in
            await self?.run(uuid: uuid, fetchId: fetchId, requestJson: requestJson)
            _ = self?.lock.withLock { self?.active.removeValue(forKey: uuid) }
        }
        lock.lock()
        active[uuid] = task
        lock.unlock()
    }

    func abortAll() {
        lock.lock()
        let tasks = Array(active.values)
        active.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    private func run(uuid: UUID, fetchId: Int, requestJson: String) async {
        guard let req = (try? JSONSerialization.jsonObject(with: Data(requestJson.utf8))) as? [String: Any],
              let urlStr = req["url"] as? String,
              let base = URL(string: urlStr) else {
            emit(fetchId, "fail", "bad fetch request", "")
            return
        }
        let method = ((req["method"] as? String) ?? "GET").uppercased()
        let headers = (req["headers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        let body = req["body"] as? String

        let vision = Self.attachPendingImages(url: urlStr, body: body)
        let effectiveUrl = vision?.0 ?? urlStr
        let effectiveBody = vision?.1 ?? body
        let attachedImages = vision != nil

        let request = Self.buildRequest(
            urlStr: effectiveUrl, fallback: base, method: method,
            headers: headers, body: effectiveBody
        )

        do {
            var (bytes, response) = try await session.bytes(for: request)
            var status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // vision fallback: 4xx with attached images → retry original request
            if attachedImages && (400...499).contains(status) && body != nil {
                let retry = Self.buildRequest(
                    urlStr: urlStr, fallback: base, method: method,
                    headers: headers, body: body
                )
                let (b2, r2) = try await session.bytes(for: retry)
                bytes = b2
                response = r2
                status = (r2 as? HTTPURLResponse)?.statusCode ?? 0
            }

            if let http = response as? HTTPURLResponse {
                var h: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let ks = k as? String {
                        h[ks] = String(describing: v)
                    }
                }
                emit(fetchId, "headers", String(status), Self.encode(h))
            } else {
                emit(fetchId, "headers", "0", "{}")
            }

            var decoder = Utf8StreamDecoder()
            var iterator = bytes.makeAsyncIterator()
            var buf: [UInt8] = []
            buf.reserveCapacity(16 * 1024)
            while let byte = try await iterator.next() {
                buf.append(byte)
                if buf.count >= 16 * 1024 {
                    if let text = decoder.decode(Data(buf)) {
                        emit(fetchId, "chunk", text, "")
                    }
                    buf.removeAll(keepingCapacity: true)
                }
            }
            if !buf.isEmpty, let text = decoder.decode(Data(buf)) {
                emit(fetchId, "chunk", text, "")
            }
            if let tail = decoder.flush() {
                emit(fetchId, "chunk", tail, "")
            }
            emit(fetchId, "done", "", "")
        } catch {
            if Task.isCancelled { return }
            emit(fetchId, "fail", error.localizedDescription, "")
        }
    }

    private static func buildRequest(
        urlStr: String, fallback: URL, method: String,
        headers: [String: String], body: String?
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: urlStr) ?? fallback)
        request.httpMethod = method
        var contentType: String? = nil
        for (k, v) in headers {
            let lk = k.lowercased()
            if lk == "content-type" { contentType = v; continue }
            if lk == "content-length" || lk == "host" { continue }
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let b = body {
            request.httpBody = Data(b.utf8)
            if contentType == nil { contentType = "application/json; charset=utf-8" }
        }
        if let ct = contentType {
            request.setValue(ct, forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 300
        return request
    }

    /// Pending camera photos → multimodal user message appended to /chat/completions body.
    private static func attachPendingImages(url: String, body: String?) -> (String, String)? {
        guard let bodyStr = body, !bodyStr.isEmpty else { return nil }
        guard url.contains("/chat/completions") else { return nil }
        guard VisionAttach.hasPending() else { return nil }
        guard var payload = (try? JSONSerialization.jsonObject(with: Data(bodyStr.utf8))) as? [String: Any],
              var messages = payload["messages"] as? [[String: Any]] else { return nil }
        let images = VisionAttach.drain()
        guard !images.isEmpty else { return nil }
        for i in messages.indices {
            if messages[i]["content"] is NSNull {
                messages[i]["content"] = ""
            }
        }
        var content: [[String: Any]] = [[
            "type": "text",
            "text": "[系统附图] 以下为用户刚通过 device_camera 拍摄的照片（按拍摄顺序）。请直接查看图片内容进行分析或回答，不要凭空猜测画面：",
        ]]
        for img in images {
            content.append(["type": "image_url", "image_url": ["url": img]])
        }
        messages.append(["role": "user", "content": content])
        payload["messages"] = messages
        var targetUrl = url
        if url.contains("open.bigmodel.cn") {
            if url.contains("/api/coding/") {
                targetUrl = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
                payload["model"] = "glm-4.6v"
            } else if !((payload["model"] as? String) ?? "").hasSuffix("v") {
                payload["model"] = "glm-4.6v"
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let out = String(data: data, encoding: .utf8) else { return nil }
        return (targetUrl, out)
    }

    private static func encode(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Chunk-boundary-safe UTF-8 decoder: incomplete multibyte sequences carry to the next chunk.
struct Utf8StreamDecoder {
    private var carry: [UInt8] = []

    mutating func decode(_ data: Data) -> String? {
        var bytes = carry + [UInt8](data)
        carry.removeAll()
        let cut = Self.validPrefixLength(bytes)
        if cut < bytes.count {
            carry = Array(bytes[cut...])
            bytes = Array(bytes[0..<cut])
        }
        if bytes.isEmpty { return nil }
        return String(data: Data(bytes), encoding: .utf8)
    }

    /// End of stream: lossy-decode any leftover bytes (invalid → U+FFFD).
    mutating func flush() -> String? {
        let bytes = carry
        carry.removeAll()
        guard !bytes.isEmpty else { return nil }
        if let s = String(data: Data(bytes), encoding: .utf8) { return s }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Longest valid-prefix length: scan back ≤4 bytes for a start byte; if the
    /// trailing sequence is incomplete, cut before its start byte.
    private static func validPrefixLength(_ b: [UInt8]) -> Int {
        let n = b.count
        var i = n - 1
        var back = 0
        while i >= 0 && back <= 3 {
            let c = b[i]
            if c & 0xC0 == 0x80 {
                if back == 3 { return max(n - 3, 0) }  // >3 trailing continuations: malformed
                back += 1
                i -= 1
                continue
            }
            let need: Int
            if c >= 0xF0 { need = 4 }
            else if c >= 0xE0 { need = 3 }
            else if c >= 0xC0 { need = 2 }
            else { need = 1 }
            return (n - i) >= need ? n : i
        }
        return max(i + 1, 0)
    }
}
