package com.harnest.app.platform

actual fun nowMs(): Long = System.currentTimeMillis()

actual fun appFilesDir(): String = System.getProperty("user.home") + "/.harnest"

actual fun defaultKernelHost(): String = "localhost"
