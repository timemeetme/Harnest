import Foundation
import JavaScriptCore

/**
 * run_script 工具宿主沙箱 — 对齐 androidApp ScriptSandbox.kt / harmonyApp ScriptEngine.cpp。
 * 内核经 device 桥调宿主：op = "runScript"，参数 {code, description, timeoutMs}。
 *
 * 设计要点：
 * - 专用串行队列（label "script-sandbox"，独立于引擎 jsQueue，防交叉死锁）；
 *   所有 JSContext evaluateScript 固定在该队列。
 * - 每次运行全新 JSContext；预置 log / console / fetch / readText / writeText。
 * - fetch 走独立 ephemeral URLSession（60s）；完成经 __sbFetchDone 回投（参数 jsLiteral 转义）。
 * - 文件读写限定 Documents/Scripts 根内（standardizedFileURL + 前缀校验，逃逸即拒）。
 * - 外层 50ms 轮询信号量 + 队列上 evaluateScript("0") 驱动 JSC 微任务（纯计算脚本需要）。
 * - 超时熔断：结果先行返回，context 在沙箱队列空闲后异步置 nil 释放（不跨线程 release）。
 * - 共享状态收在 RunState（NSLock 保护）：JS 桥回调（沙箱队列）与等待循环（调用线程）安全交接。
 * - runLock 串行化并发 runSync；脚本抛错不 throw，交模型自修。
 */
final class ScriptSandbox: @unchecked Sendable {

    static let shared = ScriptSandbox()

    private let queue = DispatchQueue(label: "script-sandbox")
    private let session: URLSession
    private let root: URL
    private let runLock = NSLock()
    /// 仅在沙箱队列访问（__sbFetch 桥同步执行期）
    private var nextFetchId: Int32 = 1

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        session = URLSession(configuration: cfg)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = docs.appendingPathComponent("Scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - 执行入口

    /// 同步执行一段 JS（DeviceBridge runScript case 调用，后台线程）。
    /// 返回给内核的 envelope：{ok, result, stdout, stdoutTruncated, error, timedOut, durationMs}。
    func runSync(code: String, timeoutMs: Int) -> [String: Any] {
        runLock.lock()
        defer { runLock.unlock() }

        let timeout = min(max(timeoutMs, 1_000), 120_000)
        let started = Date()
        let sem = DispatchSemaphore(value: 0)
        let st = RunState(sem: sem)
        let box = CtxBox()

        queue.sync { [self] in
            guard let ctx = JSContext() else {
                st.settleError("cannot create JSContext")
                return
            }
            box.ctx = ctx
            ctx.exceptionHandler = { _, value in
                st.settleError(value?.toString() ?? "unknown script error")
            }
            registerBridges(ctx, st: st, box: box)
            _ = ctx.evaluateScript(Self.runtimeJS)
            if ctx.exception != nil { return }
            _ = ctx.evaluateScript(Self.wrap(code))
            if ctx.exception != nil { return }
        }

        let deadline = started.addingTimeInterval(Double(timeout) / 1000.0)
        var fired = false
        while Date() < deadline {
            if sem.wait(timeout: .now() + 0.05) == .success { fired = true; break }
            // 微任务泵：JSC 的 promise 回调需要新的 evaluateScript 边界驱动
            queue.async { _ = box.ctx?.evaluateScript("0") }
        }

        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let snap = st.snapshot()

        if !fired || !snap.settled {
            // 超时熔断：异步释放 context（队列空闲后生效，不阻塞返回）
            queue.async { box.ctx = nil }
            return [
                "ok": false,
                "result": "",
                "stdout": snap.stdout,
                "stdoutTruncated": snap.stdoutTruncated,
                "error": "execution timed out after \(timeout)ms",
                "timedOut": true,
                "durationMs": durationMs,
            ]
        }
        if let err = snap.error {
            return [
                "ok": false,
                "result": "",
                "stdout": snap.stdout,
                "stdoutTruncated": snap.stdoutTruncated,
                "error": err,
                "timedOut": false,
                "durationMs": durationMs,
            ]
        }
        var result = snap.result ?? "null"
        if result.count > 32_768 {
            result = String(result.prefix(32_768)) + "…[truncated]"
        }
        return [
            "ok": true,
            "result": result,
            "stdout": snap.stdout,
            "stdoutTruncated": snap.stdoutTruncated,
            "error": "",
            "timedOut": false,
            "durationMs": durationMs,
        ]
    }

    // MARK: - 桥注册

    private func registerBridges(_ ctx: JSContext, st: RunState, box: CtxBox) {

        // __sbLog(line)：累计 stdout（总量 65536 封顶，丢头保尾）
        ctx.setObject({ (line: String) in
            st.appendLog(line)
        }, forKeyedSubscript: "__sbLog" as NSString)

        // __sbFetch(url, initJson) -> fetchId：异步发起，完成经 __sbFetchDone 回投
        ctx.setObject({ [weak self] (url: String, initJson: String) -> Int32 in
            guard let self else { return 0 }
            let id = self.nextFetchId
            self.nextFetchId += 1
            self.startFetch(id: id, url: url, initJson: initJson, box: box)
            return id
        }, forKeyedSubscript: "__sbFetch" as NSString)

        // __sbRead(path) -> JSON 字符串 {ok, data?} / {ok:false, error}
        ctx.setObject({ [root] (path: String) -> String in
            Self.readEnvelope(root: root, path: path)
        }, forKeyedSubscript: "__sbRead" as NSString)

        // __sbWrite(path, content) -> JSON 字符串 {ok} / {ok:false, error}
        ctx.setObject({ [root] (path: String, content: String) -> String in
            Self.writeEnvelope(root: root, path: path, content: content)
        }, forKeyedSubscript: "__sbWrite" as NSString)

        // 结算：__sbSettle(json) / __sbSettleErr(msg)（signal 信号量）
        ctx.setObject({ (json: String) in
            st.settleResult(json)
        }, forKeyedSubscript: "__sbSettle" as NSString)

        ctx.setObject({ (msg: String) in
            st.settleError(msg)
        }, forKeyedSubscript: "__sbSettleErr" as NSString)
    }

    // MARK: - fetch

    private func startFetch(id: Int32, url: String, initJson: String, box: CtxBox) {
        guard let u = URL(string: url),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            dispatchFetchDone(id, box: box, ok: false, status: 0,
                              headersJson: "{}", body: "",
                              err: "invalid url: \(url.prefix(200))")
            return
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 60
        if let data = initJson.data(using: .utf8),
           let initObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let method = (initObj["method"] as? String ?? "GET").uppercased()
            req.httpMethod = method.isEmpty ? "GET" : method
            if let headers = initObj["headers"] as? [String: String] {
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            }
            if let body = initObj["body"] as? String {
                req.httpBody = body.data(using: .utf8)
            }
        }
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            var headers: [String: String] = [:]
            for (k, v) in (http?.allHeaderFields ?? [:]) {
                headers["\(k)"] = "\(v)"
            }
            var body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            if body.count > 262_144 {
                body = String(body.prefix(262_144)) + "…[truncated]"
            }
            guard JSONSerialization.isValidJSONObject(headers),
                  let hData = try? JSONSerialization.data(withJSONObject: headers),
                  let headersJson = String(data: hData, encoding: .utf8) else {
                self.dispatchFetchDone(id, box: box, ok: false, status: status,
                                       headersJson: "{}", body: "",
                                       err: "response encode failed")
                return
            }
            if let error {
                self.dispatchFetchDone(id, box: box, ok: false, status: status,
                                       headersJson: headersJson, body: body,
                                       err: error.localizedDescription)
            } else {
                self.dispatchFetchDone(id, box: box, ok: true, status: status,
                                       headersJson: headersJson, body: body, err: nil)
            }
        }
        task.resume()
    }

    private func dispatchFetchDone(_ id: Int32, box: CtxBox, ok: Bool, status: Int,
                                   headersJson: String, body: String, err: String?) {
        let errLiteral = err.map { Self.jsLiteral($0) } ?? "null"
        let js = "__sbFetchDone(\(id), \(ok ? "true" : "false"), \(status), "
            + "\(Self.jsLiteral(headersJson)), \(Self.jsLiteral(body)), \(errLiteral));"
        queue.async {
            _ = box.ctx?.evaluateScript(js)
        }
    }

    // MARK: - 文件桥（沙箱根内读写）

    private static func resolvePath(root: URL, path: String) -> URL? {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = URL(fileURLWithPath: cleanPath, relativeTo: root).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else { return nil }
        return url
    }

    private static func readEnvelope(root: URL, path: String) -> String {
        guard let url = resolvePath(root: root, path: path) else {
            return encodeEnvelope(ok: false, data: nil, error: "path escapes sandbox")
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return encodeEnvelope(ok: false, data: nil, error: "read failed: \(path)")
        }
        var text = String(data: data, encoding: .utf8) ?? ""
        if text.count > 262_144 {
            text = String(text.prefix(262_144)) + "…[truncated]"
        }
        return encodeEnvelope(ok: true, data: text, error: nil)
    }

    private static func writeEnvelope(root: URL, path: String, content: String) -> String {
        guard let url = resolvePath(root: root, path: path) else {
            return encodeEnvelope(ok: false, data: nil, error: "path escapes sandbox")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return encodeEnvelope(ok: true, data: nil, error: nil)
        } catch {
            return encodeEnvelope(ok: false, data: nil, error: "write failed: \(error.localizedDescription)")
        }
    }

    private static func encodeEnvelope(ok: Bool, data: String?, error: String?) -> String {
        var obj: [String: Any] = ["ok": ok]
        if let data { obj["data"] = data }
        if let error { obj["error"] = error }
        guard JSONSerialization.isValidJSONObject(obj),
              let j = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: j, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"encode failed\"}"
        }
        return s
    }

    // MARK: - JS 源

    /// 沙箱 runtime 预置（对齐 Android / Harmony 端）
    private static let runtimeJS = """
globalThis.__sb = { pending: new Map(), logs: [] };
globalThis.log = (...parts) => __sbLog(parts.map(p => typeof p === 'string' ? p : JSON.stringify(p)).join(' '));
globalThis.console = { log: globalThis.log, error: globalThis.log, warn: globalThis.log, info: globalThis.log };
globalThis.fetch = (url, init) => new Promise((resolve, reject) => { const id = __sbFetch(String(url), JSON.stringify(init || {})); __sb.pending.set(id, { resolve, reject }); });
globalThis.__sbFetchDone = (id, ok, status, headersJson, body, err) => { const p = __sb.pending.get(id); if (!p) return; __sb.pending.delete(id); if (ok) { p.resolve({ status, ok: status >= 200 && status < 300, headers: JSON.parse(headersJson || '{}'), text: async () => body }); } else { p.reject(new Error(String(err || 'fetch failed'))); } };
globalThis.readText = (path) => { const r = JSON.parse(__sbRead(String(path))); if (!r.ok) throw new Error(r.error); return r.data; };
globalThis.writeText = (path, content) => { const r = JSON.parse(__sbWrite(String(path), String(content))); if (!r.ok) throw new Error(r.error); };
"""

    /// 用户代码包裹：settle / settleErr 结算，栈信息截前 3 行
    private static func wrap(_ code: String) -> String {
        """
Promise.resolve().then(async () => {
\(code)
}).then(v => __sbSettle(JSON.stringify(v === undefined ? null : v))).catch(e => __sbSettleErr(String((e && e.message) || e) + ((e && e.stack) ? '\\n' + String(e.stack).split('\\n').slice(0, 3).join('\\n') : '')));
"""
    }

    /// JS 字符串字面量转义（对齐 HarnessEngine.jsStringLiteral）
    private static func jsLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20 || c.value == 0x7f:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }
}

// MARK: - 辅助类型

/// 每次运行的共享状态：JS 桥回调（沙箱队列）与等待循环（调用线程）经 NSLock 安全交接。
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let sem: DispatchSemaphore
    private var logs: [String] = []
    private var totalChars = 0
    private var logsTruncated = false
    private var settledFlag = false
    private var resultText: String?
    private var errorText: String?

    init(sem: DispatchSemaphore) { self.sem = sem }

    func appendLog(_ line: String) {
        var l = line
        if l.count > 16_384 {
            l = String(l.prefix(16_384)) + "…[line truncated]"
        }
        lock.lock()
        logs.append(l)
        totalChars += l.count
        while totalChars > 65_536, logs.count > 1 {
            totalChars -= logs.removeFirst().count
            logsTruncated = true
        }
        lock.unlock()
    }

    func settleResult(_ json: String) {
        lock.lock()
        let first = !settledFlag
        if first {
            settledFlag = true
            resultText = json
        }
        lock.unlock()
        if first { sem.signal() }
    }

    func settleError(_ msg: String) {
        lock.lock()
        let first = !settledFlag
        if first {
            settledFlag = true
            errorText = msg
        }
        lock.unlock()
        if first { sem.signal() }
    }

    func snapshot() -> (settled: Bool, result: String?, error: String?,
                        stdout: String, stdoutTruncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (settledFlag, resultText, errorText, logs.joined(separator: "\n"), logsTruncated)
    }
}

/// context 持有盒：fetch 完成回调经 box 回投；超时后在沙箱队列异步置 nil 释放。
/// ctx 仅在沙箱队列上访问（evaluateScript / 置 nil），@unchecked Sendable 安全。
private final class CtxBox: @unchecked Sendable {
    var ctx: JSContext?
}
