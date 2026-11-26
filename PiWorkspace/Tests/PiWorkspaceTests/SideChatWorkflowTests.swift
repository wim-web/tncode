import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class SideChatWorkflowTests: XCTestCase {
    func testNativeSideChatsWithBundledPi() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PI_SIDE_CHAT_TEST_ROOT"], let endpoint = env["PI_SIDE_CHAT_TEST_ENDPOINT"],
              let node = env["PI_SIDE_CHAT_TEST_NODE"], let worker = env["PI_SIDE_CHAT_TEST_WORKER"] else {
            throw XCTSkip("Run scripts/verify-side-chat.mjs with a packaged app for the loopback test.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let projectFolder = root.appendingPathComponent("project").path
        let checkout = root.appendingPathComponent("checkout").path
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        let queue = QueuedMessage(text: "Keep parent queue paused.")
        let settings = ModelSettings(provider: .local, model: "parent-fixture-model", endpoint: endpoint)
        let parent = Conversation(id: UUID(), title: "Parent", location: .worktree(path: checkout, base: "main"),
                                  composerText: "Parent starting question.", queuedMessages: [queue], modelSelection: settings)
        let other = Conversation(id: UUID(), title: "Other thread", composerText: "Keep other draft.")
        let project = Project(id: UUID(), path: projectFolder, title: "Fixture", conversations: [parent, other],
                              selectedConversation: parent.id)
        var workspaceSettings = settings
        workspaceSettings.model = "workspace-fixture-model"
        try WorkspaceStore(root: workspaceRoot).save(
            .init(projects: [project], selectedProject: project.id, model: workspaceSettings, welcomeCompleted: true)
        )

        var failNextOpen = false
        var directories: [String] = []
        func launch() -> WorkspaceModel {
            let model = WorkspaceModel(root: workspaceRoot, keychainService: "dev.piworkspace.side-chat-fixture",
                                       credentialExists: { _ in true }, readCredential: { _ in "side-chat-fixture-key" },
                                       makeProcess: { config, directory in
                if failNextOpen {
                    failNextOpen = false
                    throw WorkspaceError("Fixture could not start Pi.")
                }
                directories.append(directory)
                return try PiProcess(config: config, cwd: directory, executable: URL(fileURLWithPath: node), arguments: [worker])
            })
            XCTAssertNil(model.startupFailure)
            model.start()
            return model
        }
        func scope(_ child: SideChat) -> SideChatScope {
            .init(projectID: project.id, parentID: parent.id, id: child.id)
        }
        let parentDirectory = WorkspaceStore.historyComponents(project: project.id, conversation: parent.id)
            .reduce(workspaceRoot) { $0.appendingPathComponent($1, isDirectory: true) }
        func parentHistory() throws -> Data {
            try history(parentDirectory)
        }
        func savedParent() throws -> Conversation {
            let data = try Data(contentsOf: workspaceRoot.appendingPathComponent(WorkspaceStore.indexName))
            let state = try JSONDecoder().decode(Workspace.self, from: data)
            return try XCTUnwrap(state.activeProject?.conversations.first { $0.id == parent.id })
        }

        weak var previousModel: WorkspaceModel?
        let childScope: SideChatScope
        let slashScope: SideChatScope
        let childHistory: Data
        let readyParentHistory: Data
        let sideDirectory: URL
        let unrelatedFile: ComposerAttachment
        do {
            let first = launch()
            previousModel = first
            let ui = SideChatOffscreenWorkspace(first)
            defer { ui.close(); XCTAssertTrue(first.terminate()) }
            try await ui.until("parent Pi connection and draft ready", details: {
                "phase=\(first.phase) draft=\(first.draft) error=\(first.error ?? "none") canSend=\(first.canSend)"
            }) { first.canSend }
            try await ui.press("send-message")
            try await ui.until("parent reply") { first.phase == .ready && first.messages.last?.text == "Parent context reply." }
            let original = try parentHistory()
            try ui.type("Keep this text in the parent.", in: "composer")
            XCTAssertTrue(first.savePendingComposer())

            try await ui.press("add-panel-surface")
            try await ui.until("side chat in add panel menu") { ui.enabled("add-panel-side-chat") }
            try ui.key(kVK_ANSI_S, "s")
            try await ui.until("side created by S", details: {
                "children=\(first.conversation?.sideChats?.count ?? 0) error=\(first.error ?? "none")"
            }) { first.conversation?.sideChats?.count == 1 }
            try await ui.until("native side composer", details: {
                guard let scope = first.sideChatToOpen?.scope else { return "no tab request" }
                let session = first.sideChatSession(scope)
                return "tab=\(ui.element("right-panel-tab-side-chat-\(scope.id)") != nil) phase=\(String(describing: session?.phase)) error=\(session?.error ?? "none")"
            }) { ui.composerField("side-chat-composer") != nil }
            let child = try XCTUnwrap(first.conversation?.sideChats?.first)
            childScope = scope(child)
            XCTAssertEqual(first.conversation?.id, parent.id)
            XCTAssertEqual(first.draft, "Keep this text in the parent.")
            XCTAssertFalse(ui.enabled("add-side-chat-to-chat"))
            XCTAssertEqual(first.sideChatSession(childScope)?.messages.count, 0)

            try ui.type("Side question from pane.", in: "side-chat-composer")
            try await ui.until("side send enabled") { ui.enabled("send-side-chat") }
            try ui.key(kVK_Return, "\r", modifiers: .command)
            try await ui.until("side-only reply") {
                first.sideChatSession(childScope)?.messages.last?.text == "Side answer to attach." &&
                    first.sideChatSession(childScope)?.phase == .ready
            }
            sideDirectory = parentDirectory.appendingPathComponent("side-chats/" + child.id.uuidString)
            childHistory = try history(sideDirectory)
            XCTAssertEqual(try parentHistory(), original)
            XCTAssertEqual(first.draft, "Keep this text in the parent.")
            XCTAssertFalse(first.messages.contains { $0.text.contains("Side answer") })
            XCTAssertEqual(first.sideChatSession(childScope)?.messages.map(\.text),
                           ["Side question from pane.", "Side answer to attach."])

            try await ui.press("close-side-chat")
            try await ui.until("side pane closed") { ui.element("side-chat-pane") == nil }
            try await ui.press("thread-details")
            try await ui.press("open-side-chat-\(child.id)")
            try await ui.until("existing side chat restored") { first.sideChatSession(childScope)?.messages.count == 2 }
            XCTAssertEqual(try history(sideDirectory), childHistory)
            try await ui.press("open-side-chat-parent")
            try await ui.until("back to parent") { ui.element("side-chat-pane") == nil }
            try ui.type("Parent work in progress.", in: "composer")
            try await ui.press("send-message")
            try await ui.until("parent request reached wire") { FileManager.default.fileExists(atPath: path + "/request-2") }
            XCTAssertTrue(first.phase.isRunning)
            XCTAssertTrue(first.attach([.pastedText("Unrelated fixture file.")], to: first.attachmentTarget(for: parent.id)))
            unrelatedFile = try XCTUnwrap(first.composerAttachments.first)
            failNextOpen = true
            let slash = "/BtW Slash question while parent is busy."
            try ui.type(slash, in: "composer")
            try await ui.press("send-message")
            try await ui.until("side startup failure") { ui.element("side-chat-error") != nil }
            let slashChild = try XCTUnwrap(first.conversation?.sideChats?.last)
            slashScope = scope(slashChild)
            XCTAssertNotEqual(slashChild.id, child.id)
            let busyHistory = try parentHistory()
            XCTAssertEqual(try savedParent().composerText, slash)
            XCTAssertEqual(try savedParent().composerAttachments, [unrelatedFile])
            XCTAssertEqual(try savedParent().queuedMessages?.map(\.id), [queue.id])
            XCTAssertTrue(first.phase.isRunning)
            try await ui.press("reconnect-side-chat")
            try await ui.until("retried slash reply while parent is busy") {
                first.sideChatSession(slashScope)?.messages.last?.text == "Slash answer only." &&
                    first.sideChatSession(slashScope)?.phase == .ready && first.draft.isEmpty
            }
            XCTAssertEqual(try parentHistory(), busyHistory)
            XCTAssertEqual(try savedParent().composerAttachments, [unrelatedFile])
            try Data().write(to: root.appendingPathComponent("release-parent"))
            try await ui.until("parent reply after release") { first.phase == .ready && first.messages.last?.text == "Busy parent reply." }
            try await ui.press("thread-row-\(other.id)")
            try await ui.until("other thread selected") { first.conversation?.id == other.id && first.phase == .ready }
            XCTAssertEqual(first.draft, "Keep other draft.")
            try await ui.press("thread-row-\(parent.id)")
            try await ui.until("parent restored after switch") { first.conversation?.id == parent.id && first.phase == .ready }
            try ui.type("Parent follow-up.", in: "composer")
            try await ui.openSideChat(child.id)
            try await ui.press("add-side-chat-to-chat")
            try await ui.press("add-side-chat-to-chat")
            XCTAssertEqual(first.composerAttachments.map(\.id), [unrelatedFile.id, child.id])
            XCTAssertEqual(try history(sideDirectory), childHistory)
            readyParentHistory = try parentHistory()
        }
        for _ in 0..<100 where previousModel != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(previousModel)

        let relaunched = launch()
        let reopened = SideChatOffscreenWorkspace(relaunched)
        defer { reopened.close(); _ = relaunched.terminate() }
        try await reopened.until("parent ready after relaunch") { relaunched.phase == .ready }
        XCTAssertEqual(relaunched.conversation?.id, parent.id)
        XCTAssertEqual(relaunched.workingDirectory, checkout)
        XCTAssertEqual(relaunched.effectiveModel, settings)
        XCTAssertEqual(relaunched.queuedMessages.map(\.id), [queue.id])
        XCTAssertEqual(relaunched.draft, "Parent follow-up.")
        XCTAssertEqual(relaunched.composerAttachments.map(\.id), [unrelatedFile.id, childScope.id])
        XCTAssertEqual(try parentHistory(), readyParentHistory)
        try await reopened.openSideChat(childScope.id)
        try await reopened.until("same side history after relaunch") {
            relaunched.sideChatSession(childScope)?.messages.count == 2
        }
        XCTAssertEqual(try history(sideDirectory), childHistory)

        try await reopened.press("delete-side-chat")
        try await reopened.until("delete confirmation title and message") {
            reopened.element("side-chat-delete-title") != nil && reopened.element("side-chat-delete-message") != nil
        }
        XCTAssertEqual(reopened.label("side-chat-delete-title"), "Delete side chat \"Side question from pane.\"?")
        XCTAssertEqual(reopened.label("side-chat-delete-message"), "This permanently clears its conversation history.")
        XCTAssertEqual(reopened.label("cancel-side-chat-delete"), "Cancel")
        XCTAssertEqual(reopened.label("confirm-side-chat-delete"), "Confirm")
        try reopened.key(kVK_Escape, "\u{1b}")
        try await reopened.until("Escape cancels delete") { reopened.element("side-chat-delete-confirmation") == nil }
        XCTAssertEqual(try history(sideDirectory), childHistory)
        try await reopened.press("delete-side-chat")
        try await reopened.press("cancel-side-chat-delete")
        try await reopened.until("cancel restores side pane") { reopened.element("cancel-side-chat-delete") == nil }
        XCTAssertEqual(try history(sideDirectory), childHistory)
        XCTAssertEqual(try parentHistory(), readyParentHistory)
        try await reopened.press("delete-side-chat")
        try await reopened.press("confirm-side-chat-delete")
        try await reopened.until("deleted chat removed") {
            relaunched.sideChat(childScope) == nil && reopened.element("open-side-chat-\(childScope.id)") == nil
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sideDirectory.path))
        XCTAssertEqual(try parentHistory(), readyParentHistory)
        XCTAssertNotNil(relaunched.sideChat(slashScope))
        XCTAssertEqual(relaunched.composerAttachments.map(\.id), [unrelatedFile.id, childScope.id])
        try await reopened.press("send-message")
        try await reopened.until("parent received explicit attachment") {
            relaunched.phase == .ready && relaunched.messages.last?.text == "Parent received attachment."
        }
        XCTAssertTrue(relaunched.composerAttachments.isEmpty)
        XCTAssertEqual(try savedParent().queuedMessages?.map(\.id), [queue.id])
        XCTAssertTrue(directories.contains(checkout))
        XCTAssertTrue(directories.contains(projectFolder))
        let afterHandoff = try parentHistory()
        let failedSlash = "/side Slash provider error."
        try uiCheckAlias(failedSlash, with: reopened)
        try await reopened.press("send-message")
        try await reopened.until("provider error appears only in side chat") { reopened.element("side-chat-error") != nil }
        let failedChild = try XCTUnwrap(relaunched.conversation?.sideChats?.last)
        let failedScope = scope(failedChild)
        XCTAssertTrue(failedChild.hasStarted)
        XCTAssertEqual(relaunched.draft, failedSlash)
        XCTAssertEqual(try parentHistory(), afterHandoff)
        try await reopened.press("close-side-chat")
        try await reopened.openSideChat(failedChild.id)
        try await reopened.until("failed slash is reopened without resending") {
            relaunched.sideChatSession(failedScope)?.phase == .ready
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/request-6"))
        XCTAssertEqual(try savedParent().composerText, failedSlash)
        XCTAssertEqual(try parentHistory(), afterHandoff)
        try await reopened.press("add-panel-surface")
        try await reopened.press("add-panel-side-chat")
        let unused = try XCTUnwrap(relaunched.conversation?.sideChats?.last)
        let unusedScope = scope(unused)
        XCTAssertNotEqual(unused.id, failedChild.id)
        try await reopened.until("unused side chat ready") { relaunched.sideChatSession(unusedScope)?.phase == .ready }
        XCTAssertFalse(reopened.enabled("add-side-chat-to-chat"))
        try await reopened.press("close-side-chat")
        try await reopened.until("unused side chat discarded") { relaunched.sideChat(unusedScope) == nil }
        XCTAssertEqual(try savedParent().composerText, failedSlash)
    }

    private func uiCheckAlias(_ text: String, with window: SideChatOffscreenWorkspace) throws {
        XCTAssertEqual(SideChat.command(in: text), "Slash provider error.")
        XCTAssertNil(SideChat.command(in: "/sidebar"))
        XCTAssertNil(SideChat.command(in: "type /btw literally"))
        try window.type(text, in: "composer")
    }

    private func history(_ directory: URL) throws -> Data {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        XCTAssertEqual(files.count, 1)
        return try Data(contentsOf: XCTUnwrap(files.first))
    }
}

@MainActor
private final class SideChatOffscreenWorkspace {
    private let app = NSApplication.shared
    private let policy: NSApplication.ActivationPolicy
    private let window: SideChatOffscreenPanel
    private let host: NSHostingView<AnyView>
    private let board = NSPasteboard.withUniqueName()
    private let suite = "dev.piworkspace.side-chat-test.\(UUID())"
    private let defaults: UserDefaults

    init(_ model: WorkspaceModel) {
        policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        defaults = UserDefaults(suiteName: suite)!
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 3200, y: 0)
        window = SideChatOffscreenPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 1840, height: 820)),
                                       styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(
            WorkspaceView(model: model, chatWidthMode: .comfortable, browserDefaults: defaults, workspacePasteboard: board)
                .defaultAppStorage(defaults)
        ))
        host.sizingOptions = []
        window.contentView = host
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
    }

    func close() {
        window.makeFirstResponder(nil)
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        window.close()
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        app.setActivationPolicy(policy)
    }

    func element(_ id: String) -> AnyObject? {
        var visited: [ObjectIdentifier: AnyObject] = [:]
        func find(_ node: AnyObject) -> AnyObject? {
            guard visited.updateValue(node, forKey: ObjectIdentifier(node)) == nil else { return nil }
            if node.accessibilityIdentifier?() == id { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let match = find(child as AnyObject) { return match }
            }
            return nil
        }
        if let result = find(host) ?? find(window) { return result }
        guard let sheet = window.attachedSheet else { return nil }
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(sheet.frame) })
        return find(sheet) ?? sheet.contentView.flatMap { find($0) }
    }

    func enabled(_ id: String) -> Bool {
        element(id)?.isAccessibilityEnabled?() == true
    }

    func label(_ id: String) -> String? {
        guard let node = element(id) else { return nil }
        let value = (node as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
        return [value as? String, node.accessibilityLabel?(), node.accessibilityTitle?()]
            .compactMap { $0 }.first { !$0.isEmpty }
    }

    func until(_ description: String, details: () -> String = { "" }, _ matches: () -> Bool) async throws {
        for _ in 0..<350 {
            host.layoutSubtreeIfNeeded()
            if matches() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(description). \(details())")
        throw WorkspaceError("Missing \(description)")
    }

    func press(_ id: String, line: UInt = #line) async throws {
        try await until("\(id) enabled (line \(line))") { self.enabled(id) }
        XCTAssertEqual(element(id)?.accessibilityPerformPress?(), true, id)
    }

    func openSideChat(_ id: UUID, line: UInt = #line) async throws {
        let row = "open-side-chat-\(id)"
        if !enabled(row) { try await press("thread-details", line: line) }
        try await press(row, line: line)
    }

    func composerField(_ id: String) -> ComposerTextField.Field? {
        func find(_ view: NSView) -> ComposerTextField.Field? {
            if let field = view as? ComposerTextField.Field, field.accessibilityIdentifier() == id { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(host)
    }

    func type(_ text: String, in id: String) throws {
        let field = try XCTUnwrap(composerField(id))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: characters, charactersIgnoringModifiers: characters,
                                                 isARepeat: false, keyCode: UInt16(code)))
        app.sendEvent(event)
    }
}

private final class SideChatOffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
