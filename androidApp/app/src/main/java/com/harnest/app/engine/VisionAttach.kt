package com.harnest.app.engine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.ArrayDeque

/**
 * Vision attachment queue — photos captured via device_camera are downscaled,
 * base64-encoded and queued here; HttpBridge attaches them to the next
 * chat/completions request as image_url content parts so a multimodal model
 * can actually SEE the picture instead of only receiving file metadata.
 */
object VisionAttach {

    private val queue = ArrayDeque<String>()
    private val lock = Any()

    /** Downscale a photo and enqueue it as a data URL. Returns false on decode failure. */
    fun pushFile(file: File, maxDim: Int = 1280, quality: Int = 80): Boolean {
        val dataUrl = downscaleToDataUrl(file, maxDim, quality) ?: return false
        synchronized(lock) { queue.addLast(dataUrl) }
        return true
    }

    /** Take all queued images (each consumed at most once, by the next chat request). */
    fun drain(): List<String> = synchronized(lock) {
        val out = queue.toList()
        queue.clear()
        out
    }

    fun hasPending(): Boolean = synchronized(lock) { queue.isNotEmpty() }

    /** JPEG -> sampled/scaled bitmap -> compressed JPEG -> data:image/jpeg;base64 URL. */
    fun downscaleToDataUrl(file: File, maxDim: Int, quality: Int): String? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= maxDim && bounds.outHeight / (sample * 2) >= maxDim) {
                sample *= 2
            }
            val src = BitmapFactory.decodeFile(file.absolutePath, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return null
            val maxSide = maxOf(src.width, src.height)
            val bmp = if (maxSide > maxDim) {
                val scale = maxDim.toFloat() / maxSide
                Bitmap.createScaledBitmap(
                    src,
                    (src.width * scale).toInt().coerceAtLeast(1),
                    (src.height * scale).toInt().coerceAtLeast(1),
                    true
                )
            } else src
            val bos = ByteArrayOutputStream()
            if (!bmp.compress(Bitmap.CompressFormat.JPEG, quality, bos)) return null
            "data:image/jpeg;base64," + Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP)
        } catch (e: Throwable) {
            null
        }
    }
}
