package com.harnest.app

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.harnest.app.common.Providers
import com.harnest.app.common.ReasoningEfforts
import com.harnest.app.device.GuiService
import com.harnest.app.device.UiLauncher
import com.harnest.app.service.ConfigService
import com.harnest.app.service.LocalEngine
import com.harnest.app.service.SessionRecord
import com.harnest.app.service.SessionStore
import com.harnest.app.service.StoredMessage
import com.harnest.app.ui.AppearanceMode
import com.harnest.app.ui.ChatView
import com.harnest.app.ui.DeviceTestView
import com.harnest.app.ui.PendingAnswer
import com.harnest.app.ui.PendingOption
import com.harnest.app.ui.BgJobView
import com.harnest.app.ui.PendingQuestion
import com.harnest.app.shared.round.LiveItem
import com.harnest.app.shared.round.RoundEvent
import com.harnest.app.shared.round.RoundStats
import com.harnest.app.shared.round.applyRoundEvent
import com.harnest.app.shared.round.traceToJson
import org.json.JSONArray
import org.json.JSONObject
import com.harnest.app.ui.DetailsView
import com.harnest.app.ui.HarnessTheme
import com.harnest.app.ui.SettingsView
import com.harnest.app.ui.ThemePrefs
import com.harnest.app.ui.harnessColors
import com.harnest.app.ui.resolveDark
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume

private const val TAB_CHAT = 0
private const val TAB_DETAILS = 1
private const val TAB_SETTINGS = 2

/** 模型选择三元组：provider + model + 思考模式（null = 服务端默认）。 */
private data class ModelSel(val provider: String, val model: String, val effort: String?)

/**
 * 应用主壳（EMM 式，对齐 harmonyApp Index.ets）：
 * 手机底部导航 / 宽屏横屏侧边导航，三 Tab：对话 / 详情 / 设置。
 * 三视图常驻组合（KeepAliveStack），切换不销毁。
 */
class MainActivity : ComponentActivity() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // ── state ────────────────────────────────────────────────
    private val sessions = mutableStateOf<List<SessionRecord>>(emptyList())
    private val currentSession = mutableStateOf<SessionRecord?>(null)
    private val pendingSelection = mutableStateOf<ModelSel?>(null)
    private val busy = mutableStateOf(false)
    private val busyHint = mutableStateOf("")
    private val toastMsg = mutableStateOf<String?>(null)
    private val appearance = mutableStateOf(AppearanceMode.SYSTEM)
    private val showDeviceTest = mutableStateOf(false)
    private val showLogs = mutableStateOf(false)
    private val logLines = mutableStateListOf<String>()
    private val configRev = mutableStateOf(0)
    private val a11yEnabled = mutableStateOf(false)
    private val liveItems = mutableStateListOf<LiveItem>()
    private val messagesRev = mutableStateOf(0) // 会话消息是普通可变列表，回合结束自增以驱动详情页重组
    private val pendingQueue = mutableStateListOf<String>() // k4：回合运行中排队的消息（回合自然结束自动续发；停止清空）
    private val pendingQid = mutableStateOf(-1) // k5：内核挂起提问的 qid（-1 = 无待答问题）
    private val pendingQuestions = mutableStateOf<List<PendingQuestion>>(emptyList()) // k5：提问卡数据（含 plan-review 审批）
    private val planModeActive = mutableStateOf(false) // k5：Plan 模式开关（每回合 details.planActive 同步）
    private val bgJobs = mutableStateOf<List<BgJobView>>(emptyList()) // k7e：后台任务可见集（jobs 事件覆盖式镜像）
    private var roundThinkChars = 0
    private var roundAnswerChars = 0
    // 思考/回复节流（150ms，窗口须严格小于内核 200ms 心跳防相位锁死）：万字累积全量高频
    // upsert 会触发快照列表整体重组卡 UI，暂存丢帧由回合收尾 flushPendingLive 补偿
    private var thinkThrottleAt = 0L
    private var thinkPendingText: String? = null
    private var thinkPendingTurn = 0
    private var thinkPendingStep = 0
    private var answerThrottleAt = 0L
    private var answerPendingText: String? = null
    private var answerPendingTurn = 0
    private var answerPendingStep = 0
    private var sendJob: Job? = null

    // ── ActivityResult bridges (register before onCreate body) ──

    private var permCont: CancellableContinuation<Boolean>? = null
    private val permLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val cont = permCont
        permCont = null
        if (cont != null && cont.isActive) cont.resume(granted)
    }

    private var picCont: CancellableContinuation<String?>? = null
    private var picFile: File? = null
    private val picLauncher = registerForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val cont = picCont
        val f = picFile
        picCont = null
        picFile = null
        if (cont != null && cont.isActive) {
            cont.resume(if (ok && f != null && f.exists()) f.absolutePath else null)
        }
    }

    private var imgCont: CancellableContinuation<String?>? = null
    private val imgLauncher = registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        val cont = imgCont
        imgCont = null
        if (cont != null && cont.isActive) cont.resume(uri?.toString())
    }

    private var docCont: CancellableContinuation<String?>? = null
    private val docLauncher = registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        val cont = docCont
        docCont = null
        if (cont != null && cont.isActive) cont.resume(uri?.toString())
    }

    private var saveCont: CancellableContinuation<String?>? = null
    private val saveLauncher = registerForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream")
    ) { uri ->
        val cont = saveCont
        saveCont = null
        if (cont != null && cont.isActive) cont.resume(uri?.toString())
    }

    // ── UiLauncher for DeviceBridge (pickers + permissions) ──

    private val uiLauncher = object : UiLauncher {
        override fun runOnUi(block: () -> Unit) {
            runOnUiThread { block() }
        }

        override fun hasPermission(perm: String): Boolean =
            checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED

        override suspend fun requestPermission(perm: String): Boolean =
            suspendCancellableCoroutine { cont ->
                if (hasPermission(perm)) {
                    cont.resume(true)
                    return@suspendCancellableCoroutine
                }
                permCont = cont
                runOnUiThread {
                    try {
                        permLauncher.launch(perm)
                    } catch (e: Throwable) {
                        permCont = null
                        cont.resume(false)
                    }
                }
            }

        override suspend fun takePicture(): String? = suspendCancellableCoroutine { cont ->
            runOnUiThread {
                try {
                    val dir = File(filesDir, "harness/photos").apply { mkdirs() }
                    val f = File(dir, "photo_${System.currentTimeMillis()}.jpg")
                    val uri = FileProvider.getUriForFile(this@MainActivity, "$packageName.fileprovider", f)
                    picFile = f
                    picCont = cont
                    picLauncher.launch(uri)
                } catch (e: Throwable) {
                    picFile = null
                    cont.resume(null)
                }
            }
        }

        override suspend fun pickImage(): String? = suspendCancellableCoroutine { cont ->
            imgCont = cont
            runOnUiThread {
                try {
                    imgLauncher.launch("image/*")
                } catch (e: Throwable) {
                    imgCont = null
                    cont.resume(null)
                }
            }
        }

        override suspend fun pickDocument(mime: String?): String? = suspendCancellableCoroutine { cont ->
            docCont = cont
            runOnUiThread {
                try {
                    docLauncher.launch(mime ?: "*/*")
                } catch (e: Throwable) {
                    docCont = null
                    cont.resume(null)
                }
            }
        }

        override suspend fun pickSaveLocation(name: String): String? = suspendCancellableCoroutine { cont ->
            saveCont = cont
            runOnUiThread {
                try {
                    saveLauncher.launch(name)
                } catch (e: Throwable) {
                    saveCont = null
                    cont.resume(null)
                }
            }
        }

        override fun cancelPending() {
            runOnUiThread {
                permCont?.cancel(); permCont = null
                picCont?.cancel(); picCont = null
                picFile = null
                imgCont?.cancel(); imgCont = null
                docCont?.cancel(); docCont = null
                saveCont?.cancel(); saveCont = null
            }
        }
    }

    // ── lifecycle ────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // 系统栏透明 + 关闭对比度遮罩：否则窗口主题默认的不透明底色会盖住应用背景，
        // 导致状态栏/导航栏不跟随应用深浅色主题（内容已满屏铺 background，透出即联动）
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }
        appearance.value = ThemePrefs.load(this)
        LocalEngine.get().attachLauncher(uiLauncher)
        GuiService.onAvailabilityChanged = { _ ->
            runOnUiThread { a11yEnabled.value = GuiService.isEnabled(this) }
        }
        LocalEngine.get().onBusyStep = { step ->
            runOnUiThread { if (busy.value) busyHint.value = step }
        }
        LocalEngine.get().onRoundEvent = { o ->
            runOnUiThread { if (busy.value) applyRoundEvent(o) }
        }
        LocalEngine.get().onTitleEvent = { o ->
            runOnUiThread { applyTitleEvent(o) }
        }
        // k3b 会话内记忆：内核 log 镜像直投 SessionStore 写队列（QuickJS 线程 → 单线程
        // executor 保序落盘 .jsonl — 不经 UI 线程，回合结束后文件即为完整真相）
        LocalEngine.get().onLogEvent = { o ->
            SessionStore.get(this).onKernelLogEvent(o)
        }
        // k5 agent 提问 / Plan 审批：asked → 提问卡（选项/自定义输入），answered/cancelled → 撤卡
        LocalEngine.get().onQuestionEvent = { o ->
            runOnUiThread { applyQuestionEvent(o) }
        }
        // k7e 后台任务：JobRegistry 可见集快照 → 后台任务卡（运行中可终止，全部退出卡片消失）
        LocalEngine.get().onJobsEvent = { o ->
            runOnUiThread { applyJobsEvent(o) }
        }
        LocalEngine.get().onLogLine = { line ->
            runOnUiThread {
                logLines.add(line)
                if (logLines.size > 300) logLines.removeRange(0, logLines.size - 300)
            }
        }
        refreshSessions()
        setContent {
            val dark = resolveDark(appearance.value)
            HarnessTheme(appearance.value) {
                SideEffect {
                    WindowInsetsControllerCompat(window, window.decorView).apply {
                        isAppearanceLightStatusBars = !dark
                        isAppearanceLightNavigationBars = !dark
                    }
                }
                AppRoot()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        a11yEnabled.value = GuiService.isEnabled(this)
    }

    override fun onDestroy() {
        super.onDestroy()
        GuiService.onAvailabilityChanged = null
        LocalEngine.get().onBusyStep = null
        LocalEngine.get().onQuestionEvent = null
        permCont?.cancel()
        picCont?.cancel()
        imgCont?.cancel()
        docCont?.cancel()
        saveCont?.cancel()
        if (isFinishing) scope.cancel()
    }

    private fun toast(msg: String) {
        toastMsg.value = msg
    }

    private fun refreshSessions() {
        sessions.value = SessionStore.get(this).loadAll().toList()
    }

    // ── actions ──────────────────────────────────────────────

    private fun newSession() {
        val sel = ConfigService.get(this).getDefaultSelection()
        pendingSelection.value = null
        pendingQueue.clear() // k4：新会话不继承旧会话排队
        clearPendingQuestion() // k5：新会话不继承旧会话待答问题
        planModeActive.value = false // k5：Plan 模式随会话（新会话默认关）
        currentSession.value = SessionRecord(
            id = SessionStore.newId(),
            title = "新会话",
            provider = sel.first,
            model = sel.second,
            effort = ConfigService.get(this).getDefaultEffort(),
            createdAt = System.currentTimeMillis(),
            updatedAt = System.currentTimeMillis(),
            messages = mutableListOf(),
        )
    }

    private fun openSessionById(id: String) {
        val record = sessions.value.firstOrNull { it.id == id } ?: return
        pendingQueue.clear() // k4：排队消息属于旧会话上下文，切会话即放弃
        clearPendingQuestion() // k5：旧会话的挂起提问随切换作废（内核 createSession 侧亦会撤）
        planModeActive.value = false // k5：切会话后由下一回合 details.planActive 重新对齐
        currentSession.value = record
    }

    private fun deleteSessionById(id: String) {
        val record = sessions.value.firstOrNull { it.id == id } ?: return
        SessionStore.get(this).delete(record.id)
        LocalEngine.get().unmountIfMounted(record.id)
        if (currentSession.value?.id == record.id) {
            currentSession.value = null
            pendingQueue.clear() // k4：会话被删，其排队消息一并放弃
            clearPendingQuestion() // k5：会话被删，挂起提问一并作废
            planModeActive.value = false
        }
        refreshSessions()
    }

    private fun applyModel(provider: String, model: String, effort: String?) {
        val session = currentSession.value
        if (session != null) {
            session.provider = provider
            session.model = model
            session.effort = effort
            SessionStore.get(this).upsert(session)
            refreshSessions()
        } else {
            pendingSelection.value = ModelSel(provider, model, effort)
        }
        LocalEngine.get().setModel(provider, model, effort)
        val effortTag = if (effort != null) " · ${ReasoningEfforts.label(effort)}" else ""
        toast("${Providers.metaOf(provider)?.label ?: provider} · $model$effortTag")
    }

    /** 发送入口（k4）：回合运行中 → 排队（本轮结束自动续发）；空闲 → 立即开新回合。 */
    private fun send(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        if (busy.value) {
            queueMessage(trimmed)
            return
        }
        sendNow(trimmed)
    }

    private fun queueMessage(text: String) {
        pendingQueue.add(text)
        toast("已排队 ${pendingQueue.size} 条 · 本轮结束后发送")
    }

    private fun cancelQueued(index: Int) {
        if (index in pendingQueue.indices) pendingQueue.removeAt(index)
    }

    /** 中途转向（k4）：idle 降级普通发送；running 中把消息注入当前回合下一 step 边界
     *  （不打断在途 LLM 请求）——实时面板立即出 ⚡ 条目，user 消息持久化带 ⚡ 标记。 */
    private fun steerMessage(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        if (!busy.value) {
            send(trimmed)
            return
        }
        val session = currentSession.value
        if (session == null) {
            send(trimmed)
            return
        }
        scope.launch {
            try {
                session.messages.add(
                    StoredMessage(
                        "s" + System.currentTimeMillis(), "user", trimmed,
                        System.currentTimeMillis(), steered = true,
                    )
                )
                session.updatedAt = System.currentTimeMillis()
                SessionStore.get(this@MainActivity).upsert(session)
                liveItems.add(LiveItem.Steer(trimmed))
                busyHint.value = "⚡ 已转向 · 下一 step 注入"
                val res = LocalEngine.get().steer(trimmed)
                if (!res.optBoolean("steered", false)) {
                    // 极小竞窗：回合恰在 steer 前结束 → 内核已降级为普通 chat
                    liveItems.add(LiveItem.Tool("steer-race", "steer", "", "ok", "回合已结束，转为普通发送", 0))
                }
            } catch (e: Throwable) {
                toast("转向失败：${e.message ?: e.javaClass.simpleName}")
            }
        }
    }

    private fun sendNow(trimmed: String) {
        sendJob = scope.launch {
            val roundStart = System.currentTimeMillis()
            var stopped = false
            busy.value = true
            busyHint.value = "启动引擎…"
            liveItems.clear()
            roundThinkChars = 0
            roundAnswerChars = 0
            try {
                try {
                    LocalEngine.get().ensureStarted(this@MainActivity)
                } catch (e: IllegalStateException) {
                    toast(e.message ?: "未配置")
                    return@launch
                }
                var session = currentSession.value
                if (session == null) {
                    val cfg = ConfigService.get(this@MainActivity)
                    val sel = pendingSelection.value
                        ?: cfg.getDefaultSelection().let { ModelSel(it.first, it.second, cfg.getDefaultEffort()) }
                    pendingSelection.value = null
                    session = SessionRecord(
                        SessionStore.newId(), SessionStore.titleFrom(trimmed),
                        sel.provider, sel.model, sel.effort,
                        System.currentTimeMillis(), System.currentTimeMillis(),
                        mutableListOf(),
                    )
                }
                // 旧会话的 provider 可能已无可用 key（清空 API/换设备导入部分配置后重开历史会话）：
                // 该 provider 未注册内核 adapter，发消息会报 no adapter registered — 回落默认可用选择
                val cfg = ConfigService.get(this@MainActivity)
                if (cfg.getConfig(session.provider).optString("apiKey").trim().isEmpty()) {
                    val def = cfg.getDefaultSelection()
                    session.provider = def.first
                    session.model = def.second
                    session.effort = cfg.getDefaultEffort()
                }
                // k3b：挂载时带上 .jsonl 事件日志 — 内核 replay 重建上下文（跨进程重启/
                // 切换会话回来的记忆延续）；新会话无日志文件 → seedJson=null 全新创建
                val seedJson = withContext(Dispatchers.IO) {
                    SessionStore.get(this@MainActivity).readSeedJson(session.id)
                }
                LocalEngine.get().mountSession(session, seedJson)
                // 记录「最后一次对话所用的模型」：新会话默认值以此为准（选择器临时切换不影响）
                ConfigService.get(this@MainActivity).setLastSelection(session.provider, session.model, session.effort)
                if (session.messages.isEmpty()) session.title = SessionStore.titleFrom(trimmed)
                session.messages.add(
                    StoredMessage("m" + System.currentTimeMillis(), "user", trimmed, System.currentTimeMillis())
                )
                currentSession.value = session
                busyHint.value = "思考中…"

                val outcome = LocalEngine.get().chat(trimmed)
                val details = outcome.optJSONObject("details")
                // k5：plan/mode 随回合折叠 — 审批通过/拒绝后由内核真相同步开关态
                if (details != null && details.has("planActive")) {
                    planModeActive.value = details.optBoolean("planActive")
                }
                val todosJson = details?.optJSONArray("todos")?.toString()
                val toolCalls = details?.optJSONArray("toolCalls")
                if (toolCalls != null && liveItems.isEmpty()) {
                    for (i in 0 until toolCalls.length()) {
                        val tc = toolCalls.optJSONObject(i) ?: continue
                        val name = tc.optString("name", "tool")
                        session.messages.add(
                            StoredMessage(
                                "t" + System.currentTimeMillis() + "-" + i,
                                "tool", "",
                                System.currentTimeMillis(),
                                toolName = name,
                                toolStatus = tc.optString("status", "ok"),
                                toolResult = tc.optString("result", "").take(400),
                                todosJson = if (name == "todo_write") todosJson else null,
                            )
                        )
                    }
                }
                // token 用量 surfaced：内核 extractDetails 的 details.usage（无 = 0 不展示）
                val usage = details?.optJSONObject("usage")
                val inTok = usage?.optLong("inputTokens", 0L) ?: 0L
                val outTok = usage?.optLong("outputTokens", 0L) ?: 0L
                // 错误判定：reason.error / max-tokens 截断 / 空回复兜底 → isError（红样式 + 重试入口）
                var failed = false
                var reply = outcome.optString("text", "").trim()
                val reason = outcome.optJSONObject("reason")
                if (reason?.optJSONObject("error") != null) failed = true
                if (reason?.optString("kind") == "max-tokens") failed = true
                if (reply.isEmpty()) {
                    reply = when {
                        reason?.optJSONObject("error") != null ->
                            "⚠️ " + reason.optJSONObject("error")!!.optString("message", reason.optJSONObject("error")!!.optString("code", "error"))
                        reason?.optString("kind") == "max-tokens" ->
                            "（模型输出达到长度上限被截断：深度思考占满了输出额度。可简化问题、降低思考强度，或换用输出额度更大的模型后重试）"
                        else -> "（无回复）"
                    }
                    failed = true
                }
                session.messages.add(
                    StoredMessage(
                        "a" + System.currentTimeMillis(), "assistant", reply,
                        System.currentTimeMillis(),
                        provider = session.provider, model = session.model,
                        durationMs = System.currentTimeMillis() - roundStart,
                        traceJson = traceJson(),
                        isError = failed,
                        inTok = inTok,
                        outTok = outTok,
                    )
                )
                session.updatedAt = System.currentTimeMillis()
                SessionStore.get(this@MainActivity).upsert(session)
                refreshSessions()
            } catch (e: Throwable) {
                val stoppedNow = e is kotlinx.coroutines.CancellationException
                if (stoppedNow) stopped = true
                var session = currentSession.value
                if (session == null) {
                    val cfg = ConfigService.get(this@MainActivity)
                    val sel = pendingSelection.value
                        ?: cfg.getDefaultSelection().let { ModelSel(it.first, it.second, cfg.getDefaultEffort()) }
                    session = SessionRecord(
                        SessionStore.newId(), SessionStore.titleFrom(trimmed),
                        sel.provider, sel.model, sel.effort,
                        System.currentTimeMillis(), System.currentTimeMillis(),
                        mutableListOf(),
                    )
                    currentSession.value = session
                }
                session.messages.add(
                    StoredMessage(
                        // err_ 前缀 = 错误消息（红样式 + 重试入口）；用户主动停止是正常结束，保持 a 前缀
                        (if (stopped) "a" else "err_") + System.currentTimeMillis(), "assistant",
                        if (stopped) "（本轮已停止）" else "⚠️ ${e.message ?: e.javaClass.simpleName}",
                        System.currentTimeMillis(),
                        durationMs = System.currentTimeMillis() - roundStart,
                        traceJson = traceJson(),
                        isError = !stopped,
                    )
                )
                session.updatedAt = System.currentTimeMillis()
                SessionStore.get(this@MainActivity).upsert(session)
                refreshSessions()
            } finally {
                flushPendingLive()
                sendJob = null
                busy.value = false
                busyHint.value = ""
                messagesRev.value++
            }
            // k4 排队续发：回合自然结束（非停止）且队列非空 → 弹出队首自动开下一回合
            if (!stopped && pendingQueue.isNotEmpty() && currentSession.value != null) {
                val next = pendingQueue.removeAt(0)
                sendNow(next)
            }
        }
    }

    /** 内核 session/title 事件 → 更新当前会话标题（LLM 自动 / fallback / 重命名共用）。 */
    private fun applyTitleEvent(o: JSONObject) {
        val title = o.optString("title", "").trim()
        if (title.isEmpty()) return
        val session = currentSession.value ?: return
        session.title = title
        session.updatedAt = System.currentTimeMillis()
        SessionStore.get(this).upsert(session)
        refreshSessions()
    }

    /** 会话手动重命名（标题不再只等 LLM 命名）。 */
    private fun renameSession(id: String, title: String) {
        val clean = title.trim()
        if (clean.isEmpty()) return
        val session = sessions.value.firstOrNull { it.id == id } ?: return
        session.title = clean
        session.updatedAt = System.currentTimeMillis()
        SessionStore.get(this).upsert(session)
        if (currentSession.value?.id == id) currentSession.value = session
        refreshSessions()
        toast("已重命名")
    }

    /** 错误重试：重发该错误消息之前最近一条 user 消息（重新问一遍，历史保留）。 */
    private fun retryFromMessage(messageId: String) {
        if (busy.value) return
        val session = currentSession.value ?: return
        val idx = session.messages.indexOfFirst { it.id == messageId }
        if (idx < 0) return
        val lastUser = session.messages.subList(0, idx).lastOrNull { it.role == "user" }
        if (lastUser == null || lastUser.content.isBlank()) {
            toast("未找到可重试的提问")
            return
        }
        send(lastUser.content)
    }

    /** 清空当前会话消息（保留会话壳与 provider 选择，重新开始）。 */
    private fun clearCurrentMessages() {
        val session = currentSession.value ?: return
        if (session.messages.isEmpty()) return
        val updated = session.copy(messages = mutableListOf(), updatedAt = System.currentTimeMillis())
        SessionStore.get(this).upsert(updated)
        currentSession.value = updated
        messagesRev.value++
        toast("已清空")
    }

    /** k5 跳过提问：每题提交全空 selected（内核按空答案继续）。 */
    private fun skipPendingQuestion() {
        val qid = pendingQid.value
        val questions = pendingQuestions.value
        if (qid < 0 || questions.isEmpty()) return
        submitQuestionAnswer(questions.map { PendingAnswer(it.id, emptyList(), "") })
    }

    // ── k6 消息尾部操作 ─────────────────────────────────────

    /** 复制消息正文到剪贴板。 */
    private fun copyMessage(m: StoredMessage) {
        try {
            val cm = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
            cm.setPrimaryClip(android.content.ClipData.newPlainText("message", m.content))
            toast("已复制")
        } catch (e: Throwable) {
            toast("复制失败")
        }
    }

    /** 👍/👎 反馈（本地持久）：再点同值取消（rating→0），异值切换。 */
    private fun rateMessage(m: StoredMessage, rating: Int) {
        val session = currentSession.value ?: return
        val idx = session.messages.indexOfFirst { it.id == m.id }
        if (idx < 0) return
        val old = session.messages[idx]
        val next = if (old.rating == rating) 0 else rating
        // 严禁原地改 session（它是 state 里那个对象，改完再 copy 也会因结构相等被
        // mutableStateOf 判定“无变化”而跳过重组）→ 必须整体构造新记录后一次赋值。
        val updated = session.copy(
            messages = session.messages.toMutableList().apply { set(idx, old.copy(rating = next)) },
            updatedAt = System.currentTimeMillis(),
        )
        SessionStore.get(this).upsert(updated)
        currentSession.value = updated
    }

    /** k6 fork：以该 user 消息为界开新会话 — 宿主侧 .jsonl 平衡前缀截断（第 n 个
     *  非转向用户回合的 turn/end 处）→ 复用 createSession(seedJson) replay 出完整上下文。
     *  fork 消息在末尾 → 整份复制；日志缺失（旧会话/被清）→ 降级仅复制消息视图。 */
    private fun forkFromMessage(m: StoredMessage) {
        if (busy.value) {
            toast("回合进行中 — 结束后再分支")
            return
        }
        val session = currentSession.value ?: return
        val store = SessionStore.get(this)
        scope.launch {
            try {
                var cutIdx = -1
                var userTurns = 0
                for (i in session.messages.indices) {
                    val msg = session.messages[i]
                    if (msg.role == "user" && !msg.steered) userTurns++
                    if (msg.id == m.id) {
                        cutIdx = i
                        break
                    }
                }
                if (cutIdx < 0) return@launch
                val source = session
                val fork = SessionRecord(
                    SessionStore.newId(), source.title + " ⑂",
                    source.provider, source.model, source.effort,
                    System.currentTimeMillis(), System.currentTimeMillis(),
                    source.messages.take(cutIdx + 1).toMutableList(),
                )
                val atEnd = cutIdx >= source.messages.size - 1
                val seed = withContext(Dispatchers.IO) {
                    if (atEnd) {
                        store.copyLogTo(source.id, fork.id)
                        store.readSeedJson(fork.id)
                    } else {
                        store.truncateLogAtUserTurn(source.id, userTurns)
                    }
                }
                if (seed != null) {
                    LocalEngine.get().ensureStarted(this@MainActivity)
                    LocalEngine.get().mountSession(fork, seed)
                    pendingQueue.clear()
                    clearPendingQuestion()
                    planModeActive.value = false
                    currentSession.value = fork
                    toast("已分支 · 上下文复刻到这条消息")
                } else {
                    store.upsert(fork)
                    refreshSessions()
                    pendingQueue.clear()
                    clearPendingQuestion()
                    planModeActive.value = false
                    currentSession.value = fork
                    toast("已分支（仅消息视图 · 该会话无事件日志，内核上下文无法复刻）")
                }
            } catch (e: Throwable) {
                toast("分支失败：${e.message ?: e.javaClass.simpleName}")
            }
        }
    }

    /** 手动压缩当前会话上下文（k3）：内核把旧回合 LLM 摘要成 summary 替换进上下文，
     *  压缩产生的新事件经 log 镜像自动落盘 .jsonl（记忆链路自洽）。须在回合间调用。 */
    private fun compactSession() {
        val session = currentSession.value
        if (session == null || session.messages.isEmpty()) {
            toast("暂无可压缩的历史")
            return
        }
        if (busy.value) {
            toast("回合进行中 — 请结束后再压缩")
            return
        }
        scope.launch {
            busy.value = true
            busyHint.value = "压缩上下文…"
            try {
                LocalEngine.get().ensureStarted(this@MainActivity)
                val seedJson = withContext(Dispatchers.IO) {
                    SessionStore.get(this@MainActivity).readSeedJson(session.id)
                }
                LocalEngine.get().mountSession(session, seedJson)
                val r = LocalEngine.get().compactNow()
                if (r.optBoolean("ok", false)) {
                    if (r.optBoolean("noop", false)) toast("暂无可压缩的历史")
                    else toast("已压缩 ${r.optInt("shadowedCount")} 个事件 · 约省 ${r.optInt("shadowedTokens")} tokens")
                } else {
                    toast("压缩失败：${r.optString("error", "未知错误")}")
                }
            } catch (e: Throwable) {
                toast("压缩失败：${e.message ?: e.javaClass.simpleName}")
            } finally {
                busy.value = false
                busyHint.value = ""
            }
        }
    }

    /** k5 内核 question 事件 → 提问卡状态：asked 解析 questions 载荷（id/question/
     *  detail/options/multiSelect/intent.plan-review）；answered/cancelled 撤卡。 */
    private fun applyQuestionEvent(o: JSONObject) {
        when (o.optString("kind")) {
            "asked" -> {
                val arr = o.optJSONArray("questions") ?: return
                val list = ArrayList<PendingQuestion>()
                for (i in 0 until arr.length()) {
                    val q = arr.optJSONObject(i) ?: continue
                    val opts = ArrayList<PendingOption>()
                    val oa = q.optJSONArray("options")
                    if (oa != null) {
                        for (j in 0 until oa.length()) {
                            val op = oa.optJSONObject(j) ?: continue
                            opts.add(PendingOption(op.optString("label"), op.optString("description", "")))
                        }
                    }
                    val intent = q.optJSONObject("intent")
                    list.add(
                        PendingQuestion(
                            id = q.optString("id"),
                            question = q.optString("question"),
                            detail = q.optString("detail", "").ifBlank { null },
                            header = q.optString("header", "").ifBlank { null },
                            options = opts,
                            multiSelect = q.optBoolean("multiSelect", false),
                            intentKind = intent?.optString("kind")?.ifBlank { null },
                            intentApprove = intent?.optString("approve")?.ifBlank { null },
                        )
                    )
                }
                if (list.isEmpty()) return
                pendingQid.value = o.optInt("qid", -1)
                pendingQuestions.value = list
                busyHint.value = "等待你的回答…"
            }
            "answered", "cancelled" -> {
                if (o.optInt("qid", -1) == pendingQid.value) clearPendingQuestion()
            }
        }
    }

    /** k7e：内核 jobs 事件（JobRegistry 可见集全量快照）→ 覆盖式镜像到后台任务卡。 */
    private fun applyJobsEvent(o: JSONObject) {
        val arr = o.optJSONArray("jobs") ?: run {
            bgJobs.value = emptyList()
            return
        }
        val list = ArrayList<BgJobView>(arr.length())
        for (i in 0 until arr.length()) {
            val j = arr.optJSONObject(i) ?: continue
            val status = j.optString("status", "running")
            // 内核 store 保留终态记录（completed/killed/failed 由回合事件呈现）；卡片只镜像活跃任务
            if (status != "running" && status != "stopping") continue
            list.add(
                BgJobView(
                    id = j.optString("id"),
                    kind = j.optString("kind"),
                    label = j.optString("label"),
                    status = j.optString("status", "running"),
                    detail = j.optString("detail", ""),
                    startedAt = j.optLong("startedAt", 0L),
                    finishedAt = j.optLong("finishedAt", 0L),
                )
            )
        }
        bgJobs.value = list
    }

    /** k7e：请求内核终止一个后台任务（bash 终止）；结果以 onJobsChanged → jobs 事件回刷卡片。 */
    private fun killBgJob(id: String) {
        scope.launch {
            try {
                val r = LocalEngine.get().killJob(id)
                if (r.optBoolean("ok")) {
                    toast("已请求终止 · ${r.optString("result")}")
                } else {
                    toast("终止失败 · ${r.optString("error")}")
                }
            } catch (e: Throwable) {
                toast("终止失败 · ${e.message}")
            }
        }
    }

    private fun clearPendingQuestion() {
        pendingQid.value = -1
        pendingQuestions.value = emptyList()
    }

    /** k5 提交提问答案：内核校验通过 → resolve 挂起的 ask()，答案作为 tool result
     *  回给模型（回合继续）；被拒（选项非法/互斥冲突）→ toast 报因，卡片保留待修正。 */
    private fun submitQuestionAnswer(answers: List<PendingAnswer>) {
        val qid = pendingQid.value
        if (qid < 0 || answers.isEmpty()) return
        scope.launch {
            try {
                val arr = JSONArray()
                for (a in answers) {
                    val o = JSONObject().put("id", a.id).put("selected", JSONArray(a.selected))
                    if (a.custom.isNotBlank()) o.put("custom", a.custom)
                    arr.put(o)
                }
                val res = LocalEngine.get().answerQuestion(qid, arr.toString())
                if (!res.optBoolean("ok", false)) {
                    toast("答案被拒：${res.optString("error", "未知原因")}")
                } else {
                    busyHint.value = "已回答 · 继续执行…"
                }
            } catch (e: Throwable) {
                toast("提交失败：${e.message ?: e.javaClass.simpleName}")
            }
        }
    }

    /** k5 开关 Plan 模式：回合外 committed 立即生效，回合内 queued 挂起到下一
     *  pre-step；开启后 agent 先产出计划（exit_plan_mode）经提问卡审批，批准才继续执行。 */
    private fun togglePlanMode() {
        val session = currentSession.value
        if (session == null) {
            toast("先发送一条消息建立会话")
            return
        }
        if (busy.value) {
            toast("回合进行中 — 结束后再切换")
            return
        }
        scope.launch {
            try {
                LocalEngine.get().ensureStarted(this@MainActivity)
                val seedJson = withContext(Dispatchers.IO) {
                    SessionStore.get(this@MainActivity).readSeedJson(session.id)
                }
                LocalEngine.get().mountSession(session, seedJson)
                val r = LocalEngine.get().setPlanMode(!planModeActive.value)
                planModeActive.value = r.optBoolean("active", false)
                toast(
                    when (r.optString("result")) {
                        "queued" -> if (planModeActive.value) "🧭 计划模式已排队 · 本轮结束后生效" else "计划模式关闭已排队 · 本轮结束后生效"
                        "committed" -> if (planModeActive.value) "🧭 计划模式开启 · agent 将先出计划待审" else "计划模式已关闭"
                        else -> "计划模式状态未变"
                    }
                )
            } catch (e: Throwable) {
                toast("切换失败：${e.message ?: e.javaClass.simpleName}")
            }
        }
    }

    /** 把内核 round 事件归并进实时活动列表（思考段/工具行/待办快照/回复预览），驱动 LiveActivityPanel。 */
    private fun applyRoundEvent(o: JSONObject) {
        when (o.optString("kind")) {
            "thinking" -> {
                // 内核 emit 段内累积全量（64 字/200ms 节流）：同 (turn,step) 幂等覆盖，跨键开新段。
                // indexOfLast 而非尾元素——assistant/message 兜底发来时该段可能已不在尾部（后有工具行）
                val text = o.optString("text", "")
                val turn = o.optInt("turn", 0)
                val step = o.optInt("step", 0)
                if (text.isNotEmpty()) {
                    val now = SystemClock.elapsedRealtime()
                    if (now - thinkThrottleAt < 150) {
                        thinkPendingText = text; thinkPendingTurn = turn; thinkPendingStep = step
                        return
                    }
                    thinkThrottleAt = now
                    upsertThink(text, turn, step, o.optInt("seq", 0))
                    roundThinkChars = liveItems.filterIsInstance<LiveItem.Think>().sumOf { it.text.length }
                    busyHint.value = "思考中 · ${roundThinkChars} 字"
                }
            }
            "answer" -> {
                // 回复预览：与 thinking 同构按 (turn,step) 分段累积覆盖 + 150ms 节流
                // （Answer 不入 trace，最终 assistant 正文即完整形态）
                val text = o.optString("text", "")
                val turn = o.optInt("turn", 0)
                val step = o.optInt("step", 0)
                if (text.isNotEmpty()) {
                    val now = SystemClock.elapsedRealtime()
                    if (now - answerThrottleAt < 150) {
                        answerPendingText = text; answerPendingTurn = turn; answerPendingStep = step
                        return
                    }
                    answerThrottleAt = now
                    val idx = liveItems.indexOfLast { it is LiveItem.Answer && it.turn == turn && it.step == step }
                    if (idx >= 0) {
                        val old = liveItems[idx] as LiveItem.Answer
                        if (text.length >= old.text.length) liveItems[idx] = old.copy(text = text)
                    } else {
                        liveItems.add(LiveItem.Answer(text, turn, step))
                    }
                    roundAnswerChars = liveItems.filterIsInstance<LiveItem.Answer>().sumOf { it.text.length }
                    busyHint.value = "撰写回复 · ${roundAnswerChars} 字"
                }
            }
            "tool-start" -> {
                liveItems.add(
                    LiveItem.Tool(
                        o.optString("callId"), o.optString("name", "tool"),
                        o.optString("args", ""), "running", "",
                    )
                )
                busyHint.value = "执行 ${o.optString("name", "tool")}…"
            }
            "tool-end" -> {
                val callId = o.optString("callId")
                var idx = liveItems.indexOfLast { it is LiveItem.Tool && it.callId == callId }
                if (idx < 0 && callId.isEmpty()) {
                    // 兜底：事件缺 callId 时归并到最后一个运行中的工具（顺序执行场景等价）
                    idx = liveItems.indexOfLast { it is LiveItem.Tool && it.status == "running" }
                }
                if (idx >= 0) {
                    val old = liveItems[idx] as LiveItem.Tool
                    liveItems[idx] = old.copy(
                        status = o.optString("status", "ok"),
                        result = o.optString("result", ""),
                        durationMs = o.optLong("durationMs", 0L),
                    )
                }
            }
            "todos" -> {
                val arr = o.optJSONArray("todos")
                val list = ArrayList<Pair<String, String>>()
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val t = arr.optJSONObject(i) ?: continue
                        list.add(t.optString("content") to t.optString("status", "pending"))
                    }
                }
                val item = LiveItem.Todos(list)
                val idx = liveItems.indexOfLast { it is LiveItem.Todos }
                if (idx >= 0) liveItems[idx] = item else liveItems.add(item)
            }
            "agent-start" -> {
                liveItems.add(
                    LiveItem.Subagent(
                        o.optString("runId"), o.optString("agentSeq"),
                        o.optString("label", "subagent"), o.optString("phase", ""),
                    )
                )
                busyHint.value = "子代理 ${o.optString("label", "subagent")}…"
            }
            "agent-end" -> {
                val rid = o.optString("runId")
                val sq = o.optString("agentSeq")
                val idx = liveItems.indexOfLast {
                    it is LiveItem.Subagent && it.runId == rid && it.agentSeq == sq
                }
                if (idx >= 0) {
                    val old = liveItems[idx] as LiveItem.Subagent
                    liveItems[idx] = old.copy(outcome = o.optString("outcome", ""))
                }
            }
        }
    }

    /** 按 (turn,step) 幂等 upsert 思考段（内核事件携带段内累积全量，同键且更长时覆盖）。 */
    private fun upsertThink(text: String, turn: Int, step: Int, seq: Int) {
        val idx = liveItems.indexOfLast { it is LiveItem.Think && it.turn == turn && it.step == step }
        if (idx >= 0) {
            val old = liveItems[idx] as LiveItem.Think
            if (text.length >= old.text.length) liveItems[idx] = old.copy(text = text)
        } else {
            liveItems.add(LiveItem.Think(seq, step, text, turn))
        }
    }

    /** 节流丢帧补偿：把 150ms 窗口内暂存的思考/回复文本落进实时面板（回合收尾保证最终完整）。 */
    private fun flushPendingLive() {
        val tText = thinkPendingText
        if (tText != null) {
            thinkPendingText = null
            upsertThink(tText, thinkPendingTurn, thinkPendingStep, 0)
        }
        val aText = answerPendingText
        if (aText != null) {
            answerPendingText = null
            val idx = liveItems.indexOfLast {
                it is LiveItem.Answer && it.turn == answerPendingTurn && it.step == answerPendingStep
            }
            if (idx >= 0) {
                val old = liveItems[idx] as LiveItem.Answer
                if (aText.length >= old.text.length) liveItems[idx] = old.copy(text = aText)
            } else {
                liveItems.add(LiveItem.Answer(aText, answerPendingTurn, answerPendingStep))
            }
        }
    }

    /** 序列化实时活动列表为轨迹 JSON，随 assistant 消息持久化（历史中可回看）。
     *  Answer 流式预览不入轨迹——最终 assistant 消息正文即其完整形态。 */
    private fun traceJson(): String? {
        flushPendingLive()
        if (liveItems.isEmpty()) return null
        val arr = JSONArray()
        for (item in liveItems) {
            val o = JSONObject()
            when (item) {
                is LiveItem.Think -> o.put("k", "think").put("t", item.text).put("s", item.step).put("u", item.turn)
                is LiveItem.Tool -> o.put("k", "tool").put("n", item.name).put("a", item.args)
                    .put("s", item.status).put("r", item.result).put("ms", item.durationMs)
                is LiveItem.Todos -> {
                    val l = JSONArray()
                    item.items.forEach { (content, status) -> l.put(JSONArray().put(content).put(status)) }
                    o.put("k", "todos").put("l", l)
                }
                is LiveItem.Steer -> o.put("k", "steer").put("t", item.text)
                is LiveItem.Subagent -> o.put("k", "subagent").put("rid", item.runId)
                    .put("sq", item.agentSeq).put("l", item.label).put("p", item.phase).put("o", item.outcome)
                is LiveItem.Answer -> continue
            }
            arr.put(o)
        }
        return arr.toString()
    }

    /**
     * 停止当前回合（输入区 ■ 按钮）：
     * L1 取消 UI 协程并取消挂起的交互等待（拍照/选择器/权限弹窗），
     * 再由 LocalEngine.abortActiveRound 完成 L3 内核取消与 L2 断流。
     */
    private fun stopCurrent() {
        if (!busy.value) return
        sendJob?.cancel()
        sendJob = null
        uiLauncher.cancelPending()
        LocalEngine.get().abortActiveRound()
        busy.value = false
        busyHint.value = ""
        val dropped = pendingQueue.size
        pendingQueue.clear() // k4：停止 = 放弃排队意图（续发仅限自然结束）
        toast(if (dropped > 0) "已停止本轮（清空 $dropped 条排队）" else "已停止本轮")
    }

    private fun appVersion(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
    } catch (e: Throwable) {
        "?"
    }

    // ── shell UI ─────────────────────────────────────────────

    @Composable
    private fun AppRoot() {
        var tab by rememberSaveable { mutableStateOf(TAB_CHAT) }
        val c = harnessColors()
        LaunchedEffect(toastMsg.value) {
            if (toastMsg.value != null) {
                delay(2200)
                toastMsg.value = null
            }
        }
        Box(Modifier.fillMaxSize().background(c.background)) {
            BoxWithConstraints(Modifier.fillMaxSize().systemBarsPadding()) {
                val wide = maxWidth >= 600.dp && maxWidth > maxHeight
                val contents = listOf<@Composable () -> Unit>(
                    { ChatTabContent(tab) { tab = it } },
                    { DetailsTabContent() },
                    { SettingsTabContent() },
                )
                if (wide) {
                    Row(Modifier.fillMaxSize()) {
                        SideRail(tab) { tab = it }
                        KeepAliveStack(tab, contents, Modifier.weight(1f).fillMaxHeight())
                    }
                } else {
                    Column(Modifier.fillMaxSize()) {
                        KeepAliveStack(tab, contents, Modifier.weight(1f).fillMaxWidth())
                        BottomNav(tab) { tab = it }
                    }
                }
            }
            if (showDeviceTest.value) {
                DeviceTestView(onClose = { showDeviceTest.value = false })
            }
            if (showLogs.value) {
                LogsOverlay()
            }
            toastMsg.value?.let { msg ->
                Box(
                    Modifier.fillMaxSize().padding(bottom = 96.dp),
                    contentAlignment = Alignment.BottomCenter,
                ) {
                    Text(
                        msg,
                        color = c.textPrimary,
                        fontSize = 12.sp,
                        modifier = Modifier
                            .background(c.surfaceElevated, RoundedCornerShape(10.dp))
                            .padding(horizontal = 14.dp, vertical = 9.dp),
                    )
                }
            }
        }
    }

    /** Compose-all / place-one stack — mirrors HarmonyOS Stack+visibility keep-alive. */
    @Composable
    private fun KeepAliveStack(
        active: Int,
        contents: List<@Composable () -> Unit>,
        modifier: Modifier = Modifier,
    ) {
        Layout(
            contents = contents,
            modifier = modifier.clipToBounds(),
        ) { measurables, constraints ->
            val placeables = measurables.map { group -> group.map { it.measure(constraints) } }
            layout(constraints.maxWidth, constraints.maxHeight) {
                placeables.forEachIndexed { index, group ->
                    group.forEach { placeable ->
                        placeable.place(
                            if (index == active) 0 else constraints.maxWidth,
                            0,
                        )
                    }
                }
            }
        }
    }

    @Composable
    private fun ChatTabContent(tab: Int, onTab: (Int) -> Unit) {
        val rev = configRev.value
        val usable = remember(rev) {
            ConfigService.get(this).listUsableProviders().mapNotNull { item ->
                val p = item.optString("provider")
                if (p.isEmpty()) null
                else {
                    val arr = item.optJSONArray("models")
                    val models = if (arr != null) List(arr.length()) { arr.optString(it) } else emptyList()
                    p to models
                }
            }
        }
        // 回合耗时跳动器：busyHint 动态拼接「阶段 · 字数 · m:ss」，对标 trae/codex 的过程提示
        var busySec by remember { mutableStateOf(0) }
        LaunchedEffect(busy.value) {
            if (busy.value) {
                busySec = 0
                val startAt = System.currentTimeMillis()
                while (true) {
                    delay(1000)
                    busySec = ((System.currentTimeMillis() - startAt) / 1000).toInt()
                }
            }
        }
        val hint = if (busy.value) {
            val base = busyHint.value.ifBlank { "处理中" }
            val sec = busySec
            val t = if (sec >= 60) "${sec / 60}:${(sec % 60).toString().padStart(2, '0')}" else "${sec}s"
            "$base · $t"
        } else ""
        ChatView(
            sessionTitle = currentSession.value?.title ?: "新会话",
            needsConfig = !ConfigService.get(this).hasUsableConfig(),
            isSending = busy.value,
            busyHint = hint,
            liveItems = liveItems,
            a11yEnabled = a11yEnabled.value,
            messages = currentSession.value?.messages ?: emptyList(),
            queuedMessages = pendingQueue,
            activeSessionId = currentSession.value?.id,
            sessions = sessions.value,
            currentProvider = currentSession.value?.provider ?: pendingSelection.value?.provider,
            currentModel = currentSession.value?.model ?: pendingSelection.value?.model,
            currentEffort = currentSession.value?.effort ?: pendingSelection.value?.effort,
            usableProviders = usable,
            providerLabel = { p -> Providers.metaOf(p)?.label ?: p },
            onNewSession = { newSession() },
            onSelectSession = { openSessionById(it) },
            onDeleteSession = { deleteSessionById(it) },
            onRenameSession = { id, title -> renameSession(id, title) },
            onClearMessages = { clearCurrentMessages() },
            onSend = { send(it) },
            onStop = { stopCurrent() },
            onQueue = { queueMessage(it.trim()) },
            onSteer = { steerMessage(it) },
            onCancelQueued = { cancelQueued(it) },
            onCompactSession = { compactSession() },
            onRate = { m, r -> rateMessage(m, r) },
            onFork = { forkFromMessage(it) },
            onCopy = { copyMessage(it) },
            onRetry = { m -> retryFromMessage(m.id) },
            pendingQuestions = if (pendingQid.value >= 0) pendingQuestions.value else emptyList(),
            onSubmitAnswers = { submitQuestionAnswer(it) },
            onSkipQuestions = { skipPendingQuestion() },
            planActive = planModeActive.value,
            onTogglePlan = { togglePlanMode() },
            onSelectModel = { p, m, e -> applyModel(p, m, e) },
            onGoSettings = { onTab(TAB_SETTINGS) },
            onOpenAccessibility = {
                try {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                } catch (e: Throwable) {
                    toast("无法打开系统设置")
                }
            },
            bgJobs = bgJobs.value,
            onKillJob = { killBgJob(it) },
        )
    }

    @Composable
    private fun DetailsTabContent() {
        busy.value // 订阅回合生命周期：结束后强制重组，让轨迹统计随最新消息重算
        val revision = messagesRev.value
        DetailsView(messages = currentSession.value?.messages ?: emptyList(), revision = revision)
    }

    @Composable
    private fun SettingsTabContent() {
        SettingsView(
            version = appVersion(),
            appearance = appearance.value,
            onAppearanceChange = { mode ->
                appearance.value = mode
                ThemePrefs.save(this@MainActivity, mode)
            },
            onConfigSaved = {
                configRev.value++
                LocalEngine.get().refreshProfiles(this)
                toast("配置已保存")
            },
            onOpenDeviceTest = { showDeviceTest.value = true },
            onOpenLogs = { showLogs.value = true },
            onOpenAccessibility = {
                try {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                } catch (e: Throwable) {
                    toast("无法打开系统设置")
                }
            },
        )
    }

    @Composable
    private fun SideRail(tab: Int, onTab: (Int) -> Unit) {
        val c = harnessColors()
        Column(
            Modifier
                .width(96.dp)
                .fillMaxHeight()
                .background(c.surface),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(
                Modifier.fillMaxWidth().padding(top = 20.dp, bottom = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("⌘", fontSize = 28.sp, color = c.textPrimary)
                Text("Harness", fontSize = 11.sp, color = c.textHint)
            }
            RailItem("对话", TAB_CHAT, tab, onTab)
            RailItem("详情", TAB_DETAILS, tab, onTab)
            RailItem("设置", TAB_SETTINGS, tab, onTab)
            Spacer(Modifier.weight(1f))
            Text(
                "Harnest App",
                fontSize = 10.sp,
                color = c.textHint,
                modifier = Modifier.padding(bottom = 16.dp),
            )
        }
    }

    @Composable
    private fun RailItem(label: String, idx: Int, tab: Int, onTab: (Int) -> Unit) {
        val c = harnessColors()
        val selected = tab == idx
        Column(
            Modifier
                .fillMaxWidth()
                .clickable { onTab(idx) }
                .background(
                    if (selected) c.background else androidx.compose.ui.graphics.Color.Transparent,
                    RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp),
                )
                .padding(top = 10.dp, bottom = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(glyph(idx), fontSize = 22.sp, color = if (selected) c.primary else c.textHint)
            Text(label, fontSize = 11.sp, color = if (selected) c.primary else c.textHint)
        }
    }

    @Composable
    private fun BottomNav(tab: Int, onTab: (Int) -> Unit) {
        val c = harnessColors()
        Column(Modifier.fillMaxWidth().background(c.surface)) {
            Box(Modifier.fillMaxWidth().height(0.5.dp).background(c.divider))
            Row(
                Modifier.fillMaxWidth().height(58.dp),
                horizontalArrangement = Arrangement.SpaceAround,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                NavItemWide("对话", TAB_CHAT, tab, onTab, Modifier.weight(1f))
                NavItemWide("详情", TAB_DETAILS, tab, onTab, Modifier.weight(1f))
                NavItemWide("设置", TAB_SETTINGS, tab, onTab, Modifier.weight(1f))
            }
        }
    }

    @Composable
    private fun NavItemWide(
        label: String,
        idx: Int,
        tab: Int,
        onTab: (Int) -> Unit,
        modifier: Modifier = Modifier,
    ) {
        val c = harnessColors()
        val selected = tab == idx
        Column(
            modifier
                .fillMaxHeight()
                .clickable { onTab(idx) }
                .padding(top = 8.dp, bottom = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(glyph(idx), fontSize = 20.sp, color = if (selected) c.primary else c.textHint)
            Text(label, fontSize = 11.sp, color = if (selected) c.primary else c.textHint)
        }
    }

    private fun glyph(idx: Int): String = when (idx) {
        TAB_CHAT -> "💬"
        TAB_DETAILS -> "📊"
        else -> "⚙"
    }

    // ── full-screen overlays ─────────────────────────────────

    @Composable
    private fun LogsOverlay() {
        val c = harnessColors()
        Column(
            Modifier
                .fillMaxSize()
                .background(c.background)
                .systemBarsPadding(),
        ) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(c.surface)
                    .height(52.dp)
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("运行日志", color = c.textPrimary, fontSize = 16.sp)
                    Text("${logLines.size} 行", color = c.textHint, fontSize = 10.sp)
                }
                Box(
                    Modifier
                        .clickable { logLines.clear() }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                ) { Text("清空", color = c.textSecondary, fontSize = 13.sp) }
                Box(
                    Modifier
                        .clickable { showLogs.value = false }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                ) { Text("关闭", color = c.primary, fontSize = 13.sp) }
            }
            LazyColumn(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                items(logLines.toList()) { line ->
                    Text(
                        line,
                        fontSize = 10.sp,
                        fontFamily = FontFamily.Monospace,
                        color = c.textSecondary,
                        modifier = Modifier.padding(vertical = 1.dp),
                    )
                }
            }
        }
    }
}
