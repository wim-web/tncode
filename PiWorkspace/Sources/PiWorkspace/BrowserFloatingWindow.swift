import AppKit
import SwiftUI

struct BrowserFloatingWindow: NSViewRepresentable {
    let session: BrowserPreviewSession
    let dock: () -> Void
    let dismiss: () -> Void

    func makeNSView(context: Context) -> Anchor {
        Anchor(panel: BrowserFloatingPanel(session: session, dock: dock, dismiss: dismiss))
    }

    func updateNSView(_ view: Anchor, context: Context) {}

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.panel?.detach()
        view.panel = nil
    }

    final class Anchor: NSView {
        var panel: BrowserFloatingPanel?

        init(panel: BrowserFloatingPanel) {
            self.panel = panel
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                panel?.detach()
                return
            }
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.panel?.present(relativeTo: window)
            }
        }
    }
}

final class BrowserFloatingPanel: NSPanel, NSWindowDelegate {
    private let dismissPreview: () -> Void

    init(session: BrowserPreviewSession, dock: @escaping () -> Void, dismiss: @escaping () -> Void) {
        dismissPreview = dismiss
        super.init(contentRect: NSRect(x: 0, y: 0, width: 500, height: 360),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered, defer: true)
        title = "Floating Browser Preview"
        setAccessibilityIdentifier("browser-floating-window")
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: 320, height: 200)
        delegate = self
        contentView = NSHostingView(rootView: BrowserSessionView(session: session, floating: true, move: dock))
    }

    func present(relativeTo workspace: NSWindow) {
        guard parent !== workspace else { return }
        let workspaceFrame = workspace.frame
        setFrameTopLeftPoint(NSPoint(x: workspaceFrame.maxX - frame.width - 16, y: workspaceFrame.maxY - 68))
        workspace.addChildWindow(self, ordered: .above)
        orderFront(nil)
    }

    func detach() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        dismissPreview()
    }
}
