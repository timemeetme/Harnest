package com.harnest.app.shared.round

import kotlin.math.round
import kotlin.math.roundToInt

/**
 * 相邻思考段/回复段各归为一组，其余条目独立成组，供活动面板分层渲染
 * （每组一个折叠单元，避免信息过密）。
 */
fun groupLiveItems(items: List<LiveItem>): List<List<LiveItem>> {
    val groups = ArrayList<List<LiveItem>>(items.size)
    var i = 0
    while (i < items.size) {
        when (items[i]) {
            is LiveItem.Think, is LiveItem.Answer -> {
                val head = items[i]::class
                var j = i
                while (j < items.size && items[j]::class == head) j++
                groups.add(items.subList(i, j).toList())
                i = j
            }

            else -> {
                groups.add(listOf(items[i]))
                i++
            }
        }
    }
    return groups
}

/** 响应耗时格式化：832ms / 3.4s / 2分13秒（对齐 EyeMouthMind ChatBubble.fmtDuration）。 */
fun fmtDuration(ms: Long): String {
    if (ms < 1000) return "${ms}ms"
    if (ms < 60_000) {
        val tenths = ms / 100
        return "${tenths / 10}.${tenths % 10}s"
    }
    val m = ms / 60_000
    val sec = (ms % 60_000 + 500) / 1000
    return "${m}分${sec}秒"
}
