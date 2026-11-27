import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class ComposerShortcutTests: XCTestCase {
    func testNativeComposerSettingsAndHeldPiTurn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PI_COMPOSER_SHORTCUT_ROOT"],
              let endpoint = env["PI_COMPOSER_SHORTCUT_ENDPOINT"],
              let node = env["PI_COMPOSER_SHORTCUT_NODE"],
              let worker = env["PI_COMPOSER_SHORTCUT_WORKER"],
              let key = env["PI_COMPOSER_SHORTCUT_KEY"] else {
            throw XCTSkip("Run scripts/verify-composer-shortcuts.mjs for the held Pi turn replay.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let workspaceRoot = root.appendingPathComponent("workspace")
        let suite = "ComposerShortcutTests.\(UUID())"
        let otherSuite = "ComposerShortcutTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            otherDefaults.removePersistentDomain(forName: otherSuite)
        }

        let thread = Conversation(id: UUID(), title: "Composer replay", composerText: "Start here")
        let other = Conversation(id: UUID(), title: "Other", composerText: "Other thread draft")
        let project = Project(id: UUID(), path: path, title: "Fixture", conversations: [thread, other],
                              selectedConversation: thread.id)
        let settings = ModelSettings(provider: .local, model: "composer-shortcut-fixture", endpoint: endpoint)
        try WorkspaceStore(root: workspaceRoot)
            .save(Workspace(projects: [project], selectedProject: project.id, model: settings, welcomeCompleted: true))
        func launch() -> WorkspaceModel {
            let model = WorkspaceModel(root: workspaceRoot, keychainService: suite,
                                       credentialExists: { _ in true }, readCredential: { _ in key }) { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: node), arguments: [worker])
            }
            XCTAssertNil(model.startupFailure)
            model.start()
            return model
        }
        func requests() -> [[String]] {
            let lines = (try? String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)) ?? ""
            return lines.split(separator: "\n").compactMap {
                try? JSONDecoder().decode([String].self, from: Data($0.utf8))
            }
        }

        let ui = ComposerShortcutWindow()
        defer { ui.close() }
        XCTAssertGreaterThan(ui.window.windowNumber, 0, "AppKit key events require a WindowServer session")
        weak var previousModel: WorkspaceModel?
        let delivered: [UUID]
        do {
            let model = launch()
            previousModel = model
            defer { ui.detach(); XCTAssertTrue(model.terminate()) }
            ui.showWorkspace(model, defaults: defaults)
            try await ui.until("local Pi ready") { model.phase == .ready }
            try await ui.press("model-settings")
            try ui.showSettings(model, defaults: defaults)
            try await ui.search("send shortcut")
            try await ui.press("settings-result-send-shortcut")
            try await ui.until("Chat settings show both controls") {
                ui.element("settings-heading-chat") != nil &&
                    ui.element("send-shortcut") != nil && ui.element("follow-up-behavior") != nil
            }
            XCTAssertNil(ui.element("reset-send-shortcut"))
            XCTAssertNil(ui.element("reset-follow-up-behavior"))
            XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
            try await ui.press("settings-close")
            ui.showWorkspace(model, defaults: defaults)

            let currentFile = root.appendingPathComponent("active.txt")
            try Data("Active attachment bytes 🌸".utf8).write(to: currentFile)
            XCTAssertTrue(model.attach([.file(currentFile)], to: model.attachmentTarget(for: thread.id)))
            let activeAttachment = try XCTUnwrap(model.composerAttachments.first)
            try await ui.setComposer("Hold this")
            try ui.submit(.shift)
            XCTAssertEqual(model.draft, "Hold this\n")
            try await ui.setComposer("Hold this\nPi turn")
            try ui.submit(repeatKey: true)
            XCTAssertEqual(model.draft, "Hold this\nPi turn")
            XCTAssertTrue(requests().isEmpty)
            try ui.submit()
            try await ui.until("Pi starts streaming the attached prompt") {
                model.canSteer && model.partial == "Held composer turn." && requests().count == 1
            }
            XCTAssertEqual(requests().first?.last,
                           "Hold this\nPi turn\n\nAttached text file \"active.txt\":\nActive attachment bytes 🌸")
            XCTAssertEqual(model.messages.first?.attachments?.first?.id, activeAttachment.id)

            for modifiers: NSEvent.ModifierFlags in [[], .command] {
                let editor = try await ui.setComposer("IME ")
                editor.setMarkedText("変換", selectedRange: NSRange(location: 2, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertTrue(editor.hasMarkedText())
                try ui.submit(modifiers)
                XCTAssertTrue(model.queuedMessages.isEmpty)
                XCTAssertEqual(model.phase, .running)
                XCTAssertEqual(requests().count, 1)
                editor.unmarkText()
            }

            var waiting: [QueuedMessage] = []
            var steering: [QueuedMessage] = []
            func followUp(_ prompt: String, _ key: NSEvent.ModifierFlags, waits: Bool) async throws {
                try await ui.setComposer(prompt)
                try ui.submit(key)
                try await ui.until("receipt for \(prompt)") {
                    model.conversation?.queuedMessages?.contains { $0.text == prompt } == true
                }
                let item = try XCTUnwrap(model.conversation?.queuedMessages?.first { $0.text == prompt })
                XCTAssertEqual(model.queuedMessages.contains { $0.id == item.id }, waits)
                XCTAssertEqual(model.draft, "")
                XCTAssertEqual(model.conversation?.id, thread.id)
                XCTAssertEqual(model.partial, "Held composer turn.")
                XCTAssertEqual(requests().count, 1)
                if waits { waiting.append(item) } else { steering.append(item) }
            }

            func setPreference(_ id: String) async throws {
                try await ui.press("model-settings")
                try ui.showSettings(model, defaults: defaults)
                try await ui.press("settings-nav-chat")
                try await ui.press(id)
                try await ui.press("settings-close")
                ui.showWorkspace(model, defaults: defaults)
            }

            for followUpDefault in ["steer", "queue"] {
                let queuesByDefault = followUpDefault == "queue"
                if queuesByDefault { try await setPreference("follow-up-behavior-queue") }
                for mode in ["enter", "mod-enter-multiline", "mod-enter"] {
                    if followUpDefault != "steer" || mode != "enter" { try await setPreference("send-shortcut-" + mode) }
                    let label = followUpDefault + " " + mode
                    let requiresCommand = mode == "mod-enter"
                    try await followUp(label + " primary", requiresCommand ? .command : [], waits: queuesByDefault)
                    try await followUp(label + " alternate", requiresCommand ? [.command, .shift] : .command,
                                       waits: !queuesByDefault)
                    if mode == "mod-enter-multiline" {
                        let prompt = label + "\nsecond line"
                        try await ui.setComposer(prompt)
                        try ui.submit()
                        XCTAssertEqual(model.draft, prompt + "\n")
                        try await followUp(prompt + " primary", .command, waits: queuesByDefault)
                        try await followUp(prompt + " alternate", [.command, .shift], waits: !queuesByDefault)
                    }
                }
            }

            let selected = waiting[1]
            let editedFile = root.appendingPathComponent("edited.txt")
            try Data("Queue edit bytes 👩🏽‍💻".utf8).write(to: editedFile)
            try await ui.setComposer("Keep this separate draft")
            model.editQueuedMessage(selected.id)
            XCTAssertTrue(model.attach([.file(editedFile)], to: model.attachmentTarget(for: thread.id)))
            let editedAttachment = try XCTUnwrap(model.composerAttachments.first)
            try await ui.setComposer("Edited queue item")
            try ui.submit()
            XCTAssertEqual(model.draft, "Edited queue item\n")
            try ui.submit(.command)
            try await ui.until("edited message restores the independent draft") {
                model.editingQueuedMessageID == nil && model.draft == "Keep this separate draft"
            }
            XCTAssertEqual(model.queuedMessages.map(\.id), waiting.map(\.id))
            XCTAssertEqual(model.queuedMessages[1].text, "Edited queue item")
            XCTAssertEqual(model.queuedMessages[1].attachments?.first?.id, editedAttachment.id)
            try await ui.press("queue-send-now-\(selected.id)")
            XCTAssertEqual(model.queuedMessages.map(\.id), waiting.filter { $0.id != selected.id }.map(\.id))
            try await ui.setComposer("Explicit Steer")
            try await ui.press("steer-message")
            let explicitSteer = try XCTUnwrap(model.conversation?.queuedMessages?.first { $0.text == "Explicit Steer" })
            try await ui.setComposer("Explicit Queue")
            try await ui.press("queue-message")
            let explicitQueue = try XCTUnwrap(model.queuedMessages.last)
            XCTAssertEqual(explicitQueue.text, "Explicit Queue")

            try Data().write(to: root.appendingPathComponent("release"))
            delivered = steering.map(\.id) + [selected.id, explicitSteer.id] +
                waiting.filter { $0.id != selected.id }.map(\.id) + [explicitQueue.id]
            try await ui.until("Pi records each queue ID and returns to idle", seconds: 20) {
                model.phase == .ready && model.queuedMessages.isEmpty &&
                    model.messages.compactMap(\.queuedID).count == delivered.count
            }
            XCTAssertEqual(model.messages.compactMap(\.queuedID), delivered)
            XCTAssertEqual(model.messages.first { $0.queuedID == selected.id }?.attachments?.first?.id, editedAttachment.id)
            XCTAssertTrue(requests().contains { $0.last == "Edited queue item\n\nAttached text file \"edited.txt\":\nQueue edit bytes 👩🏽‍💻" })
            XCTAssertEqual(model.conversation?.id, thread.id)
            let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: workspaceRoot.appendingPathComponent("workspace.json")))
            XCTAssertEqual(saved.activeProject?.conversations.first { $0.id == other.id }?.composerText, "Other thread draft")
            XCTAssertEqual(defaults.string(forKey: "chat.sendShortcut"), "mod-enter")
            XCTAssertEqual(defaults.string(forKey: "chat.followUpBehavior"), "queue")
            XCTAssertNil(otherDefaults.string(forKey: "chat.sendShortcut"))
            XCTAssertNil(otherDefaults.string(forKey: "chat.followUpBehavior"))
            try await ui.setComposer("Keep this draft through reopening")
        }
        try await ui.until("first workspace releases its store") { previousModel == nil }
        let reopened = launch()
        defer { XCTAssertTrue(reopened.terminate()) }
        ui.showWorkspace(reopened, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        try await ui.until("same thread with saved history after reopening") {
            reopened.phase == .ready && reopened.conversation?.id == thread.id &&
                reopened.messages.compactMap(\.queuedID) == delivered
        }
        XCTAssertEqual(reopened.draft, "Keep this draft through reopening")
        try await ui.setComposer("Reopened with command send")
        try ui.submit()
        XCTAssertEqual(reopened.draft, "Reopened with command send\n")
        try await ui.setComposer("Reopened with command send\nsecond line")
        try ui.submit(.command)
        try await ui.until("reopened prompt starts a held turn") {
            requests().last?.last == "Reopened with command send\nsecond line" && reopened.canSteer
        }
        try await ui.setComposer("Queue preference after reopening")
        try ui.submit(.command)
        let persistedQueue = try XCTUnwrap(reopened.queuedMessages.first)
        XCTAssertEqual(persistedQueue.text, "Queue preference after reopening")
        try await ui.setComposer("Steer alternate after reopening")
        try ui.submit([.command, .shift])
        let persistedSteer = try XCTUnwrap(reopened.conversation?.queuedMessages?.first { $0.text == "Steer alternate after reopening" })
        XCTAssertEqual(reopened.queuedMessages.map(\.id), [persistedQueue.id])
        try Data().write(to: root.appendingPathComponent("release-reopened"))
        try await ui.until("persisted follow-up preference delivers the steer first") {
            reopened.phase == .ready &&
                reopened.messages.compactMap(\.queuedID) == delivered + [persistedSteer.id, persistedQueue.id]
        }
        try await ui.press("model-settings")
        try ui.showSettings(reopened, defaults: defaults)
        try await ui.search("follow-up behavior")
        try await ui.press("settings-result-follow-up-behavior")
        try await ui.press("reset-follow-up-behavior")
        try await ui.press("reset-send-shortcut")
        XCTAssertEqual(defaults.string(forKey: "chat.followUpBehavior"), "steer")
        XCTAssertEqual(defaults.string(forKey: "chat.sendShortcut"), "enter")
    }
}

@MainActor
private final class ComposerShortcutWindow {
    let window: NSPanel
    private let app = NSApplication.shared
    private let previousPolicy: NSApplication.ActivationPolicy

    init() {
        previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2200, y: 0)
        window = ComposerShortcutPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1100, height: 720)),
                                      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
    }

    func detach() {
        window.makeFirstResponder(nil)
        window.contentView = nil
    }

    func close() {
        detach()
        window.close()
        app.setActivationPolicy(previousPolicy)
    }

    func showWorkspace(_ model: WorkspaceModel, defaults: UserDefaults) {
        window.makeFirstResponder(nil)
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable)
            .defaultAppStorage(defaults))
    }

    func showSettings(_ model: WorkspaceModel, defaults: UserDefaults) throws {
        let request = try XCTUnwrap(model.settingsRequest)
        window.makeFirstResponder(nil)
        window.contentView = NSHostingView(rootView: SettingsView(model: model, appearance: AppearanceSettings(defaults: defaults),
                                                                 browserDefaults: defaults, request: request, openWelcome: {})
            .defaultAppStorage(defaults))
    }

    func search(_ query: String) async throws {
        let search = { (field: NSTextField) in field.placeholderString == "Search settings" }
        try await until("settings search") { field(where: search) != nil }
        try replace(query, in: XCTUnwrap(field(where: search)))
    }

    @discardableResult
    func setComposer(_ prompt: String) async throws -> NSTextView {
        let composer = { (field: NSTextField) in field.accessibilityIdentifier() == "composer" && field.isEnabled }
        try await until("enabled composer") { field(where: composer) != nil }
        return try replace(prompt, in: XCTUnwrap(field(where: composer)))
    }

    @discardableResult
    private func replace(_ text: String, in field: NSTextField) throws -> NSTextView {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(editor.string, text)
        return editor
    }

    func submit(_ modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: repeatKey, keyCode: UInt16(kVK_Return)
        ))
        window.sendEvent(event)
    }

    func press(_ id: String) async throws {
        try await until("AX control \(id)") { element(id) != nil }
        XCTAssertTrue(element(id)?.accessibilityPerformPress?() == true, id)
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
        return window.contentView.flatMap { find($0) }
    }

    private func field(where matches: (NSTextField) -> Bool) -> NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            if let text = view as? NSTextField, matches(text) { return text }
            for subview in view.subviews {
                if let text = find(subview) { return text }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    func until(_ description: String, seconds: Int = 6, _ matches: () -> Bool) async throws {
        for _ in 0..<(seconds * 50) {
            window.contentView?.layoutSubtreeIfNeeded()
            if matches() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let message = "Timed out waiting for \(description)."
        XCTFail(message)
        throw WorkspaceError(message)
    }
}

private final class ComposerShortcutPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
