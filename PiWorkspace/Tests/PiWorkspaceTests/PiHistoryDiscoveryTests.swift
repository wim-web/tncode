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

    func testImportRejectsMovedSessionAndInvalidBranch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.writeSession(cwd: fixture.alpha.path, file: "selected", records: Self.messages)
        let original = try Data(contentsOf: source)
        let candidate = try XCTUnwrap(PiHistoryDiscovery.scan(agentDirectory: fixture.agent).candidates.first)
        let session = try XCTUnwrap(candidate.sessions.first)
        let holding = fixture.bucket.appendingPathComponent("moved.jsonl")
        try FileManager.default.moveItem(at: source, to: holding)
        XCTAssertThrowsError(try PiHistoryDiscovery.importHistory(session, from: candidate, threadID: UUID()))
        try FileManager.default.moveItem(at: holding, to: source)

        let bad = try fixture.writeSession(cwd: fixture.alpha.path, file: "broken", records: Self.messages + [
            #"{"type":"session_info","id":"bad","parentId":"bad","name":"Cycle"}"#,
        ])
        let rescanned = try XCTUnwrap(PiHistoryDiscovery.scan(agentDirectory: fixture.agent).candidates.first)
        let invalid = try XCTUnwrap(rescanned.sessions.first { $0.title == "Cycle" })
        XCTAssertThrowsError(try PiHistoryDiscovery.importHistory(invalid, from: rescanned, threadID: UUID()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor
    func testImportRetriesAfterIndexWriteFailureAndReopensWithoutAnAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.writeSession(cwd: fixture.alpha.path, file: "alpha", records: Self.messages)
        let sourceBytes = try Data(contentsOf: source)
        let candidate = try XCTUnwrap(PiHistoryDiscovery.scan(agentDirectory: fixture.agent).candidates.first)
        let session = try XCTUnwrap(candidate.sessions.first)
        let root = fixture.root.appendingPathComponent("Workspace")
        let index = root.appendingPathComponent(WorkspaceStore.indexName)
        let blocker = root.appendingPathComponent(WorkspaceStore.previousIndexName)
        let draft = Conversation(id: UUID(), title: "New thread", isDraft: true, composerText: "Keep editing")
        let project = Project(id: UUID(), path: candidate.folder.path, title: "Existing Alpha",
                              conversations: [draft], selectedConversation: draft.id)
        do {
            let store = try WorkspaceStore(root: root)
            try store.save(Workspace(projects: [project], selectedProject: project.id, welcomeCompleted: true))
        }
        func openWorkspace(_ reader: TranscriptReader) -> WorkspaceModel {
            WorkspaceModel(root: root, keychainService: "unused", credentialExists: { _ in
                XCTFail("An imported transcript must not check credentials")
                return false
            }, readCredential: { _ in
                XCTFail("An imported transcript must not read credentials")
                return nil
            }, makeProcess: { _, _ in reader })
        }

        let originalIndex = try Data(contentsOf: index)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        let threadID: UUID
        let savedHistory: Data
        let reader = TranscriptReader()
        do {
            let model = openWorkspace(reader)
            model.openWelcome()
            do {
                try await model.openDiscoveredPiSession(session, in: candidate)
                XCTFail("Import must fail when the index cannot be saved")
            } catch {
                XCTAssertTrue(model.showingWelcome)
                XCTAssertTrue(error.localizedDescription.contains(WorkspaceStore.previousIndexName),
                              error.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: index), originalIndex)
            XCTAssertEqual(model.conversation?.id, draft.id)
            XCTAssertEqual(model.draft, "Keep editing")
            let projectHistory = root.appendingPathComponent("sessions/\(project.id)")
            if FileManager.default.fileExists(atPath: projectHistory.path) {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: projectHistory.path), [])
            }
            XCTAssertTrue(reader.opens.isEmpty)
            try FileManager.default.removeItem(at: blocker)

            try await model.openDiscoveredPiSession(session, in: candidate)
            threadID = try XCTUnwrap(model.conversation?.id)
            XCTAssertEqual(model.project?.id, project.id)
            XCTAssertEqual(model.project?.conversations.last?.composerText, "Keep editing")
            XCTAssertEqual(model.conversation?.importedPiSessionID, session.id)
            XCTAssertNil(model.conversation?.historyModel)
            XCTAssertFalse(model.canChooseComposerModel)
            XCTAssertFalse(model.editDraft("Attempt to reply", in: threadID))
            let command = try XCTUnwrap(reader.opens.last)
            XCTAssertNil(command.config)
            XCTAssertTrue(command.requireHistory)
            XCTAssertEqual(command.cwd, candidate.folder.path)
            savedHistory = try Data(contentsOf: projectHistory.appendingPathComponent("\(threadID)/\(threadID).jsonl"))
            try model.applySettings(ModelSettings(provider: .anthropic, model: "claude"), in: .workspace,
                                    newKey: "", removeKey: false)
            XCTAssertNil(model.conversation?.historyModel)
            XCTAssertNil(try XCTUnwrap(reader.opens.last).config)
        }
        let reopened = openWorkspace(reader)
        reopened.start()
        XCTAssertEqual(reopened.conversation?.id, threadID)
        reopened.removeProject(project.id)
        XCTAssertTrue(reopened.projects.isEmpty)
        reopened.openWelcome()
        try await reopened.openDiscoveredPiSession(session, in: candidate)
        XCTAssertEqual(reopened.projects.map(\.id), [project.id])
        XCTAssertEqual(reopened.project?.conversations.map(\.id), [threadID, draft.id])
        let command = try XCTUnwrap(reader.opens.last)
        XCTAssertNil(command.config)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: command.sessionDir)
            .appendingPathComponent("\(threadID).jsonl")), savedHistory)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }

    private final class TranscriptReader: PiConnection {
        var onEvent: ((PiEvent) -> Void)?
        var onClose: (() -> Void)?
        var opens: [OpenConversation] = []

        func send(_ command: any Encodable) throws {
            if let open = command as? OpenConversation { opens.append(open) }
            else { XCTFail("Unexpected command sent to the transcript reader") }
        }

        func close() {}
    }

    private static let messages = [
        #"{"type":"message","id":"user","parentId":null,"message":{"role":"user","content":"Read Alpha"}}"#,
        #"{"type":"message","id":"assistant","parentId":"user","message":{"role":"assistant","content":[{"type":"text","text":"Alpha reply"}]}}"#,
    ]

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
        let originalID = UUID(), draftID = UUID(), betaID = UUID(), betaDraftID = UUID()
        do {
            let store = try WorkspaceStore(root: root)
            let draft = Conversation(id: draftID, title: "New thread", isDraft: true, composerText: "Keep editing")
            let project = Project(id: originalID, path: fixture.alpha.path, title: "My Alpha",
                                  conversations: [draft], selectedConversation: draftID)
            let betaDraft = Conversation(id: betaDraftID, title: "Beta draft", isDraft: true, composerText: "Keep Beta")
            let detached = Project(id: betaID, path: beta.folder.path, title: "My Beta", detached: true,
                                   conversations: [betaDraft], selectedConversation: betaDraftID)
            try store.save(Workspace(projects: [project, detached], selectedProject: project.id, welcomeCompleted: true))
        }
        func openWorkspace() -> WorkspaceModel {
            WorkspaceModel(root: root, keychainService: "unused", credentialExists: { _ in false },
                           readCredential: { _ in nil },
                           makeProcess: { _, _ in throw WorkspaceError("The fixture does not launch Pi.") })
        }

        let betaHolding = fixture.root.appendingPathComponent("Moved Beta")
        try FileManager.default.moveItem(at: fixture.beta, to: betaHolding)
        do {
            let model = openWorkspace()
            model.openWelcome()
            XCTAssertThrowsError(try model.registerDiscoveredPiProjects([alpha, beta]))
            XCTAssertEqual(model.projects.map(\.id), [originalID])
            try FileManager.default.moveItem(at: betaHolding, to: fixture.beta)
            try model.registerDiscoveredPiProjects([alpha, beta, beta])
            XCTAssertEqual(model.projects.map(\.id), [originalID, betaID])
            XCTAssertEqual(model.projects.last?.title, "My Beta")
            XCTAssertEqual(model.projects.last?.selectedConversation, betaDraftID)
            XCTAssertEqual(model.projects.last?.conversations.first?.composerText, "Keep Beta")
            XCTAssertEqual(model.project?.id, originalID)
            XCTAssertTrue(model.showingWelcome)
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
