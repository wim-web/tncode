import Darwin
import Foundation
import XCTest
@testable import PiWorkspace

final class WorkspaceFilesTests: XCTestCase {
    func testTreeSearchAndRefreshStayInsideTheSelectedDirectory() throws {
        try withFixture { root in
            let checkout = try folder("checkout", in: root)
            let sources = try folder("Sources", in: checkout)
            let outside = try folder("sibling", in: root)
            try write("outside", "Outside.swift", in: outside)
            try write("source", "Content.swift", in: sources)
            try write("notes", "notes.md", in: checkout)
            try write("git metadata", ".git", in: checkout)
            try FileManager.default.createSymbolicLink(at: checkout.appendingPathComponent("Escape"),
                                                       withDestinationURL: outside)
            let files = WorkspaceFiles(directory: checkout.path)

            let tree = try files.tree()
            XCTAssertEqual(tree.entries.map(\.path), ["Sources", "Sources/Content.swift", "Escape", "notes.md"])
            XCTAssertEqual(tree.matching("sources/con").map(\.path), ["Sources/Content.swift"])
            XCTAssertTrue(tree.matching("outside").isEmpty)
            XCTAssertThrowsError(try files.preview("Escape/Outside.swift"))
            XCTAssertThrowsError(try files.preview("../sibling/Outside.swift"))
            XCTAssertThrowsError(try files.preview(".git"))

            try FileManager.default.removeItem(at: checkout.appendingPathComponent("notes.md"))
            try write("new", "added.md", in: checkout)
            XCTAssertEqual(try files.tree().matching(".md").map(\.path), ["added.md"])
            XCTAssertThrowsError(try files.preview("notes.md")) {
                XCTAssertEqual($0 as? WorkspaceFileError, .missing)
            }
        }
    }

    func testRegularReadOnlyLargeAndBinaryPreviews() throws {
        try withFixture { root in
            let files = WorkspaceFiles(directory: root.path)
            let readOnly = try write("read only\n", "readonly.txt", in: root)
            XCTAssertEqual(chmod(readOnly.path, 0o444), 0)
            let ordinary = try text("readonly.txt", in: files)
            XCTAssertEqual(ordinary.text, "read only\n")
            XCTAssertFalse(ordinary.writable)

            // The preview limit lands inside a multi-byte character.
            let largePrefix = String(repeating: "a", count: WorkspaceFiles.textLimit - 1)
            try write(largePrefix + "é\nlast line", "large.txt", in: root)
            guard case let .largeText(prefix, size) = try files.preview("large.txt") else {
                return XCTFail("Expected a bounded text preview.")
            }
            XCTAssertEqual(prefix, largePrefix)
            XCTAssertEqual(size, Int64(WorkspaceFiles.textLimit + 11))

            let bytes = Data([0x50, 0x00, 0x80, 0xFF])
            try bytes.write(to: root.appendingPathComponent("binary.dat"))
            guard case let .binary(prefix, size) = try files.preview("binary.dat") else {
                return XCTFail("Expected a binary preview.")
            }
            XCTAssertEqual(prefix, bytes)
            XCTAssertEqual(size, 4)
        }
    }

    @MainActor
    func testNavigationFlushesOriginalCheckoutWithoutChangingGitIndex() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = try folder("project", in: root)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        let threadID = UUID()
        let project = Project(id: UUID(), path: projectRoot.path, title: "Fixture")
        var thread = Conversation(id: threadID, title: "Fixture Thread")
        let projectTarget = try target("notes.txt", thread: thread, project: project)
        let file = try write("base\n", "notes.txt", in: projectRoot)
        _ = try git(projectRoot, ["init", "-q"])
        _ = try git(projectRoot, ["add", "notes.txt"])
        _ = try git(projectRoot, ["commit", "-qm", "Base"])
        _ = try git(projectRoot, ["worktree", "add", "--detach", "--", worktree.path, "HEAD"])
        try Data("staged\n".utf8).write(to: file)
        _ = try git(projectRoot, ["add", "notes.txt"])
        try Data("unstaged\n".utf8).write(to: file)

        let saves = WorkspaceFileSaves()
        let projectSession = saves.acquire(projectTarget)
        await projectSession.refresh()
        let original = try XCTUnwrap(projectSession.editorSource)
        projectSession.edit(original.text + "editor\n", from: original)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unstaged\n")
        thread.location = .newWorktree(branch: "pending", base: "HEAD")
        XCTAssertNil(WorkspaceFilesLocation(thread: thread, project: project))
        thread.location = .worktree(path: worktree.path, base: "HEAD")
        let worktreeTarget = try target("notes.txt", thread: thread, project: project)
        let worktreeFiles = WorkspaceFiles(directory: worktreeTarget.location.directory)
        let otherThread = Conversation(id: UUID(), title: "Same Checkout")
        let otherTarget = try target("notes.txt", thread: otherThread, project: project)
        XCTAssertEqual(saves.paths(in: projectTarget.location), ["notes.txt"])
        XCTAssertFalse(saves.hasDraft(for: worktreeTarget))
        XCTAssertFalse(saves.hasDraft(for: otherTarget))

        saves.release(projectSession)
        projectSession.edit("retired editor", from: original)
        XCTAssertFalse(saves.hasDraft(for: projectTarget))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unstaged\neditor\n")
        XCTAssertEqual(try git(projectRoot, ["show", ":notes.txt"]), "staged\n")
        XCTAssertEqual(try text("notes.txt", in: worktreeFiles).text, "base\n")
    }

    func testDiffNavigationMapsRepositoryPathsToTheSelectedSubfolder() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let subfolder = try folder("app", in: root)
        let duplicate = try folder("app", in: subfolder)
        try write("right file", "note", in: subfolder)
        try write("wrong file", "note", in: duplicate)
        try write("outside selected subfolder", "outside", in: root)
        _ = try git(root, ["init", "-q"])

        let status = try await GitWorkspace(path: subfolder.path).state()
        let inside = try XCTUnwrap(status.files.first { $0.path == "app/note" })
        let outside = try XCTUnwrap(status.files.first { $0.path == "outside" })
        let workspacePath = try XCTUnwrap(status.workspacePath(for: inside))
        XCTAssertEqual(try text(workspacePath, in: WorkspaceFiles(directory: subfolder.path)).text, "right file")
        XCTAssertNil(status.workspacePath(for: outside))
    }

    func testSaveRejectsExternalChangesReplacementAndDeletion() throws {
        try withFixture { root in
            let project = Project(id: UUID(), path: root.path, title: "Fixture")
            let selection = try target("note", thread: Conversation(id: UUID(), title: "Thread"), project: project)
            let files = WorkspaceFiles(directory: root.path)
            let file = try write("before", "note", in: root)
            let original = try text("note", in: files)
            let draft = WorkspaceFileDraft(target: selection, original: original, text: "my edit")

            try Data("outside".utf8).write(to: file)
            XCTAssertThrowsError(try draft.save()) {
                XCTAssertEqual($0 as? WorkspaceFileError, .changed)
            }
            XCTAssertEqual(try text("note", in: files).text, "outside")
            XCTAssertEqual(draft.text, "my edit")

            try Data("before".utf8).write(to: file, options: .atomic)
            XCTAssertThrowsError(try draft.save()) {
                XCTAssertEqual($0 as? WorkspaceFileError, .changed)
            }
            try FileManager.default.removeItem(at: file)
            XCTAssertThrowsError(try draft.save()) {
                XCTAssertEqual($0 as? WorkspaceFileError, .missing)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            let other = try write("keep", "other", in: root)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            XCTAssertThrowsError(try draft.save())
            XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "keep")
        }
    }

    func testSaveRetainsDraftWhenPermissionIsLostAndPreservesFileMetadata() throws {
        try withFixture { root in
            let project = Project(id: UUID(), path: root.path, title: "Fixture")
            let selection = try target("note", thread: Conversation(id: UUID(), title: "Thread"), project: project)
            let file = root.appendingPathComponent("note")
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            try Data(bom + Array("before\r\n".utf8)).write(to: file)
            XCTAssertEqual(chmod(file.path, 0o751), 0)
            let files = WorkspaceFiles(directory: root.path)
            let original = try text("note", in: files)
            let edit = "before\r\n追加\r\n"
            let draft = WorkspaceFileDraft(target: selection, original: original, text: edit)

            XCTAssertEqual(chmod(file.path, 0o451), 0)
            XCTAssertThrowsError(try draft.save()) {
                XCTAssertEqual($0 as? WorkspaceFileError, .readOnly)
            }
            XCTAssertEqual(try text("note", in: files).text, "before\r\n")
            XCTAssertEqual(chmod(file.path, 0o751), 0)
            let saved = try draft.save()
            XCTAssertTrue(try text("note", in: files).matches(saved))
            XCTAssertEqual(try Data(contentsOf: file), Data(bom + Array(edit.utf8)))
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o751)
        }
    }

    @MainActor
    func testAutosaveWaitsForQuietAndAdvancesTheEditorBaseline() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("base", "note", in: root)
        let saves = WorkspaceFileSaves()
        let session = try await openSession(saves, file: file, in: root)
        let source = try XCTUnwrap(session.editorSource)

        session.edit("first", from: source)
        try await Task.sleep(for: .milliseconds(300))
        session.edit("latest\n追加", from: source)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try Data(contentsOf: file), Data("base".utf8))
        XCTAssertEqual(session.draft?.text, "latest\n追加")

        try await waitFor { session.draft == nil }
        XCTAssertEqual(try Data(contentsOf: file), Data("latest\n追加".utf8))
        session.edit("latest\n追加!", from: source)
        XCTAssertNil(session.flush())
        XCTAssertEqual(try Data(contentsOf: file), Data("latest\n追加!".utf8))
        XCTAssertFalse(saves.hasDraft(for: session.target))
    }

    @MainActor
    func testPermissionRecoveryRetainsUnsavedTextAcrossClosingAndReopening() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("base", "note", in: root)
        let saves = WorkspaceFileSaves()
        let session = try await openSession(saves, file: file, in: root)
        session.edit("unsaved", from: try XCTUnwrap(session.editorSource))
        XCTAssertEqual(chmod(file.path, 0o444), 0)

        try await waitFor { session.isReadOnly }
        XCTAssertFalse(session.isEditable)
        XCTAssertEqual(session.draft?.text, "unsaved")
        XCTAssertEqual(try Data(contentsOf: file), Data("base".utf8))
        saves.release(session)
        XCTAssertEqual(saves.paths(in: session.target.location), ["note"])

        let reopened = saves.acquire(session.target)
        await reopened.refresh()
        XCTAssertEqual(reopened.draft?.text, "unsaved")
        XCTAssertTrue(reopened.isReadOnly)
        saves.release(reopened)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        try await waitFor { !saves.hasDraft(for: session.target) }
        XCTAssertEqual(try Data(contentsOf: file), Data("unsaved".utf8))

        let clean = saves.acquire(session.target)
        XCTAssertEqual(chmod(file.path, 0o444), 0)
        await clean.refresh()
        XCTAssertNil(clean.draft)
        XCTAssertEqual(clean.editorSource?.text, "unsaved")
        XCTAssertTrue(clean.isReadOnly)
        XCTAssertFalse(clean.isEditable)
    }

    @MainActor
    func testRefreshDoesNotRebaseKeystrokesFromAnOlderEditorDisplay() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("base", "note", in: root)
        let saves = WorkspaceFileSaves()
        let session = try await openSession(saves, file: file, in: root)
        let oldDisplay = try XCTUnwrap(session.editorSource)
        try Data("base".utf8).write(to: file, options: .atomic)
        await session.refresh()
        session.edit("base edit", from: oldDisplay)
        saves.release(session)

        XCTAssertEqual(try Data(contentsOf: file), Data("base".utf8))
        let reopened = saves.acquire(session.target)
        XCTAssertEqual(reopened.draft?.text, "base edit")
        XCTAssertTrue(reopened.changedOnDisk)
    }

    @MainActor
    func testQuitFlushesPendingFilesAndKeepsBlockedFilesForRetry() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root.appendingPathComponent("state", isDirectory: true),
                                   keychainService: UUID().uuidString, readCredential: { _ in nil })
        let checkout = try folder("checkout", in: root)
        let good = try write("base", "good.txt", in: checkout)
        let blocked = try write("base", "blocked.txt", in: checkout)
        let original = try write("keep", "outside.txt", in: root)
        let goodSession = try await openSession(model.fileSaves, file: good, in: checkout)
        let blockedSession = try await openSession(model.fileSaves, file: blocked, in: checkout)

        goodSession.edit("save immediately", from: try XCTUnwrap(goodSession.editorSource))
        blockedSession.edit("keep this draft", from: try XCTUnwrap(blockedSession.editorSource))
        let backup = checkout.appendingPathComponent("original.txt")
        try FileManager.default.moveItem(at: blocked, to: backup)
        try FileManager.default.createSymbolicLink(at: blocked, withDestinationURL: original)
        model.fileSaves.release(blockedSession)
        XCTAssertTrue(model.fileSaves.hasDraft(for: blockedSession.target))
        XCTAssertFalse(model.savePendingEditsForQuit())
        XCTAssertTrue(try XCTUnwrap(model.quitFileSaveError).contains("blocked.txt"))
        XCTAssertEqual(try Data(contentsOf: good), Data("save immediately".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
        XCTAssertEqual(blockedSession.draft?.text, "keep this draft")

        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.moveItem(at: backup, to: blocked)
        XCTAssertTrue(model.terminate())
        XCTAssertNil(model.quitFileSaveError)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("keep this draft".utf8))
    }

    @MainActor
    func testOversizedDraftRemainsAvailableAndCanBeTrimmedAndSaved() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("base", "note", in: root)
        let saves = WorkspaceFileSaves()
        let session = try await openSession(saves, file: file, in: root)
        let source = try XCTUnwrap(session.editorSource)
        let oversized = String(repeating: "a", count: WorkspaceFiles.textLimit + 1)
        session.edit(oversized, from: source)
        XCTAssertEqual(session.flush() as? WorkspaceFileError, .tooLarge)
        XCTAssertEqual(session.draft?.text, oversized)
        XCTAssertTrue(session.isEditable)
        XCTAssertEqual(try Data(contentsOf: file), Data("base".utf8))

        session.edit("trimmed", from: source)
        XCTAssertNil(session.flush())
        XCTAssertEqual(try Data(contentsOf: file), Data("trimmed".utf8))
    }

    @MainActor
    private func openSession(_ saves: WorkspaceFileSaves, file: URL, in checkout: URL) async throws -> WorkspaceFileSaveSession {
        let project = Project(id: UUID(), path: checkout.path, title: "Fixture")
        let thread = Conversation(id: UUID(), title: "Fixture Thread")
        let session = saves.acquire(try target(file.lastPathComponent, thread: thread, project: project))
        await session.refresh()
        return session
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PiWorkspaceFilesTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    @discardableResult
    private func write(_ contents: String, _ name: String, in root: URL) throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func target(_ path: String, thread: Conversation, project: Project) throws -> WorkspaceFileTarget {
        WorkspaceFileTarget(location: try XCTUnwrap(WorkspaceFilesLocation(thread: thread, project: project)), path: path)
    }

    private func text(_ path: String, in files: WorkspaceFiles) throws -> WorkspaceFileText {
        guard case let .text(text) = try files.preview(path) else {
            throw WorkspaceError("Expected a text preview for \(path).")
        }
        return text
    }

    private func git(_ directory: URL, _ arguments: [String]) throws -> String {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        command.currentDirectoryURL = directory
        command.environment = [
            "PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "TMPDIR": directory.path
        ]
        command.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        let output = Pipe()
        command.standardOutput = output
        try command.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw WorkspaceError("Fixture git command failed.") }
        return String(decoding: bytes, as: UTF8.self)
    }
}
