package com.harnest.app.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Sync fs bridge — mirrors qjs_fs_call in harness_engine.cpp.
 * Sandbox: all paths resolve under engine.sandboxRoot; prefix-checked.
 */
object FsBridge {

    fun handle(engine: HarnessEngine, reqJson: String): String {
        return try {
            val req = JSONObject(reqJson)
            val op = req.optString("op", "")
            val path = req.optString("path", "")
            val resolved = resolve(engine, path)
                ?: return err("path escapes sandbox: $path")
            when (op) {
                "exists" -> JSONObject().put("exists", resolved.exists())
                "readFile" -> run {
                    if (!resolved.isFile) return@run err("open failed: $path")
                    val bytes = resolved.readBytes()
                    val isText = req.optBoolean("text", true)
                    if (isText) {
                        JSONObject().put("ok", true).put("data", String(bytes, Charsets.UTF_8))
                    } else {
                        JSONObject().put("ok", true).put("data", android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP))
                    }
                }
                "writeFile" -> run {
                    val data = req.optString("data", "")
                    val isB64 = req.optBoolean("base64", false)
                    resolved.parentFile?.mkdirs()
                    try {
                        if (isB64) {
                            resolved.writeBytes(android.util.Base64.decode(data, android.util.Base64.NO_WRAP))
                        } else {
                            resolved.writeText(data, Charsets.UTF_8)
                        }
                        JSONObject().put("ok", true)
                    } catch (e: Throwable) {
                        err("write failed: ${e.message}")
                    }
                }
                "readdir" -> run {
                    if (!resolved.isDirectory) return@run err("not a directory")
                    val entries = JSONArray()
                    resolved.listFiles()?.forEach { entries.put(it.name) }
                    JSONObject().put("ok", true).put("entries", entries)
                }
                "mkdir" -> run {
                    val rec = req.optBoolean("recursive", true)
                    val ok = if (rec) resolved.mkdirs() else resolved.mkdir()
                    JSONObject().put("ok", ok || resolved.isDirectory)
                }
                "rm" -> run {
                    val rec = req.optBoolean("recursive", false)
                    val ok = if (rec) resolved.deleteRecursively() else resolved.delete()
                    JSONObject().put("ok", ok)
                }
                "stat" -> run {
                    if (!resolved.exists()) return@run err("not found: $path")
                    val isDir = resolved.isDirectory
                    JSONObject().put("ok", true)
                        .put("isDir", isDir)
                        .put("size", if (isDir) 0L else resolved.length())
                        .put("mtimeMs", resolved.lastModified())
                }
                "rename" -> run {
                    val newPath = req.optString("newPath", "")
                    val target = resolve(engine, newPath)
                        ?: return@run err("path escapes sandbox: $newPath")
                    if (!resolved.exists()) return@run err("not found: $path")
                    try {
                        target.parentFile?.mkdirs()
                        if (target.exists() && !target.delete()) return@run err("rename failed: target busy")
                        if (resolved.renameTo(target)) JSONObject().put("ok", true)
                        else err("rename failed: $path")
                    } catch (e: Throwable) {
                        err("rename failed: ${e.message}")
                    }
                }
                "realpath" -> JSONObject().put("ok", true).put("path", resolved.path)
                else -> err("unknown op: $op")
            }.toString()
        } catch (e: Throwable) {
            err("fs bridge error: ${e.message}")
        }
    }

    /** Resolve path inside sandbox; null when it escapes. */
    fun resolve(engine: HarnessEngine, path: String): File? {
        val root = engine.sandboxRoot
        return try {
            val f = if (path.startsWith("/")) File(path) else File(root, path)
            val canonical = f.canonicalFile
            val rootCanonical = root.canonicalFile
            if (canonical == rootCanonical || canonical.path.startsWith(rootCanonical.path + File.separator)) {
                canonical
            } else null
        } catch (e: Throwable) {
            null
        }
    }

    private fun err(msg: String): String = JSONObject().put("ok", false).put("error", msg).toString()
}
