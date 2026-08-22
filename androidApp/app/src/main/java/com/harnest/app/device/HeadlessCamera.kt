package com.harnest.app.device

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/**
 * Headless still capture via camera2 — lets the agent take a photo with NO
 * user interaction (open back camera, let AF/AE converge on a repeating
 * preview request, then fire one STILL_CAPTURE).
 */
object HeadlessCamera {

    @SuppressLint("MissingPermission")
    suspend fun capture(context: Context, outFile: File, settleMs: Long = 1500L, front: Boolean = false): Boolean {
        val ok = withTimeoutOrNull(12_000L) { shoot(context, outFile, settleMs, front) }
        return ok == true && outFile.exists() && outFile.length() > 0L
    }

    private suspend fun shoot(context: Context, outFile: File, settleMs: Long, front: Boolean): Boolean {
        val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraId = pickCamera(cm, front) ?: return false
        val chars = cm.getCameraCharacteristics(cameraId)
        val size = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.getOutputSizes(ImageFormat.JPEG)
            ?.maxByOrNull { it.width.toLong() * it.height }
            ?: Size(1920, 1080)
        val orientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

        val reader = ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 3)
        val thread = HandlerThread("headless-cam").apply { start() }
        val handler = Handler(thread.looper)
        var session: CameraCaptureSession? = null
        var device: CameraDevice? = null
        try {
            device = openDevice(cm, cameraId, handler) ?: return false
            val surface = reader.surface
            val warm = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(surface)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            }.build()
            val still = device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(surface)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                set(CaptureRequest.JPEG_ORIENTATION, orientation)
            }.build()
            session = createSession(device, surface, handler) ?: return false
            session.setRepeatingRequest(warm, null, handler)
            val bytes = awaitImage(reader, session, still, settleMs, handler)
            try { session.stopRepeating() } catch (_: Throwable) {}
            if (bytes == null || bytes.isEmpty()) return false
            outFile.parentFile?.mkdirs()
            outFile.writeBytes(bytes)
            return true
        } catch (_: Throwable) {
            return false
        } finally {
            try { session?.close() } catch (_: Throwable) {}
            try { device?.close() } catch (_: Throwable) {}
            reader.close()
            thread.quitSafely()
        }
    }

    private fun pickCamera(cm: CameraManager, front: Boolean): String? {
        val ids = cm.cameraIdList
        val want = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        return ids.firstOrNull { id -> lensFacing(cm, id) == want }
            ?: if (front) null else ids.firstOrNull()
    }

    private fun lensFacing(cm: CameraManager, id: String): Int? = try {
        cm.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
    } catch (_: Throwable) {
        null
    }

    private suspend fun openDevice(cm: CameraManager, id: String, handler: Handler): CameraDevice? =
        suspendCancellableCoroutine { cont ->
            try {
                cm.openCamera(id, object : CameraDevice.StateCallback() {
                    override fun onOpened(d: CameraDevice) { if (cont.isActive) cont.resume(d) }
                    override fun onDisconnected(d: CameraDevice) { d.close(); if (cont.isActive) cont.resume(null) }
                    override fun onError(d: CameraDevice, code: Int) { d.close(); if (cont.isActive) cont.resume(null) }
                }, handler)
            } catch (_: Throwable) {
                if (cont.isActive) cont.resume(null)
            }
        }

    @Suppress("DEPRECATION")
    private suspend fun createSession(device: CameraDevice, surface: Surface, handler: Handler): CameraCaptureSession? =
        suspendCancellableCoroutine { cont ->
            try {
                device.createCaptureSession(listOf(surface), object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) { if (cont.isActive) cont.resume(s) }
                    override fun onConfigureFailed(s: CameraCaptureSession) { s.close(); if (cont.isActive) cont.resume(null) }
                }, handler)
            } catch (_: Throwable) {
                if (cont.isActive) cont.resume(null)
            }
        }

    /**
     * Drain warming frames until armed, then return the next JPEG bytes
     * (produced by the explicit STILL_CAPTURE fired at arm time).
     */
    private suspend fun awaitImage(
        reader: ImageReader,
        session: CameraCaptureSession,
        still: CaptureRequest,
        settleMs: Long,
        handler: Handler
    ): ByteArray? = suspendCancellableCoroutine { cont ->
        val armed = AtomicBoolean(false)
        reader.setOnImageAvailableListener({ r ->
            try {
                val img = r.acquireLatestImage() ?: return@setOnImageAvailableListener
                if (armed.get() && cont.isActive) {
                    val buf = img.planes[0].buffer
                    val bytes = ByteArray(buf.remaining()).also { buf.get(it) }
                    img.close()
                    r.setOnImageAvailableListener(null, null)
                    cont.resume(bytes)
                } else {
                    img.close()
                }
            } catch (_: Throwable) {
                if (cont.isActive) cont.resume(null)
            }
        }, handler)
        handler.postDelayed({
            armed.set(true)
            try {
                session.capture(still, null, handler)
            } catch (_: Throwable) {
                if (cont.isActive) cont.resume(null)
            }
        }, settleMs)
    }
}
