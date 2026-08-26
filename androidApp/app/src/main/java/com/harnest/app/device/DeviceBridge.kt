package com.harnest.app.device

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.harnest.app.engine.FsBridge
import com.harnest.app.engine.HarnessEngine
import com.harnest.app.engine.ScriptSandbox
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** UI operations the bridge needs from the host Activity (pickers / permissions). */
interface UiLauncher {
    fun runOnUi(block: () -> Unit)
    fun hasPermission(perm: String): Boolean
    suspend fun requestPermission(perm: String): Boolean
    suspend fun takePicture(): String?
    suspend fun pickImage(): String?
    suspend fun pickDocument(mime: String?): String?
    suspend fun pickSaveLocation(name: String): String?
    fun cancelPending()
}

/**
 * Android port of DeviceBridge.ets — all 21 ops.
 * Runs on its own IO scope; results reported via callback (never blocks the JS thread).
 */
class DeviceBridge(
    private val context: Context,
    private val launcher: UiLauncher,
    private val engine: HarnessEngine,
) {
    companion object {
        private const val TAG = "DeviceBridge"
        private val CAPABILITIES = listOf(
            "contacts", "calendar", "clipboard", "files", "photos", "mail", "call",
            "sms", "camera", "recorder", "app", "network", "deviceinfo", "vibrate",
            "location", "settings", "reminder", "gui", "scheduler", "share",
        )
        private const val INTERACTIVE_TIMEOUT_MS = 120_000L
        private val INTERACTIVE_TOOLS = setOf(
            "camera", "photos", "files", "permissions", "contacts", "calendar", "location",
        )
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val recorder = DeviceRecorder(context)
    private val reminders = DeviceReminder(context)

    /** Busy-hint tap: invoked with the tool name whenever a device tool starts. */
    @Volatile
    var onToolStart: ((String) -> Unit)? = null

    fun dispatch(id: Int, reqJson: String, report: (ok: Boolean, json: String) -> Unit) {
        scope.launch {
            val (ok, json) = try {
                handle(id, reqJson)
            } catch (e: Throwable) {
                Log.e(TAG, "op failed", e)
                Pair(false, JSONObject().put("error", e.message ?: "op failed").toString())
            }
            report(ok, json)
        }
    }

    private suspend fun handle(id: Int, reqJson: String): Pair<Boolean, String> {
        val req = JSONObject(reqJson)
        val op = req.optString("op", "")
        val tool = req.optString("tool", op.ifEmpty { "unknown" })
        val args = req.optJSONObject("args") ?: JSONObject()
        onToolStart?.invoke(tool)
        val out = if (tool in INTERACTIVE_TOOLS) softInteractive(tool) { execute(tool, args) } else execute(tool, args)
        val code = out.optInt("code", if (out.optBoolean("ok", true)) 0 else 1)
        return Pair(code == 0, out.toString())
    }

    /**
     * 交互类工具软超时：等待 120s 仍无用户操作时不终止回合，
     * 而是把「已等待 120s」作为工具结果告知模型，由模型决策（再等/换方案/收尾）。
     */
    private suspend fun softInteractive(tool: String, block: suspend () -> JSONObject): JSONObject {
        val res = withTimeoutOrNull(INTERACTIVE_TIMEOUT_MS) { block() }
        if (res != null) return res
        launcher.cancelPending()
        return JSONObject()
            .put("ok", false)
            .put("timeout", true)
            .put("waitedMs", INTERACTIVE_TIMEOUT_MS)
            .put(
                "error",
                "interactive tool '$tool' waited 120s with no user action — the user may be away. " +
                    "You decide what to do next: (a) call the same tool again to keep waiting, " +
                    "(b) switch to an alternative that needs no user interaction, or " +
                    "(c) summarize progress and end the turn.",
            )
    }

    // ── dispatch table ───────────────────────────────────────

    private suspend fun execute(tool: String, args: JSONObject): JSONObject {
        return when (tool) {
            "status" -> opStatus()
            "permissions" -> opPermissions(args)
            "contacts" -> DeviceProviders.contacts(context, launcher, args)
            "calendar" -> DeviceProviders.calendar(context, launcher, args)
            "clipboard" -> opClipboard(args)
            "files" -> opFiles(args)
            "photos" -> DeviceMedia.photos(context, launcher, args)
            "mail" -> opMail(args)
            "call" -> DeviceProviders.call(context, launcher, args)
            "sms" -> DeviceProviders.sms(context, launcher, args)
            "camera" -> DeviceMedia.camera(context, launcher, args)
            "recorder" -> recorder.op(args)
            "app" -> opApp(args)
            "network" -> opNetwork()
            "deviceinfo" -> opDeviceInfo()
            "vibrate" -> opVibrate(args)
            "location" -> opLocation(args)
            "settings" -> opSettings(args)
            "reminder" -> reminders.op(args)
            "gui" -> GuiBridge.execute(context, args)
            "scheduler" -> DeviceScheduler.op(context, args)
            "share" -> opShare(args)
            "runScript" -> opRunScript(args)
            else -> JSONObject().put("ok", false).put("error", "unknown tool: $tool")
        }
    }

    // ── ops ──────────────────────────────────────────────────

    private fun opStatus(): JSONObject {
        return JSONObject()
            .put("ok", true)
            .put("engine", "harness-android")
            .put("platform", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            .put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("app", context.packageName)
            .put("capabilities", JSONArray(CAPABILITIES))
            .put("note", "Android port of the Harness device bridge — same tool contract as the HarmonyOS version; gui requires the accessibility service to be enabled in system settings")
    }

    /** run_script：JS 沙箱执行（ScriptSandbox 专用 QuickJS，文件锁 filesDir/scripts 内）。
     *  阻塞至脚本 settle 或超时（上限 120s），结果 {ok,result,stdout,stdoutTruncated,timedOut,durationMs,error?}。 */
    private fun opRunScript(args: JSONObject): JSONObject {
        val code = args.optString("code", "")
        if (code.isEmpty()) return JSONObject().put("ok", false).put("error", "code is required")
        val timeoutMs = args.optLong("timeoutMs", 60_000L).coerceIn(1_000L, 120_000L)
        val res = ScriptSandbox.get(context).runSync(code, timeoutMs)
        val out = JSONObject()
            .put("ok", res["ok"] == true)
            .put("result", res["result"] as? String ?: "")
            .put("stdout", res["stdout"] as? String ?: "")
            .put("stdoutTruncated", res["stdoutTruncated"] == true)
            .put("timedOut", res["timedOut"] == true)
            .put("durationMs", res["durationMs"] as? Long ?: 0L)
        @Suppress("UNCHECKED_CAST")
        val files = res["files"] as? List<String> ?: emptyList()
        out.put("files", JSONArray(files))
        val err = res["error"] as? String
        if (!err.isNullOrEmpty()) out.put("error", err)
        return out
    }

    private suspend fun opPermissions(args: JSONObject): JSONObject {
        val op = args.optString("op", "list")
        val map: Map<String, String> = mapOf(
            "contacts" to Manifest.permission.READ_CONTACTS,
            "contactsWrite" to Manifest.permission.WRITE_CONTACTS,
            "calendar" to Manifest.permission.READ_CALENDAR,
            "calendarWrite" to Manifest.permission.WRITE_CALENDAR,
            "location" to Manifest.permission.ACCESS_FINE_LOCATION,
            "microphone" to Manifest.permission.RECORD_AUDIO,
            "sms" to Manifest.permission.READ_SMS,
            "callLog" to Manifest.permission.READ_CALL_LOG,
            "notifications" to Manifest.permission.POST_NOTIFICATIONS,
        )
        if (op == "list") {
            val arr = JSONArray()
            map.forEach { (name, perm) ->
                arr.put(JSONObject().put("name", name).put("granted", launcher.hasPermission(perm)))
            }
            return JSONObject().put("ok", true).put("permissions", arr)
        }
        if (op == "request") {
            val name = args.optString("name", "")
            val perm = map[name] ?: return JSONObject().put("ok", false).put("error", "unknown permission: $name")
            val granted = launcher.requestPermission(perm)
            return JSONObject().put("ok", true).put("name", name).put("granted", granted)
        }
        return JSONObject().put("ok", false).put("error", "unknown op: $op")
    }

    private fun opClipboard(args: JSONObject): JSONObject {
        val op = args.optString("op", "read")
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        if (op == "read") {
            val clip = cm.primaryClip
            val text = if (clip != null && clip.itemCount > 0) clip.getItemAt(0)?.text?.toString() ?: "" else ""
            return JSONObject().put("ok", true).put("text", text).put("empty", text.isEmpty())
        }
        if (op == "write") {
            val text = args.optString("text", "")
            cm.setPrimaryClip(android.content.ClipData.newPlainText("harness", text))
            return JSONObject().put("ok", true)
        }
        return JSONObject().put("ok", false).put("error", "unknown op: $op")
    }

    private suspend fun opFiles(args: JSONObject): JSONObject {
        val op = args.optString("op", "list")
        if (op == "pick") {
            val uri = launcher.pickDocument(args.optString("mime", "").ifEmpty { null }) ?: return JSONObject().put("ok", false).put("cancelled", true)
            return openContentAndStore(uri, args.optString("name", "picked"))
        }
        if (op == "save") {
            val name = args.optString("name", "file.txt")
            val target = launcher.pickSaveLocation(name) ?: return JSONObject().put("ok", false).put("cancelled", true)
            return JSONObject().put("ok", true).put("uri", target).put("name", name)
                .put("note", "SAF location selected; write the file with op=writeSaf uri=<this>")
        }
        if (op == "writeSaf") {
            val uri = args.optString("uri", "")
            val data = args.optString("data", "")
            return try {
                context.contentResolver.openOutputStream(android.net.Uri.parse(uri), "wt")?.use { os ->
                    val isB64 = args.optBoolean("base64", false)
                    val bytes = if (isB64) android.util.Base64.decode(data, android.util.Base64.NO_WRAP) else data.toByteArray(Charsets.UTF_8)
                    os.write(bytes)
                } ?: return JSONObject().put("ok", false).put("error", "cannot open uri")
                JSONObject().put("ok", true)
            } catch (e: Throwable) {
                JSONObject().put("ok", false).put("error", e.message)
            }
        }
        // sandbox ops delegate to FsBridge with a synthetic request
        val fsReq = JSONObject().put("op", op).put("path", args.optString("path", ""))
            .put("data", args.optString("data", "")).put("base64", args.optBoolean("base64", false))
        val result = FsBridge.handle(engine, fsReq.toString())
        return JSONObject(result)
    }

    private fun openContentAndStore(uriStr: String, name: String): JSONObject {
        return try {
            val uri = android.net.Uri.parse(uriStr)
            val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: return JSONObject().put("ok", false).put("error", "cannot open $uriStr")
            val scriptsRoot = ScriptSandbox.get(context).scriptsRoot
            val relPath = "picked/${System.currentTimeMillis()}_$name"
            val file = File(scriptsRoot, relPath)
            file.parentFile?.mkdirs()
            file.writeBytes(bytes)
            JSONObject().put("ok", true).put("path", relPath)
                .put("size", bytes.size).put("uri", uriStr)
        } catch (e: Throwable) {
            JSONObject().put("ok", false).put("error", e.message)
        }
    }

    private fun opMail(args: JSONObject): JSONObject {
        val to = args.optString("to", "")
        val subject = args.optString("subject", "")
        val body = args.optString("body", "")
        val intent = Intent(Intent.ACTION_SENDTO).apply {
            data = android.net.Uri.parse("mailto:")
            putExtra(Intent.EXTRA_EMAIL, arrayOf(to))
            putExtra(Intent.EXTRA_SUBJECT, subject)
            putExtra(Intent.EXTRA_TEXT, body)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            context.startActivity(intent)
            JSONObject().put("ok", true).put("launched", true)
                .put("note", "mail composer opened; the user sends it")
        } catch (e: Throwable) {
            JSONObject().put("ok", false).put("error", "no mail app: ${e.message}")
        }
    }

    private fun opApp(args: JSONObject): JSONObject {
        val op = args.optString("op", "list")
        if (op == "list") {
            val pm = context.packageManager
            val arr = JSONArray()
            pm.getInstalledPackages(0).forEach { pi ->
                if (pm.getLaunchIntentForPackage(pi.packageName) != null) {
                    val label = pi.applicationInfo?.let { pm.getApplicationLabel(it)?.toString() } ?: pi.packageName
                    arr.put(JSONObject().put("package", pi.packageName).put("name", label))
                }
            }
            return JSONObject().put("ok", true).put("apps", arr)
        }
        if (op == "open") {
            val pkg = args.optString("package", args.optString("bundleName", ""))
            val intent = context.packageManager.getLaunchIntentForPackage(pkg)
                ?: return JSONObject().put("ok", false).put("error", "app not found or not launchable: $pkg")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            return try {
                context.startActivity(intent)
                JSONObject().put("ok", true).put("launched", true)
            } catch (e: Throwable) {
                JSONObject().put("ok", false).put("error", e.message)
            }
        }
        return JSONObject().put("ok", false).put("error", "unknown op: $op")
    }

    private fun opNetwork(): JSONObject {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        val type = when {
            caps == null -> "none"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
        val down = caps?.linkDownstreamBandwidthKbps ?: -1
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        return JSONObject().put("ok", true).put("type", type).put("downstreamKbps", down)
            .put("carrier", tm?.networkOperatorName ?: "").put("online", caps != null)
    }

    private fun opDeviceInfo(): JSONObject {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val charging = bm.isCharging
        return JSONObject().put("ok", true)
            .put("brand", Build.BRAND).put("model", Build.MODEL)
            .put("os", "Android ${Build.VERSION.RELEASE}").put("apiLevel", Build.VERSION.SDK_INT)
            .put("batteryLevel", level).put("charging", charging)
    }

    private fun opVibrate(args: JSONObject): JSONObject {
        val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= 31) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        val pattern = args.optString("pattern", "short")
        val millis = when (pattern) {
            "short" -> 200L
            "double" -> 0L
            "long" -> 800L
            else -> args.optLong("millis", 200L)
        }
        if (!vibrator.hasVibrator()) return JSONObject().put("ok", false).put("error", "no vibrator")
        if (pattern == "double") {
            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 150, 120, 150), -1))
        } else {
            vibrator.vibrate(VibrationEffect.createOneShot(millis, VibrationEffect.DEFAULT_AMPLITUDE))
        }
        return JSONObject().put("ok", true)
    }

    private suspend fun opLocation(args: JSONObject): JSONObject {
        if (!launcher.requestPermission(Manifest.permission.ACCESS_FINE_LOCATION)) {
            return JSONObject().put("ok", false).put("error", "location permission denied")
        }
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as android.location.LocationManager
        val last = listOf(
            android.location.LocationManager.GPS_PROVIDER,
            android.location.LocationManager.NETWORK_PROVIDER,
            android.location.LocationManager.PASSIVE_PROVIDER,
        ).firstNotNullOfOrNull { p -> try { lm.getLastKnownLocation(p) } catch (_: SecurityException) { null } }
        if (last != null) return locationJson(last)
        if (Build.VERSION.SDK_INT < 30) {
            return JSONObject().put("ok", false).put("error", "fresh fix requires Android 11+")
        }
        return try {
            kotlinx.coroutines.suspendCancellableCoroutine { cont ->
                val consumer = java.util.function.Consumer<android.location.Location?> { loc ->
                    val result = loc?.let { locationJson(it) }
                        ?: JSONObject().put("ok", false).put("error", "no location available")
                    cont.resumeWith(Result.success(result))
                }
                lm.getCurrentLocation(
                    android.location.LocationManager.NETWORK_PROVIDER,
                    android.os.CancellationSignal(),
                    context.mainExecutor,
                    consumer,
                )
            }
        } catch (e: Throwable) {
            JSONObject().put("ok", false).put("error", e.message)
        }
    }

    private fun locationJson(loc: android.location.Location): JSONObject = JSONObject()
        .put("ok", true).put("latitude", loc.latitude).put("longitude", loc.longitude)
        .put("accuracy", loc.accuracy.toDouble()).put("provider", loc.provider ?: "")

    private fun opSettings(args: JSONObject): JSONObject {
        val page = args.optString("page", "main")
        val intent = when (page) {
            "wifi" -> Settings.ACTION_WIFI_SETTINGS
            "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
            "location" -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
            "accessibility" -> Settings.ACTION_ACCESSIBILITY_SETTINGS
            "apps" -> Settings.ACTION_APPLICATION_SETTINGS
            "notification" -> Settings.ACTION_ALL_APPS_NOTIFICATION_SETTINGS
            "battery" -> Settings.ACTION_BATTERY_SAVER_SETTINGS
            "main" -> Settings.ACTION_SETTINGS
            else -> return JSONObject().put("ok", false).put("error", "unknown page: $page")
        }
        return try {
            context.startActivity(Intent(intent).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            JSONObject().put("ok", true).put("launched", true)
        } catch (e: Throwable) {
            JSONObject().put("ok", false).put("error", e.message)
        }
    }

    private fun opShare(args: JSONObject): JSONObject {
        val text = args.optString("text", "")
        val title = args.optString("title", "Share")
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            putExtra(Intent.EXTRA_TITLE, title)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            context.startActivity(Intent.createChooser(intent, title).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            JSONObject().put("ok", true).put("launched", true)
        } catch (e: Throwable) {
            JSONObject().put("ok", false).put("error", e.message)
        }
    }
}
