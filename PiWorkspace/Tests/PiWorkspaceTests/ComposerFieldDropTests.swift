import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class ComposerFieldDropTests: XCTestCase {
    func testFileDropOnActiveComposerAndQueueFieldPreservesTextAndAttachmentOwner() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()
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

        let screenLeft = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let window = OffscreenPanel(contentRect: NSRect(x: screenLeft - 2200, y: 0, width: 1100, height: 720),
                                    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable))
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: screenLeft - 2200, y: 0))
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let drag = FileDrag(board: board)

        func assertAXHit(_ id: String, in view: NSView, fraction: CGFloat = 0.5) {
            let point = NSPoint(x: view.bounds.width * fraction, y: view.bounds.midY)
            let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
            var node = host.accessibilityHitTest(screenPoint) as AnyObject?
            var path: [String] = []
            while let current = node, path.count < 20 {
                if current.accessibilityIdentifier?() == id { return }
                path.append("\(type(of: current))")
                node = current.accessibilityParent?() as AnyObject?
            }
            XCTFail("Expected \(id) at \(screenPoint), got \(path)")
        }

        func dropPNG(_ name: String, color: NSColor, onto destination: NSView) throws -> Data {
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(color.cgColor)
            bitmap.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            let image = try XCTUnwrap(bitmap.makeImage())
            let bytes = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            let url = root.appendingPathComponent(name)
            try bytes.write(to: url)
            board.clearContents()
            XCTAssertTrue(board.writeObjects([url as NSURL]))
            XCTAssertEqual(destination.draggingEntered(drag), .copy)
            XCTAssertTrue(destination.prepareForDragOperation(drag))
            XCTAssertTrue(destination.performDragOperation(drag))
            return bytes
        }

        var droppedBytes: [String: Data] = [:]
        let draftText = try XCTUnwrap(draft.composerText)
        for (placeholder, file, original) in [("Ask Pi anything", "red.png", draftText),
                                              ("Edit queued message", "queue.png", queued.text)] {
            let editingQueue = file == "queue.png"
            if editingQueue { model.editQueuedMessage(queued.id) }
            func field() -> NSTextField? {
                descendant(in: host) { ($0 as? NSTextField)?.placeholderString == placeholder } as? NSTextField
            }
            for _ in 0..<40 {
                host.layoutSubtreeIfNeeded()
                if field() != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let composer = try XCTUnwrap(field(), placeholder)
            let destination = try XCTUnwrap(descendant(in: host) { view in
                let fieldBounds = composer.convert(composer.bounds, to: view)
                return view is AttachmentDropDestination.Destination && view.bounds.contains(fieldBounds)
            } as? AttachmentDropDestination.Destination)
            let bounds = composer.convert(composer.bounds, to: destination)
            XCTAssertGreaterThan(destination.bounds.width, bounds.width)
            XCTAssertGreaterThan(destination.bounds.height, bounds.height)
            let center = composer.convert(NSPoint(x: composer.bounds.midX, y: composer.bounds.midY), to: host.superview)
            let hit = host.hitTest(center)
            XCTAssertTrue(hit === composer || hit?.isDescendant(of: composer) == true, String(describing: hit))
            XCTAssertTrue(destination.registeredDraggedTypes.contains(.fileURL))
            XCTAssertFalse(destination.registeredDraggedTypes.contains(.string))

            XCTAssertTrue(window.makeFirstResponder(composer))
            let editor = try XCTUnwrap(composer.currentEditor() as? NSTextView)
            for fraction in [0.25, 0.5, 0.75] { assertAXHit("composer", in: composer, fraction: fraction) }
            // Bridging a retained editor.string back to NSString can read its live text storage.
            XCTAssertEqual(editor.string, original)
            let range = NSRange(location: 1, length: 2)
            editor.setSelectedRange(range)
            editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: range)
            XCTAssertTrue(editor.hasMarkedText())
            let markedText = (original as NSString).replacingCharacters(in: range, with: "かな")
            XCTAssertEqual(editor.string, markedText)
            let selection = editor.selectedRange()
            let markedRange = editor.markedRange()
            XCTAssertEqual(markedRange, range)
            XCTAssertEqual(model.draft, original)
            let bytes = try dropPNG(file, color: editingQueue ? .green : .red, onto: editingQueue ? composer : editor)
            droppedBytes[file] = bytes
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(editor.markedRange(), markedRange)
            XCTAssertEqual(editor.string, markedText)
            XCTAssertEqual(model.draft, original)
            editor.insertText((original as NSString).substring(with: range), replacementRange: markedRange)
            XCTAssertFalse(editor.hasMarkedText())
            XCTAssertEqual(editor.string, original)
            XCTAssertEqual(model.draft, original)
            // Withdraw an uncommitted insertion at the caret.
            let current = NSRange(location: NSNotFound, length: 0)
            editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: current)
            XCTAssertTrue(editor.hasMarkedText())
            editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: current)
            editor.unmarkText()
            XCTAssertFalse(editor.hasMarkedText())
            XCTAssertEqual(editor.string, original)
            XCTAssertEqual(model.draft, original)

            board.clearContents()
            let pastedText = "/tmp/ordinary plain text.png"
            XCTAssertTrue(board.setString(pastedText, forType: .string))
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            XCTAssertTrue(editor.readSelection(from: board, type: .string))
            XCTAssertEqual(editor.string, pastedText)
            XCTAssertEqual(model.draft, pastedText)
            editor.insertText(original, replacementRange: NSRange(location: 0, length: pastedText.utf16.count))
            XCTAssertEqual(editor.string, original)
            XCTAssertEqual(model.draft, original)
            XCTAssertEqual(model.composerAttachments.map(\.name), [file])
            XCTAssertEqual(model.composerAttachments.first?.payload?.data, bytes)
            if editingQueue {
                board.clearContents()
                XCTAssertTrue(board.setData(bytes, forType: .png))
                XCTAssertTrue(editor.readSelection(from: board, type: .png))
                XCTAssertEqual(model.composerAttachments.last?.name, "Pasted Image.png")
                XCTAssertEqual(model.composerAttachments.last?.payload?.data, bytes)
                XCTAssertEqual(editor.string, original)
                XCTAssertEqual(model.draft, original)
            }
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(composer.stringValue, original)
            XCTAssertEqual(model.draft, original)
        }
        // The sidebar row always owns the thread draft, including while its queue editor is open.
        let row = try XCTUnwrap(descendant(in: host) { view in
            view is AttachmentDropDestination.Destination &&
                view.convert(view.bounds, to: host).maxX <= WorkspaceLayout.defaultSidebarWidth
        } as? AttachmentDropDestination.Destination)
        assertAXHit("thread-row-\(draft.id)", in: row)
        let blue = try dropPNG("blue.png", color: .blue, onto: row)
        XCTAssertEqual(model.composerAttachments.map(\.name), ["queue.png", "Pasted Image.png"])
        model.updateQueuedMessage()
        let data = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
        let saved = try XCTUnwrap(JSONDecoder().decode(Workspace.self, from: data).projects.first?.conversations.first)
        let red = try XCTUnwrap(droppedBytes["red.png"])
        let green = try XCTUnwrap(droppedBytes["queue.png"])
        XCTAssertEqual(saved.id, draft.id)
        XCTAssertEqual(saved.composerText, draftText)
        XCTAssertEqual(saved.composerAttachments?.map(\.name), ["red.png", "blue.png"])
        XCTAssertEqual(saved.composerAttachments?.compactMap { $0.payload?.data }, [red, blue])
        let savedQueue = try XCTUnwrap(saved.queuedMessages?.first)
        XCTAssertEqual(savedQueue.id, queued.id)
        XCTAssertEqual(savedQueue.text, queued.text)
        XCTAssertEqual(savedQueue.attachments?.map(\.name), ["queue.png", "Pasted Image.png"])
        XCTAssertEqual(savedQueue.attachments?.compactMap { $0.payload?.data }, [green, green])

        let folder = root.appendingPathComponent("Dropped Project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([folder as NSURL]))
        XCTAssertTrue(row.performDragOperation(drag))
        XCTAssertEqual(model.project?.path, folder.path)
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

private final class OffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
