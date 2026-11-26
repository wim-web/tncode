import XCTest
@testable import PiWorkspace

final class QueuedMessageTests: XCTestCase {
    @MainActor
    func testQueueEditsPreserveDraftAndDrainInOrderAfterTheActiveTurn() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let model = fixture.open()
        let worker = fixture.worker
        let active = try worker.start("Active", in: model)
        fixture.append(["First", "Second", "Remove", "Fourth"], in: model)
        let items = model.queuedMessages
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(worker.prompts.count, 1)

        model.draft = "My unfinished draft"
        model.editQueuedMessage(items[1].id)
        model.draft = "Discard this edit"
        model.cancelQueuedMessageEdit()
        XCTAssertEqual(model.draft, "My unfinished draft")
        XCTAssertEqual(model.queuedMessages, items)
        model.editQueuedMessage(items[1].id)
        model.draft = "Edited"
        model.updateQueuedMessage()
        XCTAssertEqual(model.draft, "My unfinished draft")
        XCTAssertEqual(model.queuedMessages.map(\.id), items.map(\.id))
        model.removeQueuedMessage(items[2].id)
        model.moveQueuedMessageToFront(items[3].id)
        XCTAssertEqual(model.queuedMessages.map(\.text), ["Fourth", "First", "Edited"])

        worker.finish(active)
        let fourth = try XCTUnwrap(worker.prompts.last)
        XCTAssertEqual(fourth.queuedID, items[3].id)
        XCTAssertNotEqual(fourth.turnID, active.turnID)
        worker.finish(fourth)
        let first = try XCTUnwrap(worker.prompts.last)
        worker.finish(first)
        let edited = try XCTUnwrap(worker.prompts.last)
        worker.finish(edited)
        XCTAssertEqual(worker.prompts.map(\.text), ["Active", "Fourth", "First", "Edited"])
        XCTAssertEqual(model.draft, "My unfinished draft")
        XCTAssertNil(model.conversation?.queuedMessages)
        XCTAssertEqual(model.phase, .ready)
    }

    @MainActor
    func testPromotingAnItemUsesTheActiveTurnAndStopPausesTheRest() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let model = fixture.open()
        let worker = fixture.worker
        let active = try worker.start("Active", in: model)
        fixture.append(["Keep", "Promote", "Start this one"], in: model)
        let items = model.queuedMessages
        worker.emit(.inputMode(turnID: active.turnID, .steer))

        model.draft = "Direct steer"
        model.queueDraft(steering: true)
        model.sendQueuedMessageNow(items[1].id)
        XCTAssertEqual(worker.queuedInputs.map(\.text), ["Direct steer", "Promote"])
        XCTAssertEqual(worker.queuedInputs.map(\.turnID), [active.turnID, active.turnID])
        XCTAssertEqual(worker.queuedInputs.last?.queuedID, items[1].id)
        XCTAssertEqual(model.queuedMessages.map(\.id), [items[0].id, items[2].id])
        model.cancel()
        XCTAssertEqual(worker.commands.compactMap { $0 as? CancelPrompt }.last?.turnID, active.turnID)
        worker.finish(active)
        XCTAssertTrue(model.queuePaused)
        XCTAssertEqual(model.queuedMessages, items + [QueuedMessage(id: worker.queuedInputs[0].queuedID, text: "Direct steer")])

        model.sendQueuedMessageNow(items[2].id)
        let picked = try XCTUnwrap(worker.prompts.last)
        XCTAssertEqual(picked.queuedID, items[2].id)
        worker.finish(picked, recorded: false, error: "Fixture could not start the model.")
        XCTAssertTrue(model.queuePaused)
        XCTAssertEqual(worker.prompts.count, 2)
        XCTAssertEqual(model.queuedMessages.first(where: { $0.id == picked.queuedID })?.text, picked.text)
        model.resumeQueuedMessages()
        XCTAssertEqual(worker.prompts.last?.queuedID, items[0].id)
    }

    @MainActor
    func testRestartReconcilesRecordedIDsAndKeepsUnconfirmedMessagesInTheirThread() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        var model: WorkspaceModel? = fixture.open()
        let oldWorker = fixture.worker
        let active = try oldWorker.start("Active", in: XCTUnwrap(model))
        fixture.append(["Same text", "Same text", "Worker never recorded this"], in: try XCTUnwrap(model))
        let ids = try XCTUnwrap(model).queuedMessages.map(\.id)
        model?.selectConversation(fixture.other, in: fixture.project)
        XCTAssertEqual(model?.conversation?.id, fixture.thread)
        oldWorker.finish(active)
        let first = try XCTUnwrap(oldWorker.prompts.last)
        XCTAssertEqual(first.queuedID, ids[0])
        let saved = [ChatMessage(id: "recorded", role: .user, text: first.text, queuedID: ids[0])]
        model?.shutdown()
        model = nil

        let reopened = fixture.open(history: saved, restart: true)
        let restartedWorker = fixture.worker
        XCTAssertEqual(reopened.conversation?.id, fixture.thread)
        XCTAssertEqual(reopened.queuedMessages.map(\.id), Array(ids.dropFirst()))
        XCTAssertTrue(reopened.queuePaused)
        XCTAssertTrue(restartedWorker.prompts.isEmpty)
        reopened.selectConversation(fixture.other, in: fixture.project)
        fixture.worker.emit(.ready([]))
        XCTAssertTrue(reopened.queuedMessages.isEmpty)
        reopened.sendQueuedMessageNow(ids[1])
        XCTAssertTrue(fixture.worker.prompts.isEmpty)
        reopened.selectConversation(fixture.thread, in: fixture.project)
        fixture.worker.emit(.ready(saved))
        XCTAssertEqual(reopened.queuedMessages.map(\.id), Array(ids.dropFirst()))

        reopened.resumeQueuedMessages()
        XCTAssertEqual(fixture.worker.prompts.last?.queuedID, ids[1])
        let interruptedWorker = fixture.worker
        interruptedWorker.onClose?()
        XCTAssertEqual(reopened.phase, .closed)
        XCTAssertTrue(reopened.queuePaused)
        XCTAssertEqual(reopened.queuedMessages.map(\.id), Array(ids.dropFirst()))
        reopened.connect()
        fixture.worker.emit(.ready(saved))
        XCTAssertTrue(fixture.worker.prompts.isEmpty)
        reopened.resumeQueuedMessages()
        XCTAssertEqual(fixture.worker.prompts.last?.queuedID, ids[1])
    }

    @MainActor
    func testCompactionSkipOnlySendsChosenMessageAfterAcknowledgement() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let model = fixture.open()
        let worker = fixture.worker
        let active = try worker.start("Active", in: model)
        fixture.append(["First", "Skip with this"], in: model)
        let items = model.queuedMessages
        worker.emit(.inputMode(turnID: UUID(), .compacting))
        XCTAssertFalse(model.canSkipCompaction)
        worker.emit(.inputMode(turnID: active.turnID, .compacting))
        model.sendQueuedMessageNow(items[1].id)
        XCTAssertEqual(worker.queuedInputs.last?.type, .skipCompaction)
        XCTAssertEqual(worker.prompts.count, 1)
        worker.emit(.compactionSkipped(turnID: active.turnID, queuedID: items[1].id))
        worker.finish(active)
        XCTAssertEqual(worker.prompts.last?.queuedID, items[1].id)
        XCTAssertEqual(worker.prompts.last?.skipCompaction, true)
        XCTAssertEqual(model.queuedMessages, [items[0]])
    }

    @MainActor
    func testRejectedSteerAndCredentialTextStayOutOfTheModel() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let model = fixture.open()
        let worker = fixture.worker
        let active = try worker.start("Active", in: model)
        fixture.append([fixture.key, "Steer this"], in: model)
        let item = try XCTUnwrap(model.queuedMessages.first)
        XCTAssertEqual(model.queuedMessages.count, 1)
        model.editQueuedMessage(item.id)
        model.draft = "Do not save \(fixture.key)"
        model.updateQueuedMessage()
        XCTAssertEqual(model.queuedMessages, [item])
        model.cancelQueuedMessageEdit()
        XCTAssertFalse(try String(contentsOf: fixture.root.appendingPathComponent("workspace.json"),
                                  encoding: .utf8).contains(fixture.key))

        worker.emit(.inputMode(turnID: active.turnID, .steer))
        model.sendQueuedMessageNow(item.id)
        XCTAssertTrue(model.queuedMessages.isEmpty)
        worker.emit(.queueRejected(turnID: active.turnID, queuedID: item.id))
        worker.finish(active)
        XCTAssertTrue(model.queuePaused)
        XCTAssertEqual(model.queuedMessages, [item])
        XCTAssertEqual(worker.prompts.count, 1)
    }
}

@MainActor
private final class QueueFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let thread = UUID()
    let other = UUID()
    let project = UUID()
    let key = UUID().uuidString
    private(set) var worker = QueueWorker()

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("""
        {
          "projects": [{
            "id": "\(project)", "path": "\(root.path)", "title": "Fixture", "allowEdits": false,
            "selectedConversation": "\(thread)", "conversations": [
              {"id": "\(thread)", "title": "Owns queue", "archived": false},
              {"id": "\(other)", "title": "Other thread", "archived": false}
            ]
          }],
          "selectedProject": "\(project)",
          "model": {"provider": "local", "model": "fixture", "endpoint": "http://127.0.0.1:12345/v1", "contextWindow": 8192}
        }
        """.utf8).write(to: root.appendingPathComponent("workspace.json"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func open(history: [ChatMessage] = [], restart: Bool = false) -> WorkspaceModel {
        let model = WorkspaceModel(root: root, keychainService: "dev.piworkspace.queue.fixture",
                                   readCredential: { _ in self.key }, makeProcess: { _, _ in
            self.worker = QueueWorker()
            return self.worker
        })
        if restart { model.start() } else { model.connect() }
        worker.emit(.ready(history))
        return model
    }

    func append(_ texts: [String], in model: WorkspaceModel) {
        for text in texts {
            model.draft = text
            model.queueDraft()
        }
    }
}

@MainActor
private final class QueueWorker: PiConnection {
    var onEvent: ((PiEvent) -> Void)?
    var onClose: (() -> Void)?
    private(set) var commands: [any Encodable] = []
    private var history: [ChatMessage] = []

    var prompts: [SendPrompt] { commands.compactMap { $0 as? SendPrompt } }
    var queuedInputs: [SendQueuedInput] { commands.compactMap { $0 as? SendQueuedInput } }

    func send(_ command: any Encodable) throws { commands.append(command) }
    func close() {
        onEvent = nil
        onClose = nil
    }
    func emit(_ event: PiEvent) { onEvent?(event) }

    func start(_ text: String, in model: WorkspaceModel) throws -> SendPrompt {
        model.draft = text
        model.send()
        let prompt = try XCTUnwrap(prompts.last)
        history.append(ChatMessage(id: prompt.turnID.uuidString, role: .user, text: text))
        emit(.history(history))
        return prompt
    }

    func finish(_ prompt: SendPrompt, recorded: Bool = true, error: String? = nil) {
        if recorded && !history.contains(where: { $0.id == prompt.turnID.uuidString }) {
            history.append(ChatMessage(id: prompt.turnID.uuidString, role: .user, text: prompt.text,
                                       queuedID: prompt.queuedID))
        }
        emit(.finished(turnID: prompt.turnID, history, error: error))
    }
}
