package com.harnest.app.service

import android.content.Context
import android.util.Log
import com.harnest.app.common.Providers
import com.harnest.app.common.ReasoningEfforts
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * AI provider config — mirrors harmonyApp ConfigService.ets (EMM-compatible).
 * Persisted at filesDir/api_config.json as {version, configs, lastProvider, lastModel}.
 */
class ConfigService private constructor(private val context: Context) {

    companion object {
        private const val TAG = "ConfigService"
        private const val FILE = "api_config.json"

        @Volatile
        private var inst: ConfigService? = null

        fun get(context: Context): ConfigService =
            inst ?: synchronized(this) {
                inst ?: ConfigService(context.applicationContext).also { inst = it }
            }
    }

    private var cached: JSONObject? = null

    private fun file(): File = File(context.filesDir, FILE)

    @Synchronized
    fun load(): JSONObject {
        cached?.let { return it }
        val read: JSONObject? = try {
            if (file().exists()) JSONObject(file().readText()) else null
        } catch (e: Throwable) {
            Log.e(TAG, "config read failed", e); null
        }
        if (read != null && read.has("configs")) {
            if (read.optString("presetMigration") != "2026-08b") {
                // 存量配置一次性升级：旧预设模型列表换为官方现役列表（定制过的补齐缺失项）
                migratePresets(read)
                read.put("presetMigration", "2026-08b")
                cached = read
                saveLocked(read)
                Log.i(TAG, "config migrated to 2026-08b presets")
                return read
            }
            cached = read
            return read
        }
        val configs = JSONObject()
        for (p in Providers.ALL) {
            val meta = Providers.metaOf(p)!!
            configs.put(p, JSONObject()
                .put("provider", p)
                .put("apiKey", "")
                .put("baseUrl", meta.baseUrl)
                .put("models", JSONArray(meta.models))
                .put("defaultModel", meta.defaultModel)
                .put("enabled", false))
        }
        val fresh = JSONObject()
            .put("version", 1)
            .put("configs", configs)
            .put("lastProvider", Providers.DEEPSEEK)
            .put("lastModel", Providers.metaOf(Providers.DEEPSEEK)!!.defaultModel)
        cached = fresh
        saveLocked(fresh)
        return fresh
    }

    @Synchronized
    fun save() {
        cached?.let { saveLocked(it) }
    }

    private fun saveLocked(cfg: JSONObject) {
        try {
            file().writeText(cfg.toString(2))
        } catch (e: Throwable) {
            Log.e(TAG, "config save failed", e)
        }
    }

    /**
     * 预设刷新迁移（2026-08）：官方模型 ID 大面积退役后，存量配置里
     * 全部落在旧预设内的模型列表整体替换为新预设；定制过的列表保留用户条目，
     * 仅把缺失的现役预设补入（保证 kimi-k3 等新 ID 始终可选）；
     * defaultModel/lastModel 若已退役一并纠正。
     */
    private fun migratePresets(cfg: JSONObject) {
        val configs = cfg.optJSONObject("configs") ?: return
        for (p in Providers.ALL) {
            val item = configs.optJSONObject(p) ?: continue
            val legacy = Providers.LEGACY_PRESET_MODELS[p] ?: continue
            val meta = Providers.metaOf(p) ?: continue
            val models = item.optJSONArray("models") ?: continue
            val list = (0 until models.length()).mapNotNull { models.optString(it) }
            if (list.all { legacy.contains(it) }) {
                item.put("models", JSONArray(meta.models))
            } else {
                val merged = JSONArray(list)
                for (m in meta.models) {
                    if (!list.contains(m)) merged.put(m)
                }
                item.put("models", merged)
            }
            if (legacy.contains(item.optString("defaultModel"))) {
                item.put("defaultModel", meta.defaultModel)
            }
        }
        val legacyLast = Providers.LEGACY_PRESET_MODELS[cfg.optString("lastProvider")]
        val metaLast = Providers.metaOf(cfg.optString("lastProvider"))
        if (legacyLast != null && metaLast != null && legacyLast.contains(cfg.optString("lastModel"))) {
            cfg.put("lastModel", metaLast.defaultModel)
        }
    }

    fun getConfig(provider: String): JSONObject {
        val c = load()
        c.optJSONObject("configs")?.optJSONObject(provider)?.let { return it }
        val meta = Providers.metaOf(provider)
        val models: List<String> = meta?.models ?: emptyList()
        return JSONObject()
            .put("provider", provider)
            .put("apiKey", "")
            .put("baseUrl", meta?.baseUrl ?: "")
            .put("models", JSONArray(models))
            .put("defaultModel", meta?.defaultModel ?: "")
            .put("enabled", false)
    }

    /** Save one provider entry; non-empty apiKey == enabled. */
    @Synchronized
    fun setConfig(
        provider: String,
        apiKey: String,
        baseUrl: String,
        models: List<String>,
        defaultModel: String,
        maxTokens: Int? = null,
    ) {
        val c = load()
        val trimmedKey = apiKey.trim()
        if (baseUrl.isBlank() && provider != Providers.CUSTOM) {
            // keep preset when caller passes blank
        }
        val entry = JSONObject()
            .put("provider", provider)
            .put("apiKey", trimmedKey)
            .put("baseUrl", baseUrl.ifBlank { Providers.metaOf(provider)?.baseUrl ?: "" })
            .put("models", JSONArray(models.ifEmpty { listOf(defaultModel) }))
            .put("defaultModel", defaultModel.ifBlank { models.firstOrNull() ?: "" })
            .put("enabled", trimmedKey.isNotEmpty())
        if (maxTokens != null && maxTokens > 0) {
            entry.put("maxTokens", maxTokens)
        }
        c.optJSONObject("configs")?.put(provider, entry) ?: c.put("configs", JSONObject().put(provider, entry))
        saveLocked(c)
    }

    @Synchronized
    fun setLastSelection(provider: String, model: String, effort: String? = null) {
        val c = load()
        c.put("lastProvider", provider).put("lastModel", model)
        if (effort != null) c.put("lastEffort", effort) else c.remove("lastEffort")
        saveLocked(c)
    }

    /** 最近一次发送所用的思考模式；null = 默认。 */
    fun getDefaultEffort(): String? {
        val v = load().optString("lastEffort", "")
        return if (ReasoningEfforts.isValid(v.ifEmpty { null })) v.ifEmpty { null } else null
    }

    fun hasUsableConfig(): Boolean = listUsableProviders().isNotEmpty()

    /** Provider entries with a non-empty apiKey. */
    fun listUsableProviders(): List<JSONObject> {
        val out = ArrayList<JSONObject>()
        val configs = load().optJSONObject("configs") ?: return out
        for (p in Providers.ALL) {
            val item = configs.optJSONObject(p) ?: continue
            if (item.optString("apiKey").trim().isNotEmpty()) out.add(item)
        }
        return out
    }

    /** Default pick: last selection if still enabled, else first usable. */
    fun getDefaultSelection(): Pair<String, String> {
        val c = load()
        val lastProvider = c.optString("lastProvider", "")
        if (lastProvider.isNotEmpty()) {
            val item = c.optJSONObject("configs")?.optJSONObject(lastProvider)
            if (item != null && item.optBoolean("enabled", false)) {
                val models = jsonStrings(item.optJSONArray("models"))
                val lastModel = c.optString("lastModel", "")
                val model = if (lastModel.isNotEmpty() && models.contains(lastModel)) lastModel
                else item.optString("defaultModel")
                return Pair(lastProvider, model)
            }
        }
        val usable = listUsableProviders()
        if (usable.isNotEmpty()) {
            return Pair(usable[0].optString("provider"), usable[0].optString("defaultModel"))
        }
        return Pair(Providers.DEEPSEEK, Providers.metaOf(Providers.DEEPSEEK)!!.defaultModel)
    }

    /** Kernel init payload: {cwd, providers[], defaultProvider, defaultModel} — null when unconfigured. */
    fun buildEngineConfig(cwd: String): JSONObject? {
        val usable = listUsableProviders()
        if (usable.isEmpty()) return null
        val def = getDefaultSelection()
        val profiles = JSONArray()
        for (item in usable) {
            val models = jsonStrings(item.optJSONArray("models"))
                .ifEmpty { listOf(item.optString("defaultModel")) }
            val modelInputs = JSONArray()
            for (m in models) modelInputs.put(JSONObject().put("id", m))
            val profile = JSONObject()
                .put("provider", item.optString("provider"))
                .put("baseUrl", item.optString("baseUrl"))
                .put("apiKey", item.optString("apiKey"))
                .put("models", modelInputs)
            val mt = item.optInt("maxTokens", 0)
            if (mt > 0) profile.put("maxTokens", mt)
            profiles.put(profile)
        }
        return JSONObject()
            .put("cwd", cwd)
            .put("providers", profiles)
            .put("defaultProvider", def.first)
            .put("defaultModel", def.second)
    }

    /** Import EMM/harness_model_config JSON (from clipboard or file). Returns imported count + skipped providers. */
    @Synchronized
    fun importConfigJson(jsonStr: String): Pair<Int, List<String>> {
        try {
            val parsed = JSONObject(jsonStr)
            val type = parsed.optString("type", "")
            if (type != "harness_model_config" && type != "emm_model_config") return Pair(0, emptyList())
            val arr = parsed.optJSONArray("configs") ?: return Pair(0, emptyList())
            val c = load()
            val configs = c.optJSONObject("configs") ?: JSONObject().also { c.put("configs", it) }
            var imported = 0
            val skipped = ArrayList<String>()
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val providerRaw = obj.optString("provider", "")
                val apiKey = obj.optString("apiKey", "").trim()
                if (providerRaw.isEmpty()) continue
                val provider = Providers.IMPORT_ALIAS[providerRaw] ?: providerRaw
                if (Providers.IMPORT_UNSUPPORTED.contains(provider)) {
                    if (!skipped.contains(provider)) skipped.add(provider)
                    continue
                }
                val meta = Providers.metaOf(provider) ?: continue
                if (apiKey.isEmpty() || apiKey.length > 500) continue
                var models = jsonStrings(obj.optJSONArray("models")).ifEmpty { meta.models }
                var defaultModel = obj.optString("defaultModel", obj.optString("model", ""))
                if (defaultModel.isEmpty()) defaultModel = meta.defaultModel
                if (!models.contains(defaultModel)) models = models + defaultModel
                var baseUrl = obj.optString("baseUrl", "")
                if (baseUrl.isEmpty()) baseUrl = meta.baseUrl
                if (provider == Providers.GEMINI && !baseUrl.contains("/openai")) baseUrl = meta.baseUrl
                val entry = JSONObject()
                    .put("provider", provider)
                    .put("apiKey", apiKey)
                    .put("baseUrl", baseUrl)
                    .put("models", JSONArray(models))
                    .put("defaultModel", defaultModel)
                    .put("enabled", true)
                val mt = obj.optInt("maxTokens", 0)
                if (mt > 0) entry.put("maxTokens", mt)
                val existing = configs.optJSONObject(provider)
                if (existing != null && existing.optString("apiKey") == apiKey
                    && existing.optString("defaultModel") == defaultModel) continue
                configs.put(provider, entry)
                imported++
            }
            if (imported > 0) saveLocked(c)
            return Pair(imported, skipped)
        } catch (e: Throwable) {
            Log.e(TAG, "import failed", e)
            return Pair(0, emptyList())
        }
    }

    /** Export EMM-compatible model config JSON (only providers with an apiKey). */
    @Synchronized
    fun exportConfigJson(): String {
        val c = load()
        val configs = JSONArray()
        for (p in Providers.ALL) {
            val item = c.optJSONObject("configs")?.optJSONObject(p) ?: continue
            val apiKey = item.optString("apiKey").trim()
            if (apiKey.isEmpty()) continue
            val exported = JSONObject()
                .put("provider", item.optString("provider", p))
                .put("apiKey", apiKey)
                .put("model", item.optString("defaultModel"))
                .put("baseUrl", item.optString("baseUrl"))
                .put("models", item.optJSONArray("models") ?: JSONArray())
                .put("defaultModel", item.optString("defaultModel"))
            val mt = item.optInt("maxTokens", 0)
            if (mt > 0) exported.put("maxTokens", mt)
            configs.put(exported)
        }
        return JSONObject()
            .put("version", 1)
            .put("type", "emm_model_config")
            .put("exportTime", System.currentTimeMillis())
            .put("configs", configs)
            .toString(2)
    }

    private fun jsonStrings(arr: JSONArray?): List<String> {
        if (arr == null) return emptyList()
        val out = ArrayList<String>(arr.length())
        for (i in 0 until arr.length()) {
            val s = arr.optString(i, "")
            if (s.isNotEmpty()) out.add(s)
        }
        return out
    }
}
