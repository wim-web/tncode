import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class DraftProjectPickerTests: XCTestCase {
    func testSearchRecoversFromNoMatchesAndDispatchesKeyboardAndAXSelections() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()
        let alpha = Project(id: UUID(), path: "/fixture/alpha", title: "Alpha")
        let beta = Project(id: UUID(), path: "/fixture/beta", title: "Béta")
        var selections: [DraftProjectPicker.Destination?] = []
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
        let window = DraftPickerOffscreenPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 340, height: 280)),
                                               styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: DraftProjectPicker(projects: [alpha, beta], currentProject: alpha.id,
                                                           isScratch: false) { selections.append($0) })
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }

        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Search projects" { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }
        func element(_ identifier: String) -> AnyObject? {
            var visited = Set<ObjectIdentifier>()
            func search(_ node: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == identifier { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let match = search(child as AnyObject) { return match }
                }
                return nil
            }
            return search(host) ?? search(window)
        }
        func waitFor(_ description: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<80 {
                host.layoutSubtreeIfNeeded()
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Timed out waiting for \(description).")
            throw WorkspaceError("Timed out waiting for \(description).")
        }
        func key(_ code: Int, _ characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
            ))
            app.sendEvent(event)
        }

        try await waitFor("the focused search field") {
            guard let editor = textField(in: host)?.currentEditor() else { return false }
            return editor === window.firstResponder
        }
        XCTAssertNotNil(element("draft-project-search"))
        XCTAssertNotNil(element("draft-project-\(alpha.id)"))
        XCTAssertNotNil(element("draft-project-\(beta.id)"))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        func setQuery(_ query: String) {
            editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }
        setQuery("does not exist")
        try await waitFor("the no-results label") { element("draft-project-no-results") != nil }
        XCTAssertNil(element("draft-add-project"))
        try key(kVK_Return, "\r")
        XCTAssertTrue(selections.isEmpty)

        setQuery("BETA")
        try await waitFor("the recovered destination") { element("draft-project-\(beta.id)") != nil }
        XCTAssertNil(element("draft-project-\(alpha.id)"))
        XCTAssertNil(element("draft-project-no-results"))
        try key(kVK_Return, "\r")
        XCTAssertEqual(selections, [.project(beta.id)])

        setQuery("")
        try await waitFor("the project actions") {
            element("draft-add-project") != nil && element("draft-no-project") != nil
        }
        XCTAssertTrue(element("draft-no-project")?.accessibilityPerformPress?() == true)
        XCTAssertTrue(element("draft-add-project")?.accessibilityPerformPress?() == true)
        try key(kVK_Escape, "\u{1b}")
        XCTAssertEqual(selections, [.project(beta.id), .noProject, .addProject, nil])
    }
}

private final class DraftPickerOffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
