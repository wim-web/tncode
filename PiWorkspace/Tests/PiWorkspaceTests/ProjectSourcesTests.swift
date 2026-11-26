import CoreTransferable
import Foundation
import XCTest
@testable import PiWorkspace

@MainActor
final class ProjectSourcesTests: XCTestCase {
    func testDiscardOnlyRemovesTheOwnedEmptyScratchDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WorkspaceStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try store.makeScratchProject(for: Conversation(id: UUID(), title: "New thread"))
        let other = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        var stale = scratch
        stale.path = other.path
        store.discardEmptyScratchFolder(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        store.discardEmptyScratchFolder(scratch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    func testRelativeFolderAndDropReuseTheSameProject() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let child = project.appendingPathComponent("Child #1", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        let file = root.appendingPathComponent("notes")
        try Data().write(to: file)
        let dropped = root.appendingPathComponent("Dropped Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: dropped, withIntermediateDirectories: false)
        let model = workspace(in: root)

        XCTAssertThrowsError(try ProjectFolder.resolve("Child #1", relativeTo: nil))
        try model.openProject(project)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)
        let badPath = try ProjectFolder.resolve("missing", relativeTo: request.basePath)
        XCTAssertThrowsError(try model.openProject(badPath, request: request))
        XCTAssertEqual(model.project?.path, project.path)

        let relative = try ProjectFolder.resolve("Child #1", relativeTo: request.basePath)
        try await model.openProject(.localFolder(relative), request: request)
        let selected = try XCTUnwrap(model.project)
        let draft = try XCTUnwrap(model.conversation)
        XCTAssertEqual(selected.path, child.path)
        XCTAssertEqual(draft.isDraft, true)

        XCTAssertFalse(try model.openDroppedProjects([file]))
        let provider = NSItemProvider(object: dropped as NSURL)
        let transferred = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: DroppedProjectFolder.self) { continuation.resume(with: $0) }
        }
        XCTAssertTrue(try model.openDroppedProjects([file, transferred.url]))
        XCTAssertEqual(model.project?.path, dropped.path)
        XCTAssertEqual(model.conversation?.isDraft, true)
        XCTAssertTrue(try model.openDroppedProjects([file, alias]))
        XCTAssertEqual(model.projects.count, 3)
        XCTAssertEqual(model.project?.id, selected.id)
        XCTAssertEqual(model.conversation?.id, draft.id)

        let data = try Data(contentsOf: root.appendingPathComponent("workspace/workspace.json"))
        let saved = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(saved.selectedProject, selected.id)
        XCTAssertEqual(saved.projects.first { $0.id == selected.id }?.selectedConversation, draft.id)
    }

    func testNewProjectInitializesAnEmptyGitRepositoryAndOpensADraft() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = workspace(in: root)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)

        try await model.openProject(.newProject(name: "Fresh Repo", parent: root), request: request)

        let folder = root.appendingPathComponent("Fresh Repo", isDirectory: true)
        let state = try await GitWorkspace(path: folder.path).state()
        XCTAssertNotNil(state.branch)
        XCTAssertTrue(state.branches.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [".git"])
        XCTAssertEqual(model.project?.path, folder.path)
        XCTAssertEqual(model.conversation?.isDraft, true)
        XCTAssertEqual(model.projects.count, 1)
    }

    func testCreationRejectsInvalidNamesAndLeavesExistingDestinationsUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("marker")
        let original = Data("keep".utf8)
        try original.write(to: marker)
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("file")
        try original.write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        let model = workspace(in: root)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)

        for name in ["  ", "..", "sub/folder", "existing", "empty", "file", "link"] {
            do {
                try await model.openProject(.newProject(name: name, parent: root), request: request)
                XCTFail("Accepted invalid or occupied name \(name.debugDescription)")
            } catch {}
        }

        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertEqual(try Data(contentsOf: marker), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), existing.path)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       ["existing", "empty", "file", "link", "workspace"])
    }

    func testRegistrationFailureKeepsTheNewRepository() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = workspace(in: root)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)
        let index = root.appendingPathComponent("workspace/workspace.json", isDirectory: true)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        do {
            try await model.openProject(.newProject(name: "Recover", parent: root), request: request)
            XCTFail("Registered a project when the workspace index could not be written")
        } catch {}

        let folder = root.appendingPathComponent("Recover", isDirectory: true)
        let state = try await GitWorkspace(path: folder.path).state()
        XCTAssertNotNil(state.branch)
        XCTAssertTrue(model.projects.isEmpty)
        try FileManager.default.removeItem(at: index)
        try await model.openProject(.localFolder(folder), request: request)
        XCTAssertEqual(model.project?.path, folder.path)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root.resolvingSymlinksInPath()
    }

    private func workspace(in root: URL) -> WorkspaceModel {
        WorkspaceModel(root: root.appendingPathComponent("workspace", isDirectory: true),
                       keychainService: "dev.piworkspace.project-sources-test")
    }
}
