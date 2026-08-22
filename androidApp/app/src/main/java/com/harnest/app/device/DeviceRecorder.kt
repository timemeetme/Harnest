package com.harnest.app.device

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import com.harnest.app.MainActivity
import org.json.JSONObject
import java.io.File

/** recorder: m4a (AAC) start/stop with an ongoing notification while recording */
class DeviceRecorder(private val context: Context) {
    companion object { private const val TAG = "DeviceRecorder"; private const val CHANNEL_ID = "harness_recording" }

    private var recorder: MediaRecorder? = null
    private var currentFile: File? = null
    private var startTime = 0L

    suspend fun op(args: JSONObject): JSONObject {
        val op = args.optString("op", "status")
        return when (op) {
            "start" -> startRecord(args.optInt("secondsLimit", 0))
            "stop" -> stop()
            "status" -> JSONObject().put("ok", true).put("recording", recorder != null)
                .put("elapsedMs", if (recorder != null) System.currentTimeMillis() - startTime else 0)
            else -> JSONObject().put("ok", false).put("error", "unknown op: $op")
        }
    }

    private fun startRecord(secondsLimit: Int): JSONObject {
        if (recorder != null) return JSONObject().put("ok", false).put("error", "already recording — stop first")
        if (!hasMic()) return JSONObject().put("ok", false).put("error", "RECORD_AUDIO permission not granted — request via device_permissions name=microphone")
        return try {
            val dir = File(context.filesDir, "harness/audio")
            dir.mkdirs()
            val file = File(dir, "rec_${System.currentTimeMillis()}.m4a")
            @Suppress("DEPRECATION")
            val mr = MediaRecorder()
            mr.setAudioSource(MediaRecorder.AudioSource.MIC)
            mr.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            mr.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            mr.setAudioEncodingBitRate(96000)
            mr.setAudioSamplingRate(44100)
            mr.setOutputFile(file.absolutePath)
            mr.prepare()
            mr.start()
            recorder = mr
            currentFile = file
            startTime = System.currentTimeMillis()
            showRecordingNotification()
            JSONObject().put("ok", true).put("recording", true).put("uri", file.absolutePath)
                .put("note", "Recording… an ongoing notification is shown. Call op=stop when done.")
        } catch (e: Throwable) {
            Log.e(TAG, "start failed", e)
            try { recorder?.release() } catch (_: Throwable) {}
            recorder = null
            JSONObject().put("ok", false).put("error", e.message)
        }
    }

    private fun stop(): JSONObject {
        val mr = recorder ?: return JSONObject().put("ok", false).put("error", "not recording")
        val file = currentFile
        return try {
            mr.stop()
            JSONObject().put("ok", true).put("uri", file?.absolutePath ?: "").put("size", file?.length() ?: 0)
                .put("durationMs", System.currentTimeMillis() - startTime)
        } catch (e: Throwable) {
            JSONObject().put("ok", false).put("error", e.message)
        } finally {
            try { mr.release() } catch (_: Throwable) {}
            recorder = null
            cancelRecordingNotification()
        }
    }

    private fun hasMic(): Boolean =
        context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun showRecordingNotification() {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Recording", NotificationManager.IMPORTANCE_LOW))
        }
        val contentIntent = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n: Notification = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, CHANNEL_ID)
                .setContentTitle("Harness 正在录音")
                .setContentText("代理正在录制音频")
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentIntent(contentIntent)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
                .setContentTitle("Harness 正在录音")
                .setContentText("代理正在录制音频")
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentIntent(contentIntent)
                .setOngoing(true)
                .build()
        }
        try {
            nm.notify(2001, n)
        } catch (e: Throwable) {
            Log.w(TAG, "recording notification failed: ${e.message}")
        }
    }

    private fun cancelRecordingNotification() {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(2001)
        } catch (_: Throwable) {}
    }
}
