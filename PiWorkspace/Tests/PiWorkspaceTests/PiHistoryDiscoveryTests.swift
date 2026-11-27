import Foundation
import XCTest
@testable import PiWorkspace

final class PiHistoryDiscoveryTests: XCTestCase {
    func testScanUsesHeaderFoldersAndKeepsNamesAndUniqueSessions() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let alias = fixture.root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.alpha)
        let sessionID = UUID()
        let named = try fixture.writeSession(cwd: fixture.alpha.path, id: sessionID, file: "named",
                                             records: [#"{"type":"session_info","name":"Named Alpha session"}"#])
        let original = try Data(contentsOf: named)
        _ = try fixture.writeSession(cwd: alias.path, id: sessionID, file: "duplicate")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                              ofItemAtPath: fixture.bucket.appendingPathComponent("duplicate.jsonl").path)
        _ = try fixture.writeSession(cwd: fixture.beta.path, file: "unnamed",
            records: [#"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Find Beta"}]}}"#])
        _ = try fixture.writeSession(cwd: fixture.root.appendingPathComponent("Missing").path, file: "missing")
        _ = try fixture.writeSession(cwd: "Relative", file: "relative")
        try FileManager.default.createSymbolicLink(at: fixture.bucket.appendingPathComponent("link.jsonl"),
                                                   withDestinationURL: named)

        for _ in 0..<2 {
            let result = try PiHistoryDiscovery.scan(agentDirectory: fixture.agent)
            XCTAssertEqual(result.skipped, 3)
            XCTAssertFalse(result.limited)
            XCTAssertEqual(result.candidates.count, 2)
            let alpha = try XCTUnwrap(result.candidates.first(where: { $0.title == "Alpha" }))
            XCTAssertEqual(alpha.folder, try ProjectFolder.existing(at: fixture.alpha))
            XCTAssertEqual(alpha.sessions.map(\.id), [sessionID.uuidString])
            XCTAssertEqual(alpha.sessions.map(\.title), ["Named Alpha session"])
            XCTAssertEqual(result.candidates.first(where: { $0.title == "Beta" })?.sessions.map(\.title), ["Find Beta"])
        }
        XCTAssertEqual(try Data(contentsOf: named), original)
    }

    func testMissingSessionsIsEmptyAndWrongTypeCanBeRetried() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let missing = fixture.root.appendingPathComponent("Empty Pi home")
        XCTAssertTrue(try PiHistoryDiscovery.scan(agentDirectory: missing).candidates.isEmpty)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let blocker = missing.appendingPathComponent("sessions")
        try Data().write(to: blocker)
        XCTAssertThrowsError(try PiHistoryDiscovery.scan(agentDirectory: missing))
        try FileManager.default.removeItem(at: blocker)
        XCTAssertTrue(try PiHistoryDiscovery.scan(agentDirectory: missing).candidates.isEmpty)
    }

    @MainActor
    func testRegistrationRollsBackStaleSelectionAndKeepsExistingDraftOnOpenAndRelaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.writeSession(cwd: fixture.alpha.path, file: "alpha")
        _ = try fixture.writeSession(cwd: fixture.beta.path, file: "beta")
        let result = try PiHistoryDiscovery.scan(agentDirectory: fixture.agent)
        let alpha = try XCTUnwrap(result.candidates.first { $0.title == "Alpha" })
        let beta = try XCTUnwrap(result.candidates.first { $0.title == "Beta" })
        let root = fixture.root.appendingPathComponent("Workspace")
        let originalID = UUID(), draftID = UUID()
        do {
            let store = try WorkspaceStore(root: root)
            let draft = Conversation(id: draftID, title: "New thread", isDraft: true, composerText: "Keep editing")
            let project = Project(id: originalID, path: fixture.alpha.path, title: "My Alpha",
                                  conversations: [draft], selectedConversation: draftID)
            try store.save(Workspace(projects: [project], selectedProject: project.id, welcomeCompleted: true))
        }
        func openWorkspace() -> WorkspaceModel {
            WorkspaceModel(root: root, keychainService: "unused", credentialExists: { _ in false },
                           readCredential: { _ in nil },
                           makeProcess: { _, _ in throw WorkspaceError("The fixture does not launch Pi.") })
        }

        let betaHolding = fixture.root.appendingPathComponent("Moved Beta")
        try FileManager.default.moveItem(at: fixture.beta, to: betaHolding)
        let betaID: UUID
        do {
            let model = openWorkspace()
            model.openWelcome()
            XCTAssertThrowsError(try model.registerDiscoveredPiProjects([alpha, beta]))
            XCTAssertEqual(model.projects.map(\.id), [originalID])
            try FileManager.default.moveItem(at: betaHolding, to: fixture.beta)
            try model.registerDiscoveredPiProjects([alpha, beta, beta])
            betaID = try XCTUnwrap(model.projects.first { $0.path == beta.folder.path }?.id)
            XCTAssertEqual(model.projects.map(\.id), [originalID, betaID])
            XCTAssertEqual(model.conversation?.id, draftID)
            XCTAssertEqual(model.draft, "Keep editing")
            try model.openDiscoveredPiProject(alpha)
            XCTAssertEqual(model.project?.id, originalID)
            XCTAssertEqual(model.project?.title, "My Alpha")
            XCTAssertEqual(model.conversation?.id, draftID)
            XCTAssertFalse(model.showingWelcome)
        }
        let reopened = openWorkspace()
        XCTAssertEqual(reopened.projects.map(\.id), [originalID, betaID])
        XCTAssertEqual(reopened.conversation?.id, draftID)
        XCTAssertEqual(reopened.draft, "Keep editing")
    }

    private struct Fixture {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("pi-discovery-\(UUID())", isDirectory: true)
        var alpha: URL { root.appendingPathComponent("Alpha", isDirectory: true) }
        var beta: URL { root.appendingPathComponent("Beta", isDirectory: true) }
        var agent: URL { root.appendingPathComponent("Agent", isDirectory: true) }
        var bucket: URL { agent.appendingPathComponent("sessions/--shared-bucket--", isDirectory: true) }

        init() throws {
            for folder in [alpha, beta, bucket] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        func writeSession(cwd: String, id: UUID = UUID(), file: String, records: [String] = []) throws -> URL {
            let header = try JSONSerialization.data(withJSONObject: ["type": "session", "version": 3,
                                                                      "id": id.uuidString, "cwd": cwd])
            let history = ([String(decoding: header, as: UTF8.self)] + records).joined(separator: "\n") + "\n"
            let path = bucket.appendingPathComponent(file + ".jsonl")
            try Data(history.utf8).write(to: path)
            return path
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
