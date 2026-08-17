package com.harnest.app.platform

import android.content.Context

private var _filesDir: String = ""

fun initAppDir(context: Context) {
    _filesDir = context.filesDir.absolutePath
}

actual fun nowMs(): Long = System.currentTimeMillis()

actual fun appFilesDir(): String = _filesDir

actual fun defaultKernelHost(): String = "127.0.0.1"
