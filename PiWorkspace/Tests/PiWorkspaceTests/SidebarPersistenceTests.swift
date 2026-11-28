import AppKit
import Carbon
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
        try XCTSkipIf(NSScreen.screens.isEmpty && window.windowNumber <= 0,
                      "AppKit needs a WindowServer connection to route mouse events to the fixture panel.")
        let choice = "project-filter-choice-\(project.id)"
        try await window.click(choice)
        XCTAssertEqual(exclusiveSelections, 1)
        XCTAssertEqual(toggles, [])
        try await window.click(choice, modifiers: .shift)
        XCTAssertEqual(exclusiveSelections, 1)
        XCTAssertEqual(toggles, [false])
        XCTAssertTrue(window.element("project-filter-\(project.id)")?.accessibilityPerformPress?() == true)
        XCTAssertEqual(exclusiveSelections, 1)
        XCTAssertEqual(toggles, [false, false])
    }

    func testPickerSearchAndKeyboardPersistExactScopeWithoutChangingTheDraft() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("workspace.json")
        let alpha = Project(id: UUID(), path: root.appendingPathComponent("alpha").path, title: "Alpha Café")
        let beta = Project(id: UUID(), path: root.appendingPathComponent("beta").path, title: "Beta Café",
                           inSidebarScope: true)
        let draft = Conversation(id: UUID(), title: "Current draft", isDraft: true, composerText: "Keep me unsent")
        let gamma = Project(id: UUID(), path: root.appendingPathComponent("gamma").path, title: "Gamma",
                            conversations: [draft], selectedConversation: draft.id)
        try WorkspaceStore(root: root).save(Workspace(projects: [alpha, beta, gamma], selectedProject: gamma.id))
        func open(_ location: URL) -> WorkspaceModel {
            WorkspaceModel(root: location, keychainService: UUID().uuidString, readCredential: { _ in nil })
        }
        let alphaRow = "project-filter-choice-\(alpha.id)"
        let betaRow = "project-filter-choice-\(beta.id)"
        let gammaRow = "project-filter-choice-\(gamma.id)"
        let all = "project-filter-all"
        let search = "project-filter-search"
        let empty = "project-filter-no-results"
        func searchEditor(in panel: SidebarOffscreenPanel, after action: String) async throws -> NSTextView {
            try await panel.waitFor("focused project search after \(action)") {
                panel.element(search) != nil && panel.searchEditor != nil
            }
            return try XCTUnwrap(panel.searchEditor)
        }
        func replaceQuery(_ query: String, in editor: NSTextView) {
            editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }

        do {
            let model = open(root)
            XCTAssertNil(model.startupFailure)
            func checkScope(_ expected: Set<UUID>) throws {
                XCTAssertEqual(model.sidebarProjectFilter.selection, expected)
                let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
                XCTAssertEqual(Set(saved.projects.filter { $0.inSidebarScope == true }.map(\.id)), expected)
                XCTAssertEqual(saved.selectedProject, gamma.id)
                XCTAssertEqual(saved.activeProject?.selectedConversation, draft.id)
                XCTAssertEqual(saved.activeProject?.conversations.first?.composerText, "Keep me unsent")
                XCTAssertEqual(model.conversation?.id, draft.id)
                XCTAssertEqual(model.draft, "Keep me unsent")
            }

            try checkScope([beta.id])
            do {
                let window = SidebarOffscreenPanel(SidebarPickerFixture(model: model))
                defer { window.close() }
                let editor = try await searchEditor(in: window, after: "opening")
                replaceQuery(" CAFE ", in: editor)
                try await window.waitFor("both matching project titles") {
                    window.element(alphaRow) != nil && window.element(betaRow) != nil && window.element(gammaRow) == nil
                }
                XCTAssertNil(window.element(all))
                try window.key(kVK_Return, "\r")
                try await window.waitFor("closed picker after plain Return") { window.element(search) == nil }
                try checkScope([alpha.id])
            }

            let window = SidebarOffscreenPanel(SidebarPickerFixture(model: model))
            defer { window.close() }
            let reopenedEditor = try await searchEditor(in: window, after: "reopening")
            XCTAssertEqual(reopenedEditor.string, "")
            replaceQuery("Beta", in: reopenedEditor)
            try await window.waitFor("Beta as the only match") {
                window.element(betaRow) != nil && window.element(alphaRow) == nil
            }
            replaceQuery("no such project", in: reopenedEditor)
            try await window.waitFor("no matching projects") { window.element(empty) != nil }
            try window.key(kVK_Return, "\r")
            try window.key(kVK_Return, "\r", modifiers: .shift)
            try checkScope([alpha.id])
            XCTAssertNotNil(window.element(empty))
            XCTAssertTrue(window.firstResponder === reopenedEditor)

            replaceQuery("Beta", in: reopenedEditor)
            try await window.waitFor("Beta after clearing the unmatched query") { window.element(betaRow) != nil }
            reopenedEditor.setMarkedText("Beta", selectedRange: NSRange(location: 4, length: 0),
                                         replacementRange: NSRange(location: 0, length: 4))
            XCTAssertTrue(reopenedEditor.hasMarkedText())
            try window.key(kVK_Return, "\r", modifiers: .shift)
            try checkScope([alpha.id])
            XCTAssertNotNil(window.element(search))
            reopenedEditor.unmarkText()

            replaceQuery("CAFE", in: try await searchEditor(in: window, after: "marked text"))
            try await window.waitFor("both matching rows again") { window.element(alphaRow) != nil }
            try window.key(kVK_DownArrow, "\u{f701}")
            try await Task.sleep(for: .milliseconds(30))
            try window.key(kVK_Return, "\r", modifiers: .shift)
            try checkScope([alpha.id, beta.id])
            XCTAssertEqual(window.searchEditor?.string, "CAFE")
            try window.key(kVK_Return, "\r", modifiers: .shift, repeating: true)
            try checkScope([alpha.id, beta.id])
            try window.key(kVK_Return, "\r", modifiers: .shift)
            try checkScope([alpha.id])
            try window.key(kVK_Return, "\r", modifiers: .shift)
            try checkScope([alpha.id, beta.id])
            try window.key(kVK_Escape, "\u{1b}")
            try await window.waitFor("closed picker after Escape") { window.element(search) == nil }
        }

        let restoredRoot = root.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: restoredRoot, withIntermediateDirectories: false)
        let restoredIndex = restoredRoot.appendingPathComponent("workspace.json")
        try FileManager.default.copyItem(at: index, to: restoredIndex)
        let restored = open(restoredRoot)
        XCTAssertNil(restored.startupFailure)
        XCTAssertEqual(restored.sidebarProjectFilter.selection, [alpha.id, beta.id])
        XCTAssertEqual(restored.conversation?.id, draft.id)
        XCTAssertEqual(restored.draft, "Keep me unsent")
        let restoredWindow = SidebarOffscreenPanel(SidebarPickerFixture(model: restored))
        defer { restoredWindow.close() }
        let restoredEditor = try await searchEditor(in: restoredWindow, after: "restoring the workspace")
        XCTAssertEqual(restoredEditor.string, "")
        XCTAssertNotNil(restoredWindow.element(all))
        try restoredWindow.key(kVK_ANSI_KeypadEnter, "\u{3}")
        try await restoredWindow.waitFor("closed picker after All Projects") { restoredWindow.element(search) == nil }
        XCTAssertTrue(restored.sidebarProjectFilter.selection.isEmpty)
        let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: restoredIndex))
        XCTAssertTrue(saved.projects.allSatisfy { $0.inSidebarScope != true })
    }

    func testWorkspaceProjectFilterPopoverKeyboard() async throws {
        try await checkProjectFilterKeyboard(keyParent: false)
    }

    func testWorkspaceProjectFilterKeyboardWithKeyParent() async throws {
        try await checkProjectFilterKeyboard(keyParent: true)
    }

    private func checkProjectFilterKeyboard(keyParent: Bool) async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = Project(id: UUID(), path: root.appendingPathComponent("alpha").path, title: "Alpha")
        let beta = Project(id: UUID(), path: root.appendingPathComponent("beta").path, title: "Beta")
        try WorkspaceStore(root: root).save(Workspace(projects: [alpha, beta], welcomeCompleted: true))
        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString, readCredential: { _ in nil })
        defer { model.terminate() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let window = SidebarOffscreenPanel(WorkspaceView(model: model, chatWidthMode: .comfortable,
                                                         workspacePasteboard: pasteboard), allowsKey: keyParent)
        defer { window.close() }
        try XCTSkipIf(NSScreen.screens.isEmpty && window.windowNumber <= 0,
                      "The popover needs a WindowServer connection to receive window-targeted events.")
        if keyParent { window.makeKey() }
        let (firstPopover, first) = try await window.openSearchPopover("thread-filters")
        let alphaRow = "project-filter-choice-\(alpha.id)"
        let betaRow = "project-filter-choice-\(beta.id)"
        try await first.click(alphaRow)
        try await window.waitFor("the first popover to close") { !firstPopover.isShown }
        XCTAssertEqual(model.sidebarProjectFilter.selection, [alpha.id])

        let (popover, popup) = try await window.openSearchPopover("thread-filters")
        try await popup.click(betaRow, modifiers: .shift)
        XCTAssertEqual(model.sidebarProjectFilter.selection, [alpha.id, beta.id])
        try await popup.click(betaRow, modifiers: .shift)
        XCTAssertEqual(model.sidebarProjectFilter.selection, [alpha.id])
        let editor = try XCTUnwrap(popup.searchEditor)
        let target: NSWindow = keyParent ? window : popup
        XCTAssertTrue(app.keyWindow === target)
        XCTAssertTrue(target.firstResponder === editor)
        editor.insertText("unmatched", replacementRange: editor.selectedRange())
        try await window.waitFor("no matching projects") { popup.element("project-filter-no-results") != nil }
        try target.key(kVK_Return, "\r")
        XCTAssertTrue(popover.isShown)

        // Buffered keys can arrive before SwiftUI renders the new matches or highlight.
        editor.insertText("a", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try target.key(kVK_DownArrow, "\u{f701}")
        try target.key(kVK_Return, "\r", modifiers: .shift)
        XCTAssertEqual(model.sidebarProjectFilter.selection, [alpha.id, beta.id])
        try await window.waitFor("highlighted Beta in the popover") {
            popup.element(betaRow)?.isAccessibilitySelected?() == true
        }
        XCTAssertTrue(popup.searchEditor === editor)
        XCTAssertEqual(editor.string, "a")
        try target.key(kVK_Return, "\r", modifiers: .shift)
        XCTAssertEqual(model.sidebarProjectFilter.selection, [alpha.id])
        XCTAssertTrue(popover.isShown)

        if !keyParent {
            try window.key(kVK_Return, "\r", modifiers: .shift)
            XCTAssertEqual(model.sidebarProjectFilter.selection, [alpha.id])
        }
        editor.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 0, length: 1))
        XCTAssertTrue(editor.hasMarkedText())
        try target.key(kVK_Return, "\r", modifiers: .shift)
        XCTAssertEqual(model.sidebarProjectFilter.selection, [alpha.id])
        XCTAssertTrue(popover.isShown)
        editor.unmarkText()

        XCTAssertTrue(app.keyWindow === target)
        XCTAssertTrue(target.firstResponder === editor)
        XCTAssertTrue(popup.searchEditor === editor)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "a")
        try target.key(kVK_Return, "\r")
        XCTAssertEqual(model.sidebarProjectFilter.selection, [beta.id])
        try await window.waitFor("Return to dismiss the popover") { !popover.isShown }
    }

    func testWorkspaceDraftProjectPopoverKeyboard() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()

        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = Conversation(id: UUID(), title: "Draft", isDraft: true, composerText: "Keep this")
        let alpha = Project(id: UUID(), path: root.appending(path: "alpha").path, title: "Alpha",
                            conversations: [draft], selectedConversation: draft.id)
        let beta = Project(id: UUID(), path: root.appending(path: "beta").path, title: "Beta")
        for project in [alpha, beta] {
            try FileManager.default.createDirectory(atPath: project.path, withIntermediateDirectories: true)
        }
        try WorkspaceStore(root: root).save(Workspace(projects: [alpha, beta], selectedProject: alpha.id, welcomeCompleted: true))
        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString, readCredential: { _ in nil })
        defer { model.terminate() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let window = SidebarOffscreenPanel(WorkspaceView(model: model, chatWidthMode: .comfortable,
                                                         workspacePasteboard: pasteboard), allowsKey: true)
        defer { window.close() }
        try XCTSkipIf(NSScreen.screens.isEmpty && window.windowNumber <= 0, "WindowServer unavailable.")
        window.makeKey()
        let (popover, popup) = try await window.openSearchPopover("draft-project-trigger")
        let editor = try XCTUnwrap(popup.searchEditor)
        XCTAssertTrue(app.keyWindow === window)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(editor.window === popup)

        let other = SidebarOffscreenPanel(TextField("Other field", text: .constant("")))
        defer { other.close() }
        try other.key(kVK_ANSI_P, "P", modifiers: [.command, .shift])
        XCTAssertTrue(model.projects.allSatisfy { $0.pinned != true })
        try window.key(kVK_ANSI_P, "P", modifiers: [.command, .shift])
        XCTAssertEqual(model.projects.filter { $0.pinned == true }.map(\.id), [alpha.id])
        try window.key(kVK_ANSI_P, "P", modifiers: [.command, .shift])
        XCTAssertTrue(model.projects.allSatisfy { $0.pinned != true })

        editor.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        try window.key(kVK_ANSI_P, "P", modifiers: [.command, .shift])
        XCTAssertTrue(model.projects.allSatisfy { $0.pinned != true })
        editor.unmarkText()
        editor.insertText("missing", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await window.waitFor("no matches") { popup.element("draft-project-no-results") != nil }
        editor.insertText("a", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try window.key(kVK_DownArrow, "\u{f701}")
        try window.key(kVK_ANSI_P, "P", modifiers: [.command, .shift])
        XCTAssertEqual(model.projects.filter { $0.pinned == true }.map(\.id), [beta.id])
        try await window.waitFor("filtered picker") { popup.element("draft-project-pin-\(beta.id)") != nil }
        try window.key(kVK_Return, "\r")
        try await window.waitFor("chooser closed") { !popover.isShown }
        XCTAssertEqual(model.project?.id, beta.id)
        XCTAssertEqual(model.conversation?.id, draft.id)
        XCTAssertEqual(model.draft, draft.composerText)

        let (reopened, _) = try await window.openSearchPopover("draft-project-trigger")
        try window.key(kVK_Escape, "\u{1b}")
        try await window.waitFor("chooser cancelled") { !reopened.isShown }
        XCTAssertEqual(model.project?.id, beta.id)

        let (visible, _) = try await window.openSearchPopover("draft-project-trigger")
        let composer = try await window.field(withValue: model.draft)
        XCTAssertTrue(window.makeFirstResponder(composer))
        XCTAssertTrue(window.firstResponder === composer.currentEditor())
        XCTAssertTrue(visible.isShown)
        try window.key(kVK_ANSI_P, "P", modifiers: [.command, .shift])
        XCTAssertEqual(model.projects.filter { $0.pinned == true }.map(\.id), [beta.id])
    }

    func testEmptyScopedSidebarCanRestoreAllRowsWithoutChangingTheDraft() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(policy) }
        app.finishLaunching()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("workspace.json")
        let empty = Project(id: UUID(), path: root.appendingPathComponent("empty").path, title: "Empty",
                            inSidebarScope: true, sidebarFolderCollapsed: true)
        let draft = Conversation(id: UUID(), title: "Current draft", isDraft: true, composerText: "Keep me unsent")
        let project = Project(id: UUID(), path: root.appendingPathComponent("current").path, title: "Current",
                              conversations: [draft], selectedConversation: draft.id)
        try WorkspaceStore(root: root).save(Workspace(projects: [empty, project], selectedProject: project.id))
        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString, readCredential: { _ in nil })
        XCTAssertNil(model.startupFailure)
        let suite = "SidebarPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SidebarPreference.groupByProject)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let window = SidebarOffscreenPanel(WorkspaceView(model: model, chatWidthMode: .comfortable,
                                                         workspacePasteboard: pasteboard).defaultAppStorage(defaults))
        defer { window.close() }
        let clear = "sidebar-clear-project-scope"
        let row = "thread-row-\(draft.id)"
        try await window.waitFor("Show All Projects in the empty sidebar") { window.element(clear) != nil }
        XCTAssertNil(window.element(row))
        XCTAssertTrue(window.element(clear)?.accessibilityPerformPress?() == true)
        try await window.waitFor("unfiltered sidebar") { window.element(row) != nil && window.element(clear) == nil }
        let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
        XCTAssertTrue(saved.projects.allSatisfy { $0.inSidebarScope != true })
        XCTAssertEqual(saved.projects.first?.sidebarFolderCollapsed, true)
        XCTAssertEqual(saved.selectedProject, project.id)
        XCTAssertEqual(model.conversation?.id, draft.id)
        XCTAssertEqual(model.draft, "Keep me unsent")
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
            try await settings.toggleSwitch("project-settings-pin")
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

private struct SidebarPickerFixture: View {
    let model: WorkspaceModel
    @State private var showing = true

    var body: some View {
        if showing {
            SidebarProjectScopePicker(model: model, grouped: .constant(false), dismiss: { showing = false }) { _ in
                EmptyView()
            }
        }
    }
}

private final class SidebarOffscreenPanel: NSPanel {
    private var allowsKey = false

    convenience init<Content: View>(_ content: Content, allowsKey: Bool = false) {
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
        self.init(contentRect: NSRect(origin: origin, size: NSSize(width: 1080, height: 720)),
                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        self.allowsKey = allowsKey
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        contentView = host
        setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(frame) })
        orderBack(nil)
    }

    override func close() {
        contentView = nil
        super.close()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

extension NSWindow {
    func openSearchPopover(_ trigger: String) async throws -> (popover: NSPopover, window: NSWindow) {
        var shown: NSPopover?
        let observer = NotificationCenter.default.publisher(for: NSPopover.willShowNotification).sink { note in
            shown = note.object as? NSPopover
            // AppKit may constrain the child of our offscreen panel to a screen edge.
            shown?.animates = false
            shown?.contentViewController?.view.window?.alphaValue = 0
            shown?.contentViewController?.view.window?.ignoresMouseEvents = true
        }
        defer { observer.cancel() }
        try await press(trigger)
        try await waitFor("the presented project picker's field editor") {
            shown?.isShown == true && shown?.contentViewController?.view.window?.searchEditor != nil
        }
        let popover = try XCTUnwrap(shown)
        return (popover, try XCTUnwrap(popover.contentViewController?.view.window))
    }
}

private extension NSWindow {
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

    /// Settings switches are native switches: AppKit toggles them on press but reports the press as unhandled.
    func toggleSwitch(_ identifier: String) async throws {
        let control = try await waitForElement(identifier)
        let value = { ((control as? NSAccessibilityProtocol)?.accessibilityValue() as? NSNumber)?.boolValue }
        let before = try XCTUnwrap(value(), identifier)
        _ = control.accessibilityPerformPress?()
        try await waitFor("\(identifier) toggled") { value() == !before }
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

    var searchEditor: NSTextView? {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Search projects" { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let contentView, let editor = find(contentView)?.currentEditor() as? NSTextView,
              editor === firstResponder else { return nil }
        return editor
    }

    func waitFor(_ description: String, _ ready: () -> Bool) async throws {
        for _ in 0..<80 {
            contentView?.layoutSubtreeIfNeeded()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(description).")
        throw WorkspaceError("Timed out waiting for \(description).")
    }

    func click(_ identifier: String, modifiers: NSEvent.ModifierFlags = []) async throws {
        let button = try await waitForElement(identifier)
        let frame = try XCTUnwrap(button.accessibilityFrame?())
        let center = convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            // Dequeuing sets NSApp.currentEvent. Dispatch the original because the queue
            // can remap an offscreen event's window coordinates on a scaled display.
            NSApp.postEvent(event, atStart: true)
            let queued = try XCTUnwrap(NSApp.nextEvent(matching: type == .leftMouseDown ? .leftMouseDown : .leftMouseUp,
                                                      until: .now, inMode: .default, dequeue: true))
            XCTAssertEqual(queued.windowNumber, windowNumber)
            NSApp.sendEvent(event)
        }
    }

    func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: UInt16(code)
        ))
        NSApp.sendEvent(event)
    }
}
