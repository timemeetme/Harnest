import Foundation

struct ProviderMeta {
    let provider: String
    let label: String
    let baseUrl: String
    let defaultModel: String
    let models: [String]
    let keyUrl: String
}

enum Providers {
    static let deepseek = "deepseek"
    static let qwen = "qwen"
    static let doubao = "doubao"
    static let zhipu = "zhipu"
    static let zhipuCoding = "zhipu_coding"
    static let moonshot = "moonshot"
    static let openai = "openai"
    static let gemini = "gemini"
    static let claude = "claude"
    static let custom = "custom"

    static let meta: [String: ProviderMeta] = [
        deepseek: ProviderMeta(
            provider: deepseek, label: "DeepSeek", baseUrl: "https://api.deepseek.com",
            defaultModel: "deepseek-v4-pro",
            models: ["deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"],
            keyUrl: "https://platform.deepseek.com/api_keys"
        ),
        qwen: ProviderMeta(
            provider: qwen, label: "千问 Qwen", baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen3.7-plus",
            models: ["qwen3.8-max", "qwen3.7-max", "qwen3.7-plus", "qwen3.7-flash", "qwen3.6-plus"],
            keyUrl: "https://bailian.console.aliyun.com/"
        ),
        doubao: ProviderMeta(
            provider: doubao, label: "豆包 Doubao", baseUrl: "https://ark.cn-beijing.volces.com/api/v3",
            defaultModel: "doubao-seed-2.1-pro",
            models: [
                "doubao-seed-2.1-pro", "doubao-seed-2.1-turbo", "doubao-seed-2.0-pro",
                "doubao-seed-2.0-lite", "doubao-seed-2.0-mini",
            ],
            keyUrl: "https://console.volcengine.com/ark"
        ),
        zhipu: ProviderMeta(
            provider: zhipu, label: "智谱 按量付费", baseUrl: "https://open.bigmodel.cn/api/paas/v4",
            defaultModel: "glm-5.3",
            models: ["glm-5.3", "glm-5.2", "glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.6", "glm-4.5-air"],
            keyUrl: "https://open.bigmodel.cn/"
        ),
        zhipuCoding: ProviderMeta(
            provider: zhipuCoding, label: "智谱 Coding Plan", baseUrl: "https://open.bigmodel.cn/api/coding/paas/v4",
            defaultModel: "glm-5.3",
            models: ["glm-5.3", "glm-5.2", "glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.6"],
            keyUrl: "https://open.bigmodel.cn/"
        ),
        moonshot: ProviderMeta(
            provider: moonshot, label: "Kimi 月之暗面", baseUrl: "https://api.moonshot.cn/v1",
            defaultModel: "kimi-k3",
            models: ["kimi-k3", "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-k2.6"],
            keyUrl: "https://platform.moonshot.cn/"
        ),
        openai: ProviderMeta(
            provider: openai, label: "OpenAI", baseUrl: "https://api.openai.com/v1",
            defaultModel: "gpt-5.4-mini",
            models: ["gpt-5.6", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano"],
            keyUrl: "https://platform.openai.com/api-keys"
        ),
        gemini: ProviderMeta(
            provider: gemini, label: "Gemini", baseUrl: "https://generativelanguage.googleapis.com/v1beta/openai",
            defaultModel: "gemini-3.7-flash",
            models: ["gemini-3.7-flash", "gemini-3.6-flash", "gemini-flash-latest", "gemini-pro-latest"],
            keyUrl: "https://aistudio.google.com/apikey"
        ),
        claude: ProviderMeta(
            provider: claude, label: "Claude", baseUrl: "https://api.anthropic.com/v1",
            defaultModel: "claude-sonnet-4-6",
            models: ["claude-sonnet-5", "claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"],
            keyUrl: "https://console.anthropic.com/settings/keys"
        ),
        custom: ProviderMeta(
            provider: custom, label: "自定义（OpenAI 兼容）", baseUrl: "",
            defaultModel: "", models: [], keyUrl: ""
        ),
    ]

    static let all: [String] = [
        deepseek, qwen, doubao, zhipu, zhipuCoding, moonshot, openai, gemini, claude, custom,
    ]

    static let importAlias: [String: String] = ["chatgpt": openai, "kimi": moonshot]

    static let importUnsupported: [String] = []

    /// 2026-08 预设刷新前的旧模型列表（一次性迁移用，见 ConfigService.migratePresets）：
    /// 存量配置里模型列表未定制（全部落在旧预设内）的条目整体替换为官方现役预设；
    /// 定制过的列表保留用户条目，仅把缺失的现役预设补入（保证 kimi-k3 等始终可选）。
    /// gemini 旧列表与新版一致，无需迁移。
    static let legacyPresetModels: [String: [String]] = [
        deepseek: ["deepseek-chat", "deepseek-reasoner"],
        qwen: ["qwen3-max", "qwen-plus", "qwen-flash", "qwen-turbo", "qwen3-coder-plus", "qwq-plus"],
        doubao: [
            "doubao-seed-1.6-251015", "doubao-seed-1.6-lite-251015", "doubao-seed-1-6-250615",
            "doubao-1.5-pro-32k-250115", "doubao-1.5-thinking-pro-250415",
        ],
        zhipu: ["glm-5.2", "glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.6", "glm-4.5", "glm-4.5-air"],
        zhipuCoding: ["glm-5.2", "glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.6", "glm-4.5"],
        moonshot: ["kimi-k2-0905-preview", "kimi-k2-turbo-preview", "kimi-latest"],
        openai: ["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "o3", "o3-mini", "o4-mini"],
    ]

    static func metaOf(_ provider: String) -> ProviderMeta? { meta[provider] }
}

/// 思考模式档位 — 镜像 Android common/Providers.kt ReasoningEfforts。
enum ReasoningEfforts {
    static let ids: [String] = ["off", "low", "high", "max"]

    static func label(_ id: String?) -> String {
        switch id {
        case "off": return "关闭思考"
        case "low": return "轻思考"
        case "high": return "思考"
        case "max": return "深度思考"
        default: return "默认"
        }
    }

    static func isValid(_ id: String?) -> Bool {
        guard let id = id else { return true }
        return ids.contains(id)
    }
}
