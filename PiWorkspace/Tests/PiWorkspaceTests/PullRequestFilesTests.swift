import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class PullRequestFilesTests: XCTestCase {
    func testCodeFilesAndSelectedPatchStayWithTheSelectedPullRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-pr-files-\(UUID())")
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
            git.environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/fixtures/github-read")
        let state = root.appendingPathComponent("state")
        let gate = root.appendingPathComponent("gate")
        func mode(_ value: String) throws { try Data(value.utf8).write(to: state, options: .atomic) }
        try mode("files-denied")
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
        let window = OffscreenPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 480, height: 480)),
                                    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Details(reader: reader, repository: repository, selection: selection))
        host.sizingOptions = []
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
        func waitFor(_ id: String, containing expected: String? = nil) async throws -> AnyObject {
            for _ in 0..<150 {
                if let node = element(id) {
                    guard let expected else { return node }
                    let value = (node as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
                    if ((value as? String) ?? node.accessibilityLabel?())?.contains(expected) == true { return node }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw WorkspaceError("Missing AX element \(id) with text \(expected ?? "(any)")")
        }
        func press(_ id: String) async throws {
            let button = try await waitFor(id)
            XCTAssertEqual(button.accessibilityPerformPress?(), true, id)
        }

        try await press("pr-tab-code")
        _ = try await waitFor("pr-files-error", containing: "denied access")
        try mode("files-many")
        try await press("pr-files-retry")
        try await press("pr-file-row-0")
        _ = try await waitFor("pr-file-diff-text", containing: "+FORGE-CHECKOUT")
        try await press("pr-file-row-1")
        _ = try await waitFor("pr-file-diff-previous-path", containing: "docs/old guide.md")
        _ = try await waitFor("pr-file-diff-text", containing: "+FORGE-GUIDE")
        try await press("pr-file-row-2")
        _ = try await waitFor("pr-file-diff-unavailable")
        XCTAssertNil(element("pr-file-diff-text"))
        try await press("pr-file-row-3")
        _ = try await waitFor("pr-file-diff-text", containing: "+FORGE-ADD")
        try await press("pr-file-row-4")
        _ = try await waitFor("pr-file-diff-text", containing: "-FORGE-DELETE")
        try await press("pr-file-row-5")
        _ = try await waitFor("pr-file-diff-too-large")
        try await press("pr-file-row-6")
        _ = try await waitFor("pr-file-diff-partial")

        try mode("files-selection-error")
        try await press("pr-file-row-0")
        _ = try await waitFor("pr-file-diff-error", containing: "Couldn’t reach GitHub")
        try mode("files-many")
        try await press("pr-file-diff-retry")
        _ = try await waitFor("pr-file-diff-text", containing: "+FORGE-CHECKOUT")

        try mode("files-page-error")
        try await press("pr-files-load-more")
        _ = try await waitFor("pr-files-error", containing: "Couldn’t reach GitHub")
        _ = try await waitFor("pr-file-diff-text", containing: "+FORGE-CHECKOUT")
        try mode("files-many")
        try await press("pr-files-retry")
        _ = try await waitFor("pr-files-count", containing: "31 of 31")

        try mode("files-stale")
        try await press("pr-file-row-1")
        _ = try await waitFor("pr-files-stale", containing: "pull request changed")
        XCTAssertNil(element("pr-file-diff-text"))
        XCTAssertNil(element("pr-file-row-0"))
        try await press("pr-files-refresh")
        _ = try await waitFor("pr-files-count", containing: "7 of 7")

        try await press("pr-tab-summary")
        _ = try await waitFor("pr-detail-title", containing: "#42")
        try mode("initial")
        selection.number = 43
        _ = try await waitFor("pr-detail-title", containing: "#43")
        try await press("pr-tab-code")
        _ = try await waitFor("pr-files-empty")
        XCTAssertNil(element("pr-file-diff-text"))

        selection.number = 42
        _ = try await waitFor("pr-detail-title", containing: "#42")
        try mode("files-held")
        try await press("pr-tab-code")
        _ = try await waitFor("pr-files-loading")
        let started = gate.appendingPathExtension("started")
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        selection.number = 43
        _ = try await waitFor("pr-detail-title", containing: "#43")
        try Data().write(to: gate.appendingPathExtension("release"))
        try await press("pr-tab-code")
        _ = try await waitFor("pr-files-empty")
        XCTAssertNil(element("pr-file-row-0"))
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
