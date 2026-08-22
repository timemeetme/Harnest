package com.harnest.app.engine

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.whl.quickjs.wrapper.JSCallFunction
import com.whl.quickjs.wrapper.JSObject
import com.whl.quickjs.wrapper.QuickJSContext
import kotlinx.coroutines.CompletableDeferred
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Host callbacks — mirroring harness_engine.h (C++ / HarmonyOS version).
 */
interface HostListener {
    fun onLog(stream: String, chunk: String)
    fun onEvent(eventJson: String)
    fun onFetch(fetchId: Int, requestJson: String)
    fun onDevice(deviceId: Int, requestJson: String)
    fun onCallSettled(callId: Int, ok: Boolean, json: String)
}

data class CallEnvelope(
    val async: Boolean,
    val callId: Int = -1,
    val resultJson: String? = null,
    val error: String? = null,
)

/**
 * QuickJS engine wrapper — same protocol as harmonyApp cpp/harness_engine.{h,cpp}:
 *
 * Uplink (Java methods registered as JS globals before eval):
 *   __harnessFetchStart(requestJson) -> fetchId
 *   __harnessEmit(eventJson)
 *   __harnessFsCall(argsJson) -> resultJson   (sync, sandboxed)
 *   __harnessDeviceCall(requestJson) -> deviceId
 *
 * Downlink (evaluate JS globals from the host, each eval drains pending jobs):
 *   __harnessOnFetchHeaders(id, status, headersJson)
 *   __harnessOnFetchChunk(id, text)
 *   __harnessOnFetchDone(id)
 *   __harnessOnFetchFail(id, error)
 *   __harnessOnDeviceResult(id, ok, json)
 *
 * Engine factory: evaluate harness.js then createEngine() -> instance.
 * callFunc(): __harnessCall(funcName, jsonArgs) -> {sync,resultJson} | callId(async).
 */
class HarnessEngine(
    private val context: Context,
    private val listener: HostListener,
) {
    companion object {
        private const val TAG = "HarnessEngine"
    }

    private val jsThread = HandlerThread("quickjs").apply { start() }
    private val jsHandler = Handler(jsThread.looper)

    @Volatile
    private var quickJS: QuickJSContext? = null

    @Volatile
    var sandboxRoot: File = File(context.filesDir, "harness")
        private set

    private val nextFetchId = AtomicInteger(0)
    private val nextDeviceId = AtomicInteger(0)
    private val pendingCalls = ConcurrentHashMap<Int, CompletableDeferred<String>>()
    private val earlySettles = ConcurrentHashMap<Int, Pair<Boolean, String>>()
    private val nextCoroCallId = AtomicInteger(0)

    @Volatile
    private var ready = false

    fun isReady(): Boolean = ready

    // ── Lifecycle ────────────────────────────────────────────

    fun init(cwd: File) {
        sandboxRoot = cwd
        if (!cwd.exists()) cwd.mkdirs()
        val boot = jsHandler.runBlocking {
            try {
                doInit(cwd)
            } catch (e: Throwable) {
                Log.e(TAG, "init failed", e)
                listener.onLog("stderr", "[engine] init failed: ${e.message}")
                false
            }
        } ?: false
        ready = boot
    }

    private fun doInit(cwd: File): Boolean {
        com.whl.quickjs.android.QuickJSLoader.init()
        val qjs = QuickJSContext.create()
        quickJS = qjs
        val global = qjs.getGlobalObject()

        // 1. env globals (before eval — harness.js probes them)
        global.setProperty("__HARNESS_CWD", cwd.absolutePath)
        val envObj = qjs.createNewJSObject()
        global.setProperty("__HARNESS_ENV", envObj)

        // 2. host bridge functions (must exist BEFORE eval harness.js)
        global.setProperty("__harnessFetchStart", JSCallFunction { args ->
            val reqJson = args.getOrNull(0) as? String ?: ""
            val id = nextFetchId.incrementAndGet()
            jsHandler.post { listener.onFetch(id, reqJson) }
            id
        })

        global.setProperty("__harnessEmit", JSCallFunction { args ->
            val evt = args.getOrNull(0) as? String ?: "{}"
            listener.onEvent(evt)
            null
        })

        global.setProperty("__harnessFsCall", JSCallFunction { args ->
            val reqJson = args.getOrNull(0) as? String ?: "{}"
            FsBridge.handle(this, reqJson)
        })

        global.setProperty("__harnessDeviceCall", JSCallFunction { args ->
            val reqJson = args.getOrNull(0) as? String ?: "{}"
            val id = nextDeviceId.incrementAndGet()
            jsHandler.post { listener.onDevice(id, reqJson) }
            id
        })

        global.setProperty("__harnessStdout", JSCallFunction { args ->
            val chunk = args.getOrNull(0)?.toString() ?: ""
            listener.onLog("stdout", chunk)
            null
        })

        global.setProperty("__harnessStderr", JSCallFunction { args ->
            val chunk = args.getOrNull(0)?.toString() ?: ""
            listener.onLog("stderr", chunk)
            null
        })

        global.setProperty("__harnessProcessExit", JSCallFunction { _ ->
            listener.onLog("stderr", "[engine] process.exit called")
            null
        })

        global.setProperty("__harnessCallSettle", JSCallFunction { args ->
            val callId = (args.getOrNull(0) as? Number)?.toInt() ?: -1
            val ok = (args.getOrNull(1) as? Boolean) ?: false
            val json = args.getOrNull(2)?.toString() ?: "null"
            settleCall(callId, ok, json)
            null
        })

        // 3. evaluate harness.js (assets)
        val jsCode = context.assets.open("harness.js").bufferedReader().use { it.readText() }
        qjs.evaluate(jsCode, "<harness>")

        // 4. take over process.stdout/stderr/exit
        qjs.evaluate(
            """
            (function(){
              if (typeof process === 'object' && process) {
                if (process.stdout) process.stdout.write = function(c){ globalThis.__harnessStdout(String(c)); return true; };
                if (process.stderr) process.stderr.write = function(c){ globalThis.__harnessStderr(String(c)); return true; };
                process.exit = function(code){ globalThis.__harnessProcessExit(code|0); };
              }
            })();
            """.trimIndent()
        )

        // 5. createEngine() + async call driver
        val hasCreate = qjs.evaluate("(typeof createEngine === 'function')") as? Boolean ?: false
        if (!hasCreate) throw IllegalStateException("createEngine not found on globalThis after eval")
        qjs.evaluate(BOOTSTRAP_CALL)
        return true
    }

    /** Async-call driver JS: __harnessCall(name, jsonArgs) -> {sync,resultJson}|callId */
    private val BOOTSTRAP_CALL = """
        (function(){
          globalThis.__harnessEngineInstance = createEngine();
          globalThis.__harnessCallSeq = 0;
          globalThis.__harnessCall = function(funcName, jsonArgs) {
            var inst = globalThis.__harnessEngineInstance;
            if (!inst) return { sync: true, resultJson: JSON.stringify({ error: 'engine not initialized' }) };
            var fn = inst[funcName];
            if (typeof fn !== 'function') fn = globalThis[funcName];
            if (typeof fn !== 'function') return { sync: true, resultJson: JSON.stringify({ error: 'function not found: ' + funcName }) };
            var args = [];
            if (jsonArgs && jsonArgs.length > 0) args.push(JSON.parse(jsonArgs));
            var r;
            try { r = fn.apply(inst, args); }
            catch (e) { return { sync: true, resultJson: JSON.stringify({ error: String((e && e.message) || e) }) }; }
            if (r && typeof r.then === 'function') {
              var callId = ++globalThis.__harnessCallSeq;
              r.then(function(v){
                globalThis.__harnessCallSettle(callId, true, JSON.stringify(v === undefined ? null : v));
              }, function(e){
                globalThis.__harnessCallSettle(callId, false, String((e && e.message) || e));
              });
              return callId;
            }
            return { sync: true, resultJson: JSON.stringify(r === undefined ? null : r) };
          };
        })();
    """.trimIndent()

    // ── callFunc (sync or async envelope) ─────────────────────

    fun callFunc(funcName: String, jsonArgs: String?): CallEnvelope {
        if (!ready) return CallEnvelope(async = false, error = "engine not ready")
        val raw = jsHandler.runBlocking {
            try {
                val argsLiteral = jsonArgs?.let { jsStringLiteral(it) } ?: "''"
                quickJS?.evaluate("JSON.stringify(globalThis.__harnessCall('${funcName}', ${argsLiteral}))") as? String
                    ?: """{"async":false,"resultJson":"null"}"""
            } catch (e: Throwable) {
                """{"async":false,"error":${jsStringLiteral(e.message ?: "evaluate failed")}}"""
            }
        } ?: return CallEnvelope(async = false, error = "js thread unavailable")
        return parseEnvelope(raw)
    }

    /** Kotlin-suspend version of callFunc — resolves on settle (or sync immediately). */
    suspend fun callAwait(funcName: String, jsonArgs: String?): String {
        val envelope = callFunc(funcName, jsonArgs)
        envelope.error?.let { throw RuntimeException("$funcName: $it") }
        if (!envelope.async) {
            // resultJson is already the final JSON text of the JS-side return value
            // (may be an object, array, scalar or null) — never re-wrap with JSONObject().
            return envelope.resultJson ?: "null"
        }
        // Promise may settle INSIDE the callFunc evaluate (same-tick microtask drain),
        // before we could register the deferred — check the early-settle buffer first.
        earlySettles.remove(envelope.callId)?.let { (ok, json) ->
            if (ok) return json else throw RuntimeException("$funcName: $json")
        }
        val deferred = CompletableDeferred<String>()
        pendingCalls[envelope.callId] = deferred
        return deferred.await()
    }

    private fun settleCall(callId: Int, ok: Boolean, json: String) {
        val deferred = pendingCalls.remove(callId)
        if (deferred != null) {
            if (ok) deferred.complete(json) else deferred.completeExceptionally(RuntimeException(json))
            return
        }
        // No waiter yet — the callFunc evaluate has not returned to the caller. Buffer it.
        earlySettles[callId] = Pair(ok, json)
    }

    private fun parseEnvelope(raw: String): CallEnvelope {
        val trimmed = raw.trim()
        // async path: __harnessCall returned a bare callId number (JSON.stringify(5) == "5")
        trimmed.toIntOrNull()?.let { return CallEnvelope(async = true, callId = it) }
        return try {
            val obj = JSONObject(trimmed)
            when {
                obj.optBoolean("async", false) -> CallEnvelope(async = true, callId = obj.optInt("callId", -1))
                obj.has("resultJson") -> CallEnvelope(async = false, resultJson = obj.optString("resultJson"))
                else -> CallEnvelope(async = false, error = obj.optString("error", "unknown"))
            }
        } catch (e: Throwable) {
            CallEnvelope(async = false, error = "envelope parse failed: ${e.message}")
        }
    }

    // ── Downlink: fetch events / device results ───────────────

    fun fetchEvent(fetchId: Int, kind: String, a: String, b: String) {
        postJs {
            when (kind) {
                "headers" -> "__harnessOnFetchHeaders(${fetchId}, ${a.toIntOrNull() ?: 0}, ${jsStringLiteral(b)})"
                "chunk" -> "__harnessOnFetchChunk(${fetchId}, ${jsStringLiteral(a)})"
                "done" -> "__harnessOnFetchDone(${fetchId})"
                "fail" -> "__harnessOnFetchFail(${fetchId}, ${jsStringLiteral(a)})"
                else -> null
            }
        }
    }

    fun deviceResult(deviceId: Int, ok: Boolean, json: String) {
        postJs { "__harnessOnDeviceResult(${deviceId}, ${ok}, ${jsStringLiteral(json)})" }
    }

    private fun postJs(build: () -> String?) {
        val script = build() ?: return
        jsHandler.post {
            try {
                quickJS?.evaluate(script)
            } catch (e: Throwable) {
                Log.e(TAG, "downlink eval failed: ${e.message}")
                listener.onLog("stderr", "[engine] downlink eval failed: ${e.message}")
            }
        }
    }

    // ── utils ────────────────────────────────────────────────

    /** JSON-string-literal escaping (JSON string literals are valid JS literals). */
    private fun jsStringLiteral(s: String): String {
        val sb = StringBuilder("\"")
        for (c in s) {
            when {
                c == '"' -> sb.append("\\\"")
                c == '\\' -> sb.append("\\\\")
                c == '\n' -> sb.append("\\n")
                c == '\r' -> sb.append("\\r")
                c == '\t' -> sb.append("\\t")
                c == '\b' -> sb.append("\\b")
                c.code == 0x0C -> sb.append("\\f")
                c < ' ' -> sb.append("\\u%04x".format(c.code))
                c.code == 0x2028 -> sb.append("\\u2028")
                c.code == 0x2029 -> sb.append("\\u2029")
                else -> sb.append(c)
            }
        }
        sb.append("\"")
        return sb.toString()
    }

    private fun <T> Handler.runBlocking(block: () -> T): T? {
        if (looper.thread === Thread.currentThread()) return block()
        val latch = java.util.concurrent.CountDownLatch(1)
        var result: T? = null
        var error: Throwable? = null
        post {
            try { result = block() } catch (e: Throwable) { error = e } finally { latch.countDown() }
        }
        latch.await()
        error?.let { throw it }
        return result
    }

    fun dispose() {
        ready = false
        jsHandler.post {
            try { quickJS?.destroy() } catch (_: Throwable) {}
            quickJS = null
        }
        pendingCalls.forEach { (_, d) -> d.completeExceptionally(RuntimeException("engine disposed")) }
        pendingCalls.clear()
        jsThread.quitSafely()
    }
}
