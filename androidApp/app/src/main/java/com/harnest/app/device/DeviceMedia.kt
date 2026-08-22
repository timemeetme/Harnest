package com.harnest.app.device

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.provider.MediaStore
import com.harnest.app.engine.VisionAttach
import org.json.JSONObject
import java.io.File

/** camera / photos */
object DeviceMedia {

    /**
     * camera op. "capture"/"auto" (default) takes the photo automatically via
     * camera2 with no user interaction; falls back to the system camera UI if
     * the camera permission is denied or headless capture fails. "manual"
     * always opens the system camera so the user composes the shot.
     */
    suspend fun camera(context: Context, launcher: UiLauncher, args: JSONObject): JSONObject {
        when (args.optString("op", "capture")) {
            "capture", "auto" -> {
                var granted = false
                try {
                    granted = launcher.requestPermission(Manifest.permission.CAMERA)
                } catch (_: Throwable) {
                }
                if (granted) {
                    val front = args.optString("facing", "back") == "front"
                    val dir = File(context.filesDir, "harness/photos").apply { mkdirs() }
                    val f = File(dir, "photo_${System.currentTimeMillis()}.jpg")
                    if (HeadlessCamera.capture(context, f, front = front)) {
                        return finish(f, automatic = true)
                    }
                }
                return manual(launcher)
            }
            "manual" -> return manual(launcher)
            else -> return JSONObject().put("ok", false).put("error", "unknown op: ${args.optString("op")}")
        }
    }

    private suspend fun manual(launcher: UiLauncher): JSONObject {
        val path = try {
            launcher.takePicture()
        } catch (_: Throwable) {
            null
        } ?: return JSONObject().put("ok", false).put("cancelled", true)
            .put("error", "camera cancelled — no photo captured")
        return finish(File(path), automatic = false)
    }

    private fun finish(file: File, automatic: Boolean): JSONObject {
        val attached = VisionAttach.pushFile(file)
        return JSONObject().put("ok", true).put("uri", file.absolutePath).put("path", file.absolutePath)
            .put("size", file.length())
            .put("automatic", automatic)
            .put("imageAttached", attached)
            .put("note",
                (if (automatic)
                    "Photo taken AUTOMATICALLY by the agent — no user interaction was needed. "
                else
                    "Photo confirmed by the user in the system camera UI. ") +
                    (if (attached)
                        "The photo is ALSO attached to your NEXT model request as an image (image_url part) — analyze it directly, do not guess or invent its content."
                    else
                        "The image could not be attached to your next request."))
    }

    suspend fun photos(context: Context, launcher: UiLauncher, args: JSONObject): JSONObject {
        val op = args.optString("op", "pick")
        if (op == "pick") {
            val uri = launcher.pickImage()
                ?: return JSONObject().put("ok", false).put("cancelled", true)
            return try {
                val bytes = context.contentResolver.openInputStream(android.net.Uri.parse(uri))?.use { it.readBytes() }
                    ?: return JSONObject().put("ok", false).put("error", "cannot open $uri")
                val out: JSONObject
                if (args.optBoolean("base64", false)) {
                    out = JSONObject().put("ok", true).put("uri", uri).put("size", bytes.size)
                        .put("base64", android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP))
                } else {
                    val name = "photo_${System.currentTimeMillis()}.jpg"
                    val file = File(File(context.filesDir, "harness/photos"), name)
                    file.parentFile?.mkdirs()
                    file.writeBytes(bytes)
                    out = JSONObject().put("ok", true).put("uri", uri).put("size", bytes.size).put("path", "photos/$name")
                }
                out
            } catch (e: Throwable) {
                JSONObject().put("ok", false).put("error", e.message)
            }
        }
        if (op == "save") {
            val base64 = args.optString("base64", "")
            if (base64.isEmpty()) return JSONObject().put("ok", false).put("error", "base64 required")
            return try {
                val bytes = android.util.Base64.decode(base64, android.util.Base64.NO_WRAP)
                val name = args.optString("name", "harness_${System.currentTimeMillis()}.png")
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(MediaStore.Images.Media.MIME_TYPE, args.optString("mime", "image/png"))
                }
                val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                    ?: return JSONObject().put("ok", false).put("error", "MediaStore insert failed")
                context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                JSONObject().put("ok", true).put("uri", uri.toString()).put("size", bytes.size)
            } catch (e: Throwable) {
                JSONObject().put("ok", false).put("error", e.message)
            }
        }
        return JSONObject().put("ok", false).put("error", "unknown op: $op")
    }
}
