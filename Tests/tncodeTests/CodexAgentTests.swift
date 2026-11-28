import XCTest
@testable import tncode

@MainActor
final class CodexAgentTests: XCTestCase {
    func testChangingAgentKeepsSubmittedPiHistoryOnItsOriginalRoute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pi = ModelSettings(provider: .openai, model: "gpt-5-mini")
        let submitted = Conversation(id: UUID(), title: "Previous Pi thread", isDraft: false, composerText: "Keep this draft")
        let project = Project(id: UUID(), path: root.path, title: "Project", conversations: [submitted], selectedConversation: submitted.id)
        try WorkspaceStore(root: root).save(.init(projects: [project], selectedProject: project.id, model: pi, welcomeCompleted: true))
        let piWorker = RecordingWorker(), codexWorker = RecordingWorker()
        let model = WorkspaceModel(root: root, keychainService: "unused", piAgentDirectory: root.appendingPathComponent("empty"),
                                   credentialExists: { _ in false }, readCredential: { _ in nil },
                                   makeProcess: { _, _ in piWorker }, makeCodexProcess: { _, _ in codexWorker })
        defer { _ = model.terminate() }
        model.start()
        XCTAssertEqual(piWorker.opens.first?.config, pi)
        try model.applySettings(.codex, in: .workspace, newKey: "", removeKey: false)
        XCTAssertEqual(model.conversation?.id, submitted.id)
        XCTAssertEqual(model.conversation?.historyModel, pi)
        XCTAssertTrue(codexWorker.opens.isEmpty)
        model.startScratchThread()
        XCTAssertEqual(codexWorker.opens.first?.config, .codex)
        model.selectConversation(submitted.id, in: project.id)
        XCTAssertEqual(model.effectiveModel, pi)
        XCTAssertEqual(model.draft, "Keep this draft")
    }

    func testCodexSessionSearchToolsAndHistoryFromSwift() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let node = env["PI_CODEX_NATIVE_NODE"], let worker = env["PI_CODEX_NATIVE_AGENT"],
              let checkout = env["PI_CODEX_NATIVE_CHECKOUT"], env["TNCODE_CODEX_BIN"] != nil else {
            throw XCTSkip("Run verify-codex-agent.mjs with PI_CODEX_XCTEST to use an isolated real Codex session.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        func launch() -> WorkspaceModel {
            WorkspaceModel(root: root, keychainService: "unused", piAgentDirectory: root.appendingPathComponent("empty-pi"),
                           credentialExists: { _ in XCTFail("Unexpected Keychain lookup"); return false },
                           readCredential: { _ in XCTFail("Unexpected Keychain read"); return nil },
                           makeProcess: { _, _ in throw WorkspaceError("Unexpected Pi session") },
                           makeCodexProcess: { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: node), arguments: [worker], codexEnvironment: env)
            })
        }
        func wait(_ model: WorkspaceModel, _ condition: () -> Bool) async throws {
            for _ in 0..<1000 {
                if let error = model.error { throw WorkspaceError(error) }
                if condition() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw WorkspaceError("Timed out waiting for the Codex fixture.")
        }
        let threadID: UUID
        do {
            let model = launch()
            XCTAssertEqual(model.workspace.model, .codex)
            try model.openProject(URL(fileURLWithPath: checkout))
            try await wait(model) { model.phase == .ready && model.codexCapabilities?.computerUse == true }
            XCTAssertEqual(model.codexCapabilities?.webSearch, .live)
            threadID = try XCTUnwrap(model.conversation?.id)
            model.draft = "Codex fixture first prompt"
            model.send()
            try await wait(model) { model.phase == .ready && model.messages.count == 2 }
            XCTAssertEqual(model.messages.map(\.text), ["Codex fixture first prompt", "Codex fixture first reply."])
            XCTAssertEqual(model.conversation?.historyModel, .codex)
            model.draft = "Unsent follow-up"
            XCTAssertTrue(model.terminate())
        }

        let reopened = launch()
        defer { _ = reopened.terminate() }
        reopened.start()
        try await wait(reopened) { reopened.phase == .ready && reopened.messages.count == 2 }
        XCTAssertEqual(reopened.conversation?.id, threadID)
        XCTAssertEqual(reopened.messages.last?.text, "Codex fixture first reply.")
        XCTAssertEqual(reopened.draft, "Unsent follow-up")
    }

    private final class RecordingWorker: PiConnection {
        var onEvent: ((PiEvent) -> Void)?
        var onClose: (() -> Void)?
        var opens: [OpenConversation] = []
        func send(_ command: any Encodable) throws {
            if let command = command as? OpenConversation {
                opens.append(command)
                onEvent?(.ready([]))
            }
        }
        func close() { onEvent = nil; onClose = nil }
    }
}
