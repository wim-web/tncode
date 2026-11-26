import AppKit
import Carbon

enum CommandPaletteAction: Hashable {
    case chooseProject
    case newThread(UUID)
    case newScratchThread
    case addProject
    case home
    case settings
    case searchThreads
    case openProject(UUID)
    case openThread(UUID, project: UUID)

    var identifier: String {
        switch self {
        case .chooseProject: "new-thread-in"
        case .newThread(let id): "new-thread-project-\(id)"
        case .newScratchThread: "no-project"
        case .addProject: "add-project"
        case .home: "home"
        case .settings: "settings"
        case .searchThreads: "search-threads"
        case .openProject(let id): "project-\(id)"
        case .openThread(let id, _): "thread-\(id)"
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

    private func rank(for words: [String]) -> Int? {
        let label = Self.fold(title)
        let phrase = words.joined(separator: " ")
        if label == phrase { return 0 }
        if label.hasPrefix(phrase) { return 1 }
        if words.allSatisfy(label.contains) { return 2 }
        let searchable = Self.fold([title, detail, searchTerms].compactMap { $0 }.joined(separator: " "))
        return words.allSatisfy(searchable.contains) ? 3 : nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func matching(_ query: String, in rows: [Self]) -> [Self] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.compactMap { row in row.rank(for: words).map { ($0, row) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}

struct CommandPaletteContents {
    let projects: [Project]
    let availableProjects: [Project]
    let preferredProject: UUID?
    let threads: [SidebarThread]
    let activeThread: UUID?
    let canStartScratchThread: Bool

    var commands: [CommandPaletteRow] {
        var rows: [CommandPaletteRow] = []
        if let preferred = availableProjects.first(where: { $0.id == preferredProject }) ?? availableProjects.first {
            rows.append(.init(action: .newThread(preferred.id), title: "New thread in \(preferred.title)",
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
        if preferredProject != nil {
            rows.append(.init(action: .home, title: "Go to home", icon: "house"))
        }
        rows.append(.init(action: .settings, title: "Settings", icon: "gearshape", searchTerms: "preferences"))
        return rows
    }

    var projectChoices: [CommandPaletteRow] {
        let preferred = availableProjects.first { $0.id == preferredProject }
        let projects = (preferred.map { [$0] } ?? []) + availableProjects.filter { $0.id != preferredProject }
        var rows = projects.map {
            CommandPaletteRow(action: .newThread($0.id), title: $0.title, icon: "folder", detail: $0.path)
        }
        if canStartScratchThread {
            let index = min(projects.count, projects.filter { $0.pinned == true }.count + 1)
            rows.insert(.init(action: .newScratchThread, title: "No project", icon: "bubble.left",
                              searchTerms: "without project none scratch"), at: index)
        }
        return rows
    }

    func results(for query: String, choosingProject: Bool) -> [CommandPaletteRow] {
        if choosingProject { return CommandPaletteRow.matching(query, in: projectChoices) }
        if query.hasPrefix(">") { return CommandPaletteRow.matching(String(query.dropFirst()), in: commands) }

        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let visibleThreads = searching ? threads : Array(threads.lazy.filter { $0.id != activeThread }.prefix(12))
        let threadRows = visibleThreads.map {
            CommandPaletteRow(action: .openThread($0.id, project: $0.project.id),
                              title: $0.thread.title, icon: "bubble.left", detail: $0.project.title)
        }
        let projectRows = searching ? projects.map {
            CommandPaletteRow(action: .openProject($0.id), title: $0.title, icon: "folder", detail: $0.path)
        } : []
        return CommandPaletteRow.matching(query, in: commands + threadRows + projectRows)
    }
}

struct CommandPaletteSession {
    enum Key {
        case toggle, escape, up, down, select, backspace

        init?(_ event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command, event.charactersIgnoringModifiers == "k" {
                self = .toggle
                return
            }
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

    enum Response: Equatable {
        case ignored
        case handled
        case close
        case run(CommandPaletteAction)
    }

    private var parentQuery: String?
    private var highlight: CommandPaletteAction?
    var choosingProject: Bool { parentQuery != nil }
    var query = "" {
        didSet { highlight = nil }
    }

    func selected(in rows: [CommandPaletteRow]) -> CommandPaletteRow? {
        rows.first { $0.action == highlight } ?? rows.first
    }

    mutating func back() {
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
        return .run(action)
    }

    mutating func handle(_ key: Key, rows: [CommandPaletteRow], repeated: Bool, composing: Bool) -> Response {
        guard !composing else { return .ignored }
        switch key {
        case .escape, .toggle:
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
