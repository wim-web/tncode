import AppKit
import Network
import SwiftUI
import WebKit
import XCTest
@testable import PiWorkspace

final class BrowserPreviewTests: XCTestCase {
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
    func testMovingTheLiveWebViewPreservesPageHistoryZoomAndAddress() async throws {
        _ = NSApplication.shared
        let fixture = try LoopbackBrowserPage()
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

    init() throws {
        let queue = DispatchQueue(label: "BrowserPreviewTests.loopback")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let html = "<!doctype html><title>Fixture</title><input><script>document.title = location.pathname</script>"
        let response = Data((
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
        ).utf8)

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, error in
                guard error == nil else {
                    connection.cancel()
                    return
                }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }
}
