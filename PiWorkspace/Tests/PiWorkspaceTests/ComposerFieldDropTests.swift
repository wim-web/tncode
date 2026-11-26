import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import PiWorkspace

@MainActor
final class ComposerFieldDropTests: XCTestCase {
    func testLargePastesInNativeFieldKeepTheDraftAndQueueOwners() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queued = QueuedMessage(text: "Queue 🌸")
        let original = "Keep 👩🏽‍💻 this draft"
        let draft = Conversation(id: UUID(), title: "Draft", composerText: original, queuedMessages: [queued])
        let other = Conversation(id: UUID(), title: "Other", composerText: "Other draft")
        let project = Project(id: UUID(), path: root.path, title: "Fixture",
                              conversations: [draft, other], selectedConversation: draft.id)
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
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable, workspacePasteboard: board))
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: screenLeft - 2200, y: 0))
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)

        func editor(for text: String) async throws -> NSTextView {
            var field: ComposerTextField.Field?
            for _ in 0..<40 {
                host.layoutSubtreeIfNeeded()
                field = descendant(in: host) { ($0 as? ComposerTextField.Field)?.stringValue == text } as? ComposerTextField.Field
                if field != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let composer = try XCTUnwrap(field)
            XCTAssertEqual(composer.accessibilityIdentifier(), "composer")
            XCTAssertTrue(window.makeFirstResponder(composer))
            return try XCTUnwrap(composer.currentEditor() as? NSTextView)
        }

        func invoke(_ selector: Selector, on editor: NSTextView) {
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(window.firstResponder?.tryToPerform(selector, with: nil) == true)
        }
        let pasteAction = #selector(NSText.paste(_:))
        let plainAction = #selector(NSTextView.pasteAsPlainText(_:))
        func checkMenus(_ editor: NSTextView, paste: Bool, plain: Bool, line: UInt = #line) {
            let menu = NSMenu()
            for (action, expected) in [(pasteAction, paste), (plainAction, plain)] {
                let item = menu.addItem(withTitle: "Paste", action: action, keyEquivalent: "")
                item.target = editor
                menu.update()
                XCTAssertEqual(item.isEnabled, expected, line: line)
            }
        }
        func paste(_ text: String, into editor: NSTextView) {
            board.clearContents()
            XCTAssertTrue(board.setString(text, forType: .string))
            invoke(pasteAction, on: editor)
        }

        let draftEditor = try await editor(for: original)
        let selection = (original as NSString).range(of: "👩🏽‍💻")
        board.clearContents()
        checkMenus(draftEditor, paste: false, plain: false)
        draftEditor.setSelectedRange(selection)
        let belowThreshold = String(repeating: "a", count: 32 * 1024 - 1)
        paste(belowThreshold, into: draftEditor)
        XCTAssertTrue(model.draft == (original as NSString).replacingCharacters(in: selection, with: belowThreshold))
        XCTAssertTrue(model.composerAttachments.isEmpty)
        checkMenus(draftEditor, paste: true, plain: true)
        invoke(Selector(("undo:")), on: draftEditor)
        XCTAssertTrue(model.draft == original)

        invoke(Selector(("redo:")), on: draftEditor)
        XCTAssertTrue(model.draft == (original as NSString).replacingCharacters(in: selection, with: belowThreshold))
        invoke(Selector(("undo:")), on: draftEditor)
        XCTAssertTrue(model.draft == original)
        draftEditor.setSelectedRange(selection)

        let line = "  日本語 👩🏽‍💻 e\u{301}\r\n"
        let repeated = String(repeating: line, count: (32 * 1024) / line.utf8.count)
        let boundary = repeated + String(repeating: " ", count: 32 * 1024 - repeated.utf8.count)
        paste(boundary, into: draftEditor)
        XCTAssertTrue(model.draft == original)
        XCTAssertTrue(draftEditor.string == original)
        XCTAssertEqual(draftEditor.selectedRange(), selection)
        let first = try XCTUnwrap(model.composerAttachments.first)
        XCTAssertEqual(first.name, "pasted-text.txt")
        XCTAssertEqual(first.payload?.data, Data(boundary.utf8))

        invoke(plainAction, on: draftEditor)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(model.draft == (original as NSString).replacingCharacters(in: selection, with: boundary))
        XCTAssertEqual(model.composerAttachments, [first])
        invoke(Selector(("undo:")), on: draftEditor)
        XCTAssertTrue(model.draft == original)

        draftEditor.setSelectedRange(selection)

        paste(boundary + boundary, into: draftEditor)
        XCTAssertEqual(model.composerAttachments.map(\.name), ["pasted-text.txt", "pasted-text-2.txt"])
        XCTAssertEqual(model.composerAttachments.last?.payload?.data, Data((boundary + boundary).utf8))
        let accepted = model.composerAttachments
        let overFileLimit = boundary + boundary + "a"
        paste(overFileLimit, into: draftEditor)
        XCTAssertTrue(model.draft == (original as NSString).replacingCharacters(in: selection, with: overFileLimit))
        XCTAssertEqual(model.composerAttachments, accepted)
        XCTAssertNil(model.error)
        invoke(Selector(("undo:")), on: draftEditor)
        XCTAssertTrue(model.draft == original)
        draftEditor.setSelectedRange(selection)

        board.clearContents()
        XCTAssertTrue(board.setData(Data([1, 2, 3]), forType: .png))
        checkMenus(draftEditor, paste: true, plain: false)
        invoke(plainAction, on: draftEditor)
        XCTAssertEqual(model.composerAttachments, accepted)
        invoke(pasteAction, on: draftEditor)
        XCTAssertTrue(model.error?.contains("damaged") == true)
        XCTAssertEqual(model.composerAttachments, accepted)
        XCTAssertEqual(model.draft, original)

        model.editQueuedMessage(queued.id)
        let queueEditor = try await editor(for: queued.text)
        let queueTarget = model.attachmentTarget(for: draft.id)
        paste(boundary, into: queueEditor)
        XCTAssertEqual(model.composerAttachments.map(\.name), ["pasted-text.txt"])
        XCTAssertEqual(model.draft, queued.text)
        model.cancelQueuedMessageEdit()
        XCTAssertTrue(model.foldPastedText(overFileLimit, inlineLength: overFileLimit.utf16.count, in: queueTarget))
        XCTAssertTrue(model.draft == original)
        XCTAssertEqual(model.queuedMessages.first?.attachments, queued.attachments)
        XCTAssertEqual(model.composerAttachments, accepted)
        model.editQueuedMessage(queued.id)
        paste(boundary, into: try await editor(for: queued.text))
        model.updateQueuedMessage()
        XCTAssertEqual(model.queuedMessages.first?.id, queued.id)
        XCTAssertEqual(model.queuedMessages.first?.attachments?.first?.payload?.data, Data(boundary.utf8))

        model.selectConversation(other.id, in: project.id)
        paste(boundary, into: try await editor(for: "Other draft"))
        XCTAssertEqual(model.draft, "Other draft")
        XCTAssertEqual(model.composerAttachments.map(\.name), ["pasted-text.txt"])
        XCTAssertNotEqual(model.composerAttachments.first?.id, first.id)
        model.selectConversation(draft.id, in: project.id)
        let restored = try await editor(for: original)
        XCTAssertEqual(model.composerAttachments, accepted)
        for _ in accepted.count..<ComposerAttachment.maxCount { paste(boundary, into: restored) }
        XCTAssertEqual(model.composerAttachments.count, ComposerAttachment.maxCount)
        let full = model.composerAttachments
        restored.setSelectedRange(selection)
        paste(boundary, into: restored)
        XCTAssertTrue(model.draft == (original as NSString).replacingCharacters(in: selection, with: boundary))
        XCTAssertEqual(model.composerAttachments, full)
        XCTAssertNil(model.error)
        invoke(Selector(("undo:")), on: restored)
        XCTAssertTrue(model.draft == original)

        let emoji = "🌸"
        let nearLimit = emoji + String(repeating: "123456789\n", count: 11_999) + "12345678"
        XCTAssertEqual(nearLimit.utf16.count, 120_000)
        restored.insertText(nearLimit, replacementRange: NSRange(location: 0, length: restored.string.utf16.count))
        let emojiRange = NSRange(location: 0, length: emoji.utf16.count)
        restored.setSelectedRange(emojiRange)
        paste("🎈", into: restored)
        let atLimit = "🎈" + nearLimit.dropFirst()
        XCTAssertTrue(model.draft == atLimit)
        XCTAssertEqual(model.composerAttachments, full)
        restored.setSelectedRange(emojiRange)
        paste("abc", into: restored)
        XCTAssertTrue(model.error?.contains("up to 10 files") == true)
        XCTAssertTrue(model.draft == atLimit)
        XCTAssertEqual(restored.selectedRange(), emojiRange)
        XCTAssertEqual(model.composerAttachments, full)

        let activeTarget = model.attachmentTarget(for: draft.id)
        for attachment in full { model.removeAttachment(attachment.id, in: activeTarget) }
        paste("abc", into: restored)
        XCTAssertTrue(model.draft == atLimit)
        XCTAssertEqual(restored.selectedRange(), emojiRange)
        let folded = try XCTUnwrap(model.composerAttachments.first)
        XCTAssertEqual(folded.name, "pasted-text.txt")
        XCTAssertEqual(folded.payload?.data, Data("abc".utf8))
        paste(overFileLimit, into: restored)
        XCTAssertTrue(model.error?.contains("64 KB") == true)
        XCTAssertTrue(model.draft == atLimit)
        XCTAssertEqual(restored.selectedRange(), emojiRange)
        XCTAssertEqual(model.composerAttachments, [folded])
        model.removeAttachment(folded.id, in: activeTarget)
        restored.insertText(original, replacementRange: NSRange(location: 0, length: nearLimit.utf16.count))
        let alphaTIFF = try makeAttachmentImage(width: 2400, height: 1800, type: .tiff, noisy: true)
        XCTAssertGreaterThan(alphaTIFF.count, ComposerAttachment.maxBytes)
        board.clearContents()
        XCTAssertTrue(board.setData(alphaTIFF, forType: .tiff))
        XCTAssertTrue(restored.readSelection(from: board))
        let image = try XCTUnwrap(model.composerAttachments.first)
        XCTAssertEqual(image.name, "Pasted Image.png")
        XCTAssertEqual(image.payload?.mimeType, "image/png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.payload?.data)))
        XCTAssertLessThanOrEqual(bitmap.pixelsWide, 2000)
        XCTAssertEqual(Double(bitmap.pixelsWide) / Double(bitmap.pixelsHigh), 4.0 / 3.0, accuracy: 0.002)
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.9)
        XCTAssertLessThan(pixel.greenComponent, 0.2)
        XCTAssertLessThan(pixel.blueComponent, 0.2)
        XCTAssertEqual(pixel.alphaComponent, 0.5, accuracy: 0.02)
        XCTAssertEqual(model.draft, original)

        let imageURL = root.appendingPathComponent("large.png")
        let largePNG = try makeAttachmentImage(width: 2000, height: 1800, type: .png, noisy: true)
        XCTAssertGreaterThan(largePNG.count, ComposerAttachment.maxBytes)
        try largePNG.write(to: imageURL)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([imageURL as NSURL]))
        let drag = FileDrag(board: board)
        XCTAssertEqual(restored.draggingEntered(drag), .copy)
        XCTAssertFalse(restored.performDragOperation(drag))
        XCTAssertTrue(model.error?.contains("total 4 MB") == true)
        XCTAssertEqual(model.composerAttachments, [image])
        let target = model.attachmentTarget(for: draft.id)
        model.removeAttachment(image.id, in: target)

        XCTAssertEqual(restored.draggingEntered(drag), .copy)
        XCTAssertTrue(restored.performDragOperation(drag))
        let dropped = try XCTUnwrap(model.composerAttachments.first)
        XCTAssertEqual(dropped.name, "large.png")
        let droppedBytes = try XCTUnwrap(dropped.payload?.data)
        XCTAssertLessThan(droppedBytes.count, ComposerAttachment.maxBytes)
        let droppedBitmap = try XCTUnwrap(NSBitmapImageRep(data: droppedBytes))
        XCTAssertLessThan(droppedBitmap.pixelsWide, 2000)
        XCTAssertEqual(try XCTUnwrap(droppedBitmap.colorAt(x: 4, y: 4)).alphaComponent, 0.5, accuracy: 0.02)

        let jpeg = try makeAttachmentImage(width: 4, height: 3, type: .jpeg)
        let jpegURL = root.appendingPathComponent("Small JPEG.jpeg")
        try jpeg.write(to: jpegURL)
        XCTAssertTrue(model.attach([.file(jpegURL)], to: target, replacing: dropped.id))
        XCTAssertEqual(model.composerAttachments.first?.id, dropped.id)
        XCTAssertEqual(model.composerAttachments.first?.name, "Small JPEG.jpeg")
        XCTAssertEqual(model.composerAttachments.first?.payload?.data, jpeg)
        let snapshot = model.composerAttachments
        let oversized = root.appendingPathComponent("Oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 50 * 1024 * 1024 + 1)
        try handle.close()
        XCTAssertFalse(model.attach([.file(oversized)], to: target, replacing: dropped.id))
        XCTAssertTrue(model.error?.contains("50 MB") == true)
        XCTAssertEqual(model.composerAttachments, snapshot)

        let rotatedJPEG = try makeAttachmentImage(width: 2500, height: 1000, type: .jpeg, orientation: 6)
        board.clearContents()
        XCTAssertTrue(board.setData(rotatedJPEG, forType: .init(UTType.jpeg.identifier)))
        XCTAssertTrue(restored.readSelection(from: board))
        let rotated = try XCTUnwrap(model.composerAttachments.last)
        XCTAssertEqual(rotated.name, "Pasted Image.jpg")
        XCTAssertEqual(rotated.payload?.mimeType, "image/jpeg")
        let rotatedBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rotated.payload?.data)))
        XCTAssertEqual(rotatedBitmap.pixelsWide, 800)
        XCTAssertEqual(rotatedBitmap.pixelsHigh, 2000)
    }

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

        func assertAXHit(_ id: String, in view: NSView, fraction: CGFloat = 0.5, heightFraction: CGFloat = 0.5) {
            let point = NSPoint(x: view.bounds.width * fraction, y: view.bounds.height * heightFraction)
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
            XCTAssertEqual(bounds.height, 53.5, accuracy: 1)
            XCTAssertEqual(bounds.minX, WorkspaceLayout.editorInset, accuracy: 1)
            XCTAssertEqual(destination.bounds.maxX - bounds.maxX, WorkspaceLayout.editorInset, accuracy: 1)
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
            assertAXHit("composer", in: composer, heightFraction: 0.9)
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

func makeAttachmentImage(width: Int, height: Int, type: UTType, noisy: Bool = false,
                         orientation: Int = 1) throws -> Data {
    let rowBytes = width * 4
    var pixels = Data(count: rowBytes * height)
    pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
        var seed: UInt32 = 123_456_789
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                if noisy && x >= 32 {
                    seed ^= seed << 13
                    seed ^= seed >> 17
                    seed ^= seed << 5
                    buffer[offset] = UInt8(truncatingIfNeeded: seed)
                    buffer[offset + 1] = UInt8(truncatingIfNeeded: seed >> 8)
                    buffer[offset + 2] = UInt8(truncatingIfNeeded: seed >> 16)
                    buffer[offset + 3] = 255
                } else {
                    buffer[offset] = 128
                    buffer[offset + 3] = 128
                }
            }
        }
    }
    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: rowBytes, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    let data = NSMutableData()
    let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(output, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(output))
    return data as Data
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
