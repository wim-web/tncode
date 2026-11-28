import Foundation

enum ComposerSendShortcut: String, CaseIterable {
    case enter
    case commandForMultiline = "mod-enter-multiline"
    case commandAlways = "mod-enter"

    static let key = "chat.sendShortcut"
    static let initial: Self = .enter

    var title: String {
        switch self {
        case .enter: String(localized: "Enter")
        case .commandForMultiline: String(localized: "⌘ + Enter for multiline prompts")
        case .commandAlways: String(localized: "⌘ + Enter always")
        }
    }

    var alternateShortcutDescription: String {
        switch self {
        case .enter: String(localized: "⌘ + Enter")
        case .commandForMultiline: String(localized: "⌘ + Enter for one line or ⌘ + Shift + Enter for multiple lines")
        case .commandAlways: String(localized: "⌘ + Shift + Enter")
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
        case .queue: String(localized: "Queue")
        case .steer: String(localized: "Steer")
        }
    }

    var alternate: Self { self == .steer ? .queue : .steer }
}
