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
    func testLateFinishAndOldStopDeadlinesStayWithTheirTurn() throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let model = fixture.open()
        defer { model.shutdown() }
        let oldWorker = fixture.worker
        let originalThread = try XCTUnwrap(model.conversation?.id)
        let oldEvent = try XCTUnwrap(oldWorker.onEvent)
        let first = try oldWorker.start("First", in: model)
        model.cancel()
        oldWorker.finish(first)
        XCTAssertEqual(model.phase, .ready)
        model.selectConversation(fixture.other, in: fixture.project)
        let worker = fixture.worker
        worker.emit(.ready([]))
        let second = try worker.start("Second", in: model)
        model.cancel()
        worker.finish(second)
        let third = try worker.start("Third", in: model)
        fixture.append(["Wait for resume"], in: model)
        model.cancel()

        oldEvent(.finished(turnID: third.turnID, [], error: "Old helper"))
        worker.finish(second)
        model.stopAcknowledgementExpired(turnID: first.turnID, threadID: originalThread, from: oldWorker)
        model.stopAcknowledgementExpired(turnID: second.turnID, threadID: fixture.other, from: worker)
        XCTAssertEqual(model.phase, .stopping)
        XCTAssertNil(model.error)
        model.stopAcknowledgementExpired(turnID: third.turnID, threadID: fixture.other, from: worker)
        XCTAssertEqual(model.phase, .stopTimedOut)
        worker.finish(third)
        model.cancel()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.queuePaused)
        XCTAssertEqual(model.queuedMessages.map(\.text), ["Wait for resume"])
        XCTAssertEqual(worker.prompts.map(\.text), ["Second", "Third"])
        XCTAssertEqual(worker.commands.compactMap { ($0 as? CancelPrompt)?.turnID }, [second.turnID, third.turnID])
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
    func testSubmittedThreadKeepsAccountAfterStopAndFailedReopen() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        var owner: ModelSettings
        do {
            let model = fixture.open()
            let scope = try XCTUnwrap(model.draftProjectScope)
            let inherited = try XCTUnwrap(model.composerModelOptions().first)
            owner = inherited.settings
            owner.endpoint += "/other-account"
            let explicit = ComposerModelOption(settings: owner, name: "Owner", unavailableReason: nil)
            XCTAssertTrue(model.chooseComposerModel(explicit, in: scope))
            let worker = fixture.worker
            worker.emit(.ready([]))
            let active = try worker.start("Owner's history", in: model)
            fixture.append(["After Stop"], in: model)
            XCTAssertFalse(model.chooseComposerModel(inherited, in: scope))
            XCTAssertFalse(model.chooseComposerModel(nil, in: scope))
            model.cancel()
            worker.finish(active)
            XCTAssertTrue(model.queuePaused)
            XCTAssertFalse(model.canUseInheritedComposerModel)
            XCTAssertFalse(model.chooseComposerModel(inherited, in: scope))
            XCTAssertFalse(model.chooseComposerModel(nil, in: scope))
            XCTAssertEqual(model.effectiveModel, owner)
            model.shutdown()
        }

        // Fail before ready, when a fresh model has not received any history.
        let reopened = WorkspaceModel(root: fixture.root, keychainService: "fixture", credentialExists: { _ in true },
                                      readCredential: { _ in fixture.key }, makeProcess: { _, _ in
            throw WorkspaceError("Fixture could not open the worker.")
        })
        reopened.connect()
        XCTAssertEqual(reopened.phase, .closed)
        XCTAssertTrue(reopened.messages.isEmpty)
        let scope = try XCTUnwrap(reopened.draftProjectScope)
        XCTAssertFalse(reopened.canUseInheritedComposerModel)
        XCTAssertFalse(reopened.chooseComposerModel(nil, in: scope))
        let inherited = try XCTUnwrap(reopened.composerModelOptions().first { $0.settings.account != owner.account })
        XCTAssertNotNil(inherited.unavailableReason)
        XCTAssertFalse(reopened.chooseComposerModel(inherited, in: scope))
        XCTAssertEqual(reopened.conversation?.modelSelection, owner)
        XCTAssertEqual(reopened.queuedMessages.map(\.text), ["After Stop"])

        var sameAccount = owner
        sameAccount.model = "replacement-model"
        let replacement = ComposerModelOption(settings: sameAccount, name: sameAccount.model, unavailableReason: nil)
        XCTAssertTrue(reopened.chooseComposerModel(replacement, in: scope))
        XCTAssertEqual(reopened.conversation?.modelSelection, sameAccount)
        XCTAssertFalse(reopened.chooseComposerModel(nil, in: scope))
    }

    @MainActor
    func testCompactionReopensChosenModelAndKeepsSelectedRowAcrossFailure() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let model = fixture.open()
        defer { model.shutdown() }
        let first = fixture.worker
        let active = try first.start("Active", in: model)
        fixture.append(["Wait", "Selected"], in: model)
        let items = model.queuedMessages
        var next = model.effectiveModel
        next.model = "next-model"
        let choice = ComposerModelOption(settings: next, name: next.model, unavailableReason: nil)
        XCTAssertTrue(model.chooseComposerModel(choice, in: try XCTUnwrap(model.draftProjectScope)))
        first.emit(.inputMode(turnID: active.turnID, .compacting))
        model.sendQueuedMessageNow(items[1].id)
        first.emit(.compactionSkipped(turnID: active.turnID, queuedID: items[1].id))
        first.finish(active)
        XCTAssertEqual(first.prompts.map(\.text), ["Active"])
        XCTAssertEqual(model.phase, .connecting)
        fixture.worker.onClose?()
        XCTAssertTrue(model.queuePaused)
        XCTAssertEqual(model.queuedMessages.map(\.id), items.map(\.id))
        model.connect()
        let reopened = fixture.worker
        XCTAssertEqual(reopened.commands.compactMap { $0 as? OpenConversation }.first?.config, next)
        reopened.emit(.ready(model.messages))
        XCTAssertTrue(reopened.prompts.isEmpty)
        model.sendQueuedMessageNow(items[1].id)
        let selected = try XCTUnwrap(reopened.prompts.first)
        XCTAssertEqual(selected.queuedID, items[1].id)
        XCTAssertEqual(selected.skipCompaction, true)
        model.cancel()
        reopened.finish(selected)
        XCTAssertTrue(model.queuePaused)
        XCTAssertEqual(reopened.prompts.count, 1)
        XCTAssertEqual(model.queuedMessages.map(\.id), [items[0].id])
        XCTAssertEqual(model.messages.filter { $0.queuedID == items[1].id }.count, 1)
    }

    @MainActor
    func testStopAfterSkipAcknowledgementKeepsQueuePausedOnNewModel() async throws {
        let fixture = try QueueFixture()
        defer { fixture.cleanUp() }
        let model = fixture.open()
        defer { model.shutdown() }
        let worker = fixture.worker
        let first = try worker.start("Active", in: model)
        fixture.append(["First", "Selected"], in: model)
        let ids = model.queuedMessages.map(\.id)
        let selected = try XCTUnwrap(ids.last)
        var b = model.effectiveModel
        b.model = "model-b"
        XCTAssertTrue(model.chooseComposerModel(.init(settings: b, name: b.model, unavailableReason: nil),
                                                in: try XCTUnwrap(model.draftProjectScope)))
        worker.emit(.inputMode(turnID: first.turnID, .compacting))
        model.sendQueuedMessageNow(selected)
        worker.emit(.compactionSkipped(turnID: first.turnID, queuedID: selected))
        model.cancel()
        worker.finish(first)
        XCTAssertEqual(model.phase, .connecting)
        fixture.worker.emit(.ready(model.messages))
        XCTAssertTrue(model.queuePaused)
        XCTAssertEqual(model.queuedMessages.map(\.id), ids)
        XCTAssertEqual(worker.prompts.count, 1)
        XCTAssertTrue(fixture.worker.prompts.isEmpty)
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
                                   credentialExists: { _ in true }, readCredential: { _ in self.key }, makeProcess: { _, _ in
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
