package com.harnest.app.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.harnest.app.shared.ui.ConnectionStatus
import com.harnest.app.shared.ui.KernelConnectionState

@Composable
fun StatusBar(
    connection: KernelConnectionState,
    onOpenConnection: () -> Unit,
    onDisconnect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(32.dp)
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        StatusDot(connection.status)
        Text(
            text = connection.status.display(connection),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.weight(1f))
        if (connection.status == ConnectionStatus.Connected) {
            Text(
                text = "${connection.provider} · ${connection.model}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = "断开",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.clickable { onDisconnect() },
            )
        } else {
            Text(
                text = "连接内核",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable { onOpenConnection() },
            )
        }
    }
}

@Composable
private fun StatusDot(status: ConnectionStatus) {
    when (status) {
        ConnectionStatus.Connecting -> CircularProgressIndicator(
            Modifier.size(12.dp),
            strokeWidth = 1.5.dp,
            color = MaterialTheme.colorScheme.primary,
        )
        else -> {
            val color = when (status) {
                ConnectionStatus.Connected -> MaterialTheme.colorScheme.primary
                ConnectionStatus.Error -> MaterialTheme.colorScheme.error
                ConnectionStatus.Disconnected -> MaterialTheme.colorScheme.outline
                else -> MaterialTheme.colorScheme.outline
            }
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(color),
            )
        }
    }
}

private fun ConnectionStatus.display(conn: KernelConnectionState): String = when (this) {
    ConnectionStatus.Disconnected -> "未连接"
    ConnectionStatus.Connecting -> "连接中 ${conn.host}:${conn.port}"
    ConnectionStatus.Connected -> "已连接 · ${conn.host}:${conn.port}"
    ConnectionStatus.Error -> "连接失败"
}
