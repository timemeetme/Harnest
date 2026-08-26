package com.harnest.app.app.ui.components

import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Save
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.harnest.app.core.AiProvider
import com.harnest.app.core.ALL_PROVIDERS
import com.harnest.app.core.PROVIDER_META
import com.harnest.app.model.ProviderConfig
import com.harnest.app.shared.ui.AppViewModel
import com.harnest.app.shared.ui.ConnectionStatus
import com.harnest.app.shared.ui.UiState
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(
    viewModel: AppViewModel,
    state: UiState,
    modifier: Modifier = Modifier,
    onImportClick: () -> Unit = {},
    onExportFileSave: () -> Unit = {},
    exportJson: String? = null,
    resetTrigger: Boolean = false,
    onResetHandled: () -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current

    var llmConfig by remember { mutableStateOf(viewModel.loadLlmConfig()) }
    var showExportDialog by remember { mutableStateOf(false) }
    var showResetConfirm by remember { mutableStateOf(false) }

    LaunchedEffect(resetTrigger) {
        if (resetTrigger) {
            llmConfig = viewModel.loadLlmConfig()
            onResetHandled()
        }
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            SectionCard(title = "🧠 大模型配置") {
                val activeProvider = llmConfig.activeProvider
                val activeMeta = PROVIDER_META[activeProvider.value]
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "${activeMeta?.emoji ?: "🤖"} 当前激活：${activeMeta?.label ?: activeProvider.value}",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = true,
                        onCheckedChange = {},
                        enabled = false,
                    )
                }
            }
        }

        items(ALL_PROVIDERS, key = { it.value }) { provider ->
            val cfg = remember(llmConfig) { llmConfig.configs[provider.value] }
            ProviderCard(
                provider = provider,
                config = cfg,
                isActive = llmConfig.activeProvider == provider,
                onActivate = {
                    viewModel.setActiveProvider(provider)
                    llmConfig = viewModel.loadLlmConfig()
                },
                onSave = { apiKey, model, baseUrl ->
                    viewModel.updateLlmConfig(provider, apiKey, model, baseUrl)
                    llmConfig = viewModel.loadLlmConfig()
                },
            )
        }

        item {
            SectionCard(title = "🔌 内核连接") {
                KernelConnectionSection(
                    state = state,
                    viewModel = viewModel,
                    onConnect = { host, port, tls, provider, model ->
                        viewModel.connectKernel(host, port, tls, provider, model)
                    },
                )
            }
        }

        item {
            SectionCard(title = "📦 配置导入导出") {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        OutlinedButton(
                            onClick = {
                                val json = viewModel.exportLlmConfig()
                                showExportDialog = true
                                onExportFileSave
                            },
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("导出配置")
                        }
                        OutlinedButton(
                            onClick = onImportClick,
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("导入配置")
                        }
                    }
                    OutlinedButton(
                        onClick = { showResetConfirm = true },
                        colors = ButtonDefaults.outlinedButtonColors(
                            contentColor = MaterialTheme.colorScheme.error,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("重置所有配置")
                    }
                }
            }
        }

        item {
            SectionCard(title = "🎨 外观") {
                AppearanceSection(viewModel = viewModel, state = state)
            }
        }

        item {
            SectionCard(title = "🧪 开发者") {
                val ctx = androidx.compose.ui.platform.LocalContext.current
                OutlinedButton(
                    onClick = {
                        ctx.startActivity(
                            android.content.Intent(ctx, com.harnest.app.app.ui.DeviceTestActivity::class.java),
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("设备能力自测（通讯录/日历/剪贴板/文件/相册/邮件/拨号/相机/录音/应用）")
                }
            }
        }

        item {
            SectionCard(title = "ℹ️ 关于") {
                AboutSection(state = state)
            }
        }

        item { Spacer(Modifier.height(32.dp)) }
    }

    if (showExportDialog || exportJson != null) {
        val json = exportJson ?: viewModel.exportLlmConfig()
        AlertDialog(
            onDismissRequest = { showExportDialog = false },
            title = { Text("导出的配置 JSON") },
            text = {
                Text(
                    text = json,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        clipboard.setText(AnnotatedString(json))
                        Toast.makeText(context, "已复制到剪贴板", Toast.LENGTH_SHORT).show()
                    },
                ) {
                    Text("复制")
                }
            },
            dismissButton = {
                TextButton(onClick = onExportFileSave) {
                    Text("保存到文件")
                }
            },
        )
    }

    if (showResetConfirm) {
        AlertDialog(
            onDismissRequest = { showResetConfirm = false },
            title = { Text("确认重置") },
            text = { Text("这将清除所有已保存的 LLM 配置，确定继续吗？") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.resetAllConfigs()
                        llmConfig = viewModel.loadLlmConfig()
                        showResetConfirm = false
                        Toast.makeText(context, "已重置", Toast.LENGTH_SHORT).show()
                    },
                ) { Text("重置") }
            },
            dismissButton = {
                TextButton(onClick = { showResetConfirm = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun SectionCard(title: String, content: @Composable () -> Unit) {
    ElevatedCard {
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                fontWeight = FontWeight.SemiBold,
            )
            content()
        }
    }
}

@Composable
private fun ProviderCard(
    provider: AiProvider,
    config: ProviderConfig?,
    isActive: Boolean,
    onActivate: () -> Unit,
    onSave: (String, String, String) -> Unit,
) {
    val meta = PROVIDER_META[provider.value]!!
    var expanded by remember(isActive || (config?.apiKey?.isNotEmpty() == true)) {
        mutableStateOf(isActive || (config?.apiKey?.isNotEmpty() == true))
    }
    var apiKey by remember(config) { mutableStateOf(config?.apiKey ?: "") }
    var model by remember(config) { mutableStateOf(config?.model ?: meta.defaultModel) }
    var baseUrl by remember(config) { mutableStateOf(config?.baseUrl ?: meta.baseUrl) }
    var passwordVisible by remember { mutableStateOf(false) }
    var modelExpanded by remember { mutableStateOf(false) }

    ElevatedCard(
        colors = androidx.compose.material3.CardDefaults.elevatedCardColors(
            containerColor = if (isActive) MaterialTheme.colorScheme.primaryContainer
                else MaterialTheme.colorScheme.surfaceContainerLow,
        )
    ) {
        Column {
            Row(
                modifier = Modifier.fillMaxWidth().padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = meta.emoji,
                    style = MaterialTheme.typography.headlineSmall,
                )
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        meta.label,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Medium,
                    )
                    Text(
                        text = "${meta.protocol.name.lowercase()} · 默认 ${meta.defaultModel}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (isActive) {
                    AssistChip(
                        onClick = {},
                        label = { Text("激活") },
                        modifier = Modifier.height(32.dp),
                    )
                } else {
                    TextButton(
                        onClick = { onActivate() },
                        modifier = Modifier.height(32.dp),
                    ) { Text("激活") }
                }
                IconButton(onClick = { expanded = !expanded }) {
                    Icon(
                        imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        contentDescription = if (expanded) "收起" else "展开",
                    )
                }
            }

            if (expanded) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedTextField(
                        value = apiKey,
                        onValueChange = { apiKey = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("API Key") },
                        visualTransformation = if (passwordVisible) VisualTransformation.None else PasswordVisualTransformation(),
                        trailingIcon = {
                            IconButton(onClick = { passwordVisible = !passwordVisible }) {
                                Icon(
                                    imageVector = if (passwordVisible) Icons.Default.LockOpen else Icons.Default.Lock,
                                    contentDescription = if (passwordVisible) "隐藏" else "显示",
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        },
                        singleLine = true,
                    )

                    @OptIn(ExperimentalMaterial3Api::class)
                    ExposedDropdownMenuBox(
                        expanded = modelExpanded,
                        onExpandedChange = { modelExpanded = it },
                    ) {
                        OutlinedTextField(
                            value = model,
                            onValueChange = { model = it },
                            modifier = Modifier.fillMaxWidth().menuAnchor(),
                            label = { Text("模型") },
                            readOnly = false,
                            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = modelExpanded) },
                            singleLine = true,
                        )
                        ExposedDropdownMenu(
                            expanded = modelExpanded,
                            onDismissRequest = { modelExpanded = false },
                        ) {
                            meta.models.forEach { m ->
                                DropdownMenuItem(
                                    text = { Text(m) },
                                    onClick = {
                                        model = m
                                        modelExpanded = false
                                    },
                                )
                            }
                        }
                    }

                    OutlinedTextField(
                        value = baseUrl,
                        onValueChange = { baseUrl = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("Base URL") },
                        singleLine = true,
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Button(
                            onClick = { onSave(apiKey, model, baseUrl) },
                            modifier = Modifier.weight(1f),
                        ) { Text("保存") }
                        OutlinedButton(
                            onClick = {
                                apiKey = ""
                                model = meta.defaultModel
                                baseUrl = meta.baseUrl
                                passwordVisible = false
                            },
                            modifier = Modifier.weight(1f),
                        ) { Text("清空") }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KernelConnectionSection(
    state: UiState,
    viewModel: AppViewModel,
    onConnect: (String, Int, Boolean, String, String) -> Unit,
) {
    val conn = state.connection
    val llm = viewModel.loadLlmConfig()
    val active = llm.configs[llm.activeProvider.value]
    val defaultProvider = active?.provider?.value ?: "deepseek"
    val defaultModel = active?.model ?: "deepseek-v4-flash"

    var host by remember(conn.host) { mutableStateOf(conn.host) }
    var portText by remember(conn.port) { mutableStateOf(conn.port.toString()) }
    var useTls by remember(conn.useTls) { mutableStateOf(conn.useTls) }
    var testing by remember { mutableStateOf(false) }
    var testResult by remember { mutableStateOf<Pair<Boolean, String>?>(null) }

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        OutlinedTextField(
            value = host,
            onValueChange = { host = it },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Host") },
            singleLine = true,
        )
        OutlinedTextField(
            value = portText,
            onValueChange = { portText = it.filter { c -> c.isDigit() } },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Port") },
            singleLine = true,
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("使用 TLS (wss://)", modifier = Modifier.weight(1f))
            Switch(checked = useTls, onCheckedChange = { useTls = it })
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = when (conn.status) {
                    ConnectionStatus.Disconnected -> "● 未连接"
                    ConnectionStatus.Connecting -> "◉ 连接中..."
                    ConnectionStatus.Connected -> "✓ 已连接"
                    ConnectionStatus.Error -> "✗ 连接错误"
                },
                color = when (conn.status) {
                    ConnectionStatus.Disconnected -> MaterialTheme.colorScheme.outline
                    ConnectionStatus.Connecting -> MaterialTheme.colorScheme.primary
                    ConnectionStatus.Connected -> Color(0xFF4CAF50)
                    ConnectionStatus.Error -> MaterialTheme.colorScheme.error
                },
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.weight(1f),
            )
            val serverVer = conn.serverVersion
            if (serverVer != null) {
                Text(
                    text = "内核 v$serverVer",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        val port = portText.toIntOrNull() ?: 3080
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Button(
                onClick = {
                    testing = true
                    testResult = null
                    val deferred = viewModel.testKernelConnection(host, port, useTls, defaultProvider, defaultModel)
                    kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main).launch {
                        val r = deferred.await()
                        testing = false
                        testResult = r.isSuccess to (r.getOrNull() ?: r.exceptionOrNull()?.message ?: "未知错误")
                    }
                },
                modifier = Modifier.weight(1f),
                enabled = !testing && host.isNotBlank(),
            ) {
                if (testing) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 1.5.dp)
                    Spacer(Modifier.width(6.dp))
                    Text("测试中...")
                } else {
                    Text("测试连接")
                }
            }
            OutlinedButton(
                onClick = { onConnect(host, port, useTls, defaultProvider, defaultModel) },
                modifier = Modifier.weight(1f),
                enabled = conn.status != ConnectionStatus.Connecting && host.isNotBlank(),
            ) {
                Text(if (conn.status == ConnectionStatus.Connected) "重连" else "连接")
            }
        }

        if (testResult != null) {
            val (ok, msg) = testResult!!
            Text(
                text = if (ok) "✅ $msg" else "❌ 连接失败: $msg",
                color = if (ok) Color(0xFF4CAF50) else MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AppearanceSection(viewModel: AppViewModel, state: UiState) {
    val settings = state.settings
    val scope = rememberCoroutineScope()
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("主题", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        val themeOptions = listOf("Light", "Dark", "System")
        val themeValues = listOf("light", "dark", "system")
        val selectedThemeIndex = themeValues.indexOfFirst { it == settings.theme }.coerceAtLeast(0)
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            themeOptions.forEachIndexed { i, label ->
                SegmentedButton(
                    selected = selectedThemeIndex == i,
                    onClick = { viewModel.updateSettingsTheme(themeValues[i]) },
                    shape = SegmentedButtonDefaults.itemShape(index = i, count = themeOptions.size),
                ) { Text(label) }
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("语言", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                val langOptions = listOf("zh-CN 简体中文", "en-US English", "auto 跟随系统")
                val langKeys = listOf("zh-CN", "en-US", "auto")
                var langExpanded by remember { mutableStateOf(false) }
                val currentIndex = langKeys.indexOfFirst { it == settings.language }.coerceAtLeast(2)
                ExposedDropdownMenuBox(
                    expanded = langExpanded,
                    onExpandedChange = { langExpanded = it },
                ) {
                    OutlinedTextField(
                        value = langOptions[currentIndex],
                        onValueChange = {},
                        readOnly = true,
                        modifier = Modifier.fillMaxWidth().menuAnchor(),
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = langExpanded) },
                        singleLine = true,
                    )
                    ExposedDropdownMenu(
                        expanded = langExpanded,
                        onDismissRequest = { langExpanded = false },
                    ) {
                        langOptions.forEachIndexed { i, opt ->
                            DropdownMenuItem(
                                text = { Text(opt) },
                                onClick = {
                                    viewModel.updateSettingsLanguage(langKeys[i])
                                    langExpanded = false
                                },
                            )
                        }
                    }
                }
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("自动审批", style = MaterialTheme.typography.bodyMedium)
                Text(
                    "工具调用自动批准，无需人工确认",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Switch(
                checked = settings.autoApprove,
                onCheckedChange = { viewModel.updateSettingsAutoApprove(it) },
            )
        }
    }
}

@Composable
private fun AboutSection(state: UiState) {
    val context = LocalContext.current
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = "版本 ${com.harnest.app.BuildConfig.VERSION_NAME} (${com.harnest.app.BuildConfig.VERSION_CODE})",
            style = MaterialTheme.typography.bodyMedium,
        )
        val serverVer = state.connection.serverVersion
        if (serverVer != null) {
            Text(
                text = "内核版本 $serverVer",
                style = MaterialTheme.typography.bodyMedium,
            )
        } else {
            Text(
                text = "内核版本 - 未连接",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        val clipboard = LocalClipboardManager.current
        Text(
            text = "GitHub: github.com/harness-app",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.clickable {
                clipboard.setText(AnnotatedString("https://github.com/harness-app"))
                Toast.makeText(context, "已复制链接", Toast.LENGTH_SHORT).show()
            },
        )
    }
}
