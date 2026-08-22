import SwiftUI

/// 设备能力自测 — mirrors androidApp DeviceTestView.
/// Direct mode bypasses the JS bridge; full-chain mode goes through
/// harness.js `deviceSelfTest`, exercising the whole bridge path.
struct DeviceTestView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var cases: [DeviceTestCase] = DeviceTestView.buildCases()
    @State private var fullChain = false
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            header
            hint
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(cases.indices, id: \.self) { idx in
                        caseRow(cases[idx])
                            .onTapGesture { runOne(idx) }
                    }
                    unsupportedSection
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    // ── header ───────────────────────────────────────────────

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 34, height: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("设备能力自测")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(fullChain ? "全链路：JavaScriptCore 桥 → native → DeviceBridge" : "直连：DeviceBridge → native API")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textHint)
                }
                Spacer(minLength: 8)
                Button {
                    fullChain.toggle()
                } label: {
                    Text(fullChain ? "全链路" : "直连")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.primaryDim, in: Capsule())
                }
                Button {
                    runAll()
                } label: {
                    Text(running ? "运行中…" : "运行全部")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(running ? Theme.textHint : Theme.onPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(running ? Theme.surfaceElevated : Theme.primary, in: Capsule())
                }
                .disabled(running)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .background(Theme.surface)
    }

    private var hint: some View {
        Text("逐项调用设备桥：查询类直接校验；交互类（授权/选择器/分享/相机）会拉起系统界面；iOS 相机走系统相机 UI，无静默抓拍。")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textHint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .padding(.bottom, 10)
            .background(Theme.surface)
    }

    // ── rows ─────────────────────────────────────────────────

    private func caseRow(_ c: DeviceTestCase) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(c.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(c.op)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textHint)
                }
                if !c.detail.isEmpty {
                    Text(c.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textHint)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Text(c.state)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.statusColor(c.state))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Capabilities the iOS bridge does not implement yet — informational only.
    private var unsupportedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iOS 端暂未接入")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textHint)
                .padding(.top, 10)
            ForEach(Self.unsupported, id: \.0) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Text(item.0)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textHint)
                    }
                    Spacer(minLength: 8)
                    Text("未接入")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textHint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.surfaceElevated, in: Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // ── execution ────────────────────────────────────────────

    private func runOne(_ idx: Int) {
        guard !running else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            await execute(idx)
        }
    }

    private func runAll() {
        guard !running else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            for idx in cases.indices { await execute(idx) }
        }
    }

    @MainActor
    private func execute(_ idx: Int) async {
        let engine = LocalEngine.get()
        let op = cases[idx].op
        let argsJson = cases[idx].argsJson
        cases[idx].state = "运行中"
        cases[idx].detail = ""
        do {
            try await engine.ensureStarted()
            let started = Date()
            let obj: [String: Any]
            if fullChain {
                obj = try await engine.deviceFullChainCall(op: op, argsJson: argsJson)
            } else {
                let (_, json) = try await engine.deviceDirectCall(op: op, argsJson: argsJson)
                obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            }
            let took = Int(Date().timeIntervalSince(started) * 1000)
            let errText = obj["error"] as? String ?? ""
            let ok = (obj["ok"] as? Bool ?? true) && errText.isEmpty
            cases[idx].state = ok ? "通过" : "失败"
            cases[idx].detail = "\(took)ms · " + String(Self.describe(obj).prefix(160))
        } catch {
            cases[idx].state = "失败"
            cases[idx].detail = error.localizedDescription
        }
    }

    private static func describe(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return "\(obj)"
        }
        return String(data: data, encoding: .utf8) ?? "\(obj)"
    }

    // ── catalog ──────────────────────────────────────────────

    /// Args follow the *iOS* DeviceBridge contract (op/files keys differ from Android).
    private static func buildCases() -> [DeviceTestCase] {
        var seq = 0
        func c(_ name: String, _ op: String, _ args: String) -> DeviceTestCase {
            seq += 1
            return DeviceTestCase(id: seq, name: name, op: op, argsJson: args)
        }
        return [
            c("状态总览", "status", "{}"),
            c("权限查询 — 七域状态", "permissions", #"{"op":"list"}"#),
            c("权限申请 — 相机授权弹窗", "permissions", #"{"op":"request","name":"camera"}"#),
            c("剪贴板写入", "clipboard", #"{"op":"write","text":"harnest-device-test"}"#),
            c("剪贴板读取 — 校验回读", "clipboard", #"{"op":"read"}"#),
            c("沙箱写文件", "files", #"{"op":"writeFile","path":"device-test/hello.txt","data":"hello from device bridge"}"#),
            c("沙箱读文件 — 校验回读", "files", #"{"op":"readFile","path":"device-test/hello.txt"}"#),
            c("沙箱列目录", "files", #"{"op":"readdir","path":"device-test"}"#),
            c("文件选择器 — 系统文档选择", "files", #"{"op":"pick"}"#),
            c("图片选择器 — 系统照片选择", "photos", #"{"op":"pick"}"#),
            c("相机 — 系统相机 UI", "camera", #"{"op":"capture"}"#),
            c("网络 — 连通性概览", "network", "{}"),
            c("设备信息", "deviceinfo", "{}"),
            c("触感震动", "vibrate", #"{"style":"heavy"}"#),
            c("分享面板 — 系统分享", "share", #"{"text":"harnest device test"}"#),
        ]
    }

    private static let unsupported: [(String, String)] = [
        ("contacts", "通讯录 — 读写联系人"),
        ("calendar", "日历 — 事件读写"),
        ("call / sms", "拨号 / 短信 — 预填拉起"),
        ("mail", "邮件 — 拉起撰写"),
        ("recorder", "录音 — 开始 / 停止"),
        ("app", "应用 — 列表 / 跳转"),
        ("location", "定位 — 一次定位"),
        ("scheduler", "提醒 / 系统设置 / GUI / 调度"),
    ]
}

struct DeviceTestCase: Identifiable {
    let id: Int
    let name: String
    let op: String
    let argsJson: String
    var state: String = "待测"
    var detail: String = ""
}
