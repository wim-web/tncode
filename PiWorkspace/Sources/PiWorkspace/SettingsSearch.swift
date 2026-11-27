import Combine
import Foundation

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, threads, appearance, chat, project, model, sourceControl = "source-control"
    case diffs, worktrees, usage, browser, archived, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .threads: "Threads"
        case .appearance: "Appearance"
        case .chat: "Chat"
        case .project: "Project Overview"
        case .model: "Model Settings"
        case .sourceControl: "Source Control"
        case .diffs: "Diffs & pull requests"
        case .worktrees: "Worktrees"
        case .usage: "Usage"
        case .browser: "Browser Settings"
        case .archived: "Archive"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .threads: "bubble.left.and.bubble.right"
        case .appearance: "paintbrush"
        case .chat: "bubble.left"
        case .project: "folder"
        case .model: "cpu"
        case .sourceControl: "arrow.triangle.branch"
        case .diffs: "doc.text"
        case .worktrees: "arrow.triangle.branch"
        case .usage: "chart.bar"
        case .browser: "globe"
        case .archived: "archivebox"
        case .about: "info.circle"
        }
    }
}

enum SidebarPreference {
    static let groupByProject = "groupThreadsByProject"
}

enum SettingsAnchor: String {
    case groupByProject = "settings-group-by-project"
    case archiveConfirmation = "archive-confirmation"
    case terminalCloseConfirmation = "terminal-close-confirmation"
    case archive
    case snoozeOptions = "snooze-options"
    case addProjectStartsIn = "add-project-starts-in"
    case worktreeLocation = "storage-worktrees-location"
    case startFromRemote = "start-from-origin"
    case colorScheme = "appearance-color-scheme"
    case chatWidth = "appearance-chat-width"
    case restoreAppearance = "appearance-restore-defaults"
    case wordWrap = "word-wrap"
    case hideWhitespaceChanges = "hide-whitespace-changes"
    case sendShortcut = "send-shortcut"
    case followUpBehavior = "follow-up-behavior"
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
    case commitWritingStyle = "commit-writing-style"
    case commitWriterModel = "source-control-writer-model"
    case searchEngine = "browser-search-engine"
    case customSearchURL = "browser-custom-search-url"
    case appVersion = "app-version"
    case licenses = "licenses-search"
    case welcomePage = "welcome-page"
}

enum SettingsDeepLink: Equatable {
    case page(SettingsPage)
    case archiveConfirmation
    case terminalCloseConfirmation
    case wordWrap
    case hideWhitespaceChanges
    case archivedThreads
    case licenses
    case version
    case project(UUID)

    private static let pages: [String: SettingsPage] = [
        "": .general, "/": .general, "/general": .general, "/threads": .threads,
        "/appearance": .appearance, "/chat": .chat, "/model": .model, "/source-control": .sourceControl,
        "/diffs": .diffs, "/worktrees": .worktrees, "/usage": .usage, "/browser": .browser,
        "/archived": .archived, "/about": .about
    ]

    static func handles(_ url: URL) -> Bool {
        url.scheme?.lowercased() == ThreadLink.scheme &&
            ["settings", "usage", "projects"].contains(url.host?.lowercased())
    }

    init?(url: URL) {
        guard Self.handles(url), let host = url.host?.lowercased() else { return nil }
        let authority = "\(ThreadLink.scheme)://\(host)"
        let text = url.absoluteString
        guard text.prefix(authority.count).lowercased() == authority else { return nil }
        let route = text.dropFirst(authority.count)
        switch (host, route) {
        case ("usage", ""), ("usage", "/"):
            self = .page(.usage)
        case ("settings", "/open-source-licenses"):
            self = .licenses
        case ("settings", "/about#app-version"):
            self = .version
        case ("settings", "/general#archive-confirmation"):
            self = .archiveConfirmation
        case ("settings", "/general#terminal-close-confirmation"):
            self = .terminalCloseConfirmation
        case ("settings", "/appearance#word-wrap"):
            self = .wordWrap
        case ("settings", "/diffs#hide-whitespace-changes"):
            self = .hideWhitespaceChanges
        case ("settings", "/archived#archive"):
            self = .archivedThreads
        case ("settings", _):
            if let page = Self.pages[String(route)] {
                self = .page(page)
            } else {
                let prefix = "/projects?project="
                guard route.hasPrefix(prefix),
                      let id = UUID(uuidString: String(route.dropFirst(prefix.count))) else { return nil }
                self = .project(id)
            }
        case ("projects", _):
            guard route.first == "/", let id = UUID(uuidString: String(route.dropFirst())) else { return nil }
            self = .project(id)
        default:
            return nil
        }
    }

    var page: SettingsPage {
        switch self {
        case .page(let page): page
        case .archiveConfirmation, .terminalCloseConfirmation: .general
        case .wordWrap: .appearance
        case .hideWhitespaceChanges: .diffs
        case .archivedThreads: .archived
        case .licenses, .version: .about
        case .project: .project
        }
    }

    var anchor: SettingsAnchor? {
        switch self {
        case .licenses: .licenses
        case .version: .appVersion
        case .archiveConfirmation: .archiveConfirmation
        case .terminalCloseConfirmation: .terminalCloseConfirmation
        case .wordWrap: .wordWrap
        case .hideWhitespaceChanges: .hideWhitespaceChanges
        case .archivedThreads: .archive
        default: nil
        }
    }
}

@MainActor
final class SettingsRequest: ObservableObject, Identifiable {
    struct Destination: Equatable {
        let navigationID: UUID?
        let page: SettingsPage
        let anchor: SettingsAnchor?
        let projectID: UUID?
    }

    let id = UUID()
    @Published private(set) var destination: Destination

    var page: SettingsPage { destination.page }
    var projectID: UUID? { destination.projectID }

    init(page: SettingsPage, anchor: SettingsAnchor?, projectID: UUID?, focusDestination: Bool = false) {
        destination = Destination(navigationID: focusDestination ? UUID() : nil,
                                  page: page, anchor: anchor, projectID: projectID)
    }

    func navigate(to page: SettingsPage, anchor: SettingsAnchor?, projectID: UUID?) {
        destination = Destination(navigationID: UUID(), page: page, anchor: anchor, projectID: projectID ?? destination.projectID)
    }
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
        guard result.page != .project || hasProjectScope else { return false }
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

extension SettingsSearchAvailability {
    @MainActor
    init(model: WorkspaceModel, project: Project?, draft: ModelSettingsDraft, browser: BrowserSearchSettings) {
        let hasOverride = project.map { draft.scope == .project($0.id) && $0.modelOverride != nil } ?? false
        self.init(canEditModels: model.canOpenModelSettings, hasProjectScope: project != nil,
                  usesLocalProvider: draft.settings.provider == .local,
                  hasSavedKey: model.canOpenModelSettings && model.hasKey(for: draft.settings),
                  canResetModelOverride: hasOverride, usesCustomSearch: browser.engine == .custom)
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
        return Self.availableResults(available).compactMap { result -> (rank: Int, result: SettingsSearchResult)? in
            let title = Self.fold(result.title)
            if title == phrase { return (0, result) }
            if title.hasPrefix(phrase) { return (1, result) }
            if words.allSatisfy(title.contains) { return (2, result) }
            let fields = Self.fold("\(result.title) \(result.page.title) \(result.keywords)")
            return words.allSatisfy(fields.contains) ? (3, result) : nil
        }.sorted { $0.rank < $1.rank }.map(\.result)
    }

    static func availableResults(_ availability: SettingsSearchAvailability) -> [SettingsSearchResult] {
        index.filter(availability.includes)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static let index: [SettingsSearchResult] = [
        .init(page: .general, title: "General", keywords: "preferences sidebar threads"),
        .init(page: .general, anchor: .groupByProject, title: "Group by Project", keywords: "sidebar thread list grouping"),
        .init(page: .general, anchor: .archiveConfirmation, title: "Archive confirmation", keywords: "ask before thread confirm archiving"),
        .init(page: .general, anchor: .terminalCloseConfirmation, title: "Terminal close confirmation",
              keywords: "ask before delete stop process shell console history"),
        .init(page: .general, anchor: .addProjectStartsIn, title: "Add project starts in", keywords: "base directory folder browser path home"),
        .init(page: .threads, title: "Threads", keywords: "conversation preferences"),
        .init(page: .threads, anchor: .snoozeOptions, title: "Snooze options", keywords: "presets wake duration time weekday reset add remove"),
        .init(page: .appearance, title: "Appearance", keywords: "visual display theme"),
        .init(page: .appearance, anchor: .colorScheme, title: "Color scheme", keywords: "theme light dark system"),
        .init(page: .appearance, anchor: .chatWidth, title: "Chat width", keywords: "conversation composer comfortable wide full"),
        .init(page: .appearance, anchor: .wordWrap, title: "Word wrap", keywords: "long lines code diffs file previews"),
        .init(page: .appearance, anchor: .restoreAppearance, title: "Restore Defaults", keywords: "reset appearance color width wrap"),
        .init(page: .chat, title: "Chat", keywords: "conversation composer follow-ups"),
        .init(page: .chat, anchor: .sendShortcut, title: "Send shortcut", keywords: "enter return command ctrl multiline prompt new line composer"),
        .init(page: .chat, anchor: .followUpBehavior, title: "Follow-up behavior", keywords: "queue steer running turn send default behavior composer"),
        .init(page: .project, title: "Project Overview", keywords: "project settings name folder path checkouts pin"),
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
        .init(page: .sourceControl, title: "Source Control", keywords: "git commits"),
        .init(page: .sourceControl, anchor: .commitWritingStyle, title: "Commit writing style", keywords: "git repository conventional commits custom instructions"),
        .init(page: .sourceControl, anchor: .commitWriterModel, title: "Source control writer model", keywords: "git commit model provider inheritance override"),
        .init(page: .diffs, title: "Diffs & pull requests", keywords: "git changes"),
        .init(page: .diffs, anchor: .hideWhitespaceChanges, title: "Hide whitespace changes",
              keywords: "ignore white space only edits diff compare"),
        .init(page: .worktrees, title: "Worktrees", keywords: "checkout storage"),
        .init(page: .worktrees, anchor: .worktreeLocation, title: "Worktree location", keywords: "folder directory path drive external disk"),
        .init(page: .worktrees, anchor: .startFromRemote, title: "Start from remote", keywords: "new worktrees default origin upstream branch fetch"),
        .init(page: .usage, title: "Usage", keywords: "Pi assistant tokens cost providers billing limits"),
        .init(page: .browser, title: "Browser Settings", keywords: "web preview WKWebView browsing"),
        .init(page: .browser, anchor: .searchEngine, title: "Search engine", keywords: "browser address DuckDuckGo Google Bing Brave Kagi Ecosia Custom"),
        .init(page: .browser, anchor: .customSearchURL, title: "Custom search URL", keywords: "browser search template %s"),
        .init(page: .archived, title: "Archive", keywords: ""),
        .init(page: .archived, anchor: .archive, title: "Archived threads", keywords: "unarchive restore reopen history projects checkouts"),
        .init(page: .about, title: "About", keywords: "app name version build dependencies"),
        .init(page: .about, anchor: .appVersion, title: "Version", keywords: "app version build release"),
        .init(page: .about, anchor: .licenses, title: "Open source licenses", keywords: "dependencies third-party notices SwiftTerm Node Pi"),
        .init(page: .about, anchor: .welcomePage, title: "Welcome page", keywords: "onboarding setup first run getting started agents import projects"),
    ]
}
