package com.harnest.app.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

object HarnessConstants {
    const val APP_DIR = "HarnessApp"
    const val FILE_API_CONFIG = "llm_config.json"
    const val FILE_KERNEL_CONFIG = "kernel_config.json"
    const val FILE_PREFS = "preferences.json"
    const val CONFIG_TYPE = "harnest_llm_config"
}

@Serializable
enum class AiProvider(val value: String) {
    @SerialName("deepseek") DEEPSEEK("deepseek"),
    @SerialName("doubao") DOUBAO("doubao"),
    @SerialName("qwen") QWEN("qwen"),
    @SerialName("gemini") GEMINI("gemini"),
    @SerialName("openai") OPENAI("openai"),
    @SerialName("claude") CLAUDE("claude"),
    @SerialName("zhipu") ZHIPU("zhipu"),
    @SerialName("zhipu_coding") ZHIPU_CODING("zhipu_coding"),
    @SerialName("moonshot") MOONSHOT("moonshot");

    companion object {
        fun fromValue(v: String?): AiProvider =
            entries.firstOrNull { it.value == v } ?: DEEPSEEK
    }
}

@Serializable
enum class ApiProtocol(val value: String) {
    @SerialName("openai") OPENAI("openai"),
    @SerialName("anthropic") ANTHROPIC("anthropic"),
    @SerialName("gemini") GEMINI("gemini")
}

@Serializable
data class ProviderMeta(
    val provider: AiProvider,
    val label: String,
    val emoji: String,
    val protocol: ApiProtocol,
    val baseUrl: String,
    val defaultModel: String,
    val models: List<String>
)

val PROVIDER_META: Map<String, ProviderMeta> = mapOf(
    AiProvider.DEEPSEEK.value to ProviderMeta(
        provider = AiProvider.DEEPSEEK,
        label = "DeepSeek",
        emoji = "🧠",
        protocol = ApiProtocol.OPENAI,
        baseUrl = "https://api.deepseek.com/v1",
        defaultModel = "deepseek-chat",
        models = listOf(
            "deepseek-chat",
            "deepseek-reasoner",
            "deepseek-chat-latest",
            "deepseek-reasoner-latest",
        )
    ),
    AiProvider.DOUBAO.value to ProviderMeta(
        provider = AiProvider.DOUBAO,
        label = "豆包 Doubao",
        emoji = "🫘",
        protocol = ApiProtocol.OPENAI,
        baseUrl = "https://ark.cn-beijing.volces.com/api/v3",
        defaultModel = "doubao-seed-1.6-251015",
        models = listOf(
            "doubao-seed-1.6-251015",
            "doubao-seed-1.6-lite-251015",
            "doubao-1.5-pro-32k-250115",
            "doubao-pro-32k",
        )
    ),
    AiProvider.QWEN.value to ProviderMeta(
        provider = AiProvider.QWEN,
        label = "千问 Qwen",
        emoji = "🗯️",
        protocol = ApiProtocol.OPENAI,
        baseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1",
        defaultModel = "qwen-plus",
        models = listOf(
            "qwen-plus",
            "qwen-flash",
            "qwen-turbo",
            "qwen3-max",
            "qwen-long",
        )
    ),
    AiProvider.GEMINI.value to ProviderMeta(
        provider = AiProvider.GEMINI,
        label = "Gemini",
        emoji = "♊",
        protocol = ApiProtocol.GEMINI,
        baseUrl = "https://generativelanguage.googleapis.com/v1beta",
        defaultModel = "gemini-2.5-flash",
        models = listOf(
            "gemini-2.5-flash",
            "gemini-2.5-pro",
            "gemini-2.0-flash",
        )
    ),
    AiProvider.OPENAI.value to ProviderMeta(
        provider = AiProvider.OPENAI,
        label = "OpenAI",
        emoji = "🎲",
        protocol = ApiProtocol.OPENAI,
        baseUrl = "https://api.openai.com/v1",
        defaultModel = "gpt-4.1-mini",
        models = listOf(
            "gpt-4.1",
            "gpt-4.1-mini",
            "o3",
            "o3-mini",
        )
    ),
    AiProvider.CLAUDE.value to ProviderMeta(
        provider = AiProvider.CLAUDE,
        label = "Claude",
        emoji = "🪶",
        protocol = ApiProtocol.ANTHROPIC,
        baseUrl = "https://api.anthropic.com/v1",
        defaultModel = "claude-sonnet-4-5-20250929",
        models = listOf(
            "claude-sonnet-4-5-20250929",
            "claude-opus-4-1-20250805",
            "claude-haiku-4-5-20251001",
        )
    ),
    AiProvider.ZHIPU.value to ProviderMeta(
        provider = AiProvider.ZHIPU,
        label = "智谱 Zhipu",
        emoji = "📘",
        protocol = ApiProtocol.OPENAI,
        baseUrl = "https://open.bigmodel.cn/api/paas/v4",
        defaultModel = "glm-4.6",
        models = listOf(
            "glm-5",
            "glm-4.7",
            "glm-4.6",
            "glm-4.5",
        )
    ),
    AiProvider.ZHIPU_CODING.value to ProviderMeta(
        provider = AiProvider.ZHIPU_CODING,
        label = "智谱 Coding Plan",
        emoji = "📘",
        protocol = ApiProtocol.OPENAI,
        baseUrl = "https://open.bigmodel.cn/api/coding/paas/v4",
        defaultModel = "glm-4.7",
        models = listOf(
            "glm-5",
            "glm-4.7",
            "glm-4.6",
            "glm-4.5",
        )
    ),
    AiProvider.MOONSHOT.value to ProviderMeta(
        provider = AiProvider.MOONSHOT,
        label = "Kimi 月之暗面",
        emoji = "🌙",
        protocol = ApiProtocol.OPENAI,
        baseUrl = "https://api.moonshot.cn/v1",
        defaultModel = "kimi-k2-0905-preview",
        models = listOf(
            "kimi-k2-0905-preview",
            "kimi-k2-turbo-preview",
            "kimi-latest",
        )
    ),
)

val ALL_PROVIDERS: List<AiProvider> = listOf(
    AiProvider.DEEPSEEK,
    AiProvider.DOUBAO,
    AiProvider.QWEN,
    AiProvider.GEMINI,
    AiProvider.OPENAI,
    AiProvider.CLAUDE,
    AiProvider.ZHIPU,
    AiProvider.ZHIPU_CODING,
    AiProvider.MOONSHOT,
)

/**
 * 导入时的 provider 别名映射（外部应用导出标识 → 本项目标识）。
 * 与 HarmonyOS 端 Constants.ets 的 IMPORT_ALIAS 保持同步：
 * - chatgpt：EyeMouthMind 导出的 OpenAI 条目
 * - kimi：外部应用若以 kimi 标识月之暗面
 */
val IMPORT_ALIAS: Map<String, String> = mapOf(
    "chatgpt" to AiProvider.OPENAI.value,
    "kimi" to AiProvider.MOONSHOT.value,
)
