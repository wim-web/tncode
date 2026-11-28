import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import tncode

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testIndexMatchesNamesAndKeywordsAndSkipsUnavailableControls() {
        var availability = SettingsSearchAvailability(
            canEditModels: true, hasProjectScope: true, usesLocalProvider: false,
            hasSavedKey: false, canResetModelOverride: true, usesCustomSearch: false
        )
        var search = SettingsSearch()
        search.query = "  CÖLOR   SCHeme  "
        XCTAssertEqual(search.results(available: availability).first?.anchor, .colorScheme)
        search.query = " keychain credentials"
        XCTAssertEqual(search.results(available: availability).first?.anchor, .apiKey)
        search.query = "workspace override"
        XCTAssertEqual(search.results(available: availability).map(\.anchor), [.scope, .resetModelOverride])
        search.query = "custom search url"
        XCTAssertTrue(search.results(available: availability).isEmpty)
        availability.usesCustomSearch = true
        XCTAssertEqual(search.results(available: availability).first?.anchor, .customSearchURL)
        search.query = "base url"
        XCTAssertTrue(search.results(available: availability).isEmpty)
        availability.usesLocalProvider = true
        XCTAssertEqual(search.results(available: availability).first?.anchor, .endpoint)
        search.query = "thinking level"
        XCTAssertTrue(search.results(available: availability).isEmpty)
        search.query = "remove saved key"
        XCTAssertTrue(search.results(available: availability).isEmpty)
        availability.hasSavedKey = true
        XCTAssertEqual(search.results(available: availability).first?.anchor, .removeKey)
        availability.canEditModels = false
        XCTAssertTrue(search.results(available: availability).isEmpty)
        search.query = "third-party notices"
        XCTAssertEqual(search.results(available: availability).first?.anchor, .licenses)
        search.query = "onboarding"
        XCTAssertEqual(search.results(available: availability).first?.anchor, .welcomePage)
        search.query = "archived threads"
        XCTAssertEqual(search.results(available: availability).first?.id, "archive")
        XCTAssertEqual(search.results(available: availability).first?.page, .archived)
        search.query = "unarchive"
        XCTAssertEqual(search.results(available: availability).first?.anchor, .archive)
        search.query = "external disk"
        XCTAssertEqual(search.results(available: availability).first?.page, .worktrees)
        XCTAssertEqual(search.results(available: availability).first?.anchor, .worktreeLocation)
        search.query = "start from remote"
        XCTAssertEqual(search.results(available: availability).first?.anchor, .startFromRemote)
        search.query = "project overview"
        XCTAssertEqual(search.results(available: availability).first?.page, .project)
        availability.hasProjectScope = false
        XCTAssertTrue(search.results(available: availability).isEmpty)
    }

    func testResultSelectionWrapsAndNewQuerySelectsFirstMatch() {
        let availability = SettingsSearchAvailability(
            canEditModels: true, hasProjectScope: true, usesLocalProvider: true,
            hasSavedKey: false, canResetModelOverride: true, usesCustomSearch: true
        )
        var search = SettingsSearch()
        search.query = "model settings"
        let rows = search.results(available: availability)
        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertEqual(search.selected(in: rows)?.id, "model")
        search.move(by: -1, in: rows)
        XCTAssertEqual(search.selected(in: rows)?.id, rows.last?.id)
        search.move(by: 1, in: rows)
        XCTAssertEqual(search.selected(in: rows)?.id, "model")
        search.query = "browser"
        XCTAssertEqual(search.selected(in: search.results(available: availability))?.id, "browser")
    }

    func testTerminalClosePreferenceAcrossRelaunch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let suiteKey = "TNCODE_TERMINAL_CLOSE_SUITE"
        let phaseKey = "TNCODE_TERMINAL_CLOSE_PHASE"
        if let suite = environment[suiteKey] {
            let phase = try XCTUnwrap(environment[phaseKey])
            let fixture = try Fixture(suiteName: suite)
            defer { fixture.close() }
            let search = try await fixture.waitForField("settings search") { $0.placeholderString == "Search" }
            try await fixture.typeQuery("stop process shell", in: search)
            try await fixture.expectControls("settings-result-terminal-close-confirmation")
            try await fixture.key(kVK_Return, "\r")
            try await fixture.expectControls("terminal-close-confirmation")
            XCTAssertEqual(fixture.model.settingsRequest?.destination.anchor, .terminalCloseConfirmation)

            func isOn() -> Bool? {
                let control = fixture.element("terminal-close-confirmation") as? NSAccessibilityProtocol
                return (control?.accessibilityValue() as? NSNumber)?.boolValue
            }
            let initialValue = isOn()
            switch phase {
            case "fresh":
                XCTAssertNil(fixture.defaults.object(forKey: TerminalPreference.confirmClose))
                XCTAssertEqual(isOn(), true)
                XCTAssertNil(fixture.element("reset-terminal-close-confirmation"))
                let toggle = try XCTUnwrap(fixture.element("terminal-close-confirmation"))
                _ = toggle.accessibilityPerformPress?()
                try await fixture.expectControls("reset-terminal-close-confirmation")
                XCTAssertEqual(isOn(), false)
            case "disabled":
                XCTAssertEqual(isOn(), false)
                try await fixture.press("reset-terminal-close-confirmation")
                try await fixture.until("Reset restores the enabled default") {
                    isOn() == true && fixture.element("reset-terminal-close-confirmation") == nil
                }
            case "reset":
                XCTAssertEqual(isOn(), true)
                XCTAssertNil(fixture.element("reset-terminal-close-confirmation"))
            default:
                XCTFail("Unexpected relaunch phase \(phase)")
            }
            XCTAssertTrue(fixture.defaults.bool(forKey: SidebarPreference.groupByProject))
            XCTAssertTrue(fixture.defaults.synchronize())
            print("Terminal close confirmation, \(phase) launch: \(String(describing: initialValue)), after interaction: \(String(describing: isOn()))")
            return
        }

        let suite = "SettingsNavigationTests.TerminalClose.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SidebarPreference.groupByProject)
        XCTAssertTrue(defaults.synchronize())
        for phase in ["fresh", "disabled", "reset"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest",
                                 "tncodeTests.SettingsNavigationTests/testTerminalClosePreferenceAcrossRelaunch",
                                 Bundle(for: Self.self).bundlePath]
            var childEnvironment = environment
            childEnvironment["XCTestSessionIdentifier"] = nil
            childEnvironment[suiteKey] = suite
            childEnvironment[phaseKey] = phase
            process.environment = childEnvironment
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .exit, phase)
            XCTAssertEqual(process.terminationStatus, 0, phase)
        }
    }

    func testNativeSearchReachesScopedModelAndCustomBrowserURL() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try XCTSkipIf(fixture.window.windowNumber <= 0, "Native key events need an AppKit window number.")

        let search = try await fixture.waitForField("settings search") { $0.placeholderString == "Search" }
        try await fixture.until("Settings opens with keyboard focus in search") {
            search.currentEditor() != nil && search.currentEditor() === fixture.window.firstResponder
        }
        try await fixture.typeQuery("no setting matches this", in: search)
        try await fixture.key(kVK_Return, "\r")
        XCTAssertEqual((search.currentEditor() as? NSTextView)?.string, "no setting matches this")
        try await fixture.key(kVK_Escape, "\u{1b}")
        try await fixture.until("Escape clears search") { search.stringValue.isEmpty }

        try await fixture.typeQuery("model id", in: search)
        try await fixture.key(kVK_Return, "\r")
        let modelID = try await fixture.waitForField("project model ID") { $0.stringValue == "local-override" }
        try await fixture.until("Return focuses the project model ID") {
            modelID.currentEditor() != nil && modelID.currentEditor() === fixture.window.firstResponder
        }
        try XCTUnwrap(fixture.window.firstResponder as? NSTextView).selectAll(nil)
        fixture.window.sendEvent(try fixture.event(kVK_ANSI_X, "x"))
        XCTAssertEqual(modelID.stringValue, "x")
        XCTAssertEqual(search.stringValue, "")

        try await fixture.typeQuery("settings", in: search)
        try await fixture.key(kVK_UpArrow)
        try await fixture.key(kVK_Return, "\r")
        let field = try await fixture.waitForField("custom search URL") { $0.stringValue == "https://example.test/?q=%s" }
        try await fixture.until("Return focuses the custom search URL") {
            field.currentEditor() != nil && field.currentEditor() === fixture.window.firstResponder
        }
        XCTAssertEqual(BrowserSearchSettings.load(from: fixture.defaults).customURL, field.stringValue)

        try await fixture.typeQuery("provider credentials", in: search)
        try await fixture.key(kVK_Return, "\r")
        let apiKey = try await fixture.waitForField("API key") { $0 is NSSecureTextField }
        try await fixture.until("Return focuses the secure API key") {
            apiKey.currentEditor() != nil && apiKey.currentEditor() === fixture.window.firstResponder
        }
        _ = try await fixture.waitForField("unsaved project model ID") { $0.stringValue == "x" }

        let saved = try JSONDecoder().decode(
            Workspace.self, from: Data(contentsOf: fixture.root.appendingPathComponent("workspace.json"))
        )
        XCTAssertEqual(saved.activeProject?.modelOverride?.model, "local-override")
        XCTAssertEqual(saved.model.provider, .openai)
    }

    func testBrowserSearchResetClearsTheSavedEngineAndTemplate() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let index = fixture.root.appendingPathComponent("workspace.json")
        let before = try Data(contentsOf: index)
        fixture.defaults.set("Keep this preference", forKey: "unrelated-preference")
        try await fixture.press("settings-nav-browser")
        try await fixture.expectControls("browser-custom-search-url")
        XCTAssertEqual(BrowserSearchSettings.load(from: fixture.defaults).engine, .custom)
        let reset = try XCTUnwrap(fixture.element("reset-browser-search-engine"), "The configured browser has no Reset search engine to default action.")
        XCTAssertTrue(reset.accessibilityPerformPress?() == true)
        try await fixture.until("Reset persisted DuckDuckGo and removed both custom controls") {
            BrowserSearchSettings.load(from: fixture.defaults) == BrowserSearchSettings() &&
                fixture.element("browser-custom-search-url") == nil && fixture.element("reset-browser-search-engine") == nil
        }
        XCTAssertEqual(BrowserSearchSettings.load(from: try XCTUnwrap(UserDefaults(suiteName: fixture.suite))), BrowserSearchSettings())
        XCTAssertEqual(fixture.defaults.string(forKey: "unrelated-preference"), "Keep this preference")
        XCTAssertEqual(try Data(contentsOf: index), before)
    }

    func testNativeVersionSearchAndLinksKeepTheOpenSettingsDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try XCTSkipIf(fixture.window.windowNumber <= 0, "Native key events need an AppKit window number.")
        let request = try XCTUnwrap(fixture.model.settingsRequest)
        let licenses = try XCTUnwrap(URL(string: "tncode://settings/open-source-licenses"))
        let version = try XCTUnwrap(URL(string: "tncode://settings/about#app-version"))
        let search = try await fixture.waitForField("settings search") { $0.placeholderString == "Search" }

        try await fixture.typeQuery("Version", in: search)
        try await fixture.until("Version is a distinct About search result") {
            fixture.element("settings-result-app-version") != nil
        }
        try await fixture.key(kVK_Return, "\r")
        try await fixture.expectVersion()

        try await fixture.press("settings-nav-model")
        let modelID = try await fixture.waitForField("model ID") { $0.stringValue == "local-override" }
        XCTAssertTrue(fixture.window.makeFirstResponder(modelID))
        let editor = try XCTUnwrap(modelID.currentEditor() as? NSTextView)
        editor.insertText("unsaved-model", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(modelID.stringValue, "unsaved-model")

        XCTAssertTrue(fixture.model.openSettingsLink(licenses))
        try await fixture.expectLicenses()
        XCTAssertTrue(fixture.model.openSettingsLink(version))
        try await fixture.expectVersion()
        XCTAssertTrue(fixture.model.settingsRequest === request)

        try await fixture.press("settings-nav-model")
        _ = try await fixture.waitForField("unsaved model ID") { $0.stringValue == "unsaved-model" }
        XCTAssertEqual(fixture.model.workspace.activeProject?.modelOverride?.model, "local-override")

        XCTAssertTrue(fixture.model.openSettingsLink(version))
        try await fixture.expectVersion()
    }

    func testNativeLicenseLinkOpensDirectlyFromClosedSettings() async throws {
        let link = try XCTUnwrap(URL(string: "tncode://settings/open-source-licenses"))
        let fixture = try Fixture(link: link)
        defer { fixture.close() }
        try await fixture.expectLicenses()
    }

    func testNativeArchiveConfirmationSearchLinkAndReset() async throws {
        let appearance = try XCTUnwrap(URL(string: "tncode://settings/appearance"))
        let archive = try XCTUnwrap(URL(string: "tncode://settings/general#archive-confirmation"))
        let fixture = try Fixture(link: appearance)
        defer { fixture.close() }
        let search = try await fixture.waitForField("settings search") { $0.placeholderString == "Search" }
        try await fixture.typeQuery("archive confirmation", in: search)
        try await fixture.press("settings-result-archive-confirmation")
        try await fixture.expectControls("settings-heading-general", "archive-confirmation")
        XCTAssertFalse(fixture.model.confirmsThreadArchive)
        XCTAssertNil(fixture.element("reset-archive-confirmation"))

        try await fixture.toggleSwitch("archive-confirmation")
        try await fixture.expectControls("reset-archive-confirmation")
        XCTAssertTrue(fixture.model.confirmsThreadArchive)
        let otherRoot = fixture.root.appendingPathComponent("other-workspace")
        let otherWorkspace = WorkspaceModel(root: otherRoot, keychainService: fixture.suite)
        XCTAssertNil(otherWorkspace.startupFailure)
        XCTAssertFalse(otherWorkspace.confirmsThreadArchive)
        try await fixture.press("settings-nav-threads")
        XCTAssertTrue(fixture.model.openSettingsLink(archive))
        try await fixture.expectControls("settings-heading-general", "archive-confirmation", "reset-archive-confirmation")
        XCTAssertEqual(fixture.model.settingsRequest?.destination.anchor, .archiveConfirmation)
        try await fixture.press("reset-archive-confirmation")
        try await fixture.until("Reset restores off") { !fixture.model.confirmsThreadArchive }
    }

    func testSecondLinkBeforeSheetPresentationOpensLatestDestination() async throws {
        let first = try XCTUnwrap(URL(string: "tncode://settings/appearance"))
        let second = try XCTUnwrap(URL(string: "tncode://settings/open-source-licenses"))
        let fixture = try Fixture(link: first, linkBeforePresentation: second)
        defer { fixture.close() }

        try await fixture.expectLicenses()
        XCTAssertNil(fixture.element("appearance-color-scheme"))
    }

    func testSettingsLinkRecognizesLocalDestinationsOnly() throws {
        let project = UUID()
        let links: [(String, SettingsDeepLink?)] = [
            ("tncode://settings", .page(.general)),
            ("tncode://settings/", .page(.general)),
            ("tncode://settings/general", .page(.general)),
            ("tncode://settings/general#archive-confirmation", .archiveConfirmation),
            ("tncode://settings/archived", .page(.archived)),
            ("tncode://settings/archived#archive", .archivedThreads),
            ("tncode://settings/archived#archive-confirmation", nil),
            ("tncode://settings/threads#archive-confirmation", nil),
            ("tncode://settings/general?#archive-confirmation", nil),
            ("tncode://settings/appearance", .page(.appearance)),
            ("tncode://settings/chat", .page(.chat)),
            ("tncode://usage", .page(.usage)),
            ("tncode://settings/usage", .page(.usage)),
            ("tncode://projects/\(project)", .project(project)),
            ("tncode://settings/projects?project=\(project)", .project(project)),
            ("tncode://settings/open-source-licenses", .licenses),
            ("TNCODE://SETTINGS/about#app-version", .version),
            ("tncode://settings/about", .page(.about)),
            ("tncode://settings/about#version", nil),
            ("tncode://settings/about?#app-version", nil),
            ("tncode://settings/open-source-licenses/", nil),
            ("tncode://settings/open-source-licenses#app-version", nil),
            ("tncode://settings:1/about#app-version", nil),
            ("tncode://user@settings/about#app-version", nil),
            ("tncode://settings/projects", nil),
            ("tncode://settings/projects?project=\(project)&machine=remote", nil),
            ("tncode://settings/general?project=\(project)", nil),
            ("tncode://projects/\(project)/extra", nil),
            ("tncode://usage?machine=remote", nil),
            ("tncode://settings/pair", nil),
            ("tncode://thread/v1/about#app-version", nil),
            ("tncode://draft/v1/about#app-version", nil),
            ("tncode://new/v1?prompt=general", nil),
            ("https://settings/about#app-version", nil)
        ]
        for (text, expected) in links {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertEqual(SettingsDeepLink(url: url), expected, text)
        }
    }

    func testNativePageLinksKeepTheSheetAndItsProjectEdits() async throws {
        let first = UUID()
        let second = UUID()
        let fixture = try Fixture(link: URL(string: "tncode://usage"), projectIDs: [first, second])
        defer { fixture.close() }
        try XCTSkipIf(fixture.window.windowNumber <= 0, "Native key events need an AppKit window number.")
        let model = fixture.model
        let request = try XCTUnwrap(model.settingsRequest)
        let index = fixture.root.appendingPathComponent("workspace.json")
        let stored = try Data(contentsOf: index)

        func open(_ route: String) throws {
            XCTAssertTrue(model.openSettingsLink(try XCTUnwrap(URL(string: "tncode://\(route)"))))
            XCTAssertTrue(model.settingsRequest === request)
        }

        func edit(_ field: NSTextField, to text: String) throws {
            XCTAssertTrue(fixture.window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            XCTAssertEqual(field.stringValue, text)
        }

        try await fixture.expectControls("settings-heading-usage", "usage-period")
        try open("settings")
        try await fixture.expectControls("settings-heading-general", "settings-group-by-project", "add-project-starts-in")
        try open("settings/appearance")
        try await fixture.expectControls("settings-heading-appearance", "appearance-color-scheme", "appearance-chat-width")
        try open("settings/chat")
        try await fixture.expectControls("settings-heading-chat", "send-shortcut", "follow-up-behavior")
        try open("settings/archived")
        try await fixture.expectControls("settings-heading-archived", "archive", "archive-project", "archive-empty")
        try open("settings/archived#archive")
        XCTAssertEqual(request.destination.anchor, .archive)
        try await fixture.expectControls("archive", "archive-empty")

        try open("projects/\(first)")
        try await fixture.expectControls("settings-heading-project", "project-settings-name", "project-settings-pin")
        try edit(try await fixture.waitForField("Alpha name") { $0.stringValue == "Alpha" }, to: "Unsaved Alpha")
        try open("projects/\(second)")
        _ = try await fixture.waitForField("Beta name") { $0.stringValue == "Beta" }
        try open("projects/\(first)")
        _ = try await fixture.waitForField("unsaved Alpha name") { $0.stringValue == "Unsaved Alpha" }
        try await fixture.press("project-settings-model")
        try edit(try await fixture.waitForField("Alpha model") { $0.stringValue == "local-override" }, to: "unsaved-alpha")
        try open("settings/projects?project=\(second)")
        _ = try await fixture.waitForField("Beta name") { $0.stringValue == "Beta" }
        try await fixture.press("project-settings-model")
        try edit(try await fixture.waitForField("Beta model") { $0.stringValue == "beta-override" }, to: "unsaved-beta")

        let current = request.destination
        try open("projects/\(UUID())")
        XCTAssertTrue(model.threadLinkError?.contains("unavailable") == true)
        try open("settings/general?machine=elsewhere")
        XCTAssertTrue(model.threadLinkError?.contains("invalid") == true)
        XCTAssertEqual(request.destination, current)
        _ = try await fixture.waitForField("still editing Beta model") { $0.stringValue == "unsaved-beta" }

        try open("projects/\(first)")
        _ = try await fixture.waitForField("unsaved Alpha name") { $0.stringValue == "Unsaved Alpha" }
        try open("settings/model")
        _ = try await fixture.waitForField("unsaved Alpha model") { $0.stringValue == "unsaved-alpha" }
        try open("projects/\(second)")
        try await fixture.press("project-settings-model")
        _ = try await fixture.waitForField("unsaved Beta model") { $0.stringValue == "unsaved-beta" }
        XCTAssertEqual(try Data(contentsOf: index), stored)

        model.removeProject(second)
        let afterRemoval = try Data(contentsOf: index)
        try open("projects/\(second)")
        XCTAssertTrue(model.threadLinkError?.contains("unavailable") == true)
        try await fixture.expectControls("settings-heading-model", "settings-project-unavailable")
        XCTAssertNil(fixture.element("save-settings"))
        try open("settings/general")
        try await fixture.press("settings-close")
        XCTAssertNil(model.settingsRequest)
        XCTAssertNil(model.threadLinkError)
        XCTAssertEqual(model.workspace.selectedProject, first)
        XCTAssertEqual(try Data(contentsOf: index), afterRemoval)
    }

    func testNativeFolderPreferenceCommitsOnReturnAndBlur() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try XCTSkipIf(fixture.window.windowNumber <= 0, "Native key events need an AppKit window number.")
        let first = fixture.root.appendingPathComponent("First Projects")
        let second = fixture.root.appendingPathComponent("Second Projects")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }

        let search = try await fixture.waitForField("settings search") { $0.placeholderString == "Search" }
        try await fixture.typeQuery("base directory", in: search)
        try await fixture.key(kVK_Return, "\r")
        let field = try await fixture.waitForField("Add project starts in") { $0.placeholderString == "~/" }
        try await fixture.until("Search focuses the setting field") {
            field.currentEditor() != nil && field.currentEditor() === fixture.window.firstResponder
        }
        XCTAssertEqual(field.stringValue, "")

        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("  \(first.path)  ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(fixture.model.workspace.addProjectBaseDirectory)
        try await fixture.key(kVK_Return, "\r")
        try await fixture.until("Return saves the trimmed folder") {
            fixture.model.workspace.addProjectBaseDirectory == first.path
        }

        try await fixture.typeQuery("add project starts in", in: search)
        try await fixture.key(kVK_Return, "\r")
        let reopened = try await fixture.waitForField("refocused folder preference") {
            $0.placeholderString == "~/" && $0.currentEditor() === fixture.window.firstResponder
        }
        let next = try XCTUnwrap(reopened.currentEditor() as? NSTextView)
        next.insertText(second.path, replacementRange: NSRange(location: 0, length: next.string.utf16.count))
        try await fixture.typeQuery("onboarding", in: search)
        XCTAssertEqual(fixture.model.workspace.addProjectBaseDirectory, second.path)
        try await fixture.key(kVK_Return, "\r")
        XCTAssertEqual(fixture.model.workspace.addProjectBaseDirectory, second.path)
    }

    func testRestoreDeviceDefaultsPreservesWorkspaceAndPendingScopedEdits() async throws {
        let projectID = UUID()
        let threadID = UUID()
        let queue = [QueuedMessage(text: "Keep the queued prompt")]
        let fixture = try Fixture(projectIDs: [projectID], browserSettings: .init()) { workspace, defaults in
            var thread = Conversation(id: threadID, title: "Keep this thread")
            thread.composerText = "Keep the unsent draft"
            thread.queuedMessages = queue
            thread.location = .worktree(path: "/fixture/existing-checkout", base: nil)
            thread.worktreeStartsFromRemote = false
            workspace.projects[0].conversations = [thread]
            workspace.projects[0].selectedConversation = threadID
            workspace.worktreesDirectory = "/fixture/worktree-storage"
            defaults.set(true, forKey: SidebarPreference.groupByProject)
        }
        defer { fixture.close() }
        let restore = "restore-device-defaults"
        let index = fixture.root.appendingPathComponent(WorkspaceStore.indexName)
        let cleanIndex = try Data(contentsOf: index)
        let request = try XCTUnwrap(fixture.model.settingsRequest)

        try await fixture.until("Restore is disabled when only unrelated preferences differ") {
            fixture.isEnabled(restore) == false
        }
        XCTAssertEqual(try Data(contentsOf: index), cleanIndex)
        try await fixture.press("settings-nav-model")
        try await fixture.until("Restore is absent from Model settings") { fixture.element(restore) == nil }
        let modelField = try await fixture.waitForField("Project model ID") { $0.stringValue == "local-override" }
        try fixture.edit(modelField, to: "pending-project-model")
        try await fixture.press("settings-nav-appearance")
        try await fixture.activate("word-wrap")
        try await fixture.press("settings-nav-diffs")
        try await fixture.activate("hide-whitespace-changes")
        try await fixture.press("settings-nav-worktrees")
        try await fixture.activate("start-from-origin")
        try await fixture.expectControls("reset-start-from-origin")
        try await fixture.press("settings-nav-general")
        try await fixture.toggleSwitch("archive-confirmation")
        try await fixture.activate("terminal-close-confirmation")
        try await fixture.expectControls("reset-terminal-close-confirmation")
        try await fixture.until("Restore is enabled") { fixture.isEnabled(restore) == true }

        let folder = try await fixture.waitForField("Add project starts in") { $0.placeholderString == "~/" }
        try fixture.edit(folder, to: "/fixture/pending-project-start")
        let dirtyIndex = try Data(contentsOf: index)
        try await fixture.press(restore)
        try await fixture.activate("cancel-restore-device-defaults")
        try await fixture.until("Cancel dismisses the confirmation") {
            fixture.element("cancel-restore-device-defaults") == nil
        }
        XCTAssertEqual(try Data(contentsOf: index), dirtyIndex)
        XCTAssertEqual(folder.stringValue, "/fixture/pending-project-start")
        XCTAssertFalse(fixture.defaults.bool(forKey: TerminalPreference.confirmClose))
        XCTAssertFalse(fixture.defaults.bool(forKey: DiffPreferences.wordWrap))
        XCTAssertFalse(fixture.defaults.bool(forKey: DiffPreferences.ignoreWhitespace))

        try await fixture.press(restore)
        try await fixture.activate("confirm-restore-device-defaults")
        try await fixture.until("Restore cleared both the saved settings and the pending folder value") {
            fixture.isEnabled(restore) == false && folder.stringValue.isEmpty
        }
        XCTAssertTrue(fixture.model.settingsRequest === request)
        XCTAssertTrue(fixture.defaults.bool(forKey: TerminalPreference.confirmClose))
        XCTAssertTrue(fixture.defaults.bool(forKey: DiffPreferences.wordWrap))
        XCTAssertTrue(fixture.defaults.bool(forKey: DiffPreferences.ignoreWhitespace))
        try await fixture.press("settings-nav-model")
        _ = try await fixture.waitForField("Pending project edit") { $0.stringValue == "pending-project-model" }
        try await fixture.press("settings-nav-general")
        try await fixture.press("settings-close")
        XCTAssertEqual(try Data(contentsOf: index), cleanIndex)
        XCTAssertTrue(fixture.defaults.bool(forKey: SidebarPreference.groupByProject))
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let model: WorkspaceModel
        let host: NSView
        let window: NSWindow
        let activationPolicy: NSApplication.ActivationPolicy
        let ownsDefaults: Bool

        init(link: URL? = nil, linkBeforePresentation: URL? = nil, projectIDs: [UUID] = [UUID()],
             suiteName: String? = nil,
             browserSettings: BrowserSearchSettings = .init(engine: .custom, customURL: "https://example.test/?q=%s"),
             configure: (inout Workspace, UserDefaults) -> Void = { _, _ in }) throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            suite = suiteName ?? "SettingsNavigationTests.\(root.lastPathComponent)"
            ownsDefaults = suiteName == nil
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let path = root.path
            let projects = projectIDs.enumerated().map { index, id in
                var project = Project(id: id, path: path, title: index == 0 ? "Alpha" : "Beta")
                project.modelOverride = ModelSettings(provider: .local, model: index == 0 ? "local-override" : "beta-override")
                return project
            }
            var workspace = Workspace(projects: projects, selectedProject: projectIDs.first, welcomeCompleted: true)
            configure(&workspace, defaults)
            try WorkspaceStore(root: root).save(workspace)
            XCTAssertTrue(browserSettings.save(to: defaults))
            model = WorkspaceModel(root: root, keychainService: suite, makeProcess: { _, _ in
                throw WorkspaceError("No Pi helper in this test.")
            })
            XCTAssertNil(model.startupFailure)
            if let link {
                XCTAssertTrue(model.openSettingsLink(link))
            } else {
                model.openSettings()
            }
            let request = try XCTUnwrap(model.settingsRequest)
            let appearance = AppearanceSettings(defaults: defaults)
            let app = NSApplication.shared
            activationPolicy = app.activationPolicy()
            app.setActivationPolicy(.prohibited)
            app.finishLaunching()
            let sheet = SettingsView(model: model, appearance: appearance, browserDefaults: defaults,
                                     request: request, openWelcome: {})
            if let linkBeforePresentation {
                XCTAssertTrue(model.openSettingsLink(linkBeforePresentation))
            }
            host = NSHostingView(rootView: sheet.defaultAppStorage(defaults))
            let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
            window = OffscreenSettingsPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 784, height: 474)),
                                          styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(origin)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
            window.orderBack(nil)
        }

        deinit {
            if ownsDefaults { defaults.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: root)
        }

        func close() {
            window.contentView = nil
            window.close()
            NSApplication.shared.setActivationPolicy(activationPolicy)
        }

        func typeQuery(_ query: String, in field: NSTextField) async throws {
            try await key(kVK_ANSI_F, "f", modifiers: .command)
            try await until("Command-F focuses settings search") {
                field.currentEditor() != nil && field.currentEditor() === window.firstResponder
            }
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await Task.sleep(for: .milliseconds(25))
        }

        func key(_ code: Int, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) async throws {
            NSApplication.shared.sendEvent(try event(code, characters, modifiers: modifiers))
            try await Task.sleep(for: .milliseconds(25))
        }

        func event(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
            ))
        }

        func waitForField(_ name: String, _ matches: @escaping (NSTextField) -> Bool) async throws -> NSTextField {
            try await until(name) { textField(matches) != nil }
            return try XCTUnwrap(textField(matches), name)
        }

        func until(_ description: String, _ matches: () -> Bool, file: StaticString = #filePath,
                   line: UInt = #line) async throws {
            for _ in 0..<40 {
                host.layoutSubtreeIfNeeded()
                if matches() { return }
                try await Task.sleep(for: .milliseconds(15))
            }
            XCTAssertTrue(matches(), description, file: file, line: line)
        }

        func expectVersion() async throws {
            try await until("Version anchor and app version value are visible") {
                element("app-version") != nil &&
                    (element("about-version") as? NSAccessibilityProtocol)?.accessibilityValue() as? String
                        == (AboutInfo().version ?? "Unavailable")
            }
        }

        func expectControls(_ ids: String...) async throws {
            try await until("Visible controls \(ids.joined(separator: ", "))") {
                ids.allSatisfy { element($0) != nil }
            }
        }

        func expectLicenses() async throws {
            try await until("Open source licenses panel is visible") {
                element("licenses-back") != nil &&
                    element(DependencyNotice.load() == nil ? "licenses-unavailable" : "licenses-list") != nil
            }
            XCTAssertNil(element("app-version"))
        }

        func press(_ id: String) async throws {
            try await until("Control \(id) is visible") { element(id) != nil }
            let control = try XCTUnwrap(element(id))
            XCTAssertTrue(control.accessibilityPerformPress?() == true, "Press \(id)")
        }

        /// Settings switches are native switches: AppKit toggles them on press but reports the press as unhandled.
        func toggleSwitch(_ id: String) async throws {
            try await until("Control \(id) is visible") { element(id) != nil }
            let control = try XCTUnwrap(element(id))
            let value = { ((control as? NSAccessibilityProtocol)?.accessibilityValue() as? NSNumber)?.boolValue }
            let before = try XCTUnwrap(value(), id)
            _ = control.accessibilityPerformPress?()
            try await until("\(id) toggled") { value() == !before }
        }

        func activate(_ id: String) async throws {
            try await until("Control \(id) is visible") { element(id) != nil }
            let control = try XCTUnwrap(element(id))
            // Switches and alert buttons can handle this action without reporting success offscreen.
            _ = control.accessibilityPerformPress?()
        }

        func edit(_ field: NSTextField, to text: String) throws {
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            XCTAssertEqual(field.stringValue, text)
        }

        func isEnabled(_ id: String) -> Bool? {
            element(id)?.isAccessibilityEnabled?()
        }

        func element(_ id: String) -> AnyObject? {
            var visited = Set<ObjectIdentifier>()
            func find(_ node: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == id { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let match = find(child as AnyObject) { return match }
                }
                return nil
            }
            return find(host) ?? window.attachedSheet.flatMap(find) ?? find(window)
        }

        private func textField(_ matches: @escaping (NSTextField) -> Bool) -> NSTextField? {
            func find(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, matches(field) { return field }
                return view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            return find(in: host)
        }
    }
}

private final class OffscreenSettingsPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
