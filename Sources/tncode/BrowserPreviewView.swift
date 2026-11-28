import AppKit
import Carbon
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
                        Button(profile.label) { preview.addTab(profile: profile) }
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
                let inMiniPlayer = preview.miniPlayer?.tab.id == tab.id
                if inMiniPlayer || preview.floatingTab?.id == tab.id {
                    VStack(spacing: 8) {
                        Text(inMiniPlayer ? "This tab is in the Mini Player." : "This tab is in a floating window.")
                            .foregroundStyle(.secondary)
                        Button("Dock Browser Tab") { preview.dockTab(tab.id) }
                            .accessibilityIdentifier("browser-dock-here")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BrowserSessionView(session: tab, location: .panel(miniPlayer: { preview.openMiniPlayer() },
                                                                     popOut: { preview.undockSelectedTab() }))
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
        let title = tab.pageURL?.host() ?? String(localized: "Browser")
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
            .help("\(title) (\(tab.profile.label))")
            .accessibilityValue(tab.profile.label)
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
    enum Location {
        case panel(miniPlayer: () -> Void, popOut: () -> Void)
        case window(dock: () -> Void)

        var surface: BrowserSurface {
            switch self {
            case .panel: .panel
            case .window: .window
            }
        }
    }

    @ObservedObject var session: BrowserPreviewSession
    let location: Location
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                browserControl("Back", "chevron.left", id: "browser-back", action: session.goBack)
                    .disabled(!session.canGoBack)
                browserControl("Forward", "chevron.right", id: "browser-forward", action: session.goForward)
                    .disabled(!session.canGoForward)
                browserControl(session.isLoading ? "Stop Loading" : "Reload",
                        session.isLoading ? "xmark" : "arrow.clockwise",
                        id: "browser-reload", action: session.reloadOrStop)
                    .disabled(!session.canReload)
                TextField("Search or enter URL", text: $session.address)
                    .focused($addressFocused)
                    .accessibilityIdentifier("browser-address")
                    .onSubmit(session.openAddress)
                browserControl("Go", "arrow.right", id: "browser-go", action: session.openAddress)
                    .disabled(session.address.isEmpty)
                switch location {
                case let .panel(miniPlayer, popOut):
                    browserControl("Open Mini Player", "pip.enter", id: "browser-open-mini", action: miniPlayer)
                    browserControl("Open in Floating Window", "macwindow", id: "browser-undock", action: popOut)
                case .window(let dock):
                    browserControl("Dock Browser Tab", "sidebar.right", id: "browser-dock", action: dock)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)

            HStack(spacing: 4) {
                Text(session.profile.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Each profile keeps separate website data for this thread until the app quits.")
                    .accessibilityLabel("Browser Profile: \(session.profile.label)")
                    .accessibilityIdentifier("browser-profile")
                Spacer()
                browserControl("Find on page", "magnifyingglass", id: "browser-find", action: session.openFind)
                browserControl("Zoom Out", "minus", id: "browser-zoom-out", action: session.zoomOut)
                    .disabled(!session.canZoomOut)
                Button("\(session.zoom)%", action: session.resetZoom)
                    .monospacedDigit()
                    .help("Reset Zoom")
                    .accessibilityLabel("Reset Zoom")
                    .accessibilityValue("\(session.zoom)%")
                    .accessibilityIdentifier("browser-reset-zoom")
                browserControl("Zoom In", "plus", id: "browser-zoom-in", action: session.zoomIn)
                    .disabled(!session.canZoomIn)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Divider()
            if case .notice(let message) = session.problem {
                Text(localized: message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .accessibilityIdentifier("browser-error")
                Divider()
            }
            BrowserPageContent(session: session, surface: location.surface, emptyHint: "Search or enter a URL to open a page.",
                               addressFocused: addressFocused)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-preview")
    }
}

struct BrowserPageContent: View {
    @ObservedObject var session: BrowserPreviewSession
    let surface: BrowserSurface
    let emptyHint: String
    var addressFocused = false
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if surface != .miniPlayer { findBar }
            page
            if surface == .miniPlayer { findBar }
        }
        .background { WindowKeyMonitor(handle: handleFindKey) }
    }

    private var page: some View {
        ZStack {
            if case let .unreachable(url, message, domain, code) = session.problem {
                BrowserUnreachableView(url: url, message: message, errorCode: "\(domain) \(code)",
                                       reload: session.reloadOrStop)
                    .id(session.problem)
            } else {
                let empty = session.pageURL == nil && !session.isLoading
                BrowserWebView(session: session, surface: surface)
                    .opacity(empty ? 0 : 1)
                    .accessibilityHidden(empty)
                    .allowsHitTesting(!empty)
                if empty && session.problem == nil {
                    Text(localized: emptyHint)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var findBar: some View {
        if let find = session.find {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    TextField("Find in page", text: Binding(get: { session.find?.query ?? "" }, set: session.editFindQuery))
                        .textFieldStyle(.roundedBorder)
                        .focused($findFocused)
                        .accessibilityIdentifier("browser-find-query")
                    browserControl("Previous match", "chevron.up", id: "browser-find-previous") {
                        session.stepFind(backward: true)
                    }
                    .disabled(find.status != .match)
                    browserControl("Next match", "chevron.down", id: "browser-find-next") {
                        session.stepFind(backward: false)
                    }
                    .disabled(find.status != .match)
                    browserControl("Close find", "xmark", id: "browser-find-close") {
                        session.closeFind(returningFocus: true)
                    }
                }
                if let status = find.status.label {
                    Text(localized: status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("browser-find-status")
                }
            }
            .padding(6)
            .background(.regularMaterial)
            .task(id: find.focusRequest) {
                await Task.yield()
                guard !Task.isCancelled, session.find?.focusRequest == find.focusRequest,
                      session.surface == surface else { return }
                if findFocused { (session.webView.window?.firstResponder as? NSTextView)?.selectAll(nil) }
                else { findFocused = true }
            }
        }
    }

    private func handleFindKey(_ event: NSEvent, window: NSWindow) -> Bool {
        guard session.surface == surface, window.attachedSheet == nil, NSApp.modalWindow == nil,
              (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let editingField = (window.firstResponder as? NSTextView)?.isFieldEditor == true
        let editingFindField = editingField && findFocused
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f",
           session.hasPageFocus(in: window) || editingFindField || (editingField && addressFocused) {
            if editingFindField { (window.firstResponder as? NSTextView)?.selectAll(nil) }
            else { session.openFind() }
            return true
        }
        guard editingFindField else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            session.closeFind(returningFocus: true)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard modifiers.isEmpty || modifiers == .shift else { return false }
            session.stepFind(backward: modifiers == .shift)
            return true
        default:
            return false
        }
    }
}

private func browserControl(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .frame(width: 21, height: 21)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(Text(localized: title))
    .accessibilityLabel(Text(localized: title))
    .accessibilityIdentifier(id)
}

private extension BrowserPageFind.Status {
    var label: String? {
        switch self {
        case .idle: nil
        case .loading: "Waiting for the page to load…"
        case .searching: "Searching…"
        case .match: "Match found"
        case .noMatches: "No matches"
        case .unavailable: "Find on page isn’t available for this page."
        }
    }
}

private struct BrowserUnreachableView: View {
    let url: URL
    let message: String
    let errorCode: String
    let reload: () -> Void
    @State private var showsDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("This site can’t be reached").font(.headline)
                Text(url.host() ?? url.absoluteString).fontWeight(.medium)
                Text(message).foregroundStyle(.secondary)
                if showsDetails {
                    Text("Check the connection and make sure the server is running at this address.")
                    Text(url.absoluteString).textSelection(.enabled)
                    Text(errorCode).font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("browser-error-code")
                }
                HStack {
                    Button(showsDetails ? "Hide Details" : "Details") { showsDetails.toggle() }
                        .accessibilityIdentifier("browser-error-details")
                    Button("Reload", action: reload)
                        .accessibilityIdentifier("browser-error-reload")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .accessibilityIdentifier("browser-unreachable")
    }
}

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var session: BrowserPreviewSession
    let surface: BrowserSurface

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ host: NSView, context: Context) {
        let webView = session.webView
        guard session.surface == surface, webView.superview !== host else { return }
        host.subviews = []
        webView.removeFromSuperview()
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
    }

    static func dismantleNSView(_ host: NSView, coordinator: ()) {
        host.subviews = []
    }
}
