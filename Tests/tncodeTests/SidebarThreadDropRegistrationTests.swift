import AppKit
import SwiftUI
import XCTest
@testable import tncode

@MainActor
final class SidebarThreadDropRegistrationTests: XCTestCase {
    func testNativeRowsRegisterThreadDropsAlongsideFileDrops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sidebar registration \(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let thread = Conversation(id: UUID(), title: "A thread")
        let project = Project(id: UUID(), path: root.path, title: "Project", conversations: [thread],
                              selectedConversation: thread.id)
        try WorkspaceStore(root: root).save(Workspace(projects: [project], selectedProject: project.id, welcomeCompleted: true))
        let host = try SidebarDragTestWindow(model: SidebarDragTestWindow.open(root))
        defer { host.close() }
        try await host.waitForRow(thread.id)
        let internalType = NSPasteboard.PasteboardType("dev.tncode.sidebar-thread")
        XCTAssertTrue(host.destinations.contains { view in
            view.registeredDraggedTypes.contains(internalType) && view.registeredDraggedTypes.contains(.fileURL)
        }, "A rendered thread row must route both an internal thread drag and a genuine file drop.")
    }
}

@MainActor
final class SidebarDragTestWindow {
    let model: WorkspaceModel
    let window: NSPanel
    let host: NSHostingView<AnyView>
    private let policy: NSApplication.ActivationPolicy
    private let defaultsName = "dev.tncode.sidebar-drag-tests.\(UUID())"
    private let defaults: UserDefaults

    static func open(_ root: URL) -> WorkspaceModel {
        WorkspaceModel(root: root, keychainService: UUID().uuidString, readCredential: { _ in nil }) { _, _ in
            throw WorkspaceError("No Pi process in this fixture.")
        }
    }

    init(model: WorkspaceModel, grouped: Bool = false) throws {
        self.model = model
        let app = NSApplication.shared
        policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.set(grouped, forKey: SidebarPreference.groupByProject)
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2300, y: 0)
        window = OffscreenSidebarPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1150, height: 920)),
                                       styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(WorkspaceView(model: model, chatWidthMode: .comfortable)
            .defaultAppStorage(defaults)))
        window.contentView = host
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
    }

    func close() {
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        window.close()
        model.terminate()
        defaults.removePersistentDomain(forName: defaultsName)
        NSApplication.shared.setActivationPolicy(policy)
    }

    var destinations: [AttachmentDropDestination.Destination] {
        func collect(_ view: NSView) -> [AttachmentDropDestination.Destination] {
            let current = (view as? AttachmentDropDestination.Destination).map { [$0] } ?? []
            return current + view.subviews.flatMap(collect)
        }
        return collect(host)
    }

    func element(_ id: String) -> AnyObject? {
        var visited: [ObjectIdentifier: AnyObject] = [:]
        func find(_ node: AnyObject) -> AnyObject? {
            guard visited.updateValue(node, forKey: ObjectIdentifier(node)) == nil else { return nil }
            if node.accessibilityIdentifier?() == id { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let found = find(child as AnyObject) { return found }
            }
            return nil
        }
        return find(host)
    }

    func waitForRow(_ id: UUID) async throws {
        try await waitForElement("thread-row-\(id)")
    }

    func waitForElement(_ id: String) async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
            if element(id) != nil { return }
        }
        XCTFail("The control \(id) did not render.")
        throw WorkspaceError("The control \(id) did not render.")
    }
}

private final class OffscreenSidebarPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
