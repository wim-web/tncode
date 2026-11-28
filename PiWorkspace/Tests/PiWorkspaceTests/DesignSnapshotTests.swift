import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

/// Renders the workspace offscreen for design comparison with T3 Code (1080×720, as in T3Audit captures).
/// Set PI_WORKSPACE_DESIGN_SNAPSHOTS to an output directory to write PNGs, and optionally
/// PI_WORKSPACE_DESIGN_STATES to a comma-separated list of empty, draft, thread or settings-<page>
/// (for example settings-general). The window is never shown.
@MainActor
final class DesignSnapshotTests: XCTestCase {
    private static let size = NSSize(width: 1080, height: 720)

    func testRenderDesignSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["PI_WORKSPACE_DESIGN_SNAPSHOTS"] else {
            throw XCTSkip("Set PI_WORKSPACE_DESIGN_SNAPSHOTS to render design snapshots.")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // PI_WORKSPACE_DESIGN_LOCALE=ja renders with Localization/ja.lproj, as the packaged app does.
        if let locale = ProcessInfo.processInfo.environment["PI_WORKSPACE_DESIGN_LOCALE"] {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let path = package.appending(path: "Localization/\(locale).lproj").path
            let bundle = try XCTUnwrap(Bundle(path: path), "Missing \(path)")
            DesignLocalizedBundle.override = bundle
            DesignLocalizedBundle.installOverrides()
            object_setClass(Bundle.main, DesignLocalizedBundle.self)
        }
        for scheme in [ColorScheme.dark, .light] {
            for state in (ProcessInfo.processInfo.environment["PI_WORKSPACE_DESIGN_STATES"]?.split(separator: ",").map(String.init) ?? ["empty", "draft", "thread"]) {
                try render(state: state, scheme: scheme, to: directory)
            }
        }
    }

    private func render(state name: String, scheme: ColorScheme, to directory: URL) throws {
        // "thread@ocean" renders the state with a built-in theme in both modes.
        let parts = name.split(separator: "@").map(String.init)
        let theme = parts.count > 1 ? T3ThemeID(rawValue: parts[1]) ?? .t3Code : .t3Code
        let baseName = parts[0]
        let settingsPage = baseName.hasPrefix("settings-") ? SettingsPage(rawValue: String(baseName.dropFirst("settings-".count))) : nil
        if baseName.hasPrefix("settings-"), settingsPage == nil { throw XCTSkip("Unknown settings page in \(name).") }
        let state = settingsPage == nil ? baseName : "thread"
        let root = FileManager.default.temporaryDirectory.appending(path: "design-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = ["tncode", "t3code", "dotfiles"].map { name in
            root.appending(path: "projects/\(name)", directoryHint: .isDirectory)
        }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let now = Date()
        let draft = Conversation(id: UUID(), title: "New thread", isDraft: true, composerText: "")
        let active = Conversation(id: UUID(), title: "Match the sidebar design with T3 Code", lastActiveAt: now.addingTimeInterval(-120))
        let older = Conversation(id: UUID(), title: "Fix worktree retry after relaunch", lastActiveAt: now.addingTimeInterval(-7200))
        let oldest = Conversation(id: UUID(), title: "Investigate flaky terminal test", lastActiveAt: now.addingTimeInterval(-86400 * 3))
        let selected = state == "thread" ? active : draft
        let first = Project(id: UUID(), path: folders[0].path, title: "tncode", allowEdits: true,
                            conversations: state == "thread" ? [active, older, oldest] : [draft, active, older, oldest],
                            selectedConversation: selected.id, createdAt: now.addingTimeInterval(-86400 * 10))
        let second = Project(id: UUID(), path: folders[1].path, title: "t3code",
                             conversations: [Conversation(id: UUID(), title: "Review the PR panel layout", lastActiveAt: now.addingTimeInterval(-3600 * 5)),
                                             Conversation(id: UUID(), title: "Add keyboard shortcuts doc", lastActiveAt: now.addingTimeInterval(-86400 * 2))],
                             createdAt: now.addingTimeInterval(-86400 * 20))
        let third = Project(id: UUID(), path: folders[2].path, title: "dotfiles",
                            conversations: [Conversation(id: UUID(), title: "Update fish config", lastActiveAt: now.addingTimeInterval(-86400 * 8))],
                            createdAt: now.addingTimeInterval(-86400 * 30))
        let workspace = Workspace(projects: state == "empty" ? [] : [first, second, third],
                                  selectedProject: state == "empty" ? nil : first.id,
                                  model: ModelSettings(model: "claude-opus-4-5", thinkingLevel: .low),
                                  welcomeCompleted: true)
        do {
            let store = try WorkspaceStore(root: root)
            try store.save(workspace)
        }
        let messages: [ChatMessage] = state == "thread" ? [
            ChatMessage(id: "u1", role: .user, text: "The sidebar rows look different from T3 Code. Can you compare the padding and fonts?"),
            ChatMessage(id: "a1", role: .assistant, text: """
            I compared the two sidebars. T3 Code uses **13px** text for thread titles with a `0.625rem` row inset.

            1. Thread rows are 28px tall.
            2. Project headers use the folder icon.

            ```swift
            Text(title).font(.system(size: 13))
            ```

            The selected row uses a subtle accent background.
            """),
            ChatMessage(id: "u2", role: .user, text: "Great, apply it."),
            ChatMessage(id: "a2", role: .assistant, text: "Done. The rows now match."),
        ] : []
        let connection = SnapshotConnection(messages: messages)
        let model = WorkspaceModel(root: root, keychainService: "design-\(UUID().uuidString)",
                                   readCredential: { _ in "fixture" }, makeProcess: { _, _ in connection })
        defer { model.terminate() }
        model.start()
        if state == "thread" { model.selectConversation(active.id, in: first.id) }
        if let settingsPage { model.openSettings(settingsPage) }
        XCTAssertNil(model.startupFailure)
        let suite = "DesignSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        let pasteboard = NSPasteboard(name: .init("dev.piworkspace.design.\(UUID().uuidString)"))
        let appearanceSettings = AppearanceSettings(defaults: defaults)
        appearanceSettings.lightTheme = theme
        appearanceSettings.darkTheme = theme
        let product = WorkspaceView(model: model, chatWidthMode: .comfortable, browserDefaults: defaults,
                                    workspacePasteboard: pasteboard)
            .modifier(SettingsPresentation(model: model, appearance: appearanceSettings,
                                           browserDefaults: defaults, pasteboard: pasteboard, openWelcome: {}))
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, scheme)
            .environment(\.t3Themes, T3ThemeChoice(light: theme, dark: theme))
            .background(WindowChrome().frame(width: 0, height: 0))
            .frame(width: Self.size.width, height: Self.size.height)
            .ignoresSafeArea()
        let host = NSHostingView(rootView: product)
        host.sizingOptions = []
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .init(x: -10000, y: -10000), size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        window.styleMask.insert(.fullSizeContentView)
        window.setFrame(NSRect(origin: .init(x: -10000, y: -10000), size: Self.size), display: false)
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
        }
        host.layoutSubtreeIfNeeded()
        let scale = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(Self.size.width) * scale,
            pixelsHigh: Int(Self.size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = Self.size
        let frameView = host.superview ?? host
        appearance.performAsCurrentDrawingAppearance { frameView.cacheDisplay(in: frameView.bounds, to: bitmap) }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appending(path: "\(name)-\(scheme == .dark ? "dark" : "light").png"))
        window.close()
    }
}

@MainActor private final class SnapshotConnection: PiConnection {
    var onEvent: ((PiEvent) -> Void)?
    var onClose: (() -> Void)?
    private let messages: [ChatMessage]

    init(messages: [ChatMessage]) { self.messages = messages }

    func send(_ command: any Encodable) throws {
        if command is OpenConversation { onEvent?(.ready(messages, supportsImages: false)) }
    }

    func close() {}
}

/// Routes Bundle.main lookups to a chosen .lproj while rendering design snapshots.
private final class DesignLocalizedBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var override: Bundle?

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let override = Self.override {
            return override.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }

    /// Foundation and SwiftUI resolve strings through several NSBundle entry points; route them all here.
    static func installOverrides() {
        typealias Four = @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?) -> AnyObject
        typealias Three = @convention(block) (AnyObject, NSString, NSString?, NSString?) -> AnyObject
        func resolve(_ key: NSString, _ value: NSString?, _ table: NSString?) -> String {
            (override ?? Bundle(for: DesignLocalizedBundle.self))
                .localizedString(forKey: key as String, value: value as String?, table: table as String?)
        }
        let strings: Four = { _, key, value, table, _ in resolve(key, value, table) as NSString }
        let attributed: Four = { _, key, value, table, _ in NSAttributedString(string: resolve(key, value, table)) }
        let attributedThree: Three = { _, key, value, table in NSAttributedString(string: resolve(key, value, table)) }
        for name in ["localizedStringForKey:value:table:localizations:", "localizedStringForKey:value:table:localization:",
                     "_localizedStringForKey:value:table:localizations:"] {
            class_replaceMethod(self, NSSelectorFromString(name), imp_implementationWithBlock(strings), "@@:@@@@")
        }
        class_replaceMethod(self, NSSelectorFromString("localizedAttributedStringForKey:value:table:localization:"),
                            imp_implementationWithBlock(attributed), "@@:@@@@")
        class_replaceMethod(self, NSSelectorFromString("localizedAttributedStringForKey:value:table:"),
                            imp_implementationWithBlock(attributedThree), "@@:@@@")
    }
}
