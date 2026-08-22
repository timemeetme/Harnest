package com.harnest.app.ui

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/** k6 网络图片加载 — okhttp 拉取 + LruCache 内存缓存（无 Coil/Glide 依赖）。 */
object MarkdownImageLoader {
    private val client = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(12, TimeUnit.SECONDS)
        .build()

    private val cache = LruCache<String, ImageBitmap>(24 * 1024 * 1024) // ~24MB

    fun cached(url: String): ImageBitmap? = cache.get(url)

    suspend fun load(url: String): ImageBitmap? = withContext(Dispatchers.IO) {
        cache.get(url)?.let { return@withContext it }
        try {
            val req = Request.Builder().url(url).build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext null
                val bytes = resp.body?.bytes() ?: return@withContext null
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@withContext null
                val ib = bmp.asImageBitmap()
                cache.put(url, ib)
                ib
            }
        } catch (_: Throwable) {
            null
        }
    }
}

/** Markdown `![alt](url)` 渲染 — 加载中占位 / 失败回退文本，成功出圆角图。 */
@Composable
fun MarkdownImage(url: String, alt: String, modifier: Modifier = Modifier) {
    val c = harnessColors()
    val state = remember(url) { mutableStateOf<ImageBitmap?>(MarkdownImageLoader.cached(url)) }
    val failed = remember(url) { mutableStateOf(false) }
    LaunchedEffect(url) {
        if (state.value == null && !failed.value) {
            val bmp = MarkdownImageLoader.load(url)
            if (bmp != null) state.value = bmp else failed.value = true
        }
    }
    val bmp = state.value
    when {
        bmp != null -> Column(modifier.fillMaxWidth()) {
            Image(
                bitmap = bmp,
                contentDescription = alt.ifBlank { "image" },
                contentScale = ContentScale.FillWidth,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 320.dp)
                    .background(c.surface, RoundedCornerShape(8.dp)),
            )
            if (alt.isNotBlank()) {
                Spacer(Modifier.height(2.dp))
                Text(alt, color = c.textHint, fontSize = 10.sp)
            }
        }
        failed.value -> Text("🖼 图片加载失败 · $url", color = c.textHint, fontSize = 11.sp, modifier = modifier)
        else -> Box(
            modifier
                .fillMaxWidth()
                .height(120.dp)
                .background(c.surface, RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text("🖼 加载中…", color = c.textHint, fontSize = 11.sp)
        }
    }
}
