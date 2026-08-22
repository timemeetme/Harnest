import SwiftUI
import UIKit

/// Appearance preference — 深色 / 浅色 / 跟随系统.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static let storageKey = "harnest.appearance"
}

/// Design tokens — mirrors harmonyApp theme / androidApp AppTheme.
/// All colors are dynamic (Any + Dark trait pair), so switching
/// `.preferredColorScheme` re-renders every view automatically.
enum Theme {

    private static func dyn(_ light: UInt32, _ dark: UInt32, _ lightAlpha: Double = 1, _ darkAlpha: Double = 1) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            let a = trait.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: CGFloat(a)
            )
        })
    }

    static let background = dyn(0xF2F5FA, 0x0B0F1A)
    static let surface = dyn(0xFFFFFF, 0x131A2A)
    static let surfaceElevated = dyn(0xE9EEF6, 0x1C2740)
    static let primary = dyn(0x3E6E96, 0x7C9CBF)
    static let primaryDim = dyn(0x3E6E96, 0x7C9CBF, 0.10, 0.12)
    static let accent = dyn(0x00A883, 0x00D4AA)
    static let accentDim = dyn(0x00A883, 0x00D4AA, 0.10, 0.12)
    static let onPrimary = dyn(0xFFFFFF, 0x0F1622)

    static let textPrimary = dyn(0x1A2433, 0xE8ECF4)
    static let textSecondary = dyn(0x4A5A70, 0xA8B3C7)
    static let textHint = dyn(0x8291A6, 0x6B7A93)

    static let success = dyn(0x16A34A, 0x4ADE80)
    static let successDim = dyn(0x16A34A, 0x4ADE80, 0.10, 0.12)
    static let warning = dyn(0xB45309, 0xFACC15)
    static let warningDim = dyn(0xB45309, 0xFACC15, 0.10, 0.12)
    static let error = dyn(0xDC2626, 0xF87171)
    static let errorDim = dyn(0xDC2626, 0xF87171, 0.10, 0.12)

    static let bubbleUser = dyn(0x2A4A6B, 0x2A4A6B, 0.12, 0.40)
    static let bubbleAgent = dyn(0xE4EAF3, 0x1C2740)
    static let inputBar = dyn(0xFFFFFF, 0x0F1622)
    static let border = dyn(0xD5DEEB, 0x2A3A55)

    /// Status color shared by tool cards / device-test rows.
    static func statusColor(_ status: String) -> Color {
        switch status {
        case "success", "ok", "done", "通过": return success
        case "running", "运行中": return warning
        case "error", "fail", "失败": return error
        default: return textHint
        }
    }
}
