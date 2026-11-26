import Combine
import SwiftUI

private struct ComposerFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var editingComposer: Bool? {
        get { self[ComposerFocusKey.self] }
        set { self[ComposerFocusKey.self] = newValue }
    }
}

struct ComposerTextField: NSViewRepresentable {
    let target: ComposerAttachmentTarget
    let placeholder: String
    @Binding var text: String
    let pasteboard: NSPasteboard
    let drop: AttachmentDropDestination
    let foldPastedText: (String, Int) -> Bool

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
        field.maximumNumberOfLines = 7
        field.registerForDraggedTypes(AttachmentDropDestination.types)
        field.setAccessibilityIdentifier("composer")
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.composerTarget = target
        field.pasteboardOverride = pasteboard.name == .general ? nil : pasteboard
        field.drop = drop
        field.foldPastedText = foldPastedText
        field.isEnabled = context.environment.isEnabled
        field.placeholderString = placeholder
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: Field, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let cell = field.cell, let font = field.font else { return nil }
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let maxHeight = CGFloat(field.maximumNumberOfLines) * lineHeight
        let size = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: maxHeight))
        return CGSize(width: width, height: min(maxHeight, max(53.5, size.height)))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerTextField
        init(_ parent: ComposerTextField) { self.parent = parent }

        private var undoObservation: AnyCancellable?

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? Field,
                  let editor = field.currentEditor() as? NSTextView, let manager = editor.undoManager else { return }
            // AppKit restores the field editor's storage on Undo without notifying the text field delegate.
            let center = NotificationCenter.default
            undoObservation = center.publisher(for: .NSUndoManagerDidUndoChange, object: manager)
                .merge(with: center.publisher(for: .NSUndoManagerDidRedoChange, object: manager))
                .sink { [weak self, weak field, weak editor] _ in
                    guard let self, let editor, field?.currentEditor() === editor,
                          !editor.hasMarkedText(), parent.text != editor.string else { return }
                    editor.didChangeText()
                }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            undoObservation = nil
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? Field {
                parent.text = field.stringValue
                field.invalidateIntrinsicContentSize()
            }
        }
    }

    @MainActor
    struct FindSelection {
        private weak var field: Field?
        private let target: ComposerAttachmentTarget
        private let revision: Int
        private let range: NSRange

        init?(window: NSWindow?, model: WorkspaceModel) {
            guard let editor = window?.firstResponder as? Editor, !editor.hasMarkedText(),
                  let field = editor.owner, field.currentEditor() === editor,
                  let target = field.composerTarget, model.conversation?.id == target.threadID,
                  target == model.attachmentTarget(for: target.threadID),
                  editor.string.utf8.elementsEqual(model.draft.utf8) else { return nil }
            self.field = field
            self.target = target
            revision = model.composerRevision
            range = editor.selectedRange()
        }

        func restoreOnFocus(in model: WorkspaceModel) {
            guard let field, field.currentEditor() == nil else { return }
            field.selectionOnFocus = { [weak model, weak field] in
                guard let model, let field, model.composerRevision == revision,
                      model.conversation?.id == target.threadID, field.composerTarget == target,
                      target == model.attachmentTarget(for: target.threadID),
                      field.stringValue.utf8.elementsEqual(model.draft.utf8),
                      NSMaxRange(range) <= field.stringValue.utf16.count else { return nil }
                return range
            }
        }
    }

    final class Field: NSTextField {
        var composerTarget: ComposerAttachmentTarget?
        var selectionOnFocus: (() -> NSRange?)?
        var pasteboardOverride: NSPasteboard?
        var drop: AttachmentDropDestination?
        var foldPastedText: ((String, Int) -> Bool)?

        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

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

        override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?,
                             start: Int, length: Int) {
            let field = controlView as? Field
            let range = field?.selectionOnFocus?()
            field?.selectionOnFocus = nil
            super.select(withFrame: rect, in: controlView, editor: editor, delegate: delegate,
                         start: range?.location ?? start, length: range?.length ?? length)
        }

        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            editor.owner = controlView as? Field
            editor.isFieldEditor = true
            return editor
        }
    }

    final class Editor: NSTextView {
        weak var owner: Field?
        private var pastingAsPlainText = false

        override func paste(_ sender: Any?) {
            guard let board = owner?.pasteboardOverride else { return super.paste(sender) }
            if isEditable { _ = readSelection(from: board) }
        }

        override func pasteAsPlainText(_ sender: Any?) {
            pastingAsPlainText = true
            defer { pastingAsPlainText = false }
            guard let board = owner?.pasteboardOverride else { return super.pasteAsPlainText(sender) }
            if isEditable, board.availableType(from: [.string]) != nil {
                _ = readSelection(from: board, type: .string)
            }
        }

        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if let board = owner?.pasteboardOverride {
                switch item.action {
                case #selector(paste(_:)):
                    return isEditable && board.availableType(from: readablePasteboardTypes) != nil
                case #selector(pasteAsPlainText(_:)):
                    return isEditable && board.availableType(from: [.string]) != nil
                default: break
                }
            }
            return super.validateUserInterfaceItem(item)
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
            guard let fold = owner?.foldPastedText, let text = pasteboard.string(forType: .string) else { return false }
            let inlineLength = string.utf16.count - selectedRange().length + text.utf16.count
            return fold(text, inlineLength)
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
