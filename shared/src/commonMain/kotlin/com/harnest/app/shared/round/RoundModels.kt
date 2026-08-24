package com.harnest.app.shared.round

/**
 * 回合数据模型（KMP 共享，Android/iOS 宿主可直接消费）。
 * HarmonyOS 为 ArkTS 宿主，通过内核 harness.js 消费同一套协议，见 [RoundProtocol]。
 */

/** 实时回合活动条目（内核 round 事件归并而来）：思考段 / 工具调用 / 待办快照 / 回复预览。 */
sealed class LiveItem {
    /** turn+step 双键定位段（内核事件自带；trace 持久化 "u"/"s"），跨 turn 同 step 序号不串段。 */
    data class Think(val seq: Int, val step: Int, val text: String, val turn: Int = 0) : LiveItem()
    data class Tool(
        val callId: String,
        val name: String,
        val args: String,
        val status: String,
        val result: String,
        val durationMs: Long = 0L,
    ) : LiveItem()

    data class Todos(val items: List<Pair<String, String>>) : LiveItem()

    /** 回复预览：与 Think 同构按 (turn,step) 分段（trace 不持久化，最终 assistant 正文为完整形态）。 */
    data class Answer(val text: String, val turn: Int = 0, val step: Int = 0) : LiveItem()

    /** k4 中途转向注入：实时面板展示 ⚡ 条目（内核下一 step 边界 claim，不入内核事件流）。 */
    data class Steer(val text: String) : LiveItem()

    /** k7 子代理/workflow 节点：tool-workflow/agent-start 建节点，agent-end 按 runId:agentSeq 补 outcome。 */
    data class Subagent(
        val runId: String,
        val agentSeq: String,
        val label: String,
        val phase: String = "",
        val outcome: String = "", // 空 = 运行中
    ) : LiveItem()
}

/** 内核 round 事件（宿主负责把平台 JSON 适配为这些强类型事件，见 Android MainActivity / 未来 iOS 桥）。 */
sealed class RoundEvent {
    /** 流式思考增量（同 (turn,step) 归并追加）。 */
    data class ThinkingDelta(val seq: Int, val step: Int, val text: String, val turn: Int = 0) : RoundEvent()

    /** 流式回复增量。 */
    data class AnswerDelta(val text: String) : RoundEvent()

    /** 整段思考兜底（completion 锚点，同 (turn,step) 幂等覆盖流式段）。 */
    data class ThinkingWhole(val seq: Int, val step: Int, val text: String, val turn: Int = 0) : RoundEvent()

    data class ToolStart(val callId: String, val name: String, val args: String) : RoundEvent()
    data class ToolEnd(val callId: String, val status: String, val result: String, val durationMs: Long) : RoundEvent()
    data class TodosSnapshot(val items: List<Pair<String, String>>) : RoundEvent()

    /** k7 子代理/workflow 生命周期。 */
    data class AgentStart(val runId: String, val agentSeq: String, val label: String, val phase: String) : RoundEvent()
    data class AgentEnd(val runId: String, val agentSeq: String, val outcome: String) : RoundEvent()
}

/** 回合统计（驱动 UI 动态提示，如“思考中 · 128 字”）。 */
class RoundStats(var thinkChars: Int = 0, var answerChars: Int = 0) {
    fun reset() {
        thinkChars = 0
        answerChars = 0
    }
}

/** 协议常量：round 事件 kind。三端宿主（Android/iOS/HarmonyOS）与内核 harness.js 统一遵守。 */
object RoundProtocol {
    const val KIND_THINKING_DELTA = "thinking-delta"
    const val KIND_ANSWER_DELTA = "answer-delta"
    const val KIND_THINKING = "thinking"
    const val KIND_TOOL_START = "tool-start"
    const val KIND_TOOL_END = "tool-end"
    const val KIND_TODOS = "todos"
}
