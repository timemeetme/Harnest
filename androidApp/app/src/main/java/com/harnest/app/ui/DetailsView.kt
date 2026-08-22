package com.harnest.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.harnest.app.service.StoredMessage
import com.harnest.app.shared.round.LiveItem
import com.harnest.app.shared.round.fmtDuration
import com.harnest.app.shared.round.parseTrace

@Composable
fun DetailsView(messages: List<StoredMessage>, revision: Int = 0) {
    val c = harnessColors()
    // 工具轨迹来源：旧数据为独立 role="tool" 消息；新架构归并进 assistant 消息的 traceJson，此处展开还原。
    // 注意：messages 为原地 add 的 MutableList 实例（引用不变），key 必须含 size 才能在新消息到达后重算
    val traj = remember(messages, messages.size, revision) {
        buildList {
            for (m in messages) {
                if (m.role == "tool") {
                    add(m)
                } else if (m.role == "assistant") {
                    val tj = m.traceJson.orEmpty()
                    if (tj.isNotEmpty()) {
                        for (t in parseTrace(tj).filterIsInstance<LiveItem.Tool>()) {
                            val body = t.result.ifEmpty { t.args }
                            val withDur = if (t.durationMs > 0) body + "\n⏱ " + fmtDuration(t.durationMs) else body
                            add(
                                StoredMessage(
                                    id = m.id + "_t_" + t.callId.ifEmpty { t.name },
                                    role = "tool",
                                    content = "",
                                    createdAt = m.createdAt,
                                    toolName = t.name,
                                    toolStatus = t.status,
                                    toolResult = withDur,
                                )
                            )
                        }
                    }
                }
            }
        }
    }
    val errors = remember(traj) { traj.count { it.toolStatus == "error" } }
    val pending = remember(messages, messages.size) { pendingTodoCount(messages) }
    // k7 轨迹分页：默认只渲染最近 PAGE 条（新到达自动跟随），滚动到顶部点「加载更早」逐步回看
    val PAGE = 50
    val visibleCount = androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(PAGE) }
    androidx.compose.runtime.LaunchedEffect(traj.size) {
        if (traj.size <= visibleCount.value) visibleCount.value = PAGE.coerceAtLeast(traj.size)
    }
    val shown = remember(traj, visibleCount.value) { traj.takeLast(visibleCount.value.coerceAtMost(traj.size)) }
    val hiddenCount = traj.size - shown.size
    val listState = rememberLazyListState()
    LaunchedEffect(traj.size) {
        if (traj.isNotEmpty() && hiddenCount == 0) listState.animateScrollToItem(shown.size)
    }
    Column(
        Modifier
            .fillMaxSize()
            .background(c.background)
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .background(c.surface)
        ) {
            Text(
                "轨迹",
                color = c.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 16.dp, top = 14.dp, bottom = 6.dp),
            )
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 2.dp)
                    .padding(bottom = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("调用 ${traj.size}", color = c.textSecondary, fontSize = 11.sp)
                Text(
                    "失败 $errors",
                    color = if (errors > 0) c.error else c.textHint,
                    fontSize = 11.sp,
                )
                Text("待办 $pending", color = c.textSecondary, fontSize = 11.sp)
            }
        }
        if (traj.isEmpty()) {
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("🧭", fontSize = 42.sp)
                    Spacer(Modifier.height(12.dp))
                    Text("暂无执行轨迹", color = c.textHint, fontSize = 14.sp)
                    Spacer(Modifier.height(6.dp))
                    Text("对话中的工具调用会汇总到这里", color = c.textHint, fontSize = 11.sp)
                }
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = 12.dp, end = 12.dp, top = 12.dp, bottom = 100.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (hiddenCount > 0) {
                    item(key = "__load_more__") {
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .background(c.surface, androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                                .clickable { visibleCount.value += PAGE }
                                .padding(vertical = 10.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                "▲ 加载更早 $hiddenCount 条",
                                color = c.primary,
                                fontSize = 12.sp,
                            )
                        }
                    }
                }
                items(shown.size) { idx -> ToolCard(shown[idx], elevatedBackground = false) }
            }
        }
    }
}

/** Count of unfinished items in the latest todo snapshot (traceJson first, legacy todosJson fallback). */
internal fun pendingTodoCount(messages: List<StoredMessage>): Int {
    var count = 0
    for (m in messages) {
        val tj = m.traceJson.orEmpty()
        if (tj.isNotEmpty()) {
            val last = parseTrace(tj).filterIsInstance<LiveItem.Todos>().lastOrNull()
            if (last != null) count = last.items.count { it.second != "completed" }
        }
        val legacy = m.todosJson
        if (!legacy.isNullOrEmpty()) {
            count = parseTodos(legacy).count { it.status != "completed" }
        }
    }
    return count
}
