import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class DraftProjectPickerTests: XCTestCase {
    func testSearchRecoversFromNoMatchesAndDispatchesKeyboardAndAXSelections() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = try fixture.open()
        defer { model.terminate() }
        var selections: [DraftProjectPicker.Destination?] = []
        let window = DraftPickerOffscreenPanel(model: model) { selections.append($0) }
        defer { window.close() }
        try await window.waitFor("focused search") { window.searchEditor != nil }
        XCTAssertNotNil(window.element("draft-project-search"))

        try window.setQuery("does not exist")
        try await window.waitFor("no-results label") { window.element("draft-project-no-results") != nil }
        XCTAssertNil(window.element("draft-add-project"))
        XCTAssertNil(window.element("draft-no-project"))
        let before = try fixture.saved()
        try window.pinKey()
        try window.key(kVK_Return, "\r")
        XCTAssertEqual(try fixture.saved(), before)
        XCTAssertTrue(selections.isEmpty)

        try window.setQuery("CAFE TOOLS NEXT")
        try await window.waitFor("recovered destination") { window.element(fixture.betaRow) != nil }
        XCTAssertNil(window.element(fixture.alphaRow))
        XCTAssertNil(window.element("draft-project-no-results"))
        try window.key(kVK_Return, "\r")
        XCTAssertEqual(selections, [.project(fixture.beta.id)])

        try window.setQuery("")
        try await window.waitFor("No project and Add project") {
            window.element("draft-no-project") != nil && window.element("draft-add-project") != nil
        }
        for row in ["draft-add-project", "draft-no-project"] {
            // Up wraps from the first project to Add project, then to No project.
            try window.key(kVK_UpArrow, "\u{f700}")
            try window.pinKey()
            XCTAssertEqual(try fixture.saved(), before)
            XCTAssertTrue(window.element(row)?.accessibilityPerformPress?() == true)
        }
        try window.key(kVK_Escape, "\u{1b}")
        XCTAssertEqual(selections, [.project(fixture.beta.id), .addProject, .noProject, nil])
    }

    func testPinActionsKeepQueryOrderHighlightAndSavedDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        weak var closedModel: WorkspaceModel?
        let alphaPin = "draft-project-pin-\(fixture.alpha.id)"
        let betaPin = "draft-project-pin-\(fixture.beta.id)"
        do {
            let model = try fixture.open()
            defer { model.terminate() }
            closedModel = model
            let scope = try XCTUnwrap(model.draftProjectScope)
            var cancellations = 0
            let window = DraftPickerOffscreenPanel(model: model) { destination in
                XCTAssertNil(destination)
                cancellations += 1
            }
            defer { window.close() }
            func checkPin(_ expected: Bool) async throws {
                try fixture.checkSaved(betaPinned: expected)
                XCTAssertEqual(model.draftProjectScope, scope)
                let action = expected ? "Unpin" : "Pin"
                try await window.waitFor("\(action) label for matching project") {
                    window.element(betaPin)?.accessibilityLabel?() == "\(action) \(fixture.beta.title)"
                }
                XCTAssertEqual(window.element(alphaPin)?.accessibilityLabel?(), "Pin \(fixture.alpha.title)")
            }
            try await window.waitFor("focused search") { window.searchEditor != nil }
            try window.checkOrder(fixture.alphaRow, then: fixture.gammaRow)
            try window.checkOrder(fixture.gammaRow, then: fixture.betaRow)
            try window.setQuery(" CAFE ")
            try await window.waitFor("both accent-insensitive matches") {
                window.element(fixture.alphaRow) != nil && window.element(fixture.betaRow) != nil &&
                    window.element("draft-add-project") == nil
            }
            try window.checkOrder(fixture.alphaRow, then: fixture.betaRow)
            try window.key(kVK_DownArrow, "\u{f701}")
            try window.pinKey()
            try await checkPin(true)
            try window.pinKey(repeated: true)
            try fixture.checkSaved(betaPinned: true)
            try window.checkOrder(fixture.alphaRow, then: fixture.betaRow)

            try window.click(betaPin)
            try await checkPin(false)
            XCTAssertEqual(window.searchEditor?.string, " CAFE ")
            try window.click(betaPin)
            try await checkPin(true)
            // The mouse action kept the search editor and its keyboard highlight.
            XCTAssertEqual(window.searchEditor?.string, " CAFE ")
            try window.pinKey()
            try await checkPin(false)
            try window.pinKey()
            try await checkPin(true)
            try window.checkOrder(fixture.alphaRow, then: fixture.betaRow)
            XCTAssertEqual(cancellations, 0)
            try window.key(kVK_Escape, "\u{1b}")
            XCTAssertEqual(cancellations, 1)
            try fixture.checkSaved(betaPinned: true)
            window.close()
            let reopened = DraftPickerOffscreenPanel(model: model) { _ in XCTFail("Unexpected destination") }
            defer { reopened.close() }
            try await reopened.waitFor("picker reopened in pin order") {
                reopened.element(betaPin) != nil && reopened.searchEditor != nil
            }
            try reopened.checkOrder(fixture.alphaRow, then: fixture.betaRow)
            try reopened.checkOrder(fixture.betaRow, then: fixture.gammaRow)
            XCTAssertEqual(reopened.searchEditor?.string, "")
        }

        for _ in 0..<80 where closedModel != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(closedModel, "The previous model still holds the workspace lock.")
        let restored = try fixture.open()
        defer { restored.terminate() }
        XCTAssertEqual(restored.sidebarProjectFilter.selection, [fixture.alpha.id])
        XCTAssertEqual(restored.project?.id, fixture.alpha.id)
        XCTAssertEqual(restored.conversation?.id, fixture.draft.id)
        XCTAssertEqual(restored.draft, fixture.draft.composerText)
        XCTAssertEqual(restored.conversation?.composerAttachments, fixture.draft.composerAttachments)
        let window = DraftPickerOffscreenPanel(model: restored) { _ in XCTFail("Unexpected destination") }
        defer { window.close() }
        try await window.waitFor("restored pinned row") { window.element(betaPin)?.accessibilityLabel?() == "Unpin \(fixture.beta.title)" }
        try window.checkOrder(fixture.alphaRow, then: fixture.betaRow)
        try window.checkOrder(fixture.betaRow, then: fixture.gammaRow)
    }

    func testScratchPickerWithNoRegisteredProjectOffersAddProject() async throws {
        let fixture = try Fixture(scratchOnly: true)
        defer { fixture.close() }
        let model = try fixture.open()
        defer { model.terminate() }
        XCTAssertTrue(model.project?.isScratch == true)
        XCTAssertTrue(model.projects.isEmpty)
        var selections: [DraftProjectPicker.Destination?] = []
        let window = DraftPickerOffscreenPanel(model: model) { selections.append($0) }
        defer { window.close() }
        try await window.waitFor("Add project and focused search") {
            window.element("draft-add-project") != nil && window.searchEditor != nil
        }
        let scratch = try XCTUnwrap(model.project)
        XCTAssertNil(window.element("draft-no-project"))
        XCTAssertNil(window.element("draft-project-pin-\(scratch.id)"))
        let before = try fixture.saved()
        try window.pinKey()
        XCTAssertEqual(try fixture.saved(), before)
        XCTAssertTrue(selections.isEmpty)
        try window.key(kVK_Return, "\r")
        XCTAssertEqual(selections, [.addProject])
    }

    @MainActor
    private final class Fixture {
        let alpha: Project
        let beta: Project
        let gamma: Project
        let draft: Conversation
        private let root: URL
        private let policy: NSApplication.ActivationPolicy
        private var workspaceRoot: URL { root.appending(path: "workspace") }

        var alphaRow: String { "draft-project-\(alpha.id)" }
        var betaRow: String { "draft-project-\(beta.id)" }
        var gammaRow: String { "draft-project-\(gamma.id)" }

        init(scratchOnly: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let alphaFolder = root.appending(path: "first")
            let betaFolder = root.appending(path: "second")
            let gammaFolder = root.appending(path: "third")
            for folder in [alphaFolder, betaFolder, gammaFolder] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let note = try ComposerAttachment(name: "Draft note.txt", payload: ComposerAttachment.payload(for: Data("unsent note".utf8)))
            draft = Conversation(id: UUID(), title: "Current draft", isDraft: true, composerText: "Keep this draft.",
                                 composerAttachments: [note])
            alpha = Project(id: UUID(), path: alphaFolder.path, title: "Café Tools", inSidebarScope: true,
                            conversations: [draft], selectedConversation: draft.id, createdAt: Date(timeIntervalSince1970: 100))
            beta = Project(id: UUID(), path: betaFolder.path, title: "Café Tools Next", createdAt: Date(timeIntervalSince1970: 50))
            gamma = Project(id: UUID(), path: gammaFolder.path, title: "Other project", createdAt: Date(timeIntervalSince1970: 200))
            policy = NSApplication.shared.activationPolicy()
            let store = try WorkspaceStore(root: workspaceRoot)
            let projects = scratchOnly ? [try store.makeScratchProject(for: draft)] : [alpha, beta, gamma]
            try store.save(Workspace(projects: projects, selectedProject: projects.first?.id, welcomeCompleted: true))
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApplication.shared.finishLaunching()
        }

        func saved() throws -> Data { try Data(contentsOf: workspaceRoot.appending(path: "workspace.json")) }

        func checkSaved(betaPinned: Bool) throws {
            let saved = try JSONDecoder().decode(Workspace.self, from: saved())
            XCTAssertEqual(saved.projects.first { $0.id == beta.id }?.pinned == true, betaPinned)
            XCTAssertNil(saved.projects.first { $0.id == alpha.id }?.pinned)
            XCTAssertEqual(saved.projects.filter { $0.inSidebarScope == true }.map(\.id), [alpha.id])
            XCTAssertEqual(saved.selectedProject, alpha.id)
            XCTAssertEqual(saved.activeProject?.selectedConversation, draft.id)
            let persistedDraft = try XCTUnwrap(saved.activeProject?.conversations.first)
            XCTAssertEqual(persistedDraft.id, draft.id)
            XCTAssertEqual(persistedDraft.composerText, draft.composerText)
            XCTAssertEqual(persistedDraft.composerAttachments, draft.composerAttachments)
        }

        func open() throws -> WorkspaceModel {
            let model = WorkspaceModel(root: workspaceRoot, keychainService: UUID().uuidString, readCredential: { _ in nil })
            if let failure = model.startupFailure {
                XCTFail("Could not reopen fixture: \(failure)")
                throw failure
            }
            return model
        }

        func close() {
            NSApplication.shared.setActivationPolicy(policy)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor
private final class DraftPickerOffscreenPanel: NSPanel {
    convenience init(model: WorkspaceModel, finish: @escaping (DraftProjectPicker.Destination?) -> Void) {
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
        self.init(contentRect: NSRect(origin: origin, size: CGSize(width: 340, height: 280)),
                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: DraftProjectPicker(model: model, finish: finish))
        setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(frame) })
        orderBack(nil)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func close() {
        contentView = nil
        super.close()
    }

    var searchEditor: NSTextView? {
        func searchField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Search projects" { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        guard let contentView, let editor = searchField(in: contentView)?.currentEditor() as? NSTextView,
              editor === firstResponder else { return nil }
        return editor
    }

    func setQuery(_ query: String) throws {
        let editor = try XCTUnwrap(searchEditor)
        editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    func element(_ identifier: String) -> AnyObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ node: AnyObject) -> AnyObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.accessibilityIdentifier?() == identifier { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let match = search(child as AnyObject) { return match }
            }
            return nil
        }
        return contentView.flatMap { search($0) } ?? search(self)
    }

    func waitFor(_ description: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<80 {
            contentView?.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(description).")
        throw WorkspaceError("Timed out waiting for \(description).")
    }

    func checkOrder(_ first: String, then second: String) throws {
        let firstFrame = try XCTUnwrap(element(first)?.accessibilityFrame?())
        let secondFrame = try XCTUnwrap(element(second)?.accessibilityFrame?())
        XCTAssertGreaterThan(firstFrame.midY, secondFrame.midY)
    }

    func pinKey(repeated: Bool = false) throws {
        try key(kVK_ANSI_P, "P", modifiers: [.command, .shift], repeated: repeated)
    }

    func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: UInt16(code)
        ))
        NSApplication.shared.sendEvent(event)
    }

    func click(_ identifier: String) throws {
        let frame = try XCTUnwrap(element(identifier)?.accessibilityFrame?())
        let center = convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            NSApplication.shared.sendEvent(event)
        }
    }
}
