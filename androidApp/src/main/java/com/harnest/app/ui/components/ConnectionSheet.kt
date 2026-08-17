package com.harnest.app.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SheetState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.harnest.app.shared.ui.ConnectionStatus
import com.harnest.app.shared.ui.KernelConnectionState
import com.harnest.app.shared.ui.UiState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionSheet(
    state: UiState,
    onConnect: (host: String, port: Int, tls: Boolean, provider: String, model: String) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val conn = state.connection

    var host by remember(conn.host) { mutableStateOf(conn.host) }
    var portText by remember(conn.port) { mutableStateOf(conn.port.toString()) }
    var useTls by remember(conn.useTls) { mutableStateOf(conn.useTls) }
    var provider by remember(conn.provider) { mutableStateOf(conn.provider) }
    var model by remember(conn.model) { mutableStateOf(conn.model) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = androidx.compose.material3.MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = "连接 DSH 内核",
                style = androidx.compose.material3.MaterialTheme.typography.titleLarge,
            )
            Text(
                text = "运行 `pnpm dsh headless --port 3080` 启动内核",
                style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
            )

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
                Checkbox(checked = useTls, onCheckedChange = { useTls = it })
                Text("使用 TLS (wss://)")
            }

            OutlinedTextField(
                value = provider,
                onValueChange = { provider = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Provider") },
                singleLine = true,
            )

            OutlinedTextField(
                value = model,
                onValueChange = { model = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Model") },
                singleLine = true,
            )

            val connecting = conn.status == ConnectionStatus.Connecting

            Button(
                onClick = {
                    val port = portText.toIntOrNull() ?: 3080
                    onConnect(host, port, useTls, provider, model)
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = !connecting && host.isNotBlank() && model.isNotBlank(),
            ) {
                if (connecting) {
                    CircularProgressIndicator(
                        Modifier.height(18.dp),
                        strokeWidth = 1.5.dp,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text("连接中...")
                } else {
                    Text(if (conn.status == ConnectionStatus.Connected) "已连接" else "连接")
                }
            }

            if (conn.status == ConnectionStatus.Error) {
                Text(
                    text = "连接失败，请检查内核是否启动",
                    color = androidx.compose.material3.MaterialTheme.colorScheme.error,
                    style = androidx.compose.material3.MaterialTheme.typography.bodySmall,
                )
            }

            TextButton(
                onClick = onDismiss,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("取消")
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}
