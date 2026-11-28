import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import tncode

@MainActor
final class WorkspaceFilePaletteTests: XCTestCase {
    func testCheckoutSearchMatchesPathsAndTextWithReferenceOptions() async throws {
        let fixture = try await Repository()
        defer { fixture.remove() }
        let location = try XCTUnwrap(WorkspaceFilesLocation(thread: fixture.alpha, project: fixture.project))
        func search(_ mode: WorkspaceFileSearch.Mode, _ query: String,
                    _ options: WorkspaceFileSearch.Options = .init()) async throws -> WorkspaceFileSearch.Results {
            try await WorkspaceFileSearch(location: location, mode: mode, query: query, options: options).run()
        }

        let paths = try await search(.files, "@./SR/LGT")
        XCTAssertEqual(paths.matches.map(\.destination.target.path), ["src/log.txt"])
        let exact = try await search(.files, "log.txt")
        XCTAssertEqual(exact.matches.first?.destination.target.path, "log.txt")
        let initial = try await search(.files, "")
        let listed = Set(initial.matches.map(\.destination.target.path))
        XCTAssertTrue(listed.isSuperset(of: ["src/log.txt", "other/log.txt", "binary.txt"]))
        XCTAssertTrue(listed.isDisjoint(with: ["ignored.txt", "extra-ignored.txt", "outside.txt", "outside-folder/outside.txt"]))

        let defaults = try await search(.contents, "orbital-lantern")
        XCTAssertEqual(defaults.matches.map(\.destination.target.path), ["other/log.txt", "src/log.txt", "src/log.txt"])
        XCTAssertEqual(defaults.matches.compactMap(\.destination.line), [1, 3, 5])
        XCTAssertEqual(defaults.matches[1].snippet, "Alpha line OrBiTaL-lantern")

        let caseSensitive = try await search(.contents, "orbital-lantern", .init(caseSensitive: true))
        XCTAssertEqual(caseSensitive.matches.compactMap(\.destination.line), [1, 5])
        let wholeWord = try await search(.contents, "orbital-lantern", .init(wholeWord: true))
        XCTAssertEqual(wholeWord.matches.compactMap(\.destination.line), [3, 5])
        let whitespace = try await search(.contents, " line OrBiTaL-lantern")
        XCTAssertEqual(whitespace.matches.compactMap(\.destination.line), [3])
        let regex = try await search(.contents, "^alpha line orbital-.*$", .init(regex: true))
        XCTAssertEqual(regex.matches.compactMap(\.destination.line), [3])
        let invalid = try await search(.contents, "literal[", .init(regex: true))
        XCTAssertTrue(invalid.invalidRegex)
        XCTAssertEqual(invalid.matches.compactMap(\.destination.line), [4])
        try "one\r\n\r\nthree\r\n".write(to: fixture.alphaCheckout.appending(path: "blank-lines.txt"),
                                           atomically: true, encoding: .utf8)
        let blankLines = try await search(.contents, "^$", .init(regex: true))
        XCTAssertEqual(blankLines.matches.map(\.destination.target.path), ["blank-lines.txt"])
        XCTAssertEqual(blankLines.matches.compactMap(\.destination.line), [2])

        for number in 0..<6 {
            try String(repeating: "cap-marker\n", count: 101).write(
                to: fixture.alphaCheckout.appending(path: "cap-\(number).txt"), atomically: true, encoding: .utf8
            )
        }
        let limited = try await search(.contents, "cap-marker")
        XCTAssertTrue(limited.limited)
        XCTAssertEqual(limited.matches.count, 500)
        XCTAssertEqual(limited.matches.last?.destination.line, 100)
    }

    func testNativePaletteReturnsAndOpensOnlyTheSelectedCheckout() async throws {
        let fixture = try await Repository()
        defer { fixture.remove() }
        let app = try OffscreenWorkspace(fixture: fixture)
        defer { app.close() }

        try await app.openPalette(">go to file")
        try await app.enterMode("project-file-picker", command: "go-to-file")
        try app.type("src/log.txt")
        try await app.waitFor("visible path row") { app.element("command-palette-file-result-src/log.txt") != nil }
        try app.key(kVK_Escape, "\u{1b}")
        try await app.waitFor("file picker returned to the parent query") {
            app.element("command-palette") != nil && app.input?.string == ">go to file"
        }
        try await app.enterMode("project-file-picker", command: "go-to-file")
        try app.type("src/log.txt")
        try await app.waitFor("visible Alpha path") { app.element("command-palette-file-result-src/log.txt") != nil }
        try app.key(kVK_Return, "\r")
        try await app.waitFor("Alpha document in Files") { app.editor?.string == Repository.alphaText }
        let editor = try XCTUnwrap(app.editor)
        XCTAssertEqual(app.model.draft, "Keep Alpha composer")

        XCTAssertTrue(app.window.makeFirstResponder(editor))
        editor.insertText(" (unsaved)", replacementRange: (editor.string as NSString).range(of: "😀").atEnd)
        let dirty = editor.string
        XCTAssertNotEqual(dirty, Repository.alphaText)
        let alphaFile = fixture.alphaCheckout.appending(path: "src/log.txt")
        try (Repository.alphaText + "External change\n").write(to: alphaFile, atomically: true, encoding: .utf8)
        try await app.waitFor("unsaved Alpha editor") { app.element("files-unsaved") != nil }

        try await app.openPalette(">search project contents")
        try await app.enterMode("project-content-search", command: "search-project-contents")
        try app.type("orbital-lantern")
        try await app.waitFor("Alpha content hit on line 3") { app.element("command-palette-content-result-src/log.txt:3") != nil }
        try app.key(kVK_Escape, "\u{1b}")
        try await app.waitFor("content picker returned to its parent query") {
            app.element("command-palette") != nil && app.input?.string == ">search project contents"
        }
        try await app.enterMode("project-content-search", command: "search-project-contents")
        try app.type("discarded query")
        try app.type("orbital-lantern")
        try await app.waitFor("content hits replaced the old query") {
            app.element("command-palette-content-result-other/log.txt:1") != nil &&
                app.element("command-palette-content-result-src/log.txt:3") != nil
        }
        try app.key(kVK_DownArrow, "\u{f701}")
        try app.key(kVK_Return, "\r")
        try await app.waitFor("exact Alpha line selected") { app.selectedLine == "Alpha line OrBiTaL-lantern" }
        XCTAssertTrue(app.editor === editor)
        XCTAssertEqual(app.editor?.string, dirty)
        XCTAssertEqual(app.model.draft, "Keep Alpha composer")
        XCTAssertNotNil(app.element("files-unsaved"))

        try await app.openPalette(">search project contents")
        try await app.enterMode("project-content-search", command: "search-project-contents")
        try app.type("orbital-lantern")
        try await app.waitFor("Alpha row before switching checkouts") {
            app.element("command-palette-content-result-src/log.txt:3") != nil
        }
        app.model.selectConversation(fixture.beta.id, in: fixture.project.id)
        XCTAssertEqual(app.model.conversation?.id, fixture.beta.id)
        try app.key(kVK_Return, "\r")
        XCTAssertTrue(app.model.showingCommandPalette)
        try await app.waitFor("old result gone while the child remains open") {
            app.element("project-content-search") != nil &&
                app.element("command-palette-content-result-src/log.txt:\(Repository.betaLine)") != nil
        }
        XCTAssertNil(app.element("command-palette-content-result-src/log.txt:3"))
        XCTAssertNil(app.editor)
        XCTAssertEqual(app.model.draft, "Keep Beta composer")

        try app.type("beta-only phrase")
        try await app.waitFor("only Beta's content row appears") {
            app.element("command-palette-content-result-src/log.txt:\(Repository.betaLine)") != nil
        }
        try app.key(kVK_Return, "\r")
        try await app.waitFor("Beta text and exact line in Files") {
            app.editor?.string == Repository.betaText && app.selectedLine == "beta-only phrase orbital-lantern"
        }
        let betaEditor = try XCTUnwrap(app.editor)
        let betaScroll = try XCTUnwrap(betaEditor.enclosingScrollView)
        try await app.waitFor("Beta's selected line scrolled into view") { betaScroll.contentView.bounds.minY > 0 }
        let layout = try XCTUnwrap(betaEditor.layoutManager)
        let container = try XCTUnwrap(betaEditor.textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: betaEditor.selectedRange(), actualCharacterRange: nil)
        let lineY = layout.boundingRect(forGlyphRange: glyphs, in: container).midY + betaEditor.textContainerOrigin.y
        let visible = betaScroll.documentVisibleRect
        XCTAssertTrue((visible.minY...visible.maxY).contains(lineY))
        XCTAssertEqual(app.model.draft, "Keep Beta composer")
        app.model.selectConversation(fixture.alpha.id, in: fixture.project.id)
        try await app.waitFor("Alpha kept the dirty buffer") { app.editor?.string == dirty }
        XCTAssertEqual(app.model.draft, "Keep Alpha composer")
        XCTAssertEqual(try String(contentsOf: alphaFile, encoding: .utf8), Repository.alphaText + "External change\n")
    }

    func testWorkspaceSearchShortcutsSwitchModesAndOpenTheLinkedCheckout() async throws {
        let fixture = try await Repository()
        defer { fixture.remove() }
        let app = try OffscreenWorkspace(fixture: fixture)
        defer { app.close() }
        let composer = try await app.focusComposer()

        try app.goToFile()
        try await app.waitForMode("project-file-picker")
        try app.type("discarded file query")
        try app.goToFile()
        try await app.waitFor("same shortcut closes and restores the composer") {
            app.window.attachedSheet == nil && composer.currentEditor() === app.window.firstResponder
        }
        XCTAssertEqual(app.model.draft, "Keep Alpha composer")

        try app.searchContents()
        try await app.waitForMode("project-content-search")
        try app.type("discarded content query")
        try app.key(kVK_Escape, "\u{1b}")
        try await app.waitForMode("command-palette")
        try app.type(">search project contents")
        try await app.enterMode("project-content-search", command: "search-project-contents")
        try app.searchContents()
        try await app.waitFor("same shortcut closes an action-opened search") { app.window.attachedSheet == nil }

        try await app.openPalette(">search project contents")
        try await app.enterMode("project-content-search", command: "search-project-contents")
        try app.goToFile()
        try await app.waitForMode("project-file-picker")
        try app.key(kVK_Escape, "\u{1b}")
        try await app.waitForMode("command-palette")

        try app.type("discarded command query")
        try app.goToFile()
        try await app.waitForMode("project-file-picker")
        try app.type("discarded file query")
        try app.searchContents()
        try await app.waitForMode("project-content-search")
        try app.type("discarded content query")
        try app.key(kVK_ANSI_K, "k", modifiers: .command)
        try await app.waitForMode("command-palette")

        try app.goToFile()
        try await app.waitForMode("project-file-picker")
        try app.type("src/log.txt")
        try await app.waitFor("exact path result") { app.element("command-palette-file-result-src/log.txt") != nil }
        try app.key(kVK_Return, "\r")
        try await app.waitFor("selected Alpha file opened in Files") {
            app.window.attachedSheet == nil && app.editor?.string == Repository.alphaText
        }
        let editor = try XCTUnwrap(app.editor)
        XCTAssertTrue(app.window.makeFirstResponder(editor))

        try app.searchContents()
        try await app.waitForMode("project-content-search")
        try app.type("orbital-lantern")
        try await app.waitFor("content results with duplicate filenames") {
            app.element("command-palette-content-result-other/log.txt:1") != nil &&
                app.element("command-palette-content-result-src/log.txt:3") != nil
        }
        try app.key(kVK_DownArrow, "\u{f701}")
        try app.key(kVK_Return, "\r")
        try await app.waitFor("selected Alpha file and exact line") {
            app.window.attachedSheet == nil && app.selectedLine == "Alpha line OrBiTaL-lantern"
        }
        XCTAssertTrue(app.editor === editor)
        XCTAssertEqual(app.editor?.string, Repository.alphaText)
        XCTAssertEqual(app.model.draft, "Keep Alpha composer")
    }

    func testWorkspaceSearchShortcutsRespectTerminalCompositionAndSettingsFocus() async throws {
        let fixture = try await Repository()
        defer { fixture.remove() }
        let app = try OffscreenWorkspace(fixture: fixture)
        defer { app.close() }
        let composer = try await app.focusComposer()
        let editor = try XCTUnwrap(composer.currentEditor() as? ComposerTextField.Editor)
        let end = NSRange(location: editor.string.utf16.count, length: 0)
        editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: end)
        XCTAssertTrue(editor.hasMarkedText())
        let marked = editor.markedRange()
        try app.goToFile()
        try app.searchContents()
        XCTAssertFalse(app.model.showingCommandPalette)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertTrue(app.window.firstResponder === editor)
        editor.insertText("", replacementRange: marked)

        let terminal = TerminalSessionView(frame: NSRect(x: 0, y: 0, width: 70, height: 48))
        terminal.setPresentation(true, focusRequest: nil)
        app.window.contentView?.addSubview(terminal)
        XCTAssertTrue(app.window.makeFirstResponder(terminal))
        try app.goToFile()
        try app.searchContents()
        XCTAssertFalse(app.model.showingCommandPalette)
        XCTAssertTrue(app.window.firstResponder === terminal)
        terminal.removeFromSuperview()

        app.model.openSettings()
        try await app.waitFor("settings field takes focus") { app.element("settings") != nil && app.input != nil }
        let settings = try XCTUnwrap(app.window.attachedSheet)
        let settingsEditor = try XCTUnwrap(app.input)
        try app.type("Model")
        try app.goToFile()
        try app.searchContents()
        XCTAssertTrue(settings.firstResponder === settingsEditor)
        XCTAssertEqual(settingsEditor.string, "Model")
        XCTAssertFalse(app.model.showingCommandPalette)

        app.model.settingsRequest = nil
        try app.goToFile(in: app.window)
        try app.searchContents(in: app.window)
        XCTAssertFalse(app.model.showingCommandPalette)
        try await app.waitFor("settings sheet closed") { app.window.attachedSheet == nil }

        try app.goToFile()
        try await app.waitForMode("project-file-picker")
        let paletteEditor = try XCTUnwrap(app.input)
        paletteEditor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange())
        XCTAssertTrue(paletteEditor.hasMarkedText())
        let paletteMarked = paletteEditor.markedRange()
        try app.goToFile()
        try app.searchContents()
        XCTAssertTrue(app.model.showingCommandPalette)
        XCTAssertNotNil(app.element("project-file-picker"))
        XCTAssertEqual(paletteEditor.markedRange(), paletteMarked)
        paletteEditor.insertText("", replacementRange: paletteMarked)
        try app.goToFile()
        try await app.waitFor("file picker closes after composition ends") { app.window.attachedSheet == nil }
        XCTAssertEqual(app.model.draft, "Keep Alpha composer")
    }

    func testNativePaletteOpensTheSelectedSettingWithoutChangingTheDraft() async throws {
        let fixture = try await Repository()
        defer { fixture.remove() }
        let app = try OffscreenWorkspace(fixture: fixture)
        defer { app.close() }
        let width = "command-palette-setting-appearance-chat-width"
        let defaults = "command-palette-setting-appearance-restore-defaults"
        _ = try await app.focusComposer()

        try await app.openPalette("width")
        try await app.waitFor("Chat width and Restore Defaults results") {
            app.element(width) != nil && app.element(defaults) != nil
        }
        try app.key(kVK_DownArrow, "\u{f701}")
        try app.key(kVK_Return, "\r")
        try await app.waitFor("Return opens the second result in Appearance") {
            app.element("settings-heading-appearance") != nil && app.element("appearance-restore-defaults") != nil
                && app.model.settingsRequest?.destination.anchor == .restoreAppearance
        }
        try app.key(kVK_Escape, "\u{1b}")

        try await app.openPalette("Interface font")
        try await app.waitFor("unavailable settings have no result") { app.element("command-palette-empty") != nil }
        try app.key(kVK_Escape, "\u{1b}")

        try await app.openPalette(">Chat width")
        try await app.waitFor("command-only search keeps settings out") { app.element("command-palette-empty") != nil }
        try app.key(kVK_Escape, "\u{1b}")
        try await app.waitFor("Escape leaves the workspace open") { app.window.attachedSheet == nil }
        XCTAssertNil(app.model.settingsRequest)

        try await app.openPalette("Chat width")
        try await app.waitFor("Chat width is visible") { app.element(width) != nil }
        try app.key(kVK_Return, "\r")
        try await app.waitFor("Chat width opens the actual Appearance picker") {
            app.element("settings-heading-appearance") != nil && app.element("appearance-chat-width") != nil
                && app.model.settingsRequest?.destination.anchor == .chatWidth
        }
        try app.key(kVK_Escape, "\u{1b}")

        try await app.openPalette("Model ID")
        try await app.waitFor("Model ID is visible") { app.element("command-palette-setting-model-id") != nil }
        try app.key(kVK_Return, "\r")
        try await app.waitFor("Model ID opens with the project scope and field focus") {
            app.element("settings-heading-model") != nil && app.element("model-settings-source") != nil &&
                app.input?.string == app.model.workspace.model.model
        }
        XCTAssertEqual(app.model.settingsRequest?.projectID, fixture.project.id)
        try app.type("unsaved alpha model")
        let appearance = try XCTUnwrap(app.element("settings-nav-appearance"))
        XCTAssertTrue(appearance.accessibilityPerformPress?() == true)
        try await app.waitFor("Settings shows Appearance") { app.element("settings-heading-appearance") != nil }
        let modelPage = try XCTUnwrap(app.element("settings-nav-model"))
        XCTAssertTrue(modelPage.accessibilityPerformPress?() == true)
        try await app.waitFor("the project edit survives visiting another settings page") {
            (app.element("model-id") as? NSAccessibilityProtocol)?.accessibilityValue() as? String == "unsaved alpha model"
        }
        XCTAssertNil(app.model.project?.modelOverride)
        XCTAssertEqual(app.model.conversation?.id, fixture.alpha.id)
        XCTAssertEqual(app.model.draft, "Keep Alpha composer")
    }

    func testWorkspaceSearchShortcutsReportMissingCheckout() async throws {
        let fixture = try await Repository()
        defer { fixture.remove() }
        let app = try OffscreenWorkspace(fixture: fixture)
        defer { app.close() }
        _ = try await app.focusComposer()
        try FileManager.default.removeItem(at: fixture.alphaCheckout)

        func hasMissingStatus() -> Bool {
            guard let status = app.element("command-palette-file-status") else { return false }
            let value = (status as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
            let text = (value as? String) ?? status.accessibilityLabel?()
            return text == "The file or folder is missing."
        }

        try app.goToFile()
        try await app.waitFor("file picker reports the missing checkout") {
            app.element("project-file-picker") != nil && hasMissingStatus()
        }
        try app.searchContents()
        try await app.waitForMode("project-content-search")
        try app.type("main")
        try await app.waitFor("content search reports the missing checkout", until: hasMissingStatus)
        try app.key(kVK_Return, "\r")
        XCTAssertTrue(app.model.showingCommandPalette)
        XCTAssertNil(app.editor)
        XCTAssertEqual(app.model.draft, "Keep Alpha composer")
    }

    private struct Repository {
        static let alphaText = "alpha 😀\r\nsome filler\r\nAlpha line OrBiTaL-lantern\r\nliteral[\r\nanother orbital-lantern\r\n"
        static let betaLine = 164
        static let betaText = "beta\n" + String(repeating: "just this checkout\n", count: betaLine - 2) +
            "beta-only phrase orbital-lantern\n"

        let root: URL
        let alphaCheckout: URL
        let betaCheckout: URL
        let alpha: Conversation
        let beta: Conversation
        let project: Project

        init() async throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let repo = root.appending(path: "repo")
            alphaCheckout = root.appending(path: "alpha")
            betaCheckout = root.appending(path: "beta")
            do {
                try FileManager.default.createDirectory(at: repo.appending(path: "src"), withIntermediateDirectories: true)
                let git = GitWorkspace(path: repo.path)
                _ = try await git.run(["init", "-qb", "main"])
                try "main\n".write(to: repo.appending(path: "src/log.txt"), atomically: true, encoding: .utf8)
                try "ignored.txt\n".write(to: repo.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
                try "extra-ignored.txt\n".write(to: repo.appending(path: ".ignore"), atomically: true, encoding: .utf8)
                _ = try await git.run(["add", "."])
                _ = try await git.run(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c",
                                       "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture"])
                _ = try await git.run(["worktree", "add", "-qb", "alpha", alphaCheckout.path])
                _ = try await git.run(["worktree", "add", "-qb", "beta", betaCheckout.path])
                try Self.alphaText.write(to: alphaCheckout.appending(path: "src/log.txt"), atomically: true, encoding: .utf8)
                try Self.betaText.write(to: betaCheckout.appending(path: "src/log.txt"), atomically: true, encoding: .utf8)
                try "root level\n".write(to: alphaCheckout.appending(path: "log.txt"), atomically: true, encoding: .utf8)
                try FileManager.default.createDirectory(at: alphaCheckout.appending(path: "other"), withIntermediateDirectories: false)
                for path in ["other/log.txt", "ignored.txt", "extra-ignored.txt"] {
                    try "myorbital-lanterns\n".write(to: alphaCheckout.appending(path: path), atomically: true, encoding: .utf8)
                }
                try Data("\u{0}orbital-lantern\n".utf8).write(to: alphaCheckout.appending(path: "binary.txt"))
                let outside = root.appending(path: "outside.txt")
                try "orbital-lantern\n".write(to: outside, atomically: true, encoding: .utf8)
                try FileManager.default.createSymbolicLink(at: alphaCheckout.appending(path: "outside.txt"), withDestinationURL: outside)
                try FileManager.default.createSymbolicLink(at: alphaCheckout.appending(path: "outside-folder"), withDestinationURL: root)
                alpha = Conversation(id: UUID(), title: "Alpha", location: .worktree(path: alphaCheckout.path, base: nil),
                                     isDraft: true, composerText: "Keep Alpha composer")
                beta = Conversation(id: UUID(), title: "Beta", location: .worktree(path: betaCheckout.path, base: nil),
                                    isDraft: true, composerText: "Keep Beta composer")
                project = Project(id: UUID(), path: repo.path, title: "Palette fixture",
                                  conversations: [alpha, beta], selectedConversation: alpha.id)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class Panel: NSPanel {
        override var canBecomeMain: Bool { false }
        override var canBecomeKey: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

        override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
            sheetWindow.alphaValue = 0
            super.beginSheet(sheetWindow, completionHandler: handler)
            sheetWindow.setFrameOrigin(frame.origin)
        }
    }

    private struct WorkspaceWithSettings: View {
        @ObservedObject var model: WorkspaceModel
        @ObservedObject var appearance: AppearanceSettings
        let defaults: UserDefaults
        let pasteboard: NSPasteboard

        var body: some View {
            WorkspaceView(model: model, chatWidthMode: appearance.chatWidth,
                          browserDefaults: defaults, workspacePasteboard: pasteboard)
                .sheet(item: $model.settingsRequest) { request in
                    SettingsView(model: model, appearance: appearance, browserDefaults: defaults,
                                 request: request, pasteboard: pasteboard, openWelcome: {})
                }
                .defaultAppStorage(defaults)
        }
    }

    @MainActor
    private final class OffscreenWorkspace {
        let model: WorkspaceModel
        let window: NSWindow
        private let app = NSApplication.shared
        private let policy: NSApplication.ActivationPolicy
        private let defaults: UserDefaults
        private let namespace = "WorkspaceFilePaletteTests.\(UUID())"
        private let pasteboard = NSPasteboard.withUniqueName()

        init(fixture: Repository) throws {
            let state = fixture.root.appending(path: "state")
            try WorkspaceStore(root: state).save(Workspace(projects: [fixture.project], selectedProject: fixture.project.id,
                                                           welcomeCompleted: true))
            model = WorkspaceModel(root: state, keychainService: namespace, credentialExists: { _ in false },
                                   readCredential: { _ in nil }) { _, _ in throw WorkspaceError("Fixture has no agent.") }
            defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
            policy = app.activationPolicy()
            app.setActivationPolicy(.prohibited)
            app.finishLaunching()
            if NSScreen.screens.isEmpty {
                app.setActivationPolicy(policy)
                throw XCTSkip("The offscreen AppKit sheet needs WindowServer.")
            }
            let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
            let panel = Panel(contentRect: NSRect(origin: origin, size: CGSize(width: 1100, height: 740)),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let appearance = AppearanceSettings(defaults: defaults)
            appearance.chatWidth = .full
            panel.contentView = NSHostingView(rootView: WorkspaceWithSettings(
                model: model, appearance: appearance, defaults: defaults, pasteboard: pasteboard
            ))
            panel.setFrameOrigin(origin)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(panel.frame) })
            panel.orderBack(nil)
            window = panel
        }

        func close() {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentView = nil
            window.close()
            model.terminate()
            defaults.removePersistentDomain(forName: namespace)
            pasteboard.releaseGlobally()
            app.setActivationPolicy(policy)
        }

        var input: NSTextView? {
            guard let editor = window.attachedSheet?.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
            return editor
        }

        var editor: NSTextView? { element("files-editor") as? NSTextView }

        var selectedLine: String? { editor.map { ($0.string as NSString).substring(with: $0.selectedRange()) } }

        func type(_ value: String) throws {
            let fieldEditor = try XCTUnwrap(input)
            fieldEditor.insertText(value, replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
        }

        func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) throws {
            let target = target ?? window.attachedSheet ?? window
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: target.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
            ))
            app.sendEvent(event)
        }

        func goToFile(in target: NSWindow? = nil) throws {
            try key(kVK_ANSI_P, "p", modifiers: .command, in: target)
        }

        func searchContents(in target: NSWindow? = nil) throws {
            try key(kVK_ANSI_F, "F", modifiers: [.command, .shift], in: target)
        }

        func focusComposer() async throws -> ComposerTextField.Field {
            func composer(in view: NSView) -> ComposerTextField.Field? {
                if let field = view as? ComposerTextField.Field, field.accessibilityIdentifier() == "composer" { return field }
                return view.subviews.lazy.compactMap { composer(in: $0) }.first
            }
            try await waitFor("composer") { window.contentView.flatMap(composer(in:)) != nil }
            let field = try XCTUnwrap(window.contentView.flatMap(composer(in:)))
            XCTAssertTrue(window.makeFirstResponder(field))
            return field
        }

        func waitForMode(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) async throws {
            try await waitFor("\(identifier) with an empty query", file: file, line: line) {
                element(identifier) != nil && input?.string == ""
            }
        }

        func openPalette(_ query: String) async throws {
            try await waitFor("previous sheet closed") { window.attachedSheet == nil }
            try key(kVK_ANSI_K, "k", modifiers: .command)
            try await waitFor("parent palette field takes focus") { element("command-palette") != nil && input != nil }
            try type(query)
        }

        func enterMode(_ mode: String, command: String) async throws {
            try await waitFor(command) { element("command-palette-" + command) != nil }
            try key(kVK_Return, "\r")
            try await waitFor(mode) { element(mode) != nil && input?.string == "" }
        }

        func element(_ identifier: String) -> AnyObject? {
            var seen: Set<ObjectIdentifier> = []
            func find(_ node: AnyObject) -> AnyObject? {
                guard seen.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == identifier { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let result = find(child as AnyObject) { return result }
                }
                return nil
            }
            return (window.attachedSheet?.contentView).flatMap(find) ?? window.contentView.flatMap(find)
        }

        func waitFor(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                     until ready: () -> Bool) async throws {
            for _ in 0..<160 {
                window.contentView?.layoutSubtreeIfNeeded()
                if let sheet = window.attachedSheet {
                    XCTAssertEqual(sheet.alphaValue, 0)
                    sheet.contentView?.layoutSubtreeIfNeeded()
                }
                if ready() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
            throw WorkspaceError("Timed out waiting for \(description)")
        }
    }
}

private extension NSRange {
    var atEnd: NSRange { NSRange(location: NSMaxRange(self), length: 0) }
}
