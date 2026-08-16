package com.harnessapp.shared.ui

import com.harnessapp.dsh.kernel.KernelManager
import com.harnessapp.dsh.kernel.KernelMode
import com.harnessapp.dsh.model.DshNotification
import com.harnessapp.dsh.model.InitializeParams
import com.harnessapp.dsh.model.SessionEventNotification
import com.harnessapp.dsh.model.SessionPromptParams
import com.harnessapp.dsh.model.SessionStatusNotification
import com.harnessapp.dsh.model.SubagentFinishedNotification
import com.harnessapp.dsh.model.SubagentStartedNotification
import com.harnessapp.dsh.transport.dshJson
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive

/**
 * 跨三端共享的 App ViewModel。
 * 提供所有 UI 状态和业务动作；三端各自用原生 UI 框架渲染。
 */
class AppViewModel(
    val kernelManager: KernelManager = KernelManager(),
    val scope: CoroutineScope = CoroutineScope(Dispatchers.Default + SupervisorJob()),
) {
    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private var notifJob: kotlinx.coroutines.Job? = null

    /**
     * iOS / 原生桥接：订阅 state 变化。
     * 返回一个取消闭包（Swift: () -> Void），调用即停止观察。
     */
    fun observeState(onEach: (UiState) -> Unit): () -> Unit {
        val job = scope.launch {
            state.collect { onEach(it) }
        }
        return { job.cancel() }
    }

    fun onWindowSizeChanged(size: WindowSize) {
        // 响应式：折叠态下默认收起 details
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
        val id = "session-${System.currentTimeMillis()}"
        val session = SessionUi(
            id = id,
            title = "新会话",
            updatedAt = System.currentTimeMillis(),
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
            val params = InitializeParams(
                cwd = cwd.ifBlank { "/tmp" },
                provider = provider,
                model = model,
            )
            kernelManager.connect(mode, params)
                .onSuccess { result ->
                    _state.value = _state.value.copy(
                        connection = _state.value.connection.copy(
                            status = ConnectionStatus.Connected,
                            serverName = result.serverInfo.name,
                            serverVersion = result.serverInfo.version,
                        ),
                    )
                    subscribeNotifications()
                    if (_state.value.sessions.isEmpty()) {
                        newSession()
                    }
                }
                .onFailure { err ->
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
            client.subscribe { notif ->
                handleNotification(notif)
            }
        }
    }

    private fun handleNotification(notif: DshNotification) {
        when (notif) {
            is DshNotification.SessionEvent -> handleSessionEvent(notif.payload)
            is DshNotification.SessionStatus -> {
                val running = notif.payload.status.name == "running"
                _state.value = _state.value.copy(
                    sessions = _state.value.sessions.map { s ->
                        if (s.id == notif.payload.sessionId) s.copy(isRunning = running) else s
                    },
                )
            }
            is DshNotification.SubagentStarted -> {
                _state.value = _state.value.copy(
                    subagents = _state.value.subagents + SubagentUi(
                        id = notif.payload.childSessionId,
                        name = "子代理 ${notif.payload.childSessionId.takeLast(8)}",
                        parentSessionId = notif.payload.parentSessionId,
                        status = SubagentStatus.Running,
                    ),
                )
            }
            is DshNotification.SubagentFinished -> {
                _state.value = _state.value.copy(
                    subagents = _state.value.subagents.filter { it.id != notif.payload.childSessionId },
                )
            }
            is DshNotification.Unknown -> Unit
        }
    }

    private fun handleSessionEvent(payload: SessionEventNotification) {
        // 简化处理：把 event JSON 里的内容转成 UI 状态
        val eventJson = payload.event
        // 粗略启发式：根据 event.type 或 action 字段分派
        val text = eventJson.toString()
        if (text.contains("\"role\":\"user\"") || text.contains("\"role\": \"user\"")) {
            // 用户消息
        }
        _state.value = _state.value.copy(
            sessions = _state.value.sessions.map { s ->
                if (s.id == payload.sessionId) s.copy(updatedAt = System.currentTimeMillis()) else s
            },
        )
    }

    fun sendMessage(content: String) {
        val sessionId = _state.value.activeSessionId ?: return
        if (content.isBlank()) return

        val userMsg = ChatMessage(
            id = "msg-${System.currentTimeMillis()}",
            role = MessageRole.User,
            content = content,
            createdAt = System.currentTimeMillis(),
        )
        _state.value = _state.value.copy(
            messages = _state.value.messages + userMsg,
            inputText = "",
            isStreaming = true,
            sessions = _state.value.sessions.map { s ->
                if (s.id == sessionId) s.copy(
                    messageCount = s.messageCount + 1,
                    updatedAt = System.currentTimeMillis(),
                    isRunning = true,
                ) else s
            },
        )

        val client = kernelManager.client ?: return
        scope.launch {
            runCatching {
                client.prompt(
                    SessionPromptParams(
                        sessionId = sessionId,
                        contentBlocks = emptyList(),
                    )
                )
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
                id = "todo-${System.currentTimeMillis()}",
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
}
