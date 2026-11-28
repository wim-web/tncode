import AppKit
import SwiftUI
import XCTest
@testable import tncode

@MainActor
final class AgentQuestionTests: XCTestCase {
    func testLocalPiQuestionsInAnOffscreenWorkspace() async throws {
        guard let nodePath = ProcessInfo.processInfo.environment["TNCODE_QUESTION_NODE"] else {
            throw XCTSkip("Set TNCODE_QUESTION_NODE to a Node executable to run the loopback test.")
        }
        let node = URL(fileURLWithPath: nodePath)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sdk = package.appendingPathComponent("Sidecar/node_modules/@earendil-works/pi-coding-agent/package.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: sdk)) as? [String: Any]
        XCTAssertEqual(manifest?["version"] as? String, "1.6.1")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-question-\(UUID())")
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = UUID().uuidString
        let server = Process()
        let serverInput = Pipe()
        server.executableURL = node
        server.arguments = [package.appendingPathComponent("scripts/fixtures/agent-questions.mjs").path, root.path]
        server.currentDirectoryURL = root
        server.environment = ["QUESTION_FIXTURE_KEY": key]
        server.standardInput = serverInput
        try server.run()
        defer {
            try? serverInput.fileHandleForWriting.close()
            server.waitUntilExit()
        }
        let endpointFile = root.appendingPathComponent("endpoint")
        try await waitFor("loopback provider to listen") { FileManager.default.fileExists(atPath: endpointFile.path) }
        let endpoint = try String(contentsOf: endpointFile, encoding: .utf8)
        let thread = Conversation(id: UUID(), title: "Agent Question Fixture")
        var project = Project(id: UUID(), path: directory.path, title: "Question fixture",
                              conversations: [thread], selectedConversation: thread.id)
        project.toolPermission = .supervised
        let history: URL
        do {
            let store = try WorkspaceStore(root: root)
            try store.save(Workspace(projects: [project], selectedProject: project.id,
                                     model: ModelSettings(provider: .local, model: "question-fixture",
                                                          endpoint: endpoint, contextWindow: 64_000, localTools: true),
                                     welcomeCompleted: true))
            history = store.history(project: project.id, conversation: thread.id)
        }
        var worker: PiProcess?
        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString, readCredential: { _ in key }) { config, cwd in
            let process = try PiProcess(config: config, cwd: cwd, executable: node,
                                        arguments: [package.appendingPathComponent("Sidecar/worker.mjs").path])
            worker = process
            return process
        }
        XCTAssertNil(model.startupFailure)
        defer { model.shutdown() }

        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()
        let screenLeft = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let window = AgentQuestionOffscreenPanel(contentRect: NSRect(x: screenLeft - 2200, y: 0, width: 1100, height: 760),
                                                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        let host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable))
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: screenLeft - 2200, y: 0))
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)

        func element(_ id: String) -> AnyObject? {
            host.layoutSubtreeIfNeeded()
            var visited = Set<ObjectIdentifier>()
            func visit(_ node: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == id { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let match = visit(child as AnyObject) { return match }
                }
                return nil
            }
            return visit(host)
        }
        func press(_ id: String) async throws {
            try await waitFor("AX press on \(id)") { element(id)?.accessibilityPerformPress?() == true }
        }
        func textField(_ placeholder: String, in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
            return view.subviews.lazy.compactMap { textField(placeholder, in: $0) }.first
        }
        func send(_ prompt: String) async throws -> AgentQuestionScope {
            model.draft = prompt
            model.send()
            try await waitFor(prompt) { model.pendingAgentQuestion != nil || model.error != nil }
            return try XCTUnwrap(model.pendingAgentQuestion?.request.scope, model.error ?? prompt)
        }
        func rawReply(_ scope: AgentQuestionScope, _ decision: AgentQuestionReply.Decision = .decline) throws {
            try XCTUnwrap(worker).send(AgentQuestionReply(scope: scope, decision: decision))
        }

        model.connect()
        try await waitFor("Pi to open the thread") { model.phase == .ready || model.error != nil }
        let answered = try await send("Answer questions")
        try await waitFor("prompt receipt") { model.conversation?.composerSubmission == nil }
        model.draft = "Wait until the question is answered."
        model.queueDraft()
        let waiting = try XCTUnwrap(model.queuedMessages.first)
        XCTAssertFalse(model.canStartEditingQueuedMessage)
        model.editQueuedMessage(waiting.id)
        XCTAssertNil(model.editingQueuedMessageID)
        XCTAssertEqual(model.queuedMessages.first?.text, waiting.text)
        model.removeQueuedMessage(waiting.id)
        model.draft = "unrelated composer draft"
        let invalid = AgentQuestionReply.Answer(questionID: "1", value: .options([99]))
        model.respond(to: answered, with: .answer([invalid]))
        try await waitFor("helper to reject malformed answers") { model.pendingAgentQuestion?.error != nil }
        model.respond(to: answered, with: .answer([.init(questionID: "1", value: .text(key))]))
        XCTAssertEqual(model.pendingAgentQuestion?.error, "Remove the API key from your answer.")

        try await press("agent-question-option-0")
        try await press("agent-question-option-1")
        try await press("agent-question-option-1")
        try await press("agent-question-option-2")
        try await press("agent-question-toggle")
        try await waitFor("the question body to collapse") { element("agent-question-prompt") == nil }
        try await press("agent-question-toggle")
        try await press("agent-question-next")
        try await waitFor("the second question") { element("agent-question-previous") != nil }
        let answerField = try XCTUnwrap(textField("Type an answer", in: host))
        XCTAssertTrue(window.makeFirstResponder(answerField))
        let answerEditor = try XCTUnwrap(answerField.currentEditor() as? NSTextView)
        answerEditor.insertText("Night shift", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(window.makeFirstResponder(host))
        await Task.yield()
        try await press("agent-question-previous")
        try await waitFor("the first answer to restore its choices") {
            element("agent-question-option-0") != nil && textField("Or type an answer", in: host)?.stringValue == ""
        }
        try await press("agent-question-next")
        try await waitFor("the second answer to be restored") {
            element("agent-question-answer") != nil && textField("Type an answer", in: host)?.stringValue == "Night shift"
        }
        try await press("agent-question-submit")
        try await waitFor("separate write approval") { model.pendingToolApproval != nil || model.error != nil }
        let approval = try XCTUnwrap(model.pendingToolApproval, model.error ?? "Write approval")
        let committedFile = directory.appendingPathComponent("approved.txt")
        try rawReply(answered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committedFile.path))
        model.respond(to: approval.requestID, with: .approve)
        try await waitFor("the approved write") { model.phase == .ready }
        XCTAssertEqual(try String(contentsOf: committedFile, encoding: .utf8), "one write\n")
        XCTAssertEqual(model.draft, "unrelated composer draft")

        let dismissed = try await send("Dismiss questions")
        try rawReply(answered)
        try rawReply(.init(threadID: UUID(), turnID: dismissed.turnID, requestID: dismissed.requestID))
        try rawReply(.init(threadID: dismissed.threadID, turnID: answered.turnID, requestID: dismissed.requestID))
        try await press("agent-question-dismiss")
        try await waitFor("dismissal to settle") { model.phase == .ready }
        XCTAssertEqual(model.messages.last?.text, "Questions dismissed.")

        model.setToolPermission(.shellAndEdits)
        try await waitFor("permission change to reconnect") { model.phase == .ready || model.error != nil }
        let stopped = try await send("Stop questions")
        try await press("stop-message")
        model.respond(to: stopped, with: .decline)
        try rawReply(stopped)
        try await waitFor("Stop to settle") { model.phase == .ready }
        XCTAssertNil(model.pendingAgentQuestion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stopped.txt").path))

        let restarted = try await send("Restart with question")
        model.shutdown()
        XCTAssertNil(model.pendingAgentQuestion)
        try await waitFor("the previous helper to record abort") {
            guard let file = try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "jsonl" }),
                  let contents = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return contents.components(separatedBy: "Restart with question").dropFirst().last?
                .components(separatedBy: "\n").contains {
                $0.contains("\"role\":\"toolResult\"") && $0.contains("\"toolName\":\"write\"") && $0.contains("Operation aborted")
            } == true
        }
        model.connect()
        try await waitFor("the same thread to reopen") { model.phase == .ready || model.error != nil }
        XCTAssertEqual(model.conversation?.id, thread.id)
        try rawReply(restarted)
        model.draft = "Continue the thread"
        model.send()
        try rawReply(restarted)
        try await waitFor("one continuation") { model.phase == .ready }
        let failure = try? String(contentsOf: root.appendingPathComponent("provider-error"), encoding: .utf8)
        XCTAssertNil(failure)
        XCTAssertEqual(model.messages.last?.text, "Same Pi thread continued.", failure ?? model.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("restarted.txt").path))
        let requests = try String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)
        let prompts = try requests.split(separator: "\n").map {
            let request = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            return request?["prompt"] as? String
        }
        XCTAssertEqual(prompts, ["Answer questions", "Answer questions", "Answer questions", "Dismiss questions",
                                 "Dismiss questions", "Stop questions", "Restart with question", "Continue the thread"])
    }

    private func waitFor(_ description: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(description).")
        throw WorkspaceError("Timed out waiting for \(description).")
    }
}

private final class AgentQuestionOffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
