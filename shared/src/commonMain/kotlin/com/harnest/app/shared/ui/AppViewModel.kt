package com.harnest.app.shared.ui

import com.harnest.app.core.AiProvider
import com.harnest.app.core.PROVIDER_META
import com.harnest.app.data.ConfigService
import com.harnest.app.data.StorageService
import com.harnest.app.dsh.kernel.KernelManager
import com.harnest.app.dsh.kernel.KernelMode
import com.harnest.app.dsh.model.AgentStatus
import com.harnest.app.dsh.model.DshNotification
import com.harnest.app.model.LlmConfig
import com.harnest.app.model.ProviderConfig
import com.harnest.app.platform.appFilesDir
import com.harnest.app.platform.defaultKernelHost
import com.harnest.app.platform.nowMs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

class AppViewModel(
    val kernelManager: KernelManager = KernelManager(),
    val scope: CoroutineScope = CoroutineScope(Dispatchers.Default + SupervisorJob()),
) {
    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var notifJob: kotlinx.coroutines.Job? = null

    init {
        if (!StorageService.isInitialized()) {
            StorageService.init(appFilesDir())
        }
        val cfg = ConfigService.load()
        val active = cfg.configs[cfg.activeProvider.value]
        _state.value = _state.value.copy(
            connection = _state.value.connection.copy(host = defaultKernelHost()),
            settings = _state.value.settings.copy(
                provider = cfg.activeProvider.value,
                model = active?.model ?: PROVIDER_META[cfg.activeProvider.value]?.defaultModel ?: "",
            )
        )
    }

    fun observeState(onEach: (UiState) -> Unit): () -> Unit {
        val job = scope.launch { state.collect { onEach(it) } }
        return { job.cancel() }
    }

    fun onWindowSizeChanged(size: WindowSize) {
        _state.value = _state.value.copy(
            detailsOpen = size.widthClass != WindowWidthClass.Compact && _state.value.detailsOpen,
            sidebarOpen = size.widthClass != WindowWidthClass.Compact || _state.value.sidebarOpen,
        )
    }

    fun toggleSidebar() {
        _state.value = _state.value.copy(sidebarOpen = !_state.value.sidebarOpen)
    }

    fun toggleDetails() {
        _state.value = _state.value.copy(detailsOpen = !_state.value.detailsOpen)
    }

    fun selectDetailsTab(tab: DetailsTab) {
        _state.value = _state.value.copy(detailsTab = tab, detailsOpen = true)
    }

    fun updateInput(text: String) {
        _state.value = _state.value.copy(inputText = text)
    }

    fun setGoal(text: String) {
        _state.value = _state.value.copy(goal = GoalState(text = text, active = text.isNotBlank()))
    }

    fun selectSession(sessionId: String) {
        _state.value = _state.value.copy(activeSessionId = sessionId)
    }

    fun newSession(): String {
        val id = "session-${nowMs()}"
        val session = SessionUi(
            id = id,
            title = "新会话",
            updatedAt = nowMs(),
            messageCount = 0,
        )
        _state.value = _state.value.copy(
            sessions = listOf(session) + _state.value.sessions,
            activeSessionId = id,
            messages = emptyList(),
        )
        return id
    }

    fun deleteSession(sessionId: String) {
        val newList = _state.value.sessions.filter { it.id != sessionId }
        val newActive = if (_state.value.activeSessionId == sessionId) {
            newList.firstOrNull()?.id
        } else _state.value.activeSessionId
        _state.value = _state.value.copy(
            sessions = newList,
            activeSessionId = newActive,
            messages = if (_state.value.activeSessionId == sessionId) emptyList() else _state.value.messages,
        )
    }

    fun connectKernel(
        host: String,
        port: Int,
        useTls: Boolean,
        provider: String,
        model: String,
        cwd: String = "",
    ) {
        ConfigService.setActiveProvider(AiProvider.fromValue(provider))
        scope.launch {
            _state.value = _state.value.copy(
                connection = _state.value.connection.copy(
                    host = host, port = port, useTls = useTls,
                    provider = provider, model = model,
                    status = ConnectionStatus.Connecting,
                ),
                workspace = _state.value.workspace.copy(path = cwd),
            )
            val mode = KernelMode.Remote(host, port, useTls)
            kernelManager.connect(mode)
                .onSuccess { client ->
                    _state.value = _state.value.copy(
                        connection = _state.value.connection.copy(
                            status = ConnectionStatus.Connected,
                        ),
                    )
                    subscribeNotifications()
                    runCatching {
                        val rows = client.sessionList()
                        _state.value = _state.value.copy(
                            sessions = rows.map { r ->
                                SessionUi(
                                    id = r.id,
                                    title = r.title,
                                    updatedAt = r.updatedAt,
                                    messageCount = 0,
                                    isRunning = r.running,
                                )
                            }
                        )
                    }
                    if (_state.value.sessions.isEmpty()) {
                        newSession()
                    }
                }
                .onFailure {
                    _state.value = _state.value.copy(
                        connection = _state.value.connection.copy(
                            status = ConnectionStatus.Error,
                        ),
                    )
                }
        }
    }

    fun disconnectKernel() {
        scope.launch {
            notifJob?.cancel()
            notifJob = null
            kernelManager.disconnect()
            _state.value = _state.value.copy(
                connection = _state.value.connection.copy(status = ConnectionStatus.Disconnected),
            )
        }
    }

    private fun subscribeNotifications() {
        val client = kernelManager.client ?: return
        notifJob?.cancel()
        notifJob = scope.launch {
            client.subscribe { notif -> handleNotification(notif) }
        }
    }

    private fun handleNotification(notif: DshNotification) {
        when (notif) {
            is DshNotification.SessionEvent -> {
                _state.value = _state.value.copy(
                    sessions = _state.value.sessions.map { s ->
                        if (s.id == notif.sessionId) s.copy(updatedAt = nowMs()) else s
                    },
                )
            }
            is DshNotification.SessionStatus -> {
                val running = notif.status == AgentStatus.Running
                _state.value = _state.value.copy(
                    sessions = _state.value.sessions.map { s ->
                        if (s.id == notif.sessionId) s.copy(isRunning = running) else s
                    },
                )
            }
            is DshNotification.SubagentStarted -> {
                _state.value = _state.value.copy(
                    subagents = _state.value.subagents + SubagentUi(
                        id = notif.childSessionId,
                        name = "子代理 ${notif.childSessionId.takeLast(8)}",
                        parentSessionId = notif.parentSessionId,
                        status = SubagentStatus.Running,
                    ),
                )
            }
            is DshNotification.SubagentFinished -> {
                _state.value = _state.value.copy(
                    subagents = _state.value.subagents.filter { it.id != notif.childSessionId },
                )
            }
            is DshNotification.Unknown -> Unit
        }
    }

    fun sendMessage(content: String) {
        val sessionId = _state.value.activeSessionId ?: return
        if (content.isBlank()) return

        val userMsg = ChatMessage(
            id = "msg-${nowMs()}",
            role = MessageRole.User,
            content = content,
            createdAt = nowMs(),
        )
        _state.value = _state.value.copy(
            messages = _state.value.messages + userMsg,
            inputText = "",
            isStreaming = true,
            sessions = _state.value.sessions.map { s ->
                if (s.id == sessionId) s.copy(
                    messageCount = s.messageCount + 1,
                    updatedAt = nowMs(),
                    isRunning = true,
                ) else s
            },
        )

        val client = kernelManager.client ?: return
        scope.launch {
            runCatching {
                client.prompt(sessionId, content, _state.value.workspace.path.ifBlank { null })
            }
            _state.value = _state.value.copy(isStreaming = false)
        }
    }

    fun updateSettings(settings: SettingsUi) {
        _state.value = _state.value.copy(settings = settings)
    }

    fun addTodo(content: String) {
        val todos = _state.value.todos
        _state.value = _state.value.copy(
            todos = todos + TodoItemUi(
                id = "todo-${nowMs()}",
                content = content,
                done = false,
                order = todos.size,
            ),
        )
    }

    fun toggleTodo(id: String) {
        _state.value = _state.value.copy(
            todos = _state.value.todos.map {
                if (it.id == id) it.copy(done = !it.done) else it
            },
        )
    }

    fun deleteTodo(id: String) {
        _state.value = _state.value.copy(
            todos = _state.value.todos.filter { it.id != id },
        )
    }

    fun updateLlmConfig(provider: AiProvider, apiKey: String, model: String, baseUrl: String) {
        val meta = PROVIDER_META[provider.value]
        val cfg = ProviderConfig(
            provider = provider,
            apiKey = apiKey,
            model = model.ifBlank { meta?.defaultModel ?: model },
            baseUrl = baseUrl.ifBlank { meta?.baseUrl ?: baseUrl },
            enabled = apiKey.trim().isNotEmpty()
        )
        ConfigService.setProviderConfig(cfg)
        _state.value = _state.value.copy(
            settings = _state.value.settings.copy(
                provider = provider.value,
                model = cfg.model,
            )
        )
    }

    fun importLlmConfig(jsonStr: String): Int = ConfigService.importConfigJson(jsonStr)

    fun exportLlmConfig(): String = ConfigService.exportConfigJson()

    fun loadLlmConfig(): LlmConfig = ConfigService.load()

    fun setActiveProvider(provider: AiProvider) {
        ConfigService.setActiveProvider(provider)
        val active = ConfigService.getProviderConfig(provider)
        _state.value = _state.value.copy(
            settings = _state.value.settings.copy(
                provider = provider.value,
                model = active.model,
            )
        )
    }

    fun resetAllConfigs() {
        ConfigService.resetAll()
        ConfigService.load()
    }

    fun testKernelConnection(
        host: String,
        port: Int,
        useTls: Boolean,
        provider: String,
        model: String,
    ) = scope.async<Result<String>> {
        runCatching {
            val mode = KernelMode.Remote(host, port, useTls)
            withTimeout(5000L) {
                kernelManager.connect(mode).getOrThrow()
            }
        }.fold(
            onSuccess = { Result.success("连接成功") },
            onFailure = { Result.failure(it) }
        )
    }

    fun updateSettingsTheme(theme: String) {
        _state.value = _state.value.copy(
            settings = _state.value.settings.copy(theme = theme),
        )
    }

    fun updateSettingsLanguage(lang: String) {
        _state.value = _state.value.copy(
            settings = _state.value.settings.copy(language = lang),
        )
    }

    fun updateSettingsAutoApprove(auto: Boolean) {
        _state.value = _state.value.copy(
            settings = _state.value.settings.copy(autoApprove = auto),
        )
    }
}
