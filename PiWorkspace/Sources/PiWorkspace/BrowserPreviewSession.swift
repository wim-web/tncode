import Combine
import WebKit

enum BrowserProfile: String, CaseIterable {
    case standard = "Default"
    case alternate = "Alternate"
}

enum BrowserSurface { case panel, miniPlayer, window }

enum BrowserPreviewProblem: Hashable {
    case notice(String)
    case unreachable(url: URL, message: String, domain: String, code: Int)

    var message: String {
        switch self {
        case .notice(let text), .unreachable(_, let text, _, _): text
        }
    }
}

@MainActor
struct ThreadBrowserPreview {
    private enum FloatingTab {
        case window(UUID)
        case miniPlayer(UUID, BrowserMiniPlayerPlacement)

        var id: UUID {
            switch self {
            case .window(let id), .miniPlayer(let id, _): id
            }
        }

        var surface: BrowserSurface {
            switch self {
            case .window: .window
            case .miniPlayer: .miniPlayer
            }
        }
    }

    private(set) var tabs: [BrowserPreviewSession] = []
    private(set) var selectedTabID: UUID?
    private var floating: FloatingTab? {
        didSet {
            if let previous = oldValue, previous.id != floating?.id {
                tabs.first { $0.id == previous.id }?.surface = .panel
            }
            if let floating, let tab = tabs.first(where: { $0.id == floating.id }), tab.surface != floating.surface {
                tab.surface = floating.surface
            }
        }
    }
    private var dataStores: [BrowserProfile: WKWebsiteDataStore] = [:]
    var isVisible = false

    var selectedTab: BrowserPreviewSession? { tabs.first { $0.id == selectedTabID } }
    var floatingTab: BrowserPreviewSession? {
        guard case .window(let id) = floating else { return nil }
        return tabs.first { $0.id == id }
    }

    var miniPlayer: (tab: BrowserPreviewSession, placement: BrowserMiniPlayerPlacement)? {
        guard case let .miniPlayer(id, placement) = floating,
              let tab = tabs.first(where: { $0.id == id }) else { return nil }
        return (tab, placement)
    }

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
        if floating?.id == id { floating = nil }
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { isVisible = false }
    }

    mutating func undockSelectedTab() {
        guard let selectedTabID else { return }
        openWindow(for: selectedTabID)
    }

    mutating func openWindow(for id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        floating = .window(id)
        isVisible = false
    }

    mutating func openMiniPlayer() {
        guard let tab = selectedTab else { return }
        floating = .miniPlayer(tab.id, BrowserMiniPlayerPlacement(source: tab.webView.bounds.size))
        isVisible = false
    }

    mutating func placeMiniPlayer(_ placement: BrowserMiniPlayerPlacement, for id: UUID) {
        guard case .miniPlayer(id, _) = floating else { return }
        floating = .miniPlayer(id, placement)
    }

    mutating func closeMiniPlayer(for id: UUID) {
        guard case .miniPlayer(id, _) = floating else { return }
        floating = nil
    }

    mutating func dockTab(_ id: UUID) {
        guard floating?.id == id else { return }
        floating = nil
        selectTab(id)
        isVisible = true
    }

    mutating func dismissFloatingWindow(for id: UUID) {
        guard case .window(id) = floating else { return }
        floating = nil
    }
}

@MainActor
final class BrowserPreviewSession: NSObject, Identifiable, ObservableObject, WKNavigationDelegate {
    let id = UUID()
    let profile: BrowserProfile
    let webView: WKWebView
    @Published fileprivate(set) var surface: BrowserSurface = .panel
    @Published var address = ""
    @Published private(set) var pageURL: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var problem: BrowserPreviewProblem?
    var message: String? { problem?.message }
    @Published private(set) var zoom = 100
    @Published private var retryURL: URL?
    private var pendingURL: URL?
    private var urlObservation: AnyCancellable?
    private let searchDefaults: UserDefaults

    init(profile: BrowserProfile, dataStore: WKWebsiteDataStore, searchDefaults: UserDefaults = .standard) {
        self.profile = profile
        self.searchDefaults = searchDefaults
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
        let searchSettings = BrowserSearchSettings.load(from: searchDefaults)
        guard let url = BrowserAddress.resolve(address, searchSettings: searchSettings) else {
            problem = .notice("Could not open this address. Enter a valid HTTP or HTTPS URL.")
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
        problem = nil
        retryURL = nil
        pendingURL = url
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let frame = action.targetFrame else { return .cancel }
        if !frame.isMainFrame { return .allow }
        guard let url = action.request.url, BrowserAddress.isWebURL(url) else {
            problem = .notice("Browser preview can open HTTP and HTTPS pages.")
            return .cancel
        }
        pendingURL = url
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !response.isForMainFrame { return .allow }
        guard let url = response.response.url, BrowserAddress.isWebURL(url) else { return .cancel }
        guard response.canShowMIMEType else {
            problem = .notice("Browser preview can’t display this file type.")
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        retryURL = nil
        problem = nil
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
        problem = .notice("The page stopped responding. Reload to try again.")
    }

    private func showFailure(_ error: Error) {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
        let attemptedURL = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? pendingURL ?? pageURL
        pendingURL = nil
        if let url = attemptedURL, BrowserAddress.isWebURL(url) {
            retryURL = url
            address = url.absoluteString
            problem = .unreachable(url: url, message: failure.localizedDescription, domain: failure.domain, code: failure.code)
        } else {
            problem = .notice(failure.localizedDescription)
        }
    }
}
