package com.harnest.app.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Text
import com.harnest.app.common.ReasoningEfforts
import com.harnest.app.service.SessionRecord
import com.harnest.app.service.StoredMessage
import com.harnest.app.shared.round.LiveItem
import com.harnest.app.shared.round.fmtDuration
import com.harnest.app.shared.round.groupLiveItems
import com.harnest.app.shared.round.parseTrace
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Chat view — mirrors harmonyApp ChatView.ets.
 * Top bar (drawer / title / model chip / new) + config banner + message stream
 * + input area (editor + send) + model picker + sessions drawer.
 */

/** k5 提问卡数据 — 内核 question 事件（kind=asked）questions 载荷的解析形态。 */
data class PendingOption(val label: String, val description: String)

/** k7e 后台任务视图 — 内核 jobs 事件（JobRegistry 可见集快照）单条解析形态。 */
data class BgJobView(
    val id: String,
    val kind: String,
    val label: String,
    val status: String, // running / finished
    val detail: String,
    val startedAt: Long,
    val finishedAt: Long,
)

data class PendingQuestion(
    val id: String,
    val question: String,
    val detail: String?,
    val header: String?,
    val options: List<PendingOption>,
    val multiSelect: Boolean,
    val intentKind: String?, // 'plan-review' → 审批面板样式；null → 通用提问
    val intentApprove: String?, // 批准选项 label（其余选项 = 拒绝并反馈）
)

data class PendingAnswer(val id: String, val selected: List<String>, val custom: String)

@Composable
fun ChatView(
    sessionTitle: String,
    needsConfig: Boolean,
    isSending: Boolean,
    busyHint: String,
    liveItems: List<LiveItem>,
    a11yEnabled: Boolean,
    messages: List<StoredMessage>,
    queuedMessages: List<String>,
    activeSessionId: String?,
    sessions: List<SessionRecord>,
    currentProvider: String?,
    currentModel: String?,
    currentEffort: String?,
    usableProviders: List<Pair<String, List<String>>>,
    providerLabel: (String) -> String,
    onNewSession: () -> Unit,
    onSelectSession: (String) -> Unit,
    onDeleteSession: (String) -> Unit,
    onSend: (String) -> Unit,
    onStop: () -> Unit,
    onQueue: (String) -> Unit,
    onSteer: (String) -> Unit,
    onCancelQueued: (Int) -> Unit,
    onCompactSession: () -> Unit,
    pendingQuestions: List<PendingQuestion>,
    onSubmitAnswers: (List<PendingAnswer>) -> Unit,
    planActive: Boolean,
    onTogglePlan: () -> Unit,
    onSelectModel: (String, String, String?) -> Unit,
    onGoSettings: () -> Unit,
    onOpenAccessibility: () -> Unit,
    onFork: ((StoredMessage) -> Unit)? = null,
    onRate: ((StoredMessage, Int) -> Unit)? = null,
    onCopy: ((StoredMessage) -> Unit)? = null,
    bgJobs: List<BgJobView> = emptyList(),
    onKillJob: ((String) -> Unit)? = null,
) {
    var drawerOpen by remember { mutableStateOf(false) }
    var pickerOpen by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxSize().background(harnessColors().background)) {
        Column(Modifier.fillMaxSize()) {
            ChatTopBar(
                sessionTitle,
                currentModel,
                canCompact = !isSending && messages.isNotEmpty(),
                planActive = planActive,
                onTogglePlan = onTogglePlan,
                onTogglePicker = { pickerOpen = !pickerOpen },
                onOpenDrawer = { drawerOpen = true },
                onNewSession,
                onCompact = onCompactSession,
            )
            if (needsConfig) ConfigBanner(onGoSettings)
            if (!a11yEnabled) A11yBanner(onOpenAccessibility)

            AnimatedVisibility(visible = pickerOpen) {
            ModelPicker(
                usableProviders = usableProviders,
                currentProvider = currentProvider,
                currentModel = currentModel,
                currentEffort = currentEffort,
                providerLabel = providerLabel,
                onSelect = { p, m, e ->
                    onSelectModel(p, m, e)
                    pickerOpen = false
                },
                onClose = { pickerOpen = false },
            )
        }

            MessageStream(
                messages = messages,
                activeSessionId = activeSessionId,
                isSending = isSending,
                liveItems = liveItems,
                modifier = Modifier.weight(1f),
                onFork = onFork,
                onRate = onRate,
                onCopy = onCopy,
                bgJobs = bgJobs,
                onKillJob = onKillJob,
            )

            // k5 提问卡：agent 挂起待人答（ask_user_question / plan 审批）— 置于输入区上方，
            // 回答经 onSubmitAnswers 回传内核 resolve，答案作为 tool result 驱动回合继续
            AnimatedVisibility(visible = pendingQuestions.isNotEmpty()) {
                QuestionCard(
                    questions = pendingQuestions,
                    onSubmit = onSubmitAnswers,
                )
            }

            InputArea(
                isSending = isSending,
                busyHint = busyHint,
                queuedMessages = queuedMessages,
                onSend = onSend,
                onStop = onStop,
                onQueue = onQueue,
                onSteer = onSteer,
                onCancelQueued = onCancelQueued,
                modifier = Modifier.imePadding(),
            )
        }

        AnimatedVisibility(
            visible = drawerOpen,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.45f))
                    .clickable { drawerOpen = false },
            ) {
                AnimatedVisibility(
                    visible = drawerOpen,
                    enter = slideInHorizontally { -it },
                    exit = slideOutHorizontally { -it },
                ) {
                    SessionsDrawer(
                        sessions = sessions,
                        activeSessionId = activeSessionId,
                        providerLabel = providerLabel,
                        onClose = { drawerOpen = false },
                        onNewSession = {
                            onNewSession()
                            drawerOpen = false
                        },
                        onSelect = {
                            onSelectSession(it)
                            drawerOpen = false
                        },
                        onDelete = onDeleteSession,
                    )
                }
            }
        }
    }
}

@Composable
private fun ChatTopBar(
    title: String,
    currentModel: String?,
    canCompact: Boolean,
    planActive: Boolean,
    onTogglePlan: () -> Unit,
    onTogglePicker: () -> Unit,
    onOpenDrawer: () -> Unit,
    onNewSession: () -> Unit,
    onCompact: () -> Unit,
) {
    val c = harnessColors()
    Row(
        Modifier
            .fillMaxWidth()
            .background(c.surface)
            .height(52.dp)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(40.dp)
                .clickable(onClick = onOpenDrawer),
            contentAlignment = Alignment.Center,
        ) { NavText("☰", 18.sp, c.textPrimary) }
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                title,
                color = c.textPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                Modifier
                    .background(c.surfaceElevated, RoundedCornerShape(50))
                    .clickable(onClick = onTogglePicker)
                    .padding(start = 10.dp, end = 10.dp, top = 1.dp, bottom = 1.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    currentModel ?: "选择模型",
                    color = c.textHint,
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(" ▾", color = c.textHint, fontSize = 10.sp)
            }
        }
        // k5 Plan 模式开关：开启后 agent 先产出计划（exit_plan_mode）经提问卡审批，批准才执行
        Box(
            Modifier
                .size(40.dp)
                .clickable(onClick = onTogglePlan),
            contentAlignment = Alignment.Center,
        ) { NavText("🧭", 15.sp, if (planActive) c.primary else c.textHint) }
        // 手动压缩上下文入口（k3）：有历史且非发送中才显示 — 内核要求回合间调用
        if (canCompact) {
            Box(
                Modifier
                    .size(40.dp)
                    .clickable(onClick = onCompact),
                contentAlignment = Alignment.Center,
            ) { NavText("🗜", 15.sp, c.textHint) }
        }
        Box(
            Modifier
                .size(40.dp)
                .clickable(onClick = onNewSession),
            contentAlignment = Alignment.Center,
        ) { NavText("＋", 20.sp, c.primary) }
    }
}

@Composable
private fun ConfigBanner(onGoSettings: () -> Unit) {
    val c = harnessColors()
    Row(
        Modifier
            .fillMaxWidth()
            .background(c.background)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("⚠ 尚未配置任何大模型 API", color = c.warning, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Text("去设置", color = c.primary, fontSize = 13.sp, modifier = Modifier.clickable(onClick = onGoSettings))
    }
}

@Composable
private fun MessageStream(
    messages: List<StoredMessage>,
    activeSessionId: String?,
    isSending: Boolean,
    liveItems: List<LiveItem>,
    modifier: Modifier = Modifier,
    onFork: ((StoredMessage) -> Unit)? = null,
    onRate: ((StoredMessage, Int) -> Unit)? = null,
    onCopy: ((StoredMessage) -> Unit)? = null,
    bgJobs: List<BgJobView> = emptyList(),
    onKillJob: ((String) -> Unit)? = null,
) {
    val c = harnessColors()
    val listState = rememberLazyListState()
    // 会话切换/首次进入：直接跳到底部（无动画），不依赖消息数变化（两会话消息数可能相同）
    LaunchedEffect(activeSessionId, messages.size) {
        if (messages.isNotEmpty()) {
            listState.scrollToItem(messages.size - 1)
        }
    }
    // 发送中内容增长（消息数/最后一条长度/实时条目）：平滑跟随到底
    LaunchedEffect(isSending, messages.size, messages.lastOrNull()?.content?.length, liveItems.size, liveItems.lastOrNull()) {
        if (isSending) {
            listState.animateScrollToItem(messages.size)
        } else if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }
    Box(modifier) {
        if (messages.isEmpty()) {
            Column(
                Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                if (bgJobs.isNotEmpty()) Spacer(Modifier.weight(1f))
                Text("🤖", fontSize = 40.sp)
                Spacer(Modifier.height(12.dp))
                Text("开始新的对话", color = c.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                Spacer(Modifier.height(4.dp))
                Text("模型与 API 均在本机内核中运行", color = c.textHint, fontSize = 11.sp)
                if (bgJobs.isNotEmpty()) {
                    Spacer(Modifier.weight(1f))
                    BackgroundJobsCard(jobs = bgJobs, onKill = onKillJob)
                }
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(messages, key = { it.id }) { m ->
                    when (m.role) {
                        "user" -> UserBubble(m)
                        "assistant" -> AssistantBubble(m, onFork = onFork, onRate = onRate, onCopy = onCopy)
                        "tool" -> ToolCard(m, elevatedBackground = false)
                    }
                }
                if (isSending) {
                    if (liveItems.isNotEmpty()) {
                        item(key = "__live__") {
                            LiveActivityPanel(items = liveItems, isSending = true)
                        }
                    } else {
                        item(key = "__sending__") {
                            Text("思考中…", color = c.textHint, fontSize = 11.sp, modifier = Modifier.padding(start = 4.dp))
                        }
                    }
                }
                if (bgJobs.isNotEmpty()) {
                    item(key = "__jobs__") {
                        BackgroundJobsCard(jobs = bgJobs, onKill = onKillJob)
                    }
                }
            }
        }
    }
}

@Composable
private fun UserBubble(m: StoredMessage) {
    val c = harnessColors()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Column(horizontalAlignment = Alignment.End) {
            if (m.steered) {
                Text(
                    "⚡ 中途转向 · 已注入当前回合",
                    color = Color(0xFFF5A623),
                    fontSize = 10.sp,
                    modifier = Modifier.padding(end = 4.dp, bottom = 3.dp),
                )
            }
            Box(
                Modifier
                    .widthIn(max = 300.dp)
                    .background(c.userBubble, RoundedCornerShape(12.dp))
                    .padding(12.dp),
            ) {
                Text(m.content, color = c.textPrimary, fontSize = 15.sp)
            }
        }
    }
}

@Composable
private fun AssistantBubble(
    m: StoredMessage,
    onFork: ((StoredMessage) -> Unit)? = null,
    onRate: ((StoredMessage, Int) -> Unit)? = null,
    onCopy: ((StoredMessage) -> Unit)? = null,
) {
    val c = harnessColors()
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
        Column(Modifier.widthIn(max = 320.dp)) {
            val meta = listOfNotNull(m.provider, m.model).joinToString(" · ")
            if (meta.isNotEmpty() || m.durationMs > 0) {
                Row(Modifier.padding(start = 4.dp, bottom = 3.dp)) {
                    if (meta.isNotEmpty()) {
                        Text(
                            meta,
                            color = c.textHint,
                            fontSize = 10.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                    }
                    if (m.durationMs > 0) {
                        if (meta.isNotEmpty()) Spacer(Modifier.width(6.dp))
                        Text(
                            "⏱ " + fmtDuration(m.durationMs),
                            color = c.textHint,
                            fontSize = 10.sp,
                            maxLines = 1,
                        )
                    }
                }
            }
            val trace = m.traceJson
            if (!trace.isNullOrEmpty()) {
                val parsed = remember(trace) { parseTrace(trace) }
                if (parsed.isNotEmpty()) {
                    LiveActivityPanel(items = parsed, isSending = false)
                    Spacer(Modifier.height(4.dp))
                }
            }
            Box(
                Modifier
                    .background(c.assistantBubble, RoundedCornerShape(12.dp))
                    .padding(12.dp),
            ) {
                // k8 接线：Markdown 渲染（标题/粗斜/码块高亮/表格/链接/$数学$降级/@mention）
                MarkdownBody(m.content, isError = m.id.startsWith("err_"))
            }
            if ((onRate != null || onFork != null || onCopy != null) && !m.id.startsWith("err_")) {
                // emoji 是彩色字形，Text color 着不了色；选中态用 primary 半透明药丸底做视觉反馈
                Row(Modifier.padding(start = 4.dp, top = 3.dp)) {
                    if (onRate != null) {
                        Text(
                            "👍",
                            fontSize = 12.sp,
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(
                                    if (m.rating == 1) c.primary.copy(alpha = 0.28f)
                                    else Color.Transparent
                                )
                                .clickable { onRate(m, 1) }
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "👎",
                            fontSize = 12.sp,
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(
                                    if (m.rating == -1) c.primary.copy(alpha = 0.28f)
                                    else Color.Transparent
                                )
                                .clickable { onRate(m, -1) }
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                    if (onCopy != null) {
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "📋",
                            fontSize = 12.sp,
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .clickable { onCopy(m) }
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                    if (onFork != null) {
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "🍴",
                            fontSize = 12.sp,
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .clickable { onFork(m) }
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                }
            }
        }
    }
}

/** Tool status → left edge color (running=warning, error=error, ok=neutral). */
private fun toolStatusColor(status: String?): Color {
    val c = DarkHarnessColors
    return when (status) {
        "error" -> c.error
        "running" -> c.warning
        else -> c.divider
    }
}

@Composable
fun ToolCard(m: StoredMessage, elevatedBackground: Boolean = true) {
    val c = harnessColors()
    val edge = toolStatusColor(m.toolStatus)
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .background(if (elevatedBackground) c.surfaceElevated else c.surface, RoundedCornerShape(10.dp)),
    ) {
        Box(
            Modifier
                .width(3.dp)
                .fillMaxHeight()
                .background(edge)
        )
        Column(
            Modifier
                .weight(1f)
                .padding(horizontal = 12.dp, vertical = 10.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(classifyTool(m.toolName ?: "").icon, fontSize = 12.sp)
                Spacer(Modifier.width(6.dp))
                Text(
                    m.toolName ?: "tool",
                    color = c.textPrimary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                ToolStatusLabel(m.toolStatus)
            }
            val todos = m.todosJson
            if (!todos.isNullOrEmpty()) {
                Spacer(Modifier.height(8.dp))
                TodoSnapshot(todos)
            } else if (!m.toolResult.isNullOrEmpty()) {
                Spacer(Modifier.height(6.dp))
                // k6：MCP 图片工具结果（result.content[].data = base64 图像）→ 解码渲染
                val img = remember(m.toolResult) { decodeMcpImage(m.toolResult) }
                if (img != null) {
                    androidx.compose.foundation.Image(
                        bitmap = img,
                        contentDescription = m.toolName ?: "tool image",
                        contentScale = androidx.compose.ui.layout.ContentScale.FillWidth,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 280.dp)
                            .background(c.surface, RoundedCornerShape(8.dp)),
                    )
                } else {
                    Text(
                        m.toolResult,
                        color = c.textHint,
                        fontSize = 11.sp,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

/** k6 解析 MCP 图片工具结果：{"content":[{"type":"image","data":"<base64>"}]} → Bitmap。
 *  非图片结果 / 解析失败 → null（回退到纯文本展示）。仅认 image 类 mime。 */
private fun decodeMcpImage(result: String?): androidx.compose.ui.graphics.ImageBitmap? {
    if (result.isNullOrEmpty()) return null
    return try {
        val root = org.json.JSONObject(result)
        val arr = root.optJSONArray("content") ?: return null
        for (i in 0 until arr.length()) {
            val item = arr.optJSONObject(i) ?: continue
            if (item.optString("type") != "image") continue
            val mime = item.optString("mimeType", item.optString("mime", ""))
            if (mime.isNotBlank() && !mime.startsWith("image/")) continue
            val data = item.optString("data", "")
            if (data.isEmpty()) continue
            val bytes = android.util.Base64.decode(data, android.util.Base64.DEFAULT)
            val bmp = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: continue
            return bmp.asImageBitmap()
        }
        null
    } catch (_: Throwable) {
        null
    }
}

@Composable
private fun ToolStatusLabel(status: String?) {
    val c = harnessColors()
    val label = when (status) {
        "error" -> "失败"
        "running" -> "运行中"
        else -> "完成"
    }
    val fg = when (status) {
        "error" -> c.error
        "running" -> c.warning
        else -> c.textHint
    }
    val bg = when (status) {
        "error" -> c.error.copy(alpha = 0.15f)
        "running" -> c.warning.copy(alpha = 0.15f)
        else -> Color.Transparent
    }
    val bordered = status != "error" && status != "running"
    Box(
        Modifier
            .background(bg, RoundedCornerShape(9.dp))
            .then(if (bordered) Modifier.border(1.dp, c.divider, RoundedCornerShape(9.dp)) else Modifier)
            .padding(horizontal = 8.dp, vertical = 3.dp),
    ) {
        Text(label, color = fg, fontSize = 11.sp)
    }
}

@Composable
fun TodoSnapshot(todosJson: String) {
    val c = harnessColors()
    val items = remember(todosJson) { parseTodos(todosJson) }
    Column {
        items.forEach { t ->
            Row(Modifier.padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                val (icon, iconColor) = when (t.status) {
                    "completed" -> "✓" to c.success
                    "in_progress" -> "◐" to c.primary
                    else -> "○" to c.textHint
                }
                Text(icon, color = iconColor, fontSize = 12.sp)
                Spacer(Modifier.width(8.dp))
                Text(
                    t.content,
                    color = if (t.status == "completed") c.textHint else c.textPrimary,
                    fontSize = 12.sp,
                )
            }
        }
    }
}

data class TodoItem(val content: String, val status: String)

fun parseTodos(json: String): List<TodoItem> = try {
    val arr = JSONArray(json)
    (0 until arr.length()).map { i ->
        val o = arr.optJSONObject(i) ?: return@map TodoItem("", "pending")
        TodoItem(o.optString("content"), o.optString("status", "pending"))
    }
} catch (_: Throwable) {
    emptyList()
}

@Composable
private fun A11yBanner(onOpen: () -> Unit) {
    val c = harnessColors()
    Row(
        Modifier
            .fillMaxWidth()
            .background(Color(0xFFE5484D).copy(alpha = 0.12f))
            .clickable(onClick = onOpen)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("⚠", color = Color(0xFFE5484D), fontSize = 13.sp)
        Spacer(Modifier.width(8.dp))
        Text(
            "无障碍服务未开启 — GUI 自动化不可用",
            color = Color(0xFFE5484D),
            fontSize = 12.sp,
            modifier = Modifier.weight(1f),
        )
        Text("去开启", color = Color(0xFFE5484D), fontSize = 12.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun InputArea(
    isSending: Boolean,
    busyHint: String,
    queuedMessages: List<String>,
    onSend: (String) -> Unit,
    onStop: () -> Unit,
    onQueue: (String) -> Unit,
    onSteer: (String) -> Unit,
    onCancelQueued: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = harnessColors()
    var text by remember { mutableStateOf("") }
    Column(
        modifier
            .fillMaxWidth()
            .background(c.surface)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        if (isSending) {
            Text(
                busyHint.ifEmpty { "回复中…" },
                color = c.textHint,
                fontSize = 10.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(bottom = 6.dp),
            )
        }
        // k4 排队区：待发消息 chip 列表（点击 × 撤销单条），回合结束自动出队续发
        if (queuedMessages.isNotEmpty()) {
            Column(Modifier.padding(bottom = 6.dp)) {
                Text(
                    "⏳ 已排队 ${queuedMessages.size} 条 · 本轮结束后自动发送",
                    color = c.textHint,
                    fontSize = 10.sp,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
                queuedMessages.forEachIndexed { idx, q ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(vertical = 2.dp)
                            .background(c.surfaceElevated, RoundedCornerShape(8.dp))
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            q,
                            color = c.textHint,
                            fontSize = 13.sp,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "×",
                            color = c.textHint,
                            fontSize = 15.sp,
                            modifier = Modifier
                                .clickable { onCancelQueued(idx) }
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.Bottom) {
            val scroll = rememberScrollState()
            BasicTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier
                    .weight(1f)
                    .background(c.surfaceElevated, RoundedCornerShape(10.dp))
                    .heightIn(min = 42.dp, max = 120.dp)
                    .verticalScroll(scroll)
                    .padding(horizontal = 12.dp, vertical = 11.dp),
                textStyle = TextStyle(color = c.textPrimary, fontSize = 15.sp),
                cursorBrush = SolidColor(c.primary),
                decorationBox = { inner ->
                    Box {
                        if (text.isEmpty()) {
                            Text(
                                if (isSending) "追加指令：⚡转向 或 ⏳排队…" else "发送消息…",
                                color = c.textHint,
                                fontSize = 15.sp,
                            )
                        }
                        inner()
                    }
                },
            )
            Spacer(Modifier.width(8.dp))
            // k4：回合运行中 → 两个即时动作（⚡ 中途转向 = 注入当前回合；⏳ 排队 = 本轮结束后发）
            if (isSending && text.isNotBlank()) {
                Box(
                    Modifier
                        .size(40.dp)
                        .background(c.surfaceElevated, RoundedCornerShape(50))
                        .clickable {
                            onQueue(text.trim())
                            text = ""
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Text("⏳", fontSize = 13.sp)
                }
                Spacer(Modifier.width(6.dp))
                Box(
                    Modifier
                        .size(40.dp)
                        .background(Color(0xFFF5A623), RoundedCornerShape(50))
                        .clickable {
                            onSteer(text.trim())
                            text = ""
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Text("⚡", fontSize = 15.sp)
                }
            } else {
                val canSend = text.isNotBlank() && !isSending
                Box(
                    Modifier
                        .size(40.dp)
                        .background(
                            if (isSending) Color(0xFFE5484D)
                            else if (canSend) c.primary else c.divider,
                            RoundedCornerShape(50),
                        )
                        .clickable(enabled = canSend || isSending) {
                            if (isSending) {
                                onStop()
                            } else {
                                onSend(text.trim())
                                text = ""
                            }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        if (isSending) "■" else "➤",
                        color = if (isSending) Color.White else c.onPrimary,
                        fontSize = 14.sp,
                    )
                }
            }
        }
    }
}

@Composable
private fun ModelPicker(
    usableProviders: List<Pair<String, List<String>>>,
    currentProvider: String?,
    currentModel: String?,
    currentEffort: String?,
    providerLabel: (String) -> String,
    onSelect: (String, String, String?) -> Unit,
    onClose: () -> Unit,
) {
    val c = harnessColors()
    // 两个并列 Tab：模型 / 思考模式
    var tab by remember { mutableStateOf(0) } // 0=模型, 1=思考模式
    Column(
        Modifier
            .fillMaxWidth()
            .heightIn(max = 340.dp)
            .background(c.surface, RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
            .verticalScroll(rememberScrollState())
            .padding(bottom = 8.dp),
    ) {
        // 顶部 Tab 切换
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            listOf("模型", "思考模式").forEachIndexed { i, label ->
                Text(
                    label,
                    color = if (tab == i) c.primary else c.textHint,
                    fontSize = 14.sp,
                    fontWeight = if (tab == i) FontWeight.Medium else FontWeight.Normal,
                    modifier = Modifier
                        .clickable { tab = i }
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
            Spacer(Modifier.weight(1f))
            Text("收起", color = c.textHint, fontSize = 12.sp, modifier = Modifier.clickable(onClick = onClose).padding(6.dp))
        }
        if (tab == 0) {
            // ── 模型列表 ──
            usableProviders.forEach { (provider, models) ->
                Text(
                    providerLabel(provider),
                    color = c.textHint,
                    fontSize = 11.sp,
                    modifier = Modifier.padding(start = 20.dp, top = 12.dp, bottom = 4.dp),
                )
                models.forEach { model ->
                    val selected = provider == currentProvider && model == currentModel
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable {
                                // 选模型即生效（effort 保留当前值），收起面板
                                onSelect(provider, model, currentEffort)
                                onClose()
                            }
                            .padding(horizontal = 20.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                model,
                                color = if (selected) c.primary else c.textPrimary,
                                fontSize = 14.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                providerLabel(provider),
                                color = c.textHint,
                                fontSize = 10.sp,
                            )
                        }
                        if (selected) Text("✓", color = c.primary, fontSize = 14.sp)
                    }
                }
            }
            if (usableProviders.isEmpty()) {
                Text(
                    "暂无可用模型 — 请先在设置中配置 API Key",
                    color = c.textHint,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(20.dp),
                )
            }
        } else {
            // ── 思考模式列表（独立于模型选择，基于当前会话） ──
            listOf(
                null to "跟随服务端默认",
                "off" to "不产出思考，速度最快",
                "high" to "常规思考",
                "max" to "深度思考，耗时更长",
            ).forEach { (effortId, desc) ->
                val selected = currentEffort == effortId
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            // 思考模式独立切换，保留当前模型不变
                            if (currentProvider != null && currentModel != null) {
                                onSelect(currentProvider, currentModel, effortId)
                            }
                            onClose()
                        }
                        .padding(horizontal = 20.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            ReasoningEfforts.label(effortId),
                            color = if (selected) c.primary else c.textPrimary,
                            fontSize = 14.sp,
                        )
                        Text(desc, color = c.textHint, fontSize = 11.sp)
                    }
                    if (selected) Text("✓", color = c.primary, fontSize = 14.sp)
                }
            }
        }
    }
}

@Composable
private fun SessionsDrawer(
    sessions: List<SessionRecord>,
    activeSessionId: String?,
    providerLabel: (String) -> String,
    onClose: () -> Unit,
    onNewSession: () -> Unit,
    onSelect: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    val c = harnessColors()
    val fmt = remember { SimpleDateFormat("HH:mm", Locale.getDefault()) }
    Column(
        Modifier
            .width(300.dp)
            .fillMaxHeight()
            .background(c.background)
            .padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("会话", color = c.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
            Text("＋", color = c.primary, fontSize = 20.sp, modifier = Modifier.clickable(onClick = onNewSession))
        }
        Spacer(Modifier.height(12.dp))
        LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            items(sessions, key = { it.id }) { s ->
                val current = s.id == activeSessionId
                Column(
                    Modifier
                        .fillMaxWidth()
                        .background(
                            if (current) c.surfaceElevated else Color.Transparent,
                            RoundedCornerShape(10.dp),
                        )
                        .clickable { onSelect(s.id) }
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            s.title,
                            color = c.textPrimary,
                            fontSize = 14.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (current) {
                            Text("●", color = c.success, fontSize = 10.sp)
                            Spacer(Modifier.width(4.dp))
                        }
                        if (sessions.size > 1) {
                            Text(
                                "✕",
                                color = c.textHint,
                                fontSize = 13.sp,
                                modifier = Modifier
                                    .clickable { onDelete(s.id) }
                                    .padding(start = 8.dp),
                            )
                        }
                    }
                    Text(
                        "${providerLabel(s.provider)} · ${s.model} · ${fmt.format(Date(s.updatedAt))}",
                        color = c.textHint,
                        fontSize = 10.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

@Composable
private fun NavText(char: String, size: androidx.compose.ui.unit.TextUnit, color: Color) {
    Text(char, color = color, fontSize = size)
}

// ── Live activity panel（对标 Trae/Codex 的执行过程展示） ──

/**
 * 实时活动面板：思考流 + 工具步骤 + 待办快照，两级折叠控制信息密度。
 * isSending=true 时默认展开跟随最新思考；回合结束后整面板收成单行摘要，点击展开回看。
 */
@Composable
fun LiveActivityPanel(items: List<LiveItem>, isSending: Boolean) {
    val c = harnessColors()
    val groups = groupLiveItems(items)
    val thinkChars = items.filterIsInstance<LiveItem.Think>().sumOf { it.text.length }
    val answerChars = items.filterIsInstance<LiveItem.Answer>().sumOf { it.text.length }
    val toolCount = items.filterIsInstance<LiveItem.Tool>().size
    val steerCount = items.filterIsInstance<LiveItem.Steer>().size
    val summary = buildList {
        if (toolCount > 0) add("$toolCount 步")
        if (thinkChars > 0) add("$thinkChars 字思考")
        if (answerChars > 0) add("$answerChars 字回复")
        if (steerCount > 0) add("⚡$steerCount 转向")
    }.joinToString(" · ")
    var panelExpanded by remember { mutableStateOf(isSending) }
    // 回合开始自动展开跟随最新活动；回合结束自动收成摘要行（对标 trae/codex，避免信息过密）
    LaunchedEffect(isSending) { panelExpanded = isSending }
    Column(
        Modifier
            .fillMaxWidth()
            .background(c.surfaceElevated, RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable { panelExpanded = !panelExpanded },
        ) {
            if (isSending) PulseDot(c.primary) else Text(if (panelExpanded) "▾" else "▸", fontSize = 10.sp, color = c.textHint)
            Spacer(Modifier.width(8.dp))
            Text(
                if (isSending) "正在执行…" else "执行轨迹",
                color = c.textPrimary,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.weight(1f))
            Text(
                summary,
                color = c.textHint,
                fontSize = 10.sp,
                maxLines = 1,
            )
        }
        AnimatedVisibility(visible = panelExpanded) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 280.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                Spacer(Modifier.height(6.dp))
                groups.forEachIndexed { idx, group ->
                    if (idx > 0) Spacer(Modifier.height(2.dp))
                    val head = group.first()
                    when (head) {
                        is LiveItem.Think -> ThinkGroup(
                            segments = group.filterIsInstance<LiveItem.Think>(),
                            autoExpand = isSending && idx == groups.lastIndex,
                        )
                        is LiveItem.Tool -> ToolLiveRow(head)
                        is LiveItem.Todos -> TodosLiveBlock(head)
                        is LiveItem.Steer -> SteerLiveRow(head)
                        is LiveItem.Subagent -> SubagentLiveRow(head)
                        is LiveItem.Answer -> AnswerGroup(
                            segments = group.filterIsInstance<LiveItem.Answer>(),
                            autoExpand = isSending && idx == groups.lastIndex,
                        )
                    }
                }
            }
        }
    }
}

/** k7e 后台任务卡 — 内核 JobRegistry 可见集（后台 bash / 子代理等）镜像。
 *  会话级（非回合级）：回合结束后仍在跑的后台任务持续可见，全部退出后卡片自动消失。 */
@Composable
fun BackgroundJobsCard(jobs: List<BgJobView>, onKill: ((String) -> Unit)?) {
    val c = harnessColors()
    Column(
        Modifier
            .fillMaxWidth()
            .background(c.surfaceElevated, RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("🧰", fontSize = 13.sp)
            Spacer(Modifier.width(8.dp))
            Text(
                "后台任务 · ${jobs.size}",
                color = c.textPrimary,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
            )
        }
        Spacer(Modifier.height(4.dp))
        jobs.forEach { job -> BgJobRow(job, onKill) }
    }
}

@Composable
private fun BgJobRow(job: BgJobView, onKill: ((String) -> Unit)?) {
    val c = harnessColors()
    val running = job.status == "running"
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            when {
                job.kind.contains("bash") || job.kind.contains("terminal") -> "💻"
                job.kind.contains("agent") -> "🤖"
                else -> "⚙️"
            },
            fontSize = 12.sp,
        )
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(
                job.label.ifBlank { job.kind },
                color = c.textPrimary,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                buildString {
                    append(job.kind)
                    if (job.detail.isNotBlank()) append(" · ${job.detail}")
                    append(" · ").append(if (running) "运行中" else job.status)
                },
                color = c.textHint,
                fontSize = 10.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (running && onKill != null) {
            Spacer(Modifier.width(8.dp))
            Text(
                "终止",
                color = c.error,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .background(c.error.copy(alpha = 0.12f))
                    .clickable { onKill(job.id) }
                    .padding(horizontal = 10.dp, vertical = 4.dp),
            )
        }
    }
}

/** 思考组（一级折叠）：标题行汇总段数/字数，展开后按轮次分段渲染（段内二级折叠）。
 *  remember 键含 autoExpand：新活动到来时旧组自动收起、仅跟随最新一组，回合结束全部收起。 */
@Composable
private fun ThinkGroup(segments: List<LiveItem.Think>, autoExpand: Boolean) {
    val c = harnessColors()
    val head = segments.firstOrNull()
    val key = head?.let { "${it.turn}:${it.step}" } ?: "0"
    var expanded by remember(key, autoExpand) { mutableStateOf(autoExpand) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .padding(vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(if (expanded) "▾" else "▸", color = c.textHint, fontSize = 11.sp)
            Spacer(Modifier.width(7.dp))
            Text("💭", fontSize = 12.sp)
            Spacer(Modifier.width(6.dp))
            Text(
                (if (autoExpand) "思考中" else "思考过程") + if (segments.size > 1) " · ${segments.size} 段" else "",
                color = c.textPrimary,
                fontSize = 13.sp,
            )
            Spacer(Modifier.weight(1f))
            Text("${segments.sumOf { it.text.length }} 字", color = c.textHint, fontSize = 10.sp)
        }
        if (expanded) {
            segments.forEachIndexed { idx, seg ->
                if (idx > 0) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(c.divider.copy(alpha = 0.4f)),
                    )
                }
                ThinkSegment(
                    seg,
                    label = if (segments.size > 1) "第 ${idx + 1} 段" else null,
                    running = autoExpand && idx == segments.lastIndex,
                )
            }
        }
    }
}

/** 回复预览组（一级折叠）：正文撰写中的实时预览，收起仅留摘要行，展开看截断正文。 */
@Composable
private fun AnswerGroup(segments: List<LiveItem.Answer>, autoExpand: Boolean) {
    val c = harnessColors()
    val text = segments.joinToString("") { it.text }
    var expanded by remember(autoExpand) { mutableStateOf(autoExpand) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .padding(vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(if (expanded) "▾" else "▸", color = c.textHint, fontSize = 11.sp)
            Spacer(Modifier.width(7.dp))
            Text("💬", fontSize = 12.sp)
            Spacer(Modifier.width(6.dp))
            Text("回复预览", color = c.textPrimary, fontSize = 13.sp)
            Spacer(Modifier.weight(1f))
            Text("${text.length} 字", color = c.textHint, fontSize = 10.sp)
        }
        if (expanded) {
            Text(
                text,
                color = c.textSecondary,
                fontSize = 12.sp,
                lineHeight = 17.sp,
                maxLines = 10,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp),
            )
        }
    }
}

/** 单段思考（三级折叠 L3）：默认折叠只渲染单行摘要——性能关键，内核每 200ms 发段内累积全量，
 *  万字全文常驻重排会卡死 UI（对齐 iOS ThinkSegmentRow）。点击展开全文（>4000 字尾部截断）。 */
@Composable
private fun ThinkSegment(seg: LiveItem.Think, label: String?, running: Boolean) {
    val c = harnessColors()
    var expanded by remember(seg.turn, seg.step) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (label != null) {
                Text(label, color = c.textPrimary, fontSize = 11.sp)
                Spacer(Modifier.width(6.dp))
            }
            Text(
                thinkSummaryLine(seg.text, running),
                color = c.textHint,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(6.dp))
            Text("${seg.text.length} 字", color = c.textHint, fontSize = 10.sp)
            Text(if (expanded) "▾" else "▸", color = c.textHint, fontSize = 10.sp)
        }
        if (expanded) {
            Text(
                if (seg.text.length > 4000) "…" + seg.text.takeLast(4000) else seg.text,
                color = c.textHint,
                fontSize = 12.sp,
                lineHeight = 17.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 2.dp),
            )
        }
    }
}

/** ReasoningRow 摘要语义（对齐内核/iOS）：running 跟尾最新非空行（尾部 60 字滑动窗），定稿回首行。 */
private fun thinkSummaryLine(text: String, running: Boolean): String {
    val lines = text.split('\n').filter { it.isNotBlank() }
    val picked = (if (running) lines.lastOrNull() else lines.firstOrNull()) ?: return ""
    val t = picked.trim()
    return if (t.length > 60) "…" + t.takeLast(60) else t
}

/** k7 工具类型 → 专属卡片类别（图标 + 摘要抽取 + 终端等宽渲染）。 */
private enum class ToolKind(val icon: String) {
    SEARCH("🔍"), GREP("🔎"), TERMINAL("💻"), WEB("🌐"), FILE("📄"), ARTIFACT("📦"), TODO("🗒"), GENERIC("⚙️"),
}

private fun classifyTool(name: String): ToolKind {
    val n = name.lowercase()
    return when {
        "grep" in n || ("search" in n && "web" !in n && "file" !in n) -> ToolKind.GREP
        "bash" in n || "terminal" in n || "shell" in n || "exec" in n || "command" in n || "run" in n -> ToolKind.TERMINAL
        "web" in n || "http" in n || "fetch" in n || "browse" in n || "url" in n -> ToolKind.WEB
        "artifact" in n -> ToolKind.ARTIFACT
        "search" in n || "query" in n || "lookup" in n || "find" in n -> ToolKind.SEARCH
        "todo" in n -> ToolKind.TODO
        "read" in n || "write" in n || "file" in n || "edit" in n || "glob" in n -> ToolKind.FILE
        else -> ToolKind.GENERIC
    }
}

/** 从工具参数 JSON 抽一行人类可读摘要（搜索词 / 命令 / 路径）。 */
private fun toolArgsSummary(kind: ToolKind, args: String): String {
    if (args.isBlank()) return ""
    return try {
        val o = org.json.JSONObject(args)
        val key = when (kind) {
            ToolKind.TERMINAL -> listOf("command", "cmd", "script", "code")
            ToolKind.SEARCH, ToolKind.GREP -> listOf("query", "pattern", "q", "keyword", "path")
            ToolKind.WEB -> listOf("url", "query", "q")
            ToolKind.FILE -> listOf("path", "file", "filePath", "filename")
            ToolKind.ARTIFACT -> listOf("path", "file", "name", "title", "filename")
            else -> listOf("query", "command", "path", "input", "text")
        }.firstOrNull { o.has(it) && o.optString(it).isNotBlank() }
        val v = key?.let { o.optString(it) } ?: ""
        v.replace("\n", " ⏎ ").take(80)
    } catch (_: Throwable) {
        ""
    }
}

/** 工具步骤行（一级折叠）：状态色边条 + 专属图标/名称/参数摘要 + 状态标签，展开看参数与结果。
 *  终端类工具结果以等宽终端卡渲染；bash 被终止（error + 终止关键词）单独标注。 */
@Composable
private fun ToolLiveRow(tool: LiveItem.Tool) {
    val c = harnessColors()
    var expanded by remember(tool.callId, tool.name) { mutableStateOf(false) }
    val kind = classifyTool(tool.name)
    val summary = remember(tool.name, tool.args) { toolArgsSummary(kind, tool.args) }
    val terminated = tool.status == "error" &&
        (tool.result.contains("abort", true) || tool.result.contains("terminat", true) ||
            tool.result.contains("killed", true) || tool.result.contains("已停止", true))
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clickable { expanded = !expanded },
    ) {
        Box(
            Modifier
                .width(3.dp)
                .fillMaxHeight()
                .background(toolStatusColor(tool.status)),
        )
        Column(
            Modifier
                .weight(1f)
                .padding(start = 8.dp, top = 5.dp, bottom = 5.dp, end = 2.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(kind.icon, fontSize = 11.sp)
                Spacer(Modifier.width(6.dp))
                Text(
                    tool.name,
                    color = c.textPrimary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (summary.isNotBlank()) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        summary,
                        color = c.textHint,
                        fontSize = 10.sp,
                        fontFamily = if (kind == ToolKind.TERMINAL) FontFamily.Monospace else FontFamily.Default,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    Spacer(Modifier.weight(1f))
                }
                if (tool.status == "running") {
                    PulseDot(c.warning, size = 6.dp)
                    Spacer(Modifier.width(4.dp))
                }
                if (tool.durationMs > 0) {
                    Text("⏱ ${fmtDuration(tool.durationMs)}", color = c.textHint, fontSize = 10.sp)
                    Spacer(Modifier.width(6.dp))
                }
                when {
                    terminated -> Text("⛔ 已终止", color = c.error, fontSize = 10.sp)
                    tool.status == "running" -> Text("▾", color = c.textHint, fontSize = 10.sp)
                    else -> ToolStatusLabel(tool.status)
                }
            }
            AnimatedVisibility(visible = expanded) {
                Column(Modifier.padding(top = 4.dp)) {
                    if (tool.args.isNotBlank()) {
                        Text(
                            tool.args,
                            color = c.textHint,
                            fontSize = 10.sp,
                            maxLines = 4,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    if (tool.result.isNotBlank()) {
                        if (tool.args.isNotBlank()) Spacer(Modifier.height(4.dp))
                        if (kind == ToolKind.TERMINAL) {
                            // 终端卡：等宽 + 深色底，输出按原样保留（截 2000 字已由内核侧控制）
                            Box(
                                Modifier
                                    .fillMaxWidth()
                                    .background(c.surface, RoundedCornerShape(6.dp))
                                    .padding(horizontal = 8.dp, vertical = 6.dp),
                            ) {
                                Text(
                                    tool.result,
                                    color = if (tool.status == "error") c.error else c.textPrimary,
                                    fontSize = 10.sp,
                                    fontFamily = FontFamily.Monospace,
                                )
                            }
                        } else {
                            Text(
                                tool.result,
                                color = if (tool.status == "error") c.error else c.textHint,
                                fontSize = 10.sp,
                                maxLines = 8,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}

/** k4 转向条目：⚡ 高亮行，展开看注入全文（下一 step 边界生效）。 */
@Composable
private fun SteerLiveRow(item: LiveItem.Steer) {
    val c = harnessColors()
    var expanded by remember(item.text) { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .clickable { expanded = !expanded },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .width(3.dp)
                .height(16.dp)
                .background(Color(0xFFF5A623)),
        )
        Spacer(Modifier.width(8.dp))
        Text("⚡", fontSize = 11.sp)
        Spacer(Modifier.width(6.dp))
        Text(
            "中途转向",
            color = Color(0xFFF5A623),
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            item.text,
            color = c.textHint,
            fontSize = 11.sp,
            maxLines = if (expanded) 6 else 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Text(if (expanded) "▾" else "▸", color = c.textHint, fontSize = 10.sp)
    }
}

/** k7 子代理/workflow 树节点：缩进边条 + 🤖 标签 + 阶段 + 运行中脉冲 / 完成态 outcome。 */
@Composable
private fun SubagentLiveRow(item: LiveItem.Subagent) {
    val c = harnessColors()
    val running = item.outcome.isEmpty()
    val statusColor = when {
        running -> c.warning
        item.outcome.equals("error", true) || item.outcome.contains("fail", true) -> c.error
        else -> c.success
    }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 8.dp), // 树缩进：区别于一级工具行
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .width(3.dp)
                .height(16.dp)
                .background(statusColor),
        )
        Spacer(Modifier.width(8.dp))
        Text("🤖", fontSize = 11.sp)
        Spacer(Modifier.width(6.dp))
        Text(
            item.label,
            color = c.textPrimary,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (item.phase.isNotBlank()) {
            Spacer(Modifier.width(6.dp))
            Text(item.phase, color = c.textHint, fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.weight(1f))
        if (running) {
            PulseDot(c.warning, size = 6.dp)
            Spacer(Modifier.width(4.dp))
            Text("运行中", color = c.warning, fontSize = 10.sp)
        } else {
            Text(
                if (item.outcome.isBlank()) "完成" else item.outcome,
                color = statusColor,
                fontSize = 10.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** 待办快照（一级折叠）：标题显示进度 done/total，展开为状态图标列表。 */
@Composable
private fun TodosLiveBlock(todos: LiveItem.Todos) {
    val c = harnessColors()
    var expanded by remember { mutableStateOf(true) }
    val done = todos.items.count { it.second == "completed" }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .padding(vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(if (expanded) "▾" else "▸", color = c.textHint, fontSize = 11.sp)
            Spacer(Modifier.width(7.dp))
            Text("✅ 任务清单", color = c.textPrimary, fontSize = 13.sp)
            Spacer(Modifier.weight(1f))
            Text("${done}/${todos.items.size}", color = c.textHint, fontSize = 10.sp)
        }
        if (expanded) {
            todos.items.forEach { (content, status) ->
                Row(
                    Modifier.padding(start = 16.dp, top = 2.dp, bottom = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val (icon, iconColor) = when (status) {
                        "completed" -> "✓" to c.success
                        "in_progress" -> "◐" to c.primary
                        else -> "○" to c.textHint
                    }
                    Text(icon, color = iconColor, fontSize = 12.sp)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        content,
                        color = if (status == "completed") c.textHint else c.textPrimary,
                        fontSize = 12.sp,
                    )
                }
            }
        }
    }
}

/** 脉冲指示点：透明度呼吸动画，用于「正在执行」与运行中工具。 */
@Composable
private fun PulseDot(color: Color, size: androidx.compose.ui.unit.Dp = 7.dp) {
    val transition = rememberInfiniteTransition(label = "pulse")
    val alpha by transition.animateFloat(
        initialValue = 0.25f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(600), RepeatMode.Reverse),
        label = "pulseAlpha",
    )
    Box(
        Modifier
            .size(size)
            .background(color.copy(alpha = alpha), CircleShape),
    )
}

/** k5 提问卡：agent 挂起等待人回答（ask_user_question 工具 / plan 审批复用同一通道）。
 *  选项单选=圆点、多选=方框；自由文本为"其他/修改意见"，单选时与选项互斥 — 与内核
 *  answerQuestion 校验同语义，UI 保证提交即合法。问题集（qid）变化时选择态整体重置。 */
@Composable
private fun QuestionCard(
    questions: List<PendingQuestion>,
    onSubmit: (List<PendingAnswer>) -> Unit,
) {
    val c = harnessColors()
    val isPlanReview = questions.firstOrNull()?.intentKind == "plan-review"
    val selections = remember(questions) {
        questions.associate { q -> q.id to mutableStateOf(emptySet<String>()) }
    }
    val customs = remember(questions) {
        questions.associate { q -> q.id to mutableStateOf("") }
    }
    Column(
        Modifier
            .fillMaxWidth()
            // 高卡片（多题/带描述选项）不设上限会把提交键连同输入区挤出屏幕外：
            // 限高 + 内部滚动，提交键永远可达。
            .heightIn(max = 300.dp)
            .verticalScroll(rememberScrollState())
            .background(c.surfaceElevated)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Text(
            if (isPlanReview) "🧭 计划待审批" else "❓ Agent 在等你回答",
            color = c.textPrimary,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(8.dp))
        questions.forEachIndexed { idx, q ->
            if (idx > 0) Spacer(Modifier.height(10.dp))
            QuestionBlock(q, selections.getValue(q.id), customs.getValue(q.id))
        }
        Spacer(Modifier.height(10.dp))
        val allAnswered = questions.all { q ->
            selections.getValue(q.id).value.isNotEmpty()
                || customs.getValue(q.id).value.isNotBlank()
                || q.options.isEmpty()
        }
        Box(
            Modifier
                .fillMaxWidth()
                .height(40.dp)
                .background(if (allAnswered) c.primary else c.divider, RoundedCornerShape(10.dp))
                .clickable(enabled = allAnswered) {
                    onSubmit(
                        questions.map { q ->
                            PendingAnswer(
                                q.id,
                                selections.getValue(q.id).value.toList(),
                                customs.getValue(q.id).value.trim(),
                            )
                        }
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (isPlanReview) "提交决定" else "提交回答",
                color = c.onPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
            )
        }
    }
}

/** 单题块：题面 + 可展开 detail（plan markdown 预览）+ 选项行 + 自由文本输入。 */
@Composable
private fun QuestionBlock(
    q: PendingQuestion,
    selected: MutableState<Set<String>>,
    custom: MutableState<String>,
) {
    val c = harnessColors()
    Column {
        if (q.header != null) {
            Text(q.header, color = c.textHint, fontSize = 10.sp)
            Spacer(Modifier.height(2.dp))
        }
        Text(q.question, color = c.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium)
        if (q.detail != null) {
            Spacer(Modifier.height(4.dp))
            var expanded by remember(q.id) { mutableStateOf(false) }
            Text(
                q.detail,
                color = c.textSecondary,
                fontSize = 12.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = if (expanded) Int.MAX_VALUE else 4,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(c.surface, RoundedCornerShape(8.dp))
                    .clickable { expanded = !expanded }
                    .padding(horizontal = 10.dp, vertical = 8.dp),
            )
        }
        if (q.options.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            q.options.forEach { op ->
                val isSelected = op.label in selected.value
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            if (q.multiSelect) {
                                selected.value =
                                    if (isSelected) selected.value - op.label else selected.value + op.label
                            } else {
                                selected.value = if (isSelected) emptySet() else setOf(op.label)
                                custom.value = "" // 单选：选选项即清自由文本（互斥）
                            }
                        }
                        .padding(vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier
                            .size(18.dp)
                            .border(
                                1.5.dp,
                                if (isSelected) c.primary else c.divider,
                                if (q.multiSelect) RoundedCornerShape(4.dp) else CircleShape,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (q.multiSelect && isSelected) {
                            Text("✓", color = c.primary, fontSize = 12.sp)
                        } else if (!q.multiSelect && isSelected) {
                            Box(Modifier.size(8.dp).background(c.primary, CircleShape))
                        }
                    }
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(op.label, color = c.textPrimary, fontSize = 14.sp)
                        if (op.description.isNotBlank()) {
                            Text(op.description, color = c.textHint, fontSize = 11.sp)
                        }
                    }
                    // plan-review：批准项右侧标注（intent.approve 命名定位，不按位置推断）
                    if (q.intentKind == "plan-review" && q.intentApprove != null && op.label == q.intentApprove) {
                        Spacer(Modifier.width(8.dp))
                        Text("批准", color = c.primary, fontSize = 10.sp)
                    }
                }
            }
        }
        // 自由文本：plan-review = 修改意见（代替批准）；普通题 = "其他"。单选输入即取消选项
        Spacer(Modifier.height(6.dp))
        BasicTextField(
            value = custom.value,
            onValueChange = {
                custom.value = it
                if (!q.multiSelect && it.isNotBlank()) selected.value = emptySet()
            },
            modifier = Modifier
                .fillMaxWidth()
                .background(c.surface, RoundedCornerShape(8.dp))
                .padding(horizontal = 10.dp, vertical = 9.dp),
            textStyle = TextStyle(color = c.textPrimary, fontSize = 13.sp),
            cursorBrush = SolidColor(c.primary),
            decorationBox = { inner ->
                Box {
                    if (custom.value.isEmpty()) {
                        Text(
                            if (q.intentKind == "plan-review") "提出修改意见（代替批准）…"
                            else "其他回答（自由输入）…",
                            color = c.textHint,
                            fontSize = 13.sp,
                        )
                    }
                    inner()
                }
            },
        )
    }
}
