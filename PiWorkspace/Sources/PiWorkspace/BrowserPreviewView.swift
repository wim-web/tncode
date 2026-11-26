import SwiftUI
import WebKit

struct BrowserPreviewView: View {
    @ObservedObject var preview: ThreadBrowserPreview

    var body: some View {
        BrowserSessionView(session: preview.session, selectProfile: preview.selectProfile)
    }
}

private struct BrowserSessionView: View {
    @ObservedObject var session: BrowserPreviewSession
    let selectProfile: (BrowserProfile) -> Void

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
            }
            .padding(.horizontal, 8)
            .frame(height: 36)

            HStack(spacing: 4) {
                Picker("Browser Profile", selection: Binding(
                    get: { session.profile }, set: selectProfile
                )) {
                    ForEach(BrowserProfile.allCases, id: \.self) { profile in
                        Text(profile.rawValue).tag(profile)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Each profile keeps separate website data for this thread until the app quits.")
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
                    .id(ObjectIdentifier(session))
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

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
