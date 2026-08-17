package com.harnest.app.dsh.kernel

import com.harnest.app.dsh.sdk.DshClient
import com.harnest.app.dsh.transport.DshTransportFactory
import kotlinx.coroutines.*

/**
 * 内核连接模式 — 决定 DshClient 连接到哪里的核心运行时。
 */
sealed interface KernelMode {
    /** 远程模式：连接到云端或局域网 PC 上的完整 dsh 实例 */
    data class Remote(val host: String, val port: Int = 3080, val useTls: Boolean = false) : KernelMode

    /** Android 本地模式：通过内嵌 Node.js runtime 运行精简 dsh headless */
    data object Local : KernelMode

    data class Hybrid(val primary: Remote, val fallbackToLocal: Boolean = true) : KernelMode
}

/**
 * 内核管理器 — 负责 DshClient 的生命周期和内核连接状态。
 * deepseek-harness 没有 handshake 概念：connect 后直接 session.list 验证可达。
 */
class KernelManager(
    scope: CoroutineScope = CoroutineScope(Dispatchers.Default + SupervisorJob()),
) {
    private val appScope = scope

    @Volatile
    var client: DshClient? = null
        private set

    @Volatile
    var mode: KernelMode? = null
        private set

    val isReady: Boolean get() = client?.isConnected == true

    suspend fun connect(mode: KernelMode): Result<DshClient> {
        disconnect()
        this.mode = mode
        return when (mode) {
            is KernelMode.Remote -> connectRemote(mode)
            is KernelMode.Local -> connectLocal()
            is KernelMode.Hybrid -> connectHybrid(mode)
        }
    }

    suspend fun disconnect() {
        client?.let { runCatching { it.disconnect() } }
        client = null
    }

    private suspend fun connectRemote(remote: KernelMode.Remote): Result<DshClient> {
        val protocol = if (remote.useTls) "https" else "http"
        val baseUrl = "$protocol://${remote.host}:${remote.port}"
        println("[KernelManager] connectRemote -> $baseUrl")
        val c = DshClient(DshTransportFactory.create(), appScope)
        return runCatching {
            println("[KernelManager] DshClient.connect($baseUrl)...")
            c.connect(baseUrl)
            println("[KernelManager] WS connected, session.list probe...")
            val sessions = c.sessionList()
            println("[KernelManager] OK — ${sessions.size} sessions listed")
            client = c
            c
        }.onFailure { err ->
            System.err.println("[KernelManager] FAILED: ${err::class.simpleName}: ${err.message}")
            err.printStackTrace(System.err)
            runCatching { c.disconnect() }
        }
    }

    private suspend fun connectLocal(): Result<DshClient> =
        Result.failure(UnsupportedOperationException("Local mode not yet available on this platform"))

    private suspend fun connectHybrid(hybrid: KernelMode.Hybrid): Result<DshClient> {
        val remoteResult = connectRemote(hybrid.primary)
        if (remoteResult.isSuccess) return remoteResult
        if (hybrid.fallbackToLocal) {
            val localResult = connectLocal()
            if (localResult.isSuccess) return localResult
        }
        return remoteResult
    }
}
