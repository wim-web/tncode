import XCTest
@testable import tncode

final class ConversationForkTests: XCTestCase {
    @MainActor
    func testForkOpensChildAndPersistsBothDirectionsWithoutSending() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanUp() }
        let workspace = fixture.open()
        let parentWorker = fixture.worker
        let cutoff = fixture.history[3]

        workspace.resumeQueuedMessages()
        let active = try XCTUnwrap(parentWorker.prompts.last)
        XCTAssertFalse(workspace.canForkResponse(cutoff))
        workspace.forkResponse(cutoff.id)
        XCTAssertTrue(parentWorker.forks.isEmpty)
        parentWorker.onEvent?(.finished(turnID: active.turnID, fixture.history, error: "Fixture stopped"))
        XCTAssertEqual(workspace.queuedMessages, [fixture.queued])
        XCTAssertTrue(workspace.canForkResponse(cutoff))

        workspace.draft = "Latest parent draft"
        workspace.forkResponse(cutoff.id)
        workspace.forkResponse(cutoff.id)
        XCTAssertEqual(parentWorker.forks.count, 1)
        let command = try XCTUnwrap(parentWorker.forks.first)
        XCTAssertEqual(command.messageID, cutoff.id)
        XCTAssertFalse(workspace.canSend)
        XCTAssertFalse(workspace.canEditQueue)
        XCTAssertFalse(workspace.canOpenForkLink(fixture.parentID))
        parentWorker.onEvent?(.forked(threadID: UUID(), error: nil))
        XCTAssertEqual(workspace.conversation?.id, fixture.parentID)
        try fixture.writeHistory(command.threadID)
        parentWorker.onEvent?(.forked(threadID: command.threadID, error: nil))

        let childWorker = fixture.worker
        let inherited = Array(fixture.history.prefix(4))
        childWorker.onEvent?(.ready(inherited))
        XCTAssertEqual(workspace.conversation?.id, command.threadID)
        XCTAssertEqual(workspace.conversation?.title, "Parent fork")
        XCTAssertEqual(workspace.conversation?.forkOrigin?.threadID, fixture.parentID)
        XCTAssertEqual(childWorker.openCommand?.forkMessageID, cutoff.id)
        XCTAssertEqual(childWorker.openCommand?.cwd, fixture.checkout.path)
        XCTAssertEqual(workspace.messages.map(\.id), inherited.map(\.id))
        XCTAssertEqual(workspace.draft, "")
        XCTAssertTrue(workspace.queuedMessages.isEmpty)
        XCTAssertTrue(childWorker.prompts.isEmpty)

        workspace.openForkLink(fixture.parentID)
        fixture.worker.onEvent?(.ready(fixture.history))
        XCTAssertEqual(workspace.messages.map(\.id), fixture.history.map(\.id))
        XCTAssertEqual(workspace.draft, "Latest parent draft")
        XCTAssertEqual(workspace.queuedMessages, [fixture.queued])
        XCTAssertTrue(fixture.worker.prompts.isEmpty)
        workspace.openForkLink(command.threadID)
        fixture.worker.onEvent?(.ready(inherited))
        XCTAssertTrue(fixture.worker.prompts.isEmpty)
        workspace.shutdown()

        let saved = try fixture.savedWorkspace()
        XCTAssertEqual(saved.activeProject?.selectedConversation, command.threadID)
        XCTAssertEqual(saved.activeProject?.conversations.first { $0.id == fixture.parentID }?.composerText,
                       "Latest parent draft")
        XCTAssertEqual(saved.activeProject?.conversations.first { $0.id == fixture.parentID }?.queuedMessages,
                       [fixture.queued])
        XCTAssertEqual(saved.activeProject?.conversations.first { $0.id == command.threadID }?.forkOrigin?.messageID,
                       cutoff.id)
    }

    @MainActor
    func testFailedPublicationAndInterruptedForkRemoveOnlyThePreparedHistory() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanUp() }
        let model = fixture.open()
        let worker = fixture.worker
        let messageID = fixture.history[3].id

        model.forkResponse(messageID)
        let failed = try XCTUnwrap(worker.forks.last)
        try fixture.writeHistory(failed.threadID)
        let backup = fixture.root.appendingPathComponent("held-index")
        try FileManager.default.moveItem(at: fixture.index, to: backup)
        try FileManager.default.createDirectory(at: fixture.index, withIntermediateDirectories: false)
        worker.onEvent?(.forked(threadID: failed.threadID, error: nil))
        try FileManager.default.removeItem(at: fixture.index)
        try FileManager.default.moveItem(at: backup, to: fixture.index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyFile(failed.threadID).path))
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.conversation?.id, fixture.parentID)
        XCTAssertEqual(try fixture.savedWorkspace().activeProject?.conversations.count, 1)

        model.forkResponse(messageID)
        let interrupted = try XCTUnwrap(worker.forks.last)
        XCTAssertNotEqual(interrupted.threadID, failed.threadID)
        try fixture.writeHistory(interrupted.threadID)
        worker.onClose?()
        XCTAssertEqual(model.phase, .closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyFile(interrupted.threadID).path))
        XCTAssertEqual(try fixture.savedWorkspace().activeProject?.conversations.count, 1)
        XCTAssertEqual(try String(contentsOf: fixture.historyFile(fixture.parentID), encoding: .utf8), "Fixture history")
    }

    @MainActor
    func testRelaunchRollsBackUnpublishedForkAndReopensPublishedFork() async throws {
        let fixture = try ForkFixture()
        defer { fixture.cleanUp() }
        let abandoned = UUID()
        try fixture.leaveForkJournal(for: abandoned, publish: false)
        do {
            let model = fixture.open()
            XCTAssertEqual(model.conversation?.id, fixture.parentID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyFile(abandoned).path))
        }

        let published = UUID()
        try fixture.leaveForkJournal(for: published, publish: true)
        let reopened = fixture.open(relaunch: true)
        XCTAssertEqual(reopened.conversation?.id, published)
        XCTAssertEqual(fixture.worker.openCommand?.threadID, published.uuidString)
        XCTAssertEqual(fixture.worker.openCommand?.forkMessageID, fixture.history[3].id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.historyFile(published).path))
        XCTAssertTrue(fixture.worker.prompts.isEmpty)

        var inherited = Array(fixture.history.prefix(4))
        inherited[3].canFork = false
        inherited[3].incompleteReply = .interrupted
        fixture.worker.onEvent?(.ready(inherited))
        let origin = try XCTUnwrap(reopened.conversation?.forkOrigin)
        XCTAssertEqual(origin.messageID, inherited[3].id)
        reopened.forkResponse(origin.messageID)
        XCTAssertTrue(fixture.worker.forks.isEmpty)
        reopened.openForkLink(origin.threadID)
        fixture.worker.onEvent?(.ready(inherited + fixture.history.suffix(2)))
        XCTAssertEqual(reopened.conversation?.id, fixture.parentID)
        reopened.openForkLink(published)
        XCTAssertEqual(fixture.worker.openCommand?.forkMessageID, origin.messageID)
    }
}

@MainActor
private final class ForkFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let parentID = UUID()
    let projectID = UUID()
    let queued = QueuedMessage(id: UUID(), text: "Waiting in parent")
    let history = (1...3).flatMap { turn in
        [ChatMessage(id: UUID().uuidString, role: .user, text: "Question \(turn)"),
         ChatMessage(id: UUID().uuidString, role: .assistant, text: "Reply \(turn)", canFork: true)]
    }
    private(set) var worker = ForkFixtureWorker()

    var checkout: URL { root.appendingPathComponent("checkout", isDirectory: true) }
    var index: URL { root.appendingPathComponent("workspace.json") }

    init() throws {
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let parent = Conversation(id: parentID, title: "Parent", location: .worktree(path: checkout.path, base: "main"),
                                  isDraft: false, composerText: "Parent draft", queuedMessages: [queued])
        let project = Project(id: projectID, path: root.path, title: "Project",
                              conversations: [parent], selectedConversation: parentID, createdAt: Date())
        try WorkspaceStore(root: root).save(Workspace(projects: [project], selectedProject: projectID))
        try FileManager.default.createDirectory(at: historyFile(parentID).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try writeHistory(parentID)
    }

    func open(relaunch: Bool = false) -> WorkspaceModel {
        let model = WorkspaceModel(root: root, keychainService: "dev.tncode.fork.fixture",
                                   readCredential: { _ in "test-key" }, makeProcess: { _, _ in
            self.worker = ForkFixtureWorker()
            return self.worker
        })
        if relaunch { model.start() }
        else {
            model.connect()
            worker.onEvent?(.ready(history))
        }
        return model
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func savedWorkspace() throws -> Workspace {
        try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
    }

    func historyFile(_ id: UUID) -> URL {
        WorkspaceStore.historyComponents(project: projectID, conversation: id).reduce(root) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.appendingPathComponent(id.uuidString + ".jsonl")
    }

    func writeHistory(_ id: UUID) throws {
        try Data("Fixture history".utf8).write(to: historyFile(id))
    }

    func leaveForkJournal(for id: UUID, publish: Bool) throws {
        let store = try WorkspaceStore(root: root)
        var workspace = try store.load()
        try store.prepareHistory(.init(projectID: projectID, threadID: id), in: workspace)
        try writeHistory(id)
        if publish {
            workspace.projects[0].conversations.append(Conversation(
                id: id, title: "Parent fork", isDraft: false,
                forkOrigin: .init(threadID: parentID, messageID: history[3].id)
            ))
            workspace.projects[0].selectedConversation = id
            try store.save(workspace)
        }
    }
}

@MainActor
private final class ForkFixtureWorker: PiConnection {
    var onEvent: ((PiEvent) -> Void)?
    var onClose: (() -> Void)?
    private(set) var openCommand: OpenConversation?
    private(set) var forks: [ForkConversation] = []
    private(set) var prompts: [SendPrompt] = []

    func send(_ command: any Encodable) throws {
        if let command = command as? OpenConversation { openCommand = command }
        if let command = command as? ForkConversation { forks.append(command) }
        if let command = command as? SendPrompt { prompts.append(command) }
    }

    func close() {
        onEvent = nil
        onClose = nil
    }
}
