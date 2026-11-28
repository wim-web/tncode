import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import tncode

@MainActor
final class ComposerStashTests: XCTestCase {
    func testStashRestoreAndDeleteBetweenProjectsAfterRelaunch() async throws {
        let fixture = Fixture()
        let file = fixture.attachment
        let queue = QueuedMessage(text: "queued", attachments: [file])
        let source = Conversation(id: UUID(), title: "Source", composerText: " \nHello 🌱\u{FEFF}",
                                  composerAttachments: [file], queuedMessages: [queue])
        let sameFile = ComposerAttachment(name: file.name, payload: file.payload)
        let destination = Conversation(id: UUID(), title: "Destination", composerText: "  Existing text \n\t",
                                       composerAttachments: [sameFile])
        let project = fixture.project(for: source)
        let otherProject = fixture.project(for: destination)
        try fixture.save([project, otherProject])
        let entries: [UUID]
        do {
            let model = fixture.open()
            model.editQueuedMessage(queue.id)
            model.draft = "Uncommitted queue edit"
            XCTAssertFalse(model.stashCurrentPrompt())
            XCTAssertTrue(model.stashedPrompts.isEmpty)
            model.cancelQueuedMessageEdit()
            XCTAssertTrue(model.stashCurrentPrompt())
            model.draft = "Hello 🌱"
            XCTAssertTrue(model.stashCurrentPrompt())
            entries = model.stashedPrompts.map(\.id)
            XCTAssertEqual(Set(entries).count, 2)
            XCTAssertEqual(model.stashedPrompts.map(\.prompt), ["Hello 🌱", "Hello 🌱"])
            XCTAssertTrue(model.terminate())
        }

        do {
            let model = fixture.open()
            XCTAssertEqual(model.stashedPrompts.map(\.id), entries)
            let oldScope = try XCTUnwrap(model.draftProjectScope)
            model.selectConversation(destination.id, in: otherProject.id)
            let scope = try XCTUnwrap(model.draftProjectScope)
            XCTAssertFalse(model.restoreStashedPrompt(entries[1], to: oldScope))
            XCTAssertTrue(model.restoreStashedPrompt(entries[1], to: scope))
            XCTAssertFalse(model.restoreStashedPrompt(entries[1], to: scope))
            XCTAssertEqual(model.draft, "  Existing text\n\nHello 🌱")
            XCTAssertEqual(model.composerAttachments, [sameFile, file])
            XCTAssertTrue(model.deleteStashedPrompt(entries[0]))
            XCTAssertFalse(model.deleteStashedPrompt(entries[0]))
            XCTAssertTrue(model.terminate())
        }

        let saved = try fixture.saved()
        XCTAssertNil(saved.stashedPrompts)
        XCTAssertEqual(saved.activeProject?.conversations.first?.composerAttachments, [sameFile, file])
        let savedSource = try XCTUnwrap(saved.projects.first?.conversations.first)
        XCTAssertNil(savedSource.composerText)
        XCTAssertNil(savedSource.composerAttachments)
        XCTAssertEqual(savedSource.queuedMessages?.map(\.id), [queue.id])
        XCTAssertEqual(savedSource.queuedMessages?.first?.attachments, [file])
    }

    func testStashEvictsOnlyTheOldestEntryAtTheLimit() async throws {
        let fixture = Fixture()
        let source = Conversation(id: UUID(), title: "Source")
        try fixture.save([fixture.project(for: source)])
        let model = fixture.open()
        for number in 0...StashedPrompt.maxCount {
            model.draft = "Prompt \(number)"
            XCTAssertTrue(model.stashCurrentPrompt())
        }
        XCTAssertEqual(try fixture.saved().stashedPrompts?.map(\.prompt),
                       (1...StashedPrompt.maxCount).reversed().map { "Prompt \($0)" })
    }

    func testFailedWritesKeepBothOwnersAndCanBeRetried() async throws {
        let fixture = Fixture()
        let source = Conversation(id: UUID(), title: "Source", composerText: "Saved")
        try fixture.save([fixture.project(for: source)])
        let model = fixture.open()
        let scope = try XCTUnwrap(model.draftProjectScope)
        model.draft = "Edited"
        try fixture.blockWrites()
        XCTAssertFalse(model.stashCurrentPrompt())
        XCTAssertEqual(model.draft, "Edited")
        XCTAssertTrue(model.stashedPrompts.isEmpty)
        XCTAssertEqual(try fixture.saved().activeProject?.conversations.first?.composerText, "Saved")
        try fixture.unblockWrites()
        XCTAssertTrue(model.stashCurrentPrompt())
        let id = try XCTUnwrap(model.stashedPrompts.first?.id)
        try fixture.blockWrites()
        XCTAssertFalse(model.deleteStashedPrompt(id))
        XCTAssertFalse(model.restoreStashedPrompt(id, to: scope))
        XCTAssertEqual(model.stashedPrompts.map(\.id), [id])
        XCTAssertEqual(try fixture.saved().stashedPrompts?.map(\.id), [id])
        XCTAssertEqual(model.draft, "")
        try fixture.unblockWrites()
        XCTAssertTrue(model.restoreStashedPrompt(id, to: scope))
        XCTAssertEqual(model.draft, "Edited")
        XCTAssertNil(try fixture.saved().stashedPrompts)
    }

    func testRestoreKeepsTheEntryWhenAttachmentsDoNotFit() async throws {
        let fixture = Fixture()
        let source = Conversation(id: UUID(), title: "Source", composerAttachments: [fixture.attachment])
        try fixture.save([fixture.project(for: source)])
        let model = fixture.open()
        let scope = try XCTUnwrap(model.draftProjectScope)
        let staleTarget = model.attachmentTarget(for: source.id)
        XCTAssertTrue(model.stashCurrentPrompt())
        let id = try XCTUnwrap(model.stashedPrompts.first?.id)
        XCTAssertFalse(model.attach([.pastedText("Late callback")], to: staleTarget))
        let target = model.attachmentTarget(for: source.id)
        model.draft = "Keep draft text"
        let inputs = Array(repeating: ComposerAttachmentInput.pastedText("Duplicate"), count: ComposerAttachment.maxCount)
        XCTAssertTrue(model.attach(inputs, to: target))
        let current = model.composerAttachments
        XCTAssertFalse(model.restoreStashedPrompt(id, to: scope))
        XCTAssertEqual(model.stashedPrompts.first?.id, id)
        XCTAssertEqual(model.composerAttachments, current)
        model.removeAttachment(try XCTUnwrap(current.first?.id), in: target)
        XCTAssertTrue(model.restoreStashedPrompt(id, to: scope))
        XCTAssertEqual(model.draft, "Keep draft text")
        XCTAssertEqual(model.composerAttachments, Array(current.dropFirst()) + [fixture.attachment])
        XCTAssertFalse(model.attach([.pastedText("Another late callback")], to: target))
    }

    func testStashWaitsForAnInFlightPaste() async throws {
        let fixture = Fixture()
        let source = Conversation(id: UUID(), title: "Source", composerText: "Keep with file")
        try fixture.save([fixture.project(for: source)])
        let file = fixture.root.appendingPathComponent("queued-paste.txt")
        let bytes = Data("File contents".utf8)
        try bytes.write(to: file)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { finish in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                finish(file.dataRepresentation, nil)
            }
            return nil
        }

        let model = fixture.open()
        model.pasteAttachments([provider], to: model.attachmentTarget(for: source.id))
        XCTAssertFalse(model.stashCurrentPrompt())
        XCTAssertEqual(model.draft, "Keep with file")
        XCTAssertTrue(model.stashedPrompts.isEmpty)
        for _ in 0..<100 where model.isImportingComposerAttachments {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.stashCurrentPrompt())
        let entry = try XCTUnwrap(try fixture.saved().stashedPrompts?.first)
        XCTAssertEqual(entry.prompt, "Keep with file")
        XCTAssertEqual(entry.attachments.first?.payload?.data, bytes)
    }

    func testShortcutMovesTheDraftInAnOffscreenWorkspace() async throws {
        let fixture = Fixture()
        let source = Conversation(id: UUID(), title: "Source", isDraft: true, composerText: "  Test shortcut 🌱 ")
        try fixture.save([fixture.project(for: source)])
        let model = fixture.open()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()
        let left = (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2200
        let window = StashTestPanel(contentRect: NSRect(x: left, y: 0, width: 1100, height: 720),
                                    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable,
                                                       workspacePasteboard: board))
        window.contentView = host
        window.setFrameOrigin(.init(x: left, y: 0))
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)

        func composer(in view: NSView) -> ComposerTextField.Field? {
            if let field = view as? ComposerTextField.Field { return field }
            return view.subviews.lazy.compactMap(composer(in:)).first
        }

        func pressStash() throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       characters: "s", charactersIgnoringModifiers: "s",
                                                       isARepeat: false, keyCode: 1))
            app.sendEvent(event)
        }

        func fieldWithText(_ text: String) async throws -> ComposerTextField.Field {
            for _ in 0..<50 {
                host.layoutSubtreeIfNeeded()
                if let field = composer(in: host), field.stringValue == text { return field }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw WorkspaceError("Composer did not display the expected text.")
        }

        let field = try await fieldWithText("  Test shortcut 🌱 ")
        XCTAssertTrue(window.makeFirstResponder(field))
        try pressStash()
        let empty = try await fieldWithText("")
        XCTAssertFalse(field === empty)
        XCTAssertEqual(try fixture.saved().stashedPrompts?.first?.prompt, "Test shortcut 🌱")
        XCTAssertTrue(window.makeFirstResponder(empty))
        try pressStash()
        _ = try await fieldWithText("Test shortcut 🌱")
        XCTAssertNil(try fixture.saved().stashedPrompts)
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let attachment = ComposerAttachment(name: "file.txt", payload: .init(mimeType: "text/plain", data: Data("payload".utf8)))

        deinit { try? FileManager.default.removeItem(at: root) }

        func project(for thread: Conversation) -> Project {
            Project(id: UUID(), path: root.path, title: thread.title, conversations: [thread], selectedConversation: thread.id)
        }

        func save(_ projects: [Project]) throws {
            try WorkspaceStore(root: root).save(Workspace(projects: projects, selectedProject: projects.first?.id,
                                                           welcomeCompleted: true))
        }

        func saved() throws -> Workspace {
            try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
        }

        @MainActor
        func open() -> WorkspaceModel {
            WorkspaceModel(root: root, keychainService: UUID().uuidString, readCredential: { _ in nil }) { _, _ in
                throw WorkspaceError("No Pi process in this test.")
            }
        }

        private var backup: URL { root.appendingPathComponent("workspace.previous.json") }

        func blockWrites() throws {
            if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
            try Data().write(to: backup.appendingPathComponent("obstruction"))
        }

        func unblockWrites() throws { try FileManager.default.removeItem(at: backup) }
    }
}

private final class StashTestPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }
}
