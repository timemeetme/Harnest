package com.harnest.app.service

import android.content.Context
import android.util.Log
import com.harnest.app.device.DeviceBridge
import com.harnest.app.device.UiLauncher
import com.harnest.app.engine.HarnessEngine
import com.harnest.app.engine.HostListener
import com.harnest.app.engine.HttpBridge
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Local kernel engine — mirrors harmonyApp LocalEngine.ets.
 * Owns: HarnessEngine (QuickJS) + HttpBridge (OkHttp) + DeviceBridge (21 ops).
 * High-level API: init / createSession / chat / setModel / setProviderProfile / listProviders.
 */
class LocalEngine private constructor() {

    companion object {
        private const val TAG = "LocalEngine"

        @Volatile
        private var inst: LocalEngine? = null

        fun get(): LocalEngine = inst ?: synchronized(this) {
            inst ?: LocalEngine().also { inst = it }
        }
    }

    private var engine: HarnessEngine? = null
    private var http: HttpBridge? = null
    private var device: DeviceBridge? = null

    @Volatile
    private var currentLauncher: UiLauncher? = null

    @Volatile
    private var started = false

    /** Session id currently mounted in the kernel (kernel side this.agent — one at a time). */
    private var mountedSessionId: String? = null

    /** Sequence for device self-test dispatch calls. */
    private val testSeq = java.util.concurrent.atomic.AtomicInteger(900_000)

    /** Optional log tap for the UI debug panel. */
    @Volatile
    var onLogLine: ((String) -> Unit)? = null

    /** Optional busy-step tap for the UI (device tool the agent is currently running). */
    @Volatile
    var onBusyStep: ((String) -> Unit)? = null

    /** 实时回合事件（思考/工具/待办）转发给 UI，事件对象含 kind/thinking|tool|todos 载荷。 */
    @Volatile
    var onRoundEvent: ((org.json.JSONObject) -> Unit)? = null

    /** 会话标题事件（LLM 自动生成 / 本地 fallback / 用户重命名）→ UI 更新侧栏。 */
    @Volatile
    var onTitleEvent: ((org.json.JSONObject) -> Unit)? = null

    /** 会话日志镜像事件（log 增量 / log-reset 全量）→ 宿主 .jsonl 持久层。
     *  回调线程为 QuickJS 求值线程 — 宿主应直接投递到后台写队列，勿做 UI/文件 IO。 */
    @Volatile
    var onLogEvent: ((org.json.JSONObject) -> Unit)? = null

    /** k5 agent 提问 / Plan 审批事件（type=question，kind=asked/answered/cancelled）→ UI 提问卡。
     *  asked 载荷 questions[]：id/question/detail?/options[]/multiSelect?/intent{plan-review,approve}。 */
    @Volatile
    var onQuestionEvent: ((org.json.JSONObject) -> Unit)? = null

    /** k7e 后台任务快照事件：{sessionId, jobs:[JobView]} — 覆盖式镜像当前可见集。 */
    var onJobsEvent: ((org.json.JSONObject) -> Unit)? = null

    fun isReady(): Boolean = started && engine?.isReady() == true

    /** Activity attaches its UiLauncher (pickers / runtime permissions) — survives activity recreation. */
    fun attachLauncher(launcher: UiLauncher) {
        currentLauncher = launcher
    }

    private fun launcherOrNull(): UiLauncher = currentLauncher
        ?: NoopLauncher

    private object NoopLauncher : UiLauncher {
        override fun runOnUi(block: () -> Unit) {}
        override fun hasPermission(perm: String): Boolean = false
        override suspend fun requestPermission(perm: String): Boolean = false
        override suspend fun takePicture(): String? = null
        override suspend fun pickImage(): String? = null
        override suspend fun pickDocument(mime: String?): String? = null
        override suspend fun pickSaveLocation(name: String): String? = null
        override fun cancelPending() {}
    }

    /** Launcher that always delegates to the latest attached activity launcher. */
    private inner class DelegatingLauncher : UiLauncher {
        override fun runOnUi(block: () -> Unit) = launcherOrNull().runOnUi(block)
        override fun hasPermission(perm: String) = launcherOrNull().hasPermission(perm)
        override suspend fun requestPermission(perm: String) = launcherOrNull().requestPermission(perm)
        override suspend fun takePicture() = launcherOrNull().takePicture()
        override suspend fun pickImage() = launcherOrNull().pickImage()
        override suspend fun pickDocument(mime: String?) = launcherOrNull().pickDocument(mime)
        override suspend fun pickSaveLocation(name: String) = launcherOrNull().pickSaveLocation(name)
        override fun cancelPending() = launcherOrNull().cancelPending()
    }

    private val startMutex = Mutex()

    /**
     * Start the engine (idempotent, concurrency-safe).
     * Throws when no provider is configured — UI should guide to settings.
     */
    suspend fun ensureStarted(context: Context) {
        if (isReady()) return
        startMutex.withLock {
            if (isReady()) return@withLock
            val appContext = context.applicationContext
            val harnessDir = File(appContext.filesDir, "harness")
            val engineConfig = ConfigService.get(appContext).buildEngineConfig(harnessDir.absolutePath)
                ?: throw IllegalStateException("未配置任何大模型 API — 请在设置中添加")

            val eng = HarnessEngine(appContext, hostListener())
            withContext(Dispatchers.Default) {
                eng.init(harnessDir)
            }
            if (!eng.isReady()) throw IllegalStateException("引擎初始化失败（harness.js 加载异常）")

            val httpBridge = HttpBridge { fetchId, kind, a, b -> eng.fetchEvent(fetchId, kind, a, b) }
            val deviceBridge = DeviceBridge(appContext, DelegatingLauncher(), eng)
            deviceBridge.onToolStart = { tool -> onBusyStep?.invoke("工具 $tool …") }

            engine = eng
            http = httpBridge
            device = deviceBridge

            eng.callAwait("init", engineConfig.toString())
            started = true
            Log.i(TAG, "local engine started")
        }
    }

    private fun hostListener() = object : HostListener {
        override fun onLog(stream: String, chunk: String) {
            Log.d("Harness/$stream", chunk)
            onLogLine?.invoke("[$stream] $chunk")
        }

        override fun onEvent(eventJson: String) {
            Log.d("Harness/event", eventJson)
            onLogLine?.invoke("[event] $eventJson")
            try {
                val o = org.json.JSONObject(eventJson)
                when (o.optString("type")) {
                    "round" -> onRoundEvent?.invoke(o)
                    "title" -> onTitleEvent?.invoke(o)
                    // k3b 会话内记忆镜像：log（增量事件）/ log-reset（createSession 全量下行）
                    "log", "log-reset" -> onLogEvent?.invoke(o)
                    // k5 交互控制：agent 提问下发（asked）/ 已答（answered）/ 作废（cancelled）
                    "question" -> onQuestionEvent?.invoke(o)
                    // k7e 后台任务：JobRegistry 可见集全量快照（list 覆盖式镜像，kill/onJobsChanged 触发）
                    "jobs" -> onJobsEvent?.invoke(o)
                }
            } catch (_: Throwable) {
            }
        }

        override fun onFetch(fetchId: Int, requestJson: String) {
            http?.start(fetchId, requestJson)
                ?: engFail(fetchId, "http bridge not ready")
        }

        override fun onDevice(deviceId: Int, requestJson: String) {
            val dev = device
            val eng = engine
            if (dev == null || eng == null) {
                engFail(deviceId, "device bridge not ready")
                return
            }
            dev.dispatch(deviceId, requestJson) { ok, json ->
                eng.deviceResult(deviceId, ok, json)
            }
        }

        override fun onCallSettled(callId: Int, ok: Boolean, json: String) {
            // settle flows through __harnessCallSettle directly (see HarnessEngine)
        }

        private fun engFail(id: Int, msg: String) {
            engine?.fetchEvent(id, "fail", msg, "")
            engine?.deviceResult(id, false, JSONObject().put("error", msg).toString())
        }
    }

    /** Hot-reload provider profiles after settings save (no engine restart). */
    fun refreshProfiles(context: Context) {
        if (!isReady()) return
        val usable = ConfigService.get(context).listUsableProviders()
        for (item in usable) {
            val models = mutableListOf<String>()
            val arr = item.optJSONArray("models")
            if (arr != null) for (i in 0 until arr.length()) arr.optString(i, "").takeIf { it.isNotEmpty() }?.let { models.add(it) }
            if (models.isEmpty()) models.add(item.optString("defaultModel"))
            setProviderProfile(
                item.optString("provider"), item.optString("baseUrl"),
                item.optString("apiKey"), models
            )
        }
    }

    /** Provider catalog for the model picker. */
    fun listProviders(): JSONArray {
        if (!isReady()) return JSONArray()
        val envelope = engine?.callFunc("listProviders", null) ?: return JSONArray()
        envelope.resultJson?.let {
            return try {
                JSONArray(it) ?: JSONArray()
            } catch (e: Throwable) {
                Log.e(TAG, "listProviders parse failed: ${e.message}")
                JSONArray()
            }
        }
        return JSONArray()
    }

    /** Tier B：当前会话 token 用量（输入框上方水位条）。同步 callFunc，非阻塞内核读取；
     *  内核未就绪 / entry 未暴露该接口 / 解析失败一律返回 null（UI 隐藏水位条）。 */
    fun usageStats(): Map<String, Any?>? {
        if (!isReady()) return null
        return try {
            val envelope = engine?.callFunc("getUsageStats", "{}") ?: return null
            val json = envelope.resultJson ?: return null
            val o = JSONObject(json)
            if (!o.optBoolean("ok", false)) null else buildMap {
                put("sessionId", o.optString("sessionId", ""))
                put("totalTokens", o.optLong("totalTokens", 0L))
                put("surfaceTokens", o.optLong("surfaceTokens", 0L))
                put("surfaceDeltaTokens", o.optLong("surfaceDeltaTokens", 0L))
                put("baseline", o.optString("baseline", "none"))
                put("contextWindow", o.optLong("contextWindow", 0L))
                put("usageRatio", o.optDouble("usageRatio", 0.0).toFloat())
            }
        } catch (e: Throwable) {
            Log.e(TAG, "usageStats failed: ${e.message}")
            null
        }
    }

    /** Mount a session into the kernel: applies the session's model selection first.
     *  seedJson：会话 .jsonl 事件日志（k3b 会话内记忆）— 内核解析为平衡前缀 seed 后
     *  replay 重建上下文；null = 全新会话。已挂载同一会话时跳过（内核态即完整真相）。 */
    suspend fun mountSession(record: SessionRecord, seedJson: String? = null) {
        if (!isReady()) throw IllegalStateException("engine not started")
        setModel(record.provider, record.model, record.effort)
        if (mountedSessionId == record.id) return
        val args = JSONObject().put("sessionId", record.id)
        if (!seedJson.isNullOrBlank()) args.put("seedJson", seedJson)
        engine?.callAwait("createSession", args.toString())
        mountedSessionId = record.id
    }

    /** Send a message on the mounted session — returns ChatOutcome JSON. */
    suspend fun chat(text: String): JSONObject {
        if (!isReady()) throw IllegalStateException("engine not started")
        val raw = engine!!.callAwait("chat", JSONObject().put("text", text).toString())
        return JSONObject(raw)
    }

    /** 中途转向（k4）：回合运行中把转向消息注入当前回合下一 step 边界，不打断在途
     *  LLM 请求；idle 时内核降级为普通 chat。返回 {ok,steered} 或降级 ChatOutcome。 */
    suspend fun steer(text: String): JSONObject {
        if (!isReady()) throw IllegalStateException("engine not started")
        val raw = engine!!.callAwait("steer", JSONObject().put("text", text).toString())
        return JSONObject(raw)
    }

    /** 手动压缩当前会话上下文（k3，回合间调用）。
     *  成功 {ok, noop?, summary?, shadowedCount, shadowedTokens}；失败 {ok:false, error, code?}。 */
    suspend fun compactNow(): JSONObject {
        if (!isReady()) throw IllegalStateException("engine not started")
        val raw = engine!!.callAwait("compactNow", JSONObject().toString())
        return JSONObject(raw)
    }

    /** 回答 agent 提问（k5）：answersJson 为 [{id, selected[], custom?}]。内核校验
     *  （数量 == questions、id 逐一匹配、selected ⊆ 选项 label、单选 ≤1、custom 与
     *  selected 互斥）通过后 resolve 挂起的 provider ask()，答案作为 tool result 回给
     *  模型；失败 {ok:false,error}，问题继续挂起（UI 保留卡片待修正）。 */
    suspend fun answerQuestion(qid: Int, answersJson: String): JSONObject {
        if (!isReady()) throw IllegalStateException("engine not started")
        val raw = engine!!.callAwait(
            "answerQuestion",
            JSONObject().put("qid", qid).put("answers", JSONArray(answersJson)).toString(),
        )
        return JSONObject(raw)
    }

    /** 开关 Plan 模式（k5）：回合外立即生效（committed），回合内挂起到下一 pre-step
     *  （queued）；返回 {ok, result, active}。active 亦随每回合 details.planActive 折叠下行。 */
    suspend fun setPlanMode(active: Boolean): JSONObject {
        if (!isReady()) throw IllegalStateException("engine not started")
        val raw = engine!!.callAwait("setPlanMode", JSONObject().put("active", active).toString())
        return JSONObject(raw)
    }

    /** k7e：列出当前会话可见的后台任务（后台 bash / 子代理等）。返回 {ok, jobs:[JobView]}。 */
    suspend fun listJobs(): JSONObject {
        if (!isReady()) throw IllegalStateException("engine not started")
        val raw = engine!!.callAwait("listJobs", JSONObject().toString())
        return JSONObject(raw)
    }

    /** k7e：请求终止一个后台任务（bash 终止）。返回 {ok, result:requested/already-finished} 或 {ok:false,error}。 */
    suspend fun killJob(id: String): JSONObject {
        if (!isReady()) throw IllegalStateException("engine not started")
        val raw = engine!!.callAwait("killJob", JSONObject().put("id", id).toString())
        return JSONObject(raw)
    }

    /**
     * 中断当前回合（UI 停止按钮 / 看门狗超时调用）：
     * L3 内核取消 — abortActive() 触发 agent.cancel，正在运行的回合立即中止；
     * L2 传输断流 — abortAll() 取消所有在途 OkHttp 调用，防止取消后继续重试请求。
     */
    fun abortActiveRound() {
        if (!isReady()) return
        try {
            engine?.callFunc("abortActive", null)
        } catch (e: Throwable) {
            Log.w(TAG, "abortActive failed: ${e.message}")
        }
        try {
            http?.abortAll()
        } catch (_: Throwable) {
        }
    }

    /** Switch model (and optional reasoning effort) for the next message. */
    fun setModel(provider: String, model: String, effort: String? = null) {
        if (!isReady()) return
        val args = JSONObject().put("provider", provider).put("model", model)
        if (!effort.isNullOrBlank()) args.put("reasoningEffort", effort)
        engine?.callFunc("setModel", args.toString())
    }

    fun setProviderProfile(provider: String, baseUrl: String, apiKey: String, models: List<String>) {
        if (!isReady()) return
        val modelInputs = JSONArray()
        for (m in models) modelInputs.put(JSONObject().put("id", m))
        engine?.callFunc("setProviderProfile", JSONObject()
            .put("provider", provider)
            .put("baseUrl", baseUrl)
            .put("apiKey", apiKey)
            .put("models", modelInputs)
            .toString())
    }

    /** Device self-test (direct): bypass the QuickJS bridge, call DeviceBridge directly. */
    suspend fun deviceDirectCall(op: String, argsJson: String): Pair<Boolean, String> {
        val dev = device ?: throw IllegalStateException("device bridge not ready — engine not started")
        val result = CompletableDeferred<Pair<Boolean, String>>()
        dev.dispatch(
            testSeq.incrementAndGet(),
            JSONObject().put("op", op).put("args", JSONObject(argsJson)).toString(),
        ) { ok, json -> result.complete(Pair(ok, json)) }
        return result.await()
    }

    /** Device self-test (full chain): deviceSelfTest → QuickJS bridge → native → DeviceBridge. */
    suspend fun deviceFullChainCall(op: String, argsJson: String): JSONObject {
        val raw = engine?.callAwait(
            "deviceSelfTest",
            JSONObject().put("op", op).put("args", JSONObject(argsJson)).toString(),
        ) ?: throw IllegalStateException("engine not started")
        return JSONObject(raw)
    }

    /** Unmount when the session is deleted. */
    fun unmountIfMounted(sessionId: String) {
        if (mountedSessionId == sessionId) mountedSessionId = null
    }

    fun dispose() {
        started = false
        mountedSessionId = null
        engine?.dispose()
        engine = null
        http = null
        device = null
    }
}
