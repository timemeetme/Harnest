package com.harnest.app.ui

import android.widget.Toast
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
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.harnest.app.service.LocalEngine
import kotlinx.coroutines.launch
import org.json.JSONObject

class DeviceCase(val name: String, val op: String, val argsJson: String) {
    var state: String = "待测"
    var detail: String = ""
}

@Composable
fun DeviceTestView(onClose: () -> Unit) {
    val c = harnessColors()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val cases = remember { buildCases() }
    var rev by remember { mutableStateOf(0) }
    var fullChain by remember { mutableStateOf(false) }
    var lastId by remember { mutableStateOf<String?>(null) }
    var running by remember { mutableStateOf(false) }

    fun stateColor(state: String) = when (state) {
        "通过" -> c.success
        "失败" -> c.error
        "运行中" -> c.warning
        else -> c.textHint
    }

    suspend fun execute(case: DeviceCase) {
        case.state = "运行中"
        case.detail = ""
        rev++
        try {
            LocalEngine.get().ensureStarted(context)
            val args = if (case.argsJson.contains("__LAST__")) {
                val last = lastId
                if (last.isNullOrEmpty()) {
                    throw IllegalArgumentException("缺少前置新建结果（先执行对应的新建用例）")
                }
                case.argsJson.replace("__LAST__", last)
            } else {
                case.argsJson
            }
            val started = System.currentTimeMillis()
            val result = if (fullChain) {
                LocalEngine.get().deviceFullChainCall(case.op, args)
            } else {
                val (_, json) = LocalEngine.get().deviceDirectCall(case.op, args)
                JSONObject(json)
            }
            val took = System.currentTimeMillis() - started
            val idVal: Any? = result.opt("id")
            val idStr = when (idVal) {
                is String -> idVal
                is Int -> idVal.toString()
                is Long -> idVal.toString()
                else -> null
            }
            if (!idStr.isNullOrEmpty()) lastId = idStr
            val ok = result.optBoolean("ok", true) && result.optString("error").isBlank()
            case.state = if (ok) "通过" else "失败"
            case.detail = if (case.op == "recorder" && args.contains("\"start\"")) {
                "${took}ms · 录音中…（稍后执行「停止」返回文件）"
            } else {
                "${took}ms · " + result.toString().take(160)
            }
        } catch (e: Throwable) {
            case.state = "失败"
            case.detail = e.message ?: e.javaClass.simpleName
        }
        rev++
    }

    fun runOne(case: DeviceCase) {
        if (running) {
            Toast.makeText(context, "有用例正在运行", Toast.LENGTH_SHORT).show()
            return
        }
        running = true
        scope.launch {
            try {
                execute(case)
            } finally {
                running = false
            }
        }
    }

    fun runAll() {
        if (running) {
            Toast.makeText(context, "有用例正在运行", Toast.LENGTH_SHORT).show()
            return
        }
        running = true
        scope.launch {
            try {
                for (case in cases) execute(case)
            } finally {
                running = false
            }
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(c.background)
            .systemBarsPadding()
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
                    .clickable(onClick = onClose)
                    .padding(horizontal = 10.dp, vertical = 2.dp),
            )
            Column(Modifier.weight(1f)) {
                Text(
                    "设备能力自测",
                    color = c.textPrimary,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.Medium,
                )
                Text(
                    if (fullChain) "全链路：QuickJS 桥 → native → DeviceBridge" else "直连：DeviceBridge → native API",
                    color = c.textHint,
                    fontSize = 10.sp,
                )
            }
            Text(
                if (fullChain) "全链路" else "直连",
                color = c.primary,
                fontSize = 12.sp,
                modifier = Modifier
                    .background(c.primary.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
                    .clickable { fullChain = !fullChain }
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                if (running) "运行中…" else "运行全部",
                color = if (running) c.textHint else c.onPrimary,
                fontSize = 12.sp,
                modifier = Modifier
                    .background(if (running) c.surfaceElevated else c.primary, RoundedCornerShape(12.dp))
                    .clickable { runAll() }
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            )
        }
        Text(
            "逐项调用设备桥：查询类直接校验；交互类（授权/选择器/拨号/相机等）会拉起系统界面；新建 + 删除成对出现。",
            color = c.textHint,
            fontSize = 10.sp,
            modifier = Modifier
                .fillMaxWidth()
                .background(c.surface)
                .padding(horizontal = 16.dp, vertical = 2.dp)
                .padding(bottom = 10.dp),
        )
        LazyColumn(
            Modifier
                .weight(1f)
                .fillMaxWidth(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = 12.dp, end = 12.dp, top = 12.dp, bottom = 40.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            items(cases.size, key = { it }) { idx ->
                rev
                val case = cases[idx]
                Row(
                    Modifier
                        .fillMaxWidth()
                        .background(c.surfaceElevated, RoundedCornerShape(10.dp))
                        .clickable(enabled = !running) { runOne(case) }
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                case.name,
                                color = c.textPrimary,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Medium,
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                "${case.op}",
                                color = c.textHint,
                                fontSize = 10.sp,
                            )
                        }
                        if (case.detail.isNotEmpty()) {
                            Text(
                                case.detail,
                                color = c.textHint,
                                fontSize = 10.sp,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    Spacer(Modifier.width(8.dp))
                    Text(
                        case.state,
                        color = stateColor(case.state),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
        }
    }
}

private fun buildCases(): List<DeviceCase> = listOf(
    DeviceCase("状态总览", "status", "{}"),
    DeviceCase("权限查询 — 四域状态", "permissions", """{"action":"query"}"""),
    DeviceCase("权限申请 — 弹系统授权框", "permissions", """{"action":"request"}"""),
    DeviceCase("剪贴板写入", "clipboard", """{"op":"write","text":"harnest-device-test"}"""),
    DeviceCase("剪贴板读取 — 校验回读", "clipboard", """{"op":"read"}"""),
    DeviceCase("沙箱写文件", "files", """{"op":"sandboxWrite","path":"device-test/hello.txt","text":"hello from device bridge"}"""),
    DeviceCase("沙箱读文件 — 校验回读", "files", """{"op":"sandboxRead","path":"device-test/hello.txt"}"""),
    DeviceCase("沙箱列目录", "files", """{"op":"sandboxList","path":"device-test"}"""),
    DeviceCase("文件选择器 — 系统文档选择", "files", """{"op":"pick"}"""),
    DeviceCase("图片选择器 — 系统照片选择", "photos", """{"op":"pick"}"""),
    DeviceCase("通讯录查询 — 前 20 条", "contacts", """{"op":"query","limit":20}"""),
    DeviceCase("通讯录新建 — 测试联系人", "contacts", """{"op":"create","name":"Harnest 测试","phones":["13800000000"]}"""),
    DeviceCase("通讯录删除 — 按查询结果", "contacts", """{"op":"delete","id":"__LAST__"}"""),
    DeviceCase("日历查询 — 前后 7 天", "calendar", """{"op":"query"}"""),
    DeviceCase("日历新建 — 测试事件", "calendar", """{"op":"create","title":"Harnest 测试事件"}"""),
    DeviceCase("日历删除 — 按新建结果", "calendar", """{"op":"delete","id":"__LAST__"}"""),
    DeviceCase("拨号盘 — 预填号码", "call", """{"op":"dial","number":"13800138000"}"""),
    DeviceCase("短信 — 预填收件人与内容", "call", """{"op":"sms","number":"13800138000","body":"harnest test"}"""),
    DeviceCase("短信读取 — 受限降级说明", "sms", """{"op":"query","days":30}"""),
    DeviceCase("邮件 — 拉起撰写界面", "mail", """{"to":"test@example.com","subject":"Harnest 测试"}"""),
    DeviceCase("相机 — 自动拍照（无 UI）", "camera", """{"op":"capture"}"""),
    DeviceCase("录音开始 — 5 秒上限", "recorder", """{"op":"start","maxSeconds":5}"""),
    DeviceCase("录音停止 — 返回文件", "recorder", """{"op":"stop"}"""),
    DeviceCase("应用列表 — 可启动应用", "app", """{"op":"list"}"""),
    DeviceCase("打开系统设置", "app", """{"op":"open","package":"com.android.settings"}"""),
)
