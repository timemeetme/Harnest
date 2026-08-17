package com.harnest.app.dsh.transport

import io.ktor.client.*
import io.ktor.client.plugins.websocket.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.websocket.*
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.putJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

/**
 * deepseek-harness 双通道协议 Transport：
 *   上行 (client → host): HTTP POST /api/<method>     body = {type:"client-request", rpcId, method, payload}
 *   下行 (host → client): WebSocket /api/events.mux   推送 {type:"server-request"|"server-response", rpcId, method?, payload}
 */
@OptIn(ExperimentalUuidApi::class)
class OkHttpDshTransport(
    private val httpClient: HttpClient = defaultHttpClient(),
) : DshTransport {

    private var baseUrl: String = ""
    private var session: WebSocketSession? = null
    private val _pushFlow = MutableSharedFlow<PushFrame>(extraBufferCapacity = 256)
    private val pushFlow = _pushFlow.asSharedFlow()
    private var receiveJob: kotlinx.coroutines.Job? = null

    override val isConnected: Boolean get() = session != null

    override suspend fun connect(baseUrl: String) {
        this.baseUrl = baseUrl.trimEnd('/')
        val wsUrl = toWs(this.baseUrl) + "/api/events.mux"
        println("[OkHttpDshTransport] connect -> WS $wsUrl")
        session = httpClient.webSocketSession(wsUrl)
        println("[OkHttpDshTransport] WS connected: $session")
        if (receiveJob == null) {
            receiveJob = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default).launch {
                pumpWs()
            }
        }
    }

    override suspend fun disconnect() {
        receiveJob?.cancel()
        receiveJob = null
        runCatching { session?.close(CloseReason(CloseReason.Codes.NORMAL, "client disconnect")) }
        session = null
        baseUrl = ""
    }

    override suspend fun sendRpc(method: String, payload: Map<String, Any?>?): RpcResult {
        val url = "$baseUrl/api/$method"
        val rpcId = Uuid.random().toString()
        val jsonBody = buildJsonObject {
            put("type", "client-request")
            put("rpcId", rpcId)
            put("method", method)
            putJsonObject("payload") {
                (payload ?: emptyMap()).forEach { (k, v) -> putAny(k, v) }
            }
        }
        val bodyStr = dshJson.encodeToString(JsonObject.serializer(), jsonBody)
        println("[OkHttpDshTransport] HTTP POST $method -> $url body=$bodyStr")
        return runCatching {
            val resp: HttpResponse = httpClient.post(url) {
                header("Content-Type", "application/json")
                setBody(bodyStr)
            }
            val text = resp.bodyAsText()
            println("[OkHttpDshTransport] HTTP $method <- ${resp.status}: $text")
            parseServerResponse(text)
        }.getOrElse { err ->
            println("[OkHttpDshTransport] HTTP $method FAILED: ${err.message}")
            RpcResult(ok = false, errorCode = "transport", errorMessage = err.message ?: err.toString())
        }
    }

    private fun kotlinx.serialization.json.JsonObjectBuilder.putAny(key: String, value: Any?) {
        when (value) {
            null -> { /* 跳过 null，不传该 key */ }
            is String -> put(key, value)
            is Boolean -> put(key, value)
            is Number -> put(key, value.toDouble())
            is Map<*, *> -> putJsonObject(key) { value.forEach { (k, v) -> putAny(k.toString(), v) } }
            is List<*> -> putJsonArray(key) { value.forEach { add(anyToJsonElement(it)) } }
            else -> put(key, value.toString())
        }
    }

    private fun anyToJsonElement(value: Any?): JsonElement = when (value) {
        null -> JsonNull
        is String -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value.toDouble())
        is Map<*, *> -> buildJsonObject { value.forEach { (k, v) -> putAny(k.toString(), v) } }
        is List<*> -> JsonArray(value.map { anyToJsonElement(it) })
        else -> JsonPrimitive(value.toString())
    }

    override fun incoming(): Flow<PushFrame> = pushFlow

    private suspend fun pumpWs() {
        val s = session ?: return
        try {
            for (frame in s.incoming) {
                if (frame is Frame.Text) {
                    val text = frame.readText()
                    println("[OkHttpDshTransport] WS <- $text")
                    val push = parsePushFrame(text)
                    if (push != null) _pushFlow.emit(push)
                }
            }
        } catch (e: Exception) {
            println("[OkHttpDshTransport] WS pump error: ${e::class.simpleName}: ${e.message}")
            _pushFlow.emit(PushFrame.Error(e))
        }
    }

    private fun parseServerResponse(text: String): RpcResult {
        return try {
            val top: JsonObject = dshJson.parseToJsonElement(text).jsonObject
            val result = top["result"]?.jsonObject ?: return RpcResult(ok = false, errorCode = "no-result", errorMessage = "missing result field")
            val ok = result["ok"]?.jsonPrimitive?.contentOrNull?.toBoolean() ?: false
            if (ok) {
                val value = result["value"]?.takeIf { it !is JsonNull }?.let { jsonToAny(it) as? Map<*, *> }?.let { castStringKeyed(it) }
                RpcResult(ok = true, value = value)
            } else {
                val err = result["error"]?.jsonObject
                RpcResult(
                    ok = false,
                    errorCode = err?.get("code")?.jsonPrimitive?.contentOrNull,
                    errorMessage = err?.get("message")?.jsonPrimitive?.contentOrNull,
                )
            }
        } catch (e: Exception) {
            RpcResult(ok = false, errorCode = "parse", errorMessage = e.message)
        }
    }

    private fun parsePushFrame(text: String): PushFrame? {
        return try {
            val map: JsonObject = dshJson.parseToJsonElement(text).jsonObject
            val type = map["type"]?.jsonPrimitive?.contentOrNull
            when (type) {
                "server-request" -> {
                    val method = map["method"]?.jsonPrimitive?.contentOrNull ?: ""
                    val payload = map["payload"]?.let { jsonToAny(it) as? Map<*, *> }?.let { castStringKeyed(it) } ?: emptyMap()
                    PushFrame.Request(method, payload)
                }
                else -> null
            }
        } catch (e: Exception) {
            PushFrame.Error(e)
        }
    }

    private fun jsonToAny(element: JsonElement): Any? = when (element) {
        is JsonNull -> null
        is JsonPrimitive -> when {
            element.isString -> element.content
            element.content == "true" -> true
            element.content == "false" -> false
            else -> element.content.toDoubleOrNull() ?: element.content
        }
        is JsonObject -> element.entries.associate { (k, v) -> k to jsonToAny(v) }
        is JsonArray -> element.map { jsonToAny(it) }
    }

    @Suppress("UNCHECKED_CAST")
    private fun castStringKeyed(map: Map<*, *>): Map<String, Any?> = map as Map<String, Any?>

    private fun toWs(httpUrl: String): String {
        return if (httpUrl.startsWith("https://")) {
            "wss://${httpUrl.removePrefix("https://")}"
        } else if (httpUrl.startsWith("http://")) {
            "ws://${httpUrl.removePrefix("http://")}"
        } else {
            "ws://$httpUrl"
        }
    }
}

expect fun defaultHttpClient(): HttpClient
