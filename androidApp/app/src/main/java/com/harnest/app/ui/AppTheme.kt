package com.harnest.app.ui

import android.content.Context
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Harness theme tokens — mirrors harmonyApp entry/ets/theme/Theme.ets.
 * Brand dark theme (#1a1a2e base / #00d4aa primary / #7c5cff accent).
 */
data class HarnessColors(
    val background: Color,
    val surface: Color,
    val surfaceElevated: Color,
    val divider: Color,
    val primary: Color,
    val onPrimary: Color,
    val accent: Color,
    val success: Color,
    val warning: Color,
    val error: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textHint: Color,
    val userBubble: Color,
    val assistantBubble: Color,
)

val DarkHarnessColors = HarnessColors(
    background = Color(0xFF1a1a2e),
    surface = Color(0xFF252540),
    surfaceElevated = Color(0xFF2d2d50),
    divider = Color(0xFF3a3a5c),
    primary = Color(0xFF00d4aa),
    onPrimary = Color(0xFF1a1a2e),
    accent = Color(0xFF7c5cff),
    success = Color(0xFF4CAF50),
    warning = Color(0xFFFFA726),
    error = Color(0xFFEF5350),
    textPrimary = Color(0xFFf2f2f7),
    textSecondary = Color(0xFFa0a0b8),
    textHint = Color(0xFF6c6c88),
    userBubble = Color(0xFF1f3a4a),
    assistantBubble = Color(0xFF2d2d50),
)

val LightHarnessColors = HarnessColors(
    background = Color(0xFFf7f7fb),
    surface = Color(0xFFffffff),
    surfaceElevated = Color(0xFFffffff),
    divider = Color(0xFFe4e4ee),
    primary = Color(0xFF00b894),
    onPrimary = Color(0xFFffffff),
    accent = Color(0xFF6c4ce0),
    success = Color(0xFF2E7D32),
    warning = Color(0xFFE65100),
    error = Color(0xFFC62828),
    textPrimary = Color(0xFF1a1a2e),
    textSecondary = Color(0xFF5a5a7a),
    textHint = Color(0xFF9c9cb4),
    userBubble = Color(0xFFe3f7f0),
    assistantBubble = Color(0xFFffffff),
)

val LocalHarnessColors = staticCompositionLocalOf { DarkHarnessColors }

/** 外观模式 — 与 iOS（AppearanceMode）/ HarmonyOS（setColorMode）对齐。 */
enum class AppearanceMode(val label: String) {
    SYSTEM("跟随系统"),
    LIGHT("浅色"),
    DARK("深色");

    companion object {
        fun of(raw: String?): AppearanceMode =
            entries.firstOrNull { it.name == raw } ?: SYSTEM
    }
}

/** SharedPreferences 持久化（key 与 iOS AppStorage 一致：harnest.appearance）。 */
object ThemePrefs {
    private const val FILE = "harnest_prefs"
    private const val KEY = "harnest.appearance"

    fun load(context: Context): AppearanceMode = try {
        val raw = context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getString(KEY, null)
        AppearanceMode.of(raw)
    } catch (_: Throwable) {
        AppearanceMode.SYSTEM
    }

    fun save(context: Context, mode: AppearanceMode) {
        try {
            context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .edit().putString(KEY, mode.name).apply()
        } catch (_: Throwable) {
        }
    }
}

/** Resolve effective darkness: explicit modes win, SYSTEM follows the OS. */
@Composable
fun resolveDark(mode: AppearanceMode): Boolean = when (mode) {
    AppearanceMode.SYSTEM -> isSystemInDarkTheme()
    AppearanceMode.LIGHT -> false
    AppearanceMode.DARK -> true
}

/** App theme — dual palette (brand dark / light), selected by appearance mode.
 *  Also maps tokens onto MaterialTheme.colorScheme so M3 components
 *  (SegmentedButton, etc.) render brand-consistently. */
@Composable
fun HarnessTheme(appearance: AppearanceMode = AppearanceMode.SYSTEM, content: @Composable () -> Unit) {
    val dark = resolveDark(appearance)
    val colors = if (dark) DarkHarnessColors else LightHarnessColors
    val scheme = (if (dark) darkColorScheme() else lightColorScheme()).copy(
        primary = colors.primary,
        onPrimary = colors.onPrimary,
        secondaryContainer = colors.primary,
        onSecondaryContainer = colors.onPrimary,
        surface = colors.surface,
        onSurface = colors.textPrimary,
        background = colors.background,
        onBackground = colors.textPrimary,
        outline = colors.divider,
    )
    CompositionLocalProvider(LocalHarnessColors provides colors) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

@Composable
fun harnessColors(): HarnessColors = LocalHarnessColors.current

/** Shared corner radii (mirrors Theme.ets radius scale). */
object HarnessShapes {
    val card = RoundedCornerShape(10.dp)
    val bubble = RoundedCornerShape(12.dp)
    val pill = RoundedCornerShape(50)
    val sheetTop = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp)
    val dialog = RoundedCornerShape(14.dp)
    val input = RoundedCornerShape(10.dp)
    val small = RoundedCornerShape(8.dp)
}
