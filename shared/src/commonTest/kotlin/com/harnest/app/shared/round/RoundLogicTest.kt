package com.harnest.app.shared.round

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RoundLogicTest {

    @Test
    fun deltaMergesSameStepThink() {
        val items = mutableListOf<LiveItem>()
        val stats = RoundStats()
        applyRoundEvent(items, RoundEvent.ThinkingDelta(1, 0, "你"), stats)
        applyRoundEvent(items, RoundEvent.ThinkingDelta(1, 0, "好"), stats)
        assertEquals(1, items.size)
        assertEquals("你好", (items[0] as LiveItem.Think).text)
        assertEquals(2, stats.thinkChars)
        assertEquals("思考中 · 3 字", applyRoundEvent(items, RoundEvent.ThinkingDelta(1, 0, "!"), stats))
    }

    @Test
    fun differentStepStartsNewSegment() {
        val items = mutableListOf<LiveItem>()
        val stats = RoundStats()
        applyRoundEvent(items, RoundEvent.ThinkingDelta(1, 0, "a"), stats)
        applyRoundEvent(items, RoundEvent.ToolStart("c1", "device_probe", "{}"), stats)
        applyRoundEvent(items, RoundEvent.ThinkingDelta(2, 1, "b"), stats)
        assertEquals(3, items.size)
        assertEquals(1, (items[2] as LiveItem.Think).step)
    }

    @Test
    fun thinkingWholeOverridesStreamingPrefix() {
        val items = mutableListOf<LiveItem>()
        val stats = RoundStats()
        applyRoundEvent(items, RoundEvent.ThinkingDelta(3, 0, "hel"), stats)
        applyRoundEvent(items, RoundEvent.ThinkingWhole(3, 0, "hello world"), stats)
        assertEquals(1, items.size)
        assertEquals("hello world", (items[0] as LiveItem.Think).text)
        assertEquals(11, stats.thinkChars)
    }

    @Test
    fun toolEndUpdatesByCallIdAndKeepsOthersRunning() {
        val items = mutableListOf<LiveItem>()
        val stats = RoundStats()
        applyRoundEvent(items, RoundEvent.ToolStart("c1", "device_probe", "{}"), stats)
        applyRoundEvent(items, RoundEvent.ToolStart("c2", "device_capabilities_query", "{}"), stats)
        assertNull(applyRoundEvent(items, RoundEvent.ToolEnd("c1", "ok", "{\"os\":13}", 1200), stats))
        val t1 = items[0] as LiveItem.Tool
        assertEquals("ok", t1.status)
        assertEquals(1200L, t1.durationMs)
        assertEquals("running", (items[1] as LiveItem.Tool).status)
    }

    @Test
    fun answerDeltaAppendsIntoOneSegment() {
        val items = mutableListOf<LiveItem>()
        val stats = RoundStats()
        applyRoundEvent(items, RoundEvent.AnswerDelta("Hel"), stats)
        applyRoundEvent(items, RoundEvent.AnswerDelta("lo"), stats)
        assertEquals(1, items.size)
        assertEquals("Hello", (items[0] as LiveItem.Answer).text)
        assertEquals(5, stats.answerChars)
    }

    @Test
    fun todosSnapshotReplacesInPlace() {
        val items = mutableListOf<LiveItem>()
        val stats = RoundStats()
        applyRoundEvent(items, RoundEvent.TodosSnapshot(listOf("a" to "pending")), stats)
        applyRoundEvent(items, RoundEvent.TodosSnapshot(listOf("a" to "completed", "b" to "pending")), stats)
        assertEquals(1, items.filterIsInstance<LiveItem.Todos>().size)
        assertEquals(listOf("a" to "completed", "b" to "pending"), (items[0] as LiveItem.Todos).items)
    }

    @Test
    fun traceRoundTripPreservesItems() {
        val json = """[{"k":"think","t":"想","s":0},{"k":"tool","n":"probe","a":"{}","s":"ok","r":"R","ms":1500},{"k":"todos","l":[["a","completed"],["b","pending"]]}]"""
        val items = parseTrace(json)
        assertEquals(3, items.size)
        val out = traceToJson(items)
        assertTrue(out != null)
        assertEquals(items, parseTrace(out!!))
        assertTrue(items[1] is LiveItem.Tool && (items[1] as LiveItem.Tool).durationMs == 1500L)
    }

    @Test
    fun parseTraceToleratesGarbage() {
        assertEquals(0, parseTrace("").size)
        assertEquals(0, parseTrace("not json").size)
        assertEquals(0, parseTrace("[1,2,3]").size)
    }

    @Test
    fun fmtDurationCoversMsSecMin() {
        assertEquals("832ms", fmtDuration(832))
        assertEquals("3.4s", fmtDuration(3400))
        assertEquals("2分13秒", fmtDuration(133000))
    }

    @Test
    fun groupingSplitsThinkAndAnswerBlocks() {
        val items = listOf(
            LiveItem.Think(0, 0, "a"),
            LiveItem.Think(1, 0, "b"),
            LiveItem.Tool("c1", "probe", "{}", "ok", "r"),
            LiveItem.Answer("ans"),
        )
        val groups = groupLiveItems(items)
        assertEquals(3, groups.size)
        assertEquals(2, groups[0].size)
        assertEquals(1, groups[1].size)
        assertEquals(1, groups[2].size)
    }
}
