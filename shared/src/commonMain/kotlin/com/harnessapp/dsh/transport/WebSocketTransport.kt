package com.harnessapp.dsh.transport

import com.harnessapp.dsh.core.JsonRpcRequest
import com.harnessapp.dsh.core.JsonRpcResponse
import com.harnessapp.dsh.core.JsonRpcNotification
import com.harnessapp.dsh.core.JsonRpcException
import io.ktor.client.*
import io.ktor.client.plugins.websocket.*
import io.ktor.websocket.*
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.jsonNull

class WebSocketTransport(
    private val client: HttpClient = defaultHttpClient(),
) : DshTransport {

    private var session: WebSocketSession? = null

    override val isConnected: Boolean get() = session != null

    override suspend fun connect(endpoint: String) {
        val url = if (endpoint.startsWith("ws://") || endpoint.startsWith("wss://")) {
            endpoint
        } else {
            "ws://$endpoint"
        }
        session = client.webSocketSession(url)
    }

    override suspend fun disconnect() {
        session?.close(CloseReason(CloseReason.Codes.NORMAL, "client disconnect"))
        session = null
    }

    override suspend fun sendRequest(frame: JsonRpcRequest) {
        session?.send(dshJson.encodeToString(JsonRpcRequest.serializer(), frame))
            ?: throw IllegalStateException("WebSocketTransport not connected")
    }

    override suspend fun sendNotification(frame: JsonRpcNotification) {
        session?.send(dshJson.encodeToString(JsonRpcNotification.serializer(), frame))
            ?: throw IllegalStateException("WebSocketTransport not connected")
    }

    override fun incoming(): Flow<IncomingFrame> = callbackFlow {
        val s = session ?: throw IllegalStateException("WebSocketTransport not connected")
        launch {
            try {
                for (frame in s.incoming) {
                    if (frame is Frame.Text) {
                        val text = frame.readText()
                        val incoming = parseFrame(text)
                        trySend(incoming)
                    }
                }
            } catch (e: Exception) {
                trySend(IncomingFrame.Error(e))
            }
        }
        awaitClose { }
    }

    private fun parseFrame(text: String): IncomingFrame {
        return try {
            val map: JsonObject = dshJson.parseToJsonElement(text).jsonObject
            val hasId = map.containsKey("id")
            val hasMethod = map.containsKey("method")
            when {
                hasId && !hasMethod -> parseResponse(map)
                hasMethod -> parseNotification(map)
                else -> IncomingFrame.Error(IllegalArgumentException("Unknown frame: $text"))
            }
        } catch (e: Exception) {
            IncomingFrame.Error(e)
        }
    }

    private fun parseResponse(map: JsonObject): IncomingFrame {
        val id = map["id"] as? JsonPrimitive
        val hasError = map["error"] != null && map["error"] !is JsonNull
        return if (hasError) {
            val errObj = map["error"]!!.jsonObject
            val code = errObj["code"]?.jsonPrimitive?.content?.toIntOrNull() ?: -32603
            val message = errObj["message"]?.jsonPrimitive?.content ?: "Unknown error"
            val data = errObj["data"]?.takeIf { it !is JsonNull }?.jsonObject
            IncomingFrame.Error(JsonRpcException(code, message, data))
        } else {
            IncomingFrame.Response(
                JsonRpcResponse(
                    jsonrpc = map["jsonrpc"]?.jsonPrimitive?.content ?: "2.0",
                    result = map["result"]?.takeIf { it !is JsonNull }?.jsonObject,
                    id = id,
                )
            )
        }
    }

    private fun parseNotification(map: JsonObject): IncomingFrame {
        return IncomingFrame.Notification(
            JsonRpcNotification(
                jsonrpc = map["jsonrpc"]?.jsonPrimitive?.content ?: "2.0",
                method = map["method"]!!.jsonPrimitive.content,
                params = map["params"]?.takeIf { it !is JsonNull }?.jsonObject,
            )
        )
    }
}

expect fun defaultHttpClient(): HttpClient
