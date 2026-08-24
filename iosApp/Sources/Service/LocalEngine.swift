import Foundation

/**
 * Local kernel engine — mirrors harmonyApp LocalEngine.ets / androidApp LocalEngine.kt.
 * Owns: HarnessEngine (JavaScriptCore) + HttpBridge (URLSession) + DeviceBridge (10 ops).
 * High-level API: init / createSession / chat / setModel / setProviderProfile / listProviders.
 */
final class LocalEngine {

    static func get() -> LocalEngine { shared }
    private static let shared = LocalEngine()
    private init() {}

    private let lock = NSLock()
    private var engine: HarnessEngine?
    private var http: HttpBridge?
    private var device: DeviceBridge?
    private var started = false
    private var starting = false

    /// Session id currently mounted in the kernel (kernel side agent — one at a time).
    private var mountedSessionId: String?

    /// Sequence for device self-test dispatch calls.
    private var testSeq = 900_000

    /// Optional log tap for the UI debug panel.
    var onLogLine: ((String) -> Void)?

    // k 系列事件回调（payload 为原始 JSON 字符串，宿主自行解析）
    var onRoundEvent: ((String) -> Void)?
    var onTitleEvent: ((String) -> Void)?
    var onLogEvent: ((String) -> Void)?
    var onQuestionEvent: ((String) -> Void)?
    var onJobsEvent: ((String) -> Void)?

    func isReady() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return started && (engine?.isReady() ?? false)
    }

    private func engineRef() -> HarnessEngine? {
        lock.lock(); defer { lock.unlock() }
        return engine
    }

    private func httpRef() -> HttpBridge? {
        lock.lock(); defer { lock.unlock() }
        return http
    }

    private func deviceRef() -> DeviceBridge? {
        lock.lock(); defer { lock.unlock() }
        return device
    }

    // ── Lifecycle ────────────────────────────────────────────

    /// Start the engine (idempotent, concurrency-safe).
    /// Throws when no provider is configured — UI should guide to settings.
    func ensureStarted() async throws {
        if isReady() { return }
        while true {
            let claim = lock.withLock { () -> Bool? in
                if started && (engine?.isReady() ?? false) { return nil }
                if starting { return false }
                starting = true
                return true
            }
            if claim == nil { return }
            if claim == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        defer {
            lock.withLock { starting = false }
        }

        do {
            let harnessDir = AppPaths.harnessDir
            guard let engineConfig = ConfigService.get().buildEngineConfig(cwd: harnessDir.path) else {
                throw EngineError.notConfigured
            }

            let eng = HarnessEngine(listener: self)
            try await Self.bootOffMain(eng, cwd: harnessDir)
            if !eng.isReady() {
                throw EngineError.bootFailed("引擎初始化失败（harness.js 加载异常）")
            }

            let httpBridge = HttpBridge(emit: { [weak eng] fetchId, kind, a, b in
                eng?.fetchEvent(fetchId, kind: kind, a: a, b: b)
            })
            let deviceBridge = DeviceBridge(engine: eng)

            lock.withLock {
                engine = eng
                http = httpBridge
                device = deviceBridge
            }

            _ = try await eng.callAwait("init", Self.jsonEncode(engineConfig))
            lock.withLock { started = true }
            NSLog("local engine started")
        } catch {
            lock.withLock {
                if engine === nil { http = nil; device = nil }
            }
            throw error
        }
    }

    /// harness.js eval (1MB+) must stay off the main thread.
    private static func bootOffMain(_ eng: HarnessEngine, cwd: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try eng.boot(cwd: cwd)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Hot-reload provider profiles after settings save (no engine restart).
    func refreshProfiles() {
        guard isReady() else { return }
        for item in ConfigService.get().listUsableProviders() {
            let provider = item["provider"] as? String ?? ""
            let baseUrl = item["baseUrl"] as? String ?? ""
            let apiKey = item["apiKey"] as? String ?? ""
            var models = Self.stringList(item["models"]).filter { !$0.isEmpty }
            if models.isEmpty {
                let fallback = item["defaultModel"] as? String ?? ""
                if !fallback.isEmpty { models = [fallback] }
            }
            setProviderProfile(provider: provider, baseUrl: baseUrl, apiKey: apiKey, models: models)
        }
    }

    /// Provider catalog for the model picker.
    func listProviders() -> [[String: Any]] {
        guard let eng = engineRef() else { return [] }
        let envelope = eng.callFunc("listProviders", nil)
        guard let r = envelope.resultJson,
              let data = r.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            NSLog("listProviders parse failed: \(envelope.error ?? "?")")
            return []
        }
        return arr
    }

    /// Mount a session into the kernel: applies the session's model selection first.
    /// seedJson：会话 .jsonl 事件日志（k3b 会话内记忆）— 内核解析为平衡前缀 seed 后
    /// replay 重建上下文；nil = 全新会话。已挂载同一会话时跳过（内核态即完整真相）。
    func mountSession(_ record: SessionRecord, seedJson: String? = nil) async throws {
        guard isReady(), let eng = engineRef() else { throw EngineError.notStarted }
        setModel(provider: record.provider, model: record.model, effort: record.effort)
        let mounted = lock.withLock { mountedSessionId }
        if mounted == record.id { return }
        var args: [String: Any] = ["sessionId": record.id]
        if let seed = seedJson, !seed.isEmpty { args["seedJson"] = seed }
        _ = try await eng.callAwait("createSession", Self.jsonEncode(args))
        lock.withLock { mountedSessionId = record.id }
    }

    /// Send a message on the mounted session — returns ChatOutcome dictionary.
    func chat(_ text: String) async throws -> [String: Any] {
        try await callJson("chat", ["text": text])
    }

    /// 中途转向（k4）：回合运行中把转向消息注入当前回合下一 step 边界，不打断在途
    /// LLM 请求；idle 时内核降级为普通 chat。返回 {ok,steered} 或降级 ChatOutcome。
    func steer(_ text: String) async throws -> [String: Any] {
        try await callJson("steer", ["text": text])
    }

    /// 手动压缩当前会话上下文（k3，回合间调用）。
    /// 成功 {ok, noop?, summary?, shadowedCount, shadowedTokens}；失败 {ok:false, error, code?}。
    func compactNow() async throws -> [String: Any] {
        try await callJson("compactNow", [:])
    }

    /// 回答 agent 提问（k5）：answersJson 为 [{id, selected[], custom?}]。内核校验
    /// （数量 == questions、id 逐一匹配、selected ⊆ 选项 label、单选 ≤1、custom 与
    /// selected 互斥）通过后 resolve 挂起的 provider ask()，答案作为 tool result 回给
    /// 模型；失败 {ok:false,error}，问题继续挂起（UI 保留卡片待修正）。
    func answerQuestion(qid: Int, answersJson: String) async throws -> [String: Any] {
        let answers = (try? JSONSerialization.jsonObject(with: Data(answersJson.utf8))) as? [Any] ?? []
        return try await callJson("answerQuestion", ["qid": qid, "answers": answers])
    }

    /// 开关 Plan 模式（k5）：回合外立即生效（committed），回合内挂起到下一 pre-step
    /// （queued）；返回 {ok, result, active}。active 亦随每回合 details.planActive 折叠下行。
    func setPlanMode(active: Bool) async throws -> [String: Any] {
        try await callJson("setPlanMode", ["active": active])
    }

    /// k7e：列出当前会话可见的后台任务（后台 bash / 子代理等）。返回 {ok, jobs:[JobView]}。
    func listJobs() async throws -> [String: Any] {
        try await callJson("listJobs", [:])
    }

    /// k7e：请求终止一个后台任务（bash 终止）。返回 {ok, result:requested/already-finished} 或 {ok:false,error}。
    func killJob(id: String) async throws -> [String: Any] {
        try await callJson("killJob", ["id": id])
    }

    /// 中断当前回合（UI 停止按钮调用）：
    /// L3 内核取消 — abortActive() 触发 agent.cancel，正在运行的回合立即中止；
    /// L2 传输断流 — abortAll() 取消所有在途 URLSession 调用，防止取消后继续重试请求。
    func abortActiveRound() {
        guard isReady() else { return }
        _ = engineRef()?.callFunc("abortActive", nil)
        httpRef()?.abortAll()
    }

    /// Switch model (and optional reasoning effort) for the next message.
    func setModel(provider: String, model: String, effort: String? = nil) {
        guard let eng = engineRef() else { return }
        var args: [String: Any] = ["provider": provider, "model": model]
        if let e = effort, !e.isEmpty { args["reasoningEffort"] = e }
        _ = eng.callFunc("setModel", Self.jsonEncode(args))
    }

    /// callAwait + JSON 反序列化公共路径（供 chat/steer/compactNow 等共用）。
    private func callJson(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        guard let eng = engineRef() else { throw EngineError.notStarted }
        let raw = try await eng.callAwait(name, Self.jsonEncode(args))
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["error": raw]
        }
        return obj
    }

    func setProviderProfile(provider: String, baseUrl: String, apiKey: String, models: [String]) {
        guard let eng = engineRef() else { return }
        _ = eng.callFunc("setProviderProfile", Self.jsonEncode([
            "provider": provider,
            "baseUrl": baseUrl,
            "apiKey": apiKey,
            "models": models.map { ["id": $0] },
        ]))
    }

    /// Device self-test (direct): bypass the JS bridge, call DeviceBridge directly.
    func deviceDirectCall(op: String, argsJson: String) async throws -> (Bool, String) {
        guard let dev = deviceRef() else { throw EngineError.notStarted }
        let id = lock.withLock { () -> Int in
            testSeq += 1
            return testSeq
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJson.utf8))) as? [String: Any] ?? [:]
        let req = Self.jsonEncode(["op": op, "args": args])
        return await withCheckedContinuation { cont in
            dev.dispatch(id: id, reqJson: req) { ok, json in
                cont.resume(returning: (ok, json))
            }
        }
    }

    /// Device self-test (full chain): deviceSelfTest → JS bridge → native → DeviceBridge.
    func deviceFullChainCall(op: String, argsJson: String) async throws -> [String: Any] {
        guard let eng = engineRef() else { throw EngineError.notStarted }
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJson.utf8))) as? [String: Any] ?? [:]
        let raw = try await eng.callAwait("deviceSelfTest", Self.jsonEncode(["op": op, "args": args]))
        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["error": raw]
        }
        return obj
    }

    /// Unmount when the session is deleted.
    func unmountIfMounted(_ sessionId: String) {
        lock.lock()
        if mountedSessionId == sessionId { mountedSessionId = nil }
        lock.unlock()
    }

    func dispose() {
        lock.lock()
        started = false
        mountedSessionId = nil
        let eng = engine
        engine = nil
        http = nil
        device = nil
        lock.unlock()
        eng?.dispose()
    }

    // ── HostListener ─────────────────────────────────────────

    private func engFail(id: Int, msg: String) {
        engineRef()?.fetchEvent(id, kind: "fail", a: msg, b: "")
        let json = Self.jsonEncode(["error": msg])
        engineRef()?.deviceResult(id, ok: false, json: json)
    }

    // ── utils ────────────────────────────────────────────────

    static func jsonEncode(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 日志预览截断：高频事件（thinking 累积全文）只保留头部 + 总长标记。
    static func logPreview(_ s: String) -> String {
        guard s.count > 240 else { return s }
        return String(s.prefix(240)) + "…<\(s.count) chars>"
    }

    private static func stringList(_ any: Any?) -> [String] {
        guard let arr = any as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }

    static func stringListAny(_ any: Any?) -> [String] {
        stringList(any)
    }
}

extension LocalEngine: HostListener {

    func onLog(stream: String, chunk: String) {
        let p = Self.logPreview(chunk)
        NSLog("Harness/%@ %@", stream, p)
        onLogLine?("[\(stream)] \(p)")
    }

    func onEvent(eventJson: String) {
        // 万字 thinking 事件 60ms 一条：NSLog/日志镜像全文刷屏会拖垮引擎线程 — 截断预览
        let p = Self.logPreview(eventJson)
        NSLog("Harness/event %@", p)
        onLogLine?("[event] \(p)")
        guard let data = eventJson.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let type = o["type"] as? String ?? ""
        switch type {
        case "round": onRoundEvent?(eventJson)
        case "title": onTitleEvent?(eventJson)
        // k3b 会话内记忆镜像：log（增量事件）/ log-reset（createSession 全量下行）
        case "log", "log-reset": onLogEvent?(eventJson)
        // k5 交互控制：agent 提问下发（asked）/ 已答（answered）/ 作废（cancelled）
        case "question": onQuestionEvent?(eventJson)
        // k7e 后台任务：JobRegistry 可见集全量快照（list 覆盖式镜像，kill/onJobsChanged 触发）
        case "jobs": onJobsEvent?(eventJson)
        default: break
        }
    }

    func onFetch(fetchId: Int, requestJson: String) {
        guard let http = httpRef() else {
            engFail(id: fetchId, msg: "http bridge not ready")
            return
        }
        http.start(fetchId: fetchId, requestJson: requestJson)
    }

    func onDevice(deviceId: Int, requestJson: String) {
        guard let dev = deviceRef(), let eng = engineRef() else {
            engFail(id: deviceId, msg: "device bridge not ready")
            return
        }
        dev.dispatch(id: deviceId, reqJson: requestJson) { ok, json in
            eng.deviceResult(deviceId, ok: ok, json: json)
        }
    }

    func onCallSettled(callId: Int, ok: Bool, json: String) {
        // settle flows through __harnessCallSettle directly (see HarnessEngine)
    }
}
