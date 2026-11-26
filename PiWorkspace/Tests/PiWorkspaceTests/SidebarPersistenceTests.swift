import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class SidebarPersistenceTests: XCTestCase {
    func testSidebarHomeAndThreadRowReturnToTheSameUnsentDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let draft = Conversation(id: UUID(), title: "Work in progress", isDraft: true, composerText: "Keep this text.")
        let project = Project(id: UUID(), path: folder.path, title: "Project", conversations: [draft], selectedConversation: draft.id)
        try WorkspaceStore(root: root).save(Workspace(projects: [project], selectedProject: project.id, welcomeCompleted: true))
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()
        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString, readCredential: { _ in nil })
        defer { model.terminate() }
        let window = SidebarOffscreenPanel(WorkspaceView(model: model, chatWidthMode: .comfortable))
        defer { window.close() }
        for _ in 0..<50 where window.element("sidebar-home") == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(window.element("sidebar-home")?.accessibilityPerformPress?() == true)
        XCTAssertNil(model.workspace.selectedProject)
        XCTAssertTrue(window.element("thread-row-\(draft.id)")?.accessibilityPerformPress?() == true)
        XCTAssertEqual(model.conversation?.id, draft.id)
        XCTAssertEqual(model.draft, "Keep this text.")
    }

    func testScopeAndFoldersFollowProjectIDsInTheirOwnWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = root.appendingPathComponent("other-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = Project(id: UUID(), path: root.appendingPathComponent("alpha").path, title: "Project")
        let beta = Project(id: UUID(), path: root.appendingPathComponent("beta").path, title: "Project")
        let draft = Conversation(id: UUID(), title: "Draft", isDraft: true)
        let scratch = Project(id: UUID(), path: root.path, title: "No project", conversations: [draft],
                              selectedConversation: draft.id, kind: .scratch)
        let original = Workspace(projects: [alpha, beta, scratch], selectedProject: scratch.id)
        for location in [root, other] { try WorkspaceStore(root: location).save(original) }
        func open(_ location: URL) -> WorkspaceModel {
            WorkspaceModel(root: location, keychainService: UUID().uuidString, readCredential: { _ in nil })
        }
        do {
            let model = open(root)
            model.draft = "Keep this unsent"
            model.updateSidebarScope { $0.selectOnly(alpha.id) }
            model.updateSidebarScope { $0.setSelected(beta.id, true) }
            model.setSidebarFolderCollapsed(true, for: alpha.id)
            model.renameProject(beta.id, title: "Renamed")
            for staleID in [scratch.id, UUID()] {
                model.updateSidebarScope { $0.selectOnly(staleID) }
                model.setSidebarFolderCollapsed(true, for: staleID)
            }
            XCTAssertEqual(model.sidebarProjectFilter.selection, [alpha.id, beta.id])
            XCTAssertEqual(model.conversation?.id, draft.id)
            XCTAssertEqual(model.draft, "Keep this unsent")
            XCTAssertNil(model.project?.sidebarFolderCollapsed)
        }
        let independent = open(other)
        XCTAssertTrue(independent.sidebarProjectFilter.selection.isEmpty)
        XCTAssertNil(independent.projects.first?.sidebarFolderCollapsed)
        do {
            let model = open(root)
            XCTAssertNil(model.startupFailure)
            XCTAssertEqual(model.sidebarProjectFilter.selection, [alpha.id, beta.id])
            XCTAssertEqual(model.projects.first?.sidebarFolderCollapsed, true)
            XCTAssertEqual(model.conversation?.id, draft.id)
            XCTAssertEqual(model.draft, "Keep this unsent")
            model.removeProject(alpha.id)
            XCTAssertEqual(model.sidebarProjectFilter.selection, [beta.id])
            model.removeProject(beta.id)
            XCTAssertTrue(model.sidebarProjectFilter.selection.isEmpty)
        }
        let reopened = open(root)
        XCTAssertNil(reopened.startupFailure)
        XCTAssertTrue(reopened.sidebarProjectFilter.selection.isEmpty)
        XCTAssertEqual(reopened.threadProjects.map(\.id), [scratch.id])
        XCTAssertEqual(reopened.workspace.projects.first?.inSidebarScope, true)
        reopened.updateSidebarScope { $0.clear() }
        XCTAssertTrue(reopened.workspace.projects.allSatisfy { $0.inSidebarScope != true })
        XCTAssertEqual(reopened.conversation?.id, draft.id)
        XCTAssertEqual(reopened.draft, "Keep this unsent")
    }

    func testProjectNameDistinguishesPlainAndShiftClicks() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()
        let project = Project(id: UUID(), path: "/fixture/alpha", title: "Alpha", inSidebarScope: true)
        var toggles: [Bool] = []
        var exclusiveSelections = 0
        let window = SidebarOffscreenPanel(SidebarProjectScopeRow(
            project: project, setIncluded: { toggles.append($0) },
            selectOnly: { exclusiveSelections += 1 }
        ).padding())
        defer { window.close() }
        let choice = "project-filter-choice-\(project.id)"
        for _ in 0..<50 where window.element(choice) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let frame = try XCTUnwrap(window.element(choice)?.accessibilityFrame?())
        let center = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for modifiers: NSEvent.ModifierFlags in [[], .shift] {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: center, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
                app.postEvent(event, atStart: false)
            }
            while let event = app.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: .now, inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(exclusiveSelections, 1)
        XCTAssertEqual(toggles, [false])
        XCTAssertTrue(window.element("project-filter-\(project.id)")?.accessibilityPerformPress?() == true)
        XCTAssertEqual(toggles, [false, false])
    }

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
            let window = SidebarOffscreenPanel(WorkspaceView(model: model, chatWidthMode: .comfortable)
                .defaultAppStorage(defaults))
            defer { window.close() }
            let header = "project-group-\(alpha.id)"
            let row = "thread-row-\(alphaThread.id)"
            for _ in 0..<50 where window.element(header) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(window.element(header))
            if collapse {
                XCTAssertNotNil(window.element(row))
                XCTAssertTrue(window.element(header)?.accessibilityPerformPress?() == true)
            }
            for _ in 0..<50 where window.element(row) != nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(window.element(row), "Alpha must stay collapsed when the sidebar is rebuilt.")
            XCTAssertNotNil(window.element("thread-row-\(betaThread.id)"))
            XCTAssertEqual(model.conversation?.id, betaThread.id)
            XCTAssertEqual(model.draft, "Unsent")
        }
        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString)
        try await checkWindow(model: model, collapse: true)
        try await checkWindow(model: model, collapse: false)
    }

    func testProjectOverviewKeepsTheClickedScopeAndOpenDraft() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()

        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let first = root.appendingPathComponent("first/Project")
        let second = root.appendingPathComponent("second/Project")
        let checkout = root.appendingPathComponent("Linked checkout")
        for folder in [first, second] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        func git(_ arguments: String...) throws {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            command.arguments = ["-C", second.path] + arguments
            command.standardOutput = FileHandle.nullDevice
            try command.run()
            command.waitUntilExit()
            XCTAssertEqual(command.terminationStatus, 0, arguments.joined(separator: " "))
        }
        try git("init", "--template=", "-b", "main")
        try git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Fixture")
        try git("worktree", "add", "-b", "topic/linked", checkout.path)

        let firstDraft = Conversation(id: UUID(), title: "Other draft", isDraft: true, composerText: "Keep the other draft")
        let linked = Conversation(id: UUID(), title: "Linked draft", location: .worktree(path: checkout.path, base: "main"),
                                  isDraft: true, composerText: "Keep this unsent")
        let alpha = Project(id: UUID(), path: first.path, title: "Project", conversations: [firstDraft],
                            selectedConversation: firstDraft.id, modelOverride: ModelSettings(provider: .local, model: "first-model"))
        let beta = Project(id: UUID(), path: second.path, title: "Project", conversations: [linked],
                           selectedConversation: linked.id, modelOverride: ModelSettings(provider: .local, model: "second-model"))
        try WorkspaceStore(root: root).save(Workspace(projects: [alpha, beta], selectedProject: beta.id, welcomeCompleted: true))
        let suite = "ProjectOverviewTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SidebarPreference.groupByProject)
        var connectionAttempts = 0
        let model = WorkspaceModel(root: root, keychainService: suite, readCredential: { _ in nil }) { _, _ in
            connectionAttempts += 1
            throw WorkspaceError("No Pi helper in this test.")
        }
        defer { model.terminate() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let workspace = SidebarOffscreenPanel(WorkspaceView(model: model, chatWidthMode: .comfortable,
                                                             browserDefaults: defaults, workspacePasteboard: pasteboard)
            .defaultAppStorage(defaults))
        defer { workspace.close() }
        try await workspace.press("project-group-settings-\(alpha.id)")
        XCTAssertEqual(model.settingsRequest?.projectID, alpha.id)
        XCTAssertEqual(model.sidebarProjectFilter.selection, [])

        func openOverview() throws -> SidebarOffscreenPanel {
            let request = try XCTUnwrap(model.settingsRequest)
            XCTAssertEqual(request.page, .project)
            return SidebarOffscreenPanel(SettingsView(model: model, appearance: AppearanceSettings(defaults: defaults),
                                                      browserDefaults: defaults, request: request, pasteboard: pasteboard,
                                                      openWelcome: {}))
        }
        do {
            let settings = try openOverview()
            defer { settings.close() }
            try await settings.press("project-settings-copy-path")
            XCTAssertEqual(pasteboard.string(forType: .string), first.path)
            try await settings.press("project-settings-pin")
            XCTAssertTrue(model.projects.first { $0.id == alpha.id }?.pinned == true)
            XCTAssertNil(model.project?.pinned)
            try await settings.replaceField("Project", with: "Renamed project")
            try await settings.press("project-settings-save-name")
            try await settings.press("project-settings-model")
            try await settings.replaceField("first-model", with: "edited-first-model")
            try await settings.press("settings-nav-project")
            try await settings.press("project-settings-model")
            _ = try await settings.field(withValue: "edited-first-model")
            try await settings.press("save-settings")
        }
        XCTAssertEqual(connectionAttempts, 0)
        XCTAssertEqual(model.projects.first { $0.id == alpha.id }?.title, "Renamed project")
        XCTAssertEqual(model.project?.title, "Project")
        XCTAssertEqual(model.projects.first { $0.id == alpha.id }?.modelOverride?.model, "edited-first-model")
        XCTAssertEqual(model.project?.modelOverride?.model, "second-model")
        XCTAssertEqual(model.conversation?.id, linked.id)
        XCTAssertEqual(model.workingDirectory, checkout.path)
        XCTAssertEqual(model.draft, "Keep this unsent")
        XCTAssertEqual(model.projects.first { $0.id == alpha.id }?.conversations.first?.composerText, "Keep the other draft")

        model.settingsRequest = nil
        try await workspace.press("project-group-settings-\(beta.id)")
        do {
            let settings = try openOverview()
            defer { settings.close() }
            let worktree = checkout.resolvingSymlinksInPath().path
            _ = try await settings.waitForElement("project-settings-checkout-\(worktree)")
            try await settings.press("project-settings-copy-path")
            XCTAssertEqual(pasteboard.string(forType: .string), second.path)
        }

        try files.removeItem(at: first)
        model.settingsRequest = nil
        try await workspace.press("project-group-settings-\(alpha.id)")
        let unavailable = try openOverview()
        defer { unavailable.close() }
        _ = try await unavailable.waitForElement("project-settings-folder-unavailable")
        XCTAssertThrowsError(try model.copyProjectPath(alpha.id, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), second.path)
        model.settingsRequest = nil
        model.openSettings(.project, projectID: UUID())
        XCTAssertNil(model.settingsRequest)
    }
}

private final class SidebarOffscreenPanel: NSPanel {
    convenience init<Content: View>(_ content: Content) {
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
        self.init(contentRect: NSRect(origin: origin, size: NSSize(width: 1080, height: 720)),
                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        contentView = host
        setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(frame) })
        orderBack(nil)
    }

    func element(_ identifier: String) -> AnyObject? {
        guard let contentView else { return nil }
        contentView.layoutSubtreeIfNeeded()
        var visited = Set<ObjectIdentifier>()
        func find(_ node: AnyObject) -> AnyObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.accessibilityIdentifier?() == identifier { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let match = find(child as AnyObject) { return match }
            }
            return nil
        }
        return find(contentView)
    }

    func waitForElement(_ identifier: String) async throws -> AnyObject {
        try await waitFor(identifier) { element(identifier) }
    }

    func press(_ identifier: String) async throws {
        let button = try await waitForElement(identifier)
        XCTAssertTrue(button.accessibilityPerformPress?() == true, identifier)
        await Task.yield()
    }

    func field(withValue value: String) async throws -> NSTextField {
        try await waitFor("text field containing \(value)") {
            func find(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.stringValue == value { return field }
                return view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            return contentView.flatMap { find(in: $0) }
        }
    }

    func replaceField(_ value: String, with replacement: String) async throws {
        let field = try await field(withValue: value)
        XCTAssertTrue(makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(replacement, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    private func waitFor<Value>(_ description: String, read: () -> Value?) async throws -> Value {
        for _ in 0..<80 {
            contentView?.layoutSubtreeIfNeeded()
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WorkspaceError("Timed out waiting for \(description).")
    }

    override func close() {
        contentView = nil
        super.close()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
