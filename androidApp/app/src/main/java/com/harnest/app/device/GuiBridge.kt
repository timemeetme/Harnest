package com.harnest.app.device

import android.content.Context
import org.json.JSONObject

/** Bridge into GuiService with graceful degradation when the service is off. */
object GuiBridge {

    fun execute(context: Context, args: JSONObject): JSONObject {
        val svc = GuiService.instance
        if (svc == null) {
            return if (GuiService.isSystemEnabled(context)) {
                JSONObject().put("ok", false)
                    .put("error", "Harness GUI service is enabled in system settings but not yet connected " +
                        "in this process (usually right after install or process restart). Retry in a moment.")
            } else {
                JSONObject().put("ok", false)
                    .put("error", "Harness GUI accessibility service is not enabled on this device. " +
                        "Ask the user to enable it: Settings → Accessibility → Installed services → Harness GUI, " +
                        "then retry. On Android this service IS available to third-party apps (unlike HarmonyOS 5+).")
            }
        }
        val cmd = args.optString("cmd", "tree")
        return when (cmd) {
            "tree" -> svc.cmdTree()
            "find" -> svc.cmdFind(args.optString("text", ""))
            "click" -> svc.cmdClick(args.optString("text", ""), args.optInt("x", -1), args.optInt("y", -1))
            "swipe" -> {
                val startX = args.optInt("startX", 0); val startY = args.optInt("startY", 0)
                val endX = args.optInt("endX", 0); val endY = args.optInt("endY", 0)
                if (startX == 0 && startY == 0 && endX == 0 && endY == 0) {
                    JSONObject().put("ok", false).put("error", "startX/startY/endX/endY required for swipe")
                } else {
                    svc.cmdSwipe(startX, startY, endX, endY, args.optLong("duration", 300))
                }
            }
            "back" -> svc.cmdBack()
            "home" -> svc.cmdHome()
            "input" -> svc.cmdInput(args.optString("text", ""), args.optInt("x", -1), args.optInt("y", -1))
            else -> JSONObject().put("ok", false).put("error", "unknown cmd: $cmd")
        }
    }
}
