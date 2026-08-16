package com.harnessapp.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.Workspaces
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.harnessapp.shared.ui.ChatMessage
import com.harnessapp.shared.ui.DetailsTab
import com.harnessapp.shared.ui.PlanItemUi
import com.harnessapp.shared.ui.PlanStatus
import com.harnessapp.shared.ui.SubagentStatus
import com.harnessapp.shared.ui.SubagentUi
import com.harnessapp.shared.ui.TodoItemUi
import com.harnessapp.shared.ui.ToolCallUi
import com.harnessapp.shared.ui.ToolStatus
import com.harnessapp.shared.ui.UiState

@Composable
fun DetailsPanel(
    state: UiState,
    onSelectTab: (DetailsTab) -> Unit,
    onAddTodo: (String) -> Unit,
    onToggleTodo: (String) -> Unit,
    onDeleteTodo: (String) -> Unit,
    onClose: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxHeight()
            .background(MaterialTheme.colorScheme.surface)
            .padding(vertical = 8.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "详情面板",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            onClose?.let {
                IconButton(onClick = it, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Close, contentDescription = null, Modifier.size(18.dp))
                }
            }
        }

        TabRow(
            selectedTabIndex = state.detailsTab.ordinal,
            containerColor = Color.Transparent,
            modifier = Modifier.fillMaxWidth(),
        ) {
            DetailsTab.values().forEach { tab ->
                Tab(
                    selected = state.detailsTab == tab,
                    onClick = { onSelectTab(tab) },
                    text = { Text(tab.label()) },
                    icon = { Icon(tab.icon(), contentDescription = null, Modifier.size(16.dp)) },
                    selectedContentColor = MaterialTheme.colorScheme.primary,
                    unselectedContentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        Box(Modifier.fillMaxSize()) {
            when (state.detailsTab) {
                DetailsTab.Tools -> ToolsTab(messages = state.messages)
                DetailsTab.Plan -> PlanTab(plan = state.plan)
                DetailsTab.Todo -> TodoTab(
                    todos = state.todos,
                    onAdd = onAddTodo,
                    onToggle = onToggleTodo,
                    onDelete = onDeleteTodo,
                )
                DetailsTab.Subagents -> SubagentsTab(subagents = state.subagents)
                DetailsTab.Settings -> SettingsTab(state = state)
            }
        }
    }
}

private fun DetailsTab.label(): String = when (this) {
    DetailsTab.Tools -> "Tools"
    DetailsTab.Plan -> "Plan"
    DetailsTab.Todo -> "Todo"
    DetailsTab.Subagents -> "Subagents"
    DetailsTab.Settings -> "Settings"
}

private fun DetailsTab.icon(): ImageVector = when (this) {
    DetailsTab.Tools -> Icons.Default.Settings
    DetailsTab.Plan -> Icons.Default.Timeline
    DetailsTab.Todo -> Icons.Default.CheckCircle
    DetailsTab.Subagents -> Icons.Default.Workspaces
    DetailsTab.Settings -> Icons.Default.Settings
}

@Composable
private fun ToolsTab(messages: List<ChatMessage>) {
    val allCalls = remember(messages) {
        messages.flatMap { it.toolCalls }
    }
    Column(Modifier.fillMaxSize().padding(12.dp)) {
        if (allCalls.isEmpty()) {
            EmptyHint("暂未记录工具调用")
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(allCalls, key = { it.id }) { call ->
                    ToolCallCard(call)
                }
            }
        }
    }
}

@Composable
private fun ToolCallCard(call: ToolCallUi) {
    val statusColor = when (call.status) {
        ToolStatus.Success -> MaterialTheme.colorScheme.primary
        ToolStatus.Error -> MaterialTheme.colorScheme.error
        ToolStatus.Running -> MaterialTheme.colorScheme.primary
        ToolStatus.Pending -> MaterialTheme.colorScheme.outline
    }
    val result = call.result
    val hasResult = result != null

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                MaterialTheme.colorScheme.surfaceContainerLow,
                RoundedCornerShape(10.dp),
            )
            .padding(12.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .size(10.dp)
                .clip(CircleShape)
                .background(statusColor),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(call.name, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Medium)
            Text(call.args, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (hasResult && result != null) {
                Text(
                    result.take(300),
                    style = MaterialTheme.typography.bodySmall,
                    color = statusColor,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
        Text(call.status.name, style = MaterialTheme.typography.labelSmall, color = statusColor)
    }
}

@Composable
private fun PlanTab(plan: List<PlanItemUi>) {
    Column(Modifier.fillMaxSize().padding(12.dp)) {
        if (plan.isEmpty()) {
            EmptyHint("暂无计划")
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(plan, key = { it.id }) { item ->
                    PlanNode(item, depth = 0)
                }
            }
        }
    }
}

@Composable
private fun PlanNode(item: PlanItemUi, depth: Int) {
    val statusColor = when (item.status) {
        PlanStatus.Done -> MaterialTheme.colorScheme.primary
        PlanStatus.InProgress -> MaterialTheme.colorScheme.primary
        PlanStatus.Blocked -> MaterialTheme.colorScheme.error
        PlanStatus.Pending -> MaterialTheme.colorScheme.outline
    }
    val desc = item.description
    val hasDesc = desc != null

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = (depth * 12).dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(vertical = 4.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(statusColor),
            )
            Text(item.title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
            Text(item.status.name, style = MaterialTheme.typography.labelSmall, color = statusColor)
        }
        if (hasDesc && desc != null) {
            Text(desc, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        item.children.forEach { child ->
            PlanNode(child, depth + 1)
        }
    }
}

@Composable
private fun TodoTab(
    todos: List<TodoItemUi>,
    onAdd: (String) -> Unit,
    onToggle: (String) -> Unit,
    onDelete: (String) -> Unit,
) {
    var input by remember { mutableStateOf("") }

    Column(Modifier.fillMaxSize().padding(12.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = input,
                onValueChange = { input = it },
                modifier = Modifier.weight(1f),
                placeholder = { Text("添加 todo") },
                singleLine = true,
                shape = RoundedCornerShape(12.dp),
                colors = androidx.compose.material3.TextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
            )
            IconButton(
                onClick = {
                    if (input.isNotBlank()) {
                        onAdd(input)
                        input = ""
                    }
                },
                modifier = Modifier.size(44.dp).background(
                    MaterialTheme.colorScheme.primary, RoundedCornerShape(22.dp)
                ),
            ) {
                Icon(Icons.Default.Add, contentDescription = null, tint = MaterialTheme.colorScheme.onPrimary)
            }
        }

        Spacer(Modifier.height(12.dp))

        if (todos.isEmpty()) {
            EmptyHint("暂无 todo")
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                items(todos, key = { it.id }) { todo ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(
                                MaterialTheme.colorScheme.surfaceContainerLow,
                                RoundedCornerShape(10.dp),
                            )
                            .padding(horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(
                            checked = todo.done,
                            onCheckedChange = { onToggle(todo.id) },
                        )
                        Text(
                            text = todo.content,
                            modifier = Modifier.weight(1f),
                            style = MaterialTheme.typography.bodyMedium,
                            color = if (todo.done) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.onSurface,
                        )
                        IconButton(onClick = { onDelete(todo.id) }, modifier = Modifier.size(32.dp)) {
                            Icon(Icons.Default.Delete, contentDescription = null, modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SubagentsTab(subagents: List<SubagentUi>) {
    Column(Modifier.fillMaxSize().padding(12.dp)) {
        if (subagents.isEmpty()) {
            EmptyHint("暂无运行中的子代理")
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(subagents, key = { it.id }) { sa ->
                    val color = when (sa.status) {
                        SubagentStatus.Running -> MaterialTheme.colorScheme.primary
                        SubagentStatus.Done -> MaterialTheme.colorScheme.primary
                        SubagentStatus.Error -> MaterialTheme.colorScheme.error
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(
                                MaterialTheme.colorScheme.surfaceContainerLow,
                                RoundedCornerShape(10.dp),
                            )
                            .padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Box(
                            modifier = Modifier
                                .size(10.dp)
                                .clip(CircleShape)
                                .background(color),
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(sa.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                            Text(
                                text = "parent: ${sa.parentSessionId ?: "-"}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Text(sa.status.name, style = MaterialTheme.typography.labelSmall, color = color)
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsTab(state: UiState) {
    val s = state.settings
    Column(
        Modifier.fillMaxSize().padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("模型", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
        OutlinedTextField(
            value = s.provider,
            onValueChange = {},
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Provider") },
            singleLine = true,
        )
        OutlinedTextField(
            value = s.model,
            onValueChange = {},
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Model") },
            singleLine = true,
        )
        OutlinedTextField(
            value = s.maxTokens.toString(),
            onValueChange = {},
            modifier = Modifier.fillMaxWidth(),
            label = { Text("maxTokens") },
            singleLine = true,
        )

        Text("当前连接", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
        val c = state.connection
        Text("Host: ${c.host}:${c.port}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("TLS: ${c.useTls}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        val serverName = c.serverName
        val serverVersion = c.serverVersion
        if (serverName != null) {
            Text("Server: $serverName ${serverVersion ?: ""}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text("Workspace: ${state.workspace.path.ifBlank { "-" }}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun EmptyHint(text: String) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
