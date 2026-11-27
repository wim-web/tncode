import SwiftUI

struct WindowKeyMonitor: NSViewRepresentable {
    var includesPopoverFieldEditor = false
    let handle: (NSEvent, NSWindow) -> Bool

    final class Coordinator {
        var monitor: Any?
        var handle: (NSEvent, NSWindow) -> Bool

        init(handle: @escaping (NSEvent, NSWindow) -> Bool) {
            self.handle = handle
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        let coordinator = context.coordinator
        let includesPopoverFieldEditor = self.includesPopoverFieldEditor
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak anchor, weak coordinator] event in
            guard let window = anchor?.window, let target = event.window,
                  window === target || (includesPopoverFieldEditor && window.sharesFieldEditor(withKeyParent: target)),
                  coordinator?.handle(event, window) == true else { return event }
            return nil
        }
        return anchor
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
}

private extension NSWindow {
    func sharesFieldEditor(withKeyParent target: NSWindow) -> Bool {
        // AppKit can keep the workspace key while its first responder edits text inside the popover.
        guard target === parent, target === NSApp.keyWindow,
              let editor = firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return editor === target.firstResponder && editor.window === self
    }
}
