import SwiftUI

struct WindowKeyMonitor: NSViewRepresentable {
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
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak anchor, weak coordinator] event in
            guard let window = anchor?.window, window === event.window,
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
