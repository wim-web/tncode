import Darwin
import Foundation
import XCTest
@testable import PiWorkspace

@MainActor
final class WorkspaceRecoveryTests: XCTestCase {
    func testFirstLaunchWithoutAnIndexShowsWelcome() async throws {
        let fixture = try Fixture()
        let model = fixture.open()

        XCTAssertNil(model.startupFailure)
        XCTAssertTrue(model.showingWelcome)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.index.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.previous.path))
    }

    func testLegacyIndexLoadsWithoutRewritingIt() async throws {
        let fixture = try Fixture()
        let project = UUID()
        let thread = UUID()
        let legacy = Data("""
            {
              "projects": [{
                "id": "\(project)", "path": "/fixture", "title": "Legacy", "allowEdits": false,
                "conversations": [{"id": "\(thread)", "title": "Previous thread", "archived": false}],
                "selectedConversation": "\(thread)"
              }],
              "selectedProject": "\(project)",
              "model": {"provider":"openai","model":"gpt-5-mini","endpoint":"","contextWindow":8192}
            }
            """.utf8)
        try legacy.write(to: fixture.index)
        let store = try WorkspaceStore(root: fixture.root)
        let workspace = try store.load()

        XCTAssertEqual(workspace.activeProject?.id, project)
        XCTAssertEqual(workspace.activeProject?.selectedConversation, thread)
        XCTAssertEqual(workspace.activeProject?.conversations.first?.workingLocation, .project)
        try store.save(workspace)
        XCTAssertEqual(try Data(contentsOf: fixture.index), legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.previous.path))
    }

    func testSaveRetainsOnlyThePreviousValidIndexAndSkipsUnchangedSaves() async throws {
        let fixture = try Fixture()
        let store = try WorkspaceStore(root: fixture.root)
        var workspace = Workspace()
        workspace.model.model = "first"
        try store.save(workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.previous.path))
        let first = try Data(contentsOf: fixture.index)

        workspace.model.model = "second"
        try store.save(workspace)
        XCTAssertEqual(try Data(contentsOf: fixture.previous), first)
        let second = try Data(contentsOf: fixture.index)

        workspace.model.model = "third"
        try store.save(workspace)
        try store.save(workspace)
        XCTAssertEqual(try store.load().model.model, "third")
        XCTAssertEqual(try Data(contentsOf: fixture.previous), second)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)),
                       [".lock", "workspace.json", "workspace.previous.json"])
    }

    func testSaveFailureLeavesTheCurrentIndexReadable() async throws {
        let fixture = try Fixture()
        let store = try WorkspaceStore(root: fixture.root)
        try store.save(Workspace())
        let original = try Data(contentsOf: fixture.index)
        try FileManager.default.createDirectory(at: fixture.previous, withIntermediateDirectories: false)
        var updated = Workspace()
        updated.model.model = "updated"

        XCTAssertThrowsError(try store.save(updated))
        XCTAssertEqual(try Data(contentsOf: fixture.index), original)
        XCTAssertEqual(try store.load().model.model, Workspace().model.model)
    }

    func testCorruptIndexWithNoValidBackupRemainsInRecovery() async throws {
        let fixture = try Fixture()
        let corrupt = Data([0xff, 0x00, 0x01])
        try corrupt.write(to: fixture.index)
        do {
            let store = try WorkspaceStore(root: fixture.root)
            XCTAssertThrowsError(try store.save(Workspace()))
        }
        let model = fixture.open()
        assertInvalidIndex(model, canRestore: false)

        try Data("{}".utf8).write(to: fixture.previous)
        model.openWorkspace(restoringPrevious: true)
        assertInvalidIndex(model, canRestore: false)
        XCTAssertEqual(try Data(contentsOf: fixture.index), corrupt)
        XCTAssertTrue(try fixture.archives().isEmpty)
    }

    func testRecoveryValidatesAgainAndPreservesCorruptBytesAndSessions() async throws {
        let fixture = try Fixture()
        let project = Project(id: UUID(), path: "/fixture", title: "Earlier project")
        let session = try fixture.seedBackup(for: project)
        let previous = try Data(contentsOf: fixture.previous)
        let corrupt = Data("{truncated".utf8)
        try corrupt.write(to: fixture.index)

        let model = fixture.open()
        assertInvalidIndex(model, canRestore: true)
        model.openWorkspace()
        assertInvalidIndex(model, canRestore: true)
        XCTAssertEqual(try Data(contentsOf: fixture.index), corrupt)

        try Data("null".utf8).write(to: fixture.previous)
        model.openWorkspace(restoringPrevious: true)
        assertInvalidIndex(model, canRestore: false)
        XCTAssertTrue(try fixture.archives().isEmpty)

        try previous.write(to: fixture.previous)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: fixture.index.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fixture.index.path) }
        model.openWorkspace(restoringPrevious: true)
        guard case let .access(file, _)? = model.startupFailure else {
            return XCTFail("Expected the index replacement to fail")
        }
        XCTAssertEqual(file, fixture.index)
        XCTAssertEqual(try Data(contentsOf: fixture.index), corrupt)
        let archives = try fixture.archives()
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archives.first)), corrupt)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fixture.index.path)
        model.openWorkspace()
        assertInvalidIndex(model, canRestore: true)
        model.openWorkspace(restoringPrevious: true)
        XCTAssertNil(model.startupFailure)
        XCTAssertEqual(model.project?.id, project.id)
        XCTAssertEqual(model.project?.title, "Earlier project")
        XCTAssertEqual(try Data(contentsOf: fixture.index), previous)
        XCTAssertEqual(try Data(contentsOf: fixture.previous), previous)
        XCTAssertEqual(try Data(contentsOf: session), Data("fixture session".utf8))
        XCTAssertEqual(try fixture.archives(), archives)
    }

    func testMissingCurrentIndexWithBackupRequiresExplicitRestore() async throws {
        let fixture = try Fixture()
        _ = try fixture.seedBackup(for: Project(id: UUID(), path: "/fixture", title: "Previous"))
        try FileManager.default.removeItem(at: fixture.index)
        let model = fixture.open()
        guard case .invalidIndex(missing: true, canRestore: true)? = model.startupFailure else {
            return XCTFail("Expected a missing index with a recoverable backup")
        }

        model.openWorkspace(restoringPrevious: true)
        XCTAssertNil(model.startupFailure)
        XCTAssertEqual(model.project?.title, "Previous")
        XCTAssertTrue(try fixture.archives().isEmpty)
    }

    func testRestorePreservesAnIndexRepairedBeforeTheAction() async throws {
        let fixture = try Fixture()
        _ = try fixture.seedBackup(for: Project(id: UUID(), path: "/fixture", title: "Previous"))
        let repaired = try Data(contentsOf: fixture.index)
        try Data("{truncated".utf8).write(to: fixture.index)
        let model = fixture.open()
        assertInvalidIndex(model, canRestore: true)

        try repaired.write(to: fixture.index, options: .atomic)
        model.openWorkspace(restoringPrevious: true)
        XCTAssertNil(model.startupFailure)
        XCTAssertEqual(model.project?.title, "Current project")
        XCTAssertEqual(try Data(contentsOf: fixture.index), repaired)
        XCTAssertTrue(try fixture.archives().isEmpty)
    }

    func testReadPermissionFailureIsDistinctFromCorruptionAndCanRetry() async throws {
        try XCTSkipIf(geteuid() == 0, "Root can read the fixture without file permissions")
        let fixture = try Fixture()
        _ = try fixture.seedBackup(for: Project(id: UUID(), path: "/fixture", title: "Previous"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.index.path)
        let model = fixture.open()
        guard case .access(let file, _)? = model.startupFailure else {
            return XCTFail("Expected an index access error")
        }
        XCTAssertEqual(file, fixture.index)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.index.path)
        model.openWorkspace()
        XCTAssertNil(model.startupFailure)
        XCTAssertEqual(model.project?.title, "Current project")
    }

    func testSecondInstanceCanRetryAfterTheOwnerReleasesTheLock() async throws {
        let fixture = try Fixture()
        var owner: WorkspaceStore? = try WorkspaceStore(root: fixture.root)
        var workspace = Workspace()
        workspace.model.model = "owned workspace"
        try XCTUnwrap(owner).save(workspace)

        let second = fixture.open()
        guard case .inUse? = second.startupFailure else { return XCTFail("Expected a lock conflict") }
        XCTAssertEqual(try owner?.load().model.model, "owned workspace")
        owner = nil

        second.openWorkspace()
        XCTAssertNil(second.startupFailure)
        XCTAssertEqual(second.workspace.model.model, "owned workspace")
    }

    private func assertInvalidIndex(_ model: WorkspaceModel, canRestore expected: Bool,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard case let .invalidIndex(missing, canRestore)? = model.startupFailure else {
            return XCTFail("Expected a damaged index", file: file, line: line)
        }
        XCTAssertFalse(missing, file: file, line: line)
        XCTAssertEqual(canRestore, expected, file: file, line: line)
    }

    private final class Fixture {
        let root: URL
        var index: URL { root.appendingPathComponent("workspace.json") }
        var previous: URL { root.appendingPathComponent("workspace.previous.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @MainActor
        func open() -> WorkspaceModel {
            WorkspaceModel(root: root, keychainService: "dev.piworkspace.recovery-test")
        }

        func seedBackup(for project: Project) throws -> URL {
            let store = try WorkspaceStore(root: root)
            var project = project
            let thread = Conversation(id: UUID(), title: "Conversation")
            project.conversations = [thread]
            project.selectedConversation = thread.id
            var workspace = Workspace(projects: [project], selectedProject: project.id)
            try store.save(workspace)
            workspace.projects[0].title = "Current project"
            try store.save(workspace)
            let directory = store.history(project: project.id, conversation: thread.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = directory.appendingPathComponent("fixture.jsonl")
            try Data("fixture session".utf8).write(to: session)
            return session
        }

        func archives() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("workspace.corrupt-") }
        }
    }
}
