package com.harnest.app.device

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * iOS 设备能力桩实现（Phase 2 接 EventKit/Contacts/Photos/AVFoundation 真实现）。
 * 协议与 Android/HarmonyOS 对齐：op + args(JsonObject) → JsonObject。
 * 当前仅 status 可用；其余 op 抛 DeviceToolsException，上层（自测/relay）可直接展示原因。
 */
class IosDeviceTools : DeviceTools {

    override suspend fun call(op: String, args: JsonObject): JsonObject = when (op) {
        "status" -> buildJsonObject {
            put("platform", "ios")
            put("phase", "stub")
            putJsonArray("capabilities") {
                // 真实现落地前，能力列表保持为空（status 之外全部 unsupported）
            }
            putJsonObject("hint") {
                put("message", "iOS device tools arrive in phase 2 (EventKit / Contacts / Photos / AVFoundation)")
            }
        }
        else -> throw DeviceToolsException("ios device op '$op' not yet implemented (phase 2)")
    }
}
