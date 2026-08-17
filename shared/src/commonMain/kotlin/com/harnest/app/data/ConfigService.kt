package com.harnest.app.data

import com.harnest.app.core.ALL_PROVIDERS
import com.harnest.app.core.AiProvider
import com.harnest.app.core.HarnessConstants
import com.harnest.app.core.IMPORT_ALIAS
import com.harnest.app.core.PROVIDER_META
import com.harnest.app.model.LlmConfig
import com.harnest.app.model.ProviderConfig
import com.harnest.app.platform.nowMs
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

object ConfigService {
    private var config: LlmConfig? = null

    fun load(): LlmConfig {
        config?.let { return it }
        val read = StorageService.readJson<LlmConfig>(StorageService.pathApiConfig())
        if (read != null && read.configs.isNotEmpty()) {
            config = read
            return read
        }
        val configs = mutableMapOf<String, ProviderConfig>()
        for (p in ALL_PROVIDERS) {
            val meta = PROVIDER_META.getValue(p.value)
            configs[p.value] = ProviderConfig(
                provider = p,
                apiKey = "",
                model = meta.defaultModel,
                baseUrl = meta.baseUrl,
                enabled = false
            )
        }
        config = LlmConfig(
            activeProvider = AiProvider.DEEPSEEK,
            configs = configs
        )
        save()
        return config!!
    }

    fun save() {
        config?.let {
            StorageService.writeJson(StorageService.pathApiConfig(), it)
        }
    }

    fun get(): LlmConfig = load()

    fun getProviderConfig(provider: AiProvider): ProviderConfig {
        val c = load()
        val item = c.configs[provider.value]
        if (item != null) return item
        val meta = PROVIDER_META.getValue(provider.value)
        return ProviderConfig(
            provider = provider,
            apiKey = "",
            model = meta.defaultModel,
            baseUrl = meta.baseUrl,
            enabled = false
        )
    }

    fun setProviderConfig(cfg: ProviderConfig) {
        val c = load()
        val fixed = cfg.copy(enabled = cfg.apiKey.trim().isNotEmpty())
        config = c.copy(
            configs = c.configs.toMutableMap().also { it[cfg.provider.value] = fixed }
        )
        save()
    }

    fun setActiveProvider(provider: AiProvider) {
        config = load().copy(activeProvider = provider)
        save()
    }

    fun getActiveConfig(): ProviderConfig? {
        val c = load()
        val active = c.configs[c.activeProvider.value]
        if (active != null && active.apiKey.trim().isNotEmpty()) {
            return active
        }
        for (p in ALL_PROVIDERS) {
            val item = c.configs[p.value]
            if (item != null && item.apiKey.trim().isNotEmpty()) {
                return item
            }
        }
        return null
    }

    fun hasUsableConfig(): Boolean = getActiveConfig() != null

    fun exportConfigJson(): String {
        val c = load()
        val configs = mutableListOf<JsonObject>()
        for (p in ALL_PROVIDERS) {
            val item = c.configs[p.value] ?: continue
            if (item.apiKey.trim().isNotEmpty()) {
                configs.add(
                    buildJsonObject {
                        put("provider", item.provider.value)
                        put("apiKey", item.apiKey)
                        put("model", item.model)
                        put("baseUrl", item.baseUrl)
                    }
                )
            }
        }
        val data = buildJsonObject {
            put("version", 1)
            put("type", HarnessConstants.CONFIG_TYPE)
            put("exportTime", nowMs())
            put("configs", JsonArray(configs))
        }
        return data.toString()
    }

    fun resetAll() {
        config = null
        StorageService.writeText(StorageService.pathApiConfig(), "")
    }

    fun importConfigJson(jsonStr: String): Int {
        if (jsonStr.length > 1024 * 1024) {
            return -1
        }
        val parsed = try {
            StorageService.json.parseToJsonElement(jsonStr).jsonObject
        } catch (_: Exception) {
            return -1
        }
        val typeVal = parsed["type"]?.jsonPrimitive?.contentOrNull
        if (typeVal != HarnessConstants.CONFIG_TYPE) {
            return -1
        }
        val cfgArr = try {
            parsed["configs"]?.jsonArray
        } catch (_: Exception) {
            null
        } ?: return -1
        var c = load()
        var imported = 0
        for (raw in cfgArr) {
            val obj = try {
                raw.jsonObject
            } catch (_: Exception) {
                continue
            }
            val providerStr = obj["provider"]?.jsonPrimitive?.contentOrNull ?: continue
            val apiKeyStr = obj["apiKey"]?.jsonPrimitive?.contentOrNull ?: continue
            // 别名归一化（chatgpt→openai、kimi→moonshot），与 HarmonyOS 端一致
            val normalized = IMPORT_ALIAS[providerStr.lowercase()] ?: providerStr
            val provider = AiProvider.entries.firstOrNull { it.value == normalized } ?: continue
            val meta = PROVIDER_META[provider.value] ?: continue
            val apiKey = apiKeyStr.trim()
            if (apiKey.isEmpty() || apiKey.length > 500) {
                continue
            }
            val modelStr = obj["model"]?.jsonPrimitive?.contentOrNull
            val baseUrlStr = obj["baseUrl"]?.jsonPrimitive?.contentOrNull
            val cfg = ProviderConfig(
                provider = provider,
                apiKey = apiKey,
                model = if (!modelStr.isNullOrEmpty()) modelStr else meta.defaultModel,
                baseUrl = if (!baseUrlStr.isNullOrEmpty()) baseUrlStr else meta.baseUrl,
                enabled = true
            )
            val existing = c.configs[provider.value]
            if (existing != null && existing.apiKey == cfg.apiKey && existing.model == cfg.model) {
                continue
            }
            c = c.copy(
                configs = c.configs.toMutableMap().also { it[provider.value] = cfg }
            )
            imported++
        }
        if (imported > 0) {
            config = c
            save()
        }
        return imported
    }
}
