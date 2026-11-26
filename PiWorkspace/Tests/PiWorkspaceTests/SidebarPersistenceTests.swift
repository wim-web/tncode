import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class SidebarPersistenceTests: XCTestCase {
    func testCollapsedFolderSurvivesWindowRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let alphaThread = Conversation(id: UUID(), title: "Work on Alpha")
        let betaThread = Conversation(id: UUID(), title: "Work on Beta", composerText: "Unsent")
        let alpha = Project(id: UUID(), path: root.appendingPathComponent("alpha").path, title: "Alpha",
                            conversations: [alphaThread])
        let beta = Project(id: UUID(), path: root.appendingPathComponent("beta").path, title: "Beta",
                           conversations: [betaThread], selectedConversation: betaThread.id)
        try WorkspaceStore(root: root).save(Workspace(projects: [alpha, beta], selectedProject: beta.id))

        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()
        let suite = "SidebarPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SidebarPreference.groupByProject)

        func checkWindow(model: WorkspaceModel, collapse: Bool) async throws {
            let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
            let window = SidebarOffscreenPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1080, height: 720)),
                                               styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable)
                .defaultAppStorage(defaults))
            window.contentView = host
            window.setFrameOrigin(origin)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
            window.orderBack(nil)
            defer {
                window.contentView = nil
                window.close()
            }

            func element(_ identifier: String) -> AnyObject? {
                host.layoutSubtreeIfNeeded()
                var visited = Set<ObjectIdentifier>()
                func find(_ node: AnyObject) -> AnyObject? {
                    guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                    if node.accessibilityIdentifier?() == identifier { return node }
                    for child in node.accessibilityChildren?() ?? [] {
                        if let match = find(child as AnyObject) { return match }
                    }
                    return nil
                }
                return find(host)
            }
            let header = "project-group-\(alpha.id)"
            let row = "thread-row-\(alphaThread.id)"
            for _ in 0..<50 where element(header) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(element(header))
            if collapse {
                XCTAssertNotNil(element(row))
                XCTAssertTrue(element(header)?.accessibilityPerformPress?() == true)
            }
            for _ in 0..<50 where element(row) != nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(element(row), "Alpha must stay collapsed when the sidebar is rebuilt.")
            XCTAssertNotNil(element("thread-row-\(betaThread.id)"))
            XCTAssertEqual(model.conversation?.id, betaThread.id)
            XCTAssertEqual(model.draft, "Unsent")
        }
        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString)
        try await checkWindow(model: model, collapse: true)
        try await checkWindow(model: model, collapse: false)
    }
}

private final class SidebarOffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
