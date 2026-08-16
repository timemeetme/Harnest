import SwiftUI
import shared

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @Binding var selectedId: String?
    @State private var searchText = ""
    @State private var showSettings = false

    private var filteredSessions: [SessionUi] {
        let sessions = store.state.sessions
        if searchText.isEmpty { return Array(sessions) }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            List(selection: $selectedId) {
                Section("会话") {
                    ForEach(filteredSessions, id: \.id) { session in
                        SessionRow(session: session)
                            .tag(Optional(session.id))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.deleteSession(session.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsForm(store: store)
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { showSettings = false }
                        }
                    }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("DSH")
                .font(.title3.bold())
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)

            Button {
                store.newSession()
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .font(.title2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textTertiary)
            TextField("搜索会话", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
        .padding(8)
        .background(Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct SessionRow: View {
    let session: SessionUi

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(.body)
                    .lineLimit(1)
                if session.isRunning {
                    Image(systemName: "progress.indicator")
                        .font(.caption2)
                        .foregroundStyle(Theme.connecting)
                }
                Spacer()
                Text(timeAgo(from: session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            Text("\(session.messageCount) 条消息")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func timeAgo(from timestamp: Int64) -> String {
        let diff = Date().timeIntervalSince1970 - TimeInterval(timestamp) / 1000.0
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600)) 小时前" }
        return "\(Int(diff / 86400)) 天前"
    }
}
