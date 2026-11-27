import Foundation

enum ComposerSendShortcut: String, CaseIterable {
    case enter
    case commandForMultiline = "mod-enter-multiline"
    case commandAlways = "mod-enter"

    static let key = "chat.sendShortcut"
    static let initial: Self = .enter

    var title: String {
        switch self {
        case .enter: "Enter"
        case .commandForMultiline: "⌘ + Enter for multiline prompts"
        case .commandAlways: "⌘ + Enter always"
        }
    }

    var alternateShortcutDescription: String {
        switch self {
        case .enter: "⌘ + Enter"
        case .commandForMultiline: "⌘ + Enter for one line or ⌘ + Shift + Enter for multiple lines"
        case .commandAlways: "⌘ + Shift + Enter"
        }
    }

    func requiresModifier(for text: String) -> Bool {
        self == .commandAlways || (self == .commandForMultiline && text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" })
    }
}

enum ComposerFollowUp: String, CaseIterable {
    case queue, steer

    static let key = "chat.followUpBehavior"
    static let initial: Self = .steer

    var title: String {
        switch self {
        case .queue: "Queue"
        case .steer: "Steer"
        }
    }

    var alternate: Self { self == .steer ? .queue : .steer }
}
