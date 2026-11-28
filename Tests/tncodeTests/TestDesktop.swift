import XCTest

/// Skips a test that creates AppKit windows unless it runs in a separate test desktop.
///
/// Placing a window outside every display does not keep it off the user's desktop.
/// Key focus, sheets, menus, popovers, and child windows still reach the screen and keyboard.
/// Call this before `finishLaunching()` and before creating any `NSWindow` or `NSPanel`.
func requireTestDesktop() throws {
    guard ProcessInfo.processInfo.environment["TNCODE_TEST_DESKTOP"] == "dedicated" else {
        throw XCTSkip(testDesktopSkipMessage)
    }
}

let testDesktopSkipMessage = "This test creates AppKit windows. Run it in a separate test desktop with TNCODE_TEST_DESKTOP=dedicated."
