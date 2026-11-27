import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class ComposerModelPickerTests: XCTestCase {
    func testOffscreenPickerSendsSelectedModelsThroughPi() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PI_MODEL_PICKER_TEST_ROOT"],
              let endpoint = env["PI_MODEL_PICKER_TEST_ENDPOINT"],
              let node = env["PI_MODEL_PICKER_TEST_NODE"],
              let worker = env["PI_MODEL_PICKER_TEST_WORKER"] else {
            throw XCTSkip("Run scripts/verify-composer-models.mjs for the loopback integration.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let workspaceRoot = root.appendingPathComponent("workspace")
        let alpha = ModelSettings(provider: .local, model: "fixture-alpha", endpoint: endpoint)
        let beta = ModelSettings(provider: .local, model: "fixture-beta", endpoint: endpoint)
        let unsupported = ModelSettings(provider: .openai, model: "missing-fixture-model")
        let draft = Conversation(id: UUID(), title: "New thread", isDraft: true)
        let other = Conversation(id: UUID(), title: "Other thread", isDraft: true, composerText: "Other draft")
        let invalidDraft = Conversation(id: UUID(), title: "Missing model", isDraft: true, composerText: "Unsent")
        let project = Project(id: UUID(), path: path, title: "Fixture", conversations: [draft, other],
                              selectedConversation: draft.id, modelOverride: beta)
        let invalidProject = Project(id: UUID(), path: path, title: "Missing provider model",
                                     conversations: [invalidDraft], selectedConversation: invalidDraft.id,
                                     modelOverride: unsupported)
        let initial = Workspace(projects: [project, invalidProject], selectedProject: project.id,
                                model: alpha, welcomeCompleted: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let index = workspaceRoot.appendingPathComponent(WorkspaceStore.indexName)
        try JSONEncoder().encode(initial).write(to: index, options: .withoutOverwriting)

        func savedWorkspace() throws -> Workspace {
            try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
        }

        var credentialReads: [String] = []
        var presenceChecks: [String] = []
        func launch() -> WorkspaceModel {
            let model = WorkspaceModel(root: workspaceRoot, keychainService: "dev.piworkspace.composer-model-fixture",
                                       credentialExists: { account in
                presenceChecks.append(account)
                return account == beta.account
            }, readCredential: { account in
                credentialReads.append(account)
                return account == beta.account ? "composer-model-fixture-key" : nil
            }, makeProcess: { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: node), arguments: [worker])
            })
            XCTAssertNil(model.startupFailure)
            model.start()
            return model
        }

        weak var previousModel: WorkspaceModel?
        do {
            let model = launch()
            previousModel = model
            let ui = OffscreenComposerModels(model)
            defer { ui.close(); XCTAssertTrue(model.terminate()) }
            try await ui.until("Pi worker ready for the inherited model") { model.phase == .ready || model.error != nil }
            XCTAssertNil(model.error)
            XCTAssertEqual(model.effectiveModel, beta)
            try await ui.until("project’s inherited model in the picker trigger") { ui.modelLabel.contains(beta.model) }
            XCTAssertTrue(credentialReads.allSatisfy { $0 == beta.account })
            try await ui.press("active-model")
            try await ui.search("no fixture model matches")
            try await ui.until("empty search") { ui.element("composer-model-no-results") != nil }
            try ui.escape()
            try await ui.until("picker closed without changing the draft") { ui.element("composer-model-picker") == nil }
            XCTAssertEqual(ui.modelLabel.contains(beta.model), true)
            try await ui.choose(alpha, query: "OpenAI-compatible ALPHA")
            try await ui.until("saved selection-only draft") { model.phase == .ready && ui.modelLabel.contains(alpha.model) }
            XCTAssertEqual(model.conversation?.id, draft.id)
            XCTAssertTrue(model.draft.isEmpty)
            XCTAssertEqual(try savedWorkspace().activeProject?.conversations.first { $0.id == draft.id }?.modelSelection, alpha)
            XCTAssertTrue(credentialReads.allSatisfy { $0 == alpha.account })
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-0").path))
        }

        for _ in 0..<100 where previousModel != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(previousModel, "The first offscreen workspace released its store")
        let model = launch()
        let ui = OffscreenComposerModels(model)
        defer { ui.close(); XCTAssertTrue(model.terminate()) }
        try await ui.until("saved model after relaunch") { model.phase == .ready && ui.modelLabel.contains(alpha.model) }
        XCTAssertEqual(model.conversation?.id, draft.id)
        XCTAssertTrue(credentialReads.allSatisfy { $0 == alpha.account })
        model.draft = "First selected draft"
        try await ui.press("send-message")
        try await ui.until("provider received the first request") {
            model.phase == .running && model.messages.last?.role == .user && self.wireModel(0, root: root) == alpha.model
        }
        try await ui.choose(beta, query: "fixture-beta")
        try await ui.until("beta is selected for the next turn") { ui.modelLabel.contains(beta.model) }
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(wireModel(0, root: root), alpha.model)
        XCTAssertNil(wireModel(1, root: root))
        model.draft = "Queued next turn"
        try await ui.press("queue-message")
        let queued = try XCTUnwrap(model.queuedMessages.first)
        try Data().write(to: root.appendingPathComponent("release-first"))
        try await ui.until("queue completed on beta") {
            model.phase == .ready && model.messages.last?.text == "Reply from fixture-beta."
        }
        XCTAssertEqual(wireModel(1, root: root), beta.model)
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertEqual(model.messages.first { $0.queuedID == queued.id }?.text, queued.text)

        try await ui.choose(alpha, query: "fixture-alpha")
        try await ui.until("switch back with transcript preserved") {
            model.phase == .ready && model.messages.count == 4 && ui.modelLabel.contains(alpha.model)
        }
        model.draft = "Switch back after the queue"
        try await ui.press("send-message")
        try await ui.until("third turn completed on alpha") {
            model.phase == .ready && model.messages.count == 6 && self.wireModel(2, root: root) == alpha.model
        }

        let saved = try savedWorkspace()
        XCTAssertEqual(saved.model, alpha)
        XCTAssertEqual(saved.activeProject?.modelOverride, beta)
        XCTAssertNil(saved.activeProject?.conversations.first { $0.id == other.id }?.modelSelection)
        XCTAssertEqual(saved.projects.last?.modelOverride, unsupported)
        XCTAssertEqual(Set(presenceChecks), [alpha.account])
        XCTAssertEqual(Set(credentialReads), [alpha.account])

        try await ui.press("active-model")
        try await ui.press("composer-model-default")
        try await ui.until("inherited model restored") { model.phase == .ready && ui.modelLabel.contains(beta.model) }
        XCTAssertNil(model.conversation?.modelSelection)
        model.selectConversation(other.id, in: project.id)
        try await ui.until("other draft still inherits beta") {
            model.phase == .ready && model.draft == other.composerText && ui.modelLabel.contains(beta.model)
        }

        model.selectProject(invalidProject.id)
        try await ui.until("Pi reports the missing model") {
            model.phase == .closed && model.error?.contains("bundled Pi catalog") == true
        }
        try await ui.press("active-model")
        try await ui.search(unsupported.model)
        let unavailable = "composer-model-openai-\(unsupported.model)"
        try await ui.until("catalog marks configured model unavailable") {
            ui.element(unavailable)?.isAccessibilityEnabled?() == false
        }
        try await ui.press("composer-model-settings")
        XCTAssertEqual(model.settingsRequest?.page, .model)
        XCTAssertEqual(model.settingsRequest?.projectID, invalidProject.id)
        XCTAssertEqual(Set(credentialReads), [alpha.account])
    }

    private func wireModel(_ index: Int, root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent("request-\(index)"), encoding: .utf8)
    }
}

@MainActor
private final class OffscreenComposerModels {
    private let app = NSApplication.shared
    private let policy: NSApplication.ActivationPolicy
    private let window: NSPanel
    private let host: NSHostingView<WorkspaceView>
    private let pasteboard = NSPasteboard.withUniqueName()

    init(_ model: WorkspaceModel) {
        policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
        window = ModelPickerOffscreenPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1100, height: 720)),
                                           styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable,
                                                     workspacePasteboard: pasteboard))
        window.contentView = host
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
    }

    func close() {
        window.makeFirstResponder(nil)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        pasteboard.releaseGlobally()
        app.setActivationPolicy(policy)
    }

    var modelLabel: String {
        guard let trigger = element("active-model") else { return "" }
        return [trigger.accessibilityLabel?(), trigger.accessibilityTitle?()].compactMap { $0 }.joined(separator: " ")
    }

    func element(_ id: String) -> AnyObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ node: AnyObject) -> AnyObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.accessibilityIdentifier?() == id { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let match = find(child as AnyObject) { return match }
            }
            return nil
        }
        return find(host) ?? find(window)
    }

    func press(_ id: String) async throws {
        try await until(id) { self.element(id)?.isAccessibilityEnabled?() == true }
        XCTAssertEqual(element(id)?.accessibilityPerformPress?(), true, id)
    }

    func search(_ text: String) async throws {
        func findField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Search models…" { return field }
            return view.subviews.lazy.compactMap { findField(in: $0) }.first
        }
        try await until("model search field") { findField(in: self.host) != nil }
        let field = try XCTUnwrap(findField(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    func escape() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                                                  keyCode: UInt16(kVK_Escape)))
        app.sendEvent(event)
    }

    func choose(_ settings: ModelSettings, query: String) async throws {
        try await press("active-model")
        try await search(query)
        try await press("composer-model-\(settings.provider.rawValue)-\(settings.model)")
        try await until("model picker dismissed") { self.element("composer-model-picker") == nil }
    }

    func until(_ description: String, _ matches: () -> Bool) async throws {
        for _ in 0..<250 {
            host.layoutSubtreeIfNeeded()
            if matches() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let message = "Timed out waiting for \(description)."
        XCTFail(message)
        throw WorkspaceError(message)
    }
}

private final class ModelPickerOffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
