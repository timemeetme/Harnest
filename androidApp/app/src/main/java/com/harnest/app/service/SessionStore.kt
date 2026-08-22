package com.harnest.app.service

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Persisted chat message — tool rows carry trajectory fields. */
data class StoredMessage(
    val id: String,
    val role: String, // user | assistant | tool
    val content: String,
    val createdAt: Long,
    val provider: String? = null,
    val model: String? = null,
    val toolName: String? = null,
    val toolStatus: String? = null, // running | ok | error
    val toolResult: String? = null,
    val todosJson: String? = null,
    val durationMs: Long = 0,
    val traceJson: String? = null,
    val steered: Boolean = false, // k4：中途转向注入的消息（⚡ 标记）
    val rating: Int = 0, // k6：消息反馈 — 1=👍 -1=👎 0=未评（仅 assistant 有意义，本地持久）
) {
    fun toJson(): JSONObject {
        val o = JSONObject()
            .put("id", id).put("role", role).put("content", content).put("createdAt", createdAt)
        provider?.let { o.put("provider", it) }
        model?.let { o.put("model", it) }
        toolName?.let { o.put("toolName", it) }
        toolStatus?.let { o.put("toolStatus", it) }
        toolResult?.let { o.put("toolResult", it) }
        todosJson?.let { o.put("todosJson", it) }
        if (durationMs > 0) o.put("durationMs", durationMs)
        traceJson?.let { o.put("traceJson", it) }
        if (steered) o.put("steered", true)
        if (rating != 0) o.put("rating", rating)
        return o
    }

    companion object {
        fun fromJson(o: JSONObject): StoredMessage = StoredMessage(
            id = o.optString("id"),
            role = o.optString("role", "user"),
            content = o.optString("content", ""),
            createdAt = o.optLong("createdAt", System.currentTimeMillis()),
            provider = if (o.has("provider")) o.optString("provider") else null,
            model = if (o.has("model")) o.optString("model") else null,
            toolName = if (o.has("toolName")) o.optString("toolName") else null,
            toolStatus = if (o.has("toolStatus")) o.optString("toolStatus") else null,
            toolResult = if (o.has("toolResult")) o.optString("toolResult") else null,
            todosJson = if (o.has("todosJson")) o.optString("todosJson") else null,
            durationMs = o.optLong("durationMs", 0L),
            traceJson = if (o.has("traceJson")) o.optString("traceJson") else null,
            steered = o.optBoolean("steered", false),
            rating = o.optInt("rating", 0),
        )
    }
}

/** Persisted session — provider/model selection saved per conversation. */
data class SessionRecord(
    val id: String,
    var title: String,
    var provider: String,
    var model: String,
    /** 思考模式（off/high/max）；null = 服务端默认。与 provider/model 一起按会话记忆。 */
    var effort: String? = null,
    val createdAt: Long,
    var updatedAt: Long,
    val messages: MutableList<StoredMessage>,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("title", title)
        .put("provider", provider)
        .put("model", model)
        .apply { effort?.let { put("effort", it) } }
        .put("createdAt", createdAt)
        .put("updatedAt", updatedAt)
        .put("messages", JSONArray(messages.map { it.toJson() }))

    companion object {
        fun fromJson(o: JSONObject): SessionRecord {
            val messages = ArrayList<StoredMessage>()
            val arr = o.optJSONArray("messages")
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    arr.optJSONObject(i)?.let { messages.add(StoredMessage.fromJson(it)) }
                }
            }
            return SessionRecord(
                id = o.optString("id"),
                title = o.optString("title", "新会话"),
                provider = o.optString("provider", ""),
                model = o.optString("model", ""),
                effort = if (o.has("effort")) o.optString("effort") else null,
                createdAt = o.optLong("createdAt", System.currentTimeMillis()),
                updatedAt = o.optLong("updatedAt", System.currentTimeMillis()),
                messages = messages,
            )
        }
    }
}

private fun StoredMessage.toJson(): JSONObject {
    val o = JSONObject()
        .put("id", id).put("role", role).put("content", content).put("createdAt", createdAt)
    provider?.let { o.put("provider", it) }
    model?.let { o.put("model", it) }
    toolName?.let { o.put("toolName", it) }
    toolStatus?.let { o.put("toolStatus", it) }
    toolResult?.let { o.put("toolResult", it) }
    todosJson?.let { o.put("todosJson", it) }
    if (durationMs > 0) o.put("durationMs", durationMs)
    return o
}

private fun StoredMessage.Companion.fromJson(o: JSONObject): StoredMessage = StoredMessage(
    id = o.optString("id"),
    role = o.optString("role", "user"),
    content = o.optString("content", ""),
    createdAt = o.optLong("createdAt", System.currentTimeMillis()),
    provider = if (o.has("provider")) o.optString("provider") else null,
    model = if (o.has("model")) o.optString("model") else null,
    toolName = if (o.has("toolName")) o.optString("toolName") else null,
    toolStatus = if (o.has("toolStatus")) o.optString("toolStatus") else null,
    toolResult = if (o.has("toolResult")) o.optString("toolResult") else null,
    todosJson = if (o.has("todosJson")) o.optString("todosJson") else null,
    durationMs = o.optLong("durationMs", 0L),
)

/** Session persistence — sessions.json, mirrors harmonyApp SessionStore.ets. */
class SessionStore private constructor(private val context: Context) {

    companion object {
        private const val TAG = "SessionStore"
        private const val FILE = "sessions.json"

        @Volatile
        private var inst: SessionStore? = null

        fun get(context: Context): SessionStore =
            inst ?: synchronized(this) {
                inst ?: SessionStore(context.applicationContext).also { inst = it }
            }

        fun newId(): String =
            "session-" + System.currentTimeMillis() + "-" + Integer.toString((Math.random() * 1e9).toInt(), 36)

        fun titleFrom(text: String): String {
            val t = text.trim().replace(Regex("\\s+"), " ")
            return when {
                t.length > 24 -> t.substring(0, 24)
                t.isNotEmpty() -> t
                else -> "新会话"
            }
        }
    }

    private var cached: MutableList<SessionRecord>? = null

    // 会话内记忆持久层（k3b）：per-session .jsonl 事件日志。事件来自 QuickJS 求值线程的
    // 逐条镜像 — 单线程 executor 按到达序串行落盘（append-only），replay 时作为 seedJson。
    private val logExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "session-log-writer").apply { isDaemon = true }
    }

    private fun file(): File = File(context.filesDir, FILE)

    private fun logFile(sessionId: String): File =
        File(File(context.filesDir, "session-logs"), "$sessionId.jsonl")

    /** 内核 log 镜像事件路由（LocalEngine.onLogEvent 直投 — 后台线程，无 UI）。 */
    fun onKernelLogEvent(o: JSONObject) {
        val sessionId = o.optString("sessionId", "")
        if (sessionId.isEmpty()) return
        when (o.optString("type")) {
            "log" -> o.optJSONObject("event")?.let { appendLogEvent(sessionId, it) }
            "log-reset" -> o.optJSONArray("events")?.let { resetLogFile(sessionId, it) }
        }
    }

    /** 增量事件追加一行（envelope 全字段 — time/surfaceOp/sourceEventSeqs 为 seed 校验/压缩重放必填）。 */
    private fun appendLogEvent(sessionId: String, event: JSONObject) {
        logExecutor.execute {
            try {
                val f = logFile(sessionId)
                f.parentFile?.mkdirs()
                f.appendText(event.toString() + "\n")
            } catch (e: Throwable) {
                Log.e(TAG, "log append failed: ${e.message}")
            }
        }
    }

    /** 全量重写（createSession 时内核下行完整 log — 收敛到内核真相，顺带清掉崩溃残留的半写入行）。 */
    private fun resetLogFile(sessionId: String, events: JSONArray) {
        logExecutor.execute {
            try {
                val f = logFile(sessionId)
                f.parentFile?.mkdirs()
                val sb = StringBuilder()
                for (i in 0 until events.length()) {
                    events.optJSONObject(i)?.let { sb.append(it.toString()).append('\n') }
                }
                f.writeText(sb.toString())
            } catch (e: Throwable) {
                Log.e(TAG, "log reset failed: ${e.message}")
            }
        }
    }

    /** 读取事件日志 → createSession(seedJson)（内核解析平衡前缀后 replay 重建上下文）。 */
    fun readSeedJson(sessionId: String): String? = try {
        val f = logFile(sessionId)
        if (f.exists()) f.readText().trim().ifEmpty { null } else null
    } catch (e: Throwable) {
        Log.e(TAG, "log read failed: ${e.message}")
        null
    }

    /** k6 fork：截断事件日志到「第 n 个非转向用户回合」的 turn/end（含）。
     *  结构计数（turn/start +1 / turn/end -1），忽略嵌套 step；找不到目标回合返回 null。 */
    fun truncateLogAtUserTurn(sessionId: String, targetUserTurn: Int): String? {
        if (targetUserTurn <= 0) return null
        val f = logFile(sessionId)
        if (!f.exists()) return null
        return try {
            val sb = StringBuilder()
            var depth = 0
            var userTurns = 0
            var done = false
            for (line in f.readLines()) {
                if (done) break
                val t = line.trim()
                if (t.isEmpty()) continue
                val type = try {
                    JSONObject(t).optString("type")
                } catch (_: Throwable) {
                    continue // 崩溃残留半写入行 — 跳过
                }
                when (type) {
                    "turn/start" -> {
                        depth++
                        sb.append(t).append('\n')
                    }
                    "turn/end" -> {
                        sb.append(t).append('\n')
                        if (depth > 0) {
                            depth--
                            if (depth == 0) {
                                userTurns++
                                if (userTurns == targetUserTurn) done = true
                            }
                        }
                    }
                    else -> sb.append(t).append('\n')
                }
            }
            if (done) sb.toString().trim().ifEmpty { null } else null
        } catch (e: Throwable) {
            Log.e(TAG, "log truncate failed: ${e.message}")
            null
        }
    }

    /** k6 fork：整份复制事件日志到 fork 会话（fork 源消息在末尾 → 完整前缀）。 */
    fun copyLogTo(fromId: String, toId: String) {
        try {
            val src = logFile(fromId)
            if (src.exists()) {
                val dst = logFile(toId)
                dst.parentFile?.mkdirs()
                src.copyTo(dst, overwrite = true)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "log copy failed: ${e.message}")
        }
    }

    private fun deleteLogFile(sessionId: String) {
        try {
            logFile(sessionId).delete()
        } catch (_: Throwable) {
        }
    }

    @Synchronized
    fun loadAll(): MutableList<SessionRecord> {
        cached?.let { return it }
        val list = ArrayList<SessionRecord>()
        try {
            if (file().exists()) {
                val arr = JSONObject(file().readText()).optJSONArray("sessions")
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        arr.optJSONObject(i)?.let { list.add(SessionRecord.fromJson(it)) }
                    }
                }
            }
        } catch (e: Throwable) {
            Log.e(TAG, "sessions read failed", e)
        }
        cached = list
        return list
    }

    @Synchronized
    fun upsert(record: SessionRecord) {
        val list = loadAll()
        val idx = list.indexOfFirst { it.id == record.id }
        if (idx >= 0) list[idx] = record else list.add(0, record)
        saveAll(list)
    }

    @Synchronized
    fun delete(id: String) {
        val list = loadAll()
        list.removeAll { it.id == id }
        saveAll(list)
        deleteLogFile(id)
    }

    fun get(id: String): SessionRecord? = loadAll().firstOrNull { it.id == id }

    private fun saveAll(list: MutableList<SessionRecord>) {
        try {
            file().writeText(JSONObject().put("version", 1).put("sessions", JSONArray(list.map { it.toJson() })).toString())
        } catch (e: Throwable) {
            Log.e(TAG, "sessions save failed", e)
        }
    }
}
