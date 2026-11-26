import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class ThreadFindTests: XCTestCase {
    func testFindRejectsReplacedQueriesRetriesAndThreadRequests() throws {
        let projectID = UUID()
        let thread = SidebarMessageSearch.Thread(projectID: projectID, threadID: UUID())
        var find = ThreadFindSession(thread: thread, term: .words(["orbital", "lantern"]), messageID: "later")
        let initial = try XCTUnwrap(find.request)
        find.receive(["older", "later"], for: initial)
        XCTAssertEqual(find.status.label, "2 of 2")
        XCTAssertEqual(find.selection?.messageID, "later")

        find.editQuery("somewhere else")
        find.editQuery("orbital lantern")
        let edited = try XCTUnwrap(find.request)
        find.receive(["older", "later"], for: initial)
        XCTAssertEqual(find.status, .searching)
        XCTAssertEqual(edited.term, .literal("orbital lantern"))

        find.fail(edited)
        find.refresh()
        let retry = try XCTUnwrap(find.request)
        find.fail(edited)
        XCTAssertEqual(find.status, .searching)
        find.receive(["older", "later"], for: retry)
        XCTAssertEqual(find.status.label, "1 of 2")
        XCTAssertEqual(find.selection?.messageID, "older")

        find = ThreadFindSession(thread: .init(projectID: projectID, threadID: UUID()), term: edited.term)
        find.receive(["older", "later"], for: retry)
        XCTAssertEqual(find.status, .searching)
        XCTAssertNil(find.selection)
    }

    func testFindRestoresNativeComposerSelection() async throws {
        let application = NSApplication.shared
        let policy = application.activationPolicy()
        application.setActivationPolicy(.prohibited)
        defer { application.setActivationPolicy(policy) }
        application.finishLaunching()
        try XCTSkipIf(NSScreen.screens.isEmpty, "Native key events need a WindowServer display.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "Keep this draft."
        let unicode = "前🌱 選択👩🏽‍💻 後"
        let queued = QueuedMessage(text: unicode)
        let first = Conversation(id: UUID(), title: "First", isDraft: false, composerText: original, queuedMessages: [queued])
        let other = Conversation(id: UUID(), title: "Second", isDraft: false, composerText: unicode)
        let project = Project(id: UUID(), path: root.path, title: "Find fixture",
                              conversations: [first, other], selectedConversation: first.id)
        try WorkspaceStore(root: root).save(Workspace(projects: [project], selectedProject: project.id, welcomeCompleted: true))
        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString, readCredential: { _ in nil }) { _, _ in
            throw WorkspaceError("No helper in this test.")
        }
        defer { model.terminate() }
        let app = Hosted(WorkspaceView(model: model, chatWidthMode: .comfortable))
        defer { app.close() }
        let prompt = "Ask Pi anything"

        func openFind(_ range: NSRange, in placeholder: String = "Ask Pi anything") async throws {
            try await app.until("composer appeared") { app.field(placeholder) != nil }
            let composer = try XCTUnwrap(app.field(placeholder) as? ComposerTextField.Field)
            XCTAssertTrue(app.window.makeFirstResponder(composer))
            let editor = try XCTUnwrap(composer.currentEditor() as? ComposerTextField.Editor)
            editor.setSelectedRange(range)
            XCTAssertEqual(editor.selectedRange(), range)
            try await app.key(kVK_ANSI_F, "f", .command)
            try await app.until("Find took focus") { app.isEditing("Find in thread") }
            try app.type("needle")
        }

        func returnedSelection(in placeholder: String = "Ask Pi anything", line: Int = #line) async throws -> NSRange {
            try await app.until("focus returned to \(placeholder) at line \(line)") { app.field("Find in thread") == nil && app.isEditing(placeholder) }
            return try XCTUnwrap(app.window.firstResponder as? ComposerTextField.Editor).selectedRange()
        }

        func typeExclamation() throws {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                                                    timestamp: 0, windowNumber: app.window.windowNumber, context: nil,
                                                    characters: "!", charactersIgnoringModifiers: "!", isARepeat: false,
                                                    keyCode: UInt16(kVK_ANSI_1)))
            app.window.sendEvent(key)
        }

        let caret = NSRange(location: 4, length: 0)
        try await openFind(caret)
        try await app.key(kVK_Escape, "\u{1b}")
        let restoredCaret = try await returnedSelection()
        XCTAssertEqual(restoredCaret, caret)
        try typeExclamation()
        XCTAssertEqual(model.draft, "Keep! this draft.")

        model.draft = unicode
        try await app.until("Unicode draft appeared") { app.field(prompt)?.stringValue == unicode }
        let selection = (unicode as NSString).range(of: "選択👩🏽‍💻")
        try await openFind(selection)
        try await app.key(kVK_ANSI_F, "f", .command)
        try app.press("thread-find-close")
        let restoredSelection = try await returnedSelection()
        XCTAssertEqual(restoredSelection, selection)
        try typeExclamation()
        XCTAssertEqual(model.draft, "前🌱 ! 後")

        let editor = try XCTUnwrap(app.window.firstResponder as? ComposerTextField.Editor)
        editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let composition = editor.markedRange()
        XCTAssertTrue(editor.hasMarkedText())
        try await app.key(kVK_ANSI_F, "f", .command)
        XCTAssertNil(model.activeThreadFind)
        XCTAssertTrue(app.window.firstResponder === editor)
        XCTAssertEqual(editor.markedRange(), composition)
        editor.insertText("", replacementRange: composition)

        try await openFind(caret)
        let beforeRevision = model.draft
        model.draft = "Changed while Find was open"
        model.draft = beforeRevision
        try await app.key(kVK_Escape, "\u{1b}")
        let changedRevision = try await returnedSelection()
        XCTAssertNotEqual(changedRevision, caret)

        model.editQueuedMessage(queued.id)
        try await openFind(selection, in: "Edit queued message")
        try await app.key(kVK_Escape, "\u{1b}")
        let sameQueueSession = try await returnedSelection(in: "Edit queued message")
        XCTAssertEqual(sameQueueSession, selection)

        try await openFind(selection, in: "Edit queued message")
        model.cancelQueuedMessageEdit()
        model.editQueuedMessage(queued.id)
        try await app.key(kVK_Escape, "\u{1b}")
        let differentQueueSession = try await returnedSelection(in: "Edit queued message")
        XCTAssertNotEqual(differentQueueSession, selection)
        XCTAssertEqual(model.draft, unicode)

        try await openFind(selection, in: "Edit queued message")
        model.selectConversation(other.id, in: project.id)
        let newThreadSelection = try await returnedSelection()
        XCTAssertNotEqual(newThreadSelection, selection)
        XCTAssertEqual(model.draft, unicode)

        try await openFind(selection)
        XCTAssertTrue(model.savePendingEditsForQuit())
        let savedRoot = root.appendingPathComponent("relaunch")
        try FileManager.default.createDirectory(at: savedRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("workspace.json"),
                                         to: savedRoot.appendingPathComponent("workspace.json"))
        let reloaded = WorkspaceModel(root: savedRoot, keychainService: UUID().uuidString, readCredential: { _ in nil })
        XCTAssertNil(reloaded.startupFailure)
        defer { reloaded.terminate() }
        let reopened = Hosted(WorkspaceView(model: reloaded, chatWidthMode: .comfortable))
        defer { reopened.close() }
        try await reopened.until("reloaded composer appeared") { reopened.field(prompt) != nil }
        XCTAssertTrue(reopened.window.makeFirstResponder(try XCTUnwrap(reopened.field(prompt))))
        XCTAssertNil(reloaded.activeThreadFind)
        XCTAssertEqual(reloaded.draft, unicode)
        XCTAssertNotEqual(try XCTUnwrap(reopened.window.firstResponder as? ComposerTextField.Editor).selectedRange(), selection)
    }

    func testFindKeysAndRetryWithFreshPiHistories() async throws {
        _ = NSApplication.shared
        try XCTSkipIf(NSScreen.screens.isEmpty, "Native key events need a WindowServer display.")
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sidecar = environment["PI_PALETTE_SIDECAR"] ?? package.appendingPathComponent("Sidecar").path
        let node = environment["PI_PALETTE_NODE"] ?? "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: node),
              FileManager.default.fileExists(atPath: sidecar + "/node_modules/@earendil-works/pi-coding-agent") else {
            throw XCTSkip("Set PI_PALETTE_NODE and PI_PALETTE_SIDECAR to Node and the Sidecar with the installed Pi SDK.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadFind-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let workspace = root.appendingPathComponent("workspace")
        let active = Conversation(id: UUID(), title: "Test history", isDraft: false, composerText: "Keep this draft.")
        let archived = Conversation(id: UUID(), title: "Archived test history", archived: true, isDraft: false)
        let project = Project(id: UUID(), path: cwd.path, title: "Test project",
                              conversations: [active, archived], selectedConversation: active.id)
        try WorkspaceStore(root: workspace).save(
            Workspace(projects: [project], selectedProject: project.id,
                      model: ModelSettings(provider: .local, model: "find-fixture"), welcomeCompleted: true)
        )
        let term = "orbital lantern"
        let seed = try seedHistory(node: node, sidecar: sidecar, package: package, workspace: workspace,
                                   project: project, thread: active, query: term, laterQuery: term)
        let archivedSeed = try seedHistory(node: node, sidecar: sidecar, package: package, workspace: workspace,
                                           project: project, thread: archived, query: "archived lantern", laterQuery: "")
        let model = WorkspaceModel(root: workspace, keychainService: root.lastPathComponent, readCredential: { _ in nil }) {
            config, cwd in
            try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: node),
                          arguments: [sidecar + "/worker.mjs"])
        }
        defer { model.terminate() }
        XCTAssertNil(model.startupFailure)
        let suite = root.lastPathComponent
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = Hosted(WorkspaceView(model: model, chatWidthMode: .comfortable).defaultAppStorage(defaults))
        defer { app.close() }
        model.connect()
        try await app.until("Pi history opened") { model.phase == .ready }
        try await app.until("composer opened") { app.field("Ask Pi anything") != nil }
        XCTAssertEqual(model.messages.first?.id, seed.messageID)
        XCTAssertFalse(model.messages.contains { $0.id == seed.abandonedID })
        let composer = try XCTUnwrap(app.field("Ask Pi anything"))
        XCTAssertGreaterThan(app.window.windowNumber, 0)
        XCTAssertTrue(app.window.makeFirstResponder(composer))

        try await app.key(kVK_ANSI_F, "f", .command)
        try await app.until("Find took focus") { app.isEditing("Find in thread") }
        XCTAssertEqual(app.field("Find in thread")?.stringValue, "")
        XCTAssertNil(model.activeThreadFind?.status.label)
        try app.type("  ORBITAL lantern  ")
        try await app.until("first Pi message selected") { model.activeThreadFind?.status.label == "1 of 2" && model.activeThreadFind?.selection?.messageID == seed.messageID }
        try await app.key(kVK_Return, "\r")
        try await app.until("next Pi message selected") { model.activeThreadFind?.status.label == "2 of 2" && model.activeThreadFind?.selection?.messageID == seed.latestID }
        try await app.key(kVK_Return, "\r", .shift)
        try await app.until("previous Pi message selected") { model.activeThreadFind?.status.label == "1 of 2" && model.activeThreadFind?.selection?.messageID == seed.messageID }
        try await app.key(kVK_Return, "\r", .shift)
        try await app.until("previous wraps") { model.activeThreadFind?.status.label == "2 of 2" && model.activeThreadFind?.selection?.messageID == seed.latestID }
        try await app.key(kVK_Return, "\r")
        try await app.until("next wraps") { model.activeThreadFind?.status.label == "1 of 2" }

        try await app.key(kVK_ANSI_F, "f", .command)
        let editor = try XCTUnwrap(app.field("Find in thread")?.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        try app.type("palette-abandoned-branch-marker")
        try await app.until("abandoned branch excluded") { model.activeThreadFind?.status.label == "0 matches" }
        XCTAssertNil(model.activeThreadFind?.selection)
        XCTAssertEqual(model.activeThreadFind?.canStep, false)

        let extra = URL(fileURLWithPath: seed.historyPath).deletingLastPathComponent().appendingPathComponent("extra.jsonl")
        try Data().write(to: extra)
        try app.type(term)
        try await app.until("history read error shown") { model.activeThreadFind?.status.label == "Search failed" }
        try FileManager.default.removeItem(at: extra)
        model.threadFind?.refresh()
        try await app.until("same query succeeds after retry") { model.activeThreadFind?.status.label == "1 of 2" && model.activeThreadFind?.selection?.messageID == seed.messageID }
        XCTAssertEqual(app.field("Find in thread")?.stringValue, term)

        try await app.key(kVK_ANSI_F, "f", [.command, .shift])
        try await app.until("sidebar search took focus") { app.isEditing("Search threads") }
        try app.type("sidebar filter")
        try await app.key(kVK_ANSI_F, "f", .command)
        XCTAssertTrue(app.isEditing("Search threads"))
        try await app.key(kVK_Escape, "\u{1b}")
        XCTAssertTrue(app.isEditing("Search threads"))
        XCTAssertEqual(model.activeThreadFind?.status.label, "1 of 2")
        try app.type("")

        model.openSettings()
        let settings = Hosted(SettingsView(model: model, appearance: AppearanceSettings(defaults: defaults),
                                           browserDefaults: defaults, request: try XCTUnwrap(model.settingsRequest),
                                           openWelcome: {}))
        defer { settings.close() }
        try await settings.key(kVK_ANSI_F, "f", .command)
        try await settings.until("Settings owned Command-F") { settings.isEditing("Search settings") }
        try settings.type("Model ID")
        try await settings.key(kVK_Escape, "\u{1b}")
        XCTAssertEqual(model.activeThreadFind?.status.label, "1 of 2")
        model.settingsRequest = nil

        let scope = SidebarMessageSearch.Thread(projectID: project.id, threadID: active.id)
        let contents = CommandPaletteContents(projects: [project], availableProjects: [project], preferredProject: project.id,
                                             threads: [], activeThread: active.id, canStartScratchThread: true, findThread: scope)
        var paletteFinished = false
        let palette = Hosted(CommandPaletteView(contents: contents, latestMessageID: nil, searchMessages: { _ in [:] }) {
            _ in paletteFinished = true
        })
        defer { palette.close() }
        try await palette.until("palette search took focus") {
            palette.isEditing("Search commands, projects, threads, and messages...")
        }
        try palette.type(">find in current thread")
        XCTAssertEqual(contents.results(for: ">find in current thread", choosingProject: false).first?.action,
                       .findInCurrentThread(scope))
        try await palette.key(kVK_ANSI_F, "f", .command)
        XCTAssertTrue(palette.isEditing("Search commands, projects, threads, and messages..."))
        try await palette.key(kVK_Escape, "\u{1b}")
        XCTAssertTrue(paletteFinished)
        XCTAssertEqual(model.activeThreadFind?.status.label, "1 of 2")

        let terminal = TerminalSessionView(frame: NSRect(x: 0, y: 0, width: 70, height: 48))
        terminal.setPresentation(true, focusRequest: nil)
        app.window.contentView?.addSubview(terminal)
        XCTAssertTrue(app.window.makeFirstResponder(terminal))
        try await app.key(kVK_ANSI_F, "f", .command)
        try await app.key(kVK_ANSI_F, "f", [.command, .shift])
        try await app.key(kVK_Escape, "\u{1b}")
        XCTAssertTrue(app.window.firstResponder === terminal)
        XCTAssertEqual(model.activeThreadFind?.status.label, "1 of 2")
        terminal.removeFromSuperview()

        XCTAssertTrue(app.window.makeFirstResponder(composer))
        try await app.key(kVK_Escape, "\u{1b}")
        try await app.until("Close restored existing composer") { app.field("Find in thread") == nil && app.isEditing("Ask Pi anything") }
        XCTAssertTrue(app.field("Ask Pi anything") === composer)
        XCTAssertEqual(model.draft, "Keep this draft.")
        try await app.key(kVK_ANSI_F, "f", .command)
        try await app.until("Find opened empty again") { app.isEditing("Find in thread") }
        XCTAssertEqual(app.field("Find in thread")?.stringValue, "")
        try await app.key(kVK_Escape, "\u{1b}")
        try await app.until("Escape restored composer") { app.field("Find in thread") == nil && app.isEditing("Ask Pi anything") }

        try await app.key(kVK_ANSI_F, "f", .command)
        try await app.until("Find focused before switching threads") { app.isEditing("Find in thread") }
        try app.type(term)
        model.selectConversation(archived.id, in: project.id)
        try await app.until("archived Pi history opened and previous thread's Find closed") {
            model.phase == .ready && model.messages.first?.id == archivedSeed.messageID && app.field("Find in thread") == nil
        }
        try await app.key(kVK_ANSI_F, "f", .command)
        try await app.until("Find took focus in archive") { app.isEditing("Find in thread") }
        try app.type("archived lantern")
        try await app.until("archived message selected") { model.activeThreadFind?.status.label == "1 of 1" && model.activeThreadFind?.selection?.messageID == archivedSeed.messageID }
        try await app.key(kVK_Escape, "\u{1b}")
        try await app.until("archive remained read-only") { app.field("Find in thread") == nil && app.field("Ask Pi anything") == nil }
    }

    private struct Seed: Decodable {
        let messageID: String
        let latestID: String
        let abandonedID: String
        let historyPath: String
    }

    private func seedHistory(node: String, sidecar: String, package: URL, workspace: URL,
                             project: Project, thread: Conversation, query: String, laterQuery: String) throws -> Seed {
        let writer = Process()
        let output = Pipe()
        writer.executableURL = URL(fileURLWithPath: node)
        writer.arguments = [package.appendingPathComponent("scripts/fixtures/palette-message-history.mjs").path,
                            sidecar, workspace.path, project.id.uuidString, thread.id.uuidString, project.path, query, laterQuery]
        writer.standardOutput = output
        writer.environment = ["PI_OFFLINE": "1", "PI_TELEMETRY": "0", "PI_CODING_AGENT_DIR": workspace.path]
        try writer.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0)
        return try JSONDecoder().decode(Seed.self, from: data)
    }

    @MainActor
    private final class Hosted {
        let window: NSWindow

        init<Content: View>(_ content: Content) {
            _ = NSApplication.shared
            let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
            window = OffscreenFindPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1200, height: 720)),
                                       styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: content)
            window.setFrameOrigin(origin)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
            window.orderBack(nil)
        }

        func close() {
            window.contentView = nil
            window.close()
        }

        func field(_ placeholder: String) -> NSTextField? {
            func find(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
                return view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            return window.contentView.flatMap { find(in: $0) }
        }

        func isEditing(_ placeholder: String) -> Bool {
            guard let editor = field(placeholder)?.currentEditor() else { return false }
            return editor === window.firstResponder
        }

        func press(_ id: String) throws {
            var visited = Set<ObjectIdentifier>()
            func find(in node: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == id { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let match = find(in: child as AnyObject) { return match }
                }
                return nil
            }
            let host = try XCTUnwrap(window.contentView)
            let button = try XCTUnwrap(find(in: host) ?? find(in: window), id)
            XCTAssertTrue(button.accessibilityPerformPress?() == true)
        }

        func type(_ value: String) throws {
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }

        func key(_ code: Int, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: UInt16(code)
            ))
            NSApplication.shared.sendEvent(event)
            try await Task.sleep(for: .milliseconds(25))
        }

        func until(_ description: String, _ matches: () -> Bool) async throws {
            for _ in 0..<120 {
                window.contentView?.layoutSubtreeIfNeeded()
                if matches() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            let message = "Timed out waiting for \(description)."
            XCTFail(message)
            throw WorkspaceError(message)
        }
    }
}

private final class OffscreenFindPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
