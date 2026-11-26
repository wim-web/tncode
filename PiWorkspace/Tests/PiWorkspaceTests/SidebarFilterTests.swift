import Darwin
import XCTest
@testable import PiWorkspace

final class SidebarFilterTests: XCTestCase {
    @MainActor
    func testProjectScopeSearchArchiveAndPins() async throws {
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

        func results(in model: WorkspaceModel, search: String = "", archived: Bool = false) -> [UUID] {
            SidebarThread.matching(in: model.sidebarProjectFilter.projects(in: model.projects), search: search, archived: archived).map(\.id)
        }

        do {
            let model = WorkspaceModel(root: root, keychainService: UUID().uuidString)
            try expect(model.projects.map(\.id) == [alpha.id, beta.id, gamma.id], "Load projects saved without pins.")
            model.updateSidebarScope { $0.setSelected(alpha.id, true) }
            try expect(results(in: model) == [alphaThread.id, draft.id], "One checkbox restricts the list.")
            model.updateSidebarScope { $0.setSelected(beta.id, true) }
            try expect(results(in: model, search: "BUILD") == [alphaThread.id, betaPinned.id, betaSettled.id],
                       "Search returns the union of selected projects across shelves in activity order.")
            try expect(results(in: model, search: "ALPHA") == [alphaThread.id, draft.id],
                       "A project name matches its threads regardless of their title.")
            try expect(results(in: model, search: "build", archived: true) == [betaArchived.id],
                       "Archive search finds only archived threads, regardless of their previous shelf.")
            try expect(results(in: model).contains(draft.id), "Clearing the search restores the draft row.")

            model.setProjectPinned(gamma.id, pinned: true)
            let ordered = SidebarProjectFilter.orderedProjects(model.projects)
            try expect(ordered.map(\.id) == [gamma.id, alpha.id, beta.id], "Pinned projects lead the picker.")
            try expect(model.sidebarProjectFilter.projects(in: ordered).map(\.id) == [alpha.id, beta.id],
                       "Pins outside the selection do not bypass the filter.")
            try expect(model.project?.id == gamma.id, "Filtering leaves the open project selected.")

            model.updateSidebarScope { $0.setSelected(alpha.id, false) }
            try expect(model.sidebarProjectFilter.projects(in: ordered).map(\.id) == [beta.id], "Unchecking one project keeps the others.")
            model.updateSidebarScope { $0.setSelected(beta.id, false) }
            try expect(model.sidebarProjectFilter.projects(in: ordered).map(\.id) == [gamma.id, alpha.id, beta.id],
                       "Unchecking the last project restores all projects.")
            model.updateSidebarScope { $0.selectOnly(alpha.id) }
            model.updateSidebarScope { $0.setSelected(beta.id, true) }
            model.removeProject(alpha.id)
            try expect(model.sidebarProjectFilter.projects(in: model.projects).map(\.id) == [beta.id],
                       "Removing a selected project preserves the rest of the selection.")
            model.updateSidebarScope { $0.clear() }
            try expect(results(in: model) == [gammaThread.id, betaPinned.id, betaSettled.id],
                       "All Projects restores attached projects and their normal threads.")
        }

        let reopened = WorkspaceModel(root: root, keychainService: UUID().uuidString)
        try expect(SidebarProjectFilter.orderedProjects(reopened.projects).map(\.id) == [gamma.id, beta.id],
                   "The pin survives reopening the workspace.")
        reopened.updateSidebarScope { $0.selectOnly(beta.id) }
        reopened.removeProject(beta.id)
        try expect(results(in: reopened) == [gammaThread.id],
                   "Removing the last selected project restores the remaining projects.")
        reopened.setProjectPinned(gamma.id, pinned: false)
        try expect(reopened.project?.pinned == false, "Unpin updates the open project.")
        reopened.setProjectPinned(gamma.id, pinned: true)
        try expect(reopened.project?.pinned == true, "A project can be pinned again.")

    }

    @MainActor
    func testHistoricalMessageSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let older = thread("Same title", at: 1, shelf: .settled)
        let newer = thread("Same title", at: 2)
        let archived = thread("Same title", at: 3, archived: true)
        let locked = thread("Same title", at: 4)
        let malformed = thread("Same title", at: 5)
        let missing = thread("Same title", at: 6)
        let linked = thread("Same title", at: 7)
        let ambiguous = thread("Same title", at: 8)
        let alpha = project("Alpha", in: root, threads: [older, locked, malformed])
        let beta = project("Beta", in: root, threads: [newer, archived, missing, linked, ambiguous])
        let keyword = "orbital-lantern"
        let actualMessage = "a1a1a1a1"
        let fixture = """
        {"type":"message","id":"\(actualMessage)","parentId":null,"message":{"role":"user","content":"An older user mentioned \(keyword)."}}
        {"type":"message","id":"a2a2a2a2","parentId":"\(actualMessage)","message":{"role":"assistant","content":[{"type":"text","text":"selected"},{"type":"thinking","text":"hidden-thinking"},{"type":"toolCall","text":"hidden-tool-call"},{"type":"text","text":"-reply"}]}}
        {"type":"message","id":"a3a3a3a3","parentId":"a2a2a2a2","message":{"role":"user","content":"abandoned-branch"}}
        malformed JSON line
        {"type":"message","id":"a4a4a4a4","parentId":"a2a2a2a2","message":{"role":"toolResult","content":[{"type":"text","text":"hidden-tool-output"}]}}
        {"type":"branch_summary","id":"a5a5a5a5","parentId":"a4a4a4a4","summary":"hidden-branch-summary"}
        {"type":"message","id":"a6a6a6a6","parentId":"a5a5a5a5","message":{"role":"assistant","content":[{"type":"text","text":"Newest visible reply."}]}}
        """
        let hiddenKeyword = """
        {"type":"message","id":"b1b1b1b1","parentId":null,"message":{"role":"user","content":"\(keyword)"}}
        """

        let lockedFile: URL
        do {
            let store = try WorkspaceStore(root: root)
            try store.save(Workspace(projects: [alpha, beta], selectedProject: beta.id))
            let olderFile = try writeHistory(fixture, version: 2, thread: older, project: alpha, in: store)
            _ = try writeHistory(hiddenKeyword.replacingOccurrences(of: keyword, with: "Other thread."),
                                 thread: newer, project: beta, in: store)
            _ = try writeHistory(hiddenKeyword, thread: archived, project: beta, in: store)
            lockedFile = try writeHistory(hiddenKeyword, thread: locked, project: alpha, in: store)
            _ = try writeHistory(hiddenKeyword, sessionID: UUID(), thread: malformed, project: alpha, in: store)
            let ambiguousFile = try writeHistory(hiddenKeyword, thread: ambiguous, project: beta, in: store)
            try FileManager.default.copyItem(at: ambiguousFile,
                                             to: ambiguousFile.deletingLastPathComponent().appendingPathComponent("extra.jsonl"))
            let outsideHistory = root.appendingPathComponent("outside.jsonl")
            try Data(history(hiddenKeyword, version: 3, sessionID: linked.id).utf8).write(to: outsideHistory)
            let linkedDirectory = store.history(project: beta.id, conversation: linked.id)
            try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkedDirectory.appendingPathComponent("link.jsonl"),
                                                       withDestinationURL: outsideHistory)
            let original = try Data(contentsOf: olderFile)
            let testRead = SidebarMessageSearch(query: keyword, threads: [.init(projectID: alpha.id, threadID: older.id)])
            _ = try await testRead.matches(in: root)
            try expect(try Data(contentsOf: olderFile) == original, "Search leaves a v2 file unchanged.")
        }
        let lock = open(lockedFile.path, O_WRONLY)
        try expect(lock >= 0, "Open the locked history fixture.")
        defer { close(lock) }
        try expect(flock(lock, LOCK_EX | LOCK_NB) == 0, "Lock history before searching.")

        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString)
        var filter = SidebarProjectFilter()
        func request(_ query: String, archived: Bool = false) -> SidebarMessageSearch {
            let visible = SidebarThread.matching(in: filter.projects(in: model.projects), search: "", archived: archived)
            return SidebarMessageSearch(query: query, threads: visible.filter { !$0.matchesTitle(query) }.map {
                .init(projectID: $0.project.id, threadID: $0.id)
            })
        }

        let allMatches = try await model.searchMessages(request(keyword.uppercased()))
        try expect(Set(allMatches.keys) == [older.id], "Only the older, visible thread contains a searchable match.")
        try expect(allMatches[older.id]?.messageID == actualMessage, "The result targets the older message's stored ID.")
        try expect(allMatches[older.id]?.excerpt.contains(keyword) == true, "The result shows the matching text.")
        let assistantMatches = try await model.searchMessages(request("selected-reply"))
        try expect(assistantMatches[older.id]?.messageID == "a2a2a2a2", "Assistant search joins text blocks.")
        for excluded in ["abandoned-branch", "hidden-thinking", "hidden-tool-call",
                         "hidden-tool-output", "hidden-branch-summary"] {
            let matches = try await model.searchMessages(request(excluded))
            try expect(matches.isEmpty, "Search excludes \(excluded).")
        }
        filter.selectOnly(beta.id)
        let otherProject = try await model.searchMessages(request(keyword))
        try expect(otherProject.isEmpty, "Project and active-thread filters hide the older and archived matches.")
        let archiveMatches = try await model.searchMessages(request(keyword, archived: true))
        try expect(Set(archiveMatches.keys) == [archived.id], "Archive search finds the matching archived thread.")
        filter.selectOnly(alpha.id)
        let otherArchive = try await model.searchMessages(request(keyword, archived: true))
        try expect(otherArchive.isEmpty, "Project scope also restricts archive search.")

        let obsolete = request(keyword)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await model.searchMessages(obsolete)
        }
        let replacement = try await model.searchMessages(request("newest visible"))
        do {
            _ = try await cancelled.value
            throw WorkspaceError("An obsolete query returned results after cancellation.")
        } catch is CancellationError {}
        try expect(replacement[older.id]?.messageID == "a6a6a6a6", "The replacement query returns its own message.")
    }

    private func writeHistory(_ entries: String, version: Int = 3, sessionID: UUID? = nil,
                                     thread: Conversation, project: Project, in store: WorkspaceStore) throws -> URL {
        let directory = store.history(project: project.id, conversation: thread.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.jsonl")
        try Data(history(entries, version: version, sessionID: sessionID ?? thread.id).utf8).write(to: file)
        return file
    }

    private func history(_ entries: String, version: Int, sessionID: UUID) -> String {
        """
        {"type":"session","id":"\(sessionID)","version":\(version),"cwd":"/tmp","timestamp":"2026-01-01T00:00:00Z"}
        \(entries)
        """
    }

    private func thread(_ title: String, at time: TimeInterval, shelf: ThreadShelf? = nil,
                               archived: Bool = false) -> Conversation {
        Conversation(id: UUID(), title: title, archived: archived,
                     lastActiveAt: Date(timeIntervalSince1970: time), shelf: shelf)
    }

    private func project(_ title: String, in root: URL, threads: [Conversation]) -> Project {
        Project(id: UUID(), path: root.appendingPathComponent(title).path,
                title: title, conversations: threads)
    }

    private func expect(_ condition: Bool, _ description: String) throws {
        guard condition else { throw WorkspaceError(description) }
    }
}
