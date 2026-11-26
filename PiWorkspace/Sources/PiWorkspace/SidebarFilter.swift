import Foundation

struct SidebarProjectFilter {
    private(set) var selection: Set<UUID> = []

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

    mutating func retainProjects(_ ids: [UUID]) {
        selection.formIntersection(ids)
    }
}

struct SidebarThread: Identifiable {
    let project: Project
    let thread: Conversation
    var id: UUID { thread.id }

    static func matching(in projects: [Project], search: String, archived: Bool) -> [Self] {
        projects.flatMap { project in
            let matchesProject = search.isEmpty || project.title.localizedCaseInsensitiveContains(search)
            return project.conversations.filter {
                $0.archived == archived && (matchesProject || $0.title.localizedCaseInsensitiveContains(search))
            }.map { Self(project: project, thread: $0) }
        }.sorted { ($0.thread.lastActiveAt ?? .distantPast) > ($1.thread.lastActiveAt ?? .distantPast) }
    }
}
