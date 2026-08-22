package com.harnest.app.shared.round

/**
 * 回合事件归并器：把内核 round 事件折叠进实时活动列表。
 *
 * 就地修改传入的 [items]（Android 端传 Compose SnapshotStateList 即可天然驱动重组；
 * iOS/HarmonyOS 端持普通列表，事件后自行通知刷新）。
 *
 * @return 本事件对应的状态提示文案（如“执行 device_probe…”），null 表示维持原提示不变。
 */
fun applyRoundEvent(items: MutableList<LiveItem>, event: RoundEvent, stats: RoundStats): String? {
    when (event) {
        is RoundEvent.ThinkingDelta -> {
            if (event.text.isEmpty()) return null
            val last = items.lastOrNull()
            if (last is LiveItem.Think && last.step == event.step) {
                items[items.size - 1] = last.copy(text = last.text + event.text)
            } else {
                items.add(LiveItem.Think(event.seq, event.step, event.text))
            }
            stats.thinkChars += event.text.length
            return "思考中 · ${stats.thinkChars} 字"
        }

        is RoundEvent.AnswerDelta -> {
            if (event.text.isEmpty()) return null
            val last = items.lastOrNull()
            if (last is LiveItem.Answer) {
                items[items.size - 1] = last.copy(text = last.text + event.text)
            } else {
                items.add(LiveItem.Answer(event.text))
            }
            stats.answerChars += event.text.length
            return "撰写回复 · ${stats.answerChars} 字"
        }

        is RoundEvent.ThinkingWhole -> {
            val last = items.lastOrNull()
            if (last is LiveItem.Think && last.step == event.step &&
                event.text.length >= last.text.length && event.text.startsWith(last.text)
            ) {
                items[items.size - 1] = last.copy(text = event.text)
            } else {
                items.add(LiveItem.Think(event.seq, event.step, event.text))
            }
            stats.thinkChars = items.filterIsInstance<LiveItem.Think>().sumOf { it.text.length }
            return "思考中 · ${stats.thinkChars} 字"
        }

        is RoundEvent.ToolStart -> {
            items.add(LiveItem.Tool(event.callId, event.name, event.args, "running", ""))
            return "执行 ${event.name}…"
        }

        is RoundEvent.ToolEnd -> {
            var idx = items.indexOfLast { it is LiveItem.Tool && it.callId == event.callId }
            if (idx < 0 && event.callId.isEmpty()) {
                idx = items.indexOfLast { it is LiveItem.Tool && it.status == "running" }
            }
            if (idx >= 0) {
                val old = items[idx] as LiveItem.Tool
                items[idx] = old.copy(status = event.status, result = event.result, durationMs = event.durationMs)
            }
            return null
        }

        is RoundEvent.TodosSnapshot -> {
            val item = LiveItem.Todos(event.items)
            val idx = items.indexOfLast { it is LiveItem.Todos }
            if (idx >= 0) items[idx] = item else items.add(item)
            return null
        }

        is RoundEvent.AgentStart -> {
            items.add(LiveItem.Subagent(event.runId, event.agentSeq, event.label, event.phase))
            return "子代理 ${event.label}…"
        }

        is RoundEvent.AgentEnd -> {
            val idx = items.indexOfLast {
                it is LiveItem.Subagent && it.runId == event.runId && it.agentSeq == event.agentSeq
            }
            if (idx >= 0) {
                val old = items[idx] as LiveItem.Subagent
                items[idx] = old.copy(outcome = event.outcome)
            }
            return null
        }
    }
}
