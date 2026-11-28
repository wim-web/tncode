import AppKit
import SwiftUI
import XCTest
@testable import tncode

/// The window is created offscreen and never shown.
@MainActor
final class WindowChromeTests: XCTestCase {
    func testRestoresHiddenTitleBarAfterSomethingResetsIt() throws {
        let host = NSHostingView(rootView: Color.clear.background(WindowChrome().frame(width: 0, height: 0)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        settle()
        assertHiddenTitleBar(window)

        // On macOS 26 an opaque title bar covers the 52pt header strip with a blurred band.
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        settle()
        assertHiddenTitleBar(window)

        window.styleMask.remove(.fullSizeContentView)
        settle()
        assertHiddenTitleBar(window)
    }

    private func settle() {
        for _ in 0..<3 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
    }

    private func assertHiddenTitleBar(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.titlebarAppearsTransparent, file: file, line: line)
        XCTAssertEqual(window.titleVisibility, .hidden, file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), file: file, line: line)
    }
}
