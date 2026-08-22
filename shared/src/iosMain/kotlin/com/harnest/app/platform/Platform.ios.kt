package com.harnest.app.platform

import platform.Foundation.NSDate
import platform.Foundation.timeIntervalSince1970

actual fun nowMs(): Long = (NSDate().timeIntervalSince1970 * 1000).toLong()

actual fun appFilesDir(): String {
    val home = platform.Foundation.NSHomeDirectory()
    return "$home/.harnest"
}

actual fun defaultKernelHost(): String = "localhost"
