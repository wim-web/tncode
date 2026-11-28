import AppKit
import SwiftUI

/// Matches T3 Code's `hiddenInset` window: no visible title bar, content under the title bar area,
/// and traffic lights centred in the 52pt strip shared by the sidebar and the chat header.
///
/// SwiftUI can turn the title bar opaque again after the window opens. On macOS 26 an opaque title bar
/// draws a blurred band over the whole 52pt strip and hides the chat header, so the probe watches the
/// window and restores the hidden title bar whenever it changes.
struct WindowChrome: NSViewRepresentable {
    static let trafficLightOrigin = CGPoint(x: 16, y: 19)
    static let bandHeight: CGFloat = 52

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.apply()
    }

    final class Probe: NSView {
        private var observers: [NSObjectProtocol] = []
        private var chromeObservations: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            chromeObservations = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didBecomeMainNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
            }
            chromeObservations = [
                window.observe(\.titlebarAppearsTransparent) { [weak self] _, _ in self?.scheduleReapply() },
                window.observe(\.titleVisibility) { [weak self] _, _ in self?.scheduleReapply() },
                window.observe(\.styleMask) { [weak self] _, _ in self?.scheduleReapply() },
            ]
            apply()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Runs after the change that triggered it, so the window is not edited while it is still notifying.
        private nonisolated func scheduleReapply() {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        func apply() {
            guard let window, window.styleMask.contains(.titled) else { return }
            // Only write values that differ, so the observers above do not wake themselves up.
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
            layoutTrafficLights()
        }

        override func layout() {
            super.layout()
            layoutTrafficLights()
        }

        func layoutTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let miniaturize = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let container = close.superview?.superview else { return }
            let buttonHeight = close.frame.height
            let height = WindowChrome.bandHeight
            var frame = container.frame
            if frame.height != height || frame.minY != window.frame.height - height {
                frame.size.height = height
                frame.origin.y = window.frame.height - height
                container.frame = frame
            }
            let spacing = miniaturize.frame.minX - close.frame.minX
            let y = height - WindowChrome.trafficLightOrigin.y - buttonHeight
            for (index, button) in [close, miniaturize, zoom].enumerated() {
                let origin = CGPoint(x: WindowChrome.trafficLightOrigin.x + CGFloat(index) * spacing, y: y)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}

/// Lets a transparent region of the 52pt band drag the window, as `-webkit-app-region: drag` does.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window?.performMiniaturize(nil)
                case "None": break
                default: window?.performZoom(nil)
                }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
