import Foundation
import XCTest
@testable import PiWorkspace

@MainActor
final class StartupDraftTests: XCTestCase {
    func testRetryOpensOneDraftInTheOriginalProject() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.index)
        let draftID: UUID
        do {
            let model = fixture.launch()
            XCTAssertNil(model.startupFailure)
            XCTAssertNil(model.error)
            XCTAssertEqual(model.failedStartupDraftProject, fixture.target.id)
            model.retryStartupDraft()
            XCTAssertEqual(try Data(contentsOf: fixture.index), original)
            XCTAssertEqual(model.conversation?.id, fixture.current.selectedConversation)

            try fixture.unblock()
            model.renameProject(fixture.current.id, title: "Edited during recovery")
            model.retryStartupDraft()
            draftID = try XCTUnwrap(model.conversation?.id)
            model.retryStartupDraft()
            XCTAssertNil(model.failedStartupDraftProject)
            XCTAssertEqual(model.project?.id, fixture.target.id)
            XCTAssertEqual(model.conversation?.id, draftID)
            XCTAssertEqual(model.conversation?.workingLocation, .project)
            XCTAssertEqual(model.project?.conversations.count, 2)
        }

        let reopened = fixture.launch()
        XCTAssertEqual(reopened.project?.id, fixture.target.id)
        XCTAssertEqual(reopened.conversation?.id, draftID)
        XCTAssertEqual(reopened.draft, "")
        XCTAssertEqual(reopened.project?.conversations.count, 2)
        let existing = try XCTUnwrap(reopened.project?.conversations.first { $0.id == fixture.target.selectedConversation })
        XCTAssertEqual(existing.composerText, "Keep the other draft")
        XCTAssertEqual(reopened.projects.first?.conversations.map(\.id), fixture.current.conversations.map(\.id))
        XCTAssertEqual(reopened.projects.first?.title, "Edited during recovery")
    }

    func testNavigationToTheAlreadySelectedConversationCancelsRetry() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.index)
        let model = fixture.launch()
        XCTAssertEqual(model.failedStartupDraftProject, fixture.target.id)
        let current = try XCTUnwrap(fixture.current.selectedConversation)
        model.selectConversation(current, in: fixture.current.id)
        XCTAssertNil(model.failedStartupDraftProject)
        try fixture.unblock()
        model.retryStartupDraft()
        XCTAssertEqual(model.conversation?.id, current)
        XCTAssertEqual(try Data(contentsOf: fixture.index), original)
    }

    func testUnsentComposerRestoresEvenWhenPreparingANewDraftWouldFail() throws {
        let fixture = try Fixture(unsent: "Continue editing this")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.index)
        let model = fixture.launch()
        XCTAssertNil(model.failedStartupDraftProject)
        XCTAssertEqual(model.conversation?.id, fixture.current.selectedConversation)
        XCTAssertEqual(model.draft, "Continue editing this")
        XCTAssertEqual(try Data(contentsOf: fixture.index), original)
    }

    @MainActor
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var index: URL { root.appendingPathComponent("workspace.json") }
        var blocker: URL { root.appendingPathComponent("workspace.previous.json") }
        let current: Project
        let target: Project

        init(unsent: String? = nil) throws {
            let submitted = Conversation(id: UUID(), title: "Submitted", isDraft: false, composerText: unsent)
            let saved = Conversation(id: UUID(), title: "Unsent", isDraft: true, composerText: "Keep the other draft")
            current = Project(id: UUID(), path: root.appendingPathComponent("Alpha").path, title: "Alpha",
                              conversations: [submitted], selectedConversation: submitted.id,
                              createdAt: Date(timeIntervalSince1970: 1))
            target = Project(id: UUID(), path: root.appendingPathComponent("Beta").path, title: "Beta",
                             conversations: [saved], selectedConversation: saved.id,
                             createdAt: Date(timeIntervalSince1970: 2))
            for folder in [current.path, target.path, blocker.path] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            try Data([1]).write(to: blocker.appendingPathComponent("blocker"))
            let state = Workspace(projects: [current, target], selectedProject: current.id, welcomeCompleted: true)
            try JSONEncoder().encode(state).write(to: index)
        }

        func launch() -> WorkspaceModel {
            let model = WorkspaceModel(root: root, keychainService: "unused", readCredential: { _ in nil }) { _, _ in
                throw WorkspaceError("The fixture does not launch Pi.")
            }
            model.start()
            return model
        }

        func unblock() throws {
            try FileManager.default.moveItem(at: blocker, to: root.appendingPathComponent("moved-blocker"))
        }
    }
}
