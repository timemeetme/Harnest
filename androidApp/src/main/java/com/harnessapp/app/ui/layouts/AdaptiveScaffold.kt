package com.harnessapp.app.ui.layouts

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.SheetState
import androidx.compose.material3.Surface
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.harnessapp.app.ui.components.ChatPane
import com.harnessapp.app.ui.components.DetailsPanel
import com.harnessapp.app.ui.components.GoalBar
import com.harnessapp.app.ui.components.InputBar
import com.harnessapp.app.ui.components.Sidebar
import com.harnessapp.app.ui.components.StatusBar
import com.harnessapp.shared.ui.DetailsTab
import com.harnessapp.shared.ui.UiState
import com.harnessapp.shared.ui.WindowSize
import com.harnessapp.shared.ui.WindowWidthClass
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdaptiveScaffold(
    state: UiState,
    windowSize: WindowSize,
    onToggleSidebar: () -> Unit,
    onToggleDetails: () -> Unit,
    onSelectDetailsTab: (DetailsTab) -> Unit,
    onNewSession: () -> Unit,
    onSelectSession: (String) -> Unit,
    onDeleteSession: (String) -> Unit,
    onSendMessage: (String) -> Unit,
    onUpdateInput: (String) -> Unit,
    onSetGoal: (String) -> Unit,
    onAddTodo: (String) -> Unit,
    onToggleTodo: (String) -> Unit,
    onDeleteTodo: (String) -> Unit,
    onDisconnect: () -> Unit,
    onOpenConnection: () -> Unit,
) {
    when (windowSize.widthClass) {
        WindowWidthClass.Compact -> CompactLayout(
            state = state,
            onNewSession = onNewSession,
            onSelectSession = onSelectSession,
            onDeleteSession = onDeleteSession,
            onSendMessage = onSendMessage,
            onUpdateInput = onUpdateInput,
            onSetGoal = onSetGoal,
            onSelectDetailsTab = onSelectDetailsTab,
            onAddTodo = onAddTodo,
            onToggleTodo = onToggleTodo,
            onDeleteTodo = onDeleteTodo,
            onDisconnect = onDisconnect,
            onOpenConnection = onOpenConnection,
        )
        WindowWidthClass.Medium -> MediumLayout(
            state = state,
            onNewSession = onNewSession,
            onSelectSession = onSelectSession,
            onDeleteSession = onDeleteSession,
            onSendMessage = onSendMessage,
            onUpdateInput = onUpdateInput,
            onSetGoal = onSetGoal,
            onSelectDetailsTab = onSelectDetailsTab,
            onAddTodo = onAddTodo,
            onToggleTodo = onToggleTodo,
            onDeleteTodo = onDeleteTodo,
            onDisconnect = onDisconnect,
            onOpenConnection = onOpenConnection,
        )
        WindowWidthClass.Expanded -> ExpandedLayout(
            state = state,
            windowSize = windowSize,
            onNewSession = onNewSession,
            onSelectSession = onSelectSession,
            onDeleteSession = onDeleteSession,
            onSendMessage = onSendMessage,
            onUpdateInput = onUpdateInput,
            onSetGoal = onSetGoal,
            onSelectDetailsTab = onSelectDetailsTab,
            onAddTodo = onAddTodo,
            onToggleTodo = onToggleTodo,
            onDeleteTodo = onDeleteTodo,
            onDisconnect = onDisconnect,
            onOpenConnection = onOpenConnection,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CompactLayout(
    state: UiState,
    onNewSession: () -> Unit,
    onSelectSession: (String) -> Unit,
    onDeleteSession: (String) -> Unit,
    onSendMessage: (String) -> Unit,
    onUpdateInput: (String) -> Unit,
    onSetGoal: (String) -> Unit,
    onSelectDetailsTab: (DetailsTab) -> Unit,
    onAddTodo: (String) -> Unit,
    onToggleTodo: (String) -> Unit,
    onDeleteTodo: (String) -> Unit,
    onDisconnect: () -> Unit,
    onOpenConnection: () -> Unit,
) {
    val drawerState = rememberDrawerState(initialValue = DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val detailsSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var showDetails by remember { mutableStateOf(false) }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            ModalDrawerSheet(modifier = Modifier.width(280.dp)) {
                Sidebar(
                    sessions = state.sessions,
                    activeSessionId = state.activeSessionId,
                    isRunning = state.isStreaming,
                    onNewSession = onNewSession,
                    onSelectSession = {
                        onSelectSession(it)
                        scope.launch { drawerState.close() }
                    },
                    onDeleteSession = onDeleteSession,
                    onOpenConnection = onOpenConnection,
                    onClose = { scope.launch { drawerState.close() } },
                )
            }
        },
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = { scope.launch { drawerState.open() } }) {
                    Icon(Icons.Default.Menu, contentDescription = null)
                }
                StatusBar(
                    connection = state.connection,
                    onOpenConnection = onOpenConnection,
                    onDisconnect = onDisconnect,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = { showDetails = true }) {
                    Icon(Icons.Default.Tune, contentDescription = null)
                }
            }

            GoalBar(goal = state.goal, onSetGoal = onSetGoal)

            ChatPane(
                messages = state.messages,
                isStreaming = state.isStreaming,
                modifier = Modifier.weight(1f),
            )

            InputBar(
                text = state.inputText,
                isStreaming = state.isStreaming,
                provider = state.settings.provider,
                model = state.settings.model,
                onUpdateInput = onUpdateInput,
                onSend = onSendMessage,
            )
        }
    }

    if (showDetails) {
        ModalBottomSheet(
            onDismissRequest = { showDetails = false },
            sheetState = detailsSheetState,
            containerColor = MaterialTheme.colorScheme.surface,
        ) {
            DetailsPanel(
                state = state,
                onSelectTab = onSelectDetailsTab,
                onAddTodo = onAddTodo,
                onToggleTodo = onToggleTodo,
                onDeleteTodo = onDeleteTodo,
                onClose = { showDetails = false },
                modifier = Modifier.fillMaxHeight(0.85f),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MediumLayout(
    state: UiState,
    onNewSession: () -> Unit,
    onSelectSession: (String) -> Unit,
    onDeleteSession: (String) -> Unit,
    onSendMessage: (String) -> Unit,
    onUpdateInput: (String) -> Unit,
    onSetGoal: (String) -> Unit,
    onSelectDetailsTab: (DetailsTab) -> Unit,
    onAddTodo: (String) -> Unit,
    onToggleTodo: (String) -> Unit,
    onDeleteTodo: (String) -> Unit,
    onDisconnect: () -> Unit,
    onOpenConnection: () -> Unit,
) {
    val drawerState = rememberDrawerState(initialValue = DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val detailsSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var showDetails by remember { mutableStateOf(state.detailsOpen) }

    Row(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Sidebar(
            sessions = state.sessions,
            activeSessionId = state.activeSessionId,
            isRunning = state.isStreaming,
            onNewSession = onNewSession,
            onSelectSession = onSelectSession,
            onDeleteSession = onDeleteSession,
            onOpenConnection = onOpenConnection,
            modifier = Modifier.width(240.dp).fillMaxHeight(),
        )

        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceContainerHighest)

        Column(modifier = Modifier.weight(1f)) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                StatusBar(
                    connection = state.connection,
                    onOpenConnection = onOpenConnection,
                    onDisconnect = onDisconnect,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = { showDetails = !showDetails }) {
                    Icon(Icons.Default.Tune, contentDescription = null)
                }
            }
            GoalBar(goal = state.goal, onSetGoal = onSetGoal)
            ChatPane(
                messages = state.messages,
                isStreaming = state.isStreaming,
                modifier = Modifier.weight(1f),
            )
            InputBar(
                text = state.inputText,
                isStreaming = state.isStreaming,
                provider = state.settings.provider,
                model = state.settings.model,
                onUpdateInput = onUpdateInput,
                onSend = onSendMessage,
            )
        }
    }

    if (showDetails) {
        ModalBottomSheet(
            onDismissRequest = { showDetails = false },
            sheetState = detailsSheetState,
            containerColor = MaterialTheme.colorScheme.surface,
        ) {
            DetailsPanel(
                state = state,
                onSelectTab = onSelectDetailsTab,
                onAddTodo = onAddTodo,
                onToggleTodo = onToggleTodo,
                onDeleteTodo = onDeleteTodo,
                onClose = { showDetails = false },
                modifier = Modifier.fillMaxHeight(0.75f),
            )
        }
    }
}

@Composable
private fun ExpandedLayout(
    state: UiState,
    windowSize: WindowSize,
    onNewSession: () -> Unit,
    onSelectSession: (String) -> Unit,
    onDeleteSession: (String) -> Unit,
    onSendMessage: (String) -> Unit,
    onUpdateInput: (String) -> Unit,
    onSetGoal: (String) -> Unit,
    onSelectDetailsTab: (DetailsTab) -> Unit,
    onAddTodo: (String) -> Unit,
    onToggleTodo: (String) -> Unit,
    onDeleteTodo: (String) -> Unit,
    onDisconnect: () -> Unit,
    onOpenConnection: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Sidebar(
            sessions = state.sessions,
            activeSessionId = state.activeSessionId,
            isRunning = state.isStreaming,
            onNewSession = onNewSession,
            onSelectSession = onSelectSession,
            onDeleteSession = onDeleteSession,
            onOpenConnection = onOpenConnection,
            modifier = Modifier.width(windowSize.sidebarWidth.dp).fillMaxHeight(),
        )

        HorizontalDivider(color = MaterialTheme.colorScheme.surfaceContainerHighest)

        Column(modifier = Modifier.weight(1f)) {
            StatusBar(
                connection = state.connection,
                onOpenConnection = onOpenConnection,
                onDisconnect = onDisconnect,
                modifier = Modifier.fillMaxWidth(),
            )
            GoalBar(goal = state.goal, onSetGoal = onSetGoal)
            ChatPane(
                messages = state.messages,
                isStreaming = state.isStreaming,
                modifier = Modifier.weight(1f),
            )
            InputBar(
                text = state.inputText,
                isStreaming = state.isStreaming,
                provider = state.settings.provider,
                model = state.settings.model,
                onUpdateInput = onUpdateInput,
                onSend = onSendMessage,
            )
        }

        if (state.detailsOpen) {
            HorizontalDivider(color = MaterialTheme.colorScheme.surfaceContainerHighest)
            DetailsPanel(
                state = state,
                onSelectTab = onSelectDetailsTab,
                onAddTodo = onAddTodo,
                onToggleTodo = onToggleTodo,
                onDeleteTodo = onDeleteTodo,
                modifier = Modifier.width(windowSize.detailsWidth.dp).fillMaxHeight(),
            )
        }
    }
}
