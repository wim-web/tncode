import AppKit
import SwiftUI
import XCTest
@testable import tncode

@MainActor
final class PullRequestCheckLogTests: XCTestCase {
    func testSelectedJobLogIsAccessibleAndDisappearsWhenThePRChanges() async throws {
        try requireTestDesktop()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-check-log-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [
            ["init", "-q", "-b", "main"],
            ["remote", "add", "origin", "https://github.com/fixture/workspace.git"],
        ] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.currentDirectoryURL = root
            git.arguments = args
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/fixtures/github-read")
        let state = root.appendingPathComponent("state")
        let gate = root.appendingPathComponent("gate")
        func mode(_ value: String) throws { try Data(value.utf8).write(to: state, options: .atomic) }
        try mode("check-logs-denied")
        let reader = GitHubReader(directory: root.path, environment: [
            "PATH": fixture.path + ":/usr/bin:/bin",
            "PI_GH_FIXTURE_STATE": state.path,
            "PI_GH_FIXTURE_GATE": gate.path,
        ])
        let repository = try await reader.repository()
        let selection = Selection()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()
        let origin = CGPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2200, y: 0)
        let window = OffscreenPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 520, height: 620)),
                                    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Details(reader: reader, repository: repository, selection: selection))
        window.contentView = host
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }

        func element(_ id: String) -> AnyObject? {
            host.layoutSubtreeIfNeeded()
            var visited = Set<ObjectIdentifier>()
            func find(_ node: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == id { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let match = find(child as AnyObject) { return match }
                }
                return nil
            }
            return find(host)
        }
        func waitFor(_ id: String, matching predicate: (AnyObject) -> Bool = { _ in true }) async throws -> AnyObject {
            for _ in 0..<150 {
                if let node = element(id), predicate(node) { return node }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw WorkspaceError("Missing AX element \(id)")
        }
        func press(_ id: String) async throws {
            let button = try await waitFor(id)
            XCTAssertEqual(button.accessibilityPerformPress?(), true, id)
        }
        func text(_ node: AnyObject) -> String? {
            let value = (node as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
            return (value as? String) ?? node.accessibilityLabel?()
        }

        try await press("pr-check-log-1")
        _ = try await waitFor("pr-check-log-error") { text($0)?.contains("denied access") == true }
        _ = try await waitFor("pr-check-log-open")
        try mode("check-logs")
        try await press("pr-check-log-retry")
        let log = try await waitFor("pr-check-log-text")
        XCTAssertEqual(text(log), "Tests / build\nONLY-TESTS-61002")
        try await press("pr-check-log-back")

        try mode("check-logs-held")
        try await press("pr-check-log-0")
        _ = try await waitFor("pr-check-log-loading")
        let started = gate.appendingPathExtension("started")
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        selection.number = 43
        _ = try await waitFor("pr-checks-empty")
        try Data().write(to: gate.appendingPathExtension("release"))
        XCTAssertNil(element("pr-check-log-text"))
        XCTAssertNil(element("pr-check-log-loading"))
    }

    private final class Selection: ObservableObject {
        @Published var number = 42
    }

    private struct Details: View {
        let reader: GitHubReader
        let repository: GitHubRepository
        @ObservedObject var selection: Selection

        var body: some View {
            PullRequestDetailsView(reader: reader, repository: repository, number: selection.number)
                .id(selection.number)
        }
    }

    private final class OffscreenPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}
