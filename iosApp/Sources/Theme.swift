import SwiftUI

enum Theme {
    static let accent = Color(red: 0.38, green: 0.72, blue: 0.98)
    static let accentSoft = Color(red: 0.22, green: 0.48, blue: 0.72)

    static let bg = Color(.systemBackground)
    static let bgSecondary = Color(.secondarySystemBackground)
    static let bgTertiary = Color(.tertiarySystemBackground)
    static let groupBg = Color(.systemGroupedBackground)

    static let card = Color(.secondarySystemBackground)

    static let textPrimary = Color(.label)
    static let textSecondary = Color(.secondaryLabel)
    static let textTertiary = Color(.tertiaryLabel)

    static let separator = Color(.separator)
    static let separatorOpaque = Color(.opaqueSeparator)

    static let userBubble = Color(red: 0.16, green: 0.36, blue: 0.56)
    static let assistantBubble = Color(.secondarySystemBackground)
    static let toolCard = Color(.tertiarySystemBackground)
    static let planCard = Color(red: 0.28, green: 0.22, blue: 0.12)
    static let todoCard = Color(red: 0.10, green: 0.22, blue: 0.14)

    static let connected = Color(red: 0.30, green: 0.78, blue: 0.46)
    static let connecting = Color.orange
    static let error = Color.red
}

extension Color {
    static let dshAccent = Theme.accent
    static let dshCard = Theme.card
    static let dshUser = Theme.userBubble
    static let dshAssistant = Theme.assistantBubble
}
