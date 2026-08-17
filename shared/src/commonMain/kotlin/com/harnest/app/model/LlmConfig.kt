package com.harnest.app.model

import com.harnest.app.core.AiProvider
import kotlinx.serialization.Serializable

@Serializable
data class ProviderConfig(
    val provider: AiProvider,
    val apiKey: String,
    val model: String,
    val baseUrl: String,
    val enabled: Boolean = false
)

@Serializable
data class LlmConfig(
    val activeProvider: AiProvider = AiProvider.DEEPSEEK,
    val configs: Map<String, ProviderConfig> = emptyMap()
)

@Serializable
data class KernelConnection(
    val host: String = "localhost",
    val port: Int = 3080,
    val useTls: Boolean = false
)
