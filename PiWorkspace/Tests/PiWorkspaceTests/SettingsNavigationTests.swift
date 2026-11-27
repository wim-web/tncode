import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import PiWorkspace

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

    func testNativeSearchReachesScopedModelAndCustomBrowserURL() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try XCTSkipIf(fixture.window.windowNumber <= 0, "Native key events need an AppKit window number.")

        let search = try await fixture.waitForField("settings search") { $0.placeholderString == "Search settings" }
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

    func testNativeVersionSearchAndLinksKeepTheOpenSettingsDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try XCTSkipIf(fixture.window.windowNumber <= 0, "Native key events need an AppKit window number.")
        let request = try XCTUnwrap(fixture.model.settingsRequest)
        let licenses = try XCTUnwrap(URL(string: "pi-workspace://settings/open-source-licenses"))
        let version = try XCTUnwrap(URL(string: "pi-workspace://settings/about#app-version"))
        let search = try await fixture.waitForField("settings search") { $0.placeholderString == "Search settings" }

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
        let link = try XCTUnwrap(URL(string: "pi-workspace://settings/open-source-licenses"))
        let fixture = try Fixture(link: link)
        defer { fixture.close() }
        try await fixture.expectLicenses()
    }

    func testSettingsLinkRecognizesLocalDestinationsOnly() throws {
        let project = UUID()
        let links: [(String, SettingsDeepLink?)] = [
            ("pi-workspace://settings", .page(.general)),
            ("pi-workspace://settings/", .page(.general)),
            ("pi-workspace://settings/general", .page(.general)),
            ("pi-workspace://settings/appearance", .page(.appearance)),
            ("pi-workspace://settings/chat", .page(.chat)),
            ("pi-workspace://usage", .page(.usage)),
            ("pi-workspace://settings/usage", .page(.usage)),
            ("pi-workspace://projects/\(project)", .project(project)),
            ("pi-workspace://settings/projects?project=\(project)", .project(project)),
            ("pi-workspace://settings/open-source-licenses", .licenses),
            ("PI-WORKSPACE://SETTINGS/about#app-version", .version),
            ("pi-workspace://settings/about", .page(.about)),
            ("pi-workspace://settings/about#version", nil),
            ("pi-workspace://settings/about?#app-version", nil),
            ("pi-workspace://settings/open-source-licenses/", nil),
            ("pi-workspace://settings/open-source-licenses#app-version", nil),
            ("pi-workspace://settings:1/about#app-version", nil),
            ("pi-workspace://user@settings/about#app-version", nil),
            ("pi-workspace://settings/projects", nil),
            ("pi-workspace://settings/projects?project=\(project)&machine=remote", nil),
            ("pi-workspace://settings/general?project=\(project)", nil),
            ("pi-workspace://projects/\(project)/extra", nil),
            ("pi-workspace://usage?machine=remote", nil),
            ("pi-workspace://settings/pair", nil),
            ("pi-workspace://thread/v1/about#app-version", nil),
            ("pi-workspace://draft/v1/about#app-version", nil),
            ("pi-workspace://new/v1?prompt=general", nil),
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
        let fixture = try Fixture(link: URL(string: "pi-workspace://usage"), projectIDs: [first, second])
        defer { fixture.close() }
        try XCTSkipIf(fixture.window.windowNumber <= 0, "Native key events need an AppKit window number.")
        let model = fixture.model
        let request = try XCTUnwrap(model.settingsRequest)
        let index = fixture.root.appendingPathComponent("workspace.json")
        let stored = try Data(contentsOf: index)

        func open(_ route: String) throws {
            XCTAssertTrue(model.openSettingsLink(try XCTUnwrap(URL(string: "pi-workspace://\(route)"))))
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

        try open("projects/\(first)")
        try await fixture.expectControls("settings-heading-project", "project-settings-name", "project-settings-pin")
        try edit(try await fixture.waitForField("Alpha name") { $0.stringValue == "Alpha" }, to: "Unsaved Alpha")
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

        let search = try await fixture.waitForField("settings search") { $0.placeholderString == "Search settings" }
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

    @MainActor
    private final class Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let model: WorkspaceModel
        let host: NSView
        let window: NSWindow
        let activationPolicy: NSApplication.ActivationPolicy

        init(link: URL? = nil, projectIDs: [UUID] = [UUID()]) throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            suite = "SettingsNavigationTests.\(root.lastPathComponent)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let path = root.path
            let projects = projectIDs.enumerated().map { index, id in
                var project = Project(id: id, path: path, title: index == 0 ? "Alpha" : "Beta")
                project.modelOverride = ModelSettings(provider: .local, model: index == 0 ? "local-override" : "beta-override")
                return project
            }
            try WorkspaceStore(root: root).save(
                Workspace(projects: projects, selectedProject: projectIDs.first, welcomeCompleted: true)
            )
            XCTAssertTrue(BrowserSearchSettings(engine: .custom, customURL: "https://example.test/?q=%s").save(to: defaults))
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
            host = NSHostingView(rootView: SettingsView(model: model, appearance: appearance,
                                                       browserDefaults: defaults, request: request, openWelcome: {})
                .defaultAppStorage(defaults))
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
            defaults.removePersistentDomain(forName: suite)
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
            XCTAssertTrue(control.accessibilityPerformPress?() == true)
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
            return find(host) ?? find(window)
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
