import AppKit
import CryptoKit

struct ThreadCopyTarget {
    enum Field { case path, branch, id }

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
        case .id:
            text = thread.id.uuidString
        }
        try Task.checkCancellation()
        guard !text.isEmpty else { throw WorkspaceError("This thread has no workspace path to copy.") }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw WorkspaceError("Couldn’t copy to the clipboard.") }
    }
}

struct ThreadLink: Codable {
    static let scheme = "pi-workspace"
    private static let authority = "\(scheme)://thread/"

    let workspace: String
    let projectID: UUID
    let threadID: UUID

    init(workspaceID: UUID, root: URL, projectID: UUID, threadID: UUID) {
        workspace = Self.workspaceScope(id: workspaceID, root: root)
        self.projectID = projectID
        self.threadID = threadID
    }

    init?(text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.prefix(Self.authority.count).lowercased() == Self.authority else { return nil }
        let parts = text.dropFirst(Self.authority.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1", parts[1].wholeMatch(of: #/[0-9a-f]{64}/#) != nil,
              let projectID = UUID(uuidString: String(parts[2])), let threadID = UUID(uuidString: String(parts[3])) else {
            return nil
        }
        workspace = String(parts[1])
        self.projectID = projectID
        self.threadID = threadID
    }

    var text: String { "\(Self.authority)v1/\(workspace)/\(projectID)/\(threadID)" }

    static func workspaceScope(id: UUID, root: URL) -> String {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data("\(id)/\(path)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ThreadReference: Codable {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.piworkspace.thread-reference.v2")

    let link: ThreadLink
    let title: String

    @MainActor
    func copy(to pasteboard: NSPasteboard) throws {
        let item = NSPasteboardItem()
        let record = try JSONEncoder().encode(self)
        guard item.setString(link.text, forType: .string),
              item.setData(record, forType: Self.pasteboardType) else {
            throw WorkspaceError("Couldn’t copy the thread reference.")
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw WorkspaceError("Couldn’t copy the thread reference.") }
    }
}
