import SwiftUI

struct ProjectPathKeyboard: NSViewRepresentable {
    enum Response {
        case ignored
        case handled
        case replacePath(String)
    }

    let isPathFocused: () -> Bool
    let handle: (NSEvent) -> Response

    final class Coordinator {
        var monitor: Any?
        var keyboard: ProjectPathKeyboard

        init(_ keyboard: ProjectPathKeyboard) {
            self.keyboard = keyboard
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak anchor, weak coordinator] event in
            guard let coordinator, let window = anchor?.window, window === event.window,
                  coordinator.keyboard.isPathFocused(), let editor = window.firstResponder as? NSTextView,
                  editor.isFieldEditor, !editor.hasMarkedText() else { return event }
            switch coordinator.keyboard.handle(event) {
            case .ignored:
                return event
            case .handled:
                return nil
            case .replacePath(let path):
                editor.insertText(path, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                return nil
            }
        }
        return anchor
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.keyboard = self
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
}
