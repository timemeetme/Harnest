package com.harnessapp.dsh.transport

import com.harnessapp.dsh.core.JsonRpcRequest
import com.harnessapp.dsh.core.JsonRpcResponse
import com.harnessapp.dsh.core.JsonRpcNotification
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.Json

/**
 * 传输层抽象。DSH SDK protocol 支持 stdio（换行分帧）和 HTTP/WebSocket。
 * 三端实现各自提供 Transport：
 *   - Android: OkHttp WebSocket
 *   - iOS: Ktor Darwin WebSocket
 *   - JVM (调试): OkHttp WebSocket
 */
interface DshTransport {
    val isConnected: Boolean

    suspend fun connect(endpoint: String)
    suspend fun disconnect()

    suspend fun sendRequest(frame: JsonRpcRequest)
    suspend fun sendNotification(frame: JsonRpcNotification)

    fun incoming(): Flow<IncomingFrame>
}

sealed interface IncomingFrame {
    data class Response(val frame: JsonRpcResponse) : IncomingFrame
    data class Notification(val frame: JsonRpcNotification) : IncomingFrame
    data class Error(val throwable: Throwable) : IncomingFrame
}

object DshTransportFactory {
    fun create(transportType: TransportType): DshTransport = when (transportType) {
        TransportType.WEBSOCKET -> WebSocketTransport()
    }
}

enum class TransportType { WEBSOCKET }

val dshJson = Json {
    isLenient = true
    ignoreUnknownKeys = true
    encodeDefaults = true
}
