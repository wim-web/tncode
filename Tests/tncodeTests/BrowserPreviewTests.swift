import AppKit
import Carbon
import Network
import SwiftUI
import WebKit
import XCTest
@testable import tncode

final class BrowserPreviewTests: XCTestCase {
    func testMiniPlayerPreservesAspectAndPreferredPlacementAroundTheComposer() {
        let large = CGSize(width: 1000, height: 600)
        let composer = CGRect(x: 60, y: 455, width: 800, height: 140)
        let placement = BrowserMiniPlayerPlacement(source: CGSize(width: 800, height: 500))
        let plain = placement.frame(in: large)
        XCTAssertEqual(plain, CGRect(x: 668, y: 388, width: 320, height: 200))
        let clear = placement.frame(in: large, avoiding: [composer])
        XCTAssertEqual(clear.maxY, composer.minY - 12)
        let moved = placement.moved(from: clear, by: CGSize(width: -1000, height: -1000), in: large, avoiding: [composer])
        let corner = moved.frame(in: large, avoiding: [composer])
        XCTAssertEqual(corner.origin, CGPoint(x: 12, y: 12))
        let resized = moved.resized(from: corner, edge: .bottomRight, by: CGSize(width: 160, height: 100),
                                    in: large, avoiding: [composer])
        let result = resized.frame(in: large, avoiding: [composer])
        XCTAssertEqual(result, CGRect(x: 12, y: 12, width: 480, height: 300))
        let squeezed = resized.frame(in: CGSize(width: 220, height: 170))
        XCTAssertEqual(squeezed.width, 196)
        XCTAssertEqual(squeezed.width / squeezed.height, 1.6, accuracy: 0.001)
        XCTAssertEqual(resized.frame(in: large, avoiding: [composer]), result)
        let details = CGRect(x: 10, y: 10, width: 250, height: 150)
        let avoidingBoth = resized.frame(in: large, avoiding: [composer, details])
        XCTAssertFalse(avoidingBoth.intersects(composer))
        XCTAssertFalse(avoidingBoth.intersects(details))
        XCTAssertEqual(avoidingBoth.size, result.size)
    }

    func testAddressResolutionMatchesSearchAndNavigationDefaults() {
        let settings = BrowserSearchSettings()
        for (input, expected) in [
            ("localhost:5173", "http://localhost:5173/"),
            ("127.0.0.2:443/path", "http://127.0.0.2:443/path"),
            ("[::1]:3000", "http://[::1]:3000/"),
            ("0.0.0.0:3000", "http://0.0.0.0:3000/"),
            ("devbox:8080", "https://devbox:8080/"),
            ("192.168.1.5:3000", "https://192.168.1.5:3000/"),
            ("fixture.example/https://next.example", "https://fixture.example/https://next.example"),
            (" https://fixture.example/a b ", "https://fixture.example/a%20b"),
            ("weather", "https://duckduckgo.com/?q=weather"),
            ("note: café & #/?+%", "https://duckduckgo.com/?q=note%3A%20caf%C3%A9%20%26%20%23%2F%3F%2B%25")
        ] {
            XCTAssertEqual(BrowserAddress.resolve(input, searchSettings: settings)?.absoluteString, expected, input)
        }
        let google = BrowserSearchSettings(engine: .google)
        XCTAssertEqual(BrowserAddress.resolve("fixture & terms", searchSettings: google)?.absoluteString,
                       "https://www.google.com/search?q=fixture%20%26%20terms")
        let invalidCustom = BrowserSearchSettings(engine: .custom, customURL: "file:///%s")
        XCTAssertEqual(BrowserAddress.resolve("fixture terms", searchSettings: invalidCustom)?.absoluteString,
                       "https://duckduckgo.com/?q=fixture%20terms")
    }

    func testUnfinishedCustomTemplateSurvivesReopenAndUsesDuckDuckGo() throws {
        let suite = "BrowserSearchSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let template = "https://example.test/search?q="
        let edited = BrowserSearchSettings(engine: .custom, customURL: "  \(template)  ")
        XCTAssertTrue(edited.save(to: defaults), "A custom template without %s should stay editable after relaunch.")
        let loaded = BrowserSearchSettings.load(from: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(loaded, BrowserSearchSettings(engine: .custom, customURL: template))
        XCTAssertEqual(BrowserAddress.resolve("saved & reopened", searchSettings: loaded)?.absoluteString,
                       "https://duckduckgo.com/?q=saved%20%26%20reopened")
    }

    @MainActor
    func testAddressSubmissionUsesSavedEngineAndPreservesLoopbackURL() async throws {
        _ = NSApplication.shared
        let fixture = try LoopbackBrowserPage()
        defer { fixture.listener.cancel() }
        let origin = try await start(fixture)
        let port = try XCTUnwrap(origin.port)

        let suite = "BrowserPreviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(BrowserSearchSettings(engine: .brave, customURL: "\(origin)original?q=%s").save(to: defaults))
        let original = BrowserSearchSettings.load(from: defaults)
        let tab = BrowserPreviewSession(profile: .standard, dataStore: .nonPersistent(), searchDefaults: defaults)
        let rulesDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: rulesDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: rulesDirectory) }
        let ruleStore = try XCTUnwrap(WKContentRuleListStore(url: rulesDirectory))
        let compiledRules = try await ruleStore.compileContentRuleList(forIdentifier: "loopback-only", encodedContentRuleList: """
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^http://127[.]0[.]0[.]1:\(port)/"},"action":{"type":"ignore-previous-rules"}}
        ]
        """)
        tab.webView.configuration.userContentController.add(try XCTUnwrap(compiledRules))

        let path = "path%20with%20spaces?next=https://fixture.example/a%2Fb&raw=%2B#section"
        let direct = try XCTUnwrap(URL(string: origin.absoluteString + path))
        tab.address = "127.0.0.1:\(port)/\(path)"
        XCTAssertNil(tab.webView.url)
        tab.openAddress()
        try await waitFor("bare loopback URL with its path and query") {
            tab.pageURL == direct && tab.webView.title == "/path%20with%20spaces" && !tab.isLoading
        }

        let configured = BrowserSearchSettings(engine: .custom, customURL: " \(origin)search/%s?q=%s&lang=en ")
        for template in [
            "\(origin)search?q=", "file:///tmp/%s", "https://%s.example/",
            "http://127.0.0.1:99999999999999999999/?q=%s", "/search?q=%s"
        ] {
            XCTAssertTrue(BrowserSearchSettings(engine: .custom, customURL: template).save(to: defaults), template)
            let saved = BrowserSearchSettings.load(from: defaults)
            XCTAssertEqual(saved.customURL, template)
            XCTAssertEqual(BrowserAddress.resolve("query", searchSettings: saved)?.absoluteString,
                           "https://duckduckgo.com/?q=query", template)
        }
        XCTAssertTrue(configured.save(to: defaults))
        for template in [
            "http://%s@127.0.0.1:\(port)/?q=%s", "http://user:password@127.0.0.1:\(port)/?q=%s",
            String(repeating: "x", count: 2049)
        ] {
            XCTAssertFalse(BrowserSearchSettings(engine: .custom, customURL: template).save(to: defaults), template)
        }

        let escaped = "fixture%20caf%C3%A9%20%26%20%23%2F%3F%2B%25"
        tab.address = "  fixture café & #/?+%  "
        XCTAssertEqual(tab.pageURL, direct)
        tab.openAddress()
        let search = try XCTUnwrap(URL(string: "\(origin)search/\(escaped)?q=\(escaped)&lang=en"))
        try await waitFor("loopback search with the escaped term") {
            tab.pageURL == search && tab.webView.title == "/search/\(escaped)" && tab.canGoBack && !tab.isLoading
        }
        let receivedQuery = try await tab.webView.evaluateJavaScript("new URLSearchParams(location.search).get('q')")
        XCTAssertEqual(receivedQuery as? String, "fixture café & #/?+%")
        XCTAssertEqual(tab.webView.backForwardList.backItem?.url, direct)

        for address in [
            "file:///tmp/fixture", "mailto:fixture@example.test", "tel:5551234", "fixture+app://open",
            "javascript:alert('fixture text')", "http://user:password@127.0.0.1:\(port)/fixture", " "
        ] {
            tab.address = address
            tab.openAddress()
            XCTAssertTrue(tab.message?.hasPrefix("Could not open this address") == true, address)
            XCTAssertEqual(tab.pageURL, search, address)
            XCTAssertFalse(tab.isLoading, address)
        }

        let otherEngine = BrowserSearchSettings(engine: .bing, customURL: "https://%s.example/")
        XCTAssertTrue(otherEngine.save(to: defaults))
        XCTAssertEqual(BrowserSearchSettings.load(from: defaults),
                       BrowserSearchSettings(engine: .bing, customURL: "\(origin)search/%s?q=%s&lang=en"))

        XCTAssertTrue(original.save(to: defaults))
        XCTAssertEqual(BrowserSearchSettings.load(from: defaults), original)
    }

    @MainActor
    func testTabSelectionAndClosingFollowTheThread() throws {
        var preview = ThreadBrowserPreview()
        preview.togglePanel()
        let first = try XCTUnwrap(preview.selectedTab)
        XCTAssertEqual(first.profile, .standard)
        preview.addTab(profile: .alternate)
        let second = try XCTUnwrap(preview.selectedTab)
        XCTAssertEqual(second.profile, .alternate)
        preview.addTab(profile: .standard)
        let third = try XCTUnwrap(preview.selectedTab)

        preview.selectTab(second.id)
        preview.closeTab(second.id)
        XCTAssertEqual(preview.selectedTab?.id, third.id)
        preview.closeTab(third.id)
        XCTAssertEqual(preview.selectedTab?.id, first.id)

        preview.undockSelectedTab()
        XCTAssertFalse(preview.isVisible)
        XCTAssertEqual(preview.floatingTab?.id, first.id)
        preview.dismissFloatingWindow(for: first.id)
        XCTAssertNil(preview.floatingTab)
        XCTAssertFalse(preview.isVisible)
        preview.togglePanel()
        XCTAssertEqual(preview.selectedTab?.id, first.id)
        preview.closeTab(first.id)
        XCTAssertNil(preview.selectedTab)
        XCTAssertFalse(preview.isVisible)
    }

    @MainActor
    func testFindInPageUsesTheFocusedWebViewAndRejectsResultsFromAReplacedPage() async throws {
        try requireTestDesktop()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()
        try XCTSkipIf(NSScreen.screens.isEmpty, "Native key events need a WindowServer display.")
        let fixture = try LoopbackBrowserPage { path in
            switch path {
            case "/first": "<title>First</title><p id='a'>Lantern</p><p id='b'>lantern</p><p id='c'>lantern</p>"
            case "/other": "<title>Other tab</title><p id='other'>Poppy</p>"
            default: "<title>Replacement</title><p id='replacement'>Daisy</p>"
            }
        }
        defer { fixture.listener.cancel() }
        let origin = try await start(fixture)
        let tabs = BrowserFindFixture()
        let first = try XCTUnwrap(tabs.preview.selectedTab)
        let second = try XCTUnwrap(tabs.preview.tabs.last)
        let offscreen = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 1500, y: 0)
        let window = OffscreenBrowserFindPanel(
            contentRect: NSRect(origin: offscreen, size: NSSize(width: 640, height: 480)),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: BrowserFindFixtureView(fixture: tabs))
        window.contentView = host
        window.setFrameOrigin(offscreen)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)

        func element(_ id: String) -> AnyObject? {
            var visited = Set<ObjectIdentifier>()
            func find(_ node: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == id { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let match = find(child as AnyObject) { return match }
                }
                return nil
            }
            host.layoutSubtreeIfNeeded()
            return find(host) ?? find(window)
        }
        func press(_ id: String) throws {
            XCTAssertTrue(try XCTUnwrap(element(id), id).accessibilityPerformPress?() == true, id)
        }
        func key(_ code: Int, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
            ))
            app.sendEvent(event)
        }
        func findEditor(in tab: BrowserPreviewSession) async throws -> NSTextView {
            try await waitFor("the browser Find field to take keyboard focus") {
                element("browser-find-query") != nil && (window.firstResponder as? NSTextView)?.isFieldEditor == true
                    && !tab.hasPageFocus(in: window)
            }
            return try XCTUnwrap(window.firstResponder as? NSTextView)
        }
        func type(_ query: String, in tab: BrowserPreviewSession) async throws {
            let editor = try await findEditor(in: tab)
            editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }
        func selectedElement(in tab: BrowserPreviewSession) async throws -> String? {
            try await tab.webView.evaluateJavaScript("getSelection().anchorNode?.parentElement?.id ?? ''") as? String
        }
        func expectMatch(_ id: String, in tab: BrowserPreviewSession) async throws {
            try await waitFor("match status for \(id)") { tab.find?.status == .match }
            XCTAssertNotNil(element("browser-find-status"))
            let selected = try await selectedElement(in: tab)
            XCTAssertEqual(selected, id)
        }

        try await waitFor("the Browser toolbar") { element("browser-find") != nil }
        try press("browser-find")
        try await waitFor("unavailable-page feedback") { first.find?.status == .unavailable && element("browser-find-status") != nil }
        try press("browser-find-close")
        first.address = origin.appending(path: "first").absoluteString
        try await waitFor("the Go button to enable") { element("browser-go")?.isAccessibilityEnabled?() == true }
        try press("browser-go")
        try await waitFor("the first page") { first.webView.title == "First" && !first.isLoading && first.webView.window === window }
        XCTAssertTrue(window.makeFirstResponder(first.webView))
        try key(kVK_ANSI_F, "f", .command)
        try await type("lantern", in: first)
        try await expectMatch("a", in: first)
        try press("browser-find-next")
        try await expectMatch("b", in: first)
        _ = try await findEditor(in: first)
        try key(kVK_Return, "\r")
        try await expectMatch("c", in: first)
        try key(kVK_Return, "\r", .shift)
        try await expectMatch("b", in: first)
        try press("browser-find-previous")
        try await expectMatch("a", in: first)
        try key(kVK_Return, "\r", .shift)
        try await expectMatch("c", in: first)
        try key(kVK_Return, "\r")
        try await expectMatch("a", in: first)
        XCTAssertTrue(window.makeFirstResponder(first.webView))
        try key(kVK_ANSI_F, "f", .command)
        let refocused = try await findEditor(in: first)
        XCTAssertEqual(refocused.selectedRange(), NSRange(location: 0, length: 7))
        try key(kVK_ANSI_F, "f", .command)
        let editor = try await findEditor(in: first)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 7))
        try key(kVK_Escape, "\u{1b}")
        try await waitFor("Escape to restore page focus") { first.find == nil && first.hasPageFocus(in: window) }
        let cleared = try await selectedElement(in: first)
        XCTAssertEqual(cleared, "")

        try press("browser-find")
        try await type("lantern", in: first)
        XCTAssertEqual(first.find?.status, .searching)
        first.address = origin.appending(path: "replacement").absoluteString
        first.openAddress()
        XCTAssertEqual(first.find?.status, .loading)
        try await waitFor("the replacement page to report no matches") {
            first.webView.title == "Replacement" && first.find?.status == .noMatches
        }
        try await type("daisy", in: first)
        try await expectMatch("replacement", in: first)

        try press("browser-tab-\(second.id)")
        try await waitFor("the second tab to take over the browser") {
            second.webView.window === window && first.webView.window == nil && element("browser-find-query") == nil
        }
        second.address = origin.appending(path: "other").absoluteString
        second.openAddress()
        try await waitFor("the second tab’s different document") { second.webView.title == "Other tab" && !second.isLoading }
        try press("browser-find")
        let secondEditor = try await findEditor(in: second)
        XCTAssertEqual(secondEditor.string, "")
        try await type("daisy", in: second)
        try await waitFor("the second document to reject the first tab’s query") { second.find?.status == .noMatches }
        try await type("poppy", in: second)
        try await expectMatch("other", in: second)
        XCTAssertTrue(first.webView !== second.webView)
        XCTAssertTrue(first.webView.configuration.websiteDataStore !== second.webView.configuration.websiteDataStore)
        XCTAssertNil(first.find)
    }

    @MainActor
    func testMovingTheLiveWebViewPreservesPageHistoryZoomAndAddress() async throws {
        try requireTestDesktop()
        _ = NSApplication.shared
        let fixture = try LoopbackBrowserPage { path in
            "<title>\(path)</title><input><p id='first'>Movable</p><p id='second'>Movable</p>"
        }
        defer { fixture.listener.cancel() }
        let origin = try await start(fixture)
        let one = origin.appending(path: "one")
        let two = origin.appending(path: "two")
        var preview = ThreadBrowserPreview()
        preview.togglePanel()
        let tab = try XCTUnwrap(preview.selectedTab)
        let workspace = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                 styleMask: [.titled], backing: .buffered, defer: true)
        workspace.isReleasedWhenClosed = false
        defer { workspace.close() }
        workspace.contentView = NSHostingView(rootView: BrowserPreviewView(preview: .constant(preview)))

        tab.address = one.absoluteString
        XCTAssertNil(tab.pageURL)
        tab.openAddress()
        try await waitFor("first page to load at \(one). \(tab.message ?? "No browser error")") {
            tab.webView.title == "/one" && !tab.isLoading
        }
        tab.address = "file:///etc/hosts"
        tab.openAddress()
        XCTAssertNotNil(tab.message)
        XCTAssertEqual(tab.pageURL, one)
        tab.address = two.absoluteString
        tab.openAddress()
        try await waitFor("second page to load") { tab.webView.title == "/two" && tab.canGoBack && !tab.isLoading }
        try await waitFor("docked WebKit view") { tab.webView.window === workspace }
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('input').value = 'live page'")
        tab.zoomIn()
        tab.address = "unfinished address"
        tab.openFind()
        tab.editFindQuery("movable")
        try await waitFor("a match in the docked view") { tab.find?.status == .match }

        preview.openMiniPlayer()
        let mini = try XCTUnwrap(preview.miniPlayer)
        XCTAssertEqual(tab.id, mini.tab.id)
        XCTAssertFalse(preview.isVisible)
        workspace.contentView = NSHostingView(rootView:
            BrowserMiniPlayer(tab: mini.tab, placement: mini.placement, canvas: workspace.frame.size, obstacles: [],
                              place: { _ in }, dock: {}, popOut: {}, close: {}))
        try await waitFor("mini player WebKit view") { tab.webView.window === workspace && tab.webView.bounds.width <= 320 }
        let miniText = try await tab.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(miniText, "live page")
        preview.closeMiniPlayer(for: UUID())
        XCTAssertEqual(preview.miniPlayer?.tab.id, tab.id)
        preview.dockTab(tab.id)
        XCTAssertNil(preview.miniPlayer)
        XCTAssertTrue(preview.isVisible)

        preview.undockSelectedTab()
        let floatingTab = try XCTUnwrap(preview.floatingTab)
        let panel = BrowserFloatingPanel(session: floatingTab, dock: {}, dismiss: {})
        defer { panel.close() }
        try await waitFor("floating WebKit view") { tab.webView.window === panel }
        workspace.contentView = nil
        XCTAssertTrue(tab.webView.window === panel)
        let floatingText = try await tab.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(floatingText, "live page")
        XCTAssertEqual(tab.webView.pageZoom, 1.1, accuracy: 0.001)
        XCTAssertEqual(tab.address, "unfinished address")

        preview.dockTab(tab.id)
        XCTAssertTrue(preview.isVisible)
        workspace.contentView = NSHostingView(rootView: BrowserPreviewView(preview: .constant(preview)))
        try await waitFor("redocked WebKit view") { tab.webView.window === workspace }
        panel.contentView = nil
        XCTAssertTrue(tab.webView.window === workspace)
        let dockedText = try await tab.webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(dockedText, "live page")
        XCTAssertEqual(tab.find?.query, "movable")
        tab.stepFind(backward: false)
        try await waitFor("Find still steps in the retained view after redocking") { tab.find?.status == .match }
        let selected = try await tab.webView.evaluateJavaScript("getSelection().anchorNode?.parentElement?.id") as? String
        XCTAssertEqual(selected, "second")
        XCTAssertEqual(tab.zoom, 110)
        XCTAssertEqual(tab.address, "unfinished address")
        tab.goBack()
        try await waitFor("back navigation") { tab.pageURL == one && tab.canGoForward && !tab.isLoading }
        tab.goForward()
        try await waitFor("forward navigation") { tab.pageURL == two && !tab.isLoading }
    }

    @MainActor
    func testWebsiteDataIsSharedOnlyWithinAThreadAndProfile() async throws {
        _ = NSApplication.shared
        let fixture = try LoopbackBrowserPage()
        defer { fixture.listener.cancel() }
        let url = try await start(fixture)
        var preview = ThreadBrowserPreview()
        var otherThread = ThreadBrowserPreview()
        preview.addTab(profile: .standard)
        let first = try XCTUnwrap(preview.selectedTab)
        try await load(first, url: url)
        _ = try await first.webView.evaluateJavaScript("localStorage.setItem('fixture', 'standard')")
        preview.addTab(profile: .alternate)
        let alternate = try XCTUnwrap(preview.selectedTab)
        try await load(alternate, url: url)
        let alternateValue = try await storedValue(in: alternate)
        XCTAssertEqual(alternateValue, "")
        _ = try await alternate.webView.evaluateJavaScript("localStorage.setItem('fixture', 'alternate')")
        preview.addTab(profile: .standard)
        let sameProfile = try XCTUnwrap(preview.selectedTab)
        try await load(sameProfile, url: url)
        let sharedValue = try await storedValue(in: sameProfile)
        XCTAssertEqual(sharedValue, "standard")
        XCTAssertFalse(sameProfile.canGoBack)
        otherThread.addTab(profile: .standard)
        let other = try XCTUnwrap(otherThread.selectedTab)
        try await load(other, url: url)
        let otherValue = try await storedValue(in: other)
        XCTAssertEqual(otherValue, "")
        let firstValue = try await storedValue(in: first)
        XCTAssertEqual(firstValue, "standard")
    }

    @MainActor
    private func start(_ fixture: LoopbackBrowserPage) async throws -> URL {
        try await waitFor("loopback fixture listener") { (fixture.listener.port?.rawValue ?? 0) > 0 }
        let port = try XCTUnwrap(fixture.listener.port)
        return try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)/"))
    }

    @MainActor
    private func load(_ tab: BrowserPreviewSession, url: URL) async throws {
        tab.address = url.absoluteString
        tab.openAddress()
        try await waitFor("profile fixture page at \(url). \(tab.message ?? "No browser error")") {
            tab.webView.title == "/" && !tab.isLoading
        }
    }

    @MainActor
    private func storedValue(in tab: BrowserPreviewSession) async throws -> String? {
        try await tab.webView.evaluateJavaScript("localStorage.getItem('fixture') ?? ''") as? String
    }

    @MainActor
    private func waitFor(_ description: @autoclosure () -> String, condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(8)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(description())")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class LoopbackBrowserPage {
    let listener: NWListener

    init(page: @escaping (String) -> String = { _ in
        "<!doctype html><title>Fixture</title><input><script>document.title = location.pathname</script>"
    }) throws {
        let queue = DispatchQueue(label: "BrowserPreviewTests.loopback")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                guard error == nil, let data else {
                    connection.cancel()
                    return
                }
                let path = String(decoding: data, as: UTF8.self).split(separator: " ").dropFirst().first ?? "/"
                let html = page(String(path))
                let response = Data((
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
                ).utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }
}

@MainActor
private final class BrowserFindFixture: ObservableObject {
    @Published var preview = ThreadBrowserPreview()

    init() {
        preview.togglePanel()
        let first = preview.selectedTabID
        preview.addTab(profile: .alternate)
        if let first { preview.selectTab(first) }
    }
}

private struct BrowserFindFixtureView: View {
    @ObservedObject var fixture: BrowserFindFixture
    var body: some View { BrowserPreviewView(preview: $fixture.preview) }
}

private final class OffscreenBrowserFindPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
