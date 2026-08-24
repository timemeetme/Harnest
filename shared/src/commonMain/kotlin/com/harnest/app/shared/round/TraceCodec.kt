package com.harnest.app.shared.round

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * 轨迹编解码：回合活动列表 ↔ 持久化 JSON（存进 assistant 消息的 traceJson 字段）。
 * Answer 预览不入轨迹——最终 assistant 正文即其完整形态。
 */
fun traceToJson(items: List<LiveItem>): String? {
    if (items.isEmpty()) return null
    val arr = buildJsonArray {
        for (item in items) {
            when (item) {
                is LiveItem.Think -> add(
                    buildJsonObject {
                        put("k", "think")
                        put("t", item.text)
                        put("s", item.step)
                        put("u", item.turn)
                    }
                )

                is LiveItem.Tool -> add(
                    buildJsonObject {
                        put("k", "tool")
                        put("n", item.name)
                        put("a", item.args)
                        put("s", item.status)
                        put("r", item.result)
                        put("ms", item.durationMs)
                    }
                )

                is LiveItem.Todos -> add(
                    buildJsonObject {
                        put("k", "todos")
                        put(
                            "l",
                            buildJsonArray {
                                item.items.forEach { (content, status) ->
                                    add(buildJsonArray { add(JsonPrimitive(content)); add(JsonPrimitive(status)) })
                                }
                            }
                        )
                    }
                )

                is LiveItem.Answer -> {}

                is LiveItem.Steer -> add(
                    buildJsonObject {
                        put("k", "steer")
                        put("t", item.text)
                    }
                )

                is LiveItem.Subagent -> add(
                    buildJsonObject {
                        put("k", "subagent")
                        put("rid", item.runId)
                        put("sq", item.agentSeq)
                        put("l", item.label)
                        put("p", item.phase)
                        put("o", item.outcome)
                    }
                )
            }
        }
    }
    return arr.toString()
}

/** 解析轨迹 JSON；空串/非法输入返回空列表。字段缺失按默认值兜底（向后兼容旧轨迹）。 */
fun parseTrace(json: String): List<LiveItem> {
    if (json.isEmpty()) return emptyList()
    return try {
        val arr = Json.parseToJsonElement(json).jsonArray
        arr.mapIndexedNotNull { i, el ->
            val o = el as? JsonObject ?: return@mapIndexedNotNull null
            when (o.str("k")) {
                "think" -> LiveItem.Think(i, o.int("s") ?: 0, o.str("t"), o.int("u") ?: 0)
                "steer" -> LiveItem.Steer(o.str("t"))
                "subagent" -> LiveItem.Subagent(o.str("rid"), o.str("sq"), o.str("l"), o.str("p"), o.str("o"))
                "tool" -> LiveItem.Tool(
                    "",
                    o.str("n"),
                    o.str("a"),
                    o.str("s").ifEmpty { "ok" },
                    o.str("r"),
                    o.long("ms") ?: 0L,
                )

                "todos" -> {
                    val l = o["l"] as? JsonArray ?: return@mapIndexedNotNull null
                    LiveItem.Todos(
                        l.mapNotNull { p ->
                            val pair = p as? JsonArray ?: return@mapNotNull null
                            (pair.getOrNull(0)?.jsonPrimitive?.contentOrNull ?: "") to
                                (pair.getOrNull(1)?.jsonPrimitive?.contentOrNull ?: "pending")
                        }
                    )
                }

                else -> null
            }
        }
    } catch (_: Throwable) {
        emptyList()
    }
}

private fun JsonObject.str(key: String): String = this[key]?.jsonPrimitive?.contentOrNull ?: ""

private fun JsonObject.int(key: String): Int? = this[key]?.jsonPrimitive?.intOrNull

private fun JsonObject.long(key: String): Long? = this[key]?.jsonPrimitive?.longOrNull
