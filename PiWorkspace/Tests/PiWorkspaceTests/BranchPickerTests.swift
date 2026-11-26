import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class BranchPickerTests: XCTestCase {
    func testKeyboardSwitchRejectsConflictThenSelectsLinkedWorktree() async throws {
        let fixture = try Fixture()
        let model = try fixture.open()
        let thread = try XCTUnwrap(model.conversation?.id)
        let linkedPath = GitWorkspace.canonicalCheckoutPath(fixture.linked.path)
        let initialHead = try fixture.git(["rev-parse", "HEAD"])
        let linkedHead = try fixture.git(["rev-parse", "HEAD"], at: fixture.linked)
        let worktrees = try fixture.git(["worktree", "list", "--porcelain"])
        try fixture.write("staged\n", to: "conflict", at: fixture.repo)
        try fixture.git(["add", "--", "conflict"])
        try fixture.write("unstaged\n", to: "conflict", at: fixture.repo)
        let status = try fixture.git(["status", "--porcelain"])
        let index = try fixture.git(["show", ":conflict"])
        let file = fixture.repo.appendingPathComponent("conflict")
        let resumeFile = try fixture.historyFile()
        try Data("history already on disk".utf8).write(to: resumeFile)
        let history = [ChatMessage(id: "previous", role: .user, text: "Previous message")]
        fixture.connections.last?.emit(.history(history))
        let picker = try NativePicker(model: model)
        defer { picker.close() }

        try await picker.readyToCopy("main")
        try await picker.query("cOnFlIcT")
        let originalRevision = model.repositoryRevision
        try await picker.key(kVK_Return, "\r")
        try await picker.waitFor("Git evaluated the filtered branch and refused the switch") {
            model.repositoryRevision > originalRevision
        }
        XCTAssertFalse(picker.finished)
        XCTAssertEqual(model.workingDirectory, fixture.repo.path)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), initialHead)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "--short", "HEAD"]), "main\n")
        XCTAssertEqual(try fixture.git(["status", "--porcelain"]), status)
        XCTAssertEqual(try fixture.git(["show", ":conflict"]), index)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unstaged\n")

        try await picker.readyToCopy("main")
        try await picker.query("feature/")
        try await picker.key(kVK_DownArrow, "\u{f701}")
        try await picker.key(kVK_Return, "\r")
        try await picker.waitFor("picker closes after moving the thread") { picker.finished }

        XCTAssertEqual(model.conversation?.id, thread)
        XCTAssertEqual(model.workingDirectory, linkedPath)
        XCTAssertEqual(try fixture.saved().activeProject?.conversations.first?.workingLocation,
                       .worktree(path: linkedPath, base: nil))
        XCTAssertEqual(try fixture.saved().activeProject?.conversations.last?.workingLocation, .project)
        XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain"]), worktrees)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), initialHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], at: fixture.linked), linkedHead)
        XCTAssertEqual(try fixture.git(["status", "--porcelain"]), status)
        XCTAssertEqual(try fixture.git(["status", "--porcelain"], at: fixture.linked), "?? keep-local\n")
        XCTAssertEqual(fixture.connections.count, 2)
        XCTAssertEqual(fixture.connections.last?.open?.cwd, linkedPath)
        XCTAssertEqual(fixture.connections.first?.open?.sessionDir, fixture.connections.last?.open?.sessionDir)
        XCTAssertEqual(fixture.connections.first?.open?.threadID, fixture.connections.last?.open?.threadID)
        fixture.connections.last?.emit(.ready(history))
        XCTAssertEqual(model.messages.map(\.id), ["previous"])
        XCTAssertEqual(try String(contentsOf: resumeFile, encoding: .utf8), "history already on disk")

        let nextPicker = try NativePicker(model: model)
        defer { nextPicker.close() }
        try await nextPicker.readyToCopy("feature/linked-ß")
        XCTAssertEqual(nextPicker.pasteboard.string(forType: .string).map { Data($0.utf8) },
                       Data("feature/linked-ß".utf8))
        try await nextPicker.key(kVK_Escape, "\u{1b}")
        XCTAssertTrue(nextPicker.finished)
    }

    func testCreateSwitchAndTrackUseExactGitRefs() async throws {
        let fixture = try Fixture()
        let model = try fixture.open()
        let scope = try XCTUnwrap(model.branchPickerScope)
        let git = GitWorkspace(path: fixture.repo.path)
        try fixture.git(["remote", "add", "origin", fixture.repo.path])
        try fixture.git(["update-ref", "refs/remotes/origin/remote/topic", "refs/heads/conflict-target"])
        try fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/remote/topic"])
        let choices = try await git.branchChoices()
        XCTAssertTrue(choices.refs.contains {
            $0.id == "refs/remotes/origin/remote/topic" && $0.isDefault && $0.isRemote
        })
        XCTAssertFalse(choices.refs.contains { $0.id == "refs/remotes/origin/HEAD" })
        let targetHead = try fixture.git(["rev-parse", "conflict-target"])
        try await model.changeThreadBranch(.existing("refs/remotes/origin/remote/topic"), in: scope)
        XCTAssertEqual(model.workingDirectory, fixture.repo.path)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), targetHead)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "--short", "HEAD"]), "remote/topic\n")
        XCTAssertEqual(try fixture.git(["rev-parse", "--symbolic-full-name", "@{upstream}"]),
                       "refs/remotes/origin/remote/topic\n")

        let base = try fixture.git(["rev-parse", "feature/alpha"])
        let branches = try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads"])
        let picker = try NativePicker(model: model)
        defer { picker.close() }
        try await picker.readyToCopy("remote/topic")
        try await picker.query("bad..branch")
        try await picker.key(kVK_Return, "\r")
        try await picker.waitFor("Return opens the new branch form") { picker.field("New branch name") != nil }
        let name = try XCTUnwrap(picker.field("New branch name"))
        XCTAssertEqual(name.stringValue, "bad..branch")
        XCTAssertTrue(picker.window.makeFirstResponder(name))
        let originalRevision = model.repositoryRevision
        try await picker.key(kVK_Return, "\r")
        try await picker.waitFor("Git rejected the invalid name") { model.repositoryRevision > originalRevision }
        XCTAssertFalse(picker.finished)
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads"]), branches)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), targetHead)
        do {
            try await model.changeThreadBranch(.create(name: "feature/alpha", base: "HEAD"), in: scope)
            XCTFail("Duplicate branch names must be rejected.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }

        try fixture.write("keep staged\n", to: "notes", at: fixture.repo)
        try fixture.git(["add", "--", "notes"])
        try fixture.write("keep unstaged\n", to: "notes", at: fixture.repo)
        try await model.changeThreadBranch(.create(name: "feature/new-ß", base: "refs/heads/feature/alpha"), in: scope)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "--short", "HEAD"]), "feature/new-ß\n")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), base)
        XCTAssertEqual(try fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads"]),
                       branches.replacingOccurrences(of: "refs/heads/feature/linked-ß\n",
                           with: "refs/heads/feature/linked-ß\nrefs/heads/feature/new-ß\n"))
        XCTAssertEqual(try fixture.git(["show", ":notes"]), "keep staged\n")
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("notes"), encoding: .utf8), "keep unstaged\n")
        XCTAssertEqual(model.workingDirectory, fixture.repo.path)
        try await model.changeThreadBranch(.existing("refs/heads/conflict-target"), in: scope)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "--short", "HEAD"]), "conflict-target\n")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), targetHead)
        XCTAssertEqual(model.workingDirectory, fixture.repo.path)
    }

    func testPendingWorktreeChoiceOnlyChangesItsBase() async throws {
        let fixture = try Fixture()
        let model = try fixture.open(pending: true)
        let initialHead = try fixture.git(["rev-parse", "HEAD"])
        let worktrees = try fixture.git(["worktree", "list", "--porcelain"])
        let scope = try XCTUnwrap(model.branchPickerScope)
        try await model.changeThreadBranch(.existing("refs/heads/feature/linked-ß"), in: scope)
        XCTAssertEqual(try fixture.saved().activeProject?.conversations.first?.workingLocation,
                       .newWorktree(branch: "draft-branch", base: "refs/heads/feature/linked-ß"))
        XCTAssertEqual(model.workingDirectory, fixture.repo.path)
        XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain"]), worktrees)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), initialHead)
    }

    func testRunningAndPendingWorktreesCannotBeRetargeted() async throws {
        let fixture = try Fixture()
        let model = try fixture.open(protectLinkedCheckout: true)
        let scope = try XCTUnwrap(model.branchPickerScope)
        let revision = model.repositoryRevision
        model.draft = "Start a turn"
        model.send()
        XCTAssertEqual(model.phase, .running)
        do {
            try await model.changeThreadBranch(.existing("refs/heads/feature/linked-ß"), in: scope)
            XCTFail("A running thread cannot be retargeted.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Stop the current turn"))
        }
        XCTAssertEqual(model.repositoryRevision, revision)
        let prompt = try XCTUnwrap(fixture.connections.last?.prompt)
        fixture.connections.last?.emit(.finished(turnID: prompt.turnID, [], error: nil))
        XCTAssertEqual(model.phase, .ready)
        do {
            try await model.changeThreadBranch(.existing("refs/heads/feature/linked-ß"), in: scope)
            XCTFail("A worktree reserved by another thread's launch cannot be adopted.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("other thread"), error.localizedDescription)
        }
        XCTAssertEqual(model.workingDirectory, fixture.repo.path)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "--short", "HEAD"], at: fixture.linked), "feature/linked-ß\n")
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        var repo: URL { root.appendingPathComponent("local") }
        var linked: URL { root.appendingPathComponent("linked") }
        let projectID = UUID()
        let threadID = UUID()
        var connections: [Worker] = []

        init() throws {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init", "--quiet", "-b", "main"])
            try write("base\n", to: "conflict", at: repo)
            try git(["add", "--", "conflict"])
            try git(["commit", "-qm", "Base"])
            try git(["branch", "feature/alpha"])
            try git(["worktree", "add", "--quiet", "-b", "feature/linked-ß", linked.path])
            try git(["commit", "--allow-empty", "-qm", "Linked HEAD"], at: linked)
            try write("Keep linked edits\n", to: "keep-local", at: linked)
            try git(["switch", "-q", "-c", "conflict-target"])
            try write("other branch\n", to: "conflict", at: repo)
            try git(["commit", "-qam", "Conflicting content"])
            try git(["switch", "-q", "main"])
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func open(pending: Bool = false, protectLinkedCheckout: Bool = false) throws -> WorkspaceModel {
            var thread = Conversation(id: threadID, title: "Current", isDraft: pending)
            if pending { thread.location = .newWorktree(branch: "draft-branch", base: "main") }
            var other = Conversation(id: UUID(), title: "Other", isDraft: true)
            if protectLinkedCheckout {
                other.location = .worktree(path: linked.path, base: "main")
                other.worktreeLaunch = WorktreeLaunch(prompt: "Pending", originalDraft: "Pending")
            }
            let project = Project(id: projectID, path: repo.path, title: "Fixture",
                                  conversations: [thread, other], selectedConversation: threadID)
            try WorkspaceStore(root: root).save(Workspace(
                projects: [project], selectedProject: projectID, model: ModelSettings(provider: .local, model: "fixture"),
                welcomeCompleted: true
            ))
            let model = WorkspaceModel(root: root, keychainService: "BranchPickerTests", readCredential: { _ in "fixture-key" },
                                       makeProcess: { [weak self] _, _ in
                let worker = Worker()
                self?.connections.append(worker)
                return worker
            })
            model.connect()
            connections.last?.emit(.ready([]))
            return model
        }

        func saved() throws -> Workspace {
            try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
        }

        func historyFile() throws -> URL {
            let history = URL(fileURLWithPath: try XCTUnwrap(connections.first?.open?.sessionDir), isDirectory: true)
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            return history.appendingPathComponent("fixture.jsonl")
        }

        func write(_ text: String, to path: String, at directory: URL) throws {
            try Data(text.utf8).write(to: directory.appendingPathComponent(path))
        }

        @discardableResult
        func git(_ args: [String], at directory: URL? = nil) throws -> String {
            let command = Process()
            let pipe = Pipe()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            command.arguments = ["-C", (directory ?? repo).path, "-c", "user.name=Fixture",
                                 "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                                 "-c", "core.hooksPath=/dev/null"] + args
            command.standardOutput = pipe
            try command.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            command.waitUntilExit()
            guard command.terminationStatus == 0 else { throw WorkspaceError("Fixture git failed: \(args)") }
            return String(decoding: output, as: UTF8.self)
        }
    }

    @MainActor
    private final class Worker: PiConnection {
        var onEvent: ((PiEvent) -> Void)?
        var onClose: (() -> Void)?
        var open: OpenConversation?
        var prompt: SendPrompt?

        func send(_ command: any Encodable) throws {
            if let command = command as? OpenConversation { open = command }
            if let command = command as? SendPrompt { prompt = command }
        }

        func close() { onEvent = nil }
        func emit(_ event: PiEvent) { onEvent?(event) }
    }

    @MainActor
    private final class NativePicker {
        let window: NSWindow
        let pasteboard = NSPasteboard(name: .init("BranchPickerTests.\(UUID())"))
        private(set) var finished = false

        init(model: WorkspaceModel) throws {
            _ = NSApplication.shared
            let scope = try XCTUnwrap(model.branchPickerScope)
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 510, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BranchPickerView(scope: scope, model: model, pasteboard: pasteboard) {
                [weak self] in self?.finished = true
            })
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderBack(nil)
        }

        func close() {
            window.close()
            window.contentView = nil
            pasteboard.releaseGlobally()
        }

        func field(_ placeholder: String) -> NSTextField? {
            func find(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return window.contentView.flatMap(find)
        }

        func query(_ text: String) async throws {
            try await waitFor("search field is focused") {
                field("Search refs…")?.currentEditor() != nil &&
                field("Search refs…")?.currentEditor() === window.firstResponder
            }
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await Task.sleep(for: .milliseconds(35))
        }

        func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = []) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: UInt16(code)
            ))
            NSApplication.shared.sendEvent(event)
            try await Task.sleep(for: .milliseconds(35))
        }

        func readyToCopy(_ expected: String) async throws {
            pasteboard.clearContents()
            for _ in 0..<60 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await key(kVK_ANSI_C, "c", modifiers: [.command, .shift])
                if pasteboard.string(forType: .string) == expected { return }
            }
            throw WorkspaceError("The picker did not copy \(expected) to its named pasteboard.")
        }

        func waitFor(_ description: String, _ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                window.contentView?.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(15))
            }
            throw WorkspaceError("Timed out waiting for \(description)")
        }
    }
}
