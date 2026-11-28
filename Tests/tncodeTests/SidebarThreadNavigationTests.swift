import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import tncode

@MainActor
final class SidebarThreadNavigationTests: XCTestCase {
    func testTraversalAndNumberedJumpsUseVisibleOrderAndVisitHistory() async throws {
        let ui = try Fixture()
        defer { ui.close() }
        try await ui.ready()
        try await ui.expect(ui.draft)
        try await ui.type(kVK_ANSI_X, "x", atEndOf: ui.draft)

        try await ui.previous()
        try await ui.expect(ui.linked, directory: ui.checkout)
        try await ui.previous()
        try await ui.expect(ui.pinned)
        try await ui.previous()
        try await ui.expect(ui.pinned)
        try await ui.next(repeatKey: true)
        try await ui.expect(ui.pinned)
        try await ui.next()
        try await ui.expect(ui.linked, directory: ui.checkout)
        try await ui.jump(4)
        try await ui.expect(ui.active)
        try await ui.next()
        try await ui.jump(5)
        try await ui.expect(ui.active)
        try await ui.press("workspace-history-back")
        try await ui.expect(ui.linked, directory: ui.checkout)
        try await ui.press("workspace-history-forward")
        try await ui.expect(ui.active)
        try await ui.jump(3)
        try await ui.expect(ui.draft)
        XCTAssertEqual(ui.model.draft, "Alpha draftx")

        let saved = try ui.saved()
        let draft = try XCTUnwrap(saved.projects.flatMap(\.conversations).first { $0.id == ui.draft.id })
        let linked = try XCTUnwrap(saved.projects.flatMap(\.conversations).first { $0.id == ui.linked.id })
        XCTAssertEqual(draft.composerText, "Alpha draftx")
        XCTAssertEqual(draft.composerAttachments, ui.draft.composerAttachments)
        XCTAssertEqual(linked.queuedMessages, ui.linked.queuedMessages)
        XCTAssertEqual(linked.workingLocation, ui.linked.workingLocation)

        try await ui.press("sidebar-home")
        try await ui.previous()
        try await ui.expect(ui.active)
        try await ui.press("sidebar-home")
        try await ui.next()
        try await ui.expect(ui.pinned)
    }

    func testGroupingProjectScopeAndSearchUseTheRowsOnDisplay() async throws {
        let ui = try Fixture(grouped: true)
        defer { ui.close() }
        try await ui.ready()
        try await ui.jump(2)
        try await ui.expect(ui.draft)
        try await ui.jump(3)
        try await ui.expect(ui.active)
        try await ui.jump(4)
        try await ui.expect(ui.linked, directory: ui.checkout)

        try await ui.press("project-group-\(ui.alpha)")
        await ui.settle()
        XCTAssertNil(ui.element("thread-row-\(ui.draft.id)"))
        try await ui.jump(1)
        try await ui.expect(ui.pinned)
        XCTAssertEqual(try ui.saved().projects.first { $0.id == ui.alpha }?.sidebarFolderCollapsed, true)
        try await ui.next()
        try await ui.expect(ui.linked, directory: ui.checkout)

        ui.model.updateSidebarScope { $0.selectOnly(ui.alpha) }
        await ui.settle()
        try await ui.previous()
        try await ui.jump(2)
        try await ui.expect(ui.linked, directory: ui.checkout)
        try await ui.jump(1)
        try await ui.expect(ui.pinned)
        XCTAssertEqual(ui.model.sidebarProjectFilter.selection, [ui.alpha])

        try await ui.search("Find this")
        XCTAssertNotNil(ui.element("thread-row-\(ui.active.id)"))
        XCTAssertNil(ui.element("thread-row-\(ui.pinned.id)"))
        try await ui.jump(1)
        try await ui.expect(ui.active)
        XCTAssertEqual(ui.model.sidebarProjectFilter.selection, [ui.alpha])

        try await ui.search("no matches")
        try await ui.jump(1)
        try await ui.next()
        try await ui.expect(ui.active)
    }

    func testNumberedJumpsStopAtNineAndSettledRowsFollowTheirDisclosure() async throws {
        let ui = try Fixture(additionalCount: 6)
        defer { ui.close() }
        try await ui.ready()
        try await ui.jump(9)
        try await ui.expect(ui.additional[4])
        try await ui.next()
        try await ui.expect(ui.additional[5])
        try await ui.next()
        try await ui.expect(ui.additional[5])

        let disclosure = try XCTUnwrap(ui.element("settled-shelf"))
        XCTAssertTrue(disclosure.accessibilityPerformPress?() == true)
        await ui.settle()
        try await ui.next()
        try await ui.expect(ui.settled)
        try await ui.next()
        try await ui.expect(ui.settled)
        try await ui.previous()
        try await ui.expect(ui.additional[5])
    }

    func testModalMarkedTextAndQueueOwnTheWindowWhileTerminalKeepsBracketKeys() async throws {
        let ui = try Fixture()
        defer { ui.close() }
        try await ui.ready()
        let marked = try await ui.editor(for: ui.draft)
        marked.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(marked.hasMarkedText())
        try await ui.jump(2)
        try await ui.previous()
        try await ui.expect(ui.draft)
        marked.unmarkText()

        try await ui.key(kVK_ANSI_K, "k")
        try await ui.waitFor("command palette sheet") { ui.window.attachedSheet != nil }
        let beforeSheet = try Data(contentsOf: ui.index)
        try await ui.jump(2)
        try await ui.next()
        let sheet = try XCTUnwrap(ui.window.attachedSheet)
        try await ui.key(kVK_ANSI_2, "2", target: sheet)
        try await ui.expect(ui.draft)
        XCTAssertEqual(try Data(contentsOf: ui.index), beforeSheet)
        try await ui.key(kVK_Escape, "\u{1b}", modifiers: [], target: sheet)
        try await ui.waitFor("command palette closed") { ui.window.attachedSheet == nil }
        ui.window.makeKey()

        try await ui.press("active-model")
        try await ui.waitFor("model picker") { ui.element("composer-model-picker") != nil }
        try await ui.jump(2)
        try await ui.previous()
        try await ui.expect(ui.draft)
        try await ui.key(kVK_Escape, "\u{1b}", modifiers: [])
        try await ui.waitFor("model picker closed") { ui.element("composer-model-picker") == nil }

        try await ui.jump(2)
        try await ui.expect(ui.linked, directory: ui.checkout)
        let queued = try XCTUnwrap(ui.linked.queuedMessages?.first)
        ui.model.editQueuedMessage(queued.id)
        try await ui.type(kVK_ANSI_X, "x", atEndOf: ui.linked)
        XCTAssertEqual(ui.model.draft, queued.text + "x")
        try await ui.jump(1)
        try await ui.next()
        try await ui.expect(ui.linked, directory: ui.checkout)
        XCTAssertEqual(ui.model.editingQueuedMessageID, queued.id)
        XCTAssertEqual(ui.model.draft, queued.text + "x")
        ui.model.updateQueuedMessage()
        XCTAssertNil(ui.model.editingQueuedMessageID)

        await ui.settle()
        try await ui.press("toggle-terminal")
        try await ui.waitFor("terminal first responder") { ThreadTerminal.hasFocus(in: ui.window) }
        try await ui.next()
        try await ui.previous()
        XCTAssertTrue(ThreadTerminal.hasFocus(in: ui.window))
        try await ui.expect(ui.linked, directory: ui.checkout)
        try await ui.jump(3)
        try await ui.expect(ui.draft)
        _ = try await ui.editor(for: ui.draft)
        let saved = try XCTUnwrap(ui.saved().projects.flatMap(\.conversations).first { $0.id == ui.linked.id })
        XCTAssertEqual(saved.queuedMessages?.first?.text, queued.text + "x")
        XCTAssertEqual(saved.composerText, ui.linked.composerText)
        XCTAssertEqual(saved.workingLocation, ui.linked.workingLocation)
    }

    private final class OffscreenPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
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
        let alpha = UUID()
        let beta = UUID()
        let draft: Conversation
        let pinned: Conversation
        let linked: Conversation
        let active: Conversation
        let settled: Conversation
        let additional: [Conversation]
        let checkout: String
        let alphaPath: String
        private let app = NSApplication.shared
        private let policy: NSApplication.ActivationPolicy
        private let namespace = "SidebarThreadNavigationTests.\(UUID())"
        private let defaults: UserDefaults
        var index: URL { root.appending(path: "workspace.json") }

        init(grouped: Bool = false, additionalCount: Int = 0) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "sidebar-thread-navigation-\(UUID())")
            alphaPath = root.appending(path: "Alpha").path
            let betaPath = root.appending(path: "Beta").path
            checkout = root.appending(path: "Linked checkout").path
            for path in [alphaPath, betaPath] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            func git(_ arguments: String...) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", betaPath] + arguments
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw WorkspaceError("Could not prepare the linked checkout.")
                }
            }
            try git("init", "--template=", "-q", "-b", "main")
            try git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "Fixture")
            try git("worktree", "add", "-qb", "linked", checkout)
            func at(_ order: Double) -> Date { Date(timeIntervalSince1970: order) }
            let attachment = try ComposerAttachment(name: "draft.txt", payload: ComposerAttachment.payload(for: Data("Draft attachment".utf8)))
            draft = Conversation(id: UUID(), title: "Alpha draft", lastActiveAt: at(40), isDraft: true,
                                 composerText: "Alpha draft", composerAttachments: [attachment])
            pinned = Conversation(id: UUID(), title: "Same title", lastActiveAt: at(1), shelf: .pinned)
            linked = Conversation(id: UUID(), title: "Same title", lastActiveAt: at(50),
                                  location: .worktree(path: checkout, base: "main"), composerText: "Linked draft",
                                  queuedMessages: [QueuedMessage(text: "Linked queue")])
            active = Conversation(id: UUID(), title: "Find this thread", lastActiveAt: at(20))
            settled = Conversation(id: UUID(), title: "Settled thread", lastActiveAt: at(60), shelf: .settled)
            additional = (0..<additionalCount).map {
                Conversation(id: UUID(), title: "Other \($0)", lastActiveAt: at(-Double($0)))
            }
            try WorkspaceStore(root: root).save(Workspace(projects: [
                Project(id: alpha, path: alphaPath, title: "Alpha", conversations: [pinned, draft, active, settled] + additional,
                        selectedConversation: draft.id),
                Project(id: beta, path: betaPath, title: "Beta", conversations: [linked], selectedConversation: linked.id)
            ], selectedProject: alpha, welcomeCompleted: true))
            model = WorkspaceModel(root: root, keychainService: namespace, readCredential: { _ in nil }) { _, _ in
                throw WorkspaceError("No Pi process in this fixture.")
            }
            if let failure = model.startupFailure { throw failure }
            defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
            defaults.set(grouped, forKey: SidebarPreference.groupByProject)
            policy = app.activationPolicy()
            app.setActivationPolicy(.prohibited)
            app.finishLaunching()
            let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
            let panel = OffscreenPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 1180, height: 800)),
                                       styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable)
                .defaultAppStorage(defaults))
            panel.setFrameOrigin(origin)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(panel.frame) })
            panel.orderBack(nil)
            panel.makeKey()
            window = panel
        }

        func close() {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentView = nil
            window.close()
            model.terminate()
            defaults.removePersistentDomain(forName: namespace)
            app.setActivationPolicy(policy)
            try? FileManager.default.removeItem(at: root)
        }

        func ready() async throws {
            XCTAssertGreaterThan(window.windowNumber, 0)
            try await waitFor("workspace controls") { element("sidebar-home") != nil }
            _ = try await editor(for: draft)
        }

        func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = .command,
                 repeatKey: Bool = false, target: NSWindow? = nil) async throws {
            let target = target ?? window
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: target.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: UInt16(code)
            ))
            XCTAssertTrue(event.window === target)
            app.sendEvent(event)
            await settle()
        }

        func previous() async throws {
            try await key(kVK_ANSI_LeftBracket, "{", modifiers: [.command, .shift])
        }

        func next(repeatKey: Bool = false) async throws {
            try await key(kVK_ANSI_RightBracket, "}", modifiers: [.command, .shift], repeatKey: repeatKey)
        }

        func jump(_ number: Int) async throws {
            let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                         kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            try await key(codes[number - 1], String(number))
        }

        func saved() throws -> Workspace {
            try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
        }

        func expect(_ thread: Conversation, directory: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws {
            XCTAssertEqual(model.conversation?.id, thread.id, file: file, line: line)
            XCTAssertEqual(model.workingDirectory, directory ?? alphaPath, file: file, line: line)
            XCTAssertEqual(try saved().activeProject?.selectedConversation, thread.id, file: file, line: line)
        }

        func type(_ code: Int, _ characters: String, atEndOf thread: Conversation) async throws {
            let editor = try await editor(for: thread)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            try await key(code, characters, modifiers: [])
        }

        func editor(for thread: Conversation) async throws -> ComposerTextField.Editor {
            let target = model.attachmentTarget(for: thread.id)
            let matches = { (field: NSTextField) in (field as? ComposerTextField.Field)?.composerTarget == target }
            try await waitFor("composer for \(thread.title)") {
                self.textField(matching: matches) != nil
            }
            let field = try XCTUnwrap(textField(matching: matches))
            XCTAssertTrue(window.makeFirstResponder(field))
            return try XCTUnwrap(field.currentEditor() as? ComposerTextField.Editor)
        }

        func search(_ text: String) async throws {
            let field = try XCTUnwrap(textField { $0.placeholderString == "Search threads" })
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            await settle()
        }

        private func textField(matching matches: (NSTextField) -> Bool) -> NSTextField? {
            func field(in view: NSView) -> NSTextField? {
                if let textField = view as? NSTextField, matches(textField) { return textField }
                for subview in view.subviews {
                    if let match = field(in: subview) { return match }
                }
                return nil
            }
            return window.contentView.flatMap(field)
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
            return window.contentView.flatMap(find)
        }

        func press(_ id: String) async throws {
            try await waitFor(id) { element(id) != nil }
            let item = try XCTUnwrap(element(id))
            XCTAssertTrue(item.accessibilityPerformPress?() == true, id)
            await settle()
        }

        func settle() async {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func waitFor(_ description: String, _ condition: () -> Bool) async throws {
            for _ in 0..<60 {
                if condition() { return }
                await settle()
            }
            XCTFail("Timed out waiting for \(description).")
            throw WorkspaceError("Timed out waiting for \(description).")
        }
    }
}
