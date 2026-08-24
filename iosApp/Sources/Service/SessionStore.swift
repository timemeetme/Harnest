import Foundation

/// Persisted chat message — tool rows carry trajectory fields.
struct StoredMessage: Identifiable, Equatable {
    var id: String
    var role: String
    var content: String
    var createdAt: Int64
    var provider: String?
    var model: String?
    var toolName: String?
    var toolStatus: String?
    var toolResult: String?
    var todosJson: String?
    var durationMs: Int64
    var traceJson: String?
    var steered: Bool
    var rating: Int
    /// 错误/兜底文案消息（红色样式 + 重试入口，不入评分）
    var isError: Bool
    /// 回合 token 用量（内核 details.usage surfaced；0 = 未上报）
    var inTok: Int64
    var outTok: Int64

    init(
        id: String,
        role: String,
        content: String,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        provider: String? = nil,
        model: String? = nil,
        toolName: String? = nil,
        toolStatus: String? = nil,
        toolResult: String? = nil,
        todosJson: String? = nil,
        durationMs: Int64 = 0,
        traceJson: String? = nil,
        steered: Bool = false,
        rating: Int = 0,
        isError: Bool = false,
        inTok: Int64 = 0,
        outTok: Int64 = 0
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.provider = provider
        self.model = model
        self.toolName = toolName
        self.toolStatus = toolStatus
        self.toolResult = toolResult
        self.todosJson = todosJson
        self.durationMs = durationMs
        self.traceJson = traceJson
        self.steered = steered
        self.rating = rating
        self.isError = isError
        self.inTok = inTok
        self.outTok = outTok
    }

    var dict: [String: Any] {
        var o: [String: Any] = [
            "id": id, "role": role, "content": content, "createdAt": createdAt,
        ]
        if let v = provider { o["provider"] = v }
        if let v = model { o["model"] = v }
        if let v = toolName { o["toolName"] = v }
        if let v = toolStatus { o["toolStatus"] = v }
        if let v = toolResult { o["toolResult"] = v }
        if let v = todosJson { o["todosJson"] = v }
        if durationMs > 0 { o["durationMs"] = durationMs }
        if let v = traceJson { o["traceJson"] = v }
        if steered { o["steered"] = true }
        if rating != 0 { o["rating"] = rating }
        if isError { o["isError"] = true }
        if inTok > 0 { o["inTok"] = inTok }
        if outTok > 0 { o["outTok"] = outTok }
        return o
    }

    static func from(_ o: [String: Any]) -> StoredMessage {
        StoredMessage(
            id: o["id"] as? String ?? "",
            role: o["role"] as? String ?? "user",
            content: o["content"] as? String ?? "",
            createdAt: (o["createdAt"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000),
            provider: o["provider"] as? String,
            model: o["model"] as? String,
            toolName: o["toolName"] as? String,
            toolStatus: o["toolStatus"] as? String,
            toolResult: o["toolResult"] as? String,
            todosJson: o["todosJson"] as? String,
            durationMs: (o["durationMs"] as? NSNumber)?.int64Value ?? 0,
            traceJson: o["traceJson"] as? String,
            steered: (o["steered"] as? NSNumber)?.boolValue ?? false,
            rating: (o["rating"] as? NSNumber)?.intValue ?? 0,
            isError: (o["isError"] as? NSNumber)?.boolValue ?? false,
            inTok: (o["inTok"] as? NSNumber)?.int64Value ?? 0,
            outTok: (o["outTok"] as? NSNumber)?.int64Value ?? 0
        )
    }
}

/// Persisted session — provider/model selection saved per conversation.
struct SessionRecord: Identifiable, Equatable {
    var id: String
    var title: String
    var provider: String
    var model: String
    /// 思考模式（off/high/max）；nil = 服务端默认。与 provider/model 一起按会话记忆。
    var effort: String?
    var createdAt: Int64
    var updatedAt: Int64
    var messages: [StoredMessage]

    init(
        id: String,
        title: String,
        provider: String,
        model: String,
        effort: String? = nil,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        messages: [StoredMessage] = []
    ) {
        self.id = id
        self.title = title
        self.provider = provider
        self.model = model
        self.effort = effort
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    var dict: [String: Any] {
        var o: [String: Any] = [
            "id": id,
            "title": title,
            "provider": provider,
            "model": model,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "messages": messages.map { $0.dict },
        ]
        if let v = effort { o["effort"] = v }
        return o
    }

    static func from(_ o: [String: Any]) -> SessionRecord {
        let messages = (o["messages"] as? [[String: Any]] ?? []).map { StoredMessage.from($0) }
        return SessionRecord(
            id: o["id"] as? String ?? "",
            title: o["title"] as? String ?? "新会话",
            provider: o["provider"] as? String ?? "",
            model: o["model"] as? String ?? "",
            effort: o["effort"] as? String,
            createdAt: (o["createdAt"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000),
            updatedAt: (o["updatedAt"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000),
            messages: messages
        )
    }
}

/// Session persistence — sessions.json, mirrors SessionStore.kt / SessionStore.ets.
final class SessionStore {

    private static let file = AppPaths.baseDir.appendingPathComponent("sessions.json")

    /// k3b 会话内记忆：per-session .jsonl 事件日志目录。
    private static let logDir = AppPaths.baseDir.appendingPathComponent("session-logs", isDirectory: true)

    private static let shared = SessionStore()

    static func get() -> SessionStore { shared }

    static func newId() -> String {
        let rand = Int.random(in: 0..<1_000_000_000)
        return "session-" + String(Int64(Date().timeIntervalSince1970 * 1000)) + "-" + String(rand, radix: 36)
    }

    static func titleFrom(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if t.count > 24 { return String(t.prefix(24)) }
        return t.isEmpty ? "新会话" : t
    }

    private let lock = NSLock()
    private var cached: [SessionRecord]?

    // 会话内记忆持久层（k3b）：事件来自 JSC 求值线程的逐条镜像 —
    // 串行队列按到达序落盘（append-only），replay 时作为 seedJson。
    private let logQueue = DispatchQueue(label: "harnest.session-log-writer", qos: .utility)

    private func logFile(_ sessionId: String) -> URL {
        Self.logDir.appendingPathComponent(sessionId + ".jsonl")
    }

    private static func jsonLine(_ o: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 内核 log 镜像事件路由（LocalEngine.onLogEvent 直投 — 后台线程，无 UI）。
    func onKernelLogEvent(_ o: [String: Any]) {
        guard let sessionId = o["sessionId"] as? String, !sessionId.isEmpty else { return }
        let type = o["type"] as? String ?? ""
        if type == "log" {
            if let event = o["event"] as? [String: Any] {
                appendLogEvent(sessionId: sessionId, event: event)
            }
        } else if type == "log-reset" {
            if let events = o["events"] as? [[String: Any]] {
                resetLogFile(sessionId: sessionId, events: events)
            }
        }
    }

    /// 增量事件追加一行（envelope 全字段 — time/surfaceOp/sourceEventSeqs 为 seed 校验/压缩重放必填）。
    private func appendLogEvent(sessionId: String, event: [String: Any]) {
        guard let line = Self.jsonLine(event) else { return }
        logQueue.async { [weak self] in
            guard let self = self else { return }
            let f = self.logFile(sessionId)
            try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: f.path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: f, options: .atomic)
            }
        }
    }

    /// 全量重写（createSession 时内核下行完整 log — 收敛到内核真相，顺带清掉崩溃残留的半写入行）。
    private func resetLogFile(sessionId: String, events: [[String: Any]]) {
        var sb = ""
        for e in events {
            if let line = Self.jsonLine(e) {
                sb += line
                sb += "\n"
            }
        }
        logQueue.async { [weak self] in
            guard let self = self else { return }
            let f = self.logFile(sessionId)
            try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
            if let data = sb.data(using: .utf8) {
                try? data.write(to: f, options: .atomic)
            }
        }
    }

    /// 读取事件日志 → createSession(seedJson)（内核解析平衡前缀后 replay 重建上下文）。
    func readSeedJson(sessionId: String) -> String? {
        let f = logFile(sessionId)
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// k6 fork：截断事件日志到「第 n 个非转向用户回合」的 turn/end（含）。
    ///  结构计数（turn/start +1 / turn/end -1），忽略嵌套 step；找不到目标回合返回 nil。
    func truncateLogAtUserTurn(sessionId: String, targetUserTurn: Int) -> String? {
        if targetUserTurn <= 0 { return nil }
        let f = logFile(sessionId)
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        var sb = ""
        var depth = 0
        var userTurns = 0
        var done = false
        for lineRaw in text.components(separatedBy: .newlines) {
            if done { break }
            let t = lineRaw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard let data = t.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue } // 崩溃残留半写入行 — 跳过
            let type = o["type"] as? String ?? ""
            if type == "turn/start" {
                depth += 1
                sb += t
                sb += "\n"
            } else if type == "turn/end" {
                sb += t
                sb += "\n"
                if depth > 0 {
                    depth -= 1
                    if depth == 0 {
                        userTurns += 1
                        if userTurns == targetUserTurn { done = true }
                    }
                }
            } else {
                sb += t
                sb += "\n"
            }
        }
        if done {
            let trimmed = sb.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// k6 fork：整份复制事件日志到 fork 会话（fork 源消息在末尾 → 完整前缀）。
    @discardableResult
    func copyLogTo(fromId: String, toId: String) -> Bool {
        let src = logFile(fromId)
        let dst = logFile(toId)
        guard FileManager.default.fileExists(atPath: src.path) else { return false }
        try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
        return true
    }

    /// k6 fork：把截断后的事件日志文本写入 fork 会话（下次 createSession 作为 seed 重放）。
    @discardableResult
    func writeSeedText(_ sessionId: String, _ seed: String) -> Bool {
        guard let data = seed.data(using: .utf8) else { return false }
        try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        let f = logFile(sessionId)
        do {
            try FileManager.default.removeItem(at: f)
        } catch {}
        do {
            try data.write(to: f, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func deleteLogFile(sessionId: String) {
        try? FileManager.default.removeItem(at: logFile(sessionId))
    }

    func loadAll() -> [SessionRecord] {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let list = loadFromDiskLocked()
        cached = list
        return list
    }

    func upsert(_ record: SessionRecord) {
        lock.lock(); defer { lock.unlock() }
        var list = cached ?? loadFromDiskLocked()
        if let idx = list.firstIndex(where: { $0.id == record.id }) {
            list[idx] = record
        } else {
            list.insert(record, at: 0)
        }
        cached = list
        saveAllLocked(list)
    }

    func delete(id: String) {
        lock.lock(); defer { lock.unlock() }
        var list = cached ?? loadFromDiskLocked()
        list.removeAll { $0.id == id }
        cached = list
        saveAllLocked(list)
        deleteLogFile(sessionId: id)
    }

    func get(id: String) -> SessionRecord? {
        loadAll().first { $0.id == id }
    }

    private func loadFromDiskLocked() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: Self.file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = root["sessions"] as? [[String: Any]] else { return [] }
        return arr.map { SessionRecord.from($0) }
    }

    private func saveAllLocked(_ list: [SessionRecord]) {
        let root: [String: Any] = ["version": 1, "sessions": list.map { $0.dict }]
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}
