import SwiftUI

/// App 主壳（EMM 式，对齐 harmonyApp Index.ets / androidApp MainActivity）：
/// 手机底部导航 / 宽屏横屏侧边导航，三 Tab：对话 / 详情 / 设置。
/// 三视图常驻组合（keep-alive ZStack），切换不销毁。
@main
struct HarnessAppApp: App {

    @StateObject private var app = AppStore()
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            RootShell()
                .environmentObject(app)
                .tint(Theme.accent)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

enum RootTab: Int, CaseIterable {
    case chat = 0
    case details = 1
    case settings = 2

    var label: String {
        switch self {
        case .chat: return "对话"
        case .details: return "详情"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "message.fill"
        case .details: return "list.bullet.rectangle.portrait"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootShell: View {

    @EnvironmentObject private var app: AppStore
    @State private var tab: RootTab = .chat

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 600 && geo.size.width > geo.size.height
            ZStack {
                Theme.background.ignoresSafeArea()
                if wide {
                    HStack(spacing: 0) {
                        SideRail(tab: tab) { tab = $0 }
                        KeepAliveStack(tab: tab)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        KeepAliveStack(tab: tab)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        BottomNav(tab: tab) { tab = $0 }
                    }
                }
            }
        }
        .overlay { toastOverlay }
        .fullScreenCover(isPresented: $app.showDeviceTest) {
            DeviceTestView()
        }
        .fullScreenCover(isPresented: $app.showLogs) {
            LogsOverlay()
        }
    }

    // ── toast ────────────────────────────────────────────────

    private var toastOverlay: some View {
        Group {
            if let msg = app.toastMsg {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.bottom, 96)
                    .task(id: app.toastRev) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        app.clearToast()
                    }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.15), value: app.toastMsg)
    }
}

/// All three panes stay in the hierarchy — only the active one is visible
/// and hit-testable, so per-tab @State survives switches (keep-alive parity).
private struct KeepAliveStack: View {

    let tab: RootTab

    var body: some View {
        ZStack {
            ChatView()
                .modifier(KeepAlive(active: tab == .chat))
            DetailsView()
                .modifier(KeepAlive(active: tab == .details))
            SettingsView()
                .modifier(KeepAlive(active: tab == .settings))
        }
    }
}

private struct KeepAlive: ViewModifier {

    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}

// ── navigation chrome ─────────────────────────────────────

private struct BottomNav: View {

    let tab: RootTab
    let onTab: (RootTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: 0.5)
            HStack(spacing: 0) {
                ForEach(RootTab.allCases, id: \.self) { item in
                    navItem(item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { onTab(item) }
                }
            }
            .frame(height: 58)
        }
        .background(Theme.surface)
    }

    private func navItem(_ item: RootTab) -> some View {
        let selected = tab == item
        return VStack(spacing: 3) {
            Image(systemName: item.icon)
                .font(.system(size: 20))
            Text(item.label)
                .font(.system(size: 11))
        }
        .foregroundStyle(selected ? Theme.primary : Theme.textHint)
    }
}

private struct SideRail: View {

    let tab: RootTab
    let onTab: (RootTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Image(systemName: "command")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.textPrimary)
                Text("Harness")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textHint)
            }
            .padding(.top, 20)
            .padding(.bottom, 20)
            ForEach(RootTab.allCases, id: \.self) { item in
                railItem(item)
            }
            Spacer(minLength: 0)
            Text("Harnest App")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textHint)
                .padding(.bottom, 16)
        }
        .frame(width: 96)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
    }

    private func railItem(_ item: RootTab) -> some View {
        let selected = tab == item
        return VStack(spacing: 4) {
            Image(systemName: item.icon)
                .font(.system(size: 22))
            Text(item.label)
                .font(.system(size: 11))
        }
        .foregroundStyle(selected ? Theme.primary : Theme.textHint)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(selected ? AnyShapeStyle(Theme.background) : AnyShapeStyle(.clear),
                    in: TopRoundedShape(radius: 14))
        .contentShape(Rectangle())
        .onTapGesture { onTab(item) }
    }
}

// ── logs overlay ─────────────────────────────────────────

/// Top-corner-only rounded rect (matches Android RoundedCornerShape(topStart=14, topEnd=14));
/// avoids UnevenRoundedRectangle's iOS 16.4 floor.
struct TopRoundedShape: Shape {

    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}


struct LogsOverlay: View {

    @EnvironmentObject private var app: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("运行日志")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(app.logLines.count) 行")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textHint)
                }
                Spacer(minLength: 12)
                Button("清空") { app.clearLogs() }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                Button("关闭") { dismiss() }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 10)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Theme.surface)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(app.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }
}
