package com.harnest.app.ui

import android.content.Context
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.harnest.app.common.Providers
import com.harnest.app.service.ConfigService

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun SettingsView(
    version: String,
    appearance: AppearanceMode,
    onAppearanceChange: (AppearanceMode) -> Unit,
    onConfigSaved: () -> Unit,
    onOpenDeviceTest: () -> Unit,
    onOpenLogs: () -> Unit,
    onOpenAccessibility: () -> Unit,
) {
    val c = harnessColors()
    val context = LocalContext.current
    var editingProvider by remember { mutableStateOf<String?>(null) }
    var editApiKey by remember { mutableStateOf("") }
    var editBaseUrl by remember { mutableStateOf("") }
    var editModels by remember { mutableStateOf("") }
    var editMaxTokens by remember { mutableStateOf("") }
    var showImport by remember { mutableStateOf(false) }
    var importText by remember { mutableStateOf("") }
    var importResult by remember { mutableStateOf("") }
    var configRev by remember { mutableStateOf(0) }

    fun toast(msg: String) = Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()

    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json"),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        try {
            val text = ConfigService.get(context).exportConfigJson()
            context.contentResolver.openOutputStream(uri)?.use { os ->
                os.write(text.toByteArray(Charsets.UTF_8))
            }
            toast("导出成功")
        } catch (e: Throwable) {
            toast("导出失败：${e.message ?: e.javaClass.simpleName}")
        }
    }

    fun runImport(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            importResult = "请粘贴 JSON，或点击上方「从文件导入」"
            return
        }
        val (imported, skipped) = ConfigService.get(context).importConfigJson(trimmed)
        if (imported > 0) {
            importResult = if (skipped.isEmpty()) {
                "已导入 $imported 项配置"
            } else {
                "已导入 $imported 项，跳过 ${skipped.size} 项（${skipped.joinToString("、")}）"
            }
            toast(importResult)
            configRev++
            onConfigSaved()
            showImport = false
        } else {
            importResult = "无新配置（格式不符或已存在相同配置）"
        }
    }

    val importFileLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        try {
            val text = context.contentResolver.openInputStream(uri)?.use {
                it.readBytes().toString(Charsets.UTF_8)
            } ?: ""
            if (text.isBlank()) {
                toast("文件内容为空")
            } else {
                importText = text
                runImport(text)
            }
        } catch (e: Throwable) {
            toast("读取失败：${e.message ?: e.javaClass.simpleName}")
        }
    }

    val p = editingProvider
    if (p != null) {
        EditorPage(
            provider = p,
            apiKey = editApiKey,
            baseUrl = editBaseUrl,
            models = editModels,
            maxTokens = editMaxTokens,
            onApiKey = { editApiKey = it },
            onBaseUrl = { editBaseUrl = it },
            onModels = { editModels = it },
            onMaxTokens = { editMaxTokens = it },
            onBack = { editingProvider = null },
            onSave = {
                val apiKey = editApiKey.trim()
                if (apiKey.isEmpty()) {
                    toast("API Key 不能为空")
                    return@EditorPage
                }
                val models = editModels.split('\n', ',').map { it.trim() }
                    .filter { it.isNotEmpty() }.distinct()
                if (models.isEmpty()) {
                    toast("至少填写一个模型")
                    return@EditorPage
                }
                var baseUrl = editBaseUrl.trim()
                if (baseUrl.isEmpty()) baseUrl = Providers.metaOf(p)?.baseUrl ?: ""
                val mt = editMaxTokens.trim().toIntOrNull() ?: 0
                ConfigService.get(context).setConfig(
                    p, apiKey, baseUrl, models, models.first(),
                    if (mt > 0) mt else null,
                )
                toast("已保存 ${Providers.metaOf(p)?.label ?: p}")
                configRev++
                onConfigSaved()
                editingProvider = null
            },
        )
        return
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(c.background)
    ) {
        Text(
            "设置",
            color = c.textPrimary,
            fontSize = 17.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier
                .fillMaxWidth()
                .background(c.surface)
                .padding(start = 16.dp, top = 14.dp, bottom = 14.dp),
        )
        Column(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 100.dp)
        ) {
            SectionHeader("外观", "深色 / 浅色 / 跟随系统，即时生效")
            SingleChoiceSegmentedButtonRow(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp)
            ) {
                AppearanceMode.entries.forEachIndexed { index, mode ->
                    SegmentedButton(
                        selected = appearance == mode,
                        onClick = { onAppearanceChange(mode) },
                        shape = SegmentedButtonDefaults.itemShape(
                            index = index,
                            count = AppearanceMode.entries.size,
                        ),
                        label = {
                            Text(mode.label, fontSize = 13.sp, maxLines = 1)
                        },
                    )
                }
            }

            SectionHeader("大模型 API", "支持多供应商，可导入 / 导出配置")
            val configs = remember(configRev) {
                Providers.ALL.associateWith { ConfigService.get(context).getConfig(it) }
            }
            Providers.ALL.forEach { prov ->
                val item = configs[prov]
                val label = Providers.metaOf(prov)?.label ?: prov
                val enabled = item?.optString("apiKey")?.isNotBlank() == true
                val subtitle = if (enabled) {
                    val dm = item!!.optString("defaultModel")
                    val bu = item.optString("baseUrl")
                    if (bu.isNotBlank()) "$dm · $bu" else dm
                } else {
                    "未配置"
                }
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            val cfg = ConfigService.get(context).getConfig(prov)
                            editApiKey = cfg.optString("apiKey", "")
                            editBaseUrl = cfg.optString("baseUrl", "")
                            editModels = (0 until cfg.optJSONArray("models")?.length().let { it ?: 0 })
                                .mapNotNull { i -> cfg.optJSONArray("models")?.optString(i) }
                                .joinToString("\n")
                            val mt = cfg.optInt("maxTokens", 0)
                            editMaxTokens = if (mt > 0) mt.toString() else ""
                            editingProvider = prov
                        }
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(label, color = c.textPrimary, fontSize = 15.sp)
                            if (enabled) {
                                Spacer(Modifier.width(6.dp))
                                Box(
                                    Modifier
                                        .size(6.dp)
                                        .background(c.success, RoundedCornerShape(3.dp))
                                )
                            }
                        }
                        Text(subtitle, color = c.textHint, fontSize = 11.sp, maxLines = 1)
                    }
                    Text("›", color = c.textHint, fontSize = 18.sp)
                }
            }

            SectionHeader("数据", "配置以 EMM 兼容 JSON 导入导出")
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                ActionButton("导入", Modifier.weight(1f)) { showImport = true; importResult = "" }
                ActionButton("导出", Modifier.weight(1f)) {
                    val stamp = java.text.SimpleDateFormat(
                        "yyyyMMdd_HHmm", java.util.Locale.US,
                    ).format(java.util.Date())
                    exportLauncher.launch("model_config_$stamp.json")
                }
            }

            SectionHeader("局域网服务", "手机与其他设备在同一网络时可用")
            Row(
                Modifier
                    .fillMaxWidth()
                    .alpha(0.6f)
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("局域网服务", color = c.textPrimary, fontSize = 15.sp)
                    Text("高级功能 · 后续版本支持", color = c.textHint, fontSize = 11.sp)
                }
                Text("›", color = c.textHint, fontSize = 18.sp)
            }

            SectionHeader("开发者", "调试与自检入口")
            SettingRow("设备能力自测", "25 项设备能力直接验证") { onOpenDeviceTest() }
            SettingRow("无障碍服务", "GUI 自动化需要开启无障碍服务") { onOpenAccessibility() }
            SettingRow("运行日志", "内核与桥接日志（最近 300 行）") { onOpenLogs() }

            SectionHeader("关于", "")
            AboutRow("应用", "Harnest App · $version")
            AboutRow("本地内核", "deepseek-harness")
            AboutRow("JS 引擎", "QuickJS（MIT）")
            AboutRow("开源许可", "遵循各依赖的开源协议")
        }
    }

    if (showImport) {
        ImportDialog(
            text = importText,
            result = importResult,
            onText = { importText = it },
            onPickFile = {
                try {
                    importFileLauncher.launch(arrayOf("application/json", "text/plain", "*/*"))
                } catch (e: Throwable) {
                    toast("文件选择器不可用")
                }
            },
            onCancel = { showImport = false },
            onImport = { runImport(importText) },
        )
    }
}

@Composable
private fun SectionHeader(title: String, subtitle: String) {
    val c = harnessColors()
    Column(
        Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 4.dp)
    ) {
        Text(title, color = c.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.Medium)
        if (subtitle.isNotEmpty()) {
            Text(subtitle, color = c.textHint, fontSize = 10.sp)
        }
    }
}

@Composable
private fun SettingRow(title: String, subtitle: String, onClick: () -> Unit) {
    val c = harnessColors()
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = c.textPrimary, fontSize = 15.sp)
            Text(subtitle, color = c.textHint, fontSize = 11.sp)
        }
        Text("›", color = c.textHint, fontSize = 18.sp)
    }
}

@Composable
private fun AboutRow(label: String, value: String) {
    val c = harnessColors()
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = c.textPrimary, fontSize = 14.sp)
        Spacer(Modifier.weight(1f))
        Text(value, color = c.textHint, fontSize = 12.sp, maxLines = 1)
    }
}

@Composable
private fun ActionButton(text: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val c = harnessColors()
    Box(
        modifier
            .height(38.dp)
            .background(c.surfaceElevated, RoundedCornerShape(8.dp))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = c.textPrimary, fontSize = 13.sp)
    }
}

@Composable
private fun EditorPage(
    provider: String,
    apiKey: String,
    baseUrl: String,
    models: String,
    maxTokens: String,
    onApiKey: (String) -> Unit,
    onBaseUrl: (String) -> Unit,
    onModels: (String) -> Unit,
    onMaxTokens: (String) -> Unit,
    onBack: () -> Unit,
    onSave: () -> Unit,
) {
    val c = harnessColors()
    Column(
        Modifier
            .fillMaxSize()
            .background(c.background)
            .imePadding()
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .background(c.surface)
                .padding(horizontal = 8.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "‹",
                color = c.textPrimary,
                fontSize = 22.sp,
                modifier = Modifier
                    .clickable(onClick = onBack)
                    .padding(horizontal = 10.dp, vertical = 2.dp),
            )
            Text(
                Providers.metaOf(provider)?.label ?: provider,
                color = c.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.Medium,
            )
        }
        Column(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .padding(bottom = 100.dp)
        ) {
            FieldLabel("API Key")
            FieldBox(
                value = apiKey,
                onValue = onApiKey,
                hint = "sk-…",
                minLines = 2,
                maxLines = 4,
            )
            Spacer(Modifier.height(12.dp))
            FieldLabel("Base URL")
            FieldBox(
                value = baseUrl,
                onValue = onBaseUrl,
                hint = "留空使用官方地址",
                minLines = 1,
                maxLines = 2,
            )
            Spacer(Modifier.height(12.dp))
            FieldLabel("模型列表（每行一个 ID）")
            FieldBox(
                value = models,
                onValue = onModels,
                hint = "例如\ndeepseek-v4-flash\ndeepseek-v4-pro",
                minLines = 4,
                maxLines = 8,
            )
            Spacer(Modifier.height(12.dp))
            FieldLabel("最大输出 Tokens（留空用默认）")
            FieldBox(
                value = maxTokens,
                onValue = onMaxTokens,
                hint = "如 8192",
                minLines = 1,
                maxLines = 1,
            )
            Spacer(Modifier.height(20.dp))
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(44.dp)
                    .background(c.primary, RoundedCornerShape(10.dp))
                    .clickable(onClick = onSave),
                contentAlignment = Alignment.Center,
            ) {
                Text("保存", color = c.onPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

@Composable
private fun FieldLabel(text: String) {
    val c = harnessColors()
    Text(
        text,
        color = c.textSecondary,
        fontSize = 12.sp,
        modifier = Modifier.padding(bottom = 6.dp),
    )
}

@Composable
private fun FieldBox(
    value: String,
    onValue: (String) -> Unit,
    hint: String,
    minLines: Int,
    maxLines: Int,
) {
    val c = harnessColors()
    BasicTextField(
        value = value,
        onValueChange = onValue,
        textStyle = TextStyle(color = c.textPrimary, fontSize = 13.sp),
        cursorBrush = SolidColor(c.primary),
        minLines = minLines,
        maxLines = maxLines,
        decorationBox = { inner ->
            Box(
                Modifier
                    .fillMaxWidth()
                    .background(c.surfaceElevated, RoundedCornerShape(8.dp))
                    .padding(horizontal = 12.dp, vertical = 10.dp)
            ) {
                if (value.isEmpty()) {
                    Text(hint, color = c.textHint, fontSize = 12.sp)
                }
                inner()
            }
        },
    )
}

@Composable
private fun ImportDialog(
    text: String,
    result: String,
    onText: (String) -> Unit,
    onPickFile: () -> Unit,
    onCancel: () -> Unit,
    onImport: () -> Unit,
) {
    val c = harnessColors()
    Box(
        Modifier
            .fillMaxSize()
            .background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.55f))
            .clickable(indication = null, interactionSource = remember {
                androidx.compose.foundation.interaction.MutableInteractionSource()
            }, onClick = onCancel),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .fillMaxWidth(0.86f)
                .background(c.surfaceElevated, RoundedCornerShape(14.dp))
                .padding(16.dp)
                .clickable(
                    indication = null,
                    interactionSource = remember {
                        androidx.compose.foundation.interaction.MutableInteractionSource()
                    },
                ) {},
        ) {
            Text("导入模型配置", color = c.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(12.dp))
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(56.dp)
                    .background(c.primary.copy(alpha = 0.12f), RoundedCornerShape(10.dp))
                    .border(1.dp, c.primary.copy(alpha = 0.4f), RoundedCornerShape(10.dp))
                    .clickable(onClick = onPickFile),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("从文件导入", color = c.primary, fontSize = 14.sp)
                    Text("model_config_*.json", color = c.primary.copy(alpha = 0.6f), fontSize = 10.sp)
                }
            }
            Spacer(Modifier.height(10.dp))
            Text("或粘贴 JSON：", color = c.textHint, fontSize = 11.sp)
            Spacer(Modifier.height(6.dp))
            BasicTextField(
                value = text,
                onValueChange = onText,
                textStyle = TextStyle(color = c.textPrimary, fontSize = 11.sp),
                cursorBrush = SolidColor(c.primary),
                minLines = 4,
                maxLines = 8,
                decorationBox = { inner ->
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = 88.dp)
                            .background(c.background, RoundedCornerShape(8.dp))
                            .padding(10.dp)
                    ) {
                        if (text.isEmpty()) {
                            Text(
                                "{ \"type\": \"emm_model_config\", … }",
                                color = c.textHint,
                                fontSize = 11.sp,
                            )
                        }
                        inner()
                    }
                },
            )
            if (result.isNotEmpty()) {
                Spacer(Modifier.height(8.dp))
                Text(result, color = c.textSecondary, fontSize = 11.sp)
            }
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    Modifier
                        .weight(1f)
                        .height(40.dp)
                        .background(c.surface, RoundedCornerShape(10.dp))
                        .clickable(onClick = onCancel),
                    contentAlignment = Alignment.Center,
                ) { Text("取消", color = c.textSecondary, fontSize = 14.sp) }
                Box(
                    Modifier
                        .weight(1f)
                        .height(40.dp)
                        .background(c.primary, RoundedCornerShape(10.dp))
                        .clickable(onClick = onImport),
                    contentAlignment = Alignment.Center,
                ) { Text("导入", color = c.onPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium) }
            }
        }
    }
}
