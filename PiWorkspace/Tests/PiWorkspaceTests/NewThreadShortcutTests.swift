import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class NewThreadShortcutTests: XCTestCase {
    func testSidebarProjectChoiceFocusesNewDraftAfterWorktreeStorageReset() async throws {
        let fixture = try Fixture(projectCount: 2, fromWorktree: true, keyable: true)
        defer { fixture.close() }
        let project = try XCTUnwrap(fixture.model.project)
        let submitted = try XCTUnwrap(fixture.model.conversation)
        XCTAssertFalse(submitted.isDraft == true)
        try fixture.model.updateWorktreesDirectory(fixture.root.appending(path: "Custom Worktrees").path)
        try await fixture.press("model-settings")
        try await fixture.press("settings-nav-worktrees")
        try await fixture.press("reset-worktree-location")
        XCTAssertNil(fixture.model.workspace.worktreesDirectory)
        try await fixture.press("settings-close")
        try await fixture.resumeAfterSheet()

        let draftID = try await fixture.chooseProjectAndType(project.id)
        XCTAssertNotEqual(draftID, submitted.id)
        let original = fixture.model.project?.conversations.first { $0.id == submitted.id }
        XCTAssertEqual(original?.composerText, submitted.composerText)
        XCTAssertEqual(original?.composerAttachments, submitted.composerAttachments)
    }

    func testSidebarProjectChoiceFocusesSelectedEmptyDraftAndCancelPreservesSearch() async throws {
        let fixture = try Fixture(projectCount: 2, keyable: true)
        defer { fixture.close() }
        let project = try XCTUnwrap(fixture.model.project)
        fixture.model.addConversation(in: project.id)
        let empty = try XCTUnwrap(fixture.model.conversation)
        try await fixture.waitFor("selected draft's editor") {
            (fixture.window.firstResponder as? ComposerTextField.Editor)?.owner?.composerTarget?.threadID == empty.id
        }
        let search = try XCTUnwrap(fixture.textField("Search threads", in: fixture.window))
        XCTAssertTrue(fixture.window.makeFirstResponder(search))
        try await fixture.pressKey(kVK_ANSI_J, "j")
        XCTAssertEqual(search.stringValue, "j")
        let stored = try Data(contentsOf: fixture.index)
        try await fixture.press("new-conversation")
        _ = try await fixture.find("new-thread-project-\(project.id)")
        try await fixture.cancelChooser()
        try await fixture.resumeAfterSheet()
        XCTAssertTrue(fixture.window.firstResponder === search.currentEditor())
        XCTAssertEqual(search.stringValue, "j")
        XCTAssertEqual(try Data(contentsOf: fixture.index), stored)

        let draftID = try await fixture.chooseProjectAndType(project.id)
        XCTAssertEqual(draftID, empty.id)
    }

    func testCommandShiftNStartsLocalDraft() async throws {
        let fixture = try Fixture(projectCount: 2, fromWorktree: true)
        defer { fixture.close() }
        let project = try XCTUnwrap(fixture.model.project)
        let original = try XCTUnwrap(fixture.model.conversation)
        try await fixture.pressKey(kVK_ANSI_N, "N", [.command, .shift])
        XCTAssertEqual(fixture.model.project?.id, project.id)
        XCTAssertNotEqual(fixture.model.conversation?.id, original.id)
        XCTAssertEqual(fixture.model.conversation?.isDraft, true)
        XCTAssertEqual(fixture.model.conversation?.workingLocation, .project)
        XCTAssertEqual(fixture.model.workingDirectory, project.path)
        let saved = try XCTUnwrap(fixture.saved().activeProject?.conversations.first { $0.id == original.id })
        XCTAssertEqual(saved.workingLocation, original.workingLocation)
        XCTAssertEqual(saved.composerText, original.composerText)
        XCTAssertEqual(saved.composerAttachments, original.composerAttachments)
        let empty = fixture.model.conversation?.id
        try await fixture.pressKey(kVK_ANSI_N, "N", [.command, .shift])
        XCTAssertEqual(fixture.model.conversation?.id, empty)
    }

    func testNewThreadKeysChooseAcrossProjectsAndCancelWithoutChanges() async throws {
        let fixture = try Fixture(projectCount: 2)
        defer { fixture.close() }
        let projects = fixture.model.projects
        let current = try XCTUnwrap(projects.last)
        fixture.model.updateSidebarScope { $0.selectOnly(projects[0].id) }
        let before = try Data(contentsOf: fixture.index)
        for (code, characters, modifiers) in Self.newThreadKeys.prefix(2) {
            try await fixture.pressKey(code, characters, modifiers)
            _ = try await fixture.find("command-palette-new-thread-project-\(current.id)")
            _ = try await fixture.find("command-palette-new-thread-project-\(projects[0].id)")
            try await fixture.cancelChooser()
            XCTAssertEqual(try Data(contentsOf: fixture.index), before)
        }
        try await fixture.press("new-conversation")
        try await fixture.waitFor("draft in the scoped project") {
            fixture.model.project?.id == projects[0].id && fixture.model.conversation?.isDraft == true
        }
        XCTAssertEqual(fixture.model.sidebarProjectFilter.selection, [projects[0].id])
        try await fixture.pressKey(kVK_ANSI_O, "O", [.command, .shift])
        try await fixture.press("command-palette-new-thread-project-\(current.id)")
        try await fixture.waitFor("draft in the chosen project") {
            fixture.model.project?.id == current.id && fixture.model.conversation?.isDraft == true
        }
    }

    func testNewThreadKeysWithOneOrZeroProjects() async throws {
        for (code, characters, modifiers) in Self.newThreadKeys.prefix(2) {
            let fixture = try Fixture(projectCount: 1)
            defer { fixture.close() }
            let project = try XCTUnwrap(fixture.model.project)
            try await fixture.pressKey(code, characters, modifiers)
            XCTAssertEqual(fixture.model.project?.id, project.id)
            XCTAssertEqual(fixture.model.conversation?.isDraft, true)
            XCTAssertFalse(fixture.model.showingCommandPalette)
        }
        let fixture = try Fixture(projectCount: 0)
        defer { fixture.close() }
        let before = try Data(contentsOf: fixture.index)
        for (code, characters, modifiers) in Self.newThreadKeys.prefix(3) {
            try await fixture.pressKey(code, characters, modifiers)
            _ = try await fixture.find("command-palette-no-project")
            try await fixture.cancelChooser()
            XCTAssertEqual(try Data(contentsOf: fixture.index), before)
        }
    }

    func testHeaderAndPaletteUseCurrentProjectThenHomeUsesLastProject() async throws {
        let fixture = try Fixture(projectCount: 2, isDraft: true)
        defer { fixture.close() }
        let current = try XCTUnwrap(fixture.model.project)
        let original = try XCTUnwrap(fixture.model.conversation)
        let other = try XCTUnwrap(fixture.model.projects.first)
        fixture.model.updateSidebarScope { $0.selectOnly(other.id) }

        try await fixture.press("thread-project-new-thread")
        XCTAssertEqual(fixture.model.project?.id, current.id)
        let headerDraft = try XCTUnwrap(fixture.model.conversation?.id)
        XCTAssertNotEqual(headerDraft, original.id)
        fixture.model.draft = "Keep the header draft"

        fixture.model.updateSidebarScope { $0.selectOnly(other.id) }
        try await fixture.pressKey(kVK_ANSI_K, "k", .command)
        try await fixture.press("command-palette-new-thread-in-context-\(current.id)")
        try await fixture.waitFor("new draft in current project") { fixture.model.conversation?.id != headerDraft }
        let paletteDraft = try XCTUnwrap(fixture.model.conversation?.id)
        fixture.model.draft = "Keep the palette draft"

        fixture.model.showHome()
        XCTAssertNil(fixture.model.project)
        try await fixture.pressKey(kVK_ANSI_N, "N", [.command, .shift])
        XCTAssertEqual(fixture.model.project?.id, current.id)
        XCTAssertNotEqual(fixture.model.conversation?.id, paletteDraft)
        let drafts = try XCTUnwrap(fixture.saved().activeProject?.conversations)
        XCTAssertEqual(drafts.first { $0.id == original.id }?.composerText, original.composerText)
        XCTAssertEqual(drafts.first { $0.id == headerDraft }?.composerText, "Keep the header draft")
        XCTAssertEqual(drafts.first { $0.id == paletteDraft }?.composerText, "Keep the palette draft")
    }

    func testScratchRoutesEachRegisterOnePrivateDraft() async throws {
        let fixture = try Fixture(projectCount: 2)
        defer { fixture.close() }
        let registered = fixture.model.projects.map(\.id)

        try await fixture.pressKey(kVK_ANSI_N, "n", [.command, .option])
        try await fixture.assertScratch(count: 1)

        try await fixture.pressKey(kVK_ANSI_K, "k", .command)
        try await fixture.press("command-palette-new-thread-without-project")
        try await fixture.assertScratch(count: 2)

        try await fixture.pressKey(kVK_ANSI_N, "N", [.command, .shift])
        XCTAssertEqual(fixture.model.project?.id, registered.last)
        try await fixture.pressKey(kVK_ANSI_O, "O", [.command, .shift])
        try await fixture.press("command-palette-no-project")
        try await fixture.assertScratch(count: 3)
        XCTAssertEqual(try fixture.saved().projects.filter { !$0.isScratch }.map(\.id), registered)
    }

    func testTerminalAndOpenPickerLeaveNewThreadKeysUnclaimed() async throws {
        let fixture = try Fixture(projectCount: 2)
        defer { fixture.close() }
        _ = try await fixture.find("thread-project-new-thread")
        let terminal = TerminalSessionView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        terminal.setPresentation(true, focusRequest: nil)
        fixture.window.contentView?.addSubview(terminal)
        let before = try Data(contentsOf: fixture.index)
        for (code, characters, modifiers) in Self.newThreadKeys {
            try await fixture.pressKey(code, characters, modifiers, responder: terminal)
            XCTAssertFalse(fixture.model.showingCommandPalette)
            XCTAssertEqual(try Data(contentsOf: fixture.index), before)
        }
        terminal.removeFromSuperview()

        try await fixture.pressKey(kVK_ANSI_K, "k", .command)
        _ = try await fixture.find("command-palette-search")
        for (code, characters, modifiers) in Self.newThreadKeys {
            try await fixture.pressKey(code, characters, modifiers)
            XCTAssertTrue(fixture.model.showingCommandPalette)
            XCTAssertEqual(try Data(contentsOf: fixture.index), before)
        }
        try await fixture.cancelChooser()
    }

    func testNewThreadKeysPreserveQueuedEdit() async throws {
        let fixture = try Fixture(projectCount: 1)
        defer { fixture.close() }
        let queued = try XCTUnwrap(fixture.model.queuedMessages.first)
        fixture.model.editQueuedMessage(queued.id)
        fixture.model.draft = "Edited queue message"
        XCTAssertEqual(fixture.model.editingQueuedMessageID, queued.id)
        let before = try Data(contentsOf: fixture.index)
        for (code, characters, modifiers) in Self.newThreadKeys {
            try await fixture.pressKey(code, characters, modifiers)
            XCTAssertEqual(fixture.model.editingQueuedMessageID, queued.id)
            XCTAssertEqual(fixture.model.draft, "Edited queue message")
            XCTAssertEqual(try Data(contentsOf: fixture.index), before)
        }
    }

    func testAddExistingProjectFromNewProjectForm() async throws {
        let fixture = try Fixture(projectCount: 2)
        defer { fixture.close() }
        let original = try XCTUnwrap(fixture.model.project)
        let projectIDs = fixture.model.projects.map(\.id)
        try await fixture.press("open-project")
        try await fixture.press("project-source-new")
        _ = try await fixture.find("project-name")
        try fixture.enterProjectName("Name already typed")
        try await fixture.press("project-source-existing")
        _ = try await fixture.find("project-source-clone")
        try await fixture.press("project-source-local")
        try await fixture.press("confirm-project")
        try await fixture.waitFor("project picker to close") { fixture.model.projectPicker == nil }
        XCTAssertEqual(try fixture.saved().projects.map(\.id), projectIDs)
        XCTAssertEqual(fixture.model.project?.id, original.id)
        XCTAssertEqual(fixture.model.conversation?.id, original.selectedConversation)
    }

    private static let newThreadKeys: [(Int, String, NSEvent.ModifierFlags)] = [
        (kVK_ANSI_N, "n", .command),
        (kVK_ANSI_O, "O", [.command, .shift]),
        (kVK_ANSI_N, "N", [.command, .shift]),
        (kVK_ANSI_N, "n", [.command, .option])
    ]

    private struct TestWorkspace: View {
        @ObservedObject var model: WorkspaceModel
        let defaults: UserDefaults
        let pasteboard: NSPasteboard

        var body: some View {
            WorkspaceView(model: model, chatWidthMode: .full, browserDefaults: defaults, workspacePasteboard: pasteboard)
                .sheet(item: $model.settingsRequest) { request in
                    SettingsView(model: model, appearance: AppearanceSettings(defaults: defaults), browserDefaults: defaults,
                                 request: request, pasteboard: pasteboard, openWelcome: {})
                }
        }
    }

    private final class Panel: NSPanel {
        override var canBecomeMain: Bool { false }
        var keyable = false
        override var canBecomeKey: Bool { keyable }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

        override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
            sheetWindow.alphaValue = 0
            super.beginSheet(sheetWindow, completionHandler: handler)
            sheetWindow.setFrameOrigin(frame.origin)
        }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let model: WorkspaceModel
        let window: NSWindow
        private let app = NSApplication.shared
        private let policy: NSApplication.ActivationPolicy
        private let defaults: UserDefaults
        private let namespace = "NewThreadShortcutTests.\(UUID())"
        private let pasteboard = NSPasteboard.withUniqueName()
        var index: URL { root.appending(path: "workspace/workspace.json") }

        init(projectCount: Int, fromWorktree: Bool = false, isDraft: Bool = false, keyable: Bool = false) throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
            self.root = root
            let workspaceRoot = root.appendingPathComponent("workspace")
            let projects = try (0..<projectCount).map { index in
                let folder = root.appendingPathComponent("Project-\(index)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var location: ThreadLocation?
                if fromWorktree {
                    let checkout = root.appendingPathComponent("Checkout-\(index)")
                    try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
                    location = .worktree(path: checkout.path, base: "main")
                }
                let attachment = try ComposerAttachment(name: "Draft file.txt", payload: ComposerAttachment.payload(for: Data("Keep this file".utf8)))
                let thread = Conversation(id: UUID(), title: "Original", location: location, isDraft: isDraft,
                                          composerText: "Keep this input", composerAttachments: [attachment],
                                          queuedMessages: isDraft ? nil : [QueuedMessage(text: "Original queue message")])
                return Project(id: UUID(), path: try ProjectFolder.existing(at: folder).path, title: folder.lastPathComponent,
                               conversations: [thread], selectedConversation: thread.id)
            }
            try WorkspaceStore(root: workspaceRoot).save(
                Workspace(projects: projects, selectedProject: projects.last?.id, welcomeCompleted: true,
                          addProjectBaseDirectory: projects.last?.path)
            )
            model = WorkspaceModel(root: workspaceRoot, keychainService: namespace, readCredential: { _ in nil }) { _, _ in
                throw WorkspaceError("No Pi helper in this test.")
            }
            if let failure = model.startupFailure { throw failure }
            defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
            let host = NSHostingView(rootView: TestWorkspace(model: model, defaults: defaults, pasteboard: pasteboard)
                .defaultAppStorage(defaults))
            policy = app.activationPolicy()
            app.setActivationPolicy(.prohibited)
            app.finishLaunching()
            let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
            let panel = Panel(contentRect: NSRect(origin: origin, size: CGSize(width: 1050, height: 700)),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.setFrameOrigin(origin)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(panel.frame) })
            panel.keyable = keyable
            panel.orderBack(nil)
            if keyable { panel.makeKey() }
            window = panel
        }

        func close() {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentView = nil
            window.close()
            model.terminate()
            defaults.removePersistentDomain(forName: namespace)
            pasteboard.releaseGlobally()
            app.setActivationPolicy(policy)
            try? FileManager.default.removeItem(at: root)
        }

        func pressKey(_ code: Int, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [],
                      target: NSWindow? = nil, responder: NSResponder? = nil) async throws {
            let target = target ?? window
            target.contentView?.layoutSubtreeIfNeeded()
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: target.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
            ))
            if let responder {
                XCTAssertTrue(target.makeFirstResponder(responder))
                XCTAssertTrue(target.firstResponder === responder)
            }
            app.sendEvent(event)
            if let responder { XCTAssertTrue(target.firstResponder === responder) }
            try await Task.sleep(for: .milliseconds(30))
        }

        func saved() throws -> Workspace {
            try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
        }

        func assertScratch(count: Int) async throws {
            try await waitFor("scratch draft \(count)") {
                model.project?.isScratch == true && model.threadProjects.filter(\.isScratch).count == count
            }
            let projects = try saved().projects.filter(\.isScratch)
            XCTAssertEqual(projects.count, count)
            XCTAssertEqual(Set(projects.map(\.path)).count, count)
            XCTAssertTrue(projects.allSatisfy { $0.conversations.count == 1 && $0.conversations[0].isDraft == true })
            let scratchRoot = root.appending(path: "workspace/scratch").resolvingSymlinksInPath().path
            XCTAssertTrue(projects.allSatisfy { $0.path.hasPrefix(scratchRoot + "/") })
        }

        func cancelChooser() async throws {
            let sheet = try XCTUnwrap(window.attachedSheet)
            try await pressKey(kVK_Escape, "\u{1b}", target: sheet)
            try await waitFor("project chooser to close") { !model.showingCommandPalette && window.attachedSheet == nil }
        }

        func press(_ id: String) async throws {
            let button = try await find(id)
            XCTAssertTrue(button.accessibilityPerformPress?() == true, id)
        }

        func resumeAfterSheet() async throws {
            try await waitFor("sheet to dismiss") { window.attachedSheet == nil }
            // The inactive test application doesn't automatically return key status to its parent panel.
            window.makeKey()
            XCTAssertTrue(window.isKeyWindow)
        }

        func chooseProjectAndType(_ projectID: UUID) async throws -> UUID {
            try await press("new-conversation")
            try await press("new-thread-project-\(projectID)")
            try await resumeAfterSheet()
            let draft = try XCTUnwrap(model.conversation)
            XCTAssertEqual(model.project?.id, projectID)
            XCTAssertEqual(draft.isDraft, true)
            XCTAssertEqual(model.draft, "")

            let editor = window.firstResponder as? ComposerTextField.Editor
            let owner = editor?.owner
            XCTAssertEqual(owner?.composerTarget?.threadID, draft.id)
            XCTAssertEqual(owner?.accessibilityIdentifier(), "composer")
            XCTAssertNotNil(editor)
            XCTAssertTrue(owner?.currentEditor() === editor)
            XCTAssertEqual(editor?.selectedRange(), NSRange(location: 0, length: 0))
            try await pressKey(kVK_ANSI_X, "x")
            XCTAssertEqual(model.draft, "x")
            XCTAssertEqual(model.conversation?.id, draft.id)
            XCTAssertEqual(editor?.selectedRange(), NSRange(location: 1, length: 0))
            return draft.id
        }

        func textField(_ placeholder: String, in window: NSWindow) -> NSTextField? {
            func find(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
                return view.subviews.lazy.compactMap(find).first
            }
            return window.contentView.flatMap(find)
        }

        func enterProjectName(_ name: String) throws {
            let sheet = try XCTUnwrap(window.attachedSheet)
            let field = try XCTUnwrap(textField("Enter a project name", in: sheet))
            XCTAssertTrue(sheet.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(name, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            XCTAssertEqual(editor.string, name)
        }

        func find(_ id: String) async throws -> AnyObject {
            var element: AnyObject?
            try await waitFor(id) {
                var visited = Set<ObjectIdentifier>()
                func find(_ node: AnyObject) -> AnyObject? {
                    guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                    if node.accessibilityIdentifier?() == id { return node }
                    for child in node.accessibilityChildren?() ?? [] {
                        if let match = find(child as AnyObject) { return match }
                    }
                    return nil
                }
                element = (window.attachedSheet?.contentView).flatMap(find) ?? window.contentView.flatMap(find)
                return element != nil
            }
            return try XCTUnwrap(element)
        }

        func waitFor(_ description: String, _ condition: () -> Bool) async throws {
            for _ in 0..<80 {
                window.contentView?.layoutSubtreeIfNeeded()
                if let sheet = window.attachedSheet {
                    XCTAssertEqual(sheet.alphaValue, 0)
                    sheet.contentView?.layoutSubtreeIfNeeded()
                }
                if condition() { return }
                try await Task.sleep(for: .milliseconds(15))
            }
            XCTFail("Timed out waiting for \(description).")
            throw WorkspaceError("Timed out waiting for \(description).")
        }
    }
}
