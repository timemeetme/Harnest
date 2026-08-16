package com.harnessapp.dsh.sdk

import com.harnessapp.dsh.core.JsonRpcException
import com.harnessapp.dsh.core.JsonRpcRequest
import com.harnessapp.dsh.core.JsonRpcNotification
import com.harnessapp.dsh.core.JsonRpcResponse
import com.harnessapp.dsh.model.*
import com.harnessapp.dsh.transport.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

@OptIn(ExperimentalUuidApi::class)
class DshClient(
    private val transport: DshTransport = WebSocketTransport(),
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.Default + SupervisorJob()),
) {
    private val pendingRequests = mutableMapOf<String, CompletableDeferred<JsonObject>>()
    private val pendingLock = Mutex()
    private val _notifications = MutableSharedFlow<DshNotification>(extraBufferCapacity = 256)
    val notifications: SharedFlow<DshNotification> = _notifications.asSharedFlow()

    private var receiverJob: Job? = null
    private var started = false

    val isConnected: Boolean get() = transport.isConnected
    var serverInfo: ServerInfo? = null
        private set

    suspend fun connect(endpoint: String) {
        transport.connect(endpoint)
        if (!started) {
            started = true
            receiverJob = scope.launch { receiveLoop() }
        }
    }

    suspend fun disconnect() {
        receiverJob?.cancel()
        receiverJob = null
        transport.disconnect()
        pendingLock.withLock { pendingRequests.clear() }
        started = false
        serverInfo = null
    }

    suspend fun initialize(params: InitializeParams): InitializeResult {
        val element = dshJson.encodeToJsonElement(InitializeParams.serializer(), params)
        val result = request("initialize", element.jsonObject)
        val res = dshJson.decodeFromJsonElement(InitializeResult.serializer(), result)
        serverInfo = res.serverInfo
        return res
    }

    suspend fun prompt(params: SessionPromptParams): SessionPromptResult {
        val element = dshJson.encodeToJsonElement(SessionPromptParams.serializer(), params)
        val result = request("session/prompt", element.jsonObject)
        return dshJson.decodeFromJsonElement(SessionPromptResult.serializer(), result)
    }

    suspend fun shutdown() {
        request("shutdown", buildJsonObject {})
    }

    fun subscribe(handler: suspend (DshNotification) -> Unit): Job =
        scope.launch { notifications.collect { handler(it) } }

    private suspend fun receiveLoop() {
        transport.incoming().collect { frame ->
            when (frame) {
                is IncomingFrame.Response -> handleResponse(frame.frame)
                is IncomingFrame.Notification -> handleNotification(frame.frame)
                is IncomingFrame.Error -> { /* 日志或重新连接 */ }
            }
        }
    }

    private suspend fun handleResponse(frame: JsonRpcResponse) {
        val id = frame.id?.contentOrNull ?: return
        val pending = pendingLock.withLock { pendingRequests.remove(id) } ?: return
        if (frame.error != null) {
            pending.completeExceptionally(
                JsonRpcException(
                    code = frame.error.code,
                    message = frame.error.message,
                    data = frame.error.data,
                )
            )
        } else {
            pending.complete(frame.result ?: buildJsonObject {})
        }
    }

    private suspend fun handleNotification(frame: JsonRpcNotification) {
        val params = frame.params ?: buildJsonObject {}
        val notification = deserializeNotification(frame.method, params)
        _notifications.emit(notification)
    }

    private fun deserializeNotification(method: String, params: JsonObject): DshNotification = when (method) {
        "session.event" -> runCatching {
            DshNotification.SessionEvent(dshJson.decodeFromJsonElement(SessionEventNotification.serializer(), params))
        }.getOrDefault(DshNotification.Unknown(method, params))
        "session.status" -> runCatching {
            DshNotification.SessionStatus(dshJson.decodeFromJsonElement(SessionStatusNotification.serializer(), params))
        }.getOrDefault(DshNotification.Unknown(method, params))
        "subagent.started" -> runCatching {
            DshNotification.SubagentStarted(dshJson.decodeFromJsonElement(SubagentStartedNotification.serializer(), params))
        }.getOrDefault(DshNotification.Unknown(method, params))
        "subagent.finished" -> runCatching {
            DshNotification.SubagentFinished(dshJson.decodeFromJsonElement(SubagentFinishedNotification.serializer(), params))
        }.getOrDefault(DshNotification.Unknown(method, params))
        else -> DshNotification.Unknown(method, params)
    }

    private suspend fun request(method: String, params: JsonObject): JsonObject {
        val id = Uuid.random().toString()
        val deferred = CompletableDeferred<JsonObject>()
        pendingLock.withLock { pendingRequests[id] = deferred }
        try {
            transport.sendRequest(
                JsonRpcRequest(
                    jsonrpc = "2.0",
                    method = method,
                    params = params,
                    id = JsonPrimitive(id),
                )
            )
            return withTimeout(30_000) { deferred.await() }
        } catch (e: CancellationException) {
            pendingLock.withLock { pendingRequests.remove(id) }
            throw e
        } catch (e: Exception) {
            pendingLock.withLock { pendingRequests.remove(id) }
            throw e
        }
    }

    fun close() {
        receiverJob?.cancel()
        scope.cancel()
    }
}

private val JsonPrimitive.contentOrNull: String? get() = content
