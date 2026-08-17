package com.harnest.app.dsh.model

/** Agent 运行状态 */
enum class AgentStatus { Idle, Running }

/** Subagent 运行状态 */
enum class SdkRunStatus { Ok, Error }

/** 所有服务端通知的联合类型 — 来自 WebSocket /api/events.mux 下行 */
sealed interface DshNotification {
    data class SessionEvent(val sessionId: String, val event: Map<String, Any?>) : DshNotification
    data class SessionStatus(val sessionId: String, val status: AgentStatus) : DshNotification
    data class SubagentStarted(val parentSessionId: String, val childSessionId: String) : DshNotification
    data class SubagentFinished(val childSessionId: String, val status: SdkRunStatus) : DshNotification
    data class Unknown(val method: String, val raw: Map<String, Any?>) : DshNotification
}
