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
    private static let lightThemeKey = "appearance.lightTheme"
    private static let darkThemeKey = "appearance.darkTheme"

    @Published var colorScheme: AppColorScheme {
        didSet { defaults?.set(colorScheme.rawValue, forKey: Self.colorSchemeKey) }
    }

    @Published var chatWidth: ChatWidth {
        didSet { defaults?.set(chatWidth.rawValue, forKey: Self.chatWidthKey) }
    }

    /// Theme used while the app is light; chosen separately from the dark theme, as in T3 Code.
    @Published var lightTheme: T3ThemeID {
        didSet { defaults?.set(lightTheme.rawValue, forKey: Self.lightThemeKey) }
    }

    @Published var darkTheme: T3ThemeID {
        didSet { defaults?.set(darkTheme.rawValue, forKey: Self.darkThemeKey) }
    }

    var themes: T3ThemeChoice { T3ThemeChoice(light: lightTheme, dark: darkTheme) }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        colorScheme = defaults?.string(forKey: Self.colorSchemeKey).flatMap(AppColorScheme.init(rawValue:)) ?? .system
        chatWidth = defaults?.string(forKey: Self.chatWidthKey).flatMap(ChatWidth.init(rawValue:)) ?? .comfortable
        lightTheme = defaults?.string(forKey: Self.lightThemeKey).flatMap(T3ThemeID.init(rawValue:)) ?? .t3Code
        darkTheme = defaults?.string(forKey: Self.darkThemeKey).flatMap(T3ThemeID.init(rawValue:)) ?? .t3Code
    }

    func restoreDefaults() {
        colorScheme = .system
        chatWidth = .comfortable
        lightTheme = .t3Code
        darkTheme = .t3Code
    }
}

/// Interface language, applied through the app's AppleLanguages preference on the next launch.
enum AppLanguage: String, CaseIterable {
    case system, english = "en", japanese = "ja"

    static let key = "tncodeLanguage"

    /// Language names stay in their own language, as in T3 Code's language picker.
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    static var selected: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// The localization this process is showing.
    static var running: String { Bundle.main.preferredLocalizations.first ?? "en" }

    func select() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.key)
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Whether the running process shows this choice already.
    var isRunning: Bool {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? $0 }
            return preferred.map { $0 == Self.running || (!["en", "ja"].contains($0) && Self.running == "en") } ?? true
        case .english, .japanese: return rawValue == Self.running
        }
    }

    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
