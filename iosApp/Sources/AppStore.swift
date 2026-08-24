import SwiftUI

/// k5 提问卡选项（内核 question 事件下行）。
struct PendingOption: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let description: String
    let isApprove: Bool
}

/// k5 提问卡单个问题。
struct PendingQuestionItem: Identifiable, Equatable {
    let id: Int
    let question: String
    let detail: String
    let header: String
    let multiSelect: Bool
    let options: [PendingOption]
}

/// k5 提问卡（kind=asked 弹出；answered/cancelled 收起）。
struct PendingQuestion {
    let qid: Int
    var planReview = false
    let questions: [PendingQuestionItem]
}

/// k7e 后台任务镜像（仅 running/stopping）。
struct BgJob: Identifiable, Equatable {
    let id: String
    let label: String
    let status: String
}

/// 实时活动条目（round 事件归并 / traceJson 回放共用）。
struct LiveItem: Identifiable {
    enum Kind { case think, answer, tool, steer, subagent, todos }
    let id = UUID()
    let kind: Kind
    var seq = 0
    /// (turn,step) 双键定位段：内核事件自带，跨 turn 同 step 序号不串段（trace 持久化 "u"/"s"）。
    var turn = 0
    var step = 0
    var text = ""
    var callId = ""
    var name = ""
    var args = ""
    var status = ""
    var result = ""
    var todos: [(String, String)] = []
}

/// k5 提问回答项（UI 收集：选中选项 label 列表 + 可选自定义文本）。
struct QuestionPick {
    var selected: [String] = []
    var custom: String?
}

/// App-wide state machine — mirrors androidApp MainActivity / harmonyApp AppViewModel.
@MainActor
final class AppStore: ObservableObject {

    @Published var sessions: [SessionRecord] = []
    @Published var currentSession: SessionRecord?

    @Published var busy = false
    @Published var busyHint = ""
    @Published var toastMsg: String?
    @Published var toastRev = 0

    @Published var showDeviceTest = false
    @Published var showLogs = false
    @Published var logLines: [String] = []

    /// Bumped whenever model selection / provider profiles change.
    @Published var modelRev = 0

    // ── k 系列状态 ────────────────────────────────────────────
    /// k4：待发消息队列（回合结束自动续发；停止清空）
    @Published var queuedMessages: [String] = []
    /// k5：内核提问卡（非 nil 时输入区上方渲染问答卡）
    @Published var pendingQuestion: PendingQuestion?
    /// k7e：后台任务镜像（running/stopping；终止按钮 → killBgJob）
    @Published var bgJobs: [BgJob] = []
    /// k6：Plan 模式（与内核 setPlanMode / details.planActive 同步）
    @Published var planActive = false
    /// 回合实时轨迹（思考段/工具行/转向/子代理/待办），结束后序列化进 traceJson
    @Published var liveItems: [LiveItem] = []
    /// 思考文本节流：避免高频 thinking 事件（60ms 一次、万字文本）卡死 UI
    private var thinkThrottleAt: TimeInterval = 0
    private var thinkPending: String?
    private var thinkPendingTurn = 0
    private var thinkPendingStep = 0
    /// 回复预览同构节流（150ms）：万字 answer 累积全量每 200ms upsert 重建全文 Text 同样卡 UI
    private var answerThrottleAt: TimeInterval = 0
    private var answerPending: String?
    private var answerPendingTurn = 0
    private var answerPendingStep = 0

    /// k6 停止标志（doSend 收尾时检查 — 清空队列 vs 续发）
    private var stopped = false

    private let engine = LocalEngine.get()
    private let store = SessionStore.get()
    private let config = ConfigService.get()

    init() {
        engine.onLogLine = { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.logLines.append(line)
                if self.logLines.count > 400 {
                    self.logLines.removeFirst(self.logLines.count - 400)
                }
            }
        }
        // k2：LLM 自动命名
        engine.onTitleEvent = { [weak self] json in
            Task { @MainActor in self?.applyTitleEvent(json) }
        }
        // 回合实时轨迹
        engine.onRoundEvent = { [weak self] json in
            Task { @MainActor in self?.applyRoundEvent(json) }
        }
        // k3b：会话事件日志镜像（后台线程直投串行写队列，无需切主线程）
        engine.onLogEvent = { [weak self] json in
            guard let self,
                  let data = json.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            self.store.onKernelLogEvent(o)
        }
        // k5：内核提问
        engine.onQuestionEvent = { [weak self] json in
            Task { @MainActor in self?.applyQuestionEvent(json) }
        }
        // k7e：后台任务镜像
        engine.onJobsEvent = { [weak self] json in
            Task { @MainActor in self?.applyJobsEvent(json) }
        }

        sessions = store.loadAll()
        currentSession = sessions.first
    }

    // ── toast ────────────────────────────────────────────────

    func toast(_ msg: String) {
        toastMsg = msg
        toastRev += 1
    }

    func clearToast() {
        toastMsg = nil
    }

    func clearLogs() {
        logLines = []
    }

    // ── sessions ─────────────────────────────────────────────

    func refreshSessions() {
        sessions = store.loadAll()
        if let cur = currentSession, let stored = sessions.first(where: { $0.id == cur.id }) {
            currentSession = stored
        } else if currentSession == nil {
            currentSession = sessions.first
        }
    }

    func newSession() {
        guard config.hasUsableConfig() else {
            toast("请先在设置中配置模型服务")
            return
        }
        let sel = config.getDefaultSelection()
        let record = SessionRecord(
            id: SessionStore.newId(),
            title: "新会话",
            provider: sel.0,
            model: sel.1,
            effort: config.getDefaultEffort()
        )
        store.upsert(record)
        sessions = store.loadAll()
        currentSession = record
    }

    func openSession(_ record: SessionRecord) {
        currentSession = record
        liveItems = []
        pendingQuestion = nil
    }

    func deleteSession(_ record: SessionRecord) {
        store.delete(id: record.id)
        engine.unmountIfMounted(record.id)
        sessions = store.loadAll()
        if currentSession?.id == record.id {
            currentSession = sessions.first
        }
    }

    func clearMessages() {
        guard var s = currentSession else { return }
        s.messages = []
        s.updatedAt = nowMs()
        store.upsert(s)
        currentSession = s
        refreshSessions()
    }

    /// 当前会话切换模型+思考强度（k1：effort nil = 跟随服务端默认）。
    func applyModel(provider: String, model: String, effort: String? = nil) {
        let clean = ReasoningEfforts.isValid(effort) ? effort : nil
        if var s = currentSession {
            s.provider = provider
            s.model = model
            s.effort = clean
            s.updatedAt = nowMs()
            store.upsert(s)
            currentSession = s
        } else {
            // 无当前会话时自动创建一个（用户在模型选择器选模型但还没会话）
            let record = SessionRecord(
                id: SessionStore.newId(),
                title: "新会话",
                provider: provider,
                model: model,
                effort: clean
            )
            store.upsert(record)
            sessions = store.loadAll()
            currentSession = record
        }
        config.setLastSelection(provider: provider, model: model, effort: clean)
        engine.setModel(provider: provider, model: model, effort: clean)
        modelRev += 1
    }

    /// Provider catalog for the model picker — kernel list, fallback to local config.
    func providerCatalog() -> [[String: Any]] {
        let list = engine.listProviders()
        if !list.isEmpty { return list }
        var out: [[String: Any]] = []
        for item in config.listUsableProviders() {
            var models = LocalEngine.stringListAny(item["models"])
            if models.isEmpty { models = [(item["defaultModel"] as? String ?? "")].filter { !$0.isEmpty } }
            out.append([
                "provider": item["provider"] as? String ?? "",
                "baseUrl": item["baseUrl"] as? String ?? "",
                "models": models.map { ["id": $0] as [String: Any] },
            ])
        }
        return out
    }

    // ── chat（k4 排队 + k6 停止） ────────────────────────────

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        if busy {
            // k4：busy → 入队（本轮结束自动续发）
            queuedMessages.append(text)
            toast("⏳ 已排队（第 \(queuedMessages.count) 条）")
            return
        }
        if !engine.isReady() && !config.hasUsableConfig() {
            toast("请先在设置中配置模型服务")
            return
        }
        await doSend(text)
    }

    private func doSend(_ text: String) async {
        stopped = false
        busy = true
        busyHint = "引擎启动中…"
        liveItems = []
        let roundStart = Date()

        var session: SessionRecord
        if let cur = currentSession {
            session = cur
        } else {
            guard config.hasUsableConfig() else {
                toast("请先在设置中选择默认模型")
                finishRound()
                return
            }
            let sel = config.getDefaultSelection()
            session = SessionRecord(
                id: SessionStore.newId(),
                title: "新会话",
                provider: sel.0,
                model: sel.1,
                effort: config.getDefaultEffort()
            )
            store.upsert(session)
            currentSession = session
            refreshSessions()
        }

        do {
            try await engine.ensureStarted()
        } catch {
            busy = false
            busyHint = ""
            appendLocalNote(&session, "出错了：引擎启动失败 \(error.localizedDescription)")
            return
        }

        // k3b：带事件日志种子挂载（内核 replay 重建上下文）
        try? await engine.mountSession(session, seedJson: store.readSeedJson(sessionId: session.id))
        busyHint = ""

        session.messages.append(StoredMessage(
            id: Self.msgId(),
            role: "user",
            content: text,
            provider: session.provider,
            model: session.model
        ))
        session.updatedAt = nowMs()
        if session.title == "新会话" { session.title = SessionStore.titleFrom(text) }
        store.upsert(session)
        currentSession = session
        refreshSessions()

        busyHint = "思考中…"
        do {
            let outcome = try await engine.chat(text)
            // k8：planActive 随回合 details 下行
            if let details = outcome["details"] as? [String: Any] {
                planActive = details["planActive"] as? Bool ?? planActive
            }
            appendOutcome(&session, outcome, roundStart: roundStart)
        } catch {
            // k6：主动停止不算错误（落一条中性提示）
            let note = stopped
                ? "已停止本轮"
                : "发送失败：\(error.localizedDescription)"
            appendStopNote(&session, note, roundStart: roundStart)
            if !stopped { toast("请求失败：\(error.localizedDescription)") }
        }
        finishRound()
    }

    /// 回合收尾：停止 → 清空排队；自然结束 → 自动续发队首（k4）。
    private func finishRound() {
        flushPendingThink()
        busy = false
        busyHint = ""
        if stopped {
            let n = queuedMessages.count
            queuedMessages = []
            toast(n > 0 ? "已停止本轮（清空 \(n) 条排队）" : "已停止本轮")
        } else if !queuedMessages.isEmpty {
            let next = queuedMessages.removeFirst()
            Task { await doSend(next) }
        }
    }

    /// 节流丢帧补偿：把 150ms 窗口内暂存的思考/回复文本落进实时面板（回合收尾保证最终完整）。
    private func flushPendingThink() {
        guard thinkPending != nil || answerPending != nil else { return }
        var items = liveItems
        if let text = thinkPending {
            thinkPending = nil
            upsertThink(&items, text: text, turn: thinkPendingTurn, step: thinkPendingStep, seq: 0)
        }
        if let text = answerPending {
            answerPending = nil
            if let i = items.lastIndex(where: { $0.kind == .answer && $0.turn == answerPendingTurn && $0.step == answerPendingStep }),
               text.count >= items[i].text.count {
                items[i].text = text
            } else {
                var item = LiveItem(kind: .answer)
                item.turn = answerPendingTurn
                item.step = answerPendingStep
                item.text = text
                items.append(item)
            }
        }
        liveItems = items
    }

    /// 按 (turn,step) 幂等 upsert 思考段：内核事件携带段内累积全量，同键且更长时覆盖。
    private func upsertThink(_ items: inout [LiveItem], text: String, turn: Int, step: Int, seq: Int) {
        if let i = items.lastIndex(where: { $0.kind == .think && $0.turn == turn && $0.step == step }),
           text.count >= items[i].text.count {
            items[i].text = text
        } else {
            var item = LiveItem(kind: .think)
            item.seq = seq
            item.turn = turn
            item.step = step
            item.text = text
            items.append(item)
        }
    }

    private func appendOutcome(_ session: inout SessionRecord, _ outcome: [String: Any], roundStart: Date) {
        let details = outcome["details"] as? [String: Any]
        let todosJson: String? = Self.encodeString(details?["todos"])
        let toolCalls = details?["toolCalls"] as? [[String: Any]] ?? []
        let duration = Int64(Date().timeIntervalSince(roundStart) * 1000)
        let trace = traceJson()

        // 实时面板未收到事件时（事件流缺失）回落为回合结束后插入工具行
        if liveItems.isEmpty {
            for tc in toolCalls {
                let name = tc["name"] as? String ?? ""
                let status = tc["status"] as? String ?? ""
                let result = Self.encodeString(tc["result"]) ?? ""
                session.messages.append(StoredMessage(
                    id: Self.msgId(),
                    role: "tool",
                    content: result,
                    provider: session.provider,
                    model: session.model,
                    toolName: name,
                    toolStatus: status,
                    toolResult: result
                ))
            }
        }

        var reply = outcome["replyText"] as? String ?? ""
        if reply.isEmpty { reply = outcome["text"] as? String ?? "" }
        if reply.isEmpty { reply = describeReason(outcome) }

        session.messages.append(StoredMessage(
            id: Self.msgId(),
            role: "assistant",
            content: reply,
            provider: session.provider,
            model: session.model,
            todosJson: liveItems.isEmpty ? todosJson : nil,
            durationMs: duration,
            traceJson: trace.isEmpty ? nil : trace
        ))

        session.updatedAt = nowMs()
        store.upsert(session)
        currentSession = session
        refreshSessions()
    }

    private func appendStopNote(_ session: inout SessionRecord, _ message: String, roundStart: Date) {
        let duration = Int64(Date().timeIntervalSince(roundStart) * 1000)
        session.messages.append(StoredMessage(
            id: Self.msgId(),
            role: "assistant",
            content: message,
            provider: session.provider,
            model: session.model,
            durationMs: duration,
            traceJson: traceJson().isEmpty ? nil : traceJson()
        ))
        session.updatedAt = nowMs()
        store.upsert(session)
        currentSession = session
        refreshSessions()
    }

    private func appendLocalNote(_ session: inout SessionRecord, _ message: String) {
        session.messages.append(StoredMessage(
            id: Self.msgId(),
            role: "assistant",
            content: message
        ))
        session.updatedAt = nowMs()
        store.upsert(session)
        currentSession = session
        refreshSessions()
    }

    private func describeReason(_ outcome: [String: Any]) -> String {
        if let reason = outcome["reason"] as? [String: Any],
           let err = reason["error"] as? [String: Any],
           let msg = err["message"] as? String, !msg.isEmpty {
            return msg
        }
        if let reason = outcome["reason"] as? [String: Any],
           (reason["kind"] as? String) == "max-tokens" {
            return "（模型输出达到长度上限被截断：深度思考占满了输出额度。可简化问题、降低思考强度，或换用输出额度更大的模型后重试）"
        }
        return "（模型没有返回内容）"
    }

    // ── k 系列动作 ────────────────────────────────────────────

    /// k4 转向：进行中的回合注入补充指令（下一 step 边界生效）。
    func steerMessage(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard busy, engine.isReady() else {
            toast("当前无进行中的回合 — 请直接发送")
            return
        }
        do {
            let res = try await engine.steer(text)
            if res["steered"] as? Bool == true {
                if var s = currentSession {
                    s.messages.append(StoredMessage(id: Self.msgId(), role: "user", content: text, steered: true))
                    s.updatedAt = nowMs()
                    store.upsert(s)
                    currentSession = s
                    refreshSessions()
                }
                liveItems.append(LiveItem(kind: .steer, text: text))
                toast("⚡ 已转向 · 下一 step 注入")
            } else {
                toast("内核空闲 — 转向未生效，请直接发送")
            }
        } catch {
            toast("转向失败")
        }
    }

    /// k6 停止当前回合（内核 abortActive + 在途 HTTP 取消 + 清空排队）。
    func stopRound() {
        guard busy else { return }
        stopped = true
        engine.abortActiveRound()
    }

    /// k4 撤销单条排队消息。
    func cancelQueued(_ index: Int) {
        guard index >= 0, index < queuedMessages.count else { return }
        queuedMessages.remove(at: index)
    }

    /// k3 手动压缩当前会话历史（回合间调用）。
    func runCompact() async {
        if busy {
            toast("请等待当前回合结束")
            return
        }
        guard engine.isReady() else {
            toast("内核未启动 — 发送一条消息后再压缩")
            return
        }
        do {
            let res = try await engine.compactNow()
            if res["ok"] as? Bool == true, res["noop"] as? Bool != true {
                let n = (res["shadowedCount"] as? NSNumber)?.intValue ?? 0
                let t = (res["shadowedTokens"] as? NSNumber)?.intValue ?? 0
                toast("已压缩 \(n) 个事件 · 约省 \(t) tokens")
            } else {
                toast("暂无可压缩的历史")
            }
        } catch {
            toast("压缩失败")
        }
    }

    /// k8 Plan 模式开关（回合外立即生效；回合内挂起到下一 pre-step）。
    func togglePlan() async {
        guard engine.isReady() else {
            toast("内核未启动 — 发送一条消息后再切换")
            return
        }
        let next = !planActive
        do {
            let res = try await engine.setPlanMode(active: next)
            if res["ok"] as? Bool != false {
                planActive = (res["active"] as? Bool) ?? next
                toast(planActive ? "🧭 计划模式已开启" : "🧭 计划模式已关闭")
            } else {
                toast("计划模式切换失败")
            }
        } catch {
            toast("计划模式切换失败")
        }
    }

    /// k5 提交提问回答（qid 对应当前 pendingQuestion）。
    func answerPendingQuestion(_ picks: [Int: QuestionPick]) async {
        guard let pq = pendingQuestion else { return }
        var answers: [[String: Any]] = []
        for q in pq.questions {
            let pick = picks[q.id]
            var item: [String: Any] = ["id": q.id, "selected": pick?.selected ?? []]
            if let c = pick?.custom, !c.isEmpty { item["custom"] = c }
            answers.append(item)
        }
        pendingQuestion = nil
        busyHint = ""
        do {
            let data = try JSONSerialization.data(withJSONObject: answers)
            if let json = String(data: data, encoding: .utf8) {
                _ = try await engine.answerQuestion(qid: pq.qid, answersJson: json)
            }
            toast("已提交回答")
        } catch {
            toast("回答提交失败")
        }
    }

    /// k7e 终止后台任务。
    func killBgJob(_ id: String) async {
        do {
            _ = try await engine.killJob(id: id)
            toast("已请求终止后台任务")
        } catch {
            toast("终止失败")
        }
    }

    /// k6 fork：从指定消息分叉新会话（日志截断重放；无日志降级为仅消息视图）。
    func forkFromMessage(_ messageId: String) {
        guard let session = currentSession,
              let idx = session.messages.firstIndex(where: { $0.id == messageId }) else { return }
        // 目标 user 回合序号：截止该消息（含）的 user 消息数
        var userTurn = 0
        for i in 0...idx where session.messages[i].role == "user" {
            userTurn += 1
        }
        let newId = SessionStore.newId()
        var replayed = false
        if userTurn > 0, let seed = store.truncateLogAtUserTurn(sessionId: session.id, targetUserTurn: userTurn) {
            replayed = store.writeSeedText(newId, seed)
        }
        if !replayed && idx == session.messages.count - 1 {
            // 末尾消息 fork：直接全量复制日志
            replayed = store.copyLogTo(fromId: session.id, toId: newId)
        }
        let kept = Array(session.messages[0...idx])
        let newRecord = SessionRecord(
            id: newId,
            title: session.title + " ⑂",
            provider: session.provider,
            model: session.model,
            effort: session.effort,
            messages: kept
        )
        store.upsert(newRecord)
        refreshSessions()
        currentSession = newRecord
        toast(replayed
              ? "已分支（内核上下文已复刻）"
              : "已分支（仅消息视图 · 该会话无事件日志，内核上下文无法复刻）")
    }

    /// 消息评分（同值再点取消；1 赞 / -1 踩 / 0 无）。
    func setRating(messageId: String, value: Int) {
        guard var s = currentSession,
              let idx = s.messages.firstIndex(where: { $0.id == messageId }) else { return }
        s.messages[idx].rating = s.messages[idx].rating == value ? 0 : value
        s.updatedAt = nowMs()
        store.upsert(s)
        currentSession = s
        refreshSessions()
    }

    // ── 内核事件处理 ──────────────────────────────────────────

    /// k2：title 事件 → 会话自动改名（LLM 命名优先于首条消息截断）。
    private func applyTitleEvent(_ json: String) {
        guard let o = Self.parseJson(json),
              let title = (o["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              var s = currentSession else { return }
        s.title = title
        s.updatedAt = nowMs()
        store.upsert(s)
        currentSession = s
        refreshSessions()
    }

    /// k5：question 事件 → 提问卡（kind=asked 弹出 / answered|cancelled 收起）。
    private func applyQuestionEvent(_ json: String) {
        guard let o = Self.parseJson(json) else { return }
        let kind = o["kind"] as? String ?? ""
        if kind != "asked" {
            pendingQuestion = nil
            busyHint = ""
            return
        }
        let qid = (o["qid"] as? NSNumber)?.intValue ?? 0
        var planReview = false
        var questions: [PendingQuestionItem] = []
        for rawQ in (o["questions"] as? [[String: Any]] ?? []) {
            var options: [PendingOption] = []
            for rawOpt in (rawQ["options"] as? [[String: Any]] ?? []) {
                var approve = false
                if let intent = rawOpt["intent"] as? [String: Any] {
                    if intent["approve"] as? Bool == true || (intent["kind"] as? String ?? "") == "plan-review" {
                        approve = true
                        planReview = true
                    }
                }
                options.append(PendingOption(
                    label: rawOpt["label"] as? String ?? "",
                    description: rawOpt["description"] as? String ?? "",
                    isApprove: approve
                ))
            }
            guard !options.isEmpty else { continue }
            questions.append(PendingQuestionItem(
                id: (rawQ["id"] as? NSNumber)?.intValue ?? 0,
                question: rawQ["question"] as? String ?? "",
                detail: rawQ["detail"] as? String ?? "",
                header: rawQ["header"] as? String ?? "",
                multiSelect: rawQ["multiSelect"] as? Bool ?? false,
                options: options
            ))
        }
        guard !questions.isEmpty else { return }
        pendingQuestion = PendingQuestion(qid: qid, planReview: planReview, questions: questions)
        busyHint = "等待你的回答…"
    }

    /// k7e：jobs 事件 → 后台任务镜像（只保留 running/stopping）。
    private func applyJobsEvent(_ json: String) {
        guard let o = Self.parseJson(json) else { return }
        var jobs: [BgJob] = []
        for j in (o["jobs"] as? [[String: Any]] ?? []) {
            let status = j["status"] as? String ?? ""
            if status == "running" || status == "stopping" {
                jobs.append(BgJob(
                    id: j["id"] as? String ?? "",
                    label: j["label"] as? String ?? "",
                    status: status
                ))
            }
        }
        bgJobs = jobs
    }

    /// 把内核 round 事件归并进实时活动列表（思考段/工具行/待办快照/转向/子代理）。
    private func applyRoundEvent(_ json: String) {
        guard busy, let o = Self.parseJson(json) else { return }
        let kind = o["kind"] as? String ?? ""
        var items = liveItems

        switch kind {
        case "thinking":
            let text = o["text"] as? String ?? ""
            let turn = (o["turn"] as? NSNumber)?.intValue ?? 0
            let step = (o["step"] as? NSNumber)?.intValue ?? 0
            let now = Date().timeIntervalSince1970
            // 节流：150ms 内的 thinking 事件只暂存不刷新 UI（窗口须严格小于内核 200ms
            // 心跳，避免同频相位锁死导致整轮不刷新）；万字文本每 60ms 全量重发会卡死主线程。
            // 暂存带 (turn,step) 键——窗口内切段时 flush 不会误并到新段
            if now - thinkThrottleAt < 0.15 {
                thinkPending = text
                thinkPendingTurn = turn
                thinkPendingStep = step
                return
            }
            thinkThrottleAt = now
            upsertThink(&items, text: text, turn: turn, step: step,
                        seq: (o["seq"] as? NSNumber)?.intValue ?? 0)
        case "answer":
            // 回复预览：与思考同构按 (turn,step) 分段 upsert（内核段内累积全量）；
            // 同构 150ms 节流——万字回复全量 upsert 重建 AttributedString 与思考卡顿同构
            let text = o["text"] as? String ?? ""
            let turn = (o["turn"] as? NSNumber)?.intValue ?? 0
            let step = (o["step"] as? NSNumber)?.intValue ?? 0
            let now = Date().timeIntervalSince1970
            if now - answerThrottleAt < 0.15 {
                answerPending = text
                answerPendingTurn = turn
                answerPendingStep = step
                return
            }
            answerThrottleAt = now
            if let i = items.lastIndex(where: { $0.kind == .answer && $0.turn == turn && $0.step == step }),
               text.count >= items[i].text.count {
                items[i].text = text
            } else {
                var item = LiveItem(kind: .answer)
                item.turn = turn
                item.step = step
                item.text = text
                items.append(item)
            }
        case "tool-start":
            var item = LiveItem(kind: .tool)
            item.callId = o["callId"] as? String ?? ""
            item.name = o["name"] as? String ?? "tool"
            item.args = o["args"] as? String ?? ""
            item.status = "running"
            items.append(item)
        case "tool-end":
            let callId = o["callId"] as? String ?? ""
            var merged = false
            if !callId.isEmpty {
                for i in stride(from: items.count - 1, through: 0, by: -1) {
                    if items[i].kind == .tool, items[i].callId == callId {
                        items[i].status = o["status"] as? String ?? "ok"
                        items[i].result = o["result"] as? String ?? ""
                        merged = true
                        break
                    }
                }
            }
            if !merged {
                // 兜底：事件缺 callId 时归并到最后一个运行中的工具
                for i in stride(from: items.count - 1, through: 0, by: -1) {
                    if items[i].kind == .tool, items[i].status == "running" {
                        items[i].status = o["status"] as? String ?? "ok"
                        items[i].result = o["result"] as? String ?? ""
                        break
                    }
                }
            }
        case "todos":
            var todos: [(String, String)] = []
            for t in (o["todos"] as? [[String: Any]] ?? []) {
                todos.append((t["content"] as? String ?? "", t["status"] as? String ?? "pending"))
            }
            var item = LiveItem(kind: .todos)
            item.todos = todos
            if let idx = items.lastIndex(where: { $0.kind == .todos }) {
                items[idx] = item
            } else {
                items.append(item)
            }
        case "agent-start":
            var item = LiveItem(kind: .subagent)
            item.name = o["label"] as? String ?? "子代理"
            item.status = o["phase"] as? String ?? "running"
            items.append(item)
        case "agent-end":
            let label = o["label"] as? String ?? ""
            for i in stride(from: items.count - 1, through: 0, by: -1) {
                if items[i].kind == .subagent, label.isEmpty || items[i].name == label {
                    items[i].status = o["phase"] as? String ?? "done"
                    items[i].result = o["outcome"] as? String ?? ""
                    break
                }
            }
        default:
            break
        }
        liveItems = items
    }

    /// 序列化实时活动列表为轨迹 JSON（与 Android/HarmonyOS parseTrace 同格式）。
    private func traceJson() -> String {
        flushPendingThink()
        guard !liveItems.isEmpty else { return "" }
        var arr: [[String: Any]] = []
        for it in liveItems {
            switch it.kind {
            case .think:
                arr.append(["k": "think", "t": it.text, "s": it.step, "u": it.turn])
            case .answer:
                break // 回复预览不入轨迹：最终 assistant 正文即完整形态
            case .tool:
                arr.append(["k": "tool", "n": it.name, "a": it.args, "s": it.status, "r": it.result])
            case .steer:
                arr.append(["k": "steer", "t": it.text])
            case .subagent:
                arr.append(["k": "subagent", "l": it.name, "p": it.status, "o": it.result])
            case .todos:
                arr.append(["k": "todos", "l": it.todos.map { [$0.0, $0.1] }])
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 轨迹 JSON → LiveItem 列表（历史消息回放渲染）。
    static func parseTrace(_ json: String) -> [LiveItem] {
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var out: [LiveItem] = []
        for o in arr {
            switch o["k"] as? String ?? "" {
            case "think":
                var item = LiveItem(kind: .think, text: o["t"] as? String ?? "")
                item.step = (o["s"] as? NSNumber)?.intValue ?? 0
                item.turn = (o["u"] as? NSNumber)?.intValue ?? 0
                out.append(item)
            case "tool":
                out.append(LiveItem(kind: .tool,
                                    name: o["n"] as? String ?? "",
                                    args: o["a"] as? String ?? "",
                                    status: o["s"] as? String ?? "",
                                    result: o["r"] as? String ?? ""))
            case "steer":
                out.append(LiveItem(kind: .steer, text: o["t"] as? String ?? ""))
            case "subagent":
                out.append(LiveItem(kind: .subagent,
                                    name: o["l"] as? String ?? "",
                                    status: o["p"] as? String ?? "",
                                    result: o["o"] as? String ?? ""))
            default:
                var todos: [(String, String)] = []
                for pair in (o["l"] as? [[String]] ?? []) {
                    if pair.count >= 2 { todos.append((pair[0], pair[1])) }
                }
                var item = LiveItem(kind: .todos)
                item.todos = todos
                out.append(item)
            }
        }
        return out
    }

    // ── 设备快捷 ──────────────────────────────────────────────

    /// Camera quick-action — same direct device call as Android ChatView.
    func quickCamera() async {
        if busy { toast("正在处理中，请稍候"); return }
        busy = true
        busyHint = "调起相机…"
        defer { busy = false; busyHint = "" }
        do {
            try await engine.ensureStarted()
            let (ok, json) = try await engine.deviceDirectCall(op: "camera", argsJson: "{}")
            let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            if ok && obj["ok"] as? Bool != false {
                toast("拍照完成，图片已附加到下次请求")
            } else if obj["cancelled"] as? Bool == true {
                toast("已取消拍照")
            } else {
                toast("拍照失败：\(obj["error"] as? String ?? "未知错误")")
            }
        } catch {
            toast("设备调用失败：\(error.localizedDescription)")
        }
    }

    /// Reboot the kernel and re-mount current session.
    func rebootEngine() async {
        engine.dispose()
        busy = true
        busyHint = "引擎重启中…"
        defer { busy = false; busyHint = "" }
        do {
            try await engine.ensureStarted()
            engine.refreshProfiles()
            if var s = currentSession {
                fallBackUnavailableProvider(&s)
                store.upsert(s)
                currentSession = s
                try? await engine.mountSession(s, seedJson: store.readSeedJson(sessionId: s.id))
            }
            toast("内核已重启")
        } catch {
            toast("重启失败：\(error.localizedDescription)")
        }
    }

    /// 旧会话的 provider 可能已无可用 key（清空 API/换设备后重开历史会话）——
    /// 该 provider 未注册内核 adapter，发消息会报 no adapter registered。回落默认可用选择。
    private func fallBackUnavailableProvider(_ session: inout SessionRecord) {
        let key = ((config.getConfig(session.provider)["apiKey"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty else { return }
        let def = config.getDefaultSelection()
        session.provider = def.0
        session.model = def.1
        session.effort = config.getDefaultEffort()
    }

    /// Hot-apply provider configs after settings save.
    func onConfigChanged() {
        if engine.isReady() {
            engine.refreshProfiles()
        }
        modelRev += 1
    }

    // ── helpers ──────────────────────────────────────────────

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static var msgSeq = 0
    private static func msgId() -> String {
        msgSeq += 1
        return "m-\(Int(Date().timeIntervalSince1970 * 1000))-\(msgSeq)"
    }

    private static func parseJson(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func encodeString(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String { return s }
        // NSNull / NSNumber 等标量顶层会让 dataWithJSONObject 抛 NSInvalidArgumentException
        // （try? 接不住 ObjC 异常，直接崩进程）— isValidJSONObject 前置检查不抛异常。
        // 触发源：内核 details.todos / details.usage 在纯对话回合为 JSON null。
        if any is NSNull { return nil }
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
