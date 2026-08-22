package com.harnest.app.device

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * GUI automation — Android AccessibilityService (the capability HarmonyOS 6.1
 * closed to third parties). Same command contract as the HarmonyOS GuiExtAbility:
 * tree / find / click / swipe / back / home / input.
 *
 * The user must enable it: Settings → Accessibility → Installed services → Harness GUI.
 */
class GuiService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: GuiService? = null
            private set

        @Volatile
        var onAvailabilityChanged: ((Boolean) -> Unit)? = null

        fun isEnabled(context: Context): Boolean = instance != null || isSystemEnabled(context)

        fun isSystemEnabled(context: Context): Boolean {
            val expected = ComponentName(context, GuiService::class.java)
            val setting = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            return setting.split(':').any { ComponentName.unflattenFromString(it) == expected }
        }

        private fun notifyAvailability() {
            val cb = onAvailabilityChanged ?: return
            try {
                cb.invoke(instance != null)
            } catch (_: Throwable) {
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        notifyAvailability()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        notifyAvailability()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        notifyAvailability()
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    // ── node accessors ───────────────────────────────────────

    private fun rootNode(): AccessibilityNodeInfo? = rootInActiveWindow

    private fun serializeNode(node: AccessibilityNodeInfo, depth: Int, budget: IntArray): JSONObject {
        val rect = Rect()
        node.getBoundsInScreen(rect)
        val o = JSONObject()
            .put("text", node.text?.toString() ?: "")
            .put("description", node.contentDescription?.toString() ?: "")
            .put("type", typeName(node))
            .put("clickable", node.isClickable)
            .put("editable", node.isEditable)
            .put("scrollable", node.isScrollable)
            .put("checkable", node.isCheckable)
            .put("checked", node.isChecked)
            .put("focused", node.isFocused)
            .put("selected", node.isSelected)
            .put("viewId", node.viewIdResourceName ?: "")
            .put("packageName", node.packageName?.toString() ?: "")
            .put("rect", JSONObject()
                .put("left", rect.left).put("top", rect.top)
                .put("right", rect.right).put("bottom", rect.bottom)
                .put("centerX", rect.centerX()).put("centerY", rect.centerY()))
        if (depth < 8) {
            val children = JSONArray()
            for (i in 0 until node.childCount) {
                if (budget[0] <= 0) break
                node.getChild(i)?.let { child ->
                    budget[0]--
                    children.put(serializeNode(child, depth + 1, budget))
                }
            }
            if (children.length() > 0) o.put("children", children)
        }
        return o
    }

    private fun typeName(node: AccessibilityNodeInfo): String = when (node.className?.toString()) {
        android.widget.Button::class.java.name, android.widget.ImageButton::class.java.name -> "Button"
        android.widget.TextView::class.java.name -> "Text"
        android.widget.EditText::class.java.name -> "TextField"
        android.widget.CheckBox::class.java.name -> "CheckBox"
        android.widget.Switch::class.java.name -> "Switch"
        android.widget.ImageView::class.java.name -> "Image"
        android.view.ViewGroup::class.java.name -> "Container"
        android.webkit.WebView::class.java.name -> "WebView"
        "androidx.recyclerview.widget.RecyclerView" -> "List"
        android.widget.ScrollView::class.java.name -> "Scroll"
        else -> node.className?.toString()?.substringAfterLast('.') ?: "Node"
    }

    private fun findFirst(node: AccessibilityNodeInfo?, text: String, depth: Int, budget: IntArray): AccessibilityNodeInfo? {
        if (node == null || budget[0] <= 0 || depth > 12) return null
        budget[0]--
        val label = node.text?.toString() ?: node.contentDescription?.toString() ?: ""
        if (label.isNotEmpty() && label.contains(text)) return node
        for (i in 0 until node.childCount) {
            val hit = findFirst(node.getChild(i), text, depth + 1, budget)
            if (hit != null) return hit
        }
        return null
    }

    private fun findEditable(node: AccessibilityNodeInfo?, depth: Int, budget: IntArray): AccessibilityNodeInfo? {
        if (node == null || budget[0] <= 0 || depth > 12) return null
        budget[0]--
        if (node.isEditable) return node
        for (i in 0 until node.childCount) {
            val hit = findEditable(node.getChild(i), depth + 1, budget)
            if (hit != null) return hit
        }
        return null
    }

    // ── commands (called from GuiBridge on a worker thread) ──

    fun cmdTree(): JSONObject {
        val root = rootNode() ?: return JSONObject().put("ok", false)
            .put("error", "no active window — the screen may be off/locked or the service was just enabled")
        val budget = intArrayOf(200)
        val tree = serializeNode(root, 0, budget)
        return JSONObject().put("ok", true).put("tree", tree).put("truncated", budget[0] <= 0)
    }

    fun cmdFind(text: String): JSONObject {
        if (text.isEmpty()) return JSONObject().put("ok", false).put("error", "text required")
        val root = rootNode() ?: return JSONObject().put("ok", false).put("error", "no active window")
        val hit = findFirst(root, text, 0, intArrayOf(1500))
            ?: return JSONObject().put("ok", true).put("found", false)
        val rect = Rect()
        hit.getBoundsInScreen(rect)
        return JSONObject().put("ok", true).put("found", true)
            .put("centerX", rect.centerX()).put("centerY", rect.centerY())
            .put("rect", JSONObject().put("left", rect.left).put("top", rect.top)
                .put("right", rect.right).put("bottom", rect.bottom))
            .put("clickable", hit.isClickable).put("text", hit.text?.toString() ?: "")
    }

    fun cmdClick(text: String, x: Int, y: Int): JSONObject {
        var cx = x
        var cy = y
        if (text.isNotEmpty()) {
            val root = rootNode() ?: return JSONObject().put("ok", false).put("error", "no active window")
            val hit = findFirst(root, text, 0, intArrayOf(1500))
                ?: return JSONObject().put("ok", false).put("error", "no element matching '$text'")
            if (hit.isClickable) {
                if (hit.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                    return JSONObject().put("ok", true).put("action", "performAction(ACTION_CLICK)")
                }
            }
            val rect = Rect()
            hit.getBoundsInScreen(rect)
            cx = rect.centerX()
            cy = rect.centerY()
        }
        if (cx <= 0 || cy <= 0) return JSONObject().put("ok", false).put("error", "x/y or text required")
        return gestureClick(cx, cy)
    }

    fun cmdSwipe(startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Long): JSONObject {
        val path = Path().apply { moveTo(startX.toFloat(), startY.toFloat()) }
        val steps = 10
        for (i in 1..steps) {
            val t = i.toFloat() / steps
            path.lineTo(startX + (endX - startX) * t, startY + (endY - startY) * t)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs.coerceIn(100, 8000))
        return dispatchAndWait(GestureDescription.Builder().addStroke(stroke).build())
    }

    fun cmdBack(): JSONObject {
        val ok = performGlobalAction(GLOBAL_ACTION_BACK)
        return JSONObject().put("ok", ok).put("action", "back")
    }

    fun cmdHome(): JSONObject {
        val ok = performGlobalAction(GLOBAL_ACTION_HOME)
        return JSONObject().put("ok", ok).put("action", "home")
    }

    fun cmdInput(text: String, x: Int, y: Int): JSONObject {
        if (text.isEmpty()) return JSONObject().put("ok", false).put("error", "text required")
        val root = rootNode() ?: return JSONObject().put("ok", false).put("error", "no active window")
        var target: AccessibilityNodeInfo? = if (x > 0 && y > 0) null else findEditable(root, 0, intArrayOf(1500))
        if (target == null && x > 0 && y > 0) {
            // tap at (x,y) then retry find — taps usually focus an editable
            gestureClick(x, y)
            Thread.sleep(250)
            val root2 = rootNode()
            target = findEditable(root2, 0, intArrayOf(1500))
        }
        target = target ?: findEditable(rootNode(), 0, intArrayOf(1500))
        target ?: return JSONObject().put("ok", false).put("error", "no editable field found on screen")
        val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text) }
        val ok = target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        return if (ok) JSONObject().put("ok", true).put("input", text)
        else JSONObject().put("ok", false).put("error", "setText failed")
    }

    // ── gesture helpers ──────────────────────────────────────

    private fun gestureClick(x: Int, y: Int): JSONObject {
        val path = Path().apply {
            moveTo(x.toFloat(), y.toFloat())
            lineTo(x.toFloat() + 1f, y.toFloat())
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, 60)
        return dispatchAndWait(GestureDescription.Builder().addStroke(stroke).build())
    }

    private fun dispatchAndWait(gesture: GestureDescription): JSONObject {
        val latch = java.util.concurrent.CountDownLatch(1)
        var ok = false
        val dispatched = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) { ok = true; latch.countDown() }
            override fun onCancelled(gestureDescription: GestureDescription?) { ok = false; latch.countDown() }
        }, null)
        if (!dispatched) return JSONObject().put("ok", false).put("error", "gesture dispatch failed")
        latch.await(3, java.util.concurrent.TimeUnit.SECONDS)
        return if (ok) JSONObject().put("ok", true)
        else JSONObject().put("ok", false).put("error", "gesture cancelled")
    }
}
