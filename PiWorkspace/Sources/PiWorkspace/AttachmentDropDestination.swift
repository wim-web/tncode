import SwiftUI

extension View {
    func attachmentDropDestination(canDrop: Bool, perform: @escaping ([NSPasteboardItem]) -> Bool,
                                   isTargeted: @escaping (Bool) -> Void) -> some View {
        background {
            AttachmentDropDestination(canDrop: canDrop, perform: perform, isTargeted: isTargeted)
                .accessibilityHidden(true)
        }
    }
}

/// AppKit routes drags by registered pasteboard type, independently of mouse hit testing.
struct AttachmentDropDestination: NSViewRepresentable {
    let canDrop: Bool
    let perform: ([NSPasteboardItem]) -> Bool
    let isTargeted: (Bool) -> Void

    static let types = ComposerAttachmentInput.contentTypes.map { NSPasteboard.PasteboardType($0.identifier) }

    func operation(for sender: NSDraggingInfo) -> NSDragOperation? {
        guard sender.draggingPasteboard.availableType(from: Self.types) != nil else { return nil }
        let accepts = sender.draggingSourceOperationMask.contains(.copy) && canDrop
        isTargeted(accepts)
        return accepts ? .copy : []
    }

    func receive(_ sender: NSDraggingInfo) -> Bool? {
        guard let operation = operation(for: sender) else { return nil }
        defer { isTargeted(false) }
        return !operation.isEmpty && receiveItems(from: sender.draggingPasteboard)
    }

    func receiveItems(from pasteboard: NSPasteboard) -> Bool {
        guard canDrop, let items = pasteboard.pasteboardItems, !items.isEmpty else { return false }
        return perform(items)
    }

    func makeNSView(context: Context) -> Destination {
        let view = Destination()
        view.registerForDraggedTypes(Self.types)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Destination, context: Context) {
        view.target = self
    }

    final class Destination: NSView {
        var target: AttachmentDropDestination?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            target?.operation(for: sender) ?? []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            target?.isTargeted(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            target?.receive(sender) ?? false
        }
    }
}
