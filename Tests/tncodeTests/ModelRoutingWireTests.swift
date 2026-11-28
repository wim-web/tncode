import XCTest
@testable import tncode

@MainActor
final class ModelRoutingWireTests: XCTestCase {
    func testPromptLinksUseTheDestinationCatalogAndSendOnlyFromTheComposer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["PI_ROUTING_OWNER"], let foreign = env["PI_ROUTING_OTHER"],
              let node = env["PI_ROUTING_NODE"], let worker = env["PI_ROUTING_WORKER"] else {
            throw XCTSkip("Run scripts/verify-model-routing.mjs for the loopback integration.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceModel = ModelSettings(provider: .local, model: "route-foreign", endpoint: foreign)
        let sourceDraft = Conversation(id: UUID(), title: "Original", isDraft: true, composerText: "Keep editing")
        let source = Project(id: UUID(), path: root.path, title: "Source", conversations: [sourceDraft],
                             selectedConversation: sourceDraft.id, modelOverride: sourceModel)
        try WorkspaceStore(root: root).save(.init(projects: [source], selectedProject: source.id, welcomeCompleted: true))
        let owner = ModelSettings(provider: .local, model: "route-b", endpoint: endpoint)
        var reads: [String] = []
        let model = WorkspaceModel(root: root, keychainService: "unused", credentialExists: {
            $0 == owner.account || $0 == "openai"
        }, readCredential: { account in
            reads.append(account)
            return account == owner.account ? "routing-fixture-key" : nil
        }, makeProcess: { config, cwd in
            try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: node), arguments: [worker])
        })
        defer { model.shutdown() }
        XCTAssertNil(model.startupFailure)

        func waitForReady() async throws {
            for _ in 0..<500 {
                if let error = model.error { throw WorkspaceError(error) }
                if model.phase == .ready { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw WorkspaceError("Timed out opening \(model.effectiveModel.model) (\(model.phase)).")
        }
        func openScratch(_ hint: String) throws {
            model.promptLinkReview = nil
            let url = try XCTUnwrap(URL(string: "tncode://new/v1?prompt=prompt-link-marker&" + hint))
            XCTAssertTrue(model.openPromptLink(url))
            try model.openPromptLinkDraft(XCTUnwrap(model.promptLinkReview))
            XCTAssertTrue(model.project?.isScratch == true)
            XCTAssertEqual(model.draft, "prompt-link-marker")
        }
        model.connect()
        try await waitForReady()
        XCTAssertFalse(reads.contains(owner.account))
        reads.removeAll()
        XCTAssertTrue(model.composerModelOptions().contains { $0.settings.model == "gpt-5" && $0.unavailableReason == nil })
        try openScratch("provider=openai&model=gpt-5")
        try await waitForReady()
        XCTAssertEqual(model.effectiveModel.model, "gpt-5")
        XCTAssertEqual(model.conversation?.modelSelection?.account, "openai")

        try model.applySettings(owner, in: .workspace, newKey: "", removeKey: false)
        try openScratch("provider=local&model=route-foreign")
        try await waitForReady()
        XCTAssertNil(model.conversation?.modelSelection)
        XCTAssertEqual(model.effectiveModel, owner)
        XCTAssertTrue(model.messages.isEmpty)
        model.send()
        for _ in 0..<500 where model.messages.last?.role != .assistant {
            if let error = model.error { throw WorkspaceError(error) }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(model.messages.last?.text, "Fixture reply")
        XCTAssertTrue(reads.contains(owner.account))
        XCTAssertFalse(reads.contains(sourceModel.account))
        let restored = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
        XCTAssertEqual(restored.projects.first?.conversations.first?.composerText, sourceDraft.composerText)
        XCTAssertEqual(restored.projects.first?.modelOverride, sourceModel)
    }

    func testInheritedRouteSurvivesSettingsResetRelaunchAndSideChat() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["PI_ROUTING_OWNER"], let otherEndpoint = env["PI_ROUTING_OTHER"],
              let node = env["PI_ROUTING_NODE"], let worker = env["PI_ROUTING_WORKER"] else {
            throw XCTSkip("Run scripts/verify-model-routing.mjs for the loopback integration.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("store")
        let first = ModelSettings(provider: .local, model: "route-a", endpoint: endpoint)
        var second = first
        second.model = "route-b"
        let other = ModelSettings(provider: .local, model: "route-foreign", endpoint: otherEndpoint)
        let submitted = Conversation(id: UUID(), title: "New thread", isDraft: true)
        let draft = Conversation(id: UUID(), title: "Unsent", isDraft: true, composerText: "Keep this draft")
        let project = Project(id: UUID(), path: root.path, title: "Fixture", conversations: [submitted, draft],
                              selectedConversation: submitted.id)
        try WorkspaceStore(root: directory).save(.init(projects: [project], selectedProject: project.id,
                                                       model: first, welcomeCompleted: true))
        func launch() -> WorkspaceModel {
            let model = WorkspaceModel(root: directory, keychainService: UUID().uuidString,
                                       credentialExists: { $0 == first.account },
                                       readCredential: { $0 == first.account ? "routing-fixture-key" : nil },
                                       makeProcess: { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: node), arguments: [worker])
            })
            model.connect()
            return model
        }
        func wait(_ model: WorkspaceModel, _ condition: () -> Bool) async throws {
            for _ in 0..<500 {
                if let error = model.error { throw WorkspaceError(error) }
                if condition() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw WorkspaceError("Timed out waiting for the inherited model in \(model.phase).")
        }
        func send(_ text: String, through model: WorkspaceModel, on route: ModelSettings) async throws {
            guard model.effectiveModel == route else {
                throw WorkspaceError("The expected model was not selected before sending the fixture prompt.")
            }
            let count = model.messages.count
            model.draft = text
            model.send()
            try await wait(model) { model.phase == .ready && model.messages.count == count + 2 }
        }
        do {
            let model = launch()
            try await wait(model) { model.phase == .ready }
            try await send("inherited-first-marker", through: model, on: first)
            XCTAssertNil(model.conversation?.modelSelection)
            XCTAssertEqual(model.conversation?.historyModel, first)
            try model.applySettings(second, in: .project(project.id), newKey: "", removeKey: false)
            try await wait(model) { model.phase == .ready }
            try await send("inherited-model-marker", through: model, on: second)
            model.selectConversation(draft.id, in: project.id)
            try await wait(model) { model.phase == .ready && model.conversation?.id == draft.id }
            try model.applySettings(other, in: .workspace, newKey: "", removeKey: false)
            try model.resetProjectModel(project.id)
            try await wait(model) { model.phase == .ready }
            XCTAssertEqual(model.draft, draft.composerText)
            XCTAssertEqual(model.effectiveModel, other)
            XCTAssertNil(model.conversation?.historyModel)
            XCTAssertTrue(model.terminate())
        }
        let model = launch()
        defer { _ = model.terminate() }
        try await wait(model) { model.phase == .ready }
        XCTAssertEqual(model.conversation?.id, draft.id)
        XCTAssertEqual(model.draft, draft.composerText)
        model.selectConversation(submitted.id, in: project.id)
        try await wait(model) { model.phase == .ready && model.conversation?.id == submitted.id }
        XCTAssertEqual(model.messages.filter { $0.role == .user }.map(\.text), ["inherited-first-marker", "inherited-model-marker"])
        XCTAssertTrue(model.composerModelOptions().contains { $0.id == second.identity && $0.unavailableReason == nil })
        XCTAssertFalse(model.canUseInheritedComposerModel)
        try await send("inherited-resumed-marker", through: model, on: second)
        model.startSideChat(in: submitted.id)
        let scope = try XCTUnwrap(model.sideChatToOpen?.scope)
        let child = try XCTUnwrap(model.sideChat(scope))
        guard child.model == second else { return XCTFail("Side chat must use the parent’s account.") }
        try await wait(model) { model.sideChatSession(scope)?.phase == .ready }
        model.editSideChat("inherited-side-marker", in: scope)
        model.sendSideChat(scope)
        try await wait(model) { model.sideChatSession(scope)?.messages.last?.role == .assistant }
        XCTAssertEqual(model.messages.filter { $0.role == .user }.count, 3)
    }

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
