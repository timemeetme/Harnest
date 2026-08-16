import SwiftUI
import shared

struct GoalBarView: View {
    @ObservedObject var store: AppStore
    @State private var editing = false
    @State private var draft: String = ""

    var body: some View {
        Group {
            if store.state.goal.active || !store.state.goal.text.isEmpty {
                Button {
                    draft = store.state.goal.text
                    editing = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "target")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                        Text(store.state.goal.text.isEmpty ? "设置目标" : store.state.goal.text)
                            .font(.footnote)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.bgSecondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .popover(isPresented: $editing) {
            NavigationStack {
                VStack(spacing: 12) {
                    TextField("目标", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 16)
                    Text("描述这次会话希望达成的目标")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                    Spacer()
                }
                .padding(.top, 20)
                .navigationTitle("设置目标")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { editing = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清除") {
                            store.setGoal("")
                            editing = false
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            store.setGoal(draft)
                            editing = false
                        }
                        .bold()
                    }
                }
            }
            .frame(width: 320, height: 200)
        }
    }
}
