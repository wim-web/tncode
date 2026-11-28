import Combine
import Foundation

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, threads, appearance, chat, project, model, sourceControl = "source-control"
    case diffs, worktrees, usage, browser, labs, archived, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .threads: String(localized: "Threads")
        case .appearance: String(localized: "Appearance")
        case .chat: String(localized: "Chat")
        case .project: String(localized: "Projects")
        case .model: String(localized: "Providers")
        case .sourceControl: String(localized: "Source control & issues")
        case .diffs: String(localized: "Diffs & pull requests")
        case .worktrees: String(localized: "Worktrees")
        case .usage: String(localized: "Usage")
        case .browser: String(localized: "Browser")
        case .labs: String(localized: "Labs")
        case .archived: String(localized: "Archive")
        case .about: String(localized: "About")
        }
    }

    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .threads: "bubble.left.and.bubble.right"
        case .appearance: "paintpalette"
        case .chat: "text.bubble"
        case .project: "macwindow"
        case .model: "cpu"
        case .sourceControl: "arrow.triangle.branch"
        case .diffs: "plus.forwardslash.minus"
        case .worktrees: "folder"
        case .usage: "chart.bar"
        case .browser: "globe"
        case .labs: "flask"
        case .archived: "archivebox"
        case .about: "info.circle"
        }
    }

    /// Pages that open with "Applying settings for [project] on [machine]".
    var showsScopeSentence: Bool { [.threads, .project, .archived].contains(self) }

    /// Earlier page names, still matched by settings search.
    var searchAliases: String {
        switch self {
        case .project: "Project Overview"
        case .model: "Model Settings"
        case .sourceControl: "Source Control"
        case .browser: "Browser Settings"
        default: ""
        }
    }

    /// Navigation groups in T3 Code's order. Untitled groups are separated by space only.
    static let navigationGroups: [(title: String?, pages: [SettingsPage])] = [
        (nil, [.general, .appearance, .chat, .diffs]),
        ("Agents", [.model, .threads, .browser]),
        ("Code", [.project, .sourceControl, .worktrees]),
        (nil, [.labs, .about, .archived])
    ]
}

enum SidebarPreference {
    static let groupByProject = "groupThreadsByProject"
}

enum SettingsAnchor: String {
    case groupByProject = "boring-sidebar"
    case language
    case defaultModel = "default-model"
    case defaultPermissions = "default-permissions"
    case theme
    case archiveConfirmation = "archive-confirmation"
    case terminalCloseConfirmation = "terminal-close-confirmation"
    case archive
    case snoozeOptions = "snooze-options"
    case addProjectStartsIn = "add-project-starts-in"
    case worktreeLocation = "storage-worktrees-location"
    case startFromRemote = "start-from-origin"
    case colorScheme = "appearance-color-scheme"
    case chatWidth = "appearance-chat-width"
    case wordWrap = "word-wrap"
    case hideWhitespaceChanges = "hide-whitespace-changes"
    case sendShortcut = "send-shortcut"
    case followUpBehavior = "follow-up-behavior"
    case accountSignIn = "provider-account-sign-in"
    case endpoint = "endpoint"
    case contextWindow = "context-window"
    case localTools = "local-tools"
    case localImages = "local-images"
    case apiKey = "key-input"
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
        "/archived": .archived, "/labs": .labs, "/about": .about
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
    /// Incremented when the user clicks outside the modal; Settings validates fields before closing.
    @Published private(set) var closeRequests = 0

    func requestClose() { closeRequests += 1 }

    var page: SettingsPage { destination.page }
    var projectID: UUID? { destination.projectID }

    init(page: SettingsPage, anchor: SettingsAnchor?, projectID: UUID?, focusDestination: Bool = false) {
        destination = Destination(navigationID: focusDestination ? UUID() : nil,
                                  page: page, anchor: anchor, projectID: projectID)
    }

    func navigate(to page: SettingsPage, anchor: SettingsAnchor?, projectID: UUID?) {
        destination = Destination(navigationID: UUID(), page: page, anchor: anchor, projectID: projectID ?? destination.projectID)
    }

    /// The scope sentence's project menu: a project, or nil for All projects.
    func selectProject(_ projectID: UUID?) {
        guard projectID != destination.projectID else { return }
        destination = Destination(navigationID: destination.navigationID, page: destination.page, anchor: nil,
                                  projectID: projectID)
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
    var hasProjectScope: Bool
    var usesCustomSearch: Bool

    func includes(_ result: SettingsSearchResult) -> Bool {
        return switch result.anchor {
        case .customSearchURL: usesCustomSearch
        default: true
        }
    }
}

extension SettingsSearchAvailability {
    @MainActor
    init(model: WorkspaceModel, project: Project?, browser: BrowserSearchSettings) {
        self.init(hasProjectScope: project != nil, usesCustomSearch: browser.engine == .custom)
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
            // Match the title as shown (localized) and in English, so either language finds it.
            let shownTitle = NSLocalizedString(result.title, comment: "")
            let titles = Set([Self.fold(shownTitle), Self.fold(result.title)])
            if titles.contains(phrase) { return (0, result) }
            if titles.contains(where: { $0.hasPrefix(phrase) }) { return (1, result) }
            if titles.contains(where: { title in words.allSatisfy(title.contains) }) { return (2, result) }
            let fields = Self.fold("\(shownTitle) \(result.title) \(result.page.title) \(result.page.searchAliases) \(result.keywords)")
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
        .init(page: .general, title: "General", keywords: "preferences confirmations display"),
        .init(page: .general, anchor: .archiveConfirmation, title: "Archive confirmation",
              keywords: "ask before thread second click inline action"),
        .init(page: .general, anchor: .terminalCloseConfirmation, title: "Terminal close confirmation",
              keywords: "ask before delete stop process shell console history"),
        .init(page: .general, anchor: .language, title: "Language",
              keywords: "locale translation english japanese 日本語 system default"),
        .init(page: .appearance, title: "Appearance", keywords: "theme colors interface typography"),
        .init(page: .appearance, anchor: .colorScheme, title: "Color scheme", keywords: "appearance light dark system mode"),
        .init(page: .appearance, anchor: .theme, title: "Themes", keywords: "appearance colors palette custom import"),
        .init(page: .appearance, anchor: .chatWidth, title: "Chat width",
              keywords: "wide full width column layout messages composer monitor"),
        .init(page: .appearance, anchor: .wordWrap, title: "Word wrap", keywords: "long lines code blocks diffs file previews"),
        .init(page: .chat, title: "Chat", keywords: "composer follow-ups"),
        .init(page: .chat, anchor: .sendShortcut, title: "Send shortcut",
              keywords: "enter return command ctrl multiline prompt new line composer"),
        .init(page: .chat, anchor: .followUpBehavior, title: "Follow-up behavior",
              keywords: "queue steer running turn send default behavior composer"),
        .init(page: .diffs, title: "Diffs & pull requests", keywords: "git changes"),
        .init(page: .diffs, anchor: .hideWhitespaceChanges, title: "Hide whitespace changes",
              keywords: "diff ignore spaces edits default"),
        .init(page: .model, title: "Providers",
              keywords: "provider codex pi claude chatgpt copilot openai anthropic local endpoint models favorites"),
        .init(page: .model, anchor: .apiKey, title: "API key", keywords: "provider credentials authentication keychain"),
        .init(page: .threads, title: "Threads", keywords: "new projects new threads snooze"),
        .init(page: .threads, anchor: .addProjectStartsIn, title: "Add project starts in",
              keywords: "base directory folder browser path home"),
        .init(page: .threads, anchor: .defaultModel, title: "Default model",
              keywords: "new thread project provider reasoning effort"),
        .init(page: .threads, anchor: .defaultPermissions, title: "Permissions",
              keywords: "new thread default runtime mode supervised approvals read files shell edits full access"),
        .init(page: .threads, anchor: .snoozeOptions, title: "Snooze options",
              keywords: "snooze presets times later tonight tomorrow next week remind"),
        .init(page: .browser, title: "Browser", keywords: "web preview browsing"),
        .init(page: .browser, anchor: .searchEngine, title: "Search engine",
              keywords: "address bar duckduckgo google bing brave kagi ecosia custom url"),
        .init(page: .browser, anchor: .customSearchURL, title: "Custom search URL", keywords: "browser search template %s"),
        .init(page: .project, title: "Project overview", keywords: "name icon emoji image checkout remove delete"),
        .init(page: .sourceControl, title: "Source control & issues", keywords: "git commits pull requests"),
        .init(page: .sourceControl, anchor: .commitWritingStyle, title: "Commit and pull request writing",
              keywords: "commit messages pull request titles descriptions conventions conventional custom instructions"),
        .init(page: .sourceControl, anchor: .commitWriterModel, title: "Source control writer model",
              keywords: "commit messages pull request text branch names model"),
        .init(page: .worktrees, title: "Worktrees", keywords: "checkout creation"),
        .init(page: .worktrees, anchor: .worktreeLocation, title: "Worktree location",
              keywords: "worktree location folder directory path drive external disk"),
        .init(page: .worktrees, anchor: .startFromRemote, title: "Start from remote",
              keywords: "new worktrees default origin upstream branch fetch"),
        .init(page: .labs, title: "Labs", keywords: "beta"),
        .init(page: .labs, anchor: .groupByProject, title: "Boring sidebar (group by project)",
              keywords: "beta folders project tree classic sidebar"),
        .init(page: .archived, title: "Archive", keywords: ""),
        .init(page: .archived, anchor: .archive, title: "Archived threads", keywords: "restore reopen deleted history projects"),
        .init(page: .about, title: "About", keywords: "app version"),
        .init(page: .about, anchor: .appVersion, title: "Version", keywords: "app version build release"),
        .init(page: .about, anchor: .welcomePage, title: "Welcome page",
              keywords: "onboarding setup first run getting started agents import projects"),
        .init(page: .about, anchor: .licenses, title: "Open source licenses",
              keywords: "dependencies third-party notices assets"),
    ]
}
