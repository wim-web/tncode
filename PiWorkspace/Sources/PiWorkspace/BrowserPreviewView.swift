import AppKit
import SwiftUI
import WebKit

struct BrowserPreviewView: View {
    @Binding var preview: ThreadBrowserPreview

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(preview.tabs) { tab in
                                BrowserTabButton(tab: tab, selected: preview.selectedTabID == tab.id) {
                                    preview.selectTab(tab.id)
                                } close: {
                                    preview.closeTab(tab.id)
                                }
                                .id(tab.id)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: preview.selectedTabID, initial: true) { _, id in
                        if let id { scroll.scrollTo(id) }
                    }
                }
                Menu {
                    ForEach(BrowserProfile.allCases, id: \.self) { profile in
                        Button(profile.rawValue) { preview.addTab(profile: profile) }
                            .accessibilityIdentifier("browser-new-tab-\(profile.rawValue.lowercased())")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New Browser Tab")
                .accessibilityLabel("New Browser Tab")
                .accessibilityIdentifier("browser-new-tab")
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            Divider()

            if let tab = preview.selectedTab {
                if preview.floatingTab?.id == tab.id {
                    VStack(spacing: 8) {
                        Text("This tab is in a floating window.")
                            .foregroundStyle(.secondary)
                        Button("Dock Browser Tab") { preview.dockTab(tab.id) }
                            .accessibilityIdentifier("browser-dock-here")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BrowserSessionView(session: tab, floating: false) { preview.undockSelectedTab() }
                        .id(tab.id)
                }
            }
        }
    }
}

private struct BrowserTabButton: View {
    @ObservedObject var tab: BrowserPreviewSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        let title = tab.pageURL?.host() ?? "Browser"
        HStack(spacing: 4) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .help("Close Tab")
            .accessibilityLabel("Close \(title) Tab")
            .accessibilityIdentifier("browser-close-tab-\(tab.id)")

            Button(action: select) {
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: 114, minHeight: 20)
                    .contentShape(Rectangle())
            }
            .help("\(title) (\(tab.profile.rawValue))")
            .accessibilityValue(tab.profile.rawValue)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("browser-tab-\(tab.id)")
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 4)
        .background(selected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct BrowserSessionView: View {
    @ObservedObject var session: BrowserPreviewSession
    let floating: Bool
    let move: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                control("Back", "chevron.left", id: "browser-back", action: session.goBack)
                    .disabled(!session.canGoBack)
                control("Forward", "chevron.right", id: "browser-forward", action: session.goForward)
                    .disabled(!session.canGoForward)
                control(session.isLoading ? "Stop Loading" : "Reload",
                        session.isLoading ? "xmark" : "arrow.clockwise",
                        id: "browser-reload", action: session.reloadOrStop)
                    .disabled(!session.canReload)
                TextField("Enter URL", text: $session.address)
                    .accessibilityIdentifier("browser-address")
                    .onSubmit(session.openAddress)
                control("Open URL", "arrow.right", id: "browser-go", action: session.openAddress)
                    .disabled(session.address.isEmpty)
                if floating {
                    control("Dock Browser Tab", "sidebar.right", id: "browser-dock", action: move)
                } else {
                    control("Open in Floating Window", "macwindow", id: "browser-undock", action: move)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)

            HStack(spacing: 4) {
                Text(session.profile.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Each profile keeps separate website data for this thread until the app quits.")
                    .accessibilityLabel("Browser Profile: \(session.profile.rawValue)")
                    .accessibilityIdentifier("browser-profile")
                Spacer()
                control("Zoom Out", "minus", id: "browser-zoom-out", action: session.zoomOut)
                    .disabled(!session.canZoomOut)
                Button("\(session.zoom)%", action: session.resetZoom)
                    .monospacedDigit()
                    .help("Reset Zoom")
                    .accessibilityLabel("Reset Zoom")
                    .accessibilityValue("\(session.zoom)%")
                    .accessibilityIdentifier("browser-reset-zoom")
                control("Zoom In", "plus", id: "browser-zoom-in", action: session.zoomIn)
                    .disabled(!session.canZoomIn)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Divider()
            if let message = session.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .accessibilityIdentifier("browser-error")
                Divider()
            }
            ZStack {
                let empty = session.pageURL == nil && !session.isLoading
                BrowserWebView(webView: session.webView)
                    .opacity(empty ? 0 : 1)
                    .accessibilityHidden(empty)
                    .allowsHitTesting(!empty)
                if empty && session.message == nil {
                    Text("Enter an HTTP or HTTPS URL to preview a page.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-preview")
    }

    private func control(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 21, height: 21)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ host: NSView, context: Context) {
        guard webView.superview !== host else { return }
        host.subviews = []
        webView.removeFromSuperview()
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
    }

    static func dismantleNSView(_ host: NSView, coordinator: ()) {
        // The web view may already belong to the other window.
        host.subviews = []
    }
}
