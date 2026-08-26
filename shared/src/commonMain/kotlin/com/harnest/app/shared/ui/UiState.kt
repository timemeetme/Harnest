package com.harnest.app.shared.ui

import kotlinx.serialization.Serializable

/** 对话消息角色 */
@Serializable
enum class MessageRole { User, Assistant, System, Tool }

@Serializable
data class ChatMessage(
    val id: String,
    val role: MessageRole,
    val content: String,
    val createdAt: Long,
    val reasoning: String? = null,
    val toolCalls: List<ToolCallUi> = emptyList(),
    val isStreaming: Boolean = false,
)

@Serializable
data class ToolCallUi(
    val id: String,
    val name: String,
    val args: String,
    val result: String? = null,
    val status: ToolStatus = ToolStatus.Pending,
)

@Serializable
enum class ToolStatus { Pending, Running, Success, Error }

@Serializable
data class SessionUi(
    val id: String,
    val title: String,
    val updatedAt: Long,
    val messageCount: Int,
    val isRunning: Boolean = false,
)

@Serializable
data class TodoItemUi(
    val id: String,
    val content: String,
    val done: Boolean,
    val order: Int,
)

@Serializable
data class PlanItemUi(
    val id: String,
    val title: String,
    val description: String? = null,
    val status: PlanStatus = PlanStatus.Pending,
    val children: List<PlanItemUi> = emptyList(),
)

@Serializable
enum class PlanStatus { Pending, InProgress, Done, Blocked }

@Serializable
data class ApprovalRequestUi(
    val id: String,
    val title: String,
    val description: String? = null,
    val toolName: String? = null,
    val createdAt: Long,
)

@Serializable
data class SubagentUi(
    val id: String,
    val name: String,
    val status: SubagentStatus = SubagentStatus.Running,
    val parentSessionId: String? = null,
)

@Serializable
enum class SubagentStatus { Running, Done, Error }

@Serializable
data class GoalState(
    val text: String = "",
    val active: Boolean = false,
)

@Serializable
data class KernelConnectionState(
    val host: String = "localhost",
    val port: Int = 3080,
    val useTls: Boolean = false,
    val provider: String = "deepseek",
    val model: String = "deepseek-v4-flash",
    val status: ConnectionStatus = ConnectionStatus.Disconnected,
    val serverName: String? = null,
    val serverVersion: String? = null,
)

@Serializable
enum class ConnectionStatus { Disconnected, Connecting, Connected, Error }

@Serializable
data class WorkspaceUi(
    val path: String = "",
    val name: String = "",
)

@Serializable
data class SettingsUi(
    val provider: String = "deepseek",
    val model: String = "deepseek-v4-flash",
    val maxTokens: Int = 8192,
    val autoApprove: Boolean = false,
    val theme: String = "system",
    val language: String = "zh-CN",
)

@Serializable
data class UiState(
    val sessions: List<SessionUi> = emptyList(),
    val activeSessionId: String? = null,
    val messages: List<ChatMessage> = emptyList(),
    val todos: List<TodoItemUi> = emptyList(),
    val plan: List<PlanItemUi> = emptyList(),
    val approvals: List<ApprovalRequestUi> = emptyList(),
    val subagents: List<SubagentUi> = emptyList(),
    val goal: GoalState = GoalState(),
    val connection: KernelConnectionState = KernelConnectionState(),
    val workspace: WorkspaceUi = WorkspaceUi(),
    val settings: SettingsUi = SettingsUi(),
    val inputText: String = "",
    val isStreaming: Boolean = false,
    val sidebarOpen: Boolean = true,
    val detailsOpen: Boolean = false,
    val detailsTab: DetailsTab = DetailsTab.Tools,
)

@Serializable
enum class DetailsTab { Tools, Plan, Todo, Subagents, Settings }
