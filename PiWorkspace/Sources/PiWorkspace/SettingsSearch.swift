import Foundation

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, model, browser, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .model: "Model Settings"
        case .browser: "Browser Settings"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .model: "cpu"
        case .browser: "globe"
        case .about: "info.circle"
        }
    }
}

enum SidebarPreference {
    static let groupByProject = "groupThreadsByProject"
}

enum SettingsAnchor: String {
    case groupByProject = "settings-group-by-project"
    case colorScheme = "appearance-color-scheme"
    case chatWidth = "appearance-chat-width"
    case restoreAppearance = "appearance-restore-defaults"
    case scope = "model-settings-scope"
    case provider = "provider"
    case modelID = "model-id"
    case endpoint = "endpoint"
    case contextWindow = "context-window"
    case localTools = "local-tools"
    case localImages = "local-images"
    case thinkingLevel = "thinking-level"
    case apiKey = "key-input"
    case removeKey = "remove-api-key"
    case resetModelOverride = "reset-model-override"
    case searchEngine = "browser-search-engine"
    case customSearchURL = "browser-custom-search-url"
    case licenses = "licenses-search"
}

struct SettingsRequest: Identifiable {
    let id = UUID()
    let page: SettingsPage
    let anchor: SettingsAnchor?
    let projectID: UUID?
}

enum SettingsFocus: Hashable {
    case search, heading
    case anchor(SettingsAnchor)
}

struct SettingsSearchResult: Identifiable {
    let page: SettingsPage
    var anchor: SettingsAnchor? = nil
    let title: String
    let keywords: String
    var id: String { anchor?.rawValue ?? page.rawValue }
}

struct SettingsSearchAvailability {
    var canEditModels: Bool
    var hasProjectScope: Bool
    var usesLocalProvider: Bool
    var hasSavedKey: Bool
    var canResetModelOverride: Bool
    var usesCustomSearch: Bool

    func includes(_ result: SettingsSearchResult) -> Bool {
        guard result.page != .model || canEditModels else { return false }
        return switch result.anchor {
        case .scope: hasProjectScope
        case .endpoint, .contextWindow, .localTools, .localImages: usesLocalProvider
        case .thinkingLevel: !usesLocalProvider
        case .removeKey: hasSavedKey
        case .resetModelOverride: canResetModelOverride
        case .customSearchURL: usesCustomSearch
        default: true
        }
    }
}

struct SettingsSearch {
    var query = "" { didSet { selectedIndex = 0 } }
    private var selectedIndex = 0

    var isSearching: Bool { query.contains { !$0.isWhitespace } }

    func selected(in results: [SettingsSearchResult]) -> SettingsSearchResult? {
        results.isEmpty ? nil : results[min(selectedIndex, results.count - 1)]
    }

    mutating func move(by offset: Int, in results: [SettingsSearchResult]) {
        guard !results.isEmpty else { return }
        selectedIndex = (min(selectedIndex, results.count - 1) + offset + results.count) % results.count
    }

    func results(available: SettingsSearchAvailability) -> [SettingsSearchResult] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        return Self.index.compactMap { result -> (rank: Int, result: SettingsSearchResult)? in
            guard available.includes(result) else { return nil }
            let title = Self.fold(result.title)
            if title == phrase { return (0, result) }
            if title.hasPrefix(phrase) { return (1, result) }
            if words.allSatisfy(title.contains) { return (2, result) }
            let fields = Self.fold("\(result.title) \(result.page.title) \(result.keywords)")
            return words.allSatisfy(fields.contains) ? (3, result) : nil
        }.sorted { $0.rank < $1.rank }.map(\.result)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static let index: [SettingsSearchResult] = [
        .init(page: .general, title: "General", keywords: "preferences sidebar threads"),
        .init(page: .general, anchor: .groupByProject, title: "Group by Project", keywords: "sidebar thread list grouping"),
        .init(page: .appearance, title: "Appearance", keywords: "visual display theme"),
        .init(page: .appearance, anchor: .colorScheme, title: "Color scheme", keywords: "theme light dark system"),
        .init(page: .appearance, anchor: .chatWidth, title: "Chat width", keywords: "conversation composer comfortable wide full"),
        .init(page: .appearance, anchor: .restoreAppearance, title: "Restore Defaults", keywords: "reset appearance color width"),
        .init(page: .model, title: "Model Settings", keywords: "providers Pi project workspace"),
        .init(page: .model, anchor: .scope, title: "Scope", keywords: "workspace project default inheritance override"),
        .init(page: .model, anchor: .provider, title: "Provider", keywords: "OpenAI Anthropic local OpenAI-compatible"),
        .init(page: .model, anchor: .modelID, title: "Model ID", keywords: "model name identifier"),
        .init(page: .model, anchor: .endpoint, title: "Base URL", keywords: "local provider endpoint address"),
        .init(page: .model, anchor: .contextWindow, title: "Context window", keywords: "local provider tokens limit"),
        .init(page: .model, anchor: .localTools, title: "Model supports coding tools", keywords: "local provider function calls"),
        .init(page: .model, anchor: .localImages, title: "Model supports image input", keywords: "local provider vision attachments"),
        .init(page: .model, anchor: .thinkingLevel, title: "Thinking level", keywords: "reasoning effort"),
        .init(page: .model, anchor: .apiKey, title: "API key", keywords: "provider credentials authentication keychain"),
        .init(page: .model, anchor: .removeKey, title: "Remove saved key", keywords: "delete API key credentials"),
        .init(page: .model, anchor: .resetModelOverride, title: "Reset to Workspace default", keywords: "project override restore inherited model"),
        .init(page: .browser, title: "Browser Settings", keywords: "web preview WKWebView browsing"),
        .init(page: .browser, anchor: .searchEngine, title: "Search engine", keywords: "browser address DuckDuckGo Google Bing Brave Kagi Ecosia Custom"),
        .init(page: .browser, anchor: .customSearchURL, title: "Custom search URL", keywords: "browser search template %s"),
        .init(page: .about, title: "About", keywords: "app name version build dependencies"),
        .init(page: .about, anchor: .licenses, title: "Open source licenses", keywords: "dependencies third-party notices SwiftTerm Node Pi"),
    ]
}
