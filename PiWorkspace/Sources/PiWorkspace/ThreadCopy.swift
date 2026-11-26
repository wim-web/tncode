import AppKit

struct ThreadCopyTarget {
    enum Field { case path, branch, reference, id }

    let root: URL
    let project: Project
    let thread: Conversation

    var isDraft: Bool { thread.isDraft == true && !thread.archived }
    var path: String { thread.workingLocation.directory(in: project) }

    var branchReadPath: String? {
        guard !project.isScratch else { return nil }
        switch thread.workingLocation {
        case .project: return isDraft ? nil : path
        case let .worktree(path, _): return path
        case .newWorktree: return nil
        }
    }

    var draftBase: String? {
        guard isDraft, case let .newWorktree(_, base) = thread.workingLocation else { return nil }
        return GitBranchRef.displayName(base)
    }

    @MainActor
    func copy(_ field: Field, to pasteboard: NSPasteboard) async throws {
        try Task.checkCancellation()
        let text: String
        switch field {
        case .path:
            text = path
        case .branch:
            let branch: String?
            if let branchReadPath {
                branch = try await GitWorkspace(path: branchReadPath).currentBranch()
            } else {
                branch = draftBase
            }
            guard let branch, !branch.isEmpty else {
                throw WorkspaceError("This thread’s checkout has no current branch.")
            }
            text = branch
        case .reference:
            try ThreadReference(root: root, projectID: project.id, thread: thread).copy(to: pasteboard)
            return
        case .id:
            text = thread.id.uuidString
        }
        try Task.checkCancellation()
        guard !text.isEmpty else { throw WorkspaceError("This thread has no workspace path to copy.") }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw WorkspaceError("Couldn’t copy to the clipboard.") }
    }
}

struct ThreadReference: Codable {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.piworkspace.thread-reference.v1")

    let projectID: UUID
    let threadID: UUID
    let title: String
    let historyURL: URL

    init(root: URL, projectID: UUID, thread: Conversation) {
        self.projectID = projectID
        threadID = thread.id
        title = thread.title
        historyURL = WorkspaceStore.historyComponents(project: projectID, conversation: thread.id)
            .reduce(root.standardizedFileURL) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    @MainActor
    func copy(to pasteboard: NSPasteboard) throws {
        let item = NSPasteboardItem()
        let record = try JSONEncoder().encode(self)
        guard item.setString(historyURL.absoluteString, forType: .string),
              item.setData(record, forType: Self.pasteboardType) else {
            throw WorkspaceError("Couldn’t copy the thread reference.")
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw WorkspaceError("Couldn’t copy the thread reference.") }
    }
}
