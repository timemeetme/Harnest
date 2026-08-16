import SwiftUI
import shared

struct MainScaffold: View {
    @ObservedObject var store: AppStore
    let windowSize: WindowSize

    var body: some View {
        let wc = windowSize.widthClass
        switch wc {
        case .expanded:
            ExpandedLayout(store: store)
        case .medium:
            MediumLayout(store: store)
        case .compact:
            CompactLayout(store: store)
        }
    }
}

struct ExpandedLayout: View {
    @ObservedObject var store: AppStore
    @State private var selectedSessionId: String? = nil
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store, selectedId: $selectedSessionId)
        } content: {
            ChatView(store: store)
        } detail: {
            DetailsPanelView(store: store)
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
        .navigationSplitViewColumnWidth(min: 360, ideal: 480, max: 600, for: .content)
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 420, for: .detail)
        .onAppear {
            selectedSessionId = store.state.activeSessionId
        }
        .onChange(of: store.state.activeSessionId) { newValue in
            selectedSessionId = newValue
        }
    }
}

struct MediumLayout: View {
    @ObservedObject var store: AppStore
    @State private var selectedSessionId: String? = nil
    @State private var showDetails = false

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, selectedId: $selectedSessionId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            ChatView(store: store)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            store.toggleDetails()
                            showDetails.toggle()
                        } label: {
                            Label("详情", systemImage: "sidebar.right")
                        }
                    }
                }
                .sheet(isPresented: $showDetails) {
                    NavigationStack {
                        DetailsPanelView(store: store)
                            .navigationTitle("详情")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("关闭") {
                                        showDetails = false
                                    }
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
        }
        .onAppear {
            selectedSessionId = store.state.activeSessionId
        }
        .onChange(of: store.state.activeSessionId) { newValue in
            selectedSessionId = newValue
        }
    }
}

struct CompactLayout: View {
    @ObservedObject var store: AppStore
    @State private var showSidebar = false
    @State private var showDetails = false

    var body: some View {
        NavigationStack {
            ChatView(store: store)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showSidebar = true } label: {
                            Image(systemName: "sidebar.left")
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        GoalBarView(store: store)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.toggleDetails()
                            showDetails.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                    }
                }
                .sheet(isPresented: $showSidebar) {
                    SidebarView(store: store, selectedId: .init(
                        get: { store.state.activeSessionId },
                        set: { newId in
                            if let id = newId {
                                store.selectSession(id)
                            }
                            showSidebar = false
                        }
                    ))
                }
                .sheet(isPresented: $showDetails) {
                    NavigationStack {
                        DetailsPanelView(store: store)
                            .navigationTitle("详情")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("关闭") { showDetails = false }
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
        }
    }
}
