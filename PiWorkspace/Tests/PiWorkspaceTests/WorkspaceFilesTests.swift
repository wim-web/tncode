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

    func testEditRetainsOriginalCheckoutAndDoesNotChangeGitIndex() throws {
        try withFixture { root in
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

            let files = WorkspaceFiles(directory: projectRoot.path)
            let original = try text("notes.txt", in: files)
            let draft = WorkspaceFileDraft(target: projectTarget, original: original, text: original.text + "editor\n")
            let drafts = WorkspaceFileDrafts()
            drafts[projectTarget] = draft
            thread.location = .newWorktree(branch: "pending", base: "HEAD")
            XCTAssertNil(WorkspaceFilesLocation(thread: thread, project: project))
            XCTAssertThrowsError(try draft.save(whileActive: nil)) {
                XCTAssertEqual($0 as? WorkspaceFileError, .inactive)
            }
            thread.location = .worktree(path: worktree.path, base: "HEAD")
            let worktreeTarget = try target("notes.txt", thread: thread, project: project)
            let worktreeFiles = WorkspaceFiles(directory: worktreeTarget.location.directory)
            XCTAssertEqual(try text("notes.txt", in: worktreeFiles).text, "base\n")
            XCTAssertNil(drafts[worktreeTarget])
            XCTAssertThrowsError(try draft.save(whileActive: worktreeTarget)) {
                XCTAssertEqual($0 as? WorkspaceFileError, .inactive)
            }

            let otherThread = Conversation(id: UUID(), title: "Same Checkout")
            let otherTarget = try target("notes.txt", thread: otherThread, project: project)
            XCTAssertNil(drafts[otherTarget])
            XCTAssertThrowsError(try draft.save(whileActive: otherTarget)) {
                XCTAssertEqual($0 as? WorkspaceFileError, .inactive)
            }
            let differentFile = try target("different.txt",
                                           thread: Conversation(id: threadID, title: "Fixture Thread"),
                                           project: project)
            XCTAssertThrowsError(try draft.save(whileActive: differentFile)) {
                XCTAssertEqual($0 as? WorkspaceFileError, .inactive)
            }
            XCTAssertEqual(try text("notes.txt", in: files).text, "unstaged\n")

            thread.location = .project
            let restored = try target("notes.txt", thread: thread, project: project)
            XCTAssertEqual(drafts[restored]?.text, "unstaged\neditor\n")
            let saved = try XCTUnwrap(drafts[restored]).save(whileActive: restored)
            XCTAssertEqual(saved.text, "unstaged\neditor\n")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), saved.text)
            XCTAssertEqual(try git(projectRoot, ["show", ":notes.txt"]), "staged\n")
            XCTAssertEqual(try text("notes.txt", in: worktreeFiles).text, "base\n")
        }
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
            XCTAssertThrowsError(try draft.save(whileActive: selection)) {
                XCTAssertEqual($0 as? WorkspaceFileError, .changed)
            }
            XCTAssertEqual(try text("note", in: files).text, "outside")
            XCTAssertEqual(draft.text, "my edit")

            try Data("before".utf8).write(to: file, options: .atomic)
            XCTAssertThrowsError(try draft.save(whileActive: selection)) {
                XCTAssertEqual($0 as? WorkspaceFileError, .changed)
            }
            try FileManager.default.removeItem(at: file)
            XCTAssertThrowsError(try draft.save(whileActive: selection)) {
                XCTAssertEqual($0 as? WorkspaceFileError, .missing)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            let other = try write("keep", "other", in: root)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            XCTAssertThrowsError(try draft.save(whileActive: selection))
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
            XCTAssertThrowsError(try draft.save(whileActive: selection)) {
                XCTAssertEqual($0 as? WorkspaceFileError, .readOnly)
            }
            XCTAssertEqual(try text("note", in: files).text, "before\r\n")
            XCTAssertEqual(chmod(file.path, 0o751), 0)
            let saved = try draft.save(whileActive: selection)
            XCTAssertTrue(try text("note", in: files).matches(saved))
            XCTAssertEqual(try Data(contentsOf: file), Data(bom + Array(edit.utf8)))
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o751)
        }
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
