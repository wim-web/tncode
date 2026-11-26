import SwiftUI

/// AppKit routes drags by registered pasteboard type, independently of mouse hit testing.
struct ComposerFieldDropTarget: NSViewRepresentable {
    var canAttach: () -> Bool
    var attach: ([ComposerAttachmentInput]) -> Bool
    var isTargeted: (Bool) -> Void

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
        var target: ComposerFieldDropTarget?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let accepts = sender.draggingSourceOperationMask.contains(.copy) && target?.canAttach() == true
            target?.isTargeted(accepts)
            return accepts ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            target?.isTargeted(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { target?.isTargeted(false) }
            guard sender.draggingSourceOperationMask.contains(.copy), let target, target.canAttach() else { return false }
            let inputs = (sender.draggingPasteboard.pasteboardItems ?? []).lazy.compactMap(ComposerAttachmentInput.init)
            let batch = Array(inputs.prefix(ComposerAttachment.maxCount + 1))
            return !batch.isEmpty && target.attach(batch)
        }
    }
}
