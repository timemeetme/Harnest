import SwiftUI
import UniformTypeIdentifiers

/// Settings page — mirrors androidApp SettingsView.kt.
struct SettingsView: View {

    @EnvironmentObject var app: AppStore
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw: String = AppearanceMode.system.rawValue
    @State private var importMsg: String?

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    appearanceSection
                    providerSection
                    transferSection
                    developerSection
                    aboutSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .background(Theme.background)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // ── appearance ───────────────────────────────────────────

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("外观")
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.primary)
                        .frame(width: 22)
                    Text("主题模式")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Picker("主题模式", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // ── providers ────────────────────────────────────────────

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("模型服务")
            VStack(spacing: 6) {
                ForEach(Providers.all, id: \.self) { provider in
                    NavigationLink {
                        ProviderEditView(provider: provider)
                    } label: {
                        ProviderRow(provider: provider)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // ── import / export ──────────────────────────────────────

    private var transferSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("导入 / 导出")
            VStack(spacing: 6) {
                ActionRow(icon: "doc.on.clipboard", title: "从剪贴板导入配置", subtitle: "支持 EMM 格式的模型配置 JSON") {
                    importFromClipboard()
                }
                ActionRow(icon: "doc.on.doc", title: "复制全部配置到剪贴板", subtitle: "导出为 EMM 格式 JSON") {
                    let json = ConfigService.get().exportConfigJson()
                    UIPasteboard.general.string = json
                    app.toast("已复制 \(json.count) 字符到剪贴板")
                }
                if let msg = importMsg {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textHint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importMsg = "剪贴板为空"
            return
        }
        let (count, errors) = ConfigService.get().importConfigJson(text)
        if count > 0 {
            importMsg = "已导入 \(count) 个模型服务配置"
            app.onConfigChanged()
            app.toast("已导入 \(count) 个模型服务")
        } else {
            importMsg = errors.first ?? "导入失败：剪贴板内容不是有效的配置 JSON"
        }
    }

    // ── developer ────────────────────────────────────────────

    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("开发者")
            VStack(spacing: 6) {
                ActionRow(icon: "checkmark.seal", title: "设备能力自测", subtitle: "直连 / 全链路验证设备桥能力") {
                    app.showDeviceTest = true
                }
                ActionRow(icon: "terminal", title: "内核日志", subtitle: "查看 harness 引擎运行日志") {
                    app.showLogs = true
                }
            }
        }
    }

    // ── about ────────────────────────────────────────────────

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("关于")
            VStack(spacing: 6) {
                infoRow("应用", "Harnest (iOS) 1.0.0")
                infoRow("内核", LocalEngine.get().isReady() ? "引擎运行中" : "未启动（首次对话时自动启动）")
                infoRow("内核目录", AppPaths.harnessDir.lastPathComponent)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textHint)
            .padding(.horizontal, 4)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textHint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// ── provider row ────────────────────────────────────────────

private struct ProviderRow: View {
    let provider: String

    private var meta: ProviderMeta? { Providers.metaOf(provider) }
    private var cfg: [String: Any] { ConfigService.get().getConfig(provider) }
    private var configured: Bool {
        (cfg["apiKey"] as? String ?? "").isEmpty == false
    }
    private var modelCount: Int {
        (cfg["models"] as? [Any] ?? []).count
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meta?.label ?? provider)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(meta?.baseUrl ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textHint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(configured ? "已配置 · \(modelCount) 个模型" : "未配置")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(configured ? Theme.accent : Theme.textHint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(configured ? Theme.accentDim : Theme.surfaceElevated)
                .clipShape(Capsule())
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textHint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// ── action row ──────────────────────────────────────────────

struct ActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textHint)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textHint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// ── provider edit ───────────────────────────────────────────

struct ProviderEditView: View {

    let provider: String

    @EnvironmentObject var app: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var baseUrl = ""
    @State private var models: [String] = []
    @State private var defaultModel = ""
    @State private var maxTokens = ""
    @State private var showKey = false
    @State private var newModel = ""
    @State private var addModelField = false

    private var meta: ProviderMeta? { Providers.metaOf(provider) }
    private var keyUrl: URL? {
        guard let url = meta?.keyUrl, !url.isEmpty else { return nil }
        return URL(string: url)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                apiKeySection
                baseUrlSection
                maxTokensSection
                modelsSection
                saveSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .background(Theme.background)
        .navigationTitle(meta?.label ?? provider)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        let cfg = ConfigService.get().getConfig(provider)
        apiKey = cfg["apiKey"] as? String ?? ""
        baseUrl = cfg["baseUrl"] as? String ?? meta?.baseUrl ?? ""
        models = LocalEngine.stringListAny(cfg["models"])
        defaultModel = cfg["defaultModel"] as? String ?? (models.first ?? "")
        if defaultModel.isEmpty && !models.isEmpty {
            defaultModel = models[0]
        }
        if let mt = cfg["maxTokens"] as? Int, mt > 0 {
            maxTokens = String(mt)
        } else {
            maxTokens = ""
        }
    }

    // ── api key ──────────────────────────────────────────────

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textHint)
            HStack(spacing: 8) {
                Group {
                    if showKey {
                        TextField("sk-…", text: $apiKey)
                    } else {
                        SecureField("sk-…", text: $apiKey)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textHint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if let url = keyUrl {
                Link(destination: url) {
                    Text("获取 API Key：\(url.host ?? url.absoluteString)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.primary)
                        .underline()
                }
            }
        }
    }

    // ── base url ─────────────────────────────────────────────

    private var baseUrlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("接口地址 Base URL")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textHint)
            TextField("https://…", text: $baseUrl)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if let def = meta?.baseUrl, baseUrl == def {
                Text("使用官方默认地址")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textHint)
            }
        }
    }

    // ── models ───────────────────────────────────────────────

    private var maxTokensSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最大输出 Tokens（留空用默认）")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textHint)
            TextField("如 8192", text: $maxTokens)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.numberPad)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("模型列表（\(models.count)）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textHint)
                Spacer()
                Button {
                    addModelField.toggle()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primary)
                }
            }

            if addModelField {
                HStack(spacing: 8) {
                    TextField("输入模型 ID，如 gpt-4o", text: $newModel)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("添加") {
                        let m = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !m.isEmpty else { return }
                        if !models.contains(m) { models.append(m) }
                        newModel = ""
                        addModelField = false
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if models.isEmpty {
                Text("暂无模型，请点击 + 添加")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textHint)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(models, id: \.self) { model in
                        modelRow(model)
                    }
                }
            }
        }
    }

    private func modelRow(_ model: String) -> some View {
        let isDefault = model == defaultModel
        return HStack(spacing: 10) {
            Button {
                defaultModel = model
            } label: {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(isDefault ? Theme.warning : Theme.textHint)
            }
            .buttonStyle(.plain)

            Text(model)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)

            if isDefault {
                Text("默认")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.warningDim)
                    .clipShape(Capsule())
            }

            Spacer()

            Button {
                models.removeAll { $0 == model }
                if defaultModel == model {
                    defaultModel = models.first ?? ""
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textHint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // ── save ─────────────────────────────────────────────────

    private var saveSection: some View {
        VStack(spacing: 8) {
            Button(action: save) {
                Text("保存")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(canSave ? Theme.primary : Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canSave)

            Text("留空 API Key 即可停用该服务")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textHint)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 6)
    }

    private var canSave: Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return true }
        let url = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return false }
        return !models.isEmpty && !defaultModel.isEmpty
    }

    private func save() {
        let mt = Int(maxTokens.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        ConfigService.get().setConfig(
            provider: provider,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseUrl: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            models: models,
            defaultModel: defaultModel,
            maxTokens: mt > 0 ? mt : nil
        )
        app.onConfigChanged()
        app.toast("已保存 \(meta?.label ?? provider) 配置")
        dismiss()
    }
}
