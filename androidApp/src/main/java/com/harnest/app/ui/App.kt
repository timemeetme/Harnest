package com.harnest.app.app.ui

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import com.harnest.app.app.ui.components.ConnectionSheet
import com.harnest.app.app.ui.layouts.AdaptiveScaffold
import com.harnest.app.shared.ui.AppViewModel
import com.harnest.app.shared.ui.ConnectionStatus
import com.harnest.app.shared.ui.UiState
import com.harnest.app.shared.ui.WindowSize
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@Composable
fun HarnessApp(
    viewModel: AppViewModel,
    state: UiState,
    windowSize: WindowSize,
) {
    val context = LocalContext.current
    var forceConnectionSheet by remember { mutableStateOf(state.connection.status == ConnectionStatus.Disconnected) }
    var exportJson by remember { mutableStateOf<String?>(null) }
    var resetTrigger by remember { mutableStateOf(false) }
    val scope = remember { CoroutineScope(Dispatchers.Main) }

    val exportLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/json")
    ) { uri ->
        uri?.let {
            val text = exportJson ?: return@let
            try {
                context.contentResolver.openOutputStream(uri)?.use { os ->
                    os.write(text.toByteArray())
                }
                Toast.makeText(context, "已保存到文件", Toast.LENGTH_SHORT).show()
            } catch (e: Exception) {
                Toast.makeText(context, "保存失败: ${e.message}", Toast.LENGTH_SHORT).show()
            }
            exportJson = null
        }
    }

    val importLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri?.let {
            try {
                val text = context.contentResolver.openInputStream(it)?.bufferedReader()?.use { r -> r.readText() }
                    ?: return@let
                scope.launch {
                    val count = viewModel.importLlmConfig(text)
                    val msg = when {
                        count < 0 -> "导入失败：JSON 格式错误"
                        count == 0 -> "导入完成：无新增配置"
                        else -> "导入成功：共导入 $count 条配置"
                    }
                    Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
                }
            } catch (e: Exception) {
                Toast.makeText(context, "导入失败: ${e.message}", Toast.LENGTH_SHORT).show()
            }
        }
    }

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
            viewModel = viewModel,
            onImportClick = { importLauncher.launch(arrayOf("application/json", "*/*")) },
            onExportFileSave = {
                val json = viewModel.exportLlmConfig()
                exportJson = json
                exportLauncher.launch("harness-llm-config-${System.currentTimeMillis()}.json")
            },
            exportJson = exportJson,
            resetTrigger = resetTrigger,
            onResetHandled = { resetTrigger = false },
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
