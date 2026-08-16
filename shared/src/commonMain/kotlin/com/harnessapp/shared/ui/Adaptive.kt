package com.harnessapp.shared.ui

/**
 * 跨三端统一的响应式布局断点。
 * 与 Material 3 / SwiftUI SizeClass / ArkUI 断点保持对齐：
 *   Compact   < 600dp   — 手机竖屏
 *   Medium   600..840   — 手机横屏 / 小平板
 *   Expanded  > 840     — 大平板 / 桌面窗口
 */
enum class WindowWidthClass { Compact, Medium, Expanded }

enum class WindowHeightClass { Compact, Medium, Expanded }

data class WindowSize(val widthDp: Float, val heightDp: Float) {
    val widthClass: WindowWidthClass get() = when {
        widthDp < 600f -> WindowWidthClass.Compact
        widthDp <= 840f -> WindowWidthClass.Medium
        else -> WindowWidthClass.Expanded
    }
    val heightClass: WindowHeightClass get() = when {
        heightDp < 480f -> WindowHeightClass.Compact
        heightDp <= 900f -> WindowHeightClass.Medium
        else -> WindowHeightClass.Expanded
    }

    /** 三栏布局中侧边栏推荐宽度（dp） */
    val sidebarWidth: Float get() = when (widthClass) {
        WindowWidthClass.Compact -> 0f
        WindowWidthClass.Medium -> 240f
        WindowWidthClass.Expanded -> 300f
    }

    /** 右侧详情面板推荐宽度 */
    val detailsWidth: Float get() = when (widthClass) {
        WindowWidthClass.Compact -> 0f
        WindowWidthClass.Medium -> 0f
        WindowWidthClass.Expanded -> 360f
    }

    /** 是否应该把详情面板做成右侧抽屉 */
    val isDetailsDrawer: Boolean get() = widthClass != WindowWidthClass.Expanded

    /** 是否应该把侧边栏做成抽屉 */
    val isSidebarDrawer: Boolean get() = widthClass == WindowWidthClass.Compact
}

enum class Panel { Sidebar, Details }
