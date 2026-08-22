import SwiftUI

/// Details page — mirrors androidApp DetailsView.kt.
struct DetailsView: View {

    @EnvironmentObject var app: AppStore

    private var session: SessionRecord? { app.currentSession }

    private var toolCount: Int {
        session?.messages.filter { $0.toolName != nil }.count ?? 0
    }

    private var latestTodos: String? {
        session?.messages.last(where: { $0.todosJson != nil })?.todosJson
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let s = session {
                        sessionCard(s)
                        if let todos = latestTodos {
                            TodoCard(json: todos)
                        }
                        if !s.messages.isEmpty {
                            traceSection(s)
                        } else {
                            hintCard("当前会话暂无消息，先在对话页发起一次任务")
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .background(Theme.background)
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // ── session card ─────────────────────────────────────────

    private func sessionCard(_ s: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                statChip("模型", "\(s.provider) · \(s.model)")
                statChip("消息", "\(s.messages.count)")
                statChip("工具调用", "\(toolCount)")
            }
            Text("更新于 \(Self.timeText(s.updatedAt))")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textHint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statChip(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textHint)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // ── todos ────────────────────────────────────────────────

    private struct TodoCard: View {
        let json: String

        private var items: [(content: String, done: Bool)] {
            guard let data = json.data(using: .utf8),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                return []
            }
            return arr.map {
                let content = $0["content"] as? String ?? $0["text"] as? String ?? ""
                let status = $0["status"] as? String ?? "pending"
                return (content, status == "done" || status == "completed")
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("最新任务清单")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textHint)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(item.done ? Theme.accent : Theme.textHint)
                            Text(item.content)
                                .font(.system(size: 12))
                                .foregroundStyle(item.done ? Theme.textHint : Theme.textSecondary)
                                .strikethrough(item.done, color: Theme.textHint)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // ── trace ────────────────────────────────────────────────

    private func traceSection(_ s: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("消息轨迹")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textHint)
            VStack(spacing: 6) {
                ForEach(Array(s.messages.enumerated()), id: \.offset) { idx, msg in
                    traceRow(idx, msg)
                }
            }
        }
    }

    private func traceRow(_ idx: Int, _ msg: StoredMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            roleBadge(msg)
            VStack(alignment: .leading, spacing: 3) {
                if let tool = msg.toolName {
                    Text("调用 \(tool) · \(msg.toolStatus ?? "")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(msg.content.isEmpty ? "（空）" : msg.content)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Text(Self.timeText(msg.createdAt))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textHint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func roleBadge(_ msg: StoredMessage) -> some View {
        let (text, color, dim): (String, Color, Color) = {
            switch msg.role {
            case "user": return ("我", Theme.primary, Theme.primaryDim)
            case "tool": return ("工具", Theme.warning, Theme.warningDim)
            default: return ("AI", Theme.accent, Theme.accentDim)
            }
        }()
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(dim)
            .clipShape(Capsule())
    }

    private func hintCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textHint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textHint)
            Text("暂无轨迹数据")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("先在对话页发起一次任务，这里会展示执行轨迹")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textHint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private static func timeText(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
}
