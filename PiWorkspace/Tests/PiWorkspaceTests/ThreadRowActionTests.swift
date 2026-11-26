import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class ThreadRowActionTests: XCTestCase {
    func testCopyTargetsUseTheirOwnCheckoutAndPasteTheLocalThreadReference() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        model.connect()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let local = ThreadCopyTarget(root: fixture.workspace, project: fixture.project, thread: fixture.local)
        let linked = ThreadCopyTarget(root: fixture.workspace, project: fixture.project, thread: fixture.linked)
        let scratch = ThreadCopyTarget(root: fixture.workspace, project: fixture.scratch, thread: fixture.scratchThread)

        for (target, path) in [(local, fixture.repo.path), (linked, fixture.checkout.path), (scratch, fixture.scratch.path)] {
            try await target.copy(.path, to: board)
            XCTAssertEqual(board.string(forType: .string), path)
        }
        for (target, branch) in [(local, "main"), (linked, "topic/作業")] {
            try await target.copy(.branch, to: board)
            XCTAssertEqual(board.string(forType: .string), branch)
        }
        XCTAssertNil(scratch.branchReadPath)
        try Fixture.git(["checkout", "--quiet", "--detach", "HEAD"], in: fixture.checkout)
        do {
            try await linked.copy(.branch, to: board)
            XCTFail("A detached checkout has no branch to copy.")
        } catch {
            XCTAssertEqual(board.string(forType: .string), "topic/作業")
        }
        try await linked.copy(.id, to: board)
        XCTAssertEqual(board.string(forType: .string), fixture.linked.id.uuidString)
        try await linked.copy(.reference, to: board)
        let record = try JSONDecoder().decode(ThreadReference.self,
            from: XCTUnwrap(board.data(forType: ThreadReference.pasteboardType)))
        XCTAssertEqual(record.projectID, fixture.project.id)
        XCTAssertEqual(record.threadID, fixture.linked.id)
        XCTAssertEqual(record.title, fixture.linked.title)
        XCTAssertEqual(board.string(forType: .string), record.historyURL.absoluteString)
        XCTAssertTrue(record.historyURL.isFileURL)
        XCTAssertEqual(try Data(contentsOf: record.historyURL.appendingPathComponent("seed.jsonl")), fixture.historyBytes)
        XCTAssertNil(board.string(forType: .fileURL))
        XCTAssertEqual(model.conversation?.id, fixture.local.id)

        let host = OffscreenWorkspace(model: model, pasteboard: board)
        defer { host.close() }
        let field = try await host.waitFor("active composer") { host.composer }
        XCTAssertTrue(host.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.paste(nil)
        XCTAssertEqual(model.draft, record.historyURL.absoluteString)
        XCTAssertTrue(model.composerAttachments.isEmpty)
    }

    func testRenameArchiveAndRestoreKeepHistoryCheckoutAndDirtyDrafts() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        model.connect()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let host = OffscreenWorkspace(model: model, pasteboard: board)
        defer { host.close() }
        let id = fixture.linked.id
        let projectID = fixture.project.id
        let row = "thread-row-\(id)"
        try await host.press(row)
        XCTAssertEqual(model.conversation?.id, id)
        XCTAssertEqual(model.workingDirectory, fixture.checkout.path)
        XCTAssertEqual(model.messages.first?.text, "Keep the linked checkout history.")

        model.renameConversation(id, in: projectID, title: " \n \t")
        XCTAssertEqual(model.conversation?.title, fixture.linked.title)
        model.draft = "Dirty linked follow-up 🚲"
        model.renameConversation(id, in: projectID, title: "  Renamed linked thread \n")
        XCTAssertEqual(model.conversation?.title, "Renamed linked thread")
        XCTAssertEqual(SidebarThread.matching(in: model.threadProjects, search: "Renamed linked thread",
                                              archived: false).map(\.id), [id])
        _ = try await host.waitFor("renamed conversation title") {
            host.element("conversation-title")?.accessibilityLabel?() == "Renamed linked thread" ? true : nil
        }
        model.draft += "\nBefore archive"
        model.archiveConversation(id, in: projectID, archived: true)
        XCTAssertFalse(model.showArchive)
        XCTAssertEqual(model.conversation?.isDraft, true)
        XCTAssertEqual(model.workingDirectory, fixture.repo.path)
        XCTAssertEqual(model.draft, "")
        _ = try await host.waitFor("archived row removed") { host.element(row) == nil ? true : nil }

        model.showArchive = true
        XCTAssertEqual(SidebarThread.matching(in: model.threadProjects, search: "", archived: true).map(\.id), [id])
        try await host.press(row)
        XCTAssertEqual(model.conversation?.archived, true)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.messages.first?.text, "Keep the linked checkout history.")
        try await host.press("restore-open-thread")
        XCTAssertFalse(model.showArchive)
        XCTAssertEqual(model.conversation?.id, id)
        XCTAssertEqual(model.conversation?.archived, false)
        XCTAssertEqual(model.conversation?.title, "Renamed linked thread")
        XCTAssertEqual(model.draft, "Dirty linked follow-up 🚲\nBefore archive")
        XCTAssertEqual(model.workingDirectory, fixture.checkout.path)
        XCTAssertEqual(try Data(contentsOf: fixture.historyFile), fixture.historyBytes)
        XCTAssertEqual(try String(contentsOf: fixture.checkout.appendingPathComponent("local note"), encoding: .utf8),
                       "Keep this untracked file.")
        try await host.press("thread-row-\(fixture.local.id)")
        XCTAssertEqual(model.draft, "Other draft")
    }

    func testArchiveTargetsOnlyTheIdleRowAndStartsAnIndependentScratchDraft() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        model.connect()
        model.send()
        XCTAssertEqual(model.phase, .running)
        let id = fixture.local.id
        let other = fixture.linked.id
        let projectID = fixture.project.id
        model.archiveConversation(id, in: projectID, archived: true)
        XCTAssertEqual(model.conversation?.archived, false)
        model.archiveConversation(other, in: projectID, archived: true)
        XCTAssertEqual(model.project?.conversations.first { $0.id == other }?.archived, true)
        XCTAssertEqual(model.conversation?.id, id)
        XCTAssertEqual(model.phase, .running)
        model.archiveConversation(other, in: projectID, archived: false)
        XCTAssertEqual(model.project?.conversations.first { $0.id == other }?.archived, false)
        XCTAssertEqual(model.phase, .running)
        model.shutdown()

        model.selectConversation(fixture.scratchThread.id, in: fixture.scratch.id)
        model.draft = "Scratch follow-up"
        model.archiveConversation(fixture.scratchThread.id, in: fixture.scratch.id, archived: true)
        XCTAssertEqual(model.project?.isScratch, true)
        XCTAssertNotEqual(model.project?.id, fixture.scratch.id)
        XCTAssertNotEqual(model.workingDirectory, fixture.scratch.path)
        XCTAssertEqual(model.conversation?.isDraft, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.scratch.path))
        model.selectConversation(fixture.scratchThread.id, in: fixture.scratch.id)
        XCTAssertEqual(model.conversation?.archived, true)
        model.archiveConversation(fixture.scratchThread.id, in: fixture.scratch.id, archived: false)
        XCTAssertEqual(model.draft, "Scratch follow-up")
        XCTAssertEqual(model.workingDirectory, fixture.scratch.path)
    }

    private final class Fixture {
        let root: URL
        let workspace: URL
        let repo: URL
        let checkout: URL
        let local = Conversation(id: UUID(), title: "Local thread", isDraft: false, composerText: "Other draft")
        let scratchThread = Conversation(id: UUID(), title: "Scratch thread", isDraft: false)
        let linked: Conversation
        let project: Project
        let scratch: Project
        let historyFile: URL
        let historyBytes = Data("""
            {"type":"message","id":"linked-reply","role":"assistant","text":"Keep the linked checkout history."}
            """.utf8)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Thread Actions \(UUID())", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            repo = root.appendingPathComponent("Project Files", isDirectory: true)
            checkout = root.appendingPathComponent("Linked Checkout", isDirectory: true)
            let files = FileManager.default
            try files.createDirectory(at: repo, withIntermediateDirectories: true)
            try Self.git(["init", "-q", "-b", "main", "--template="], in: repo)
            try Self.git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                          "commit", "--allow-empty", "-q", "-m", "Fixture"], in: repo)
            try Self.git(["worktree", "add", "-q", "-b", "topic/作業", checkout.path], in: repo)
            try Data("Keep this untracked file.".utf8).write(to: checkout.appendingPathComponent("local note"))
            let store = try WorkspaceStore(root: workspace)
            linked = Conversation(id: UUID(), title: "Linked thread", location: .worktree(path: checkout.path, base: "main"),
                                  isDraft: false)
            project = Project(id: UUID(), path: repo.path, title: "Fixture",
                              conversations: [local, linked], selectedConversation: local.id)
            scratch = try store.makeScratchProject(for: scratchThread)
            try store.save(Workspace(projects: [project, scratch], selectedProject: project.id, welcomeCompleted: true))
            let history = store.history(project: project.id, conversation: linked.id)
            try files.createDirectory(at: history, withIntermediateDirectories: true)
            historyFile = history.appendingPathComponent("seed.jsonl")
            try historyBytes.write(to: historyFile)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @MainActor
        func open() -> WorkspaceModel {
            WorkspaceModel(root: workspace, keychainService: root.lastPathComponent, readCredential: { _ in "fixture-key" }) { _, _ in
                Connection()
            }
        }

        static func git(_ arguments: [String], in folder: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = folder
            process.environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw WorkspaceError("Fixture Git command failed.") }
        }
    }

    private final class Connection: PiConnection {
        var onEvent: ((PiEvent) -> Void)?
        var onClose: (() -> Void)?

        func send(_ command: any Encodable) throws {
            guard let open = command as? OpenConversation else { return }
            let file = URL(fileURLWithPath: open.sessionDir).appendingPathComponent("seed.jsonl")
            let messages = if FileManager.default.fileExists(atPath: file.path) {
                [try JSONDecoder().decode(ChatMessage.self, from: Data(contentsOf: file))]
            } else {
                [ChatMessage]()
            }
            onEvent?(.ready(messages))
        }

        func close() {}
    }

    @MainActor
    private final class OffscreenWorkspace {
        let window: NSWindow
        let host: NSView
        let activationPolicy: NSApplication.ActivationPolicy

        init(model: WorkspaceModel, pasteboard: NSPasteboard) {
            let app = NSApplication.shared
            activationPolicy = app.activationPolicy()
            app.setActivationPolicy(.prohibited)
            app.finishLaunching()
            let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2200, y: 0)
            window = ThreadActionsOffscreenPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1100, height: 720)),
                                                 styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable,
                                                         workspacePasteboard: pasteboard))
            window.contentView = host
            window.setFrameOrigin(origin)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
            window.orderBack(nil)
        }

        func close() {
            window.contentView = nil
            window.close()
            NSApplication.shared.setActivationPolicy(activationPolicy)
        }

        var composer: ComposerTextField.Field? {
            func find(_ view: NSView) -> ComposerTextField.Field? {
                (view as? ComposerTextField.Field) ?? view.subviews.lazy.compactMap(find).first
            }
            return find(host)
        }

        func element(_ id: String) -> AnyObject? {
            var visited = Set<ObjectIdentifier>()
            func find(_ node: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == id { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let found = find(child as AnyObject) { return found }
                }
                return nil
            }
            return find(host) ?? find(window)
        }

        func waitFor<T>(_ description: String, _ read: () -> T?) async throws -> T {
            for _ in 0..<80 {
                host.layoutSubtreeIfNeeded()
                if let value = read() { return value }
                try await Task.sleep(for: .milliseconds(20))
            }
            let message = "Timed out waiting for \(description)."
            XCTFail(message)
            throw WorkspaceError(message)
        }

        func press(_ id: String) async throws {
            let button = try await waitFor(id) { element(id) }
            XCTAssertTrue(button.accessibilityPerformPress?() == true)
            await Task.yield()
        }
    }
}

private final class ThreadActionsOffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
