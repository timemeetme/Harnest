import Foundation

enum AppPaths {
    static var baseDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("harnest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var harnessDir: URL { baseDir.appendingPathComponent("harness", isDirectory: true) }
}

/// AI provider config — mirrors ConfigService.kt / ConfigService.ets (EMM-compatible).
/// Persisted at ApplicationSupport/harnest/api_config.json.
final class ConfigService {

    private static let file = AppPaths.baseDir.appendingPathComponent("api_config.json")

    private static let shared = ConfigService()

    static func get() -> ConfigService { shared }

    private let lock = NSLock()
    private var cached: [String: Any]?

    private func loadLocked() -> [String: Any] {
        if let c = cached { return c }
        var read: [String: Any]? = nil
        if let data = try? Data(contentsOf: Self.file) {
            read = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        if let read = read, read["configs"] is [String: Any] {
            cached = read
            return read
        }
        var configs: [String: Any] = [:]
        for p in Providers.all {
            guard let meta = Providers.metaOf(p) else { continue }
            configs[p] = [
                "provider": p,
                "apiKey": "",
                "baseUrl": meta.baseUrl,
                "models": meta.models,
                "defaultModel": meta.defaultModel,
                "enabled": false,
            ] as [String: Any]
        }
        let fresh: [String: Any] = [
            "version": 1,
            "configs": configs,
            "lastProvider": Providers.deepseek,
            "lastModel": Providers.metaOf(Providers.deepseek)?.defaultModel ?? "",
        ]
        cached = fresh
        saveLocked(fresh)
        return fresh
    }

    private func saveLocked(_ cfg: [String: Any]) {
        // Swift 字典为值类型：写路径必须回写缓存，否则 load() 仍返回旧快照
        // （Kotlin JSONObject 为引用类型，原地 put 即同步；Swift 需显式回写）
        cached = cfg
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    func load() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { saveLocked(c) }
    }

    func getConfig(_ provider: String) -> [String: Any] {
        let c = load()
        if let item = (c["configs"] as? [String: Any])?[provider] as? [String: Any] { return item }
        let meta = Providers.metaOf(provider)
        return [
            "provider": provider,
            "apiKey": "",
            "baseUrl": meta?.baseUrl ?? "",
            "models": meta?.models ?? [],
            "defaultModel": meta?.defaultModel ?? "",
            "enabled": false,
        ] as [String: Any]
    }

    /// Save one provider entry; non-empty apiKey == enabled.
    func setConfig(provider: String, apiKey: String, baseUrl: String, models: [String], defaultModel: String, maxTokens: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        var c = loadLocked()
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBase = baseUrl.isEmpty ? (Providers.metaOf(provider)?.baseUrl ?? "") : baseUrl
        var entry: [String: Any] = [
            "provider": provider,
            "apiKey": trimmedKey,
            "baseUrl": effectiveBase,
            "models": models.isEmpty ? [defaultModel] : models,
            "defaultModel": defaultModel.isEmpty ? (models.first ?? "") : defaultModel,
            "enabled": !trimmedKey.isEmpty,
        ]
        if let mt = maxTokens, mt > 0 {
            entry["maxTokens"] = mt
        }
        var configs = (c["configs"] as? [String: Any]) ?? [:]
        configs[provider] = entry
        c["configs"] = configs
        saveLocked(c)
    }

    func setLastSelection(provider: String, model: String, effort: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var c = loadLocked()
        c["lastProvider"] = provider
        c["lastModel"] = model
        if let v = effort { c["lastEffort"] = v } else { c.removeValue(forKey: "lastEffort") }
        saveLocked(c)
    }

    /// 最近一次发送所用的思考模式；nil = 默认。
    func getDefaultEffort() -> String? {
        let v = load()["lastEffort"] as? String ?? ""
        guard !v.isEmpty else { return nil }
        return ReasoningEfforts.isValid(v) ? v : nil
    }

    func hasUsableConfig() -> Bool { !listUsableProviders().isEmpty }

    /// Provider entries with a non-empty apiKey, in catalog order.
    func listUsableProviders() -> [[String: Any]] {
        let configs = (load()["configs"] as? [String: Any]) ?? [:]
        var out: [[String: Any]] = []
        for p in Providers.all {
            guard let item = configs[p] as? [String: Any] else { continue }
            let key = (item["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { out.append(item) }
        }
        return out
    }

    /// Default pick: last selection if still enabled, else first usable.
    func getDefaultSelection() -> (String, String) {
        let c = load()
        let lastProvider = c["lastProvider"] as? String ?? ""
        if !lastProvider.isEmpty {
            let item = (c["configs"] as? [String: Any])?[lastProvider] as? [String: Any]
            if let item = item, item["enabled"] as? Bool == true {
                let models = jsonStrings(item["models"])
                let lastModel = c["lastModel"] as? String ?? ""
                let model = (models.contains(lastModel) && !lastModel.isEmpty)
                    ? lastModel
                    : (item["defaultModel"] as? String ?? "")
                return (lastProvider, model)
            }
        }
        let usable = listUsableProviders()
        if let first = usable.first {
            return (first["provider"] as? String ?? "", first["defaultModel"] as? String ?? "")
        }
        return (Providers.deepseek, Providers.metaOf(Providers.deepseek)?.defaultModel ?? "")
    }

    /// Kernel init payload: {cwd, providers[], defaultProvider, defaultModel} — nil when unconfigured.
    func buildEngineConfig(cwd: String) -> [String: Any]? {
        let usable = listUsableProviders()
        if usable.isEmpty { return nil }
        let def = getDefaultSelection()
        var profiles: [[String: Any]] = []
        for item in usable {
            var models = jsonStrings(item["models"])
            if models.isEmpty { models = [item["defaultModel"] as? String ?? ""] }
            var profile: [String: Any] = [
                "provider": item["provider"] as? String ?? "",
                "baseUrl": item["baseUrl"] as? String ?? "",
                "apiKey": item["apiKey"] as? String ?? "",
                "models": models.map { ["id": $0] as [String: Any] },
            ]
            if let mt = item["maxTokens"] as? Int, mt > 0 {
                profile["maxTokens"] = mt
            }
            profiles.append(profile)
        }
        return [
            "cwd": cwd,
            "providers": profiles,
            "defaultProvider": def.0,
            "defaultModel": def.1,
        ]
    }

    /// Import EMM/harness_model_config JSON (from clipboard or file). Returns (imported, skipped).
    func importConfigJson(_ jsonStr: String) -> (Int, [String]) {
        lock.lock(); defer { lock.unlock() }
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8))) as? [String: Any] else {
            return (0, [])
        }
        let type = parsed["type"] as? String ?? ""
        if type != "harness_model_config" && type != "emm_model_config" { return (0, []) }
        guard let arr = parsed["configs"] as? [[String: Any]] else { return (0, []) }
        var c = loadLocked()
        var configs = (c["configs"] as? [String: Any]) ?? [:]
        var imported = 0
        var skipped: [String] = []
        for obj in arr {
            let providerRaw = obj["provider"] as? String ?? ""
            let apiKey = (obj["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if providerRaw.isEmpty { continue }
            let provider = Providers.importAlias[providerRaw] ?? providerRaw
            if Providers.importUnsupported.contains(provider) {
                if !skipped.contains(provider) { skipped.append(provider) }
                continue
            }
            guard let meta = Providers.metaOf(provider) else { continue }
            if apiKey.isEmpty || apiKey.count > 500 { continue }
            var models = jsonStrings(obj["models"])
            if models.isEmpty { models = meta.models }
            var defaultModel = (obj["defaultModel"] as? String) ?? (obj["model"] as? String) ?? ""
            if defaultModel.isEmpty { defaultModel = meta.defaultModel }
            if !models.contains(defaultModel) { models.append(defaultModel) }
            var baseUrl = obj["baseUrl"] as? String ?? ""
            if baseUrl.isEmpty { baseUrl = meta.baseUrl }
            if provider == Providers.gemini && !baseUrl.contains("/openai") { baseUrl = meta.baseUrl }
            var entry: [String: Any] = [
                "provider": provider,
                "apiKey": apiKey,
                "baseUrl": baseUrl,
                "models": models,
                "defaultModel": defaultModel,
                "enabled": true,
            ]
            if let mt = obj["maxTokens"] as? Int, mt > 0 {
                entry["maxTokens"] = mt
            }
            if let existing = configs[provider] as? [String: Any],
               existing["apiKey"] as? String == apiKey,
               existing["defaultModel"] as? String == defaultModel {
                continue
            }
            configs[provider] = entry
            imported += 1
        }
        if imported > 0 {
            c["configs"] = configs
            saveLocked(c)
        }
        return (imported, skipped)
    }

    /// Export EMM-compatible model config JSON (only providers with an apiKey).
    func exportConfigJson() -> String {
        let c = load()
        var configs: [[String: Any]] = []
        for p in Providers.all {
            guard let item = (c["configs"] as? [String: Any])?[p] as? [String: Any] else { continue }
            let apiKey = (item["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if apiKey.isEmpty { continue }
            var exported: [String: Any] = [
                "provider": item["provider"] as? String ?? p,
                "apiKey": apiKey,
                "model": item["defaultModel"] as? String ?? "",
                "baseUrl": item["baseUrl"] as? String ?? "",
                "models": item["models"] ?? [],
                "defaultModel": item["defaultModel"] as? String ?? "",
            ]
            if let mt = item["maxTokens"] as? Int, mt > 0 {
                exported["maxTokens"] = mt
            }
            configs.append(exported)
        }
        let out: [String: Any] = [
            "version": 1,
            "type": "emm_model_config",
            "exportTime": Int(Date().timeIntervalSince1970 * 1000),
            "configs": configs,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func jsonStrings(_ any: Any?) -> [String] {
        guard let arr = any as? [Any] else { return [] }
        return arr.compactMap { ($0 as? String)?.isEmpty == false ? $0 as? String : nil }
    }
}
