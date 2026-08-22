package com.harnest.app.app.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.harnest.app.app.ui.theme.HarnessTheme
import com.harnest.app.device.AndroidDeviceTools
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** 自测用例 */
data class DeviceCase(
    val name: String,
    val op: String,
    val argsJson: String,
    var state: String = "待测",
    var detail: String = "",
)

/**
 * 设备能力自测（Android）：逐项驱动 DeviceTools 的 12 类 op。
 * 与鸿蒙 DeviceTest.ets 对齐；Android 无内嵌引擎，全部直连 AndroidDeviceTools。
 */
class DeviceTestActivity : ComponentActivity() {

    private lateinit var tools: AndroidDeviceTools

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        tools = AndroidDeviceTools(this)
        setContent {
            HarnessTheme {
                DeviceTestScreen(tools)
            }
        }
    }

    override fun onDestroy() {
        tools.dispose()
        super.onDestroy()
    }
}

@Composable
fun DeviceTestScreen(tools: AndroidDeviceTools) {
    val scope = rememberCoroutineScope()
    var running by remember { mutableStateOf(false) }
    var lastId by remember { mutableStateOf("") }
    val cases = remember {
        mutableListOf(
            DeviceCase("状态 — capabilities + 权限概览", "status", "{}"),
            DeviceCase("权限查询 — 四域状态", "permissions", """{"action":"query"}"""),
            DeviceCase("权限申请 — 弹系统授权框", "permissions", """{"action":"request"}"""),
            DeviceCase("剪贴板写入", "clipboard", """{"op":"write","text":"harnest-device-test"}"""),
            DeviceCase("剪贴板读取 — 校验回读", "clipboard", """{"op":"read"}"""),
            DeviceCase("沙箱写文件", "files", """{"op":"sandboxWrite","path":"device-test/hello.txt","text":"hello from device tools"}"""),
            DeviceCase("沙箱读文件 — 校验回读", "files", """{"op":"sandboxRead","path":"device-test/hello.txt"}"""),
            DeviceCase("沙箱列目录", "files", """{"op":"sandboxList","path":"device-test"}"""),
            DeviceCase("文件选择器 — 系统文档选择", "files", """{"op":"pick"}"""),
            DeviceCase("相册选择器 — 系统照片选择", "photos", """{"op":"pick"}"""),
            DeviceCase("通讯录查询 — 前 20 条", "contacts", """{"op":"query","limit":20}"""),
            DeviceCase("通讯录新建 — 测试联系人", "contacts", """{"op":"create","name":"Harnest 测试","phones":["13800000000"]}"""),
            DeviceCase("通讯录删除 — 按新建结果", "contacts", """{"op":"delete","id":"__LAST__"}"""),
            DeviceCase("日历查询 — 前后 7 天", "calendar", """{"op":"query"}"""),
            DeviceCase("日历新建 — 1 小时后事件", "calendar", """{"op":"create","title":"Harnest 测试事件","notes":"device tools self test"}"""),
            DeviceCase("日历删除 — 按新建结果", "calendar", """{"op":"delete","id":"__LAST__"}"""),
            DeviceCase("拨号盘 — 预填号码", "call", """{"op":"dial","number":"13800138000"}"""),
            DeviceCase("短信 — 预填收件人与内容", "call", """{"op":"sms","number":"13800138000","body":"harnest test"}"""),
            DeviceCase("短信读取 — 最近 30 天收件箱", "sms", """{"op":"query","days":30,"limit":50}"""),
            DeviceCase("邮件 — 拉起撰写界面", "mail", """{"to":"test@example.com","subject":"Harnest 测试","body":"from device tools"}"""),
            DeviceCase("相机 — 系统拍照（预览图）", "camera", "{}"),
            DeviceCase("录音开始 — 5 秒上限", "recorder", """{"op":"start","maxSeconds":5}"""),
            DeviceCase("录音停止 — 返回文件", "recorder", """{"op":"stop"}"""),
            DeviceCase("应用列表 — 可启动应用", "app", """{"op":"list"}"""),
            DeviceCase("应用打开 — 系统设置", "app", """{"op":"open","uri":"settings"}"""),
        )
    }
    var caseList by remember { mutableStateOf(cases.toList()) }

    suspend fun runCase(c: DeviceCase) {
        c.state = "运行中"
        caseList = cases.toList()
        val started = System.currentTimeMillis()
        try {
            var argsJson = c.argsJson
            if (argsJson.contains("__LAST__")) {
                if (lastId.isEmpty()) throw Exception("no previous create result to delete")
                argsJson = argsJson.replace("__LAST__", lastId)
            }
            val args: JsonObject =
                if (argsJson == "{}") buildJsonObject {}
                else kotlinx.serialization.json.Json.parseToJsonElement(argsJson).jsonObject
            val result = tools.call(c.op, args)
            val idVal = result["id"]
            if (idVal is kotlinx.serialization.json.JsonPrimitive && idVal.content.isNotEmpty()) {
                lastId = idVal.content
            }
            c.state = "通过"
            var detail = result.toString()
            if (detail.length > 240) detail = detail.take(240) + "…"
            c.detail = "$detail (${System.currentTimeMillis() - started}ms)"
        } catch (e: Exception) {
            c.state = "失败"
            c.detail = e.message ?: e.toString()
        }
        caseList = cases.toList()
    }

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        // 顶栏
        Row(
            Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val ctx = androidx.compose.ui.platform.LocalContext.current
            Text(
                "‹",
                fontSize = 22.sp,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier
                    .clickable { (ctx as? ComponentActivity)?.finish() }
                    .padding(horizontal = 10.dp),
            )
            Text(
                "设备能力自测",
                fontSize = 17.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onBackground,
            )
            Spacer(Modifier.weight(1f))
            val pass = cases.count { it.state == "通过" }
            val fail = cases.count { it.state == "失败" }
            Text(
                "通过 $pass / 失败 $fail",
                fontSize = 12.sp,
                color = if (fail > 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.outline,
            )
        }

        // 说明 + 全部运行
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "直连 AndroidDeviceTools（通讯录/日历/剪贴板/文件/相册/邮件/拨号/相机/录音/应用）",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.outline,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(10.dp))
            Button(
                onClick = {
                    if (running) return@Button
                    scope.launch {
                        running = true
                        for (c in cases) {
                            if (c.name.contains("录音开始")) {
                                runCase(c)
                                delay(3000) // 录 3 秒再停
                            } else {
                                runCase(c)
                            }
                        }
                        running = false
                    }
                },
                enabled = !running,
            ) {
                if (running) {
                    CircularProgressIndicator(Modifier.width(16.dp).height(16.dp), strokeWidth = 1.5.dp)
                    Spacer(Modifier.width(6.dp))
                }
                Text(if (running) "运行中…" else "全部运行")
            }
        }

        // 用例列表
        LazyColumn(
            Modifier.fillMaxSize().weight(1f),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = 16.dp, end = 16.dp, bottom = 24.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            itemsIndexed(caseList) { idx, c ->
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(enabled = !running) { scope.launch { running = true; runCase(c); running = false } },
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                    ),
                    shape = RoundedCornerShape(10.dp),
                ) {
                    Column(Modifier.padding(12.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "${idx + 1}. ${c.name}",
                                fontSize = 14.sp,
                                color = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                c.state,
                                fontSize = 12.sp,
                                color = when (c.state) {
                                    "通过" -> Color(0xFF4CAF50)
                                    "失败" -> MaterialTheme.colorScheme.error
                                    "运行中" -> MaterialTheme.colorScheme.primary
                                    else -> MaterialTheme.colorScheme.outline
                                },
                            )
                            if (c.state == "待测" && !running) {
                                Spacer(Modifier.width(8.dp))
                                Text("▶", fontSize = 14.sp, color = MaterialTheme.colorScheme.primary)
                            }
                        }
                        if (c.detail.isNotEmpty()) {
                            Spacer(Modifier.height(4.dp))
                            Text(
                                c.detail,
                                fontSize = 11.sp,
                                fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.outline,
                                maxLines = 4,
                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}
