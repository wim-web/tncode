import SwiftUI

struct ComposerTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let drop: AttachmentDropDestination
    let attachPastedText: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.cell = Cell(textCell: "")
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.registerForDraggedTypes(AttachmentDropDestination.types)
        field.setAccessibilityIdentifier("composer")
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.drop = drop
        field.attachPastedText = attachPastedText
        field.isEnabled = context.environment.isEnabled
        field.placeholderString = placeholder
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: Field, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let cell = field.cell, let font = field.font else { return nil }
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(7 * lineHeight, max(2 * lineHeight, size.height)))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerTextField
        init(_ parent: ComposerTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? Field {
                parent.text = field.stringValue
                field.invalidateIntrinsicContentSize()
            }
        }
    }

    final class Field: NSTextField {
        var drop: AttachmentDropDestination?
        var attachPastedText: ((String) -> Void)?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            drop?.operation(for: sender) ?? super.draggingEntered(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            drop?.operation(for: sender) ?? super.draggingUpdated(sender)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            drop?.operation(for: sender).map { !$0.isEmpty } ?? super.prepareForDragOperation(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            drop?.receive(sender) ?? super.performDragOperation(sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            drop?.isTargeted(false)
            super.draggingExited(sender)
        }
    }

    final class Cell: NSTextFieldCell {
        private let editor = Editor()
        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            editor.owner = controlView as? Field
            editor.isFieldEditor = true
            return editor
        }
    }

    final class Editor: NSTextView {
        weak var owner: Field?
        private var pastingAsPlainText = false

        override func pasteAsPlainText(_ sender: Any?) {
            pastingAsPlainText = true
            defer { pastingAsPlainText = false }
            super.pasteAsPlainText(sender)
        }

        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            AttachmentDropDestination.types + super.readablePasteboardTypes
        }

        override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            takeAttachment(from: pasteboard) || super.readSelection(from: pasteboard, type: type)
        }

        private func takeAttachment(from pasteboard: NSPasteboard) -> Bool {
            guard !pastingAsPlainText else { return false }
            if let drop = owner?.drop, pasteboard.availableType(from: AttachmentDropDestination.types) != nil {
                _ = drop.receiveItems(from: pasteboard)
                return true
            }
            if let attach = owner?.attachPastedText, let text = pasteboard.string(forType: .string),
               text.utf8.count >= ComposerAttachmentInput.pastedTextThreshold {
                attach(text)
                return true
            }
            return false
        }

        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            super.acceptableDragTypes + AttachmentDropDestination.types
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            owner?.drop?.operation(for: sender) ?? super.draggingEntered(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            owner?.drop?.operation(for: sender) ?? super.draggingUpdated(sender)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            owner?.drop?.operation(for: sender).map { !$0.isEmpty } ?? super.prepareForDragOperation(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            owner?.drop?.receive(sender) ?? super.performDragOperation(sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            owner?.drop?.isTargeted(false)
            super.draggingExited(sender)
        }
    }
}
