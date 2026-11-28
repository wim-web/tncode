import AppKit
import SwiftUI
import XCTest
@testable import tncode

@MainActor
final class CommitWritingTests: XCTestCase {
    func testCommitWritingThroughOffscreenChangesAndPinnedPi() async throws {
        try requireTestDesktop()
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PI_COMMIT_WRITING_ROOT"], let origin = env["PI_COMMIT_WRITING_ORIGIN"],
              let node = env["PI_COMMIT_WRITING_NODE"], let worker = env["PI_COMMIT_WRITING_WORKER"] else {
            throw XCTSkip("Run scripts/verify-commit-writing.mjs for the Pi loopback test.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let workspace = root.appendingPathComponent("workspace")
        let repo = root.appendingPathComponent("repo")
        let topic = root.appendingPathComponent("topic")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        @discardableResult
        func git(_ directory: URL, _ args: String...) async throws -> String {
            let result = try await GitWorkspace(path: directory.path).run(args, cancellable: true)
            return String(decoding: result.output.bytes, as: UTF8.self)
        }
        func write(_ content: String, to path: String, in directory: URL) throws {
            try (content + "\n").write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        func selectedPatch() async throws -> String {
            try await git(topic, "diff", "--no-color", "--no-ext-diff", "HEAD", "--", "selected.txt")
        }
        func assertCommit(_ subject: String, body: String = "") async throws {
            let subjectOnDisk = try await git(topic, "log", "-1", "--format=%s")
            let bodyOnDisk = try await git(topic, "log", "-1", "--format=%b")
            let changed = try await git(topic, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD")
            XCTAssertEqual(subjectOnDisk, subject + "\n")
            XCTAssertEqual(bodyOnDisk, body.isEmpty ? "\n" : body + "\n\n")
            XCTAssertEqual(changed, "selected.txt\n")
            print("git log subject=\(subjectOnDisk.debugDescription) body=\(bodyOnDisk.debugDescription)")
        }

        try await git(repo, "init", "--template=", "-b", "main")
        try await git(repo, "config", "user.name", "Fixture")
        try await git(repo, "config", "user.email", "fixture@example.invalid")
        try await git(repo, "config", "commit.gpgsign", "false")
        try write("selected-base", to: "selected.txt", in: repo)
        try await git(repo, "add", "selected.txt")
        try await git(repo, "commit", "-m", "Related repository subject")
        try write("excluded-base", to: "excluded.txt", in: repo)
        try await git(repo, "add", "excluded.txt")
        try await git(repo, "commit", "-m", "Unrelated repository subject", "-m", "Unrelated repository body")
        let main = try await git(repo, "rev-parse", "HEAD")
        try await git(repo, "worktree", "add", "-b", "topic", topic.path)
        try write("excluded staged sentinel", to: "excluded.txt", in: topic)
        try await git(topic, "add", "excluded.txt")
        try write("excluded working sentinel", to: "excluded.txt", in: topic)
        let excludedIndex = try await git(topic, "show", ":excluded.txt")
        let index = try await git(topic, "rev-parse", "--path-format=absolute", "--git-path", "index")
        let indexURL = URL(fileURLWithPath: index.trimmingCharacters(in: .newlines))

        let inherited = ModelSettings(provider: .local, model: "inherited-model", endpoint: origin + "/inherited/v1")
        let dedicated = ModelSettings(provider: .local, model: "dedicated-writer", endpoint: origin + "/override/v1")
        let otherChoice = ModelSettings(provider: .local, model: "current-workspace-default", endpoint: dedicated.endpoint)
        var thread = Conversation(id: UUID(), title: "Private thread sentinel",
                                  location: .worktree(path: topic.path, base: "main"),
                                  isDraft: false, composerText: "Private draft sentinel")
        thread.historyModel = inherited
        thread.modelSelection = otherChoice
        let project = Project(id: UUID(), path: repo.path, title: "Fixture", conversations: [thread],
                              selectedConversation: thread.id, modelOverride: otherChoice)
        try WorkspaceStore(root: workspace).save(Workspace(projects: [project], selectedProject: project.id,
                                                           model: otherChoice, welcomeCompleted: true))
        let location = try XCTUnwrap(WorkspaceFilesLocation(thread: thread, project: project))
        var credentialReads: [String] = []
        var processStarts = 0
        func launch() -> WorkspaceModel {
            WorkspaceModel(root: workspace, keychainService: "Fixture", credentialExists: { _ in true },
                           readCredential: { account in
                credentialReads.append(account)
                switch account {
                case inherited.account: return "private-inherited-writer-fixture-key"
                case dedicated.account: return "private-override-writer-fixture-key"
                default: return nil
                }
            }, makeProcess: { config, cwd in
                processStarts += 1
                XCTAssertEqual(cwd, topic.path)
                return try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: node), arguments: [worker])
            })
        }
        func changes(_ model: WorkspaceModel) throws -> OffscreenCommitHost {
            try OffscreenCommitHost(SourceControlView(location: location, model: model, openBranch: {},
                                                   copyBranch: { _ in }, openFile: { _ in }))
        }
        func prepare(_ ui: OffscreenCommitHost) async throws {
            try await ui.press("git-review-scope")
            try await ui.press("git-review-scope-uncommitted")
            try await ui.press("git-include-excluded.txt")
            try await ui.until("one selected file") { ui.text("git-selection-count").contains("1 of 2 selected") }
        }
        func capture(_ number: Int, model: ModelSettings, patch: String) throws -> String {
            let file = root.appendingPathComponent("request-\(number)")
            let body = try JSONDecoder().decode(CommitWireRequest.self, from: Data(contentsOf: file))
            XCTAssertEqual(body.model, model.model)
            XCTAssertEqual(body.route, model == inherited ? "/inherited/v1/chat/completions" : "/override/v1/chat/completions")
            XCTAssertTrue(body.tools?.isEmpty ?? true)
            XCTAssertEqual(body.messages.map(\.role), ["system", "user"])
            let user = try XCTUnwrap(body.messages.last?.content)
            XCTAssertEqual(user, patch)
            let system = try XCTUnwrap(body.messages.first?.content)
            XCTAssertTrue(system.contains("Return a JSON object with keys: subject, body."))
            XCTAssertFalse(system.contains("Private"))
            return system
        }
        func assertOwner(_ model: WorkspaceModel) {
            XCTAssertEqual(model.effectiveModel, inherited)
            XCTAssertEqual(model.conversation?.historyModel, inherited)
            XCTAssertEqual(model.conversation?.modelSelection, otherChoice)
            XCTAssertEqual(model.conversation?.composerText, "Private draft sentinel")
        }

        try write("selected wire sentinel one", to: "selected.txt", in: topic)
        weak var firstModel: WorkspaceModel?
        do {
            let model = launch()
            if let failure = model.startupFailure { throw failure }
            firstModel = model
            assertOwner(model)
            let ui = try changes(model)
            defer { ui.close(); XCTAssertTrue(model.terminate()) }
            try await prepare(ui)
            try await ui.setText("Typed subject", id: "git-commit-message")
            try await ui.setText("", id: "git-commit-message")
            XCTAssertEqual(processStarts, 0)
            XCTAssertTrue(credentialReads.isEmpty)
            let patch = try await selectedPatch()
            try await ui.press("git-commit")
            try await ui.until("commit reloaded") { ui.element("git-include-selected.txt") == nil }
            try await assertCommit("Describe the selected change")
            let prompt = try capture(0, model: inherited,
                                     patch: "Recent commit subjects for the selected paths:\nRelated repository subject\n\nSelected patch:\n" + patch)
            XCTAssertTrue(prompt.contains("Follow the repository's established commit message style"))
            try model.saveCommitWritingSettings(.init(style: .custom, customInstructions: "  Put two short bullets in the body. \n",
                                                       writerModel: dedicated))
            XCTAssertEqual(model.commitWritingSettings.customInstructions, "Put two short bullets in the body.")
            XCTAssertEqual(processStarts, 1)
            XCTAssertEqual(Set(credentialReads), [inherited.account])
            assertOwner(model)
        }
        for _ in 0..<100 where firstModel != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(firstModel)

        try write("selected wire sentinel two", to: "selected.txt", in: topic)
        let model = launch()
        if let failure = model.startupFailure { throw failure }
        defer { XCTAssertTrue(model.terminate()) }
        assertOwner(model)
        XCTAssertEqual(model.commitWritingSettings, .init(style: .custom, customInstructions: "Put two short bullets in the body.",
                                                           writerModel: dedicated))
        let ui = try changes(model)
        defer { ui.close() }
        try await prepare(ui)
        let customPatch = try await selectedPatch()
        try await ui.press("git-commit")
        try await ui.until("custom commit reloaded") { ui.element("git-include-selected.txt") == nil }
        let custom = try capture(1, model: dedicated, patch: customPatch)
        XCTAssertTrue(custom.hasSuffix("Additional instructions:\nPut two short bullets in the body."))
        try await assertCommit("Document the selected change", body: "- First detail\n- Second detail")
        assertOwner(model)

        try write("selected pending sentinel", to: "selected.txt", in: topic)
        try await ui.press("git-refresh")
        try await ui.until("pending selected file") { ui.text("git-selection-count").contains("1 of 2 selected") }
        let pendingHead = try await git(topic, "rev-parse", "HEAD")
        let pendingIndex = try Data(contentsOf: indexURL)
        let pendingPatch = try await selectedPatch()
        for error in ["fixture denied the writer", "did not return a valid commit message"] {
            try await ui.press("git-commit")
            try await ui.until(error) { ui.text("git-error").contains(error) }
            XCTAssertTrue(ui.text("git-selection-count").contains("1 of 2 selected"))
            XCTAssertEqual(try Data(contentsOf: indexURL), pendingIndex)
        }
        try await ui.press("git-commit")
        try await ui.until("held request") { FileManager.default.fileExists(atPath: root.appendingPathComponent("request-4").path) }
        try await ui.press("git-commit-cancel")
        try await ui.until("Pi stream cancelled") { FileManager.default.fileExists(atPath: root.appendingPathComponent("closed-4").path) }
        try await ui.until("commit ready after cancellation") { ui.element("git-commit")?.isAccessibilityEnabled?() == true }
        let afterErrors = try await git(topic, "rev-parse", "HEAD")
        XCTAssertEqual(afterErrors, pendingHead)
        XCTAssertEqual(try Data(contentsOf: indexURL), pendingIndex)
        XCTAssertTrue(ui.text("git-selection-count").contains("1 of 2 selected"))
        for number in 2...4 {
            XCTAssertEqual(try capture(number, model: dedicated, patch: pendingPatch), custom)
        }
        assertOwner(model)

        try model.saveCommitWritingSettings(.init(style: .conventional, customInstructions: "Hidden instructions sentinel"))
        try await ui.press("git-commit")
        try await ui.until("conventional commit reloaded") { ui.element("git-include-selected.txt") == nil }
        let conventional = try capture(5, model: inherited, patch: pendingPatch)
        XCTAssertTrue(conventional.contains("Use Conventional Commits when generating commit subjects"))
        XCTAssertFalse(conventional.contains("Hidden instructions sentinel"))
        try await assertCommit("fix(git): preserve the excluded staging")

        model.openSettings(.sourceControl)
        let request = try XCTUnwrap(model.settingsRequest)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CommitWritingTests.\(UUID())"))
        let settings = try OffscreenCommitHost(SettingsView(model: model, appearance: AppearanceSettings(defaults: defaults),
                                                        browserDefaults: defaults, request: request, openWelcome: {}))
        defer { settings.close() }
        try await settings.press("reset-commit-writing-style")
        try await settings.press("save-commit-writing")
        XCTAssertEqual(model.commitWritingSettings, CommitWritingSettings())
        XCTAssertEqual(processStarts, 6)
        let saved = try JSONDecoder().decode(Workspace.self, from: Data(
            contentsOf: workspace.appendingPathComponent(WorkspaceStore.indexName)
        ))
        XCTAssertNil(saved.commitWriting)
        XCTAssertEqual(saved.effectiveModel, inherited)
        assertOwner(model)

        try write("selected after reset sentinel", to: "selected.txt", in: topic)
        try await ui.press("git-refresh")
        try await ui.until("selected file after reset") { ui.text("git-selection-count").contains("1 of 2 selected") }
        let resetPatch = try await selectedPatch()
        try await ui.press("git-commit")
        try await ui.until("default commit reloaded") { ui.element("git-include-selected.txt") == nil }
        let resetPrompt = try capture(6, model: inherited,
                                      patch: "Recent commit subjects for the selected paths:\n" +
                                      "fix(git): preserve the excluded staging\nDocument the selected change\nDescribe the selected change\n" +
                                      "Related repository subject\n\nSelected patch:\n" + resetPatch)
        XCTAssertTrue(resetPrompt.contains("Follow the repository's established commit message style"))
        try await assertCommit("Describe the selected change " + String(repeating: "🌱", count: 21))
        let stagedAfter = try await git(topic, "show", ":excluded.txt")
        XCTAssertEqual(stagedAfter, excludedIndex)
        XCTAssertEqual(try String(contentsOf: topic.appendingPathComponent("excluded.txt"), encoding: .utf8),
                       "excluded working sentinel\n")

        try write("manual selected sentinel", to: "selected.txt", in: topic)
        try await ui.press("git-refresh")
        try await ui.until("manual selected file") { ui.text("git-selection-count").contains("1 of 2 selected") }
        let manual = "fix(git): Keep my manual subject."
        try await ui.setText(manual, id: "git-commit-message")
        try await ui.press("git-commit")
        try await ui.until("manual commit reloaded") { ui.element("git-include-selected.txt") == nil }
        try await assertCommit(manual)
        XCTAssertEqual(processStarts, 7)
        var credentialRoutes: [String] = []
        for account in credentialReads where account != credentialRoutes.last {
            credentialRoutes.append(account)
        }
        XCTAssertEqual(credentialRoutes, [inherited.account, dedicated.account, inherited.account])
        let original = try await git(repo, "rev-parse", "HEAD")
        XCTAssertEqual(original, main)
        assertOwner(model)
        print("Offscreen menu, settings edits and reset, and manual commit started no Pi processes.")
        print("Writer override survived relaunch. Failure and cancellation preserved HEAD, index, and file selection.")
    }
}

private struct CommitWireRequest: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }

    let route: String
    let model: String
    let messages: [Message]
    let tools: [String]?
}

@MainActor
private final class OffscreenCommitHost {
    private let app = NSApplication.shared
    private let policy: NSApplication.ActivationPolicy
    private let panel: CommitWritingPanel
    private let host: NSHostingView<AnyView>

    init(_ view: some View) throws {
        try requireTestDesktop()
        policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2_000, y: 0)
        panel = CommitWritingPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 820, height: 750)),
                                   styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(view))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(panel.frame) })
        panel.orderBack(nil)
    }

    func close() {
        host.rootView = AnyView(EmptyView())
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        app.setActivationPolicy(policy)
    }

    func element(_ id: String) -> AnyObject? {
        elements(from: host).first { $0.accessibilityIdentifier?() == id }
    }

    private func elements(from root: AnyObject) -> [AnyObject] {
        var visited: [ObjectIdentifier: AnyObject] = [:]
        var pending = [root]
        while let node = pending.popLast() {
            guard visited.updateValue(node, forKey: ObjectIdentifier(node)) == nil else { continue }
            pending.append(contentsOf: (node.accessibilityChildren?() ?? []).map { $0 as AnyObject })
        }
        return Array(visited.values)
    }

    func text(_ id: String) -> String {
        guard let node = element(id) else { return "" }
        return elements(from: node).flatMap { element in
            let selector = NSSelectorFromString("accessibilityValue")
            let value = element.responds?(to: selector) == true
                ? element.perform?(selector)?.takeUnretainedValue() : nil
            return [element.accessibilityLabel?(), element.accessibilityTitle?(), value as? String].compactMap { $0 }
        }.joined(separator: " ")
    }

    func press(_ id: String) async throws {
        try await until(id) { element(id)?.isAccessibilityEnabled?() == true }
        XCTAssertEqual(element(id)?.accessibilityPerformPress?(), true, id)
        await Task.yield()
    }

    func setText(_ value: String, id: String) async throws {
        func findField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.accessibilityIdentifier() == id { return field }
            for child in view.subviews {
                if let field = findField(in: child) { return field }
            }
            return nil
        }
        try await until(id) { findField(in: host) != nil }
        let field = try XCTUnwrap(findField(in: host))
        field.setAccessibilityValue(value)
        try await until("updated \(id)") { field.stringValue == value }
    }

    func until(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let controls = elements(from: host).compactMap { $0.accessibilityIdentifier?() }.filter { !$0.isEmpty }
        XCTFail("Timed out waiting for \(description). Controls:\n\(controls.map { "\($0) \(text($0))" }.joined(separator: "\n"))")
        throw WorkspaceError("Timed out waiting for \(description).")
    }
}

private final class CommitWritingPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
