import SwiftUI
import shared

struct InputBarView: View {
    @ObservedObject var store: AppStore
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.separator)
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)

                inputField

                Button {
                    store.sendMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(sendDisabled ? Theme.textTertiary : Theme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(sendDisabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.bg)
        }
    }

    private var inputField: some View {
        ZStack(alignment: .leading) {
            if store.state.inputText.isEmpty {
                Text("发送消息...")
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            TextEditor(text: Binding(
                get: { store.state.inputText },
                set: { store.updateInput($0) }
            ))
            .focused($isFocused)
            .scrollContentBackground(.hidden)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .frame(minHeight: 36, maxHeight: 160)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var sendDisabled: Bool {
        let t = store.state.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || store.state.isStreaming
    }
}
