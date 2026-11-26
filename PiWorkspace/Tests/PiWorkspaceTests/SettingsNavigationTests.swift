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
        defer { fixture.window.close() }
        try XCTSkipIf(fixture.window.windowNumber <= 0, "Native key events need an AppKit window number.")

        let search = try await fixture.typeQuery("no setting matches this")
        try await fixture.key(kVK_Return, "\r")
        XCTAssertEqual((search.currentEditor() as? NSTextView)?.string, "no setting matches this")
        try await fixture.key(kVK_Escape, "\u{1b}")
        try await fixture.until("Escape clears search") { search.stringValue.isEmpty }

        _ = try await fixture.typeQuery("model id")
        try await fixture.key(kVK_Return, "\r")
        let modelID = try await fixture.waitForField("project model ID") { $0.stringValue == "local-override" }
        try await fixture.until("Return focuses the project model ID") {
            modelID.currentEditor() != nil && modelID.currentEditor() === fixture.window.firstResponder
        }
        try fixture.edit(modelID, text: "unsaved-model")

        _ = try await fixture.typeQuery("settings")
        try await fixture.key(kVK_UpArrow)
        try await fixture.key(kVK_Return, "\r")
        let field = try await fixture.waitForField("custom search URL") { $0.stringValue == "https://example.test/?q=%s" }
        XCTAssertEqual(BrowserSearchSettings.load(from: fixture.defaults).customURL, field.stringValue)

        _ = try await fixture.typeQuery("provider credentials")
        try await fixture.key(kVK_Return, "\r")
        _ = try await fixture.waitForField("API key") { $0 is NSSecureTextField }
        _ = try await fixture.waitForField("unsaved project model ID") { $0.stringValue == "unsaved-model" }

        let saved = try JSONDecoder().decode(
            Workspace.self, from: Data(contentsOf: fixture.root.appendingPathComponent("workspace.json"))
        )
        XCTAssertEqual(saved.activeProject?.modelOverride?.model, "local-override")
        XCTAssertEqual(saved.model.provider, .openai)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let model: WorkspaceModel
        let host: NSView
        let window: NSWindow

        init() throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            suite = "SettingsNavigationTests.\(root.lastPathComponent)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            var scoped = Project(id: UUID(), path: root.path, title: "Alpha")
            scoped.modelOverride = ModelSettings(provider: .local, model: "local-override")
            try WorkspaceStore(root: root).save(
                Workspace(projects: [scoped], selectedProject: scoped.id, welcomeCompleted: true)
            )
            XCTAssertTrue(BrowserSearchSettings(engine: .custom, customURL: "https://example.test/?q=%s").save(to: defaults))
            model = WorkspaceModel(root: root, keychainService: suite, makeProcess: { _, _ in
                throw WorkspaceError("No Pi helper in this test.")
            })
            XCTAssertNil(model.startupFailure)
            model.openSettings()
            let request = try XCTUnwrap(model.settingsRequest)
            let appearance = AppearanceSettings(defaults: defaults)
            host = NSHostingView(rootView: SettingsView(model: model, appearance: appearance,
                                                       browserDefaults: defaults, request: request)
                .defaultAppStorage(defaults))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 784, height: 474),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderBack(nil)
        }

        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func typeQuery(_ query: String) async throws -> NSTextField {
            let field = try await waitForField("settings search") { $0.placeholderString == "Search settings" }
            XCTAssertTrue(window.makeFirstResponder(field))
            try await key(kVK_ANSI_F, "f", modifiers: .command)
            try edit(field, text: query)
            try await Task.sleep(for: .milliseconds(25))
            return field
        }

        func edit(_ field: NSTextField, text: String) throws {
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }

        func key(_ code: Int, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
            ))
            NSApplication.shared.sendEvent(event)
            try await Task.sleep(for: .milliseconds(25))
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

        private func textField(_ matches: @escaping (NSTextField) -> Bool) -> NSTextField? {
            func find(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, matches(field) { return field }
                return view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            return find(in: host)
        }
    }
}
