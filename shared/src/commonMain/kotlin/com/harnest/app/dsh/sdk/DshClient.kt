package com.harnest.app.dsh.sdk

import com.harnest.app.dsh.model.*
import com.harnest.app.dsh.transport.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/**
 * deepseek-harness 客户端。直接透传 method name 和 Map 为参数 —
 * 协议 payload shape 交给调用方和 deepseek-harness 自身类型对齐。
 *
 * 生命周期:
 *   connect(baseUrl)  →  建立 WebSocket 下行 + 准备 HTTP 上行
 *   session.list()    →  首次握手，验证内核可达
 *   prompt / cancel / ... → 业务调用
 */
class DshClient(
    private val transport: DshTransport = DshTransportFactory.create(),
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.Default + SupervisorJob()),
) {
    private val _notifications = MutableSharedFlow<DshNotification>(extraBufferCapacity = 512)
    val notifications: SharedFlow<DshNotification> = _notifications.asSharedFlow()

    private var receiverJob: Job? = null

    val isConnected: Boolean get() = transport.isConnected

    suspend fun connect(baseUrl: String) {
        transport.connect(baseUrl)
        receiverJob?.cancel()
        receiverJob = scope.launch { receiveLoop() }
    }

    suspend fun disconnect() {
        receiverJob?.cancel()
        receiverJob = null
        runCatching { transport.disconnect() }
    }

    suspend fun rpc(method: String, payload: Map<String, Any?>? = null): RpcResult =
        transport.sendRpc(method, payload)

    suspend fun sessionList(): List<SessionRow> {
        val result = rpc("session.list", emptyMap())
        if (!result.ok) throw IllegalStateException("session.list failed: ${result.errorMessage}")
        return parseSessionList(result.value)
    }

    suspend fun createSession(cwd: String): String {
        val result = rpc("session.create", mapOf("cwd" to cwd))
        if (!result.ok) throw IllegalStateException("session.create failed: ${result.errorMessage}")
        val id = result.value?.get("sessionId") as? String
            ?: (result.value?.get("id") as? String)
            ?: throw IllegalStateException("session.create missing sessionId")
        return id
    }

    suspend fun prompt(sessionId: String, content: String, cwd: String? = null): String {
        val result = rpc("session.prompt", buildMap {
            put("sessionId", sessionId)
            put("content", content)
            cwd?.let { put("cwd", it) }
        })
        if (!result.ok) throw IllegalStateException("session.prompt failed: ${result.errorMessage}")
        val messageId = result.value?.get("messageId") as? String ?: ""
        return messageId
    }

    fun subscribe(handler: suspend (DshNotification) -> Unit): Job =
        scope.launch { notifications.collect { handler(it) } }

    private suspend fun receiveLoop() {
        transport.incoming().collect { frame ->
            when (frame) {
                is PushFrame.Request -> {
                    val notif = parseNotification(frame.method, frame.payload)
                    _notifications.emit(notif)
                }
                is PushFrame.Error -> { /* TODO: reconnect logic */ }
            }
        }
    }

    private fun parseNotification(method: String, payload: Map<String, Any?>): DshNotification {
        return when {
            method == "session/event" || method == "session.created" || method.startsWith("session/") -> {
                DshNotification.SessionEvent(
                    sessionId = (payload["sessionId"] as? String) ?: "",
                    event = payload,
                )
            }
            method == "session/status" -> DshNotification.SessionStatus(
                sessionId = (payload["sessionId"] as? String) ?: "",
                status = AgentStatus.Running,
            )
            method == "subagent/started" -> DshNotification.SubagentStarted(
                parentSessionId = (payload["parentSessionId"] as? String) ?: "",
                childSessionId = (payload["childSessionId"] as? String) ?: "",
            )
            method == "subagent/finished" -> DshNotification.SubagentFinished(
                childSessionId = (payload["childSessionId"] as? String) ?: "",
                status = SdkRunStatus.Ok,
            )
            else -> DshNotification.Unknown(method, payload)
        }
    }

    private fun parseSessionList(value: Map<String, Any?>?): List<SessionRow> {
        val items = value?.get("items") as? List<*> ?: return emptyList()
        return items.mapNotNull { row ->
            val map = row as? Map<*, *> ?: return@mapNotNull null
            val id = (map["sessionId"] as? String) ?: return@mapNotNull null
            val projections = map["projections"] as? Map<*, *>
            val values = projections?.get("values") as? Map<*, *>
            val title = (values?.get("title") as? String) ?: ""
            SessionRow(
                id = id,
                title = title,
                updatedAt = (map["updatedAt"] as? Number)?.toLong() ?: 0L,
                running = (map["running"] as? Boolean) ?: false,
            )
        }
    }

    fun close() {
        receiverJob?.cancel()
        scope.cancel()
    }
}

data class SessionRow(
    val id: String,
    val title: String,
    val updatedAt: Long,
    val running: Boolean,
)
