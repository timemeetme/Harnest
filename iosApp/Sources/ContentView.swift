import SwiftUI
import shared

struct ContentView: View {
    @ObservedObject var store: AppStore
    let windowSize: WindowSize

    var body: some View {
        let connection = store.state.connection
        if connection.status != .connected {
            ConnectionView(store: store)
        } else {
            MainScaffold(store: store, windowSize: windowSize)
        }
    }
}
