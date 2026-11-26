import XCTest
@testable import PiWorkspace

@MainActor
final class ModelRoutingWireTests: XCTestCase {
    func testHistoryAndCompactionSelectionStayOnTheChosenRoute() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["PI_ROUTING_OWNER"], let foreignEndpoint = env["PI_ROUTING_OTHER"],
              let node = env["PI_ROUTING_NODE"], let worker = env["PI_ROUTING_WORKER"],
              let release = env["PI_ROUTING_RELEASE"] else {
            throw XCTSkip("Run scripts/verify-model-routing.mjs for the loopback integration.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = ModelSettings(provider: .local, model: "route-a", endpoint: endpoint, contextWindow: 65_536)
        var b = a
        b.model = "route-b"
        var foreign = b
        foreign.model = "route-foreign"
        foreign.endpoint = foreignEndpoint
        let thread = Conversation(id: UUID(), title: "Fixture", isDraft: true, modelSelection: a)
        let normal = Conversation(id: UUID(), title: "Ordinary queue", isDraft: true, modelSelection: a)
        let project = Project(id: UUID(), path: root.path, title: "Fixture", conversations: [thread, normal],
                              selectedConversation: thread.id, modelOverride: foreign)
        try WorkspaceStore(root: store).save(Workspace(projects: [project], selectedProject: project.id,
                                                       model: b, welcomeCompleted: true))
        let model = WorkspaceModel(root: store, keychainService: UUID().uuidString, credentialExists: { _ in true },
                                   readCredential: { _ in "routing-fixture-key" }, makeProcess: { config, cwd in
            try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: node), arguments: [worker])
        })
        defer { model.shutdown() }
        func wait(_ stage: String, until done: () -> Bool) async throws {
            for _ in 0..<500 {
                if let error = model.error { throw WorkspaceError(error) }
                if done() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw WorkspaceError("Timed out waiting for \(stage) (\(model.phase)).")
        }
        model.connect()
        try await wait("owner ready") { model.phase == .ready }
        model.draft = "owner-history-marker"
        model.send()
        try await wait("history receipt") { model.phase == .ready && model.messages.count == 2 }
        let scope = try XCTUnwrap(model.draftProjectScope)
        let foreignChoice = try XCTUnwrap(model.composerModelOptions().first { $0.id == foreign.identity })
        XCTAssertNotNil(foreignChoice.unavailableReason)
        XCTAssertFalse(model.chooseComposerModel(foreignChoice, in: scope))
        XCTAssertFalse(model.chooseComposerModel(nil, in: scope))
        try await wait("ready for the next turn") { model.phase == .ready }

        model.draft = "compaction-marker\n" + String(repeating: "context ", count: 14_000)
        model.send()
        try await wait("active compaction") { model.canSkipCompaction }
        let sameAccount = try XCTUnwrap(model.composerModelOptions().first { $0.id == b.identity })
        XCTAssertTrue(model.chooseComposerModel(sameAccount, in: scope))
        for text in ["queue-head-marker", "skip-selected-marker"] {
            model.draft = text
            model.queueDraft()
        }
        let queue = model.queuedMessages
        let selected = try XCTUnwrap(queue.last)
        model.sendQueuedMessageNow(selected.id)
        try await wait("both queued receipts") { model.phase == .ready && model.queuedMessages.isEmpty }
        XCTAssertEqual(model.messages.compactMap(\.queuedID), queue.reversed().map(\.id))
        XCTAssertEqual(model.effectiveModel, b)

        model.selectConversation(normal.id, in: project.id)
        try await wait("ordinary queue ready") { model.phase == .ready && model.conversation?.id == normal.id }
        model.draft = "normal-active-marker"
        model.send()
        try await wait("ordinary turn in progress") { model.phase == .running && model.canChooseComposerModel }
        let choice = try XCTUnwrap(model.composerModelOptions().first { $0.id == b.identity })
        XCTAssertTrue(model.chooseComposerModel(choice, in: try XCTUnwrap(model.draftProjectScope)))
        model.draft = "normal-queued-marker"
        model.queueDraft()
        let ordinaryID = try XCTUnwrap(model.queuedMessages.first?.id)
        try Data().write(to: URL(fileURLWithPath: release))
        try await wait("ordinary queue drained") { model.phase == .ready && model.queuedMessages.isEmpty }
        XCTAssertEqual(model.messages.compactMap(\.queuedID), [ordinaryID])
    }
}
