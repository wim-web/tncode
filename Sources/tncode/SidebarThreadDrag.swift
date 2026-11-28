import SwiftUI

@MainActor
final class SidebarThreadDrag: NSObject, ObservableObject, NSDraggingSource {
    static let type = NSPasteboard.PasteboardType("dev.tncode.sidebar-thread")

    struct Source {
        let drag: SidebarThreadDrag
        let origin: () -> SidebarThreadDragOrigin?
    }

    @MainActor
    struct Destination {
        let drag: SidebarThreadDrag
        let placement: SidebarThreadPlacement
        let order: (SidebarThreadDragOrigin) -> [UUID]?
        let receive: (SidebarThreadDragOrigin) -> Bool

        func operation(for sender: NSDraggingInfo) -> NSDragOperation {
            guard sender.draggingSourceOperationMask.contains(.move),
                  let origin = drag.origin(for: sender), let order = order(origin) else {
                drag.clearTarget(placement)
                return []
            }
            let afterRow: Bool
            if case let .row(row) = placement.slot, let target = order.firstIndex(of: row),
               let source = order.firstIndex(of: origin.threadID) {
                afterRow = source > target
            } else {
                afterRow = false
            }
            let insertion = Insertion(placement: placement, afterRow: afterRow)
            if drag.insertion != insertion { drag.insertion = insertion }
            return .move
        }

        func perform(_ sender: NSDraggingInfo) -> Bool {
            guard let origin = drag.origin(for: sender) else { return false }
            drag.cancel()
            return receive(origin)
        }
    }

    struct Insertion: Equatable {
        let placement: SidebarThreadPlacement
        let afterRow: Bool
    }

    @Published private(set) var isDragging = false
    @Published private(set) var insertion: Insertion?
    private let sources = NSHashTable<AttachmentDropDestination.Destination>.weakObjects()
    private var monitor: Any?
    private var press: (view: AttachmentDropDestination.Destination, origin: SidebarThreadDragOrigin, event: NSEvent)?
    private var session: (token: UUID, origin: SidebarThreadDragOrigin)?
    private weak var appKitSession: NSDraggingSession?

    func addSource(_ view: AttachmentDropDestination.Destination) {
        sources.add(view)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
                [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }
    }

    func removeSource(_ view: AttachmentDropDestination.Destination) {
        sources.remove(view)
        if press?.view === view { press = nil }
        if sources.count == 0, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            cancel()
            guard event.clickCount == 1, !event.modifierFlags.contains(.control), let window = event.window,
                  let view = sources.allObjects.first(where: { view in
                      view.window === window && !view.isHiddenOrHasHiddenAncestor &&
                      view.bounds.intersection(view.visibleRect).contains(view.convert(event.locationInWindow, from: nil)) &&
                      view.source != nil
                  }), let origin = view.source?.origin() else { return false }
            press = (view, origin, event)
        case .leftMouseDragged:
            guard let press, event.window != nil, event.window === press.view.window else { return false }
            let start = press.event.locationInWindow
            let current = event.locationInWindow
            guard hypot(start.x - current.x, start.y - current.y) >= 5 else { return false }
            self.press = nil
            guard press.view.source?.origin() == press.origin, let content = event.window?.contentView else { return false }
            let rect = press.view.bounds.intersection(press.view.visibleRect)
            let snapshot = press.view.convert(rect, to: content)
            guard !snapshot.isEmpty, let bitmap = content.bitmapImageRepForCachingDisplay(in: snapshot) else { return false }
            content.cacheDisplay(in: snapshot, to: bitmap)
            let image = NSImage(size: rect.size)
            image.addRepresentation(bitmap)
            let item = NSDraggingItem(pasteboardWriter: begin(press.origin))
            item.setDraggingFrame(rect, contents: image)
            let dragging = press.view.beginDraggingSession(with: [item], event: event, source: self)
            dragging.animatesToStartingPositionsOnCancelOrFail = true
            return true
        case .leftMouseUp:
            press = nil
        default:
            break
        }
        return false
    }

    func begin(_ origin: SidebarThreadDragOrigin) -> NSPasteboardItem {
        let token = UUID()
        session = (token, origin)
        if !isDragging { isDragging = true }
        let item = NSPasteboardItem()
        item.setString(token.uuidString, forType: Self.type)
        return item
    }

    private func origin(for sender: NSDraggingInfo) -> SidebarThreadDragOrigin? {
        guard (sender.draggingSource as AnyObject?) === self,
              let session, sender.draggingPasteboard.string(forType: Self.type) == session.token.uuidString else {
            return nil
        }
        return session.origin
    }

    func clearTarget(_ placement: SidebarThreadPlacement) {
        if insertion?.placement == placement { insertion = nil }
    }

    func cancel() {
        press = nil
        session = nil
        appKitSession = nil
        if insertion != nil { insertion = nil }
        if isDragging { isDragging = false }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        appKitSession = session
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if appKitSession === session { cancel() }
    }
}
