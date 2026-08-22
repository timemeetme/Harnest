package com.harnest.app.engine

/**
 * Stream-safe UTF-8 decoder: holds back incomplete multi-byte sequences at
 * chunk boundaries (mirrors TextDecoder streaming on the HarmonyOS side).
 */
class Utf8StreamDecoder {
    private var pending = ByteArray(0)

    fun decode(chunk: ByteArray, length: Int): String {
        val buf = if (pending.isEmpty()) chunk.copyOf(length) else pending + chunk.copyOf(length)
        var i = 0
        var seqStart = 0
        while (i < buf.size) {
            val b = buf[i].toInt() and 0xFF
            val seqLen = when {
                b < 0x80 -> 1
                b and 0xE0 == 0xC0 -> 2
                b and 0xF0 == 0xE0 -> 3
                b and 0xF8 == 0xF0 -> 4
                else -> 1 // invalid byte — treat as single, decoder will replace
            }
            if (i + seqLen > buf.size) break // incomplete sequence at tail
            i += seqLen
            seqStart = i
        }
        val complete = buf.copyOfRange(0, seqStart)
        pending = buf.copyOfRange(seqStart, buf.size)
        return String(complete, Charsets.UTF_8)
    }

    fun flush(): String {
        if (pending.isEmpty()) return ""
        val rest = String(pending, Charsets.UTF_8)
        pending = ByteArray(0)
        return rest
    }
}
