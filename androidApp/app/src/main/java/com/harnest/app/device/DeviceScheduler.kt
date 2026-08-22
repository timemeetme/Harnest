package com.harnest.app.device

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.Data
import androidx.work.workDataOf
import com.harnest.app.MainActivity
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/** WorkScheduler parity — WorkManager periodic background jobs + notification. */
object DeviceScheduler {

    private const val WORK_PREFIX = "harness_job_"
    private const val PREFS = "harness_scheduler"

    fun op(context: Context, args: JSONObject): JSONObject {
        val op = args.optString("op", "list")
        if (op == "start" || op == "create") {
            val task = args.optString("task", "default")
            val intervalMinutes = args.optLong("intervalMinutes", 30)
            if (intervalMinutes < 15) return JSONObject().put("ok", false)
                .put("error", "minimum interval is 15 minutes (WorkManager limit)")
            val workId = args.optInt("workId", (WORK_PREFIX.length + task.hashCode()).let { if (it >= 0) it else -it })
            val name = WORK_PREFIX + workId
            val data: Data = workDataOf("workId" to workId, "task" to task)
            val request = PeriodicWorkRequestBuilder<SchedulerWorker>(intervalMinutes, TimeUnit.MINUTES)
                .setInputData(data).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(name, ExistingPeriodicWorkPolicy.UPDATE, request)
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("j_$workId", JSONObject()
                    .put("workId", workId).put("task", task)
                    .put("intervalMinutes", intervalMinutes).toString())
                .apply()
            return JSONObject().put("ok", true).put("workId", workId).put("task", task)
                .put("intervalMinutes", intervalMinutes)
                .put("note", "background job scheduled; each run writes filesDir/harness/work_trigger.json and posts a notification")
        }
        if (op == "stop") {
            val workId = args.optInt("workId", -1)
            if (workId < 0) return JSONObject().put("ok", false).put("error", "workId required")
            WorkManager.getInstance(context).cancelUniqueWork(WORK_PREFIX + workId)
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove("j_$workId").apply()
            return JSONObject().put("ok", true).put("stopped", workId)
        }
        if (op == "stopAll") {
            val wm = WorkManager.getInstance(context)
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).all.keys
                .filter { it.startsWith("j_") }.forEach { key ->
                    val wid = key.removePrefix("j_").toIntOrNull() ?: return@forEach
                    wm.cancelUniqueWork(WORK_PREFIX + wid)
                }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
            return JSONObject().put("ok", true)
        }
        if (op == "list") {
            val arr = JSONArray()
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).all.forEach { (k, v) ->
                if (k.startsWith("j_")) runCatching { arr.put(JSONObject(v.toString())) }
            }
            return JSONObject().put("ok", true).put("jobs", arr)
        }
        if (op == "trigger") {
            // run once now (test path)
            val task = args.optString("task", "manual")
            val workId = args.optInt("workId", 9999)
            val request = OneTimeWorkRequestBuilder<SchedulerWorker>()
                .setInputData(workDataOf("workId" to workId, "task" to task)).build()
            WorkManager.getInstance(context).enqueue(request)
            return JSONObject().put("ok", true).put("triggered", true)
        }
        return JSONObject().put("ok", false).put("error", "unknown op: $op")
    }
}

class SchedulerWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val workId = inputData.getInt("workId", -1)
        val task = inputData.getString("task") ?: "default"
        runCatching {
            val dir = File(applicationContext.filesDir, "harness")
            dir.mkdirs()
            File(dir, "work_trigger.json").writeText(JSONObject()
                .put("workId", workId).put("task", task)
                .put("timestamp", System.currentTimeMillis()).toString())
        }
        postNotification(task)
        return Result.success()
    }

    private fun postNotification(task: String) {
        val ctx = applicationContext
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel("harness_scheduler", "Scheduled tasks", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val contentIntent = PendingIntent.getActivity(
            ctx, 0, Intent(ctx, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = if (Build.VERSION.SDK_INT >= 26) {
            android.app.Notification.Builder(ctx, "harness_scheduler")
                .setContentTitle("Harness 定时任务")
                .setContentText("task=$task 已触发，点击打开")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(contentIntent).setAutoCancel(true).build()
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(ctx)
                .setContentTitle("Harness 定时任务")
                .setContentText("task=$task 已触发，点击打开")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(contentIntent).setAutoCancel(true).build()
        }
        // POST_NOTIFICATIONS granted? try/notify silently
        runCatching { nm.notify(3000 + (task.hashCode().let { if (it >= 0) it else -it } % 1000), n) }
    }
}
