import AppKit
import Carbon

struct SidebarProjectFilter {
    private(set) var selection: Set<UUID> = []

    init(selection: Set<UUID> = []) { self.selection = selection }

    static func orderedProjects(_ projects: [Project]) -> [Project] {
        projects.sorted { $0.pinned == true && $1.pinned != true }
    }

    func projects(in projects: [Project]) -> [Project] {
        let selected = projects.filter { selection.contains($0.id) }
        return selected.isEmpty ? projects : selected
    }

    mutating func setSelected(_ id: UUID, _ selected: Bool) {
        if selected { selection.insert(id) }
        else { selection.remove(id) }
    }

    mutating func selectOnly(_ id: UUID) {
        selection = [id]
    }

    mutating func clear() {
        selection.removeAll()
    }
}

struct SidebarThread: Identifiable {
    let project: Project
    let thread: Conversation
    var id: UUID { thread.id }

    func matchesTitle(_ search: String) -> Bool {
        search.isEmpty || thread.title.localizedCaseInsensitiveContains(search) ||
            project.title.localizedCaseInsensitiveContains(search)
    }

    static func matching(in projects: [Project], search: String, archived: Bool) -> [Self] {
        projects.flatMap { project in
            return project.conversations.filter {
                $0.archived == archived
            }.map { Self(project: project, thread: $0) }
        }.filter {
            $0.matchesTitle(search)
        }.sorted { ($0.thread.lastActiveAt ?? .distantPast) > ($1.thread.lastActiveAt ?? .distantPast) }
    }
}

enum SidebarThreadShortcut {
    case previous, next, number(Int)

    init?(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch modifiers {
        case [.command, .shift]:
            switch Int(event.keyCode) {
            case kVK_ANSI_LeftBracket: self = .previous
            case kVK_ANSI_RightBracket: self = .next
            default:
                switch event.charactersIgnoringModifiers {
                case "[": self = .previous
                case "]": self = .next
                default: return nil
                }
            }
        case .command:
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            if let index = digits.firstIndex(of: Int(event.keyCode)) {
                self = .number(index)
            } else if let text = event.charactersIgnoringModifiers, let digit = Int(text), (1...9).contains(digit) {
                self = .number(digit - 1)
            } else {
                return nil
            }
        default:
            return nil
        }
    }

    func targetIndex(count: Int, current: Int?, hasSelection: Bool) -> Int? {
        let index: Int
        switch self {
        case .number(let position): index = position
        case .previous:
            guard !hasSelection || current != nil else { return nil }
            index = current.map { $0 - 1 } ?? count - 1
        case .next:
            guard !hasSelection || current != nil else { return nil }
            index = current.map { $0 + 1 } ?? 0
        }
        return (0..<count).contains(index) ? index : nil
    }
}
