import SwiftUI
import shared

struct ChatView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MessageList(messages: Array(store.state.messages))
            InputBarView(store: store)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(titleText)
    }

    private var titleText: String {
        store.state.sessions.first(where: { $0.id == store.state.activeSessionId })?.title
            ?? "新会话"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var statusText: String {
        let c = store.state.connection
        switch c.status {
        case .connected: return "已连接 · \(c.serverName ?? "内核")"
        case .connecting: return "连接中..."
        case .error: return "连接错误"
        case .disconnected: return "未连接"
        }
    }

    private var statusColor: Color {
        let c = store.state.connection
        switch c.status {
        case .connected: return Theme.connected
        case .connecting: return Theme.connecting
        case .error: return Theme.error
        case .disconnected: return Theme.textTertiary
        }
    }
}

private struct MessageList: View {
    let messages: [ChatMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        EmptyChatView()
                            .padding(.vertical, 40)
                    } else {
                        ForEach(messages, id: \.id) { msg in
                            MessageRow(message: msg)
                                .id(msg.id)
                        }
                        if !messages.isEmpty {
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(text: message.content)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                AssistantBubble(
                    text: message.content,
                    reasoning: message.reasoning,
                    isStreaming: message.isStreaming
                )
                if !message.toolCalls.isEmpty {
                    ToolCallList(toolCalls: Array(message.toolCalls))
                }
            }
        case .system:
            SystemBubble(text: message.content)
        case .tool:
            SystemBubble(text: message.content)
        }
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(12)
                .background(Theme.userBubble)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 420, alignment: .trailing)
        }
    }
}

private struct AssistantBubble: View {
    let text: String
    let reasoning: String?
    let isStreaming: Bool

    @State private var showReasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reasoning, !reasoning.isEmpty {
                Button {
                    withAnimation { showReasoning.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showReasoning ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("思考过程")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                if showReasoning {
                    Text(reasoning)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(8)
                        .background(Theme.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .padding(12)
                .background(Theme.assistantBubble)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 520, alignment: .leading)
                .overlay(alignment: .bottomTrailing) {
                    if isStreaming {
                        ProgressView()
                            .controlSize(.small)
                            .padding([.bottom, .trailing], 6)
                    }
                }
        }
    }
}

private struct SystemBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.bgSecondary)
                .clipShape(Capsule())
            Spacer()
        }
    }
}

private struct ToolCallList: View {
    let toolCalls: [ToolCallUi]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(toolCalls, id: \.id) { tc in
                ToolCallCard(toolCall: tc)
            }
        }
    }
}

private struct ToolCallCard: View {
    let toolCall: ToolCallUi
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolIcon)
                        .foregroundStyle(statusColor)
                    Text(toolCall.name)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().background(Theme.separator)
                VStack(alignment: .leading, spacing: 6) {
                    Text("参数")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.textSecondary)
                    Text(toolCall.args)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                    if let result = toolCall.result, !result.isEmpty {
                        Text("结果")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.textSecondary)
                        Text(result)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
            }
        }
        .background(Theme.toolCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var toolIcon: String {
        switch toolCall.name {
        case let n where n.contains("read"): "doc.text"
        case let n where n.contains("write") || n.contains("edit"): "square.and.pencil"
        case let n where n.contains("bash") || n.contains("run"): "terminal"
        default: "hammer"
        }
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .pending: return Theme.textTertiary
        case .running: return Theme.connecting
        case .success: return Theme.connected
        case .error: return Theme.error
        }
    }

    private var statusText: String {
        switch toolCall.status {
        case .pending: return "等待中"
        case .running: return "执行中"
        case .success: return "完成"
        case .error: return "错误"
        }
    }
}

private struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "message.badge")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("开始一段新对话")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
            Text("在下方输入你的问题，DSH 会帮你规划并执行。")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
