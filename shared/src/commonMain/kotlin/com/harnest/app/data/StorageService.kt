package com.harnest.app.data

import com.harnest.app.core.HarnessConstants
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okio.FileSystem
import okio.Path.Companion.toPath

object StorageService {
    private val fs = FileSystem.SYSTEM

    @PublishedApi
    internal val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
        isLenient = true
    }

    private var baseDir: okio.Path = "".toPath()

    fun init(filesDir: String) {
        baseDir = (filesDir + "/" + HarnessConstants.APP_DIR).toPath()
        ensureDirPath(baseDir)
    }

    fun isInitialized(): Boolean = baseDir.name.isNotEmpty()

    fun getBaseDir(): String = baseDir.toString()

    private fun ensureDirPath(path: okio.Path) {
        try {
            fs.createDirectories(path)
        } catch (_: Exception) {
        }
    }

    fun writeText(path: String, text: String): Boolean {
        return try {
            val p = path.toPath()
            p.parent?.let { ensureDirPath(it) }
            val tmp = (path + ".tmp").toPath()
            fs.write(tmp) { writeUtf8(text) }
            fs.atomicMove(tmp, p)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun readText(path: String): String {
        return try {
            val p = path.toPath()
            if (!fs.exists(p)) return ""
            fs.read(p) { readUtf8() }
        } catch (_: Exception) {
            ""
        }
    }

    inline fun <reified T> readJson(path: String): T? {
        val txt = readText(path)
        if (txt.isEmpty()) return null
        return try {
            json.decodeFromString<T>(txt)
        } catch (_: Exception) {
            null
        }
    }

    inline fun <reified T> writeJson(path: String, obj: T): Boolean {
        val text = try {
            json.encodeToString(obj)
        } catch (_: Exception) {
            return false
        }
        return writeText(path, text)
    }

    fun pathApiConfig(): String = "${getBaseDir()}/${HarnessConstants.FILE_API_CONFIG}"
    fun pathKernelConfig(): String = "${getBaseDir()}/${HarnessConstants.FILE_KERNEL_CONFIG}"
    fun pathPrefs(): String = "${getBaseDir()}/${HarnessConstants.FILE_PREFS}"
}
