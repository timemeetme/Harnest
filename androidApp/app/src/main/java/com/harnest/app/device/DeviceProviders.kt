package com.harnest.app.device

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.CalendarContract
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.Telephony
import org.json.JSONArray
import org.json.JSONObject

/**
 * ContentResolver-backed providers: contacts / calendar / call log / sms.
 * On Android these are genuinely readable+writeable (unlike HarmonyOS third-party).
 */
object DeviceProviders {

    // ── contacts ─────────────────────────────────────────────

    suspend fun contacts(context: Context, launcher: UiLauncher, args: JSONObject): JSONObject {
        val op = args.optString("op", "list")
        if (op == "list" || op == "query") {
            if (!ensure(launcher, Manifest.permission.READ_CONTACTS, "read contacts")) return denied("read contacts")
            return try {
                val query = args.optString("query", "")
                val cr = context.contentResolver
                val arr = JSONArray()
                val projection = arrayOf(
                    ContactsContract.Contacts._ID,
                    ContactsContract.Contacts.DISPLAY_NAME,
                    ContactsContract.Contacts.HAS_PHONE_NUMBER,
                )
                val sel = if (query.isNotEmpty())
                    "${ContactsContract.Contacts.DISPLAY_NAME} LIKE ?" else null
                val selArgs = if (query.isNotEmpty()) arrayOf("%$query%") else null
                cr.query(ContactsContract.Contacts.CONTENT_URI, projection, sel, selArgs, null)?.use { c ->
                    var count = 0
                    while (c.moveToNext() && count < args.optInt("limit", 50)) {
                        val id = c.getLong(0)
                        val name = c.getString(1) ?: ""
                        var number = ""
                        if (c.getInt(2) > 0) {
                            cr.query(
                                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                                arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
                                "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID}=?",
                                arrayOf(id.toString()), null,
                            )?.use { p -> if (p.moveToFirst()) number = p.getString(0) ?: "" }
                        }
                        var email = ""
                        cr.query(
                            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
                            arrayOf(ContactsContract.CommonDataKinds.Email.ADDRESS),
                            "${ContactsContract.CommonDataKinds.Email.CONTACT_ID}=?",
                            arrayOf(id.toString()), null,
                        )?.use { e -> if (e.moveToFirst()) email = e.getString(0) ?: "" }
                        arr.put(JSONObject().put("id", id).put("name", name).put("number", number).put("email", email))
                        count++
                    }
                }
                JSONObject().put("ok", true).put("contacts", arr)
            } catch (e: SecurityException) {
                denied("read contacts")
            } catch (e: Throwable) {
                err(e)
            }
        }
        if (op == "create") {
            if (!ensure(launcher, Manifest.permission.WRITE_CONTACTS, "write contacts")) return denied("write contacts")
            return try {
                val values = ContentValues().apply {
                    put(ContactsContract.RawContacts.ACCOUNT_TYPE, null as String?)
                    put(ContactsContract.RawContacts.ACCOUNT_NAME, null as String?)
                }
                val rawUri = context.contentResolver.insert(ContactsContract.RawContacts.CONTENT_URI, values)
                    ?: return JSONObject().put("ok", false).put("error", "insert raw contact failed")
                val rawId = android.content.ContentUris.parseId(rawUri)
                val name = args.optString("name", "")
                val number = args.optString("number", "")
                val email = args.optString("email", "")
                if (name.isNotEmpty()) {
                    val d = ContentValues().apply {
                        put(ContactsContract.Data.RAW_CONTACT_ID, rawId)
                        put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE)
                        put(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME, name)
                    }
                    context.contentResolver.insert(ContactsContract.Data.CONTENT_URI, d)
                }
                if (number.isNotEmpty()) {
                    val d = ContentValues().apply {
                        put(ContactsContract.Data.RAW_CONTACT_ID, rawId)
                        put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
                        put(ContactsContract.CommonDataKinds.Phone.NUMBER, number)
                        put(ContactsContract.CommonDataKinds.Phone.TYPE, ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE)
                    }
                    context.contentResolver.insert(ContactsContract.Data.CONTENT_URI, d)
                }
                if (email.isNotEmpty()) {
                    val d = ContentValues().apply {
                        put(ContactsContract.Data.RAW_CONTACT_ID, rawId)
                        put(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE)
                        put(ContactsContract.CommonDataKinds.Email.ADDRESS, email)
                    }
                    context.contentResolver.insert(ContactsContract.Data.CONTENT_URI, d)
                }
                JSONObject().put("ok", true).put("id", rawId).put("name", name)
            } catch (e: Throwable) {
                err(e)
            }
        }
        if (op == "delete") {
            if (!ensure(launcher, Manifest.permission.WRITE_CONTACTS, "write contacts")) return denied("write contacts")
            return try {
                val id = args.optString("id", "")
                if (id.isEmpty()) return JSONObject().put("ok", false).put("error", "id required")
                val uri = Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_URI, id)
                val deleted = context.contentResolver.delete(uri, null, null)
                JSONObject().put("ok", true).put("deleted", deleted)
            } catch (e: Throwable) {
                err(e)
            }
        }
        return JSONObject().put("ok", false).put("error", "unknown op: $op")
    }

    // ── calendar ─────────────────────────────────────────────

    suspend fun calendar(context: Context, launcher: UiLauncher, args: JSONObject): JSONObject {
        val op = args.optString("op", "list")
        if (op == "list" || op == "query") {
            if (!ensure(launcher, Manifest.permission.READ_CALENDAR, "read calendar")) return denied("read calendar")
            return try {
                val calId = primaryCalendarId(context) ?: return JSONObject().put("ok", false)
                    .put("error", "no calendar account found")
                val from = args.optLong("from", System.currentTimeMillis() - 7L * 24 * 3600 * 1000)
                val to = args.optLong("to", System.currentTimeMillis() + 30L * 24 * 3600 * 1000)
                val projection = arrayOf(
                    CalendarContract.Events._ID,
                    CalendarContract.Events.TITLE,
                    CalendarContract.Events.DESCRIPTION,
                    CalendarContract.Events.DTSTART,
                    CalendarContract.Events.DTEND,
                    CalendarContract.Events.EVENT_LOCATION,
                )
                val arr = JSONArray()
                context.contentResolver.query(
                    CalendarContract.Instances.CONTENT_URI.buildUpon()
                        .appendPath(from.toString()).appendPath(to.toString()).build(),
                    projection, null, null, "${CalendarContract.Instances.DTSTART} ASC",
                )?.use { c ->
                    var count = 0
                    while (c.moveToNext() && count < args.optInt("limit", 50)) {
                        val title = c.getString(1) ?: ""
                        val start = c.getLong(3)
                        val end = if (c.isNull(4)) start else c.getLong(4)
                        val allDay = end - start >= 24L * 3600 * 1000 &&
                            start % (24L * 3600 * 1000) < 1000
                        arr.put(JSONObject()
                            .put("id", c.getLong(0)).put("title", title)
                            .put("description", c.getString(2) ?: "")
                            .put("startMs", start).put("endMs", end)
                            .put("location", c.getString(5) ?: "").put("allDay", allDay)
                            .put("calendarId", calId))
                        count++
                    }
                }
                JSONObject().put("ok", true).put("events", arr).put("calendarId", calId)
            } catch (e: SecurityException) {
                denied("read calendar")
            } catch (e: Throwable) {
                err(e)
            }
        }
        if (op == "create") {
            if (!ensure(launcher, Manifest.permission.WRITE_CALENDAR, "write calendar")) return denied("write calendar")
            return try {
                val calId = primaryCalendarId(context) ?: return JSONObject().put("ok", false)
                    .put("error", "no calendar account found")
                val start = args.optLong("startMs", System.currentTimeMillis() + 3600_000L)
                val durationMin = args.optLong("durationMinutes", 60)
                val values = ContentValues().apply {
                    put(CalendarContract.Events.CALENDAR_ID, calId)
                    put(CalendarContract.Events.TITLE, args.optString("title", "Event"))
                    put(CalendarContract.Events.DESCRIPTION, args.optString("description", ""))
                    put(CalendarContract.Events.EVENT_LOCATION, args.optString("location", ""))
                    put(CalendarContract.Events.DTSTART, start)
                    put(CalendarContract.Events.DTEND, start + durationMin * 60_000)
                    put(CalendarContract.Events.EVENT_TIMEZONE, java.util.TimeZone.getDefault().id)
                }
                val uri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
                JSONObject().put("ok", true).put("id", uri?.lastPathSegment ?: "-1")
            } catch (e: Throwable) {
                err(e)
            }
        }
        if (op == "delete") {
            if (!ensure(launcher, Manifest.permission.WRITE_CALENDAR, "write calendar")) return denied("write calendar")
            return try {
                val id = args.optString("id", "")
                if (id.isEmpty()) return JSONObject().put("ok", false).put("error", "id required")
                val deleted = context.contentResolver.delete(
                    Uri.withAppendedPath(CalendarContract.Events.CONTENT_URI, id), null, null)
                JSONObject().put("ok", true).put("deleted", deleted)
            } catch (e: Throwable) {
                err(e)
            }
        }
        return JSONObject().put("ok", false).put("error", "unknown op: $op")
    }

    private fun primaryCalendarId(context: Context): Long? {
        return try {
            context.contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.IS_PRIMARY),
                null, null, null,
            )?.use { c ->
                var fallback: Long? = null
                while (c.moveToNext()) {
                    val id = c.getLong(0)
                    if (c.getInt(1) == 1) return id
                    if (fallback == null) fallback = id
                }
                fallback
            }
        } catch (e: Throwable) {
            null
        }
    }

    // ── call (dial/sms/calllog) ──────────────────────────────

    suspend fun call(context: Context, launcher: UiLauncher, args: JSONObject): JSONObject {
        val op = args.optString("op", "dial")
        val number = args.optString("number", "")
        if (op == "calllog" || op == "history" || op == "query") {
            // On Android the call log IS readable with READ_CALL_LOG runtime permission.
            if (!ensure(launcher, Manifest.permission.READ_CALL_LOG, "read call log")) {
                return JSONObject().put("ok", false)
                    .put("error", "READ_CALL_LOG permission denied — ask the user to grant it via device_permissions request name=callLog, or ask them to read the call log themselves")
            }
            return try {
                val limit = args.optInt("limit", 20)
                val arr = JSONArray()
                context.contentResolver.query(
                    CallLog.Calls.CONTENT_URI,
                    arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE,
                        CallLog.Calls.DATE, CallLog.Calls.DURATION),
                    null, null, "${CallLog.Calls.DATE} DESC",
                )?.use { c ->
                    var count = 0
                    while (c.moveToNext() && count < limit) {
                        val type = when (c.getInt(2)) {
                            CallLog.Calls.INCOMING_TYPE -> "incoming"
                            CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                            CallLog.Calls.MISSED_TYPE -> "missed"
                            else -> "other"
                        }
                        arr.put(JSONObject()
                            .put("number", c.getString(0) ?: "")
                            .put("name", c.getString(1) ?: "")
                            .put("type", type)
                            .put("dateMs", c.getLong(3))
                            .put("durationSec", c.getLong(4)))
                        count++
                    }
                }
                JSONObject().put("ok", true).put("readable", true).put("calls", arr)
            } catch (e: SecurityException) {
                denied("read call log")
            } catch (e: Throwable) {
                err(e)
            }
        }
        if (number.isEmpty()) return JSONObject().put("ok", false).put("error", "dial/sms requires number")
        if (op == "dial") {
            return launchIntent(context, Intent(Intent.ACTION_DIAL, Uri.parse("tel:$number")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                "dialer opened with number pre-filled; the user presses call")
        }
        if (op == "sms") {
            val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$number")).apply {
                putExtra("sms_body", args.optString("body", ""))
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            return launchIntent(context, intent, "sms composer opened; the user sends it")
        }
        return JSONObject().put("ok", false).put("error", "unknown op: $op (supported: dial, sms, calllog)")
    }

    // ── sms (read + compose) ─────────────────────────────────

    suspend fun sms(context: Context, launcher: UiLauncher, args: JSONObject): JSONObject {
        val op = args.optString("op", "list")
        if (op == "list" || op == "read" || op == "query") {
            if (!ensure(launcher, Manifest.permission.READ_SMS, "read sms")) {
                return JSONObject().put("ok", false)
                    .put("error", "READ_SMS permission denied — ask the user to grant it via device_permissions request name=sms")
            }
            return try {
                val limit = args.optInt("limit", 20)
                val from = args.optString("from", "")
                val sel = if (from.isNotEmpty()) "${Telephony.Sms.ADDRESS} LIKE ?" else null
                val selArgs = if (from.isNotEmpty()) arrayOf("%$from%") else null
                val arr = JSONArray()
                context.contentResolver.query(
                    Telephony.Sms.Inbox.CONTENT_URI,
                    arrayOf(Telephony.Sms.ADDRESS, Telephony.Sms.PERSON, Telephony.Sms.BODY, Telephony.Sms.DATE),
                    sel, selArgs, "${Telephony.Sms.DATE} DESC",
                )?.use { c ->
                    var count = 0
                    while (c.moveToNext() && count < limit) {
                        arr.put(JSONObject()
                            .put("from", c.getString(0) ?: "")
                            .put("name", c.getString(1) ?: "")
                            .put("body", c.getString(2) ?: "")
                            .put("dateMs", c.getLong(3)))
                        count++
                    }
                }
                JSONObject().put("ok", true).put("readable", true).put("messages", arr)
            } catch (e: SecurityException) {
                denied("read sms")
            } catch (e: Throwable) {
                err(e)
            }
        }
        if (op == "send" || op == "compose") {
            val number = args.optString("number", "")
            if (number.isEmpty()) return JSONObject().put("ok", false).put("error", "send requires number")
            val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$number")).apply {
                putExtra("sms_body", args.optString("body", ""))
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            return launchIntent(context, intent, "sms composer opened; the user sends it")
        }
        return JSONObject().put("ok", false).put("error", "unknown op: $op")
    }

    // ── helpers ──────────────────────────────────────────────

    private suspend fun ensure(launcher: UiLauncher, perm: String, what: String): Boolean =
        launcher.requestPermission(perm)

    private fun denied(what: String): JSONObject =
        JSONObject().put("ok", false).put("error", "permission denied: $what")

    private fun err(e: Throwable): JSONObject =
        JSONObject().put("ok", false).put("error", e.message ?: e.javaClass.simpleName)

    private fun launchIntent(context: Context, intent: Intent, note: String): JSONObject {
        return try {
            context.startActivity(intent)
            JSONObject().put("ok", true).put("launched", true).put("note", note)
        } catch (e: Throwable) {
            JSONObject().put("ok", false).put("error", "failed to launch: ${e.message}")
        }
    }
}
