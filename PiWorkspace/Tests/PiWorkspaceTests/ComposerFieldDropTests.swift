import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class ComposerFieldDropTests: XCTestCase {
    func testFileDropOnActiveComposerAndQueueFieldPreservesTextAndAttachmentOwner() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queued = QueuedMessage(text: "Queued prompt")
        let draft = Conversation(id: UUID(), title: "Draft", composerText: "Keep typing", queuedMessages: [queued])
        let project = Project(id: UUID(), path: root.path, title: "Fixture",
                              conversations: [draft], selectedConversation: draft.id)
        try WorkspaceStore(root: root).save(Workspace(projects: [project], selectedProject: project.id, welcomeCompleted: true))
        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString, readCredential: { _ in "fixture-credential" }) { _, _ in
            throw WorkspaceError("No helper in this test.")
        }
        defer { model.terminate() }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable))
        window.contentView = host
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let drag = FileDrag(board: board)

        for (placeholder, file) in [("Ask Pi anything", "draft.txt"), ("Edit queued message", "queue.txt")] {
            if file == "queue.txt" { model.editQueuedMessage(queued.id) }
            func field() -> NSTextField? {
                descendant(in: host) { ($0 as? NSTextField)?.placeholderString == placeholder } as? NSTextField
            }
            for _ in 0..<40 {
                host.layoutSubtreeIfNeeded()
                if field() != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let composer = try XCTUnwrap(field(), placeholder)
            let destination = try XCTUnwrap(descendant(in: host) { $0 is ComposerFieldDropTarget.Destination }
                as? ComposerFieldDropTarget.Destination)
            let bounds = composer.convert(composer.bounds, to: destination)
            XCTAssertTrue(destination.bounds.contains(NSPoint(x: bounds.midX, y: bounds.midY)))
            let center = composer.convert(NSPoint(x: composer.bounds.midX, y: composer.bounds.midY), to: host.superview)
            let hit = host.hitTest(center)
            XCTAssertTrue(hit === composer || hit?.isDescendant(of: composer) == true, String(describing: hit))
            XCTAssertTrue(destination.registeredDraggedTypes.contains(.fileURL))
            XCTAssertFalse(destination.registeredDraggedTypes.contains(.string))

            XCTAssertTrue(window.makeFirstResponder(composer))
            let editor = try XCTUnwrap(composer.currentEditor() as? NSTextView)
            let original = editor.string
            let range = NSRange(location: 1, length: 2)
            editor.setSelectedRange(range)
            editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: range)
            XCTAssertTrue(editor.hasMarkedText())
            let text = editor.string
            let selection = editor.selectedRange()
            let markedRange = editor.markedRange()
            let draftBeforeDrop = model.draft
            let url = root.appendingPathComponent(file)
            try Data(file.utf8).write(to: url)
            board.clearContents()
            XCTAssertTrue(board.writeObjects([url as NSURL]))
            XCTAssertEqual(destination.draggingEntered(drag), .copy)
            XCTAssertTrue(destination.performDragOperation(drag))
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(editor.markedRange(), markedRange)
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(model.draft, draftBeforeDrop)
            editor.insertText((original as NSString).substring(with: range), replacementRange: markedRange)
            XCTAssertEqual(editor.string, original)
            XCTAssertEqual(model.composerAttachments.map(\.name), [file])
            XCTAssertEqual(model.composerAttachments.first?.payload?.data, Data(file.utf8))
        }
        model.updateQueuedMessage()
        let data = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
        let saved = try XCTUnwrap(JSONDecoder().decode(Workspace.self, from: data).projects.first?.conversations.first)
        XCTAssertEqual(saved.composerText, "Keep typing")
        XCTAssertEqual(saved.composerAttachments?.map(\.name), ["draft.txt"])
        XCTAssertEqual(saved.queuedMessages?.first?.text, "Queued prompt")
        XCTAssertEqual(saved.queuedMessages?.first?.attachments?.map(\.name), ["queue.txt"])
    }

    func testNativeRepresentationsPreferFileURLAndIgnorePlainTextPaths() throws {
        let item = NSPasteboardItem()
        let path = "/tmp/looks like a file.png"
        item.setString(path, forType: .string)
        XCTAssertNil(ComposerAttachmentInput(pasteboardItem: item))
        let bytes = Data([1, 2, 3])
        item.setData(bytes, forType: .png)
        guard case .image(let image, .png) = ComposerAttachmentInput(pasteboardItem: item) else {
            return XCTFail("The PNG representation should be used")
        }
        XCTAssertEqual(image, bytes)
        let url = URL(fileURLWithPath: path)
        item.setString(url.absoluteString, forType: .fileURL)
        guard case .file(let file) = ComposerAttachmentInput(pasteboardItem: item) else {
            return XCTFail("The named file should take precedence over its image preview")
        }
        XCTAssertEqual(file, url)
    }

    private func descendant(in view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let match = descendant(in: child, matching: predicate) { return match }
        }
        return nil
    }
}

private final class FileDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(board: NSPasteboard) { draggingPasteboard = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
