package com.harnest.app.device

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.harnest.app.MainActivity
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Reminders — AlarmManager + notification. Contract mirrors the HarmonyOS
 * reminderAgentManager version (timer / calendar types).
 */
class DeviceReminder(private val context: Context) {
    companion object {
        private const val CHANNEL_ID = "harness_reminder"
        private const val PREFS = "harness_reminders"
        private const val BASE_ID = 1000
        private var nextId = BASE_ID + 1
    }

    fun op(args: JSONObject): JSONObject {
        val op = args.optString("op", "list")
        if (op == "list") {
            val arr = JSONArray()
            prefs().all.forEach { (k, v) ->
                if (k.startsWith("r_")) {
                    runCatching { arr.put(JSONObject(v.toString())) }
                }
            }
            return JSONObject().put("ok", true).put("reminders", arr)
        }
        if (op == "cancel") {
            val id = args.optInt("id", -1)
            if (id < BASE_ID) return JSONObject().put("ok", false).put("error", "id required")
            cancel(id)
            return JSONObject().put("ok", true).put("cancelled", id)
        }
        if (op == "cancelAll") {
            val all = prefs().all.keys.filter { it.startsWith("r_") }
            all.forEach { key ->
                prefs().getString(key, null)?.let { raw ->
                    runCatching { cancel(JSONObject(raw).optInt("id", -1)) }
                }
            }
            prefs().edit().clear().apply()
            return JSONObject().put("ok", true).put("cancelledAll", all.size)
        }
        if (op == "publish" || op == "create") {
            val type = args.optString("type", "timer")
            val title = args.optString("title", "Harness 提醒")
            val content = args.optString("content", "")
            val id = nextId++
            val triggerAt: Long = when (type) {
                "timer" -> System.currentTimeMillis() + args.optLong("seconds", 60) * 1000
                "calendar" -> args.optLong("dateTimeMs", System.currentTimeMillis() + 3600_000)
                else -> return JSONObject().put("ok", false).put("error", "unknown type: $type (timer|calendar)")
            }
            val pi = pendingIntent(id, title, content)
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            try {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
            } catch (e: SecurityException) {
                runCatching { am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi) }
            }
            val rec = JSONObject().put("id", id).put("type", type).put("title", title)
                .put("content", content).put("triggerAtMs", triggerAt)
            prefs().edit().putString("r_$id", rec.toString()).apply()
            return JSONObject().put("ok", true).put("reminderId", id)
                .put("note", "system notification will fire at trigger time")
        }
        return JSONObject().put("ok", false).put("error", "unknown op: $op")
    }

    private fun pendingIntent(id: Int, title: String, content: String): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java).apply {
            putExtra("id", id); putExtra("title", title); putExtra("content", content)
        }
        return PendingIntent.getBroadcast(
            context, id, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun cancel(id: Int) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pendingIntent(id, "", "")
        runCatching { am.cancel(pi) }
        pi.cancel()
        prefs().edit().remove("r_$id").apply()
    }

    private fun prefs() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: android.content.Intent) {
        val id = intent.getIntExtra("id", -1)
        val title = intent.getStringExtra("title") ?: "Harness 提醒"
        val content = intent.getStringExtra("content") ?: ""
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel("harness_reminder", "Reminders", NotificationManager.IMPORTANCE_HIGH))
        }
        val contentIntent = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = if (Build.VERSION.SDK_INT >= 26) {
            android.app.Notification.Builder(context, "harness_reminder")
                .setContentTitle(title).setContentText(content)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(contentIntent).setAutoCancel(true).build()
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(context)
                .setContentTitle(title).setContentText(content)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(contentIntent).setAutoCancel(true).build()
        }
        nm.notify(id, n)
        context.getSharedPreferences("harness_reminders", Context.MODE_PRIVATE)
            .edit().remove("r_$id").apply()
        // also record a trigger file (parity with the HarmonyOS WorkScheduler flow)
        runCatching {
            val f = File(File(context.filesDir, "harness"), "reminder_fired.json")
            f.writeText(JSONObject()
                .put("id", id).put("title", title).put("firedAt", System.currentTimeMillis()).toString())
        }
    }
}
