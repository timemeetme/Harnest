package com.harnest.app.device

import android.Manifest
import android.annotation.SuppressLint
import android.content.ContentProviderOperation
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaRecorder
import android.net.Uri
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.io.File
import java.util.TimeZone
import kotlin.coroutines.resume
import kotlin.math.min

/**
 * Android 设备能力实现（Phase 1：自测界面直调；Phase 2：WS device/call 帧 relay）。
 * 协议与 HarmonyOS DeviceBridge.ets 对齐：op + args(JsonObject) → JsonObject。
 *
 * 安全原则：全部走免敏感权限路径 —
 * - 拨号/短信/邮件只预填拉起系统 UI（ACTION_DIAL / ACTION_SENDTO），不做直拨（CALL_PHONE）
 * - 拍照用系统相机返回预览图（免 CAMERA 权限声明）
 * - 文件/相册选择用系统 picker（免 MANAGE_EXTERNAL_STORAGE）
 */
class AndroidDeviceTools(private val activity: ComponentActivity) : DeviceTools {

    private val resolver = activity.contentResolver

    // ---- 权限映射（scope → manifest 权限） ----
    private val scopePermissions = mapOf(
        "contacts" to listOf(Manifest.permission.READ_CONTACTS, Manifest.permission.WRITE_CONTACTS),
        "calendar" to listOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR),
        "microphone" to listOf(Manifest.permission.RECORD_AUDIO),
        "camera" to listOf(Manifest.permission.CAMERA),
        "sms" to listOf(Manifest.permission.READ_SMS),
    )

    // ---- Activity 结果桥（launcher 必须在 Activity STARTED 前注册，故构造时一次注册） ----
    private var permissionSink: ((Map<String, Boolean>) -> Unit)? = null
    private val permissionLauncher =
        activity.registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
            permissionSink?.invoke(grants)
            permissionSink = null
        }

    private var openDocSink: ((Uri?) -> Unit)? = null
    private val openDocLauncher =
        activity.registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            openDocSink?.invoke(uri)
            openDocSink = null
        }

    private var pickMediaSink: ((Uri?) -> Unit)? = null
    private val pickMediaLauncher =
        activity.registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
            pickMediaSink?.invoke(uri)
            pickMediaSink = null
        }

    private var takePreviewSink: ((Bitmap?) -> Unit)? = null
    private val takePreviewLauncher =
        activity.registerForActivityResult(ActivityResultContracts.TakePicturePreview()) { bmp ->
            takePreviewSink?.invoke(bmp)
            takePreviewSink = null
        }

    // ---- 录音状态 ----
    private var recorder: MediaRecorder? = null
    private var recorderFile: File? = null
    private var recorderStartMs: Long = 0
    private var recorderTimer: kotlinx.coroutines.Job? = null
    private val scope = kotlinx.coroutines.CoroutineScope(
        kotlinx.coroutines.SupervisorJob() + Dispatchers.Main,
    )

    /** 释放资源（Activity onDestroy 调用）：停录音、取消定时器 */
    fun dispose() {
        recorderTimer?.cancel()
        recorderTimer = null
        stopRecorderInternal()
        scope.cancel()
    }

    // ---- 入口 ----
    override suspend fun call(op: String, args: JsonObject): JsonObject = withContext(Dispatchers.Main) {
        when (op) {
            "status" -> opStatus()
            "permissions" -> opPermissions(args)
            "contacts" -> opContacts(args)
            "calendar" -> opCalendar(args)
            "clipboard" -> opClipboard(args)
            "files" -> opFiles(args)
            "photos" -> opPhotos(args)
            "mail" -> opMail(args)
            "call" -> opCall(args)
            "sms" -> opSms(args)
            "camera" -> opCamera(args)
            "recorder" -> opRecorder(args)
            "app" -> opApp(args)
            else -> throw DeviceToolsException("unknown op: $op")
        }
    }

    // ---- status ----
    private fun opStatus(): JsonObject = buildJsonObject {
        put("platform", "android")
        putJsonArray("capabilities") {
            DeviceCapabilities.list().forEach { add(it) }
        }
        putJsonArray("permissions") {
            scopePermissions.forEach { (scope, perms) ->
                perms.forEach { p ->
                    add(
                        buildJsonObject {
                            put("scope", scope)
                            put("permission", p)
                            put(
                                "granted",
                                ContextCompat.checkSelfPermission(
                                    activity, p,
                                ) == android.content.pm.PackageManager.PERMISSION_GRANTED,
                            )
                        },
                    )
                }
            }
        }
    }

    // ---- permissions ----
    private suspend fun opPermissions(args: JsonObject): JsonObject {
        val action = args.str("action") ?: "query"
        if (action == "request") {
            scopePermissions.keys.forEach { scope -> ensureScope(scope) }
        }
        return buildJsonObject {
            putJsonArray("granted") {
                scopePermissions.values.flatten().distinct().forEach { p ->
                    if (ContextCompat.checkSelfPermission(activity, p) ==
                        android.content.pm.PackageManager.PERMISSION_GRANTED
                    ) add(p)
                }
            }
            putJsonArray("denied") {
                scopePermissions.values.flatten().distinct().forEach { p ->
                    if (ContextCompat.checkSelfPermission(activity, p) !=
                        android.content.pm.PackageManager.PERMISSION_GRANTED
                    ) add(p)
                }
            }
        }
    }

    private suspend fun ensureScope(scope: String) {
        val perms = scopePermissions[scope] ?: return
        val missing = perms.filter {
            ContextCompat.checkSelfPermission(activity, it) != android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) return
        val grants = suspendCancellableCoroutine { cont ->
            permissionSink = { cont.resume(it) }
            permissionLauncher.launch(missing.toTypedArray())
        }
        val denied = grants.filterValues { !it }.keys
        if (denied.isNotEmpty()) {
            throw DeviceToolsException("permission denied: ${denied.joinToString()}")
        }
    }

    // ---- contacts ----
    @SuppressLint("Range")
    private suspend fun opContacts(args: JsonObject): JsonObject {
        val sub = args.str("op") ?: "query"
        when (sub) {
            "query" -> {
                ensureScope("contacts")
                val limit = args.int("limit") ?: 20
                return withContext(Dispatchers.IO) {
                    val contacts = mutableListOf<JsonObject>()
                    resolver.query(
                        ContactsContract.Contacts.CONTENT_URI,
                        arrayOf(
                            ContactsContract.Contacts._ID,
                            ContactsContract.Contacts.DISPLAY_NAME,
                            ContactsContract.Contacts.HAS_PHONE_NUMBER,
                        ),
                        null, null,
                        "${ContactsContract.Contacts.DISPLAY_NAME} ASC",
                    )?.use { c ->
                        while (c.moveToNext() && contacts.size < limit) {
                            val id = c.getLong(0)
                            val name = c.getString(1) ?: ""
                            val hasPhone = c.getInt(2) > 0
                            val phones = mutableListOf<String>()
                            if (hasPhone) {
                                resolver.query(
                                    ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                                    arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
                                    "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
                                    arrayOf(id.toString()), null,
                                )?.use { p ->
                                    while (p.moveToNext() && phones.size < 3) {
                                        p.getString(0)?.let { phones.add(it) }
                                    }
                                }
                            }
                            contacts.add(buildJsonObject {
                                put("id", id.toString())
                                put("name", name)
                                putJsonArray("phones") { phones.forEach { add(it) } }
                            })
                        }
                    }
                    buildJsonObject {
                        putJsonArray("contacts") { contacts.forEach { add(it) } }
                        put("count", contacts.size)
                    }
                }
            }
            "create" -> {
                ensureScope("contacts")
                val name = args.str("name") ?: throw DeviceToolsException("name required")
                val phones = args.strList("phones")
                val ops = arrayListOf(
                    ContentProviderOperation.newInsert(ContactsContract.RawContacts.CONTENT_URI)
                        .withValue(ContactsContract.RawContacts.ACCOUNT_TYPE, null)
                        .withValue(ContactsContract.RawContacts.ACCOUNT_NAME, null)
                        .build(),
                    ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                        .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                        .withValue(
                            ContactsContract.Data.MIMETYPE,
                            ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE,
                        )
                        .withValue(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME, name)
                        .build(),
                )
                phones.forEach { phone ->
                    ops.add(
                        ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                            .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                            .withValue(
                                ContactsContract.Data.MIMETYPE,
                                ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE,
                            )
                            .withValue(ContactsContract.CommonDataKinds.Phone.NUMBER, phone)
                            .withValue(
                                ContactsContract.CommonDataKinds.Phone.TYPE,
                                ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE,
                            )
                            .build(),
                    )
                }
                val results = resolver.applyBatch(ContactsContract.AUTHORITY, ops)
                val rawUri = results.firstOrNull()?.uri
                    ?: throw DeviceToolsException("create contact failed (no result uri)")
                val rawId = rawUri.lastPathSegment ?: throw DeviceToolsException("create contact failed (no raw id)")
                // raw → contact id（delete 用）
                var contactId = rawId
                resolver.query(
                    ContactsContract.RawContacts.CONTENT_URI,
                    arrayOf(ContactsContract.RawContacts.CONTACT_ID),
                    "${ContactsContract.RawContacts._ID} = ?", arrayOf(rawId), null,
                )?.use { c ->
                    if (c.moveToFirst()) contactId = c.getLong(0).toString()
                }
                return buildJsonObject { put("id", contactId); put("name", name) }
            }
            "delete" -> {
                ensureScope("contacts")
                val id = args.str("id") ?: throw DeviceToolsException("id required")
                val deleted = resolver.delete(
                    ContactsContract.Contacts.CONTENT_URI.buildUpon().appendPath(id).build(), null, null,
                )
                return buildJsonObject { put("deleted", deleted) }
            }
            else -> throw DeviceToolsException("unknown contacts op: $sub")
        }
    }

    // ---- calendar ----
    private suspend fun opCalendar(args: JsonObject): JsonObject {
        val sub = args.str("op") ?: "query"
        when (sub) {
            "query" -> {
                ensureScope("calendar")
                val now = System.currentTimeMillis()
                val begin = args.long("begin") ?: (now - 7L * 24 * 3600 * 1000)
                val end = args.long("end") ?: (now + 7L * 24 * 3600 * 1000)
                return withContext(Dispatchers.IO) {
                    val events = mutableListOf<JsonObject>()
                    val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
                        .appendPath(begin.toString()).appendPath(end.toString()).build()
                    resolver.query(
                        uri,
                        arrayOf(
                            CalendarContract.Instances.EVENT_ID,
                            CalendarContract.Instances.TITLE,
                            CalendarContract.Instances.DESCRIPTION,
                            CalendarContract.Instances.BEGIN,
                            CalendarContract.Instances.END,
                            CalendarContract.Instances.ALL_DAY,
                        ),
                        null, null, "${CalendarContract.Instances.BEGIN} ASC",
                    )?.use { c ->
                        while (c.moveToNext() && events.size < 50) {
                            events.add(buildJsonObject {
                                put("id", c.getLong(0).toString())
                                put("title", c.getString(1) ?: "")
                                put("notes", c.getString(2) ?: "")
                                put("begin", c.getLong(3))
                                put("end", c.getLong(4))
                                put("allDay", c.getInt(5) == 1)
                            })
                        }
                    }
                    buildJsonObject {
                        putJsonArray("events") { events.forEach { add(it) } }
                        put("count", events.size)
                    }
                }
            }
            "create" -> {
                ensureScope("calendar")
                val title = args.str("title") ?: throw DeviceToolsException("title required")
                val durationMin = (args.int("duration") ?: 60).toLong()
                val begin = args.long("begin") ?: (System.currentTimeMillis() + 3600_000L)
                val values = android.content.ContentValues().apply {
                    put(CalendarContract.Events.CALENDAR_ID, primaryCalendarId())
                    put(CalendarContract.Events.TITLE, title)
                    put(CalendarContract.Events.DESCRIPTION, args.str("notes") ?: "")
                    put(CalendarContract.Events.DTSTART, begin)
                    put(CalendarContract.Events.DTEND, begin + durationMin * 60_000)
                    put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
                }
                val evUri = resolver.insert(CalendarContract.Events.CONTENT_URI, values)
                    ?: throw DeviceToolsException("insert event failed")
                val evId = evUri.lastPathSegment ?: throw DeviceToolsException("insert event failed (no id)")
                // 提醒（参数 reminderMinutes，默认 10 分钟前）
                val reminderMin = args.int("reminderMinutes") ?: 10
                if (reminderMin >= 0) {
                    val rv = android.content.ContentValues().apply {
                        put(CalendarContract.Reminders.EVENT_ID, evId)
                        put(CalendarContract.Reminders.MINUTES, reminderMin)
                        put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
                    }
                    try {
                        resolver.insert(CalendarContract.Reminders.CONTENT_URI, rv)
                    } catch (_: Exception) {
                        // 某些日历账户不支持提醒，忽略
                    }
                }
                return buildJsonObject {
                    put("id", evId); put("title", title); put("begin", begin)
                }
            }
            "delete" -> {
                ensureScope("calendar")
                val id = args.str("id") ?: throw DeviceToolsException("id required")
                val deleted = resolver.delete(
                    CalendarContract.Events.CONTENT_URI.buildUpon().appendPath(id).build(), null, null,
                )
                return buildJsonObject { put("deleted", deleted) }
            }
            else -> throw DeviceToolsException("unknown calendar op: $sub")
        }
    }

    private fun primaryCalendarId(): Long {
        resolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            arrayOf(CalendarContract.Calendars._ID),
            "${CalendarContract.Calendars.VISIBLE} = 1 AND ${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ${CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR}",
            null, null,
        )?.use { c ->
            if (c.moveToFirst()) return c.getLong(0)
        }
        // 回退：任意可见日历
        resolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            arrayOf(CalendarContract.Calendars._ID),
            "${CalendarContract.Calendars.VISIBLE} = 1", null, null,
        )?.use { c ->
            if (c.moveToFirst()) return c.getLong(0)
        }
        throw DeviceToolsException("no writable calendar found (add an account in the Calendar app first)")
    }

    // ---- clipboard ----
    private fun opClipboard(args: JsonObject): JsonObject {
        val sub = args.str("op") ?: "read"
        val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        when (sub) {
            "write" -> {
                val text = args.str("text") ?: throw DeviceToolsException("text required")
                cm.setPrimaryClip(android.content.ClipData.newPlainText("harnest", text))
                return buildJsonObject { put("ok", true); put("length", text.length) }
            }
            "read" -> {
                val clip = cm.primaryClip
                val text = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).coerceToText(activity)?.toString() ?: "" else ""
                return buildJsonObject { put("text", text) }
            }
            else -> throw DeviceToolsException("unknown clipboard op: $sub")
        }
    }

    // ---- files ----
    private suspend fun opFiles(args: JsonObject): JsonObject {
        val sub = args.str("op") ?: throw DeviceToolsException("op required")
        when (sub) {
            "pick" -> {
                val uri = suspendCancellableCoroutine<Uri?> { cont ->
                    openDocSink = { cont.resume(it) }
                    openDocLauncher.launch(arrayOf("*/*"))
                } ?: throw DeviceToolsException("no file picked")
                return buildJsonObject {
                    put("uri", uri.toString())
                    put("name", queryDisplayName(uri))
                }
            }
            "sandboxWrite" -> {
                val file = sandboxFile(args.str("path") ?: throw DeviceToolsException("path required"))
                val text = args.str("text") ?: ""
                withContext(Dispatchers.IO) {
                    file.parentFile?.mkdirs()
                    file.writeText(text)
                }
                return buildJsonObject { put("path", file.absolutePath); put("bytes", text.toByteArray().size) }
            }
            "sandboxRead" -> {
                val file = sandboxFile(args.str("path") ?: throw DeviceToolsException("path required"))
                val text = withContext(Dispatchers.IO) {
                    if (!file.exists()) throw DeviceToolsException("file not found: ${file.path}")
                    file.readText()
                }
                return buildJsonObject { put("text", text) }
            }
            "sandboxList" -> {
                val dir = sandboxFile(args.str("path") ?: "")
                val names = withContext(Dispatchers.IO) {
                    if (!dir.exists() || !dir.isDirectory) emptyList()
                    else dir.list()?.toList() ?: emptyList()
                }
                return buildJsonObject { putJsonArray("files") { names.forEach { add(it) } } }
            }
            else -> throw DeviceToolsException("unknown files op: $sub")
        }
    }

    /** 沙箱内路径守卫：拒绝 .. 逃逸（与 HarmonyOS sandboxPath 一致） */
    private fun sandboxFile(relPath: String): File {
        val root = activity.filesDir.canonicalFile
        val f = File(root, relPath).canonicalFile
        if (!f.path.startsWith(root.path + File.separator) && f != root) {
            throw DeviceToolsException("path escapes app sandbox: $relPath")
        }
        return f
    }

    private fun queryDisplayName(uri: Uri): String {
        resolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) return c.getString(0) ?: uri.lastPathSegment ?: ""
        }
        return uri.lastPathSegment ?: ""
    }

    // ---- photos ----
    private suspend fun opPhotos(args: JsonObject): JsonObject {
        val sub = args.str("op") ?: "pick"
        when (sub) {
            "pick" -> {
                val uri = suspendCancellableCoroutine<Uri?> { cont ->
                    pickMediaSink = { cont.resume(it) }
                    pickMediaLauncher.launch(
                        androidx.activity.result.PickVisualMediaRequest(
                            ActivityResultContracts.PickVisualMedia.ImageOnly,
                        ),
                    )
                } ?: throw DeviceToolsException("no photo picked")
                return buildJsonObject { put("uri", uri.toString()) }
            }
            "save" -> throw DeviceToolsException("photos save not supported on android yet (use files pick instead)")
            else -> throw DeviceToolsException("unknown photos op: $sub")
        }
    }

    // ---- mail ----
    private fun opMail(args: JsonObject): JsonObject {
        val to = args.str("to") ?: throw DeviceToolsException("to required")
        val subject = args.str("subject") ?: ""
        val body = args.str("body") ?: ""
        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:${Uri.encode(to)}")).apply {
            putExtra(Intent.EXTRA_SUBJECT, subject)
            putExtra(Intent.EXTRA_TEXT, body)
        }
        return runSystemUi(intent, "mail app")
    }

    // ---- call（dial/sms — 只预填拉起系统 UI，不做直拨） ----
    private fun opCall(args: JsonObject): JsonObject {
        val sub = args.str("op") ?: "dial"
        when (sub) {
            "dial" -> {
                val number = args.str("number") ?: throw DeviceToolsException("number required")
                return runSystemUi(Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(number)}")), "dialer")
            }
            "sms" -> {
                val number = args.str("number") ?: throw DeviceToolsException("number required")
                val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:${Uri.encode(number)}")).apply {
                    putExtra("sms_body", args.str("body") ?: "")
                }
                return runSystemUi(intent, "sms app")
            }
            else -> throw DeviceToolsException("unknown call op: $sub (direct CALL_PHONE intentionally unsupported)")
        }
    }

    // ---- sms（收件箱读取 — READ_SMS 运行时权限） ----
    private suspend fun opSms(args: JsonObject): JsonObject {
        val sub = args.str("op") ?: "query"
        if (sub != "query") throw DeviceToolsException("unknown sms op: $sub")
        ensureScope("sms")
        val days = args.int("days") ?: 30
        val limit = args.int("limit") ?: 50
        val addressFilter = args.str("address")?.trim() ?: ""
        val sinceMs = System.currentTimeMillis() - days.toLong() * 24L * 60L * 60L * 1000L
        return withContext(Dispatchers.IO) {
            val items = mutableListOf<JsonObject>()
            try {
                resolver.query(
                    Uri.parse("content://sms"),
                    arrayOf("_id", "address", "date", "type", "body"),
                    "date >= ?",
                    arrayOf(sinceMs.toString()),
                    "date DESC",
                )?.use { c ->
                    val iId = c.getColumnIndexOrThrow("_id")
                    val iAddr = c.getColumnIndexOrThrow("address")
                    val iDate = c.getColumnIndexOrThrow("date")
                    val iType = c.getColumnIndexOrThrow("type")
                    val iBody = c.getColumnIndexOrThrow("body")
                    while (c.moveToNext() && items.size < limit) {
                        val addr = c.getString(iAddr) ?: ""
                        if (addressFilter.isNotEmpty() && !addr.contains(addressFilter, ignoreCase = true)) continue
                        val dateMs = c.getLong(iDate)
                        items.add(
                            buildJsonObject {
                                put("id", c.getLong(iId))
                                put("address", addr)
                                put("date", dateMs)
                                put(
                                    "dateIso",
                                    java.text.SimpleDateFormat(
                                        "yyyy-MM-dd HH:mm:ss",
                                        java.util.Locale.US,
                                    ).format(java.util.Date(dateMs)),
                                )
                                put(
                                    "type",
                                    when (c.getInt(iType)) {
                                        1 -> "received"; 2 -> "sent"; 3 -> "draft"; 4 -> "outbox"; else -> "other"
                                    },
                                )
                                put("body", c.getString(iBody) ?: "")
                            },
                        )
                    }
                }
            } catch (e: SecurityException) {
                throw DeviceToolsException("permission denied: READ_SMS (grant it in system settings)")
            }
            buildJsonObject {
                put("ok", true)
                put("days", days)
                put("count", items.size)
                putJsonArray("messages") { items.forEach { add(it) } }
            }
        }
    }

    private fun runSystemUi(intent: Intent, what: String): JsonObject {
        try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
        } catch (e: Exception) {
            throw DeviceToolsException("no $what available: ${e.message}")
        }
        return buildJsonObject { put("ok", true); put("launched", what) }
    }

    // ---- camera（系统相机预览图 — 免 CAMERA 权限） ----
    private suspend fun opCamera(args: JsonObject): JsonObject {
        val bmp = suspendCancellableCoroutine<Bitmap?> { cont ->
            takePreviewSink = { cont.resume(it) }
            takePreviewLauncher.launch(null)
        } ?: throw DeviceToolsException("capture cancelled")
        val file = File(activity.filesDir, "camera-${System.currentTimeMillis()}.png")
        withContext(Dispatchers.IO) {
            file.outputStream().use { os -> bmp.compress(Bitmap.CompressFormat.PNG, 90, os) }
        }
        return buildJsonObject {
            put("path", file.absolutePath)
            put("width", bmp.width)
            put("height", bmp.height)
        }
    }

    // ---- recorder ----
    @Suppress("DEPRECATION")
    private suspend fun opRecorder(args: JsonObject): JsonObject {
        val sub = args.str("op") ?: throw DeviceToolsException("op required")
        when (sub) {
            "start" -> {
                if (recorder != null) throw DeviceToolsException("recorder already running")
                ensureScope("microphone")
                val maxSeconds = min(args.int("maxSeconds") ?: 30, 120)
                val file = File(activity.filesDir, "record-${System.currentTimeMillis()}.m4a")
                withContext(Dispatchers.IO) {
                    @Suppress("DEPRECATION")
                    val r = MediaRecorder()
                    r.setAudioSource(MediaRecorder.AudioSource.MIC)
                    r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                    r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                    r.setAudioEncodingBitRate(96_000)
                    r.setAudioSamplingRate(44_100)
                    r.setOutputFile(file.absolutePath)
                    r.prepare()
                    r.start()
                    recorder = r
                    recorderFile = file
                    recorderStartMs = System.currentTimeMillis()
                }
                // maxSeconds 后自动停（防止悬挂录音）；不阻塞调用方
                recorderTimer?.cancel()
                recorderTimer = scope.launch {
                    delay(maxSeconds * 1000L)
                    stopRecorderInternal()
                }
                return buildJsonObject {
                    put("ok", true)
                    put("path", file.absolutePath)
                    put("maxSeconds", maxSeconds)
                }
            }
            "stop" -> {
                if (recorder == null) throw DeviceToolsException("recorder not running")
                recorderTimer?.cancel()
                recorderTimer = null
                stopRecorderInternal()
                val f = recorderFile
                return buildJsonObject {
                    put("path", f?.absolutePath ?: "")
                    put("bytes", f?.length() ?: 0L)
                    put("durationMs", System.currentTimeMillis() - recorderStartMs)
                }
            }
            else -> throw DeviceToolsException("unknown recorder op: $sub")
        }
    }

    private fun stopRecorderInternal() {
        try {
            recorder?.stop()
        } catch (_: Exception) {
            // 极短录音 stop 会抛 RuntimeException，忽略（文件可能无效但流程完成）
        }
        try {
            recorder?.release()
        } catch (_: Exception) {
        }
        recorder = null
    }

    // ---- app ----
    @SuppressLint("QueryPermissionsNeeded")
    private fun opApp(args: JsonObject): JsonObject {
        val sub = args.str("op") ?: "list"
        val pm = activity.packageManager
        when (sub) {
            "list" -> {
                val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                val apps = pm.queryIntentActivities(launcherIntent, 0)
                    .map { ri ->
                        buildJsonObject {
                            put("package", ri.activityInfo.packageName)
                            put("label", ri.loadLabel(pm).toString())
                        }
                    }
                    .sortedBy { it["label"]!!.jsonPrimitive.content }
                return buildJsonObject {
                    putJsonArray("apps") { apps.take(200).forEach { add(it) } }
                    put("count", min(apps.size, 200))
                }
            }
            "open" -> {
                val pkg = args.str("package")
                val uri = args.str("uri")
                val intent = when {
                    pkg != null -> pm.getLaunchIntentForPackage(pkg)
                        ?: throw DeviceToolsException("app not found or not launchable: $pkg")
                    uri == "about" || uri == "settings" -> Intent(android.provider.Settings.ACTION_SETTINGS)
                    uri != null -> Intent(Intent.ACTION_VIEW, Uri.parse(uri))
                    else -> throw DeviceToolsException("package or uri required")
                }
                return runSystemUi(intent, "app")
            }
            "gui" -> throw DeviceToolsException("app gui automation is phase-3 (AccessibilityService), not yet available")
            else -> throw DeviceToolsException("unknown app op: $sub")
        }
    }

    // ---- 参数工具 ----
    private fun JsonObject.str(key: String): String? =
        (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.intOrNull

    private fun JsonObject.long(key: String): Long? =
        (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.longOrNull

    private fun JsonObject.strList(key: String): List<String> =
        (this[key] as? JsonArray)?.mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull }
            ?: emptyList()
}
