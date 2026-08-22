import Foundation
import JavaScriptCore

/// Host callbacks — mirroring harness_engine.h / HarnessEngine.kt.
protocol HostListener: AnyObject {
    func onLog(stream: String, chunk: String)
    func onEvent(eventJson: String)
    func onFetch(fetchId: Int, requestJson: String)
    func onDevice(deviceId: Int, requestJson: String)
    func onCallSettled(callId: Int, ok: Bool, json: String)
}

struct CallEnvelope {
    let isAsync: Bool
    let callId: Int
    let resultJson: String?
    let error: String?
}

enum EngineError: LocalizedError {
    case notConfigured
    case notStarted
    case callFailed(String)
    case bootFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置任何大模型 API — 请在设置中添加"
        case .notStarted: return "引擎未启动"
        case .callFailed(let msg): return msg
        case .bootFailed(let msg): return msg
        }
    }
}

/**
 * JavaScriptCore engine wrapper — same bridge protocol as the QuickJS versions
 * (harmonyApp cpp/harness_engine.cpp, androidApp HarnessEngine.kt):
 *
 * Uplink (native blocks registered as JS globals before eval):
 *   __harnessFetchStart(requestJson) -> fetchId
 *   __harnessEmit(eventJson)
 *   __harnessFsCall(argsJson) -> resultJson   (sync, sandboxed)
 *   __harnessDeviceCall(requestJson) -> deviceId
 *   __harnessStdout / __harnessStderr / __harnessProcessExit
 *   __harnessCallSettle(callId, ok, json)
 *
 * Downlink (evaluated on the JS queue; JSC drains microtasks after each eval):
 *   __harnessOnFetchHeaders(id, status, headersJson)
 *   __harnessOnFetchChunk(id, text)
 *   __harnessOnFetchDone(id)
 *   __harnessOnFetchFail(id, error)
 *   __harnessOnDeviceResult(id, ok, json)
 *
 * Engine factory: evaluate harness.js then createEngine() -> instance.
 * callFunc(): __harnessCall(funcName, jsonArgs) -> {sync,resultJson} | callId(async).
 */
final class HarnessEngine {

    private weak var listener: HostListener?

    /// All JSContext access happens on this serial queue.
    private let jsQueue = DispatchQueue(label: "harnest.js")

    private let stateLock = NSLock()
    private var context: JSContext?
    private var ready = false

    private(set) var sandboxRoot: URL

    private var nextFetchId = 0
    private var nextDeviceId = 0
    private var pendingCalls: [Int: CheckedContinuation<String, Error>] = [:]
    private var earlySettles: [Int: (Bool, String)] = [:]

    init(listener: HostListener) {
        self.listener = listener
        self.sandboxRoot = AppPaths.harnessDir
    }

    func isReady() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return ready
    }

    // ── Lifecycle ────────────────────────────────────────────

    func boot(cwd: URL) throws {
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        sandboxRoot = cwd
        var bootError: Error?
        jsQueue.sync {
            do { try doInit(cwd: cwd) } catch { bootError = error }
        }
        if let e = bootError {
            stateLock.lock(); ready = false; stateLock.unlock()
            throw e
        }
        stateLock.lock(); ready = true; stateLock.unlock()
    }

    private func doInit(cwd: URL) throws {
        guard let ctx = JSContext() else {
            throw EngineError.bootFailed("JSContext create failed")
        }
        context = ctx
        ctx.exceptionHandler = { [weak self] _, value in
            let msg = value?.toString() ?? "unknown js exception"
            self?.listener?.onLog(stream: "stderr", chunk: "[engine] \(msg)")
        }
        let global = ctx.globalObject

        // 1. env globals (before eval — harness.js probes them)
        global.setObject(cwd.path, forKeyedSubscript: "__HARNESS_CWD" as NSString)
        global.setObject(NSDictionary(), forKeyedSubscript: "__HARNESS_ENV" as NSString)

        // 2. console shim (harness.js may console.log during eval; JSContext has none by default)
        ctx.evaluateScript(
            """
            (function(){
              if (typeof console === 'undefined') {
                var join = function(a){ return Array.prototype.slice.call(a).map(String).join(' ') + '\\n'; };
                globalThis.console = {
                  log: function(){ globalThis.__harnessStdout(join(arguments)); },
                  info: function(){ globalThis.__harnessStdout(join(arguments)); },
                  debug: function(){ globalThis.__harnessStdout(join(arguments)); },
                  warn: function(){ globalThis.__harnessStderr(join(arguments)); },
                  error: function(){ globalThis.__harnessStderr(join(arguments)); }
                };
              }
            })();
            """
        )

        // 3. host bridge functions (must exist BEFORE eval harness.js)
        let fetchStart: @convention(block) (Any?) -> Int = { [weak self] arg in
            guard let self = self else { return -1 }
            let reqJson = (arg as? String) ?? String(describing: arg ?? "")
            self.stateLock.lock()
            self.nextFetchId += 1
            let id = self.nextFetchId
            self.stateLock.unlock()
            self.jsQueue.async { [weak self] in
                self?.listener?.onFetch(fetchId: id, requestJson: reqJson)
            }
            return id
        }
        global.setObject(fetchStart, forKeyedSubscript: "__harnessFetchStart" as NSString)

        let emit: @convention(block) (Any?) -> Void = { [weak self] arg in
            guard let self = self else { return }
            let evt = (arg as? String) ?? "{}"
            self.listener?.onEvent(eventJson: evt)
        }
        global.setObject(emit, forKeyedSubscript: "__harnessEmit" as NSString)

        let fsCall: @convention(block) (Any?) -> String = { [weak self] arg in
            guard let self = self else { return "{\"ok\":false,\"error\":\"engine gone\"}" }
            return FsBridge.handle(engine: self, reqJson: (arg as? String) ?? "{}")
        }
        global.setObject(fsCall, forKeyedSubscript: "__harnessFsCall" as NSString)

        let deviceCall: @convention(block) (Any?) -> Int = { [weak self] arg in
            guard let self = self else { return -1 }
            let reqJson = (arg as? String) ?? "{}"
            self.stateLock.lock()
            self.nextDeviceId += 1
            let id = self.nextDeviceId
            self.stateLock.unlock()
            self.jsQueue.async { [weak self] in
                self?.listener?.onDevice(deviceId: id, requestJson: reqJson)
            }
            return id
        }
        global.setObject(deviceCall, forKeyedSubscript: "__harnessDeviceCall" as NSString)

        let stdout: @convention(block) (Any?) -> Void = { [weak self] arg in
            guard let self = self else { return }
            let chunk = (arg as? String) ?? String(describing: arg ?? "")
            self.listener?.onLog(stream: "stdout", chunk: chunk)
        }
        global.setObject(stdout, forKeyedSubscript: "__harnessStdout" as NSString)

        let stderr: @convention(block) (Any?) -> Void = { [weak self] arg in
            guard let self = self else { return }
            let chunk = (arg as? String) ?? String(describing: arg ?? "")
            self.listener?.onLog(stream: "stderr", chunk: chunk)
        }
        global.setObject(stderr, forKeyedSubscript: "__harnessStderr" as NSString)

        let processExit: @convention(block) (Any?) -> Void = { [weak self] _ in
            self?.listener?.onLog(stream: "stderr", chunk: "[engine] process.exit called")
        }
        global.setObject(processExit, forKeyedSubscript: "__harnessProcessExit" as NSString)

        let callSettle: @convention(block) (Any?, Any?, Any?) -> Void = { [weak self] a, b, c in
            guard let self = self else { return }
            let callId = intValue(a) ?? -1
            let ok = boolValue(b) ?? false
            let json = (c as? String) ?? String(describing: c ?? "null")
            self.settleCall(callId, ok, json)
        }
        global.setObject(callSettle, forKeyedSubscript: "__harnessCallSettle" as NSString)

        // 4. evaluate harness.js (bundle resource)
        guard let jsUrl = Bundle.main.url(forResource: "harness", withExtension: "js"),
              let jsCode = try? String(contentsOf: jsUrl, encoding: .utf8) else {
            throw EngineError.bootFailed("harness.js not found in bundle")
        }
        ctx.evaluateScript(jsCode, withSourceURL: URL(fileURLWithPath: "/<harness>"))

        // 5. take over process.stdout/stderr/exit
        ctx.evaluateScript(
            """
            (function(){
              if (typeof process === 'object' && process) {
                if (process.stdout) process.stdout.write = function(c){ globalThis.__harnessStdout(String(c)); return true; };
                if (process.stderr) process.stderr.write = function(c){ globalThis.__harnessStderr(String(c)); return true; };
                process.exit = function(code){ globalThis.__harnessProcessExit(code|0); };
              }
            })();
            """
        )

        // 6. createEngine() + async call driver
        let hasCreate = (ctx.evaluateScript("(typeof createEngine === 'function')")?.toBool()) ?? false
        if !hasCreate {
            throw EngineError.bootFailed("createEngine not found on globalThis after eval")
        }
        ctx.evaluateScript(Self.bootstrapCall)
    }

    /// Async-call driver JS: __harnessCall(name, jsonArgs) -> {sync,resultJson}|callId
    private static let bootstrapCall = """
        (function(){
          globalThis.__harnessEngineInstance = createEngine();
          globalThis.__harnessCallSeq = 0;
          globalThis.__harnessCall = function(funcName, jsonArgs) {
            var inst = globalThis.__harnessEngineInstance;
            if (!inst) return { sync: true, resultJson: JSON.stringify({ error: 'engine not initialized' }) };
            var fn = inst[funcName];
            if (typeof fn !== 'function') fn = globalThis[funcName];
            if (typeof fn !== 'function') return { sync: true, resultJson: JSON.stringify({ error: 'function not found: ' + funcName }) };
            var args = [];
            if (jsonArgs && jsonArgs.length > 0) args.push(JSON.parse(jsonArgs));
            var r;
            try { r = fn.apply(inst, args); }
            catch (e) { return { sync: true, resultJson: JSON.stringify({ error: String((e && e.message) || e) }) }; }
            if (r && typeof r.then === 'function') {
              var callId = ++globalThis.__harnessCallSeq;
              r.then(function(v){
                globalThis.__harnessCallSettle(callId, true, JSON.stringify(v === undefined ? null : v));
              }, function(e){
                globalThis.__harnessCallSettle(callId, false, String((e && e.message) || e));
              });
              return callId;
            }
            return { sync: true, resultJson: JSON.stringify(r === undefined ? null : r) };
          };
        })();
        """

    // ── callFunc (sync or async envelope) ─────────────────────

    /// Must NOT be called from the JS queue (uses jsQueue.sync internally).
    func callFunc(_ funcName: String, _ jsonArgs: String?) -> CallEnvelope {
        if !isReady() {
            return CallEnvelope(isAsync: false, callId: -1, resultJson: nil, error: "engine not ready")
        }
        var raw: String?
        jsQueue.sync {
            guard let ctx = self.context else { return }
            let argsLiteral = jsonArgs.map { Self.jsStringLiteral($0) } ?? "''"
            let script = "JSON.stringify(globalThis.__harnessCall('\(funcName)', \(argsLiteral)))"
            raw = ctx.evaluateScript(script)?.toString()
        }
        guard let raw else {
            return CallEnvelope(isAsync: false, callId: -1, resultJson: nil, error: "js thread unavailable")
        }
        return Self.parseEnvelope(raw)
    }

    /// Async version of callFunc — resolves on settle (or sync immediately).
    func callAwait(_ funcName: String, _ jsonArgs: String?) async throws -> String {
        let envelope = callFunc(funcName, jsonArgs)
        if let err = envelope.error { throw EngineError.callFailed("\(funcName): \(err)") }
        if !envelope.isAsync {
            return envelope.resultJson ?? "null"
        }
        return try await withCheckedThrowingContinuation { cont in
            stateLock.lock()
            if let early = earlySettles.removeValue(forKey: envelope.callId) {
                stateLock.unlock()
                if early.0 { cont.resume(returning: early.1) }
                else { cont.resume(throwing: EngineError.callFailed("\(funcName): \(early.1)")) }
                return
            }
            pendingCalls[envelope.callId] = cont
            stateLock.unlock()
        }
    }

    private func settleCall(_ callId: Int, _ ok: Bool, _ json: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        if let cont = pendingCalls.removeValue(forKey: callId) {
            if ok { cont.resume(returning: json) }
            else { cont.resume(throwing: EngineError.callFailed(json)) }
            return
        }
        earlySettles[callId] = (ok, json)
    }

    private static func parseEnvelope(_ raw: String) -> CallEnvelope {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let callId = Int(trimmed) {
            return CallEnvelope(isAsync: true, callId: callId, resultJson: nil, error: nil)
        }
        guard let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return CallEnvelope(isAsync: false, callId: -1, resultJson: nil, error: "envelope parse failed")
        }
        let isAsync = boolValue(obj["async"]) ?? false
        if isAsync {
            return CallEnvelope(isAsync: true, callId: intValue(obj["callId"]) ?? -1, resultJson: nil, error: nil)
        }
        if let r = obj["resultJson"] as? String {
            return CallEnvelope(isAsync: false, callId: -1, resultJson: r, error: nil)
        }
        return CallEnvelope(isAsync: false, callId: -1, resultJson: nil, error: (obj["error"] as? String) ?? "unknown")
    }

    // ── Downlink: fetch events / device results ───────────────

    func fetchEvent(_ fetchId: Int, kind: String, a: String, b: String) {
        let script: String?
        switch kind {
        case "headers":
            let status = Int(a) ?? 0
            script = "__harnessOnFetchHeaders(\(fetchId), \(status), \(Self.jsStringLiteral(b)))"
        case "chunk":
            script = "__harnessOnFetchChunk(\(fetchId), \(Self.jsStringLiteral(a)))"
        case "done":
            script = "__harnessOnFetchDone(\(fetchId))"
        case "fail":
            script = "__harnessOnFetchFail(\(fetchId), \(Self.jsStringLiteral(a)))"
        default:
            script = nil
        }
        postJs(script)
    }

    func deviceResult(_ deviceId: Int, ok: Bool, json: String) {
        postJs("__harnessOnDeviceResult(\(deviceId), \(ok), \(Self.jsStringLiteral(json)))")
    }

    private func postJs(_ script: String?) {
        guard let script else { return }
        jsQueue.async { [weak self] in
            guard let ctx = self?.context else { return }
            _ = ctx.evaluateScript(script)
        }
    }

    // ── utils ────────────────────────────────────────────────

    /// JSON-string-literal escaping (JSON string literals are valid JS literals).
    static func jsStringLiteral(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                let v = scalar.value
                if v < 0x20 || v == 0x2028 || v == 0x2029 {
                    out += String(format: "\\u%04x", v)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return nil
    }

    func dispose() {
        stateLock.lock()
        ready = false
        let pendings = pendingCalls
        pendingCalls.removeAll()
        earlySettles.removeAll()
        stateLock.unlock()
        for (_, cont) in pendings {
            cont.resume(throwing: EngineError.callFailed("engine disposed"))
        }
        jsQueue.sync {
            context = nil
        }
    }
}
