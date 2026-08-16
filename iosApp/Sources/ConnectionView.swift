import SwiftUI
import shared

struct ConnectionView: View {
    @ObservedObject var store: AppStore

    @State private var host: String = "192.168.1.100"
    @State private var port: String = "3080"
    @State private var useTls: Bool = false
    @State private var provider: String = "deepseek"
    @State private var model: String = "deepseek-chat"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                heroSection
                    .padding(.top, 40)
                ScrollView {
                    Form {
                        Section("内核连接") {
                            TextField("Host", text: $host)
                                .textInputAutocapitalization(.never)
                            TextField("端口", text: $port)
                                .keyboardType(.numberPad)
                            Toggle("使用 TLS", isOn: $useTls)
                        }
                        Section("模型配置") {
                            TextField("Provider", text: $provider)
                                .textInputAutocapitalization(.never)
                            TextField("Model", text: $model)
                                .textInputAutocapitalization(.never)
                        }
                        Section {
                            Button {
                                store.connectKernel(
                                    host: host,
                                    port: Int(port) ?? 3080,
                                    useTls: useTls,
                                    provider: provider,
                                    model: model,
                                    cwd: ""
                                )
                            } label: {
                                HStack(spacing: 8) {
                                    if store.state.connection.status == .connecting {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "link")
                                    }
                                    Text("连接 DSH 内核")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.state.connection.status == .connecting)
                            .tint(Theme.accent)

                            statusRow
                        }
                        Section("使用提示") {
                            Text("iOS 不能内嵌 Node.js 运行时（Apple 禁止 JIT），必须远程连接。\n在 PC 上运行：\n  pnpm dsh headless --port 3080\n手机连接同局域网 PC 的 IP。")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.groupBg)
            .navigationTitle("DSH Mobile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var heroSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("连接 DSH 内核")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("配置好远程内核的连接信息，即可开始使用。")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var statusRow: some View {
        let c = store.state.connection
        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var statusColor: Color {
        switch store.state.connection.status {
        case .connecting: return Theme.connecting
        case .connected: return Theme.connected
        case .error: return Theme.error
        default: return Theme.textTertiary
        }
    }

    private var statusText: String {
        let c = store.state.connection
        switch c.status {
        case .connecting: return "连接中..."
        case .connected: return "已连接 · \(c.serverName ?? "")"
        case .error: return "连接失败"
        default: return "等待连接"
        }
    }
}
