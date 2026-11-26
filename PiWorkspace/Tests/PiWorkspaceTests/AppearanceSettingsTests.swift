import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    func testChoicesReloadIndependentlyOfOtherPreferenceDomains() throws {
        let suite = "AppearanceSettingsTests.\(UUID().uuidString)"
        let otherSuite = suite + ".other"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            otherDefaults.removePersistentDomain(forName: otherSuite)
        }

        let settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.colorScheme, .system)
        XCTAssertEqual(settings.chatWidth, .comfortable)

        let otherSettings = AppearanceSettings(defaults: otherDefaults)
        otherSettings.colorScheme = .light
        otherSettings.chatWidth = .wide

        for (scheme, width) in [(AppColorScheme.dark, ChatWidth.full), (.light, .wide), (.system, .comfortable)] {
            settings.colorScheme = scheme
            settings.chatWidth = width
            let reloaded = AppearanceSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(reloaded.colorScheme, scheme)
            XCTAssertEqual(reloaded.chatWidth, width)
        }

        settings.colorScheme = .dark
        settings.chatWidth = .full
        settings.restoreDefaults()
        let restored = AppearanceSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restored.colorScheme, .system)
        XCTAssertEqual(restored.chatWidth, .comfortable)
        let otherReloaded = AppearanceSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: otherSuite)))
        XCTAssertEqual(otherReloaded.colorScheme, .light)
        XCTAssertEqual(otherReloaded.chatWidth, .wide)
    }

    func testInvalidPreferencesFallBackIndependently() throws {
        let suite = "AppearanceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setPersistentDomain([
            "appearance.colorScheme": "invalid",
            "appearance.chatWidth": "full",
        ], forName: suite)
        var settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.colorScheme, .system)
        XCTAssertEqual(settings.chatWidth, .full)

        defaults.setPersistentDomain([
            "appearance.colorScheme": "dark",
            "appearance.chatWidth": 123,
        ], forName: suite)
        settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.colorScheme, .dark)
        XCTAssertEqual(settings.chatWidth, .comfortable)
    }

    func testNativeWindowAndSwiftUIHostingInheritAppAppearance() async {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let probe = SchemeProbe()
        let host = NSHostingView(rootView: SchemeProbeView(probe: probe))
        window.contentView = host

        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
        for scheme in [AppColorScheme.light, .dark, .system] {
            scheme.apply(to: app)
            let native = switch scheme {
            case .system: app.effectiveAppearance.bestMatch(from: appearances)
            case .light: NSAppearance.Name.aqua
            case .dark: NSAppearance.Name.darkAqua
            }
            let swiftUI: ColorScheme = native == .darkAqua ? .dark : .light
            for _ in 0..<20 where probe.scheme != swiftUI {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: appearances), native)
            XCTAssertEqual(probe.scheme, swiftUI)
        }

        XCTAssertNil(app.appearance)
        XCTAssertNil(window.appearance)
    }

    func testWidthChangesResizeHostedComposerAndTranscript() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = Conversation(id: UUID(), title: "Draft", isDraft: true, composerText: "Keep typing")
        let submitted = Conversation(id: UUID(), title: "Submitted", isDraft: false)
        let project = Project(id: UUID(), path: root.path, title: "Fixture",
                              conversations: [draft], selectedConversation: draft.id)
        let scratch: Project
        do {
            let store = try WorkspaceStore(root: root)
            scratch = try store.makeScratchProject(for: submitted)
            try store.save(Workspace(projects: [project, scratch], selectedProject: project.id, welcomeCompleted: true))
        }
        let model = WorkspaceModel(root: root, keychainService: UUID().uuidString, makeProcess: { _, _ in
            throw WorkspaceError("No Pi helper in this test.")
        })
        defer { model.terminate() }
        let suite = "AppearanceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppearanceSettings(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1680, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: HostedWorkspace(model: model, settings: settings)
            .defaultAppStorage(defaults))
        window.contentView = host

        let composer = { self.findSubview(in: host) { (field: NSTextField) in
            field.placeholderString == "Ask Pi anything"
        } }
        let transcript = { self.findSubview(in: host) { (view: NSScrollView) in
            view.bounds.width > 256
        } }
        try await assertWidth(710, in: host) { composer()?.superview }
        let draftComposer = try XCTUnwrap(composer())
        XCTAssertTrue(window.makeFirstResponder(draftComposer))
        let editor = try XCTUnwrap(draftComposer.currentEditor() as? NSTextView)
        let caret = NSRange(location: 4, length: 0)
        editor.setSelectedRange(caret)
        let draftFrames: [(viewport: CGFloat, x: CGFloat, width: CGFloat)] = [
            (1080, 318, 701), (900, 318, 521), (1440, 493.5, 710), (1080, 318, 701),
        ]
        for sample in draftFrames {
            window.setContentSize(NSSize(width: sample.viewport, height: 720))
            try await assertWidth(sample.width, in: host, view: composer)
            let frame = host.convert(draftComposer.bounds, from: draftComposer)
            XCTAssertEqual(frame.minX, sample.x, accuracy: 0.5)
            XCTAssertEqual(host.isFlipped ? frame.minY : host.bounds.height - frame.maxY, 317.3, accuracy: 0.5)
            XCTAssertEqual(frame.height, 53.5, accuracy: 0.5)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), caret)
        }
        window.setContentSize(NSSize(width: 1680, height: 720))
        for (mode, width) in [(ChatWidth.comfortable, 710.0), (.wide, 1126.0), (.full, 1301.0)] {
            settings.chatWidth = mode
            try await assertWidth(width, in: host) { composer()?.superview }
            XCTAssertTrue(composer() === draftComposer)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(model.conversation?.id, draft.id)
            XCTAssertEqual(model.draft, "Keep typing")
        }
        model.selectConversation(submitted.id, in: scratch.id)
        XCTAssertEqual(model.conversation?.id, submitted.id)
        for (mode, width) in [(ChatWidth.full, 1301.0), (.wide, 1126.0), (.comfortable, 710.0)] {
            settings.chatWidth = mode
            try await assertWidth(width, in: host) { composer()?.superview }
            try await assertWidth(width + 26, in: host, view: transcript)
        }
    }

    private func assertWidth(_ width: CGFloat, in host: NSView, view: () -> NSView?) async throws {
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            if let view = view(), abs(view.bounds.width - width) < 0.5 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try XCTUnwrap(view()).bounds.width, width, accuracy: 0.5)
    }

    private func findSubview<Subview: NSView>(in root: NSView, matching predicate: (Subview) -> Bool) -> Subview? {
        if let match = root as? Subview, predicate(match) { return match }
        for child in root.subviews {
            if let match = findSubview(in: child, matching: predicate) { return match }
        }
        return nil
    }
}

private struct HostedWorkspace: View {
    let model: WorkspaceModel
    @ObservedObject var settings: AppearanceSettings

    var body: some View {
        WorkspaceView(model: model, chatWidthMode: settings.chatWidth)
    }
}

private final class SchemeProbe {
    var scheme: ColorScheme?
}

private struct SchemeProbeView: NSViewRepresentable {
    let probe: SchemeProbe
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        probe.scheme = scheme
    }
}
