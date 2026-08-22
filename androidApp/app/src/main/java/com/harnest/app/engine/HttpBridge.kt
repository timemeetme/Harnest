package com.harnest.app.engine

import android.util.Log
import okhttp3.Call
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * HTTP bridge — mirrors HttpBridge.ets: executes the fetch requested by the
 * QuickJS side (via onFetch), streaming headers/chunks back as fetch events.
 * Pending device_camera photos are attached to the next chat/completions
 * request as image_url parts (multimodal vision).
 */
class HttpBridge(private val emit: (fetchId: Int, kind: String, a: String, b: String) -> Unit) {

    companion object {
        private const val TAG = "HttpBridge"
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(300, TimeUnit.SECONDS)
        .build()

    private val active = mutableMapOf<Int, Call>()
    private val lock = Any()

    /** requestJson: {url, method, headers, body} */
    fun start(fetchId: Int, requestJson: String) {
        val req = try {
            JSONObject(requestJson)
        } catch (e: Throwable) {
            emit(fetchId, "fail", "bad fetch request json: ${e.message}", "")
            return
        }
        val url = req.optString("url", "")
        val method = req.optString("method", "GET").uppercase()
        val headers = req.optJSONObject("headers")
        val bodyStr = when {
            !req.has("body") || req.isNull("body") -> null
            else -> req.optString("body")
        }

        val vision = attachPendingImages(url, bodyStr)
        val effectiveUrl = vision?.first ?: url
        val effectiveBody = vision?.second ?: bodyStr
        val attachedImages = vision != null

        val call = client.newCall(buildRequest(effectiveUrl, method, headers, effectiveBody))
        synchronized(lock) { active[fetchId] = call }
        call.enqueue(object : okhttp3.Callback {
            override fun onFailure(call: Call, e: IOException) {
                synchronized(lock) { active.remove(fetchId) }
                Log.w(TAG, "fetch#$fetchId fail: ${e.message}")
                emit(fetchId, "fail", e.message ?: "network error", "")
            }

            override fun onResponse(call: Call, response: Response) {
                var resp = response
                if (attachedImages && resp.code in 400..499 && bodyStr != null) {
                    try {
                        Log.w(TAG, "fetch#$fetchId: vision request rejected (${resp.code}), retrying without images")
                        resp.close()
                        resp = client.newCall(buildRequest(url, method, headers, bodyStr)).execute()
                    } catch (e: Throwable) {
                        synchronized(lock) { active.remove(fetchId) }
                        emit(fetchId, "fail", "vision retry failed: ${e.message}", "")
                        return
                    }
                }
                try {
                    val headerJson = JSONObject()
                    for ((k, v) in resp.headers) {
                        if (!headerJson.has(k)) headerJson.put(k, v)
                    }
                    emit(fetchId, "headers", resp.code.toString(), headerJson.toString())
                    val utf8 = Utf8StreamDecoder()
                    resp.body?.byteStream()?.use { stream ->
                        val buffer = ByteArray(16 * 1024)
                        while (true) {
                            val n = stream.read(buffer)
                            if (n < 0) break
                            if (n > 0) {
                                val text = utf8.decode(buffer, n)
                                if (text.isNotEmpty()) emit(fetchId, "chunk", text, "")
                            }
                        }
                    }
                    val rest = utf8.flush()
                    if (rest.isNotEmpty()) emit(fetchId, "chunk", rest, "")
                    emit(fetchId, "done", "", "")
                } catch (e: Throwable) {
                    emit(fetchId, "fail", e.message ?: "read error", "")
                } finally {
                    synchronized(lock) { active.remove(fetchId) }
                    resp.close()
                }
            }
        })
    }

    private fun buildRequest(url: String, method: String, headers: JSONObject?, bodyStr: String?): Request {
        val builder = Request.Builder().url(url)
        headers?.keys()?.forEach { k -> builder.header(k, headers.optString(k, "")) }
        val mediaType = "application/json; charset=utf-8".toMediaType()
        when (method) {
            "GET" -> builder.get()
            "POST" -> builder.post((bodyStr ?: "").toRequestBody(mediaType))
            "PUT" -> builder.put((bodyStr ?: "").toRequestBody(mediaType))
            "DELETE" -> if (bodyStr != null) builder.delete(bodyStr.toRequestBody(mediaType)) else builder.delete()
            "PATCH" -> builder.patch((bodyStr ?: "").toRequestBody(mediaType))
            "HEAD" -> builder.head()
            else -> builder.method(method, bodyStr?.toRequestBody(mediaType))
        }
        return builder.build()
    }

    /**
     * Append pending camera photos to the next chat/completions request as a
     * user message with OpenAI-compatible image_url content parts. When the
     * configured provider is text-only (e.g. zhipu coding endpoint), reroute
     * the request to a vision-capable route. Returns (url, body) when images
     * were attached, or null to leave the request untouched.
     */
    private fun attachPendingImages(url: String, bodyStr: String?): Pair<String, String>? {
        if (bodyStr.isNullOrEmpty()) return null
        if (!url.contains("/chat/completions")) return null
        if (!VisionAttach.hasPending()) return null
        val body = try {
            JSONObject(bodyStr)
        } catch (e: Throwable) {
            return null
        }
        val messages = body.optJSONArray("messages") ?: return null
        val images = VisionAttach.drain()
        if (images.isEmpty()) return null
        for (i in 0 until messages.length()) {
            val m = messages.optJSONObject(i) ?: continue
            if (m.has("content") && m.isNull("content")) m.put("content", "")
        }
        val content = JSONArray().put(
            JSONObject().put("type", "text").put(
                "text",
                "[系统附图] 以下为用户刚通过 device_camera 拍摄的照片（按拍摄顺序）。请直接查看图片内容进行分析或回答，不要凭空猜测画面："
            )
        )
        for (img in images) {
            content.put(
                JSONObject().put("type", "image_url")
                    .put("image_url", JSONObject().put("url", img))
            )
        }
        messages.put(JSONObject().put("role", "user").put("content", content))
        body.put("messages", messages)
        var targetUrl = url
        if (url.contains("open.bigmodel.cn")) {
            if (url.contains("/api/coding/")) {
                targetUrl = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
                body.put("model", "glm-4.6v")
                Log.i(TAG, "vision route: coding endpoint is text-only, rerouting to glm-4.6v on standard endpoint")
            } else if (!body.optString("model").endsWith("v")) {
                body.put("model", "glm-4.6v")
                Log.i(TAG, "vision route: switching model to glm-4.6v")
            }
        }
        Log.i(TAG, "attaching ${images.size} photo(s) to chat request as image_url parts")
        return targetUrl to body.toString()
    }

    fun abortAll() {
        synchronized(lock) {
            active.values.forEach { it.cancel() }
            active.clear()
        }
    }
}
