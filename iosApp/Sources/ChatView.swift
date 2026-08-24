import SwiftUI

/// Chat page — mirrors androidApp ChatView.kt / harmonyApp ChatView.ets.
/// k4 排队/转向 · k5 提问卡 · k6 Plan/停止/fork · k7e 后台任务 · k8 Markdown/评分。
struct ChatView: View {

    @EnvironmentObject var app: AppStore
    @State private var draft = ""
    @State private var showDrawer = false
    @State private var showModelPicker = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.border)
                messageList
                // k5：内核提问卡（非 nil 时输入区上方渲染；plan-review 走批准流）
                if app.pendingQuestion != nil {
                    PendingQuestionCard()
                }
                // k6：回合实时轨迹面板（思考/工具/转向/子代理/待办）
                LiveActivityPanel(items: app.liveItems, live: true)
                inputBar
            }
            .background(Theme.background)

            if showDrawer { sessionDrawer }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView()
                .presentationDetents([.medium, .large])
        }
    }

    // ── header（模型 chip / Plan / 压缩 / 新会话） ───────────

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showDrawer = true }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("会话列表")

            Button {
                showModelPicker = true
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.currentSession?.title ?? "Harnest 对话")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Text(headerSubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textHint)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textHint)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)

            // iOS 增强：快捷相机（拍摄后发送）/ 引擎重启
            Button {
                Task { await app.quickCamera() }
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, height: 34)
            }
            .disabled(app.busy)
            .accessibilityLabel("快捷相机")

            Button {
                Task { await app.rebootEngine() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, height: 34)
            }
            .disabled(app.busy)
            .accessibilityLabel("重启引擎")

            // k5/k6：Plan 模式开关 — 开启后 agent 先产出计划，经提问卡批准才执行
            Button {
                Task { await app.togglePlan() }
            } label: {
                Text("🧭")
                    .font(.system(size: 15))
                    .frame(width: 34, height: 34)
                    .background(app.planActive ? Theme.primary.opacity(0.18) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(app.planActive ? Theme.primary : .clear, lineWidth: 1)
                    )
            }
            .accessibilityLabel(app.planActive ? "关闭计划模式" : "开启计划模式")

            // k3：手动压缩历史（回合间可用）
            if canCompact {
                Button {
                    Task { await app.runCompact() }
                } label: {
                    Text("🗜")
                        .font(.system(size: 15))
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("压缩会话历史")
            }

            Button {
                app.newSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel("新会话")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    private var canCompact: Bool {
        // 蓝本：!isSending && messages.isNotEmpty()
        !app.busy && !(app.currentSession?.messages ?? []).isEmpty
    }

    private var headerSubtitle: String {
        guard let s = app.currentSession else { return "未选择模型" }
        var text = "\(Providers.metaOf(s.provider)?.label ?? s.provider) · \(s.model)"
        if let e = s.effort { text += " · \(ReasoningEfforts.label(e))" }
        let usable = ConfigService.get().listUsableProviders().count
        if usable > 1 { text += " · \(usable) 个服务" }
        return text
    }

    // ── 消息流 ────────────────────────────────────────────────

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    let messages = app.currentSession?.messages ?? []
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages) { msg in
                            MessageRow(message: msg)
                                .id(msg.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("chatBottom")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: app.currentSession?.id) {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: app.currentSession?.messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: app.liveItems.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: app.liveItems.reduce(0) { $0 + $1.text.count }) {
                scrollToBottom(proxy)
            }
            .onTapGesture { inputFocused = false }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("chatBottom", anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(Theme.textHint)
            Text("开始新的对话")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(ConfigService.get().hasUsableConfig()
                 ? "输入消息，Agent 会自动规划任务并调用设备能力"
                 : "尚未配置模型服务，请先到「设置」完成配置")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textHint)
                .multilineTextAlignment(.center)
            // k7e：空态下常驻后台任务卡（全部退出后自动消失）
            if !app.bgJobs.isEmpty {
                BackgroundJobsCard()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.bottom, 20)
    }

    // ── 输入区（k4 排队/转向 + k6 停止） ──────────────────────

    private var inputBar: some View {
        VStack(spacing: 6) {
            if app.busy && !app.busyHint.isEmpty { busyBar }
            if !app.queuedMessages.isEmpty { queuedChips }
            HStack(spacing: 10) {
                TextField(
                    app.busy ? "追加指令：⚡转向 或 ⏳排队…" : "发送消息…",
                    text: $draft, axis: .vertical
                )
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onSubmit { submit() }

                if app.busy {
                    // 回合运行中：⏳ 排队（本轮后发）/ ⚡ 转向（注入当前回合）/ ■ 停止
                    if hasDraft {
                        Button { submit(.queue) } label: {
                            Text("⏳")
                                .font(.system(size: 15))
                                .frame(width: 38, height: 38)
                                .background(Theme.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityLabel("排队发送")
                        Button { submit(.steer) } label: {
                            Text("⚡")
                                .font(.system(size: 15))
                                .frame(width: 38, height: 38)
                                .background(Theme.warning.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityLabel("中途转向")
                    }
                    Button {
                        app.stopRound()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Theme.error)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityLabel("停止")
                } else {
                    Button(action: { submit() }) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .background(hasDraft ? Theme.primary : Theme.surfaceElevated)
                            .foregroundStyle(hasDraft ? Theme.onPrimary : Theme.textHint)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!hasDraft)
                    .accessibilityLabel("发送")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.inputBar)
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var busyBar: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.primary)
            Text(app.busyHint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }

    /// k4 排队区：待发消息 chip 列表（点击 × 撤销单条），回合结束自动出队续发。
    private var queuedChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("⏳ 已排队 \(app.queuedMessages.count) 条 · 本轮结束后自动发送")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textHint)
            ForEach(app.queuedMessages.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text(app.queuedMessages[i])
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        app.cancelQueued(i)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textHint)
                            .frame(width: 20, height: 20)
                    }
                    .accessibilityLabel("撤销排队第 \(i + 1) 条")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private enum SubmitMode { case send, queue, steer }

    private func submit(_ mode: SubmitMode = .send) {
        guard hasDraft else { return }
        let text = draft
        draft = ""
        switch mode {
        case .send:
            Task { await app.send(text) }
        case .queue:
            Task { await app.send(text) }   // busy 中 send = 自动入队
        case .steer:
            Task { await app.steerMessage(text) }
        }
    }

    // ── 会话抽屉 ──────────────────────────────────────────────

    private var sessionDrawer: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { showDrawer = false } }

            HStack(spacing: 0) {
                sessionPanel
                Spacer(minLength: 0)
            }
            .transition(.move(edge: .leading))
        }
    }

    private var sessionPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    withAnimation { showDrawer = false }
                    app.newSession()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("新会话")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.primary)
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(Theme.border)

            ScrollView {
                LazyVStack(spacing: 6) {
                    if app.sessions.isEmpty {
                        Text("暂无历史会话")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textHint)
                            .padding(.top, 30)
                    } else {
                        ForEach(app.sessions) { s in
                            SessionRow(
                                record: s,
                                active: s.id == app.currentSession?.id,
                                deletable: app.sessions.count > 1
                            ) {
                                app.openSession(s)
                                withAnimation(.easeOut(duration: 0.18)) { showDrawer = false }
                            } onDelete: {
                                app.deleteSession(s)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
    }
}

// ── message row（user 气泡 / 工具卡 / assistant 气泡） ───────

private struct MessageRow: View {
    @EnvironmentObject var app: AppStore
    let message: StoredMessage

    var body: some View {
        if message.role == "user" {
            UserBubble(message: message)
        } else if message.toolName != nil {
            ToolCard(message: message)
        } else {
            AssistantBubble(message: message)
        }
    }
}

/// k4：user 气泡 — 转向注入的消息带 ⚡ 标记。
private struct UserBubble: View {
    let message: StoredMessage

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if message.steered {
                Text("⚡")
                    .font(.system(size: 11))
                    .padding(.top, 7)
            }
            Spacer(minLength: 48)
            Text(message.content)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.bubbleUser)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// assistant 气泡 — meta 行 + 轨迹回放 + Markdown 正文 + 尾部操作。
private struct AssistantBubble: View {
    @EnvironmentObject var app: AppStore
    let message: StoredMessage

    private var isError: Bool { message.id.hasPrefix("err_") }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if !metaLine.isEmpty {
                    Text(metaLine)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textHint)
                }
                // 轨迹回放：traceJson → LiveItem（历史消息的思考/工具/转向折叠面板）
                if let trace = message.traceJson, !trace.isEmpty {
                    let items = AppStore.parseTrace(trace)
                    if !items.isEmpty {
                        LiveActivityPanel(items: items, live: false)
                    }
                }
                MarkdownBody(text: message.content, isError: isError)
                if let todos = message.todosJson, !todos.isEmpty {
                    TodoSnapshot(json: todos)
                }
                if !isError { actionRow }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.bubbleAgent)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 48)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let p = message.provider, !p.isEmpty {
            parts.append(Providers.metaOf(p)?.label ?? p)
        }
        if let m = message.model, !m.isEmpty { parts.append(m) }
        if message.durationMs > 0 { parts.append("⏱\(AssistantBubble.fmtDuration(message.durationMs))") }
        return parts.joined(separator: " · ")
    }

    static func fmtDuration(_ ms: Int64) -> String {
        let s = Int(ms) / 1000
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m\(s % 60)s"
    }

    /// 尾部操作：👍👎 评分（选中高亮 pill）/ 📋 复制 / 🍴 fork 分叉。
    private var actionRow: some View {
        HStack(spacing: 6) {
            rateButton("👍", 1)
            rateButton("👎", -1)
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)
            Button {
                UIPasteboard.general.string = message.content
                app.toast("📋 已复制回复内容")
            } label: {
                Text("📋").font(.system(size: 13)).frame(width: 30, height: 26)
            }
            .accessibilityLabel("复制回复")
            Button {
                app.forkFromMessage(message.id)
            } label: {
                Text("🍴").font(.system(size: 13)).frame(width: 30, height: 26)
            }
            .accessibilityLabel("从此处分叉新会话")
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func rateButton(_ emoji: String, _ value: Int) -> some View {
        Button {
            app.setRating(messageId: message.id, value: value)
        } label: {
            Text(emoji)
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
                .background(message.rating == value ? Theme.primary.opacity(0.28) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(value > 0 ? "赞" : "踩")
    }
}

// ── tool card（状态色边条 + 图标 + 待办 + MCP 图片 + 终端结果） ──

private struct ToolCard: View {
    let message: StoredMessage

    private var status: String { message.toolStatus ?? "" }
    private var running: Bool { status == "running" || status == "运行中" }
    private var failed: Bool {
        status == "error" || status == "fail" || status == "失败"
    }
    private var terminated: Bool {
        failed && (message.toolResult ?? "").contains("终止")
    }

    private var edgeColor: Color {
        running ? Theme.warning : (failed ? Theme.error : Theme.border)
    }

    private var icon: String {
        let name = message.toolName ?? ""
        if name.contains("camera") { return "camera.fill" }
        if name.contains("clipboard") { return "doc.on.doc" }
        if name.contains("files") || name.contains("photos") { return "folder" }
        if name.contains("network") || name.contains("http") { return "network" }
        if name.contains("vibrate") { return "iphone.radiowaves.left.and.right" }
        if name.contains("share") { return "square.and.arrow.up" }
        if name.contains("shell") || name.contains("exec") || name.contains("bash") { return "terminal" }
        return "wrench.and.screwdriver"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Group {
                    if running {
                        ProgressView().controlSize(.small).tint(Theme.warning)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 13))
                            .foregroundStyle(failed ? Theme.error : Theme.primary)
                    }
                }
                .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.toolName ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if terminated {
                        Text("⛔ 已终止")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.error)
                    }
                }
                Spacer(minLength: 6)
                Text(running ? "运行中" : (failed ? "失败" : "完成"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(running ? Theme.warning : (failed ? Theme.error : Theme.success))
            }

            if let todos = message.todosJson, !todos.isEmpty {
                TodoSnapshot(json: todos)
            }

            // k8：MCP 工具结果内嵌图片（content[].type=image 的 base64）
            if let result = message.toolResult {
                McpImageView(result: result)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border.opacity(0.6), lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            // 状态色边条：running=warning / error=error / 其他=divider
            RoundedRectangle(cornerRadius: 1.5)
                .fill(edgeColor)
                .frame(width: 3)
                .padding(.vertical, 6)
                .padding(.leading, 0)
        }
    }
}

/// MCP 图片结果：`{"content":[{"type":"image","data":"<base64>"}]}` → 图片，否则回退终端文本。
private struct McpImageView: View {
    let result: String

    private var imageData: Data? {
        guard let data = result.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["content"] as? [[String: Any]],
              let img = arr.first(where: { ($0["type"] as? String) == "image" }),
              let b64 = img["data"] as? String,
              let decoded = Data(base64Encoded: b64) else { return nil }
        return decoded
    }

    var body: some View {
        if let data = imageData, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if !result.isEmpty {
            // 终端类结果：等宽 4 行摘要
            Text(result)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textHint)
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.background.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// ── todo snapshot ───────────────────────────────────────────

private struct TodoSnapshot: View {

    struct Item: Identifiable {
        let id = UUID()
        let content: String
        let status: String
    }

    let items: [Item]

    init(json: String) {
        var parsed: [Item] = []
        if let data = json.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for obj in arr {
                let content = obj["content"] as? String ?? obj["text"] as? String ?? ""
                let status = obj["status"] as? String ?? "pending"
                parsed.append(Item(content: content, status: status))
            }
        }
        items = parsed
    }

    private var doneCount: Int {
        items.filter { $0.status == "done" || $0.status == "completed" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("任务清单 · \(doneCount)/\(items.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textHint)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: item.status == "done" || item.status == "completed" ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(item.status == "done" || item.status == "completed" ? Theme.accent : Theme.textHint)
                    Text(item.content)
                        .font(.system(size: 11))
                        .foregroundStyle(item.status == "done" || item.status == "completed" ? Theme.textHint : Theme.textSecondary)
                        .strikethrough(item.status == "done" || item.status == "completed", color: Theme.textHint)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// ── 实时活动面板（live 当前回合 / replay 历史回放共用） ───────

struct LiveActivityPanel: View {

    let items: [LiveItem]
    /// live=true：随 busy 自动展开；false：历史回放默认折叠。
    var live: Bool = false

    @EnvironmentObject private var app: AppStore
    @State private var expanded = false

    private var thinkChars: Int {
        items.filter { $0.kind == .think }.reduce(0) { $0 + $1.text.count }
    }
    private var answerChars: Int {
        items.filter { $0.kind == .answer }.reduce(0) { $0 + $1.text.count }
    }
    private var steerCount: Int {
        items.filter { $0.kind == .steer }.count
    }

    private var summaryText: String {
        var parts = ["\(items.count) 步"]
        if thinkChars > 0 { parts.append("\(thinkChars) 字思考") }
        if answerChars > 0 { parts.append("\(answerChars) 字回复") }
        if steerCount > 0 { parts.append("⚡\(steerCount) 转向") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        if live { PulseDot() }
                        Text(summaryText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textHint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(items) { item in
                                    LiveItemRow(item: item)
                                        .id(item.id)
                                }
                                Color.clear.frame(height: 1).id("liveBottom")
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                        }
                        .frame(maxHeight: 280)
                        .transition(.opacity)
                        .onChange(of: thinkChars) { _, _ in
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("liveBottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border.opacity(0.6), lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .onAppear {
                if live { expanded = true }
            }
            .onChange(of: live ? app.busy : false) { _, busy in
                // 回合结束自动折叠（延迟 0.6s 避免闪烁）
                if !busy && expanded {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if !app.busy { withAnimation { expanded = false } }
                    }
                }
            }
        }
    }
}

/// 呼吸圆点：回合运行中的视觉心跳。
private struct PulseDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Theme.primary)
            .frame(width: 6, height: 6)
            .scaleEffect(pulsing ? 1.3 : 0.7)
            .opacity(pulsing ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

/// 单条活动行：思考/工具/转向/子代理/待办 五类形态。
private struct LiveItemRow: View {
    let item: LiveItem

    var body: some View {
        switch item.kind {
        case .think:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("💭")
                        .font(.system(size: 11))
                    Text("思考 · 第 \(item.seq) 轮")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textHint)
                }
                Text(item.text.count > 4000
                     ? "…（已省略 \(item.text.count - 4000) 字，仅展示尾部）\n\(item.text.suffix(4000))"
                     : item.text)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Theme.background.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .answer:
            Text(item.text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(12)
                .truncationMode(.tail)

        case .tool:
            LiveToolRow(item: item)

        case .steer:
            // k4 转向条目：⚡ 高亮（下一 step 边界生效）
            HStack(alignment: .top, spacing: 5) {
                Text("⚡")
                    .font(.system(size: 11))
                Text(item.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Theme.warning.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .subagent:
            HStack(alignment: .top, spacing: 5) {
                Text("🤖")
                    .font(.system(size: 11))
                Text(item.text)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.vertical, 2)

        case .todos:
            LiveTodosBlock(item: item)
        }
    }
}

/// 工具步骤行：状态色边条 + 图标 + 名称 + 等宽结果摘要。
private struct LiveToolRow: View {
    let item: LiveItem

    private var running: Bool { item.status == "running" || item.status == "运行中" }
    private var failed: Bool {
        item.status == "error" || item.status == "fail" || item.status == "失败"
    }
    private var terminated: Bool {
        failed && item.result.contains("终止")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(running ? Theme.warning : (failed ? Theme.error : Theme.border))
                .frame(width: 3)
                .frame(minHeight: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundStyle(failed ? Theme.error : Theme.primary)
                    Text(item.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if terminated {
                        Text("⛔ 已终止")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.error)
                    } else if running {
                        Text("运行中…")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.warning)
                    } else if failed {
                        Text("失败")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.error)
                    }
                }
                if !item.args.isEmpty {
                    Text(item.args)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textHint)
                        .lineLimit(2)
                }
                if !item.result.isEmpty {
                    Text(item.result)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textHint)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(Theme.background.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 待办快照：done/total + 条目列表。
private struct LiveTodosBlock: View {
    let item: LiveItem

    private var doneCount: Int {
        item.todos.filter { $0.1 == "done" || $0.1 == "completed" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("☑️ 待办 · \(doneCount)/\(item.todos.count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textHint)
            ForEach(Array(item.todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: todo.1 == "done" || todo.1 == "completed" ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(todo.1 == "done" || todo.1 == "completed" ? Theme.accent : Theme.textHint)
                    Text(todo.0)
                        .font(.system(size: 10))
                        .foregroundStyle(todo.1 == "done" || todo.1 == "completed" ? Theme.textHint : Theme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.background.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// ── k5 提问卡（普通问答 / plan-review 批准流） ───────────────

private struct PendingQuestionCard: View {
    @EnvironmentObject var app: AppStore

    /// 题目下标 → 选择（选项 label 列表 + 可选自定义文本）
    @State private var picks: [Int: QuestionPick] = [:]

    private var question: PendingQuestion {
        app.pendingQuestion ?? PendingQuestion(qid: 0, questions: [])
    }

    /// 全部作答才可提交
    private var allAnswered: Bool {
        guard !question.questions.isEmpty else { return false }
        for i in question.questions.indices {
            let p = picks[i]
            let hasSelection = !(p?.selected.isEmpty ?? true)
            let hasCustom = !(p?.custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            if !hasSelection && !hasCustom { return false }
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.planReview ? "🧭 计划待审批" : "❓ Agent 在等你回答")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(question.planReview ? Theme.primary : Theme.warning)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(question.questions.enumerated()), id: \.element.id) { idx, q in
                        questionBlock(idx, q)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)

            Button {
                Task { await app.answerPendingQuestion(picks) }
                picks = [:]
            } label: {
                Text("提交回答")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(allAnswered ? Theme.primary : Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!allAnswered)
        }
        .padding(12)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.warning.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onDisappear { picks = [:] }
    }

    @ViewBuilder
    private func questionBlock(_ idx: Int, _ q: PendingQuestionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !q.header.isEmpty {
                Text(q.header)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textHint)
            }
            Text(q.question)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            if !q.detail.isEmpty {
                Text(q.detail)
                    .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            }

            ForEach(q.options) { opt in
                optionRow(idx, q, opt)
            }

            // 自由文本：plan-review = 修改意见（代替批准）；普通题 = 其他。单选输入即取消选项
            TextField(
                question.planReview ? "提出修改意见（代替批准）…" : "其他（可选，直接输入文字）…",
                text: Binding(
                    get: { picks[idx]?.custom ?? "" },
                    set: { text in
                        var p = picks[idx] ?? QuestionPick()
                        p.custom = text
                        if !text.trimmingCharacters(in: .whitespaces).isEmpty && !q.multiSelect {
                            p.selected = []   // 单选：输入即取消选项
                        }
                        picks[idx] = p
                    }
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.background.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .background(Theme.background.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func optionRow(_ idx: Int, _ q: PendingQuestionItem, _ opt: PendingOption) -> some View {
        let selected = picks[idx]?.selected.contains(opt.label) ?? false
        return Button {
            var p = picks[idx] ?? QuestionPick()
            if q.multiSelect {
                if selected {
                    p.selected.removeAll { $0 == opt.label }
                } else {
                    p.selected.append(opt.label)
                }
            } else {
                p.selected = selected ? [] : [opt.label]
                if !selected { p.custom = nil }   // 选了选项即清空修改意见
            }
            picks[idx] = p
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected
                      ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (q.multiSelect ? "square" : "circle"))
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.primary : Theme.textHint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(opt.label)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.primary : Theme.textPrimary)
                            .multilineTextAlignment(.leading)
                        // plan-review：批准项右侧标注（intent.approve 命名定位，不按位置推断）
                        if opt.isApprove {
                            Text("批准")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.primary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.primary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    if !opt.description.isEmpty {
                        Text(opt.description)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textHint)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Theme.primary.opacity(0.07) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// ── k7e 后台任务卡 ──────────────────────────────────────────

struct BackgroundJobsCard: View {
    @EnvironmentObject var app: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("后台任务 · \(app.bgJobs.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
            ForEach(app.bgJobs) { job in
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.warning)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(job.status)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textHint)
                    }
                    Spacer()
                    Button {
                        Task { await app.killBgJob(job.id) }
                    } label: {
                        Text("终止")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.error)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Theme.error.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.warning.opacity(0.4), lineWidth: 0.5)
        )
        .padding(.top, 8)
    }
}

// ── session row ─────────────────────────────────────────────

private struct SessionRow: View {
    let record: SessionRecord
    let active: Bool
    var deletable: Bool = true
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var timeText: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(record.createdAt)))
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Theme.primary : Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(record.provider) · \(record.model) · \(timeText)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textHint)
                        .lineLimit(1)
                }
                Spacer()
                if deletable {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textHint)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除会话")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(active ? Theme.primaryDim : Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? Theme.primary.opacity(0.5) : Theme.border.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// ── model picker（模型 / 思考模式 两个并列 Tab） ─────────────

struct ModelPickerView: View {

    @EnvironmentObject var app: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var tab: PickerTab = .model

    enum PickerTab: String, CaseIterable {
        case model = "模型"
        case effort = "思考模式"
    }

    struct ModelRow: Identifiable {
        var id: String { "\(provider)/\(model)" }
        let provider: String
        let providerLabel: String
        let model: String
    }

    struct ProviderGroup: Identifiable {
        var id: String { provider }
        let provider: String
        let label: String
        let models: [ModelRow]
    }

    private var groups: [ProviderGroup] {
        var out: [ProviderGroup] = []
        for p in app.providerCatalog() {
            let provider = p["provider"] as? String ?? ""
            let label = Providers.metaOf(provider)?.label ?? provider
            let models = (p["models"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
                .filter { !$0.isEmpty }
                .map { ModelRow(provider: provider, providerLabel: label, model: $0) }
            if !models.isEmpty {
                out.append(ProviderGroup(provider: provider, label: label, models: models))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 Tab 切换
            HStack(spacing: 0) {
                ForEach(PickerTab.allCases, id: \.self) { t in
                    Button {
                        withAnimation { tab = t }
                    } label: {
                        Text(t.rawValue)
                            .font(.system(size: 15, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? Theme.primary : Theme.textHint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider().overlay(Theme.border)

            ScrollView {
                if tab == .model {
                    modelList
                } else {
                    effortList
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Theme.surface)
    }

    // ── 模型列表 ──

    private var modelList: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(groups) { group in
                Text(group.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textHint)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                ForEach(group.models) { row in
                    modelRow(row)
                }
            }
        }
    }

    private func modelRow(_ row: ModelRow) -> some View {
        let selected = app.currentSession?.provider == row.provider
            && app.currentSession?.model == row.model
        return Button {
            // 选模型即生效，effort 保留当前值；sheet 自动收起
            app.applyModel(provider: row.provider, model: row.model, effort: app.currentSession?.effort)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.model)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.primary : Theme.textPrimary)
                    Text(row.providerLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textHint)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? Theme.primaryDim : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // ── 思考模式列表（独立于模型选择，基于当前会话） ──

    private var effortList: some View {
        let current = app.currentSession?.effort
        return VStack(alignment: .leading, spacing: 6) {
            effortRow(effort: nil, label: ReasoningEfforts.label(nil),
                      caption: "跟随服务端默认", selected: current == nil)
            ForEach(ReasoningEfforts.ids, id: \.self) { e in
                effortRow(effort: e, label: ReasoningEfforts.label(e),
                          caption: effortCaption(e), selected: current == e)
            }
        }
    }

    private func effortCaption(_ e: String) -> String {
        switch e {
        case "off": return "不产出思考，速度最快"
        case "high": return "常规思考"
        case "max": return "深度思考，耗时更长"
        default: return ""
        }
    }

    private func effortRow(effort: String?, label: String, caption: String, selected: Bool) -> some View {
        Button {
            // 思考模式独立切换，保留当前模型不变
            if let s = app.currentSession {
                app.applyModel(provider: s.provider, model: s.model, effort: effort)
            }
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.primary : Theme.textPrimary)
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textHint)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(selected ? Theme.primaryDim : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
