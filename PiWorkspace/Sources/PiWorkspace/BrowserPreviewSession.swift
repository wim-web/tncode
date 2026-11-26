import Combine
import WebKit

enum BrowserProfile: String, CaseIterable {
    case standard = "Default"
    case alternate = "Alternate"
}

@MainActor
struct ThreadBrowserPreview {
    private(set) var tabs: [BrowserPreviewSession] = []
    private(set) var selectedTabID: UUID?
    private var floatingTabID: UUID?
    private var dataStores: [BrowserProfile: WKWebsiteDataStore] = [:]
    var isVisible = false

    var selectedTab: BrowserPreviewSession? { tabs.first { $0.id == selectedTabID } }
    var floatingTab: BrowserPreviewSession? { tabs.first { $0.id == floatingTabID } }

    mutating func togglePanel() {
        if tabs.isEmpty {
            addTab(profile: .standard)
        } else {
            isVisible.toggle()
        }
    }

    mutating func addTab(profile: BrowserProfile) {
        let dataStore = dataStores[profile] ?? WKWebsiteDataStore.nonPersistent()
        dataStores[profile] = dataStore
        let tab = BrowserPreviewSession(profile: profile, dataStore: dataStore)
        tabs.append(tab)
        selectTab(tab.id)
        isVisible = true
    }

    mutating func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    mutating func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if floatingTabID == id { floatingTabID = nil }
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { isVisible = false }
    }

    mutating func undockSelectedTab() {
        guard let selectedTabID else { return }
        floatingTabID = selectedTabID
        isVisible = false
    }

    mutating func dockTab(_ id: UUID) {
        guard floatingTabID == id else { return }
        floatingTabID = nil
        selectTab(id)
        isVisible = true
    }

    mutating func dismissFloatingWindow(for id: UUID) {
        guard floatingTabID == id else { return }
        floatingTabID = nil
    }
}

@MainActor
final class BrowserPreviewSession: NSObject, Identifiable, ObservableObject, WKNavigationDelegate {
    let id = UUID()
    let profile: BrowserProfile
    let webView: WKWebView
    @Published var address = ""
    @Published private(set) var pageURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var zoom = 100
    @Published private var retryURL: URL?
    private var pendingURL: URL?
    private var urlObservation: AnyCancellable?

    init(profile: BrowserProfile, dataStore: WKWebsiteDataStore) {
        self.profile = profile
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.publisher(for: \.canGoBack).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).filter { !$0 }.assign(to: &$isLoading)
        urlObservation = webView.publisher(for: \.url).sink { [weak self] url in
            self?.pageURL = url
            if let url { self?.address = url.absoluteString }
        }
    }

    var canReload: Bool { isLoading || retryURL != nil || pageURL != nil }
    var canZoomIn: Bool { zoom < 200 }
    var canZoomOut: Bool { zoom > 50 }

    func openAddress() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text, encodingInvalidCharacters: false), Self.isWebURL(url) else {
            message = "Enter a valid URL starting with http:// or https://."
            return
        }
        load(url)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reloadOrStop() {
        if isLoading {
            let stoppedURL = pendingURL
            webView.stopLoading()
            retryURL = stoppedURL
            if let stoppedURL { address = stoppedURL.absoluteString }
        } else if let retryURL {
            load(retryURL)
        } else {
            webView.reload()
        }
    }

    func zoomIn() { setZoom(min(200, zoom + 10)) }
    func zoomOut() { setZoom(max(50, zoom - 10)) }
    func resetZoom() { setZoom(100) }

    private func setZoom(_ percent: Int) {
        zoom = percent
        webView.pageZoom = CGFloat(percent) / 100
    }

    private func load(_ url: URL) {
        address = url.absoluteString
        message = nil
        retryURL = nil
        pendingURL = url
        webView.load(URLRequest(url: url))
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty,
              url.user() == nil, url.password() == nil else { return false }
        return url.port.map { (1...65535).contains($0) } ?? true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let frame = action.targetFrame else { return .cancel }
        if !frame.isMainFrame { return .allow }
        guard let url = action.request.url, Self.isWebURL(url) else {
            message = "Browser preview can open HTTP and HTTPS pages."
            return .cancel
        }
        pendingURL = url
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !response.isForMainFrame { return .allow }
        guard let url = response.response.url, Self.isWebURL(url) else { return .cancel }
        guard response.canShowMIMEType else {
            message = "Browser preview can’t display this file type."
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        retryURL = nil
        message = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pendingURL = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        message = "The page stopped responding. Reload to try again."
    }

    private func showFailure(_ error: Error) {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
        let attemptedURL = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? pendingURL
        pendingURL = nil
        if let url = attemptedURL, Self.isWebURL(url) {
            retryURL = url
            address = url.absoluteString
        }
        message = failure.localizedDescription
    }
}
