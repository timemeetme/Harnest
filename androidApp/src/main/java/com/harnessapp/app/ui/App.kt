package com.harnessapp.app.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.harnessapp.app.ui.components.ConnectionSheet
import com.harnessapp.app.ui.layouts.AdaptiveScaffold
import com.harnessapp.shared.ui.AppViewModel
import com.harnessapp.shared.ui.ConnectionStatus
import com.harnessapp.shared.ui.UiState
import com.harnessapp.shared.ui.WindowSize

@Composable
fun HarnessApp(
    viewModel: AppViewModel,
    state: UiState,
    windowSize: WindowSize,
) {
    var forceConnectionSheet by remember { mutableStateOf(state.connection.status == ConnectionStatus.Disconnected) }

    Surface(Modifier.fillMaxSize()) {
        AdaptiveScaffold(
            state = state,
            windowSize = windowSize,
            onToggleSidebar = viewModel::toggleSidebar,
            onToggleDetails = viewModel::toggleDetails,
            onSelectDetailsTab = viewModel::selectDetailsTab,
            onNewSession = viewModel::newSession,
            onSelectSession = viewModel::selectSession,
            onDeleteSession = viewModel::deleteSession,
            onSendMessage = viewModel::sendMessage,
            onUpdateInput = viewModel::updateInput,
            onSetGoal = viewModel::setGoal,
            onAddTodo = viewModel::addTodo,
            onToggleTodo = viewModel::toggleTodo,
            onDeleteTodo = viewModel::deleteTodo,
            onDisconnect = viewModel::disconnectKernel,
            onOpenConnection = { forceConnectionSheet = true },
        )
    }

    if (forceConnectionSheet || state.connection.status == ConnectionStatus.Error) {
        ConnectionSheet(
            state = state,
            onConnect = { host, port, tls, provider, model ->
                viewModel.connectKernel(host, port, tls, provider, model)
                forceConnectionSheet = false
            },
            onDismiss = {
                if (state.connection.status == ConnectionStatus.Connected) {
                    forceConnectionSheet = false
                }
            },
        )
    }
}
