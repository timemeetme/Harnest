package com.harnest.app.engine

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import com.whl.quickjs.wrapper.JSCallFunction
import com.whl.quickjs.wrapper.QuickJSContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * run_script 工具的 JS 沙箱宿主（独立于引擎线程的专用 QuickJS）：
 * - 每次运行全新 QuickJSContext（脚本间零共享），超时销毁后下次运行自动恢复
 * - 预置 runtime：log/console（64KB 环形 stdout）、fetch（OkHttp 异步桥）、readText/writeText、setTimeout/setInterval（宿主 postDelayed 驱动）
 * - 文件访问锁死在 filesDir/scripts 内（canonicalPath 校验，逃逸即报错）
 * - runSync：Promise 包裹用户代码，CountDownLatch 等待 settle 或超时（默认上限 120s）
 * 桥函数遵循 FsBridge 约定：不抛 Java 异常 — read/write 错误以 \u0000 前缀哨兵串带回 JS 侧转 throw。
 */
class ScriptSandbox private constructor(private val context: Context) {

    companion object {
        private const val TAG = "ScriptSandbox"
        private const val STDOUT_CAP = 64 * 1024
        private const val RESULT_CAP = 32 * 1024
        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()

        @Volatile
        private var instance: ScriptSandbox? = null

        fun get(context: Context): ScriptSandbox =
            instance ?: synchronized(this) {
                instance ?: ScriptSandbox(context.applicationContext).also { instance = it }
            }
    }

    private val jsThread = HandlerThread("script-sandbox").apply { start() }
    private val jsHandler = Handler(jsThread.looper)

    val sandboxRoot: File = File(context.filesDir, "scripts").apply { mkdirs() }

    /** 脚本沙箱根目录别名（DeviceBridge pick 落点用）。 */
    val scriptsRoot: File get() = sandboxRoot

    private val fetchClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(55, TimeUnit.SECONDS)
        .callTimeout(60, TimeUnit.SECONDS)
        .build()

    private val nextFetchId = AtomicInteger(0)
    private val runLock = Any()
    private val logLock = Any()
    private val logBuf = StringBuilder()
    private var logTruncated = false

    /** 沙箱脚本本轮写入的文件（相对路径），execute 返回时透传给内核。 */
    private val writtenFiles: MutableSet<String> = mutableSetOf()

    @Volatile
    private var qjs: QuickJSContext? = null

    @Volatile
    private var latch = CountDownLatch(1)

    @Volatile
    private var settleResult: String? = null

    @Volatile
    private var settleError: String? = null

    @Volatile
    private var evalError: String? = null

    // ── entry（阻塞调用方线程至上限，宿主须在 IO 上下文调用）──────────

    fun runSync(code: String, timeoutMs: Long): Map<String, Any?> = synchronized(runLock) {
        val startedAt = SystemClock.elapsedRealtime()
        synchronized(logLock) {
            logBuf.setLength(0)
            logTruncated = false
        }
        synchronized(writtenFiles) { writtenFiles.clear() }
        settleResult = null
        settleError = null
        evalError = null
        latch = CountDownLatch(1)
        jsHandler.post {
            try {
                prepareContext().evaluate(wrapCode(code))
            } catch (e: Throwable) {
                evalError = e.message ?: e.javaClass.simpleName
                latch.countDown()
            }
        }
        val settled = latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        val durationMs = SystemClock.elapsedRealtime() - startedAt
        val stdout = synchronized(logLock) { logBuf.toString() }
        val stdoutTruncated = synchronized(logLock) { logTruncated }
        if (!settled) {
            // 超时：脚本已失控，销毁 context（下次运行 prepareContext 重建）
            jsHandler.post {
                try {
                    qjs?.destroy()
                } catch (_: Throwable) {
                }
                qjs = null
            }
            return mapOf(
                "ok" to false,
                "timedOut" to true,
                "error" to "execution timed out after ${timeoutMs}ms",
                "stdout" to stdout,
                "stdoutTruncated" to stdoutTruncated,
                "result" to "",
                "durationMs" to durationMs,
                "files" to synchronized(writtenFiles) { writtenFiles.toList() },
            )
        }
        val err = evalError ?: settleError
        mapOf(
            "ok" to (err == null),
            "result" to (if (err == null) clip(settleResult ?: "null", RESULT_CAP) else ""),
            "stdout" to stdout,
            "stdoutTruncated" to stdoutTruncated,
            "error" to err,
            "timedOut" to false,
            "durationMs" to durationMs,
            "files" to synchronized(writtenFiles) { writtenFiles.toList() },
        )
    }

    // ── context 装配（沙箱线程内调用）──────────────────────────

    private fun prepareContext(): QuickJSContext {
        try {
            qjs?.destroy()
        } catch (_: Throwable) {
        }
        qjs = null
        com.whl.quickjs.android.QuickJSLoader.init()
        val ctx = QuickJSContext.create()
        qjs = ctx
        val global = ctx.getGlobalObject()
        global.setProperty("__sbLog", JSCallFunction { args ->
            addLog(args.getOrNull(0) as? String ?: "")
            null
        })
        global.setProperty("__sbFetch", JSCallFunction { args ->
            startFetch(args.getOrNull(0) as? String ?: "{}")
        })
        global.setProperty("__sbRead", JSCallFunction { args -> sbRead(args.getOrNull(0) as? String ?: "") })
        global.setProperty("__sbWrite", JSCallFunction { args ->
            sbWrite(args.getOrNull(0) as? String ?: "", args.getOrNull(1) as? String ?: "")
        })
        global.setProperty("__sbReadB64", JSCallFunction { args ->
            sbReadB64(args.getOrNull(0) as? String ?: "")
        })
        global.setProperty("__sbWriteB64", JSCallFunction { args ->
            sbWriteB64(args.getOrNull(0) as? String ?: "", args.getOrNull(1) as? String ?: "")
        })
        global.setProperty("__sbTimerStart", JSCallFunction { args ->
            val id = (args.getOrNull(0) as? Number)?.toInt() ?: 0
            val ms = (args.getOrNull(1) as? Number)?.toLong() ?: 0L
            startTimer(ctx, id, ms)
            null
        })
        global.setProperty("__sbSettle", JSCallFunction { args ->
            settleResult = args.getOrNull(0)?.toString() ?: "null"
            latch.countDown()
            null
        })
        global.setProperty("__sbSettleErr", JSCallFunction { args ->
            settleError = args.getOrNull(0)?.toString() ?: "script failed"
            latch.countDown()
            null
        })
        ctx.evaluate(RUNTIME_JS)
        loadPrelude(ctx)
        return ctx
    }

    /** 加载共享沙箱预置库（assets/prelude.js，OOXML/zip/base64 能力）。失败仅 log 不崩溃。 */
    private fun loadPrelude(ctx: QuickJSContext) {
        try {
            val js = context.assets.open("prelude.js").bufferedReader().readText()
            ctx.evaluate(js)
        } catch (e: Throwable) {
            Log.w(TAG, "prelude.js load failed: ${e.message}")
        }
    }

    /** 用户代码包裹模板：同步体抛错 / Promise reject 都收敛到 __sbSettleErr。 */
    private fun wrapCode(code: String): String = """
Promise.resolve().then(function(){
  return (function(){
${code}
  })();
}).then(function(v){
  try { globalThis.__sbSettle(JSON.stringify(v === undefined ? null : v)); }
  catch (e) { globalThis.__sbSettleErr('result not serializable: ' + String((e && e.message) || e)); }
}, function(e){
  globalThis.__sbSettleErr(String((e && e.message) || e));
});
""".trimIndent()

    /** 预置 runtime：__sb（pending fetch Map + logs）、log/console、fetch、readText/writeText。 */
    private val RUNTIME_JS = """
(function(){
  globalThis.__sb = { pending: new Map(), logs: [] };
  globalThis.log = function(){
    try {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) {
        var a = arguments[i];
        try { parts.push(typeof a === 'string' ? a : JSON.stringify(a)); }
        catch (e) { parts.push(String(a)); }
      }
      var line = parts.join(' ');
      globalThis.__sb.logs.push(line);
      globalThis.__sbLog(line);
    } catch (e) {}
  };
  globalThis.console = { log: globalThis.log, info: globalThis.log, warn: globalThis.log, error: globalThis.log, debug: globalThis.log };
  globalThis.__sbFetchDone = function(id, ok, status, body, err){
    var p = globalThis.__sb.pending.get(id);
    if (!p) return;
    globalThis.__sb.pending.delete(id);
    if (ok) p.resolve({ ok: true, status: status, text: body });
    else p.reject(new Error(err || 'fetch failed'));
  };
  globalThis.fetch = function(url, opts){
    opts = opts || {};
    return new Promise(function(resolve, reject){
      var id = globalThis.__sbFetch(JSON.stringify({ url: String(url), method: opts.method || 'GET', headers: opts.headers || {}, body: typeof opts.body === 'string' ? opts.body : null }));
      globalThis.__sb.pending.set(id, { resolve: resolve, reject: reject });
    });
  };
  globalThis.readText = function(rel){
    var r = globalThis.__sbRead(String(rel));
    if (r === null || r === undefined) throw new Error('readText failed');
    if (r.length > 0 && r.charCodeAt(0) === 0) throw new Error(r.slice(1));
    return r;
  };
  globalThis.writeText = function(rel, content){
    var r = globalThis.__sbWrite(String(rel), content === null || content === undefined ? '' : String(content));
    if (typeof r === 'string' && r.length > 0 && r.charCodeAt(0) === 0) throw new Error(r.slice(1));
    return true;
  };
})();
globalThis.__sb.timers = new Map(); globalThis.__sb.timerSeq = 1;
globalThis.setTimeout = function(fn, ms){ var a = [].slice.call(arguments, 2); var id = __sb.timerSeq++; __sb.timers.set(id, function(){ fn.apply(null, a); }); __sbTimerStart(id, Math.max(0, Number(ms) || 0)); return id; };
globalThis.clearTimeout = function(id){ __sb.timers.delete(id); };
globalThis.setInterval = function(fn, ms){ var a = [].slice.call(arguments, 2); var id = __sb.timerSeq++; var period = Math.max(0, Number(ms) || 0); var tick = function(){ __sb.timers.set(id, tick); __sbTimerStart(id, period); fn.apply(null, a); }; __sb.timers.set(id, tick); __sbTimerStart(id, period); return id; };
globalThis.clearInterval = globalThis.clearTimeout;
globalThis.__sbFireTimer = function(id){ var f = __sb.timers.get(id); if (!f) return; __sb.timers.delete(id); f(); };
""".trimIndent()

    // ── native 桥实现（不抛异常，错误经哨兵/settle 通道回传）──────

    private fun addLog(s: String) {
        synchronized(logLock) {
            val line = if (logBuf.isEmpty()) s else "\n" + s
            if (logBuf.length + line.length > STDOUT_CAP) {
                val keep = STDOUT_CAP - line.length
                if (keep > 0) logBuf.delete(0, logBuf.length - keep) else logBuf.setLength(0)
                logTruncated = true
            }
            logBuf.append(line)
        }
    }

    private fun startFetch(reqJson: String): Int {
        val id = nextFetchId.incrementAndGet()
        try {
            val req = JSONObject(reqJson)
            val method = req.optString("method", "GET").uppercase().ifEmpty { "GET" }
            val builder = Request.Builder().url(req.optString("url", ""))
            req.optJSONObject("headers")?.let { h ->
                for (k in h.keys()) builder.header(k, h.optString(k))
            }
            val body = req.optString("body", "").ifEmpty { null }
            val rb = if (body != null && method != "GET" && method != "HEAD") body.toRequestBody(JSON_MEDIA) else null
            builder.method(method, rb)
            fetchClient.newCall(builder.build()).enqueue(object : Callback {
                override fun onFailure(call: Call, e: java.io.IOException) {
                    completeFetch(id, false, 0, null, e.message ?: "network error")
                }

                override fun onResponse(call: Call, response: Response) {
                    response.use {
                        val text = try {
                            it.body?.string() ?: ""
                        } catch (e: Throwable) {
                            completeFetch(id, false, 0, null, "read body failed: ${e.message}")
                            return
                        }
                        completeFetch(id, true, it.code, text, null)
                    }
                }
            })
        } catch (e: Throwable) {
            completeFetch(id, false, 0, null, e.message ?: "invalid fetch request")
        }
        return id
    }

    private fun completeFetch(id: Int, ok: Boolean, status: Int, body: String?, err: String?) {
        jsHandler.post {
            val ctx = qjs ?: return@post
            try {
                ctx.evaluate(
                    if (ok) "__sbFetchDone($id, true, $status, ${jsStr(body ?: "")}, null)"
                    else "__sbFetchDone($id, false, 0, null, ${jsStr(err ?: "fetch failed")})"
                )
            } catch (e: Throwable) {
                Log.e(TAG, "fetch deliver failed: ${e.message}")
            }
        }
    }

    /** 定时器桥：延迟 ms 后回投 __sbFireTimer（注册时的 ctx 已销毁重建则静默跳过，防跨 run 误触发）。 */
    private fun startTimer(ctxAtReg: QuickJSContext, id: Int, ms: Long) {
        jsHandler.postDelayed({
            val ctx = qjs ?: return@postDelayed
            if (ctx !== ctxAtReg) return@postDelayed
            try {
                ctx.evaluate("__sbFireTimer($id)")
            } catch (e: Throwable) {
                Log.e(TAG, "timer deliver failed: ${e.message}")
            }
        }, ms)
    }

    /** 读写均限沙箱根内；返回 \u0000 前缀哨兵串 = 错误（JS 侧转 throw）。 */
    private fun resolveInSandbox(rel: String): File {
        val rootPath = sandboxRoot.canonicalPath + File.separator
        val f = File(sandboxRoot, rel).canonicalFile
        if (!f.path.startsWith(rootPath)) throw RuntimeException("path escapes sandbox: $rel")
        return f
    }

    private fun sbRead(rel: String): String = try {
        resolveInSandbox(rel).readText()
    } catch (e: Throwable) {
        "\u0000${e.message ?: e.javaClass.simpleName}"
    }

    private fun sbWrite(rel: String, content: String): String = try {
        val f = resolveInSandbox(rel)
        f.parentFile?.mkdirs()
        f.writeText(content)
        synchronized(writtenFiles) { writtenFiles.add(rel) }
        "ok"
    } catch (e: Throwable) {
        "\u0000${e.message ?: e.javaClass.simpleName}"
    }

    /** prelude 二进制读桥：返回 JSON 字符串 "{ok,dataBase64}" 或 "{ok:false,error}"。 */
    private fun sbReadB64(rel: String): String = try {
        val bytes = resolveInSandbox(rel).readBytes()
        "{\"ok\":true,\"dataBase64\":\"${Base64.encodeToString(bytes, Base64.NO_WRAP)}\"}"
    } catch (e: Throwable) {
        "{\"ok\":false,\"error\":\"${e.message ?: e.javaClass.simpleName}\"}"
    }

    /** prelude 二进制写桥：Base64 解码失败 / 越界 / IO 错误均回 JSON error；成功登记 writtenFiles。 */
    private fun sbWriteB64(rel: String, base64: String): String = try {
        val bytes = try {
            Base64.decode(base64, Base64.NO_WRAP)
        } catch (e: Throwable) {
            return "{\"ok\":false,\"error\":\"invalid base64\"}"
        }
        val f = resolveInSandbox(rel)
        f.parentFile?.mkdirs()
        f.writeBytes(bytes)
        synchronized(writtenFiles) { writtenFiles.add(rel) }
        "{\"ok\":true}"
    } catch (e: Throwable) {
        "{\"ok\":false,\"error\":\"${e.message ?: e.javaClass.simpleName}\"}"
    }

    // ── utils ────────────────────────────────────────────────

    private fun clip(s: String, cap: Int): String =
        if (s.length <= cap) s else s.substring(0, cap) + "…[truncated]"

    private fun jsStr(s: String): String {
        val sb = StringBuilder("\"")
        for (ch in s) {
            when {
                ch == '"' -> sb.append("\\\"")
                ch == '\\' -> sb.append("\\\\")
                ch == '\n' -> sb.append("\\n")
                ch == '\r' -> sb.append("\\r")
                ch == '\t' -> sb.append("\\t")
                ch == '\b' -> sb.append("\\b")
                ch.code == 0x0C -> sb.append("\\f")
                ch < ' ' -> sb.append("\\u%04x".format(ch.code))
                ch.code == 0x2028 -> sb.append("\\u2028")
                ch.code == 0x2029 -> sb.append("\\u2029")
                else -> sb.append(ch)
            }
        }
        sb.append("\"")
        return sb.toString()
    }
}
