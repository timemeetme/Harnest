import SwiftUI
import shared

struct DetailsPanelView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("标签", selection: Binding(
                get: { store.state.detailsTab },
                set: { store.selectDetailsTab($0) }
            )) {
                Text("工具").tag(DetailsTab.tools)
                Text("计划").tag(DetailsTab.plan)
                Text("Todo").tag(DetailsTab.todo)
                Text("子代理").tag(DetailsTab.subagents)
                Text("设置").tag(DetailsTab.settings)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            TabView(selection: Binding(
                get: { store.state.detailsTab },
                set: { store.selectDetailsTab($0) }
            )) {
                ToolCallTab(store: store)
                    .tag(DetailsTab.tools)
                PlanTab(store: store)
                    .tag(DetailsTab.plan)
                TodoTab(store: store)
                    .tag(DetailsTab.todo)
                SubagentTab(store: store)
                    .tag(DetailsTab.subagents)
                SettingsTab(store: store)
                    .tag(DetailsTab.settings)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Theme.bg)
    }
}

private struct ToolCallTab: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let toolCalls = store.state.messages
            .flatMap { Array($0.toolCalls) }
            .reversed()

        ScrollView {
            LazyVStack(spacing: 8) {
                if toolCalls.isEmpty {
                    EmptyStateView(icon: "hammer", title: "暂无工具调用", subtitle: "助手开始执行任务后这里会显示工具记录。")
                        .padding(.top, 60)
                } else {
                    ForEach(toolCalls, id: \.id) { tc in
                        ToolCallCard(toolCall: tc)
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct PlanTab: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let plan = store.state.plan

        ScrollView {
            LazyVStack(spacing: 8) {
                if plan.isEmpty {
                    EmptyStateView(icon: "list.bullet.clipboard", title: "暂无计划", subtitle: "助手生成计划后会显示在这里。")
                        .padding(.top, 60)
                } else {
                    ForEach(plan, id: \.id) { item in
                        PlanRow(item: item)
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct PlanRow: View {
    let item: PlanItemUi

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.caption)
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            if let desc = item.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Theme.planCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusIcon: String {
        switch item.status {
        case .pending: return "circle"
        case .inProgress: return "circle.dashed"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .pending: return Theme.textTertiary
        case .inProgress: return Theme.connecting
        case .done: return Theme.connected
        case .blocked: return Theme.error
        }
    }

    private var statusText: String {
        switch item.status {
        case .pending: return "待办"
        case .inProgress: return "进行中"
        case .done: return "完成"
        case .blocked: return "阻塞"
        }
    }
}

private struct TodoTab: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let todos = store.state.todos.sorted { $0.order < $1.order }
        let input = Binding(
            get: { "" },
            set: { store.addTodo($0) }
        )
        @State var newItem = ""

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("添加 Todo", text: $newItem)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let t = newItem.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { store.addTodo(t) }
                        newItem = ""
                    }
                Button {
                    let t = newItem.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { store.addTodo(t) }
                    newItem = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    if todos.isEmpty {
                        EmptyStateView(icon: "checklist", title: "暂无 Todo", subtitle: "在上方添加待办事项。")
                            .padding(.top, 40)
                    } else {
                        ForEach(todos, id: \.id) { item in
                            TodoRow(item: item) {
                                store.toggleTodo(item.id)
                            } onDelete: {
                                store.deleteTodo(item.id)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }
}

private struct TodoRow: View {
    let item: TodoItemUi
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Theme.connected : Theme.textTertiary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Text(item.content)
                .font(.body)
                .foregroundStyle(item.done ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(item.done)

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.textTertiary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Theme.todoCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

private struct SubagentTab: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let subagents = store.state.subagents

        ScrollView {
            LazyVStack(spacing: 8) {
                if subagents.isEmpty {
                    EmptyStateView(icon: "person.2", title: "暂无子代理", subtitle: "助手分派子代理后会在这里显示。")
                        .padding(.top, 60)
                } else {
                    ForEach(subagents, id: \.id) { sub in
                        SubagentRow(subagent: sub)
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct SubagentRow: View {
    let subagent: SubagentUi

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(subagent.name)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(statusColor)
        }
        .padding(10)
        .background(Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        switch subagent.status {
        case .running: return Theme.connecting
        case .done: return Theme.connected
        case .error: return Theme.error
        }
    }

    private var statusText: String {
        switch subagent.status {
        case .running: return "运行中"
        case .done: return "已完成"
        case .error: return "错误"
        }
    }
}

private struct SettingsTab: View {
    @ObservedObject var store: AppStore

    var body: some View {
        SettingsForm(store: store)
    }
}

struct SettingsForm: View {
    @ObservedObject var store: AppStore
    @State private var host: String
    @State private var port: String
    @State private var useTls: Bool
    @State private var provider: String
    @State private var model: String

    init(store: AppStore) {
        self.store = store
        let c = store.state.connection
        self._host = State(initialValue: c.host)
        self._port = State(initialValue: "\(c.port)")
        self._useTls = State(initialValue: c.useTls)
        self._provider = State(initialValue: c.provider)
        self._model = State(initialValue: c.model)
    }

    var body: some View {
        Form {
            Section("内核连接") {
                TextField("Host", text: $host)
                TextField("端口", text: $port)
                    .keyboardType(.numberPad)
                Toggle("使用 TLS", isOn: $useTls)
            }
            Section("模型配置") {
                TextField("Provider", text: $provider)
                TextField("Model", text: $model)
            }
            Section {
                Button {
                    store.disconnectKernel()
                    store.connectKernel(
                        host: host,
                        port: Int(port) ?? 3080,
                        useTls: useTls,
                        provider: provider,
                        model: model,
                        cwd: store.state.workspace.path
                    )
                } label: {
                    Text("重新连接")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if store.state.connection.status == .connected {
                    Button(role: .destructive) {
                        store.disconnectKernel()
                    } label: {
                        Text("断开连接")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            Section("使用提示") {
                Text("iOS 不能内嵌 Node.js 运行时（Apple 禁止 JIT），必须远程连接。在 PC 上运行：\n  pnpm dsh headless --port 3080\n手机连接同局域网 PC 的 IP。")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}
