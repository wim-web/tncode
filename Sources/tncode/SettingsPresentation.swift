import SwiftUI

/// Presents Settings the way T3 Code's route modal does: a card over the dimmed workspace in the same window,
/// instead of a macOS sheet.
struct SettingsPresentation: ViewModifier {
    @ObservedObject var model: WorkspaceModel
    let appearance: AppearanceSettings
    let browserDefaults: UserDefaults
    let pasteboard: NSPasteboard
    let openWelcome: () -> Void
    @State private var returnFocus = ReturnFocus()

    /// A sheet hands focus back to the main window when it closes; the in-window modal does the same.
    private final class ReturnFocus {
        weak var window: NSWindow?
        weak var responder: NSResponder?

        func capture() {
            guard let window = NSApp.keyWindow else { return }
            self.window = window
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
               let field = editor.delegate as? NSResponder {
                responder = field
            } else {
                responder = window.firstResponder
            }
        }

        func restore() {
            defer { responder = nil }
            guard let window, let responder else { return }
            if let view = responder as? NSView, view.window !== window { return }
            window.makeFirstResponder(responder)
        }
    }

    func body(content: Content) -> some View {
        content
            .blur(radius: model.settingsRequest == nil ? 0 : 2)
            .onChange(of: model.settingsRequest?.id) { previous, current in
                if previous == nil, current != nil { returnFocus.capture() }
                if previous != nil, current == nil {
                    Task { @MainActor in
                        await Task.yield()
                        if model.settingsRequest == nil, !model.showingWelcome { returnFocus.restore() }
                    }
                }
            }
            .overlay {
                if let request = model.settingsRequest {
                    GeometryReader { window in
                        let frame = T3RouteModalLayout.frame(in: window.size)
                        ZStack(alignment: .topLeading) {
                            T3ModalBackdrop { request.requestClose() }
                            SettingsView(model: model, appearance: appearance, browserDefaults: browserDefaults,
                                         request: request, pasteboard: pasteboard, openWelcome: openWelcome)
                                .defaultAppStorage(browserDefaults)
                                .environment(\.settingsViewportHeight, window.size.height)
                                .frame(width: frame.width, height: frame.height)
                                .modifier(T3ModalCard(radius: frame.radius))
                                .offset(x: frame.minX, y: frame.minY)
                        }
                    }
                    .ignoresSafeArea()
                    .id(request.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.settingsRequest?.id)
    }
}

/// AppRouteModal sizing: inset 40 on windows at least 1024 wide, 24 from 640, edge to edge below; max 1280×960.
enum T3RouteModalLayout {
    struct Frame {
        let minX: CGFloat
        let minY: CGFloat
        let width: CGFloat
        let height: CGFloat
        let radius: CGFloat
    }

    static func frame(in size: CGSize) -> Frame {
        let inset: CGFloat = size.width >= 1024 ? 40 : size.width >= 640 ? 24 : 0
        let top = inset == 0 ? 0 : max(inset, inset == 24 ? WorkspaceLayout.headerHeight : 0)
        let width = min(1280, max(0, size.width - inset * 2))
        let height = min(960, max(0, size.height - top - inset))
        return Frame(minX: (size.width - width) / 2, minY: top + (size.height - top - inset - height) / 2,
                     width: width, height: height, radius: inset == 0 ? 0 : 16)
    }
}

/// Window-wide layer behind a modal: black 64% (dark) or canvas 60% (light).
struct T3ModalBackdrop: View {
    let dismiss: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        T3Palette(colorScheme, t3Themes).backdrop
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dismiss?() }
            .accessibilityHidden(true)
    }
}

/// Canvas-coloured card with T3 Code's modal radius, hairline border and shadow.
struct T3ModalCard: ViewModifier {
    var radius: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    func body(content: Content) -> some View {
        let palette = T3Palette(colorScheme, t3Themes)
        content
            .background(palette.canvas, in: RoundedRectangle(cornerRadius: radius))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(palette.border) }
            .shadow(color: .black.opacity(0.35), radius: 20, y: 25)
    }
}
