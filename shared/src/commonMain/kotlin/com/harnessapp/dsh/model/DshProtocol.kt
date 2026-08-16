package com.harnessapp.dsh.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** InitializeParams: SDK 握手参数 */
@Serializable
data class InitializeParams(
    val cwd: String,
    val provider: String,
    val model: String,
    val maxTokens: Int? = null,
)

/** InitializeResult: 握手返回 */
@Serializable
data class InitializeResult(
    val serverInfo: ServerInfo,
)

@Serializable
data class ServerInfo(
    val name: String,
    val version: String,
)

/** SessionPromptParams: 发送用户消息 */
@Serializable
data class SessionPromptParams(
    val sessionId: String,
    val contentBlocks: List<JsonObject> = emptyList(),
)

/** SessionPromptResult: prompt 入队回执 */
@Serializable
data class SessionPromptResult(
    val messageId: String,
)

/** 会话事件通知 — 内核流式推送的完整会话日志事件 */
@Serializable
data class SessionEventNotification(
    val sessionId: String,
    val event: JsonObject,
)

/** Agent 运行状态通知 */
@Serializable
data class SessionStatusNotification(
    val sessionId: String,
    val status: AgentStatus,
)

@Serializable
enum class AgentStatus { idle, running }

/** Subagent 启动通知 */
@Serializable
data class SubagentStartedNotification(
    val parentSessionId: String,
    val childSessionId: String,
)

/** Subagent 完成通知 */
@Serializable
data class SubagentFinishedNotification(
    val provider: String,
    val agentId: String,
    val parentSessionId: String,
    val childSessionId: String,
    val status: SdkRunStatus,
    val stopReason: JsonObject,
    val lastAssistantMessage: List<JsonObject>? = null,
)

@Serializable
enum class SdkRunStatus { ok, error }

/** 所有服务端通知的联合类型 — 客户端分发器根据 method 决定反序列化目标 */
sealed interface DshNotification {
    data class SessionEvent(val payload: SessionEventNotification) : DshNotification
    data class SessionStatus(val payload: SessionStatusNotification) : DshNotification
    data class SubagentStarted(val payload: SubagentStartedNotification) : DshNotification
    data class SubagentFinished(val payload: SubagentFinishedNotification) : DshNotification
    data class Unknown(val method: String, val raw: JsonObject) : DshNotification
}
