import Foundation

// From PiWorkspace: swiftc Sources/PiWorkspace/{Workspace,WorkspaceModel,SidebarFilter,GitWorkspace,KeyVault,PiProcess}.swift scripts/verify-sidebar.swift -o /tmp/verify-sidebar
@main
@MainActor
struct VerifySidebar {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let alphaThread = thread("Alpha build", at: 3)
        let betaPinned = thread("Beta build pin", at: 2, shelf: .pinned)
        let betaSettled = thread("Beta build settled", at: 1, shelf: .settled)
        let betaArchived = thread("Beta build archive", at: 5, shelf: .pinned, archived: true)
        let draft = thread("New thread", at: 0)
        let gammaThread = thread("Gamma build", at: 4)
        let alpha = project("Alpha", in: root, threads: [alphaThread, draft])
        let beta = project("Beta", in: root, threads: [betaPinned, betaSettled, betaArchived])
        let gamma = project("Gamma", in: root, threads: [gammaThread])
        let original = Workspace(projects: [alpha, beta, gamma], selectedProject: gamma.id)
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceStore(root: root).save(original)

        var filter = SidebarProjectFilter()
        func results(in projects: [Project], search: String = "", archived: Bool = false) -> [UUID] {
            SidebarThread.matching(in: filter.projects(in: projects), search: search, archived: archived).map(\.id)
        }

        do {
            let model = WorkspaceModel(root: root, keychainService: UUID().uuidString)
            try expect(model.projects.map(\.id) == [alpha.id, beta.id, gamma.id], "Load projects saved without pins.")
            filter.setSelected(alpha.id, true)
            try expect(results(in: model.projects) == [alphaThread.id, draft.id], "One checkbox restricts the list.")
            filter.setSelected(beta.id, true)
            try expect(results(in: model.projects, search: "BUILD") == [alphaThread.id, betaPinned.id, betaSettled.id],
                       "Search returns the union of selected projects across shelves in activity order.")
            try expect(results(in: model.projects, search: "ALPHA") == [alphaThread.id, draft.id],
                       "A project name matches its threads regardless of their title.")
            try expect(results(in: model.projects, search: "build", archived: true) == [betaArchived.id],
                       "Archive search finds only archived threads, regardless of their previous shelf.")
            try expect(results(in: model.projects).contains(draft.id), "Clearing the search restores the draft row.")

            model.setProjectPinned(gamma.id, pinned: true)
            let ordered = SidebarProjectFilter.orderedProjects(model.projects)
            try expect(ordered.map(\.id) == [gamma.id, alpha.id, beta.id], "Pinned projects lead the picker.")
            try expect(filter.projects(in: ordered).map(\.id) == [alpha.id, beta.id],
                       "Pins outside the selection do not bypass the filter.")
            try expect(model.project?.id == gamma.id, "Filtering leaves the open project selected.")

            filter.setSelected(alpha.id, false)
            try expect(filter.projects(in: ordered).map(\.id) == [beta.id], "Unchecking one project keeps the others.")
            filter.setSelected(beta.id, false)
            try expect(filter.projects(in: ordered).map(\.id) == [gamma.id, alpha.id, beta.id],
                       "Unchecking the last project restores all projects.")
            filter.selectOnly(alpha.id)
            filter.setSelected(beta.id, true)
            model.removeProject(alpha.id)
            filter.retainProjects(model.projects.map(\.id))
            try expect(filter.projects(in: model.projects).map(\.id) == [beta.id],
                       "Removing a selected project preserves the rest of the selection.")
            try expect(filter.projects(in: [alpha] + model.projects).map(\.id) == [beta.id],
                       "Reattaching the same project does not select it again.")
            filter.clear()
            try expect(results(in: model.projects) == [gammaThread.id, betaPinned.id, betaSettled.id],
                       "All Projects restores attached projects and their normal threads.")
        }

        let reopened = WorkspaceModel(root: root, keychainService: UUID().uuidString)
        try expect(SidebarProjectFilter.orderedProjects(reopened.projects).map(\.id) == [gamma.id, beta.id],
                   "The pin survives reopening the workspace.")
        filter.selectOnly(beta.id)
        reopened.removeProject(beta.id)
        filter.retainProjects(reopened.projects.map(\.id))
        try expect(results(in: reopened.projects) == [gammaThread.id],
                   "Removing the last selected project restores the remaining projects.")
        reopened.setProjectPinned(gamma.id, pinned: false)
        try expect(reopened.project?.pinned == false, "Unpin updates the open project.")
        reopened.setProjectPinned(gamma.id, pinned: true)
        try expect(reopened.project?.pinned == true, "A project can be pinned again.")
        print("Passed sidebar fixture checks for project scope, search, archive, drafts, and pins.")
    }

    private static func thread(_ title: String, at time: TimeInterval, shelf: ThreadShelf? = nil,
                               archived: Bool = false) -> Conversation {
        Conversation(id: UUID(), title: title, archived: archived,
                     lastActiveAt: Date(timeIntervalSince1970: time), shelf: shelf)
    }

    private static func project(_ title: String, in root: URL, threads: [Conversation]) -> Project {
        Project(id: UUID(), path: root.appendingPathComponent(title).path,
                title: title, conversations: threads)
    }

    private static func expect(_ condition: Bool, _ description: String) throws {
        guard condition else { throw WorkspaceError(description) }
    }
}
