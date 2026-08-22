package com.harnest.app.device

import kotlinx.serialization.json.JsonObject

/**
 * 设备能力统一入口（协议与 HarmonyOS DeviceBridge 的 op/args 完全对齐，见 doc/device-tools-design.md）。
 *
 * op ∈ status / permissions / contacts / calendar / clipboard / files / photos /
 *      mail / call / camera / recorder / app
 *
 * - Android：androidApp 的 AndroidDeviceTools（ContentResolver + Intent + MediaRecorder + ActivityResult）
 * - iOS：Phase 2（当前桩实现返回 unsupported）
 * - HarmonyOS：原生 DeviceBridge.ets（不经本接口，走 QuickJS 桥）
 * - PC relay（Phase 2）：DshClient 收到 WS device/call 帧后转发到本接口，device/result 回传内核
 */
interface DeviceTools {
    /** 执行一个设备能力调用；失败抛 DeviceToolsException（message 面向用户可读） */
    suspend fun call(op: String, args: JsonObject): JsonObject
}

/** 设备能力错误（权限被拒、op 不支持、参数缺失等） */
class DeviceToolsException(message: String) : Exception(message)

/** 各端声明的能力差异（status op 返回 capabilities 列表用） */
object DeviceCapabilities {
    const val CONTACTS = "contacts"
    const val CALENDAR = "calendar"
    const val CLIPBOARD = "clipboard"
    const val FILES = "files"
    const val PHOTOS = "photos"
    const val MAIL = "mail"
    const val CALL = "call"
    const val CAMERA = "camera"
    const val RECORDER = "recorder"
    const val APP = "app"
    const val GUI = "app-gui"

    fun list(): List<String> = listOf(
        CONTACTS, CALENDAR, CLIPBOARD, FILES, PHOTOS, MAIL, CALL, CAMERA, RECORDER, APP,
    )
}
