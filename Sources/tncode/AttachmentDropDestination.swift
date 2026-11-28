import SwiftUI

extension View {
    func attachmentDropDestination(canDrop: Bool, threadSource: SidebarThreadDrag.Source? = nil,
                                   threadDrop: SidebarThreadDrag.Destination? = nil,
                                   perform: @escaping ([NSPasteboardItem]) -> Bool,
                                   isTargeted: @escaping (Bool) -> Void) -> some View {
        background {
            AttachmentDropDestination(canDrop: canDrop, perform: perform, isTargeted: isTargeted,
                                      threadSource: threadSource, threadDrop: threadDrop)
                .id(threadDrop?.placement)
                .accessibilityHidden(true)
        }
    }
}

/// AppKit routes drags by registered pasteboard type, independently of mouse hit testing.
struct AttachmentDropDestination: NSViewRepresentable {
    struct FileMentionDrop {
        let accepts: (UUID) -> Bool
        let receive: (UUID) -> Bool
    }

    let canDrop: Bool
    let perform: ([NSPasteboardItem]) -> Bool
    let isTargeted: (Bool) -> Void
    var fileMentionDrop: FileMentionDrop?
    var threadSource: SidebarThreadDrag.Source?
    var threadDrop: SidebarThreadDrag.Destination?
    var receivesAttachments = true

    static let types = ComposerAttachmentInput.contentTypes.map { NSPasteboard.PasteboardType($0.identifier) }
    var dragTypes: [NSPasteboard.PasteboardType] {
        var types = receivesAttachments ? Self.types : []
        if fileMentionDrop != nil { types.append(WorkspaceFileMentionDrag.type) }
        if threadDrop != nil { types.append(SidebarThreadDrag.type) }
        return types
    }

    private func isThreadDrag(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL]) == nil &&
            pasteboard.availableType(from: [SidebarThreadDrag.type]) != nil
    }

    func operation(for sender: NSDraggingInfo) -> NSDragOperation? {
        let pasteboard = sender.draggingPasteboard
        if isThreadDrag(pasteboard) { return threadDrop?.operation(for: sender) ?? [] }
        guard receivesAttachments else { return nil }
        let allowsCopy = canDrop && sender.draggingSourceOperationMask.contains(.copy)
        let accepts: Bool
        if pasteboard.types?.contains(WorkspaceFileMentionDrag.type) == true {
            accepts = allowsCopy && fileMentionToken(from: pasteboard).map { fileMentionDrop?.accepts($0) == true } == true
        } else {
            guard pasteboard.availableType(from: Self.types) != nil else { return nil }
            accepts = allowsCopy
        }
        isTargeted(accepts)
        return accepts ? .copy : []
    }

    func receive(_ sender: NSDraggingInfo) -> Bool? {
        guard let operation = operation(for: sender) else { return nil }
        defer { isTargeted(false) }
        guard !operation.isEmpty else { return false }
        let pasteboard = sender.draggingPasteboard
        if isThreadDrag(pasteboard) { return threadDrop?.perform(sender) == true }
        if pasteboard.types?.contains(WorkspaceFileMentionDrag.type) == true {
            guard let id = fileMentionToken(from: pasteboard) else { return false }
            return fileMentionDrop?.receive(id) == true
        }
        return receiveItems(from: pasteboard)
    }

    private func fileMentionToken(from pasteboard: NSPasteboard) -> UUID? {
        guard fileMentionDrop != nil else { return nil }
        return WorkspaceFileMentionDrag.token(from: pasteboard)
    }

    func receiveItems(from pasteboard: NSPasteboard) -> Bool {
        guard canDrop, let items = pasteboard.pasteboardItems, !items.isEmpty else { return false }
        return perform(items)
    }

    func makeNSView(context: Context) -> Destination {
        let view = Destination()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Destination, context: Context) {
        if Set(view.registeredDraggedTypes) != Set(dragTypes) { view.registerForDraggedTypes(dragTypes) }
        if view.source?.drag !== threadSource?.drag {
            view.source?.drag.removeSource(view)
            threadSource?.drag.addSource(view)
        }
        view.target = self
    }

    static func dismantleNSView(_ view: Destination, coordinator: ()) {
        view.source?.drag.removeSource(view)
        view.target = nil
    }

    final class Destination: NSView {
        var target: AttachmentDropDestination?
        var source: SidebarThreadDrag.Source? { target?.threadSource }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            target?.operation(for: sender) ?? []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            target?.operation(for: sender) ?? []
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            target?.operation(for: sender).map { !$0.isEmpty } ?? false
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            target?.isTargeted(false)
            if let drop = target?.threadDrop { drop.drag.clearTarget(drop.placement) }
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            target?.receive(sender) ?? false
        }
    }
}
