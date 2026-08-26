package com.harnest.app.common

/**
 * Provider presets — mirrors harmonyApp Constants.ets (PROVIDER_META / ALL_PROVIDERS).
 * Kernel uses the OpenAI-compatible protocol only.
 */
data class ProviderMeta(
    val provider: String,
    val label: String,
    val baseUrl: String,
    val defaultModel: String,
    val models: List<String>,
    val keyUrl: String,
)

object Providers {
    const val DEEPSEEK = "deepseek"
    const val QWEN = "qwen"
    const val DOUBAO = "doubao"
    const val ZHIPU = "zhipu"
    const val ZHIPU_CODING = "zhipu_coding"
    const val MOONSHOT = "moonshot"
    const val OPENAI = "openai"
    const val GEMINI = "gemini"
    const val CUSTOM = "custom"

    val META: LinkedHashMap<String, ProviderMeta> = linkedMapOf(
        DEEPSEEK to ProviderMeta(
            DEEPSEEK, "DeepSeek", "https://api.deepseek.com",
            "deepseek-v4-flash", listOf("deepseek-v4-flash", "deepseek-v4-pro"),
            "https://platform.deepseek.com/api_keys"
        ),
        QWEN to ProviderMeta(
            QWEN, "千问 Qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "qwen-plus",
            listOf("qwen3.8-max", "qwen3.7-plus", "qwen3.7-flash", "qwen-plus", "qwen-flash"),
            "https://bailian.console.aliyun.com/"
        ),
        DOUBAO to ProviderMeta(
            DOUBAO, "豆包 Doubao", "https://ark.cn-beijing.volces.com/api/v3",
            "doubao-seed-2.1-pro",
            listOf(
                "doubao-seed-2.1-pro", "doubao-seed-2.1-turbo", "doubao-seed-2.0-pro",
                "doubao-seed-2.0-lite", "doubao-seed-2.0-mini"
            ),
            "https://console.volcengine.com/ark"
        ),
        ZHIPU to ProviderMeta(
            ZHIPU, "智谱 按量付费", "https://open.bigmodel.cn/api/paas/v4",
            "glm-5.3",
            listOf("glm-5.3", "glm-5.2", "glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.6", "glm-4.5-air"),
            "https://open.bigmodel.cn/"
        ),
        ZHIPU_CODING to ProviderMeta(
            ZHIPU_CODING, "智谱 Coding Plan", "https://open.bigmodel.cn/api/coding/paas/v4",
            "glm-5.3",
            listOf("glm-5.3", "glm-5.2", "glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.6"),
            "https://open.bigmodel.cn/"
        ),
        MOONSHOT to ProviderMeta(
            MOONSHOT, "Kimi 月之暗面", "https://api.moonshot.cn/v1",
            "kimi-k3",
            listOf("kimi-k3", "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-k2.6"),
            "https://platform.kimi.com/"
        ),
        OPENAI to ProviderMeta(
            OPENAI, "OpenAI", "https://api.openai.com/v1",
            "gpt-5.6-luna",
            listOf("gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini"),
            "https://platform.openai.com/api-keys"
        ),
        GEMINI to ProviderMeta(
            GEMINI, "Gemini", "https://generativelanguage.googleapis.com/v1beta/openai",
            "gemini-3.7-flash",
            listOf("gemini-3.7-flash", "gemini-3.6-flash", "gemini-flash-latest", "gemini-pro-latest"),
            "https://aistudio.google.com/apikey"
        ),
        CUSTOM to ProviderMeta(CUSTOM, "自定义（OpenAI 兼容）", "", "", emptyList(), ""),
    )

    val ALL: List<String> = META.keys.toList()

    val IMPORT_ALIAS: Map<String, String> = mapOf("chatgpt" to OPENAI, "kimi" to MOONSHOT)

    val IMPORT_UNSUPPORTED: List<String> = listOf("claude")

    fun metaOf(provider: String): ProviderMeta? = META[provider]
}

/**
 * 思考模式（reasoning effort）— 与内核 llm-deepseek 适配器的合法档位对齐（off/high/max）。
 * null = 不发送 reasoningEffort，走 provider 服务端默认。
 */
object ReasoningEfforts {
    val IDS = listOf("off", "high", "max")

    fun label(id: String?): String = when (id) {
        "off" -> "关闭思考"
        "high" -> "思考"
        "max" -> "深度思考"
        else -> "默认"
    }

    fun isValid(id: String?): Boolean = id == null || IDS.contains(id)
}
