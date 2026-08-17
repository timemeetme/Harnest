package com.harnest.app.dsh.transport

import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.Json

/**
 * deepseek-harness 采用双通道协议：
 *   上行 (client → host): HTTP POST /api/<method>    body = ClientRequest JSON
 *   下行 (host → client): WebSocket /api/events.mux  推送 ServerRequest JSON 帧
 *
 * 本 Transport 把两者封装成一个接口：sendRequest 走 HTTP，incoming 走 WS。
 */
interface DshTransport {
    val isConnected: Boolean

    suspend fun connect(baseUrl: String)
    suspend fun disconnect()

    suspend fun sendRpc(method: String, payload: Map<String, Any?>?): RpcResult

    fun incoming(): Flow<PushFrame>
}

sealed interface PushFrame {
    data class Request(val method: String, val payload: Map<String, Any?>) : PushFrame
    data class Error(val throwable: Throwable) : PushFrame
}

data class RpcResult(
    val ok: Boolean,
    val value: Map<String, Any?>? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
)

object DshTransportFactory {
    fun create(): DshTransport = OkHttpDshTransport()
}

val dshJson = Json {
    isLenient = true
    ignoreUnknownKeys = true
    encodeDefaults = true
}
