import SwiftUI

extension View {
    func attachmentDropDestination(canDrop: Bool, perform: @escaping ([NSPasteboardItem]) -> Bool,
                                   isTargeted: @escaping (Bool) -> Void) -> some View {
        overlay {
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

    func makeNSView(context: Context) -> Destination {
        let view = Destination()
        view.registerForDraggedTypes(ComposerAttachmentInput.contentTypes.map { .init($0.identifier) })
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
            let accepts = sender.draggingSourceOperationMask.contains(.copy) && target?.canDrop == true
            target?.isTargeted(accepts)
            return accepts ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            target?.isTargeted(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { target?.isTargeted(false) }
            guard sender.draggingSourceOperationMask.contains(.copy), let target, target.canDrop,
                  let items = sender.draggingPasteboard.pasteboardItems, !items.isEmpty else { return false }
            return target.perform(items)
        }
    }
}
