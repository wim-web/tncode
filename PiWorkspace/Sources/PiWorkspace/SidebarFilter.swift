import Foundation

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
