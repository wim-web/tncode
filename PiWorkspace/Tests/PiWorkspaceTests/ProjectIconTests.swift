import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import PiWorkspace

@MainActor
final class ProjectIconTests: XCTestCase {
    func testScopedOverviewSavesCancelsAndResetsAcrossStoreRelaunch() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["PI_WORKSPACE_ICON_TEST_ROOT"],
           let phase = environment["PI_WORKSPACE_ICON_TEST_PHASE"].flatMap(Phase.init(rawValue:)) {
            try await exerciseOverview(root: URL(fileURLWithPath: root, isDirectory: true), phase: phase)
            return
        }
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().appending(path: "ProjectIconTests-\(UUID())")
        let workspaceRoot = root.appending(path: "workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = try ["First", "Second"].map { name in
            let path = root.appending(path: name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let draft = Conversation(id: UUID(), title: "Draft", isDraft: true, composerText: "Keep the \(name) draft")
            return Project(id: UUID(), path: path.path, title: "Same name", conversations: [draft],
                           selectedConversation: draft.id, modelOverride: ModelSettings(provider: .local, model: name))
        }
        let first = projects[0]
        var second = projects[1]
        try FileManager.default.createDirectory(at: root.appending(path: "Linked checkout"), withIntermediateDirectories: true)
        second.conversations[0].location = .worktree(path: root.appending(path: "Linked checkout").path, base: "main")
        let original = Workspace(projects: [first, second], selectedProject: second.id,
                                 model: ModelSettings(provider: .local, model: "Workspace"), welcomeCompleted: true,
                                 worktreesDirectory: root.path, newWorktreesStartFromRemote: false)
        try WorkspaceStore(root: workspaceRoot).save(original)
        let imageURL = URL(fileURLWithPath: second.path).appending(path: "Generated.png")
        try writeImage(to: imageURL)
        let imported = try ProjectIcon.importing(imageURL)

        try runHost(workspaceRoot, phase: .save)
        try FileManager.default.removeItem(at: imageURL)
        try runHost(workspaceRoot, phase: .reset)
        let reopened = try WorkspaceStore(root: workspaceRoot).load()
        var expected = original
        expected.projects[1].icon = imported
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(reopened), try encoder.encode(expected))
    }

    private enum Phase: String { case save, reset }

    private func runHost(_ workspace: URL, phase: Phase) throws {
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        test.arguments = ["xctest", "-XCTest",
                          "PiWorkspaceTests.ProjectIconTests/testScopedOverviewSavesCancelsAndResetsAcrossStoreRelaunch",
                          Bundle(for: Self.self).bundlePath]
        var environment = ProcessInfo.processInfo.environment
        environment["XCTestSessionIdentifier"] = nil
        environment["PI_WORKSPACE_ICON_TEST_ROOT"] = workspace.path
        environment["PI_WORKSPACE_ICON_TEST_PHASE"] = phase.rawValue
        test.environment = environment
        try test.run()
        test.waitUntilExit()
        XCTAssertEqual(test.terminationStatus, 0, phase.rawValue)
    }

    private func exerciseOverview(root: URL, phase: Phase) async throws {
        let host = try Host(root: root)
        defer { host.close() }
        let first = host.model.workspace.projects[0]
        let second = host.model.workspace.projects[1]
        if phase == .reset {
            let imported = try XCTUnwrap(second.icon)
            XCTAssertEqual(first.icon, .symbol(.globe, .blue))
            try await host.openOverview(for: second)
            try await host.waitFor("the saved image after relaunch") {
                host.element("project-settings-icon-preview")?.accessibilityLabel?() == imported.summary
            }
            try await host.press("settings-close")
            try await host.waitFor("the second Overview to close") { host.window.attachedSheet == nil }
            try await host.openOverview(for: first)
            try await host.press("project-settings-reset-icon")
            try await host.waitFor {
                host.element("project-settings-icon-preview")?.accessibilityLabel?() == "Default project icon"
            }
            XCTAssertEqual(host.model.workspace.projects.map(\.icon), [nil, imported])
            try await host.press("settings-close")
            try await host.waitFor("the reset Overview to close") { host.window.attachedSheet == nil }
            return
        }

        let index = root.appending(path: WorkspaceStore.indexName)
        let previous = root.appending(path: WorkspaceStore.previousIndexName)
        try await host.openOverview(for: first)
        try await host.press("project-settings-choose-icon")
        try await host.press("project-icon-symbol-globe")
        try await host.press("project-icon-color-blue")
        try await host.press("project-icon-save")
        try await host.waitFor("the symbol to save and the picker to close") {
            host.model.workspace.projects.first?.icon == .symbol(.globe, .blue) && host.iconSheet == nil
        }
        XCTAssertNil(host.model.workspace.projects[1].icon)
        XCTAssertEqual(host.model.project?.id, second.id)
        XCTAssertEqual(host.model.draft, second.conversations[0].composerText)

        let saved = try Data(contentsOf: index)
        try await host.press("project-settings-choose-icon")
        try await host.press("project-icon-symbol-terminal")
        try await host.press("project-icon-cancel")
        try await host.waitFor("the cancelled picker to close") { host.iconSheet == nil }
        XCTAssertEqual(try Data(contentsOf: index), saved)

        let originalPrevious = previous.appendingPathExtension("original")
        try FileManager.default.moveItem(at: previous, to: originalPrevious)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: false)
        try await host.press("project-settings-choose-icon")
        try await host.press("project-icon-symbol-terminal")
        try await host.press("project-icon-save")
        try await host.waitFor("the picker write error") { host.element("project-icon-save-error") != nil }
        XCTAssertEqual(host.model.workspace.projects.first?.icon, .symbol(.globe, .blue))
        XCTAssertEqual(try Data(contentsOf: index), saved)
        try await host.press("project-icon-cancel")
        try await host.waitFor("the failed picker to close") { host.iconSheet == nil }
        try await host.press("project-settings-reset-icon")
        try await host.waitFor("the reset write error") { host.element("project-settings-icon-error") != nil }
        XCTAssertEqual(try Data(contentsOf: index), saved)
        try FileManager.default.removeItem(at: previous)
        try FileManager.default.moveItem(at: originalPrevious, to: previous)
        try await host.press("settings-close")
        try await host.waitFor("the Overview to close") { host.window.attachedSheet == nil }
        try await host.openOverview(for: second)
        try await host.press("project-settings-choose-icon-file")
        try await host.waitFor("the native file panel") { host.iconSheet != nil }
        let settings = try XCTUnwrap(host.window.attachedSheet)
        let filePanel = try XCTUnwrap(settings.attachedSheet as? NSOpenPanel)
        filePanel.cancel(nil)
        try await host.waitFor("the file panel to close") { settings.attachedSheet == nil }
        XCTAssertEqual(try Data(contentsOf: index), saved)

        let imageURL = URL(fileURLWithPath: second.path).appending(path: "Generated.png")
        let imported = try ProjectIcon.importing(imageURL)
        try host.model.setProjectIcon(imported, for: second.id)
        try await host.waitFor {
            host.element("project-settings-icon-preview")?.accessibilityLabel?() == imported.summary
        }
        try await host.press("settings-close")
        try await host.waitFor("the Overview to close before relaunch") { host.window.attachedSheet == nil }
    }

    func testImportMakesBoundedSelfContainedBitmap() throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().appending(path: "ProjectIconImages-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for (ext, type) in [("png", UTType.png), ("jpg", .jpeg), ("gif", .gif)] {
            let url = root.appending(path: "Generated.\(ext)")
            try writeImage(to: url, type: type)
            guard case .image(let png) = try ProjectIcon.importing(url) else { return XCTFail("Expected an image") }
            let image = try XCTUnwrap(ProjectIcon.bitmap(from: png))
            XCTAssertEqual(image.width, 128, ext)
            XCTAssertEqual(image.height, 64, ext)
            XCTAssertLessThanOrEqual(png.count, 128 * 1024)
            let center = NSBitmapImageRep(cgImage: image).colorAt(x: 64, y: 32)
            let rgb = try XCTUnwrap(center?.usingColorSpace(.sRGB))
            XCTAssertEqual(rgb.greenComponent, 0.5, accuracy: 0.08, ext)
            XCTAssertEqual(rgb.alphaComponent, 1, accuracy: 0.01, ext)
        }
        let svg = root.appending(path: "Generated.svg")
        try Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="400" height="200">
          <rect width="400" height="200" fill="#108040"/>
        </svg>
        """.utf8).write(to: svg)
        guard case .image(let png) = try ProjectIcon.importing(svg) else { return XCTFail("Expected an image") }
        let image = try XCTUnwrap(ProjectIcon.bitmap(from: png))
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 64)
        let broken = root.appending(path: "Broken.png")
        try Data("invalid image".utf8).write(to: broken)
        XCTAssertThrowsError(try ProjectIcon.importing(broken))
        XCTAssertThrowsError(try ProjectIcon.importing(root.appending(path: "File.pdf")))
        XCTAssertEqual(ProjectIcon.firstEmoji(in: " 🇯🇵 suffix"), "🇯🇵")
        XCTAssertEqual(ProjectIcon.firstEmoji(in: " 4️⃣ "), "4️⃣")
        XCTAssertNil(ProjectIcon.firstEmoji(in: "plain 🌱"))
        XCTAssertEqual(ProjectIcon.monogramText(" ｇ9 "), "G9")
        XCTAssertNil(ProjectIcon.monogramText("three"))
        XCTAssertNil(ProjectIcon.monogramText("💻"))
    }

    private func writeImage(to url: URL, type: UTType = .png) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.125, green: 0.5, blue: 0.25, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private struct WorkspaceHost: View {
        @ObservedObject var model: WorkspaceModel
        let defaults: UserDefaults
        let pasteboard: NSPasteboard

        var body: some View {
            WorkspaceView(model: model, chatWidthMode: .comfortable, browserDefaults: defaults, workspacePasteboard: pasteboard)
                .sheet(item: $model.settingsRequest) { request in
                    SettingsView(model: model, appearance: AppearanceSettings(defaults: defaults), browserDefaults: defaults,
                                 request: request, pasteboard: pasteboard, openWelcome: {})
                }
                .defaultAppStorage(defaults)
        }
    }

    private final class OffscreenPanel: NSPanel {
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

        override func beginSheet(_ sheet: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
            sheet.alphaValue = 0
            super.beginSheet(sheet, completionHandler: completionHandler)
            sheet.setFrameOrigin(frame.origin)
        }
    }

    @MainActor
    private final class Host {
        let model: WorkspaceModel
        let window: NSPanel
        private let app = NSApplication.shared
        private let policy: NSApplication.ActivationPolicy
        private let namespace = "ProjectIconTests.\(UUID())"
        private let defaults: UserDefaults
        private let pasteboard = NSPasteboard.withUniqueName()

        init(root: URL) throws {
            model = WorkspaceModel(root: root, keychainService: namespace, readCredential: { _ in nil }) { _, _ in
                throw WorkspaceError("The project icon fixture has no Pi worker.")
            }
            if let failure = model.startupFailure {
                XCTFail("Could not open the real workspace store: \(failure.localizedDescription)")
                throw failure
            }
            defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
            defaults.set(true, forKey: SidebarPreference.groupByProject)
            policy = app.activationPolicy()
            app.setActivationPolicy(.prohibited)
            XCTAssertEqual(app.activationPolicy(), .prohibited)
            app.finishLaunching()
            let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
            window = OffscreenPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 1050, height: 720)),
                                    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WorkspaceHost(model: model, defaults: defaults, pasteboard: pasteboard))
            window.setFrameOrigin(origin)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
            window.orderBack(nil)
        }

        func close() {
            window.contentView = nil
            window.close()
            XCTAssertTrue(model.terminate())
            defaults.removePersistentDomain(forName: namespace)
            pasteboard.releaseGlobally()
            app.setActivationPolicy(policy)
        }

        func openOverview(for project: Project) async throws {
            try await press("project-group-settings-\(project.id)")
            let path = try await find("project-settings-path")
            XCTAssertEqual((path as? NSAccessibilityProtocol)?.accessibilityValue() as? String, project.path)
            XCTAssertEqual(model.settingsRequest?.projectID, project.id)
        }

        func press(_ id: String) async throws {
            let button = try await find(id)
            XCTAssertEqual(button.accessibilityPerformPress?(), true, id)
        }

        func find(_ id: String) async throws -> AnyObject {
            var match: AnyObject?
            try await waitFor(id) {
                match = element(id)
                return match != nil
            }
            return try XCTUnwrap(match)
        }

        func element(_ id: String) -> AnyObject? {
            var visited = Set<ObjectIdentifier>()
            func visit(_ node: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == id { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let match = visit(child as AnyObject) { return match }
                }
                return nil
            }
            func search(_ window: NSWindow) -> AnyObject? {
                window.contentView?.layoutSubtreeIfNeeded()
                return window.attachedSheet.flatMap(search) ?? window.contentView.flatMap(visit)
            }
            return search(window)
        }

        var iconSheet: NSWindow? { window.attachedSheet?.attachedSheet }

        func waitFor(_ description: String = "updated project settings",
                     _ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Timed out waiting for \(description).")
            throw WorkspaceError("Timed out waiting for \(description).")
        }
    }
}
