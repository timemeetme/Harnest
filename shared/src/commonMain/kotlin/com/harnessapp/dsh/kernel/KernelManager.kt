package com.harnessapp.dsh.kernel

import com.harnessapp.dsh.sdk.DshClient
import com.harnessapp.dsh.transport.DshTransportFactory
import com.harnessapp.dsh.transport.TransportType
import kotlinx.coroutines.*

/**
 * 内核连接模式 — 决定 dsh-client 连接到哪里的核心运行时。
 */
sealed interface KernelMode {
    /** 远程模式：连接到云端或局域网 PC 上的完整 dsh 实例 */
    data class Remote(val host: String, val port: Int = 3080, val useTls: Boolean = false) : KernelMode

    /** Android 本地模式：通过内嵌 Node.js runtime 运行精简 dsh headless */
    data object Local : KernelMode

    /**
     * 混合模式：优先连接指定地址，失败时 fallback 到本地（如果可用）。
     * 这是推荐的首发模式。
     */
    data class Hybrid(val primary: Remote, val fallbackToLocal: Boolean = true) : KernelMode
}

/**
 * 内核管理器 — 负责 DshClient 的生命周期和内核连接状态。
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

    suspend fun connect(mode: KernelMode, initializeParams: com.harnessapp.dsh.model.InitializeParams): Result<com.harnessapp.dsh.model.InitializeResult> {
        disconnect()
        this.mode = mode
        return when (mode) {
            is KernelMode.Remote -> connectRemote(mode, initializeParams)
            is KernelMode.Local -> connectLocal(initializeParams)
            is KernelMode.Hybrid -> connectHybrid(mode, initializeParams)
        }
    }

    suspend fun disconnect() {
        client?.let { runCatching { it.disconnect() } }
        client = null
    }

    private suspend fun connectRemote(remote: KernelMode.Remote, params: com.harnessapp.dsh.model.InitializeParams): Result<com.harnessapp.dsh.model.InitializeResult> {
        val protocol = if (remote.useTls) "wss" else "ws"
        val endpoint = "$protocol://${remote.host}:${remote.port}"
        val c = DshClient(DshTransportFactory.create(TransportType.WEBSOCKET), appScope)
        return runCatching {
            c.connect(endpoint)
            val result = c.initialize(params)
            client = c
            result
        }.onFailure { runCatching { c.disconnect() } }
    }

    private suspend fun connectLocal(params: com.harnessapp.dsh.model.InitializeParams): Result<com.harnessapp.dsh.model.InitializeResult> {
        return Result.failure(UnsupportedOperationException("Local mode not yet available on this platform"))
    }

    private suspend fun connectHybrid(hybrid: KernelMode.Hybrid, params: com.harnessapp.dsh.model.InitializeParams): Result<com.harnessapp.dsh.model.InitializeResult> {
        val remoteResult = connectRemote(hybrid.primary, params)
        if (remoteResult.isSuccess) return remoteResult
        if (hybrid.fallbackToLocal) {
            val localResult = connectLocal(params)
            if (localResult.isSuccess) return localResult
        }
        return remoteResult
    }
}
