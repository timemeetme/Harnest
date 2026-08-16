import SwiftUI
import shared

@main
struct HarnessAppApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            GeometryReader { geo in
                let size = WindowSize(
                    widthDp: Float(geo.size.width),
                    heightDp: Float(geo.size.height)
                )
                ContentView(store: store, windowSize: size)
                    .tint(Theme.accent)
                    .task(id: size.widthDp) {
                        store.onWindowSizeChanged(size)
                    }
            }
            .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    let vm = AppViewModel()

    @Published private(set) var state: UiState = UiState()

    private var cancelObservation: (() -> Void)?

    init() {
        cancelObservation = vm.observeState { [weak self] newState in
            Task { @MainActor [weak self] in
                self?.state = newState
            }
        }
    }

    deinit {
        cancelObservation?()
    }

    func onWindowSizeChanged(_ size: WindowSize) {
        vm.onWindowSizeChanged(size: size)
    }

    func toggleSidebar() { vm.toggleSidebar() }
    func toggleDetails() { vm.toggleDetails() }
    func selectDetailsTab(_ tab: DetailsTab) { vm.selectDetailsTab(tab: tab) }
    func updateInput(_ text: String) { vm.updateInput(text: text) }
    func setGoal(_ text: String) { vm.setGoal(text: text) }
    func selectSession(_ id: String) { vm.selectSession(sessionId: id) }
    func newSession() { vm.newSession() }
    func deleteSession(_ id: String) { vm.deleteSession(sessionId: id) }
    func connectKernel(host: String, port: Int, useTls: Bool, provider: String, model: String, cwd: String) {
        vm.connectKernel(host: host, port: Int32(port), useTls: useTls, provider: provider, model: model, cwd: cwd)
    }
    func disconnectKernel() { vm.disconnectKernel() }
    func sendMessage() { vm.sendMessage(content: state.inputText) }
    func addTodo(_ content: String) { vm.addTodo(content: content) }
    func toggleTodo(_ id: String) { vm.toggleTodo(id: id) }
    func deleteTodo(_ id: String) { vm.deleteTodo(id: id) }
}
