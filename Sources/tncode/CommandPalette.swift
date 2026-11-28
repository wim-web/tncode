import AppKit
import Carbon

enum CommandPaletteAction: Hashable {
    case chooseProject
    case newThread(UUID)
    case newScratchThread
    case addProject
    case home
    case settings
    case projectSettings(UUID)
    case openSetting(SettingsPage, anchor: SettingsAnchor?, projectID: UUID?)
    case searchThreads
    case findInCurrentThread(SidebarMessageSearch.Thread)
    case findInBrowser(UUID)
    case searchWorkspace(WorkspaceFileSearch.Mode)
    case openWorkspaceFile(WorkspaceFileSearch.Destination)
    case openProject(UUID)
    case openThread(UUID, project: UUID)
    case openMessage(UUID, project: UUID, occurrence: TranscriptOccurrence, term: TranscriptSearchTerm)

    var identifier: String {
        switch self {
        case .chooseProject: "new-thread-in"
        case .newThread(let id): "new-thread-project-\(id)"
        case .newScratchThread: "no-project"
        case .addProject: "add-project"
        case .home: "home"
        case .settings: "settings"
        case .projectSettings(let id): "project-settings-\(id)"
        case .openSetting(let page, let anchor, _): "setting-\(anchor?.rawValue ?? page.rawValue)"
        case .searchThreads: "search-threads"
        case .findInCurrentThread: "find-current-thread"
        case .findInBrowser: "find-in-browser-page"
        case .searchWorkspace(.files): "go-to-file"
        case .searchWorkspace(.contents): "search-project-contents"
        case .openWorkspaceFile(let destination):
            destination.line.map { "content-result-\(destination.target.path):\($0)" }
                ?? "file-result-\(destination.target.path)"
        case .openProject(let id): "project-\(id)"
        case .openThread(let id, _): "thread-\(id)"
        case .openMessage(let id, _, let match, _): "message-\(id)-\(match.messageID)"
        }
    }
}

struct CommandPaletteRow: Identifiable {
    let action: CommandPaletteAction
    let title: String
    let icon: String
    var detail: String? = nil
    var searchTerms: String = ""
    var id: CommandPaletteAction { action }

    private func rank(for words: [String], exact: Bool) -> Int? {
        // Rows show their title localized; match it as shown and in English.
        let shownTitle = NSLocalizedString(title, comment: "")
        let labels = Set([Self.fold(shownTitle), Self.fold(title)])
        let phrase = words.joined(separator: " ")
        if labels.contains(phrase) { return 0 }
        if labels.contains(where: { $0.hasPrefix(phrase) }) { return 1 }
        if labels.contains(where: { label in exact ? label.contains(phrase) : words.allSatisfy(label.contains) }) { return 2 }
        let searchable = Self.fold([shownTitle, title, detail, searchTerms].compactMap { $0 }.joined(separator: " "))
        return (exact ? searchable.contains(phrase) : words.allSatisfy(searchable.contains)) ? 3 : nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func matching(_ query: String, in rows: [Self]) -> [Self] {
        let phrase = TranscriptSearchTerm.quotedPhrase(in: query)
        let words = fold(phrase ?? query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.compactMap { row in row.rank(for: words, exact: phrase != nil).map { ($0, row) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}

struct CommandPaletteGroup: Identifiable {
    enum Kind: String {
        case actions = "Actions"
        case projects = "Projects"
        case recentThreads = "Recent Threads"
        case threads = "Threads"
        case settings = "Settings"
        case messages = "In messages"
        case files = "Files"
        case contents = "Matches"
    }

    let id: Kind
    var rows: [CommandPaletteRow]
}

struct CommandPaletteContents {
    let projects: [Project]
    let availableProjects: [Project]
    let preferredProject: UUID?
    let threads: [SidebarThread]
    let activeThread: UUID?
    let canStartScratchThread: Bool
    var findThread: SidebarMessageSearch.Thread? = nil
    var findBrowserTab: UUID? = nil
    var settingsProject: Project? = nil
    var defaultProject: UUID? = nil
    var settings: [SettingsSearchResult] = []

    var localThreadProject: Project? {
        availableProjects.first { $0.id == preferredProject }
            ?? availableProjects.first { $0.id == defaultProject }
            ?? availableProjects.first
    }

    var commands: [CommandPaletteRow] {
        var rows: [CommandPaletteRow] = []
        if let project = localThreadProject {
            rows.append(.init(action: .newThread(project.id), title: String(localized: "New thread in \(project.title)"),
                              icon: "square.and.pencil", searchTerms: "chat create draft"))
            rows.append(.init(action: .chooseProject, title: "New thread in...", icon: "square.and.pencil",
                              searchTerms: "new thread project pick choose select"))
        }
        if canStartScratchThread {
            rows.append(.init(action: .newScratchThread, title: "New thread without a project",
                              icon: "bubble.left", searchTerms: "no project scratch chat"))
        }
        rows.append(.init(action: .addProject, title: "Add project", icon: "folder.badge.plus",
                          searchTerms: "open local folder directory repository new project"))
        rows.append(.init(action: .searchThreads, title: "Search threads", icon: "magnifyingglass",
                          searchTerms: "find messages"))
        if let findThread {
            rows.append(.init(action: .findInCurrentThread(findThread), title: "Find in current thread",
                              icon: "text.magnifyingglass", searchTerms: "search messages"))
        }
        if let findBrowserTab {
            rows.append(.init(action: .findInBrowser(findBrowserTab), title: "Find on page in browser",
                              icon: "text.magnifyingglass", searchTerms: "find search browser preview page"))
        }
        rows.append(.init(action: .searchWorkspace(.files), title: "Go to file", icon: "doc.text.magnifyingglass",
                          searchTerms: "open file file picker find file quick open"))
        rows.append(.init(action: .searchWorkspace(.contents), title: "Search project contents",
                          icon: "text.magnifyingglass", searchTerms: "find in files grep content search text search"))
        if preferredProject != nil {
            rows.append(.init(action: .home, title: "Go to home", icon: "house"))
        }
        rows.append(.init(action: .settings, title: "Settings", icon: "gearshape", searchTerms: "preferences"))
        if let settingsProject {
            rows.append(.init(action: .projectSettings(settingsProject.id), title: "Project settings",
                              icon: "folder", detail: settingsProject.title,
                              searchTerms: "overview name folder path checkout model pin"))
        }
        return rows
    }

    var projectChoices: [CommandPaletteRow] {
        let preferred = localThreadProject
        let projects = (preferred.map { [$0] } ?? []) + availableProjects.filter { $0.id != preferred?.id }
        var rows = projects.map {
            CommandPaletteRow(action: .newThread($0.id), title: $0.title, icon: "folder", detail: $0.path)
        }
        if canStartScratchThread {
            let index = min(projects.count, projects.filter { $0.pinned == true }.count + 1)
            rows.insert(.init(action: .newScratchThread, title: "No project", icon: "bubble.left",
                              searchTerms: "without project none scratch"), at: index)
        }
        return rows.isEmpty ? [.init(action: .addProject, title: "Add project", icon: "folder.badge.plus")] : rows
    }

    private func threadRow(_ thread: SidebarThread) -> CommandPaletteRow {
        CommandPaletteRow(action: .openThread(thread.id, project: thread.project.id),
                          title: thread.thread.title, icon: "bubble.left", detail: thread.project.displayTitle)
    }

    func messageSearch(for query: String, choosingProject: Bool) -> SidebarMessageSearch? {
        guard !choosingProject, !query.hasPrefix(">"), let term = TranscriptSearchTerm(paletteQuery: query) else { return nil }
        let candidates = threads.compactMap { thread -> SidebarMessageSearch.Thread? in
            guard CommandPaletteRow.matching(query, in: [threadRow(thread)]).isEmpty else { return nil }
            return .init(projectID: thread.project.id, threadID: thread.id)
        }
        guard !candidates.isEmpty else { return nil }
        return SidebarMessageSearch(term: term, threads: candidates)
    }

    func results(for query: String, choosingProject: Bool) -> [CommandPaletteRow] {
        groups(for: query, choosingProject: choosingProject).flatMap(\.rows)
    }

    func groups(for query: String, choosingProject: Bool, search: SidebarMessageSearch? = nil,
                matches: [UUID: SidebarMessageSearch.Match] = [:]) -> [CommandPaletteGroup] {
        if choosingProject {
            let rows = CommandPaletteRow.matching(query, in: projectChoices)
            return rows.isEmpty ? [] : [.init(id: .projects, rows: rows)]
        }
        if query.hasPrefix(">") {
            let rows = CommandPaletteRow.matching(String(query.dropFirst()), in: commands)
            return rows.isEmpty ? [] : [.init(id: .actions, rows: rows)]
        }

        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let visibleThreads = searching ? threads : Array(threads.lazy.filter { $0.id != activeThread }.prefix(12))
        let projectRows = searching ? projects.map {
            CommandPaletteRow(action: .openProject($0.id), title: $0.title, icon: "folder", detail: $0.path)
        } : []
        let settingsRows = searching ? settings.map { result in
            CommandPaletteRow(action: .openSetting(result.page, anchor: result.anchor,
                                                   projectID: result.page == .project ? settingsProject?.id : nil),
                              title: result.title, icon: result.page.icon,
                              detail: result.anchor == nil ? nil : result.page.title, searchTerms: result.keywords)
        } : []
        let rows = CommandPaletteRow.matching(query, in: commands + visibleThreads.map(threadRow) + projectRows + settingsRows)
        var groups = rows.reduce(into: [CommandPaletteGroup]()) { groups, row in
            let kind: CommandPaletteGroup.Kind
            switch row.action {
            case .openProject: kind = .projects
            case .openThread: kind = searching ? .threads : .recentThreads
            case .openSetting: kind = .settings
            default: kind = .actions
            }
            if let index = groups.firstIndex(where: { $0.id == kind }) {
                groups[index].rows.append(row)
            } else {
                groups.append(.init(id: kind, rows: [row]))
            }
        }
        if let search, !matches.isEmpty {
            let threadByID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let messageRows = search.threads.lazy.compactMap { target -> CommandPaletteRow? in
                guard let thread = threadByID[target.threadID], thread.project.id == target.projectID,
                      let match = matches[target.threadID] else { return nil }
                return CommandPaletteRow(
                    action: .openMessage(thread.id, project: thread.project.id, occurrence: match.occurrence, term: search.term),
                    title: thread.thread.title, icon: "text.bubble", detail: match.excerpt
                )
            }
            let limitedRows = Array(messageRows.prefix(10))
            if !limitedRows.isEmpty { groups.append(.init(id: .messages, rows: limitedRows)) }
        }
        return groups
    }
}

struct CommandPaletteSession {
    enum Key: Equatable {
        case toggle(WorkspaceFileSearch.Mode?)
        case escape, up, down, select, backspace

        init?(_ event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
            case ("k", .command): self = .toggle(nil)
            case ("p", .command): self = .toggle(.files)
            case ("f", [.command, .shift]): self = .toggle(.contents)
            default:
                guard modifiers.isEmpty else { return nil }
                switch Int(event.keyCode) {
                case kVK_Escape: self = .escape
                case kVK_UpArrow: self = .up
                case kVK_DownArrow: self = .down
                case kVK_Return, kVK_ANSI_KeypadEnter: self = .select
                case kVK_Delete: self = .backspace
                default: return nil
                }
            }
        }
    }

    enum Response: Equatable {
        case ignored
        case handled
        case close
        case run(CommandPaletteAction)
    }

    struct Search: Equatable {
        let request: SidebarMessageSearch
        let queryRevision: UUID
        let latestMessageID: String?
    }

    struct FileSearch: Equatable {
        let request: WorkspaceFileSearch
        let queryRevision: UUID
    }

    private struct WorkspaceSearchContext {
        let mode: WorkspaceFileSearch.Mode
        let parentQuery: String
        let parentHighlight: CommandPaletteAction?
    }

    private var parentQuery: String?
    private var highlight: CommandPaletteAction?
    private var queryRevision = UUID()
    private var searchResult: (search: Search, matches: [UUID: SidebarMessageSearch.Match])?
    private var workspaceSearch: WorkspaceSearchContext?
    private var fileResult: (search: FileSearch, result: Result<WorkspaceFileSearch.Results, Error>)?

    init(choosingProject: Bool = false, fileSearchMode: WorkspaceFileSearch.Mode? = nil) {
        parentQuery = choosingProject ? "" : nil
        if let fileSearchMode {
            setWorkspaceSearch(fileSearchMode)
        }
    }

    var choosingProject: Bool { parentQuery != nil }
    var fileSearchMode: WorkspaceFileSearch.Mode? { workspaceSearch?.mode }
    var query = "" { didSet { resetResults() } }
    var fileOptions = WorkspaceFileSearch.Options() { didSet { resetResults() } }

    mutating func resetResults() {
        highlight = nil
        queryRevision = UUID()
        searchResult = nil
        fileResult = nil
    }

    func messageSearch(in contents: CommandPaletteContents, latestMessageID: String?) -> Search? {
        guard workspaceSearch == nil else { return nil }
        return contents.messageSearch(for: query, choosingProject: choosingProject).map {
            Search(request: $0, queryRevision: queryRevision, latestMessageID: latestMessageID)
        }
    }

    func messageMatches(for search: Search?) -> [UUID: SidebarMessageSearch.Match]? {
        searchResult?.search == search ? searchResult?.matches : nil
    }

    mutating func receive(_ matches: [UUID: SidebarMessageSearch.Match], for search: Search) {
        guard search.queryRevision == queryRevision else { return }
        searchResult = (search, matches)
    }

    func fileSearch(at location: WorkspaceFilesLocation?) -> FileSearch? {
        guard let mode = fileSearchMode, let location else { return nil }
        if mode == .contents {
            guard query.utf16.count <= WorkspaceFileSearch.queryLimit,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        }
        let request = WorkspaceFileSearch(location: location, mode: mode, query: query, options: fileOptions)
        return FileSearch(request: request, queryRevision: queryRevision)
    }

    func fileResult(for search: FileSearch?) -> Result<WorkspaceFileSearch.Results, Error>? {
        fileResult?.search == search ? fileResult?.result : nil
    }

    mutating func receive(_ result: Result<WorkspaceFileSearch.Results, Error>, for search: FileSearch) {
        guard search.queryRevision == queryRevision else { return }
        fileResult = (search, result)
    }

    func selected(in rows: [CommandPaletteRow]) -> CommandPaletteRow? {
        rows.first { $0.action == highlight } ?? rows.first
    }

    mutating func back() {
        if let workspaceSearch {
            self.workspaceSearch = nil
            query = workspaceSearch.parentQuery
            highlight = workspaceSearch.parentHighlight
            return
        }
        guard let parentQuery else { return }
        self.parentQuery = nil
        query = parentQuery
    }

    mutating func select(_ action: CommandPaletteAction) -> Response {
        if action == .chooseProject {
            parentQuery = query
            query = ""
            return .handled
        }
        if case .searchWorkspace(let mode) = action {
            setWorkspaceSearch(mode, parentQuery: query, parentHighlight: action)
            return .handled
        }
        return .run(action)
    }

    private mutating func setWorkspaceSearch(_ mode: WorkspaceFileSearch.Mode?, parentQuery: String = "",
                                             parentHighlight: CommandPaletteAction? = nil) {
        workspaceSearch = mode.map { WorkspaceSearchContext(mode: $0, parentQuery: parentQuery,
                                                            parentHighlight: parentHighlight) }
        fileOptions = .init()
        query = ""
    }

    mutating func handle(_ key: Key, rows: [CommandPaletteRow], repeated: Bool, composing: Bool) -> Response {
        guard !composing else { return .ignored }
        switch key {
        case .toggle(let mode):
            guard !repeated else { return .handled }
            guard mode != fileSearchMode else { return .close }
            parentQuery = nil
            setWorkspaceSearch(mode)
            return .handled
        case .escape where workspaceSearch != nil:
            if !repeated { back() }
            return .handled
        case .escape:
            return repeated ? .handled : .close
        case .up, .down:
            if let selected = selected(in: rows), let index = rows.firstIndex(where: { $0.id == selected.id }) {
                let step = key == .up ? -1 : 1
                highlight = rows[(index + step + rows.count) % rows.count].id
            }
            return .handled
        case .select:
            guard !repeated, let action = selected(in: rows)?.action else { return .handled }
            return select(action)
        case .backspace:
            guard query.isEmpty, choosingProject, !repeated else { return .ignored }
            back()
            return .handled
        }
    }
}
