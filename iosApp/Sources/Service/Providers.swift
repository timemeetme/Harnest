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
    static let custom = "custom"

    static let meta: [String: ProviderMeta] = [
        deepseek: ProviderMeta(
            provider: deepseek, label: "DeepSeek", baseUrl: "https://api.deepseek.com",
            defaultModel: "deepseek-chat", models: ["deepseek-chat", "deepseek-reasoner"],
            keyUrl: "https://platform.deepseek.com/api_keys"
        ),
        qwen: ProviderMeta(
            provider: qwen, label: "千问 Qwen", baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-plus",
            models: ["qwen3-max", "qwen-plus", "qwen-flash", "qwen-turbo", "qwen3-coder-plus", "qwq-plus"],
            keyUrl: "https://bailian.console.aliyun.com/"
        ),
        doubao: ProviderMeta(
            provider: doubao, label: "豆包 Doubao", baseUrl: "https://ark.cn-beijing.volces.com/api/v3",
            defaultModel: "doubao-seed-1.6-251015",
            models: [
                "doubao-seed-1.6-251015", "doubao-seed-1.6-lite-251015", "doubao-seed-1-6-250615",
                "doubao-1.5-pro-32k-250115", "doubao-1.5-thinking-pro-250415",
            ],
            keyUrl: "https://console.volcengine.com/ark"
        ),
        zhipu: ProviderMeta(
            provider: zhipu, label: "智谱 按量付费", baseUrl: "https://open.bigmodel.cn/api/paas/v4",
            defaultModel: "glm-4.6",
            models: ["glm-5.2", "glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.6", "glm-4.5", "glm-4.5-air"],
            keyUrl: "https://open.bigmodel.cn/"
        ),
        zhipuCoding: ProviderMeta(
            provider: zhipuCoding, label: "智谱 Coding Plan", baseUrl: "https://open.bigmodel.cn/api/coding/paas/v4",
            defaultModel: "glm-4.7",
            models: ["glm-5.2", "glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.6", "glm-4.5"],
            keyUrl: "https://open.bigmodel.cn/"
        ),
        moonshot: ProviderMeta(
            provider: moonshot, label: "Kimi 月之暗面", baseUrl: "https://api.moonshot.cn/v1",
            defaultModel: "kimi-k2-0905-preview",
            models: ["kimi-k2-0905-preview", "kimi-k2-turbo-preview", "kimi-latest"],
            keyUrl: "https://platform.moonshot.cn/"
        ),
        openai: ProviderMeta(
            provider: openai, label: "OpenAI", baseUrl: "https://api.openai.com/v1",
            defaultModel: "gpt-4.1-mini",
            models: ["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "o3", "o3-mini", "o4-mini"],
            keyUrl: "https://platform.openai.com/api-keys"
        ),
        gemini: ProviderMeta(
            provider: gemini, label: "Gemini", baseUrl: "https://generativelanguage.googleapis.com/v1beta/openai",
            defaultModel: "gemini-2.5-flash",
            models: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash", "gemini-2.5-flash-lite"],
            keyUrl: "https://aistudio.google.com/apikey"
        ),
        custom: ProviderMeta(
            provider: custom, label: "自定义（OpenAI 兼容）", baseUrl: "",
            defaultModel: "", models: [], keyUrl: ""
        ),
    ]

    static let all: [String] = [
        deepseek, qwen, doubao, zhipu, zhipuCoding, moonshot, openai, gemini, custom,
    ]

    static let importAlias: [String: String] = ["chatgpt": openai, "kimi": moonshot]

    static let importUnsupported: [String] = ["claude"]

    static func metaOf(_ provider: String) -> ProviderMeta? { meta[provider] }
}

/// 思考模式档位 — 镜像 Android common/Providers.kt ReasoningEfforts。
enum ReasoningEfforts {
    static let ids: [String] = ["off", "high", "max"]

    static func label(_ id: String?) -> String {
        switch id {
        case "off": return "关闭思考"
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
