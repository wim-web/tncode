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

    /// Settings → Chat → Follow-up behavior, by send shortcut (T3 Code's wording).
    var followUpDescription: String {
        switch self {
        case .enter:
            String(localized: "Queue follow-ups while the agent runs or steer the current run. Press ⌘ + Enter to do the opposite for one message.")
        case .commandForMultiline:
            String(localized: "Queue follow-ups while the agent runs or steer the current run. Press ⌘ + Enter for single-line prompts or ⌘ + Shift + Enter for multiline prompts to do the opposite for one message.")
        case .commandAlways:
            String(localized: "Queue follow-ups while the agent runs or steer the current run. Press ⌘ + Shift + Enter to do the opposite for one message.")
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
