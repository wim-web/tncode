import AppKit
import Combine

enum DiffPreferences {
    static let wordWrap = "wordWrap"
    static let ignoreWhitespace = "diffIgnoreWhitespace"
    static let defaultWordWrap = true
    static let defaultIgnoreWhitespace = true
}

enum AppColorScheme: String, CaseIterable {
    case system, light, dark

    @MainActor
    func apply(to application: NSApplication) {
        switch self {
        case .system: application.appearance = nil
        case .light: application.appearance = NSAppearance(named: .aqua)
        case .dark: application.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum ChatWidth: String, CaseIterable {
    case comfortable, wide, full
}

@MainActor
final class AppearanceSettings: ObservableObject {
    private let defaults: UserDefaults?
    private static let colorSchemeKey = "appearance.colorScheme"
    private static let chatWidthKey = "appearance.chatWidth"

    @Published var colorScheme: AppColorScheme {
        didSet { defaults?.set(colorScheme.rawValue, forKey: Self.colorSchemeKey) }
    }

    @Published var chatWidth: ChatWidth {
        didSet { defaults?.set(chatWidth.rawValue, forKey: Self.chatWidthKey) }
    }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        colorScheme = defaults?.string(forKey: Self.colorSchemeKey).flatMap(AppColorScheme.init(rawValue:)) ?? .system
        chatWidth = defaults?.string(forKey: Self.chatWidthKey).flatMap(ChatWidth.init(rawValue:)) ?? .comfortable
    }

    func restoreDefaults() {
        colorScheme = .system
        chatWidth = .comfortable
    }
}
