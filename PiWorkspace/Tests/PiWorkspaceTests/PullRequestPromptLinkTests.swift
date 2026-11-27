import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class PullRequestPromptLinkTests: XCTestCase {
    func testOffscreenCheckoutReconfirmsHeadAndResumesOneOwnedWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let link = try fixture.link(prompt: "%E2%80%8EReview+the+changed+head")
        let checkout = "prompt-link-pr-checkout"
        let pending: PendingPullRequestCheckout
        weak var firstModel: WorkspaceModel?
        do {
            let model = fixture.open()
            firstModel = model
            defer { model.terminate() }
            XCTAssertNil(model.startupFailure)

            let originalIndex = try fixture.saved()
            let originalRefs = try fixture.refs()
            let originalWorktrees = try fixture.git("worktree", "list", "--porcelain")
            XCTAssertTrue(model.openPromptLink(link))
            let reviewID = model.promptLinkReview?.id
            XCTAssertTrue(model.openPromptLink(link))
            XCTAssertEqual(model.promptLinkReview?.id, reviewID)
            let panel = LinkPanel(model: model)
            defer { panel.close() }
            try await panel.waitFor(checkout)
            try panel.check("prompt-link-pull-request", includes: "fixture/repo#17")
            try panel.check("prompt-link-pr-title", includes: "Fixture pull request")
            try panel.check("prompt-link-pr-folder", includes: fixture.repo.path)
            try panel.check("prompt-link-pr-head", includes: fixture.oldHead)
            try panel.check("prompt-link-preview", includes: "Review the changed head")
            try await panel.waitFor("prompt-link-hidden-warning")
            XCTAssertEqual(try fixture.saved(), originalIndex)
            XCTAssertEqual(try fixture.refs(), originalRefs)
            XCTAssertEqual(try fixture.git("worktree", "list", "--porcelain"), originalWorktrees)
            XCTAssertEqual(model.conversation?.id, fixture.unrelatedDraft.id)

            try fixture.writePR(head: fixture.newHead)
            try panel.press(checkout)
            let error = "prompt-link-action-error"
            try await panel.waitFor(error, includes: "head changed")
            try panel.check("prompt-link-pr-head", includes: fixture.newHead)
            XCTAssertEqual(try fixture.saved(), originalIndex)
            XCTAssertEqual(try fixture.refs(), originalRefs)
            XCTAssertEqual(try fixture.git("worktree", "list", "--porcelain"), originalWorktrees)
            XCTAssertThrowsError(try fixture.git("cat-file", "-t", fixture.newHead))

            try fixture.installFailingPreparationHook()
            try panel.press(checkout)
            try await panel.waitFor(error, includes: "fixture rejects PR branch")
            XCTAssertEqual(model.conversation?.id, fixture.unrelatedDraft.id)
            pending = try XCTUnwrap(model.projects.first { $0.id == fixture.project.id }?.pendingPullRequestCheckouts?.first)
            XCTAssertEqual(pending.checkout.head, fixture.newHead)
            let worktrees = try await GitWorkspace(path: fixture.repo.path).worktrees()
            let interrupted = try XCTUnwrap(worktrees.first { $0.path == pending.checkout.path })
            XCTAssertNil(interrupted.branch)
            XCTAssertEqual(interrupted.head, fixture.newHead)
            XCTAssertEqual(model.projects.flatMap(\.conversations).count, 2)

            try fixture.removePreparationHook()
            let interruptedEdit = URL(fileURLWithPath: pending.checkout.path).appendingPathComponent("keep-this-edit")
            try Data("in-progress checkout edit".utf8).write(to: interruptedEdit)
            try panel.press(checkout)
            try await panel.waitFor(error, includes: "contains changes")
            XCTAssertEqual(try String(contentsOf: interruptedEdit, encoding: .utf8), "in-progress checkout edit")
            XCTAssertEqual(model.projects.flatMap(\.conversations).count, 2)
            XCTAssertEqual(model.projects.first { $0.id == fixture.project.id }?.pendingPullRequestCheckouts?.first?.checkout.owner,
                           pending.checkout.owner)
            try FileManager.default.removeItem(at: interruptedEdit)
            model.promptLinkReview = nil
        }

        // Resolve the link from disk with the pending checkout already present.
        for _ in 0..<100 where firstModel != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(firstModel)
        let reopened = fixture.open()
        defer { reopened.terminate() }
        XCTAssertNil(reopened.startupFailure)
        XCTAssertTrue(reopened.openPromptLink(link))
        let resumedPanel = LinkPanel(model: reopened)
        defer { resumedPanel.close() }
        try await resumedPanel.waitFor(checkout)
        try resumedPanel.press(checkout)
        try await resumedPanel.waitUntil("one prepared draft") { reopened.conversation?.id == pending.checkout.owner }
        XCTAssertNil(reopened.promptLinkReview)
        XCTAssertEqual(reopened.conversation?.id, pending.checkout.owner)
        XCTAssertEqual(reopened.project?.id, fixture.project.id)
        XCTAssertEqual(reopened.workingDirectory, pending.checkout.path)
        XCTAssertEqual(reopened.conversation?.isDraft, true)
        XCTAssertEqual(reopened.draft, "Review the changed head")
        XCTAssertEqual(reopened.conversation?.pullRequestLinks.map(\.reference.url.absoluteString), [fixture.prURL])
        XCTAssertNil(reopened.conversation?.composerSubmission)
        XCTAssertNil(reopened.project?.pendingPullRequestCheckouts)
        XCTAssertEqual(reopened.projects.flatMap(\.conversations).count, 3)
        XCTAssertEqual(try fixture.git(in: URL(fileURLWithPath: pending.checkout.path), "rev-parse", "HEAD"), fixture.newHead)
        XCTAssertEqual(try fixture.git("worktree", "list", "--porcelain").components(separatedBy: "worktree ").count, 4)
        try fixture.checkOriginalCheckouts(in: reopened)
        XCTAssertEqual(fixture.connectionDirectories, [pending.checkout.path])

        let preparedIndex = try fixture.saved()
        let preparedWorktrees = try fixture.git("worktree", "list", "--porcelain")
        XCTAssertTrue(reopened.openPromptLink(link))
        resumedPanel.showReview()
        try await resumedPanel.waitFor("reopen-prompt-link")
        try resumedPanel.check("prompt-link-title", includes: "This link is open")
        try resumedPanel.press("reopen-prompt-link")
        try await resumedPanel.waitFor("prompt-link-pr-open-thread")
        try resumedPanel.check("prompt-link-pr-folder", includes: GitWorkspace.canonicalCheckoutPath(pending.checkout.path))
        XCTAssertNil(resumedPanel.element(checkout))
        XCTAssertEqual(try fixture.saved(), preparedIndex)
        try resumedPanel.press("prompt-link-pr-open-thread")
        try await resumedPanel.waitUntil("linked draft reopening") { reopened.promptLinkReview == nil }
        XCTAssertEqual(reopened.conversation?.id, pending.checkout.owner)
        XCTAssertEqual(try fixture.git("worktree", "list", "--porcelain"), preparedWorktrees)
        XCTAssertEqual(reopened.projects.flatMap(\.conversations).count, 3)
    }

    func testOffscreenLinkedThreadKeepsDraftUntilExplicitReplacement() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_PROMPT_LINK_TEST_APP"] else {
            throw XCTSkip("Set PI_PROMPT_LINK_TEST_APP to exercise a saved Pi session.")
        }
        try await checkDraftReplacement(app: URL(fileURLWithPath: path), isDraft: false)
    }

    func testOffscreenUnsentPRDraftKeepsDraftUntilExplicitReplacement() async throws {
        let app = ProcessInfo.processInfo.environment["PI_PROMPT_LINK_TEST_APP"].map { URL(fileURLWithPath: $0) }
        try await checkDraftReplacement(app: app, isDraft: true)
    }

    private func checkDraftReplacement(app: URL?, isDraft: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let reference = try XCTUnwrap(GitHubPullRequestReference(url: fixture.prURL))
        var linked = Conversation(id: UUID(), title: "Existing PR thread", isDraft: isDraft,
                                  composerText: "Keep this follow-up",
                                  linkedPullRequests: [.init(reference: reference, title: "Fixture pull request")])
        let attachment = ComposerAttachment(id: UUID(), name: "review.txt",
                                            payload: .init(mimeType: "text/plain", data: Data("draft bytes".utf8)))
        linked.composerAttachments = [attachment]
        linked.queuedMessages = [.init(id: UUID(), text: "An earlier follow-up")]
        let history = try isDraft ? nil : app.map { try fixture.seedHistory(app: $0, thread: linked.id) }
        let savedMessages = try history?.messages()
        do {
            let store = try WorkspaceStore(root: fixture.workspace)
            var workspace = try store.load()
            workspace.model = ModelSettings(provider: .local, model: "pr-link-fixture", endpoint: "http://127.0.0.1:1/v1")
            workspace.projects[0].conversations.append(linked)
            try store.save(workspace)
        }
        let model = fixture.open(app: app)
        defer { model.terminate() }
        XCTAssertNil(model.startupFailure)
        let link = try fixture.link(prompt: "New+follow-up")
        let index = try fixture.saved()
        let worktrees = try fixture.git("worktree", "list", "--porcelain")
        XCTAssertTrue(model.openPromptLink(link))
        let review = try XCTUnwrap(model.promptLinkReview)
        guard case let .thread(target) = try await model.resolvePullRequestPromptLink(review) else {
            return XCTFail("Expected the existing linked PR thread.")
        }
        XCTAssertEqual(target.threadID, linked.id)
        let panel = LinkPanel(model: model)
        defer { panel.close() }
        try await panel.waitFor("prompt-link-pr-draft-conflict")
        try panel.check("prompt-link-pr-thread", includes: linked.title)
        try panel.check("prompt-link-pr-folder", includes: GitWorkspace.canonicalCheckoutPath(fixture.repo.path))
        XCTAssertEqual(try fixture.saved(), index)

        if let history {
            let file = URL(fileURLWithPath: history.historyPath)
            let original = try Data(contentsOf: file)
            let header = original.prefix(through: try XCTUnwrap(original.firstIndex(of: 10)))
            try header.write(to: file, options: .atomic)
            try panel.press("prompt-link-pr-open-thread")
            try await panel.waitUntil("empty submitted history rejected") {
                panel.element("prompt-link-action-error") != nil || model.promptLinkReview == nil
            }
            XCTAssertEqual(model.conversation?.id, fixture.unrelatedDraft.id)
            XCTAssertEqual(try fixture.saved(), index)
            XCTAssertEqual(try Data(contentsOf: file), header)
            try original.write(to: file, options: .atomic)
        }

        try panel.press("prompt-link-pr-open-thread")
        try await panel.waitUntil("linked thread") { model.promptLinkReview == nil }
        XCTAssertEqual(model.conversation?.id, linked.id)
        XCTAssertEqual(model.draft, linked.composerText)
        if let history {
            try await panel.waitUntil("existing Pi history") { model.messages.contains { $0.id == history.latestID } }
        }
        XCTAssertTrue(model.openPromptLink(link))
        panel.showReview()
        try await panel.waitFor("reopen-prompt-link")
        try panel.press("reopen-prompt-link")
        let replace = "prompt-link-pr-replace-draft"
        try await panel.waitFor(replace)
        try panel.press(replace)
        try await panel.waitUntil("replacement draft") { model.promptLinkReview == nil }
        XCTAssertEqual(model.conversation?.id, linked.id)
        XCTAssertEqual(model.draft, "New follow-up")
        XCTAssertEqual(model.conversation?.composerAttachments?.first?.payload?.data, attachment.payload?.data)
        XCTAssertEqual(model.conversation?.queuedMessages?.first?.id, linked.queuedMessages?.first?.id)
        if let history {
            try await panel.waitUntil("existing Pi history after replacing the draft") { model.messages.contains { $0.id == history.latestID } }
            XCTAssertEqual(try history.messages(), savedMessages)
        }
        XCTAssertEqual(try fixture.git("worktree", "list", "--porcelain"), worktrees)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ghLog.path))
        try fixture.checkOriginalCheckouts(in: model)
    }

    func testDamagedPRForkKeepsCurrentWorkerSelectionAndBothDrafts() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_PROMPT_LINK_TEST_APP"] else {
            throw XCTSkip("Set PI_PROMPT_LINK_TEST_APP to exercise the bundled Pi worker.")
        }
        let app = URL(fileURLWithPath: path)
        let fixture = try Fixture()
        defer { fixture.close() }
        let parent = try fixture.seedHistory(app: app, thread: fixture.mainDraft.id)
        let queued = QueuedMessage(text: "Keep this queued message")
        do {
            let store = try WorkspaceStore(root: fixture.workspace)
            var workspace = try store.load()
            workspace.model = ModelSettings(provider: .local, model: "palette-fixture")
            workspace.projects[0].conversations[0].isDraft = false
            workspace.projects[1].conversations[0].queuedMessages = [queued]
            try store.save(workspace)
        }
        let model = fixture.open(app: app)
        defer { model.terminate() }
        let panel = LinkPanel(model: model)
        defer { panel.close() }
        model.selectConversation(fixture.mainDraft.id, in: fixture.project.id)
        try await panel.waitUntil("parent history") { model.messages.last?.id == parent.latestID }
        model.forkResponse(parent.latestID)
        try await panel.waitUntil("real Pi fork") { model.phase == .ready && model.conversation?.forkOrigin?.messageID == parent.latestID }
        let childID = try XCTUnwrap(model.conversation?.id)
        let scope = try XCTUnwrap(model.gitHubScope)
        try await model.linkPullRequest(fixture.prURL, in: scope, repository: model.gitHubRepository(in: scope))
        model.draft = "Preserve this fork follow-up"
        let sourceProject = try XCTUnwrap(model.projects.first { $0.path == fixture.other.path })
        model.selectConversation(fixture.unrelatedDraft.id, in: sourceProject.id)
        try await panel.waitUntil("unrelated worker ready") { model.phase == .ready }
        let source = try XCTUnwrap(fixture.latestWorker)
        let child = fixture.workspace.appendingPathComponent("sessions/\(fixture.project.id)/\(childID)/\(childID).jsonl")
        let original = try Data(contentsOf: child)
        let header = original.prefix(through: try XCTUnwrap(original.firstIndex(of: 10)))
        try header.write(to: child, options: .atomic)
        let parentFile = URL(fileURLWithPath: parent.historyPath)
        let parentBytes = try Data(contentsOf: parentFile)
        let saved = try fixture.saved()
        let link = try fixture.link(prompt: "Replace+this")
        var selections: [UUID?] = []
        let subscription = model.$workspace.sink { selections.append($0.activeProject?.selectedConversation) }
        defer { subscription.cancel() }
        for action in ["prompt-link-pr-replace-draft", "prompt-link-pr-open-thread"] {
            XCTAssertTrue(model.openPromptLink(link))
            panel.showReview()
            try await panel.waitFor(action)
            try panel.press(action)
            try await panel.waitUntil("Pi rejected the damaged fork") {
                panel.element("prompt-link-action-error") != nil || model.error != nil
            }
            XCTAssertEqual(model.conversation?.id, fixture.unrelatedDraft.id)
            XCTAssertEqual(model.phase, .ready)
            XCTAssertNotNil(source.onEvent)
            XCTAssertEqual(model.draft, fixture.unrelatedDraft.composerText)
            XCTAssertEqual(model.queuedMessages, [queued])
            XCTAssertEqual(Set(selections), [fixture.unrelatedDraft.id])
            XCTAssertEqual(try fixture.saved(), saved)
            XCTAssertEqual(try Data(contentsOf: child), header)
            XCTAssertEqual(try Data(contentsOf: parentFile), parentBytes)
            try panel.check("prompt-link-action-error", includes: "fork history is incomplete")
            model.promptLinkReview = nil
        }
        try original.write(to: child, options: .atomic)
        XCTAssertTrue(model.openPromptLink(link))
        panel.showReview()
        try await panel.waitFor("prompt-link-pr-replace-draft")
        try panel.press("prompt-link-pr-replace-draft")
        try await panel.waitUntil("restored fork") { model.messages.last?.id == parent.latestID && model.phase == .ready }
        XCTAssertEqual(model.conversation?.id, childID)
        XCTAssertEqual(model.draft, "Replace this")
        XCTAssertNil(source.onEvent)
        XCTAssertEqual(try Data(contentsOf: parentFile), parentBytes)
        XCTAssertEqual(try Data(contentsOf: child), original)
        XCTAssertEqual(model.projects.first { $0.id == sourceProject.id }?.conversations.first?.queuedMessages, [queued])
    }

    func testLateReadyKeepsNewComposerTextAndNewSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let reference = try XCTUnwrap(GitHubPullRequestReference(url: fixture.prURL))
        var linked = Conversation(id: UUID(), title: "Linked draft", isDraft: true, composerText: "Original follow-up")
        linked.linkedPullRequests = [.init(reference: reference, title: "Fixture PR")]
        do {
            let store = try WorkspaceStore(root: fixture.workspace)
            var workspace = try store.load()
            workspace.projects[0].conversations.append(linked)
            try store.save(workspace)
        }
        let candidate = FixtureWorker()
        let model = WorkspaceModel(root: fixture.workspace, keychainService: "unused", readCredential: { _ in nil }) { _, _ in
            candidate.onOpen == nil ? FixtureWorker() : candidate
        }
        defer { model.terminate() }
        model.connect()
        XCTAssertTrue(model.openPromptLink(try fixture.link(prompt: "Replace+this")))
        let review = try XCTUnwrap(model.promptLinkReview)
        guard case let .thread(target) = try await model.resolvePullRequestPromptLink(review) else {
            return XCTFail("Expected a linked draft")
        }
        for changeSelection in [false, true] {
            let opened = expectation(description: "Pi received the open command")
            candidate.onOpen = { opened.fulfill() }
            let attempt = Task {
                try await model.openPullRequestPromptLinkThread(review, target: target, replaceDraft: true)
            }
            await fulfillment(of: [opened], timeout: 5)
            let lateEvent = try XCTUnwrap(candidate.onEvent)
            candidate.onOpen = nil
            if changeSelection {
                model.selectConversation(fixture.mainDraft.id, in: fixture.project.id)
            } else {
                model.draft = "Edited while opening"
            }
            lateEvent(.ready([]))
            do {
                try await attempt.value
                XCTFail("A stale Pi callback opened the linked draft")
            } catch {}
            let expectedDraft = changeSelection ? fixture.mainDraft.composerText : "Edited while opening"
            XCTAssertEqual(model.draft, expectedDraft)
            XCTAssertEqual(model.conversation?.id, changeSelection ? fixture.mainDraft.id : fixture.unrelatedDraft.id)
            XCTAssertEqual(model.projects.flatMap(\.conversations).first { $0.id == linked.id }?.composerText, linked.composerText)
            XCTAssertEqual(model.phase, .ready)
        }
        var opens = 0
        candidate.onOpen = { opens += 1 }
        model.selectConversation(linked.id, in: fixture.project.id)
        XCTAssertEqual(model.phase, .connecting)
        Task {
            model.draft = "Updated the linked draft while Pi was opening"
            candidate.onEvent?(.ready([]))
        }
        do {
            try await model.openPullRequestPromptLinkThread(review, target: target, replaceDraft: true)
            XCTFail("The already-connecting thread lost its newer draft")
        } catch {}
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.draft, "Updated the linked draft while Pi was opening")
    }

    func testWrongRepositoryResponseAndChangedLocalRemoteCannotConfirm() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = fixture.open()
        defer { model.terminate() }
        XCTAssertTrue(model.openPromptLink(try fixture.link()))
        let review = try XCTUnwrap(model.promptLinkReview)
        let index = try fixture.saved()
        let worktrees = try fixture.git("worktree", "list", "--porcelain")
        try fixture.writePR(head: fixture.oldHead, url: "https://github.com/fixture/other/pull/17")
        do {
            _ = try await model.resolvePullRequestPromptLink(review)
            XCTFail("A response for another repository must not be offered for checkout.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unreadable pull request"))
        }
        try fixture.writePR(head: fixture.oldHead)
        guard case let .checkout(target) = try await model.resolvePullRequestPromptLink(review) else {
            return XCTFail("Expected the matching project.")
        }
        _ = try fixture.git("remote", "set-url", "origin", "git@github.com:fixture/other.git")
        do {
            _ = try await model.preparePullRequestPromptLink(review, target: target)
            XCTFail("A stale checkout must be rejected.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("repository changed"))
        }
        let ghRequests = try Data(contentsOf: fixture.ghLog)
        guard case .missingProject = try await model.resolvePullRequestPromptLink(review) else {
            return XCTFail("Expected a missing project after its remote changed.")
        }
        XCTAssertEqual(try fixture.saved(), index)
        XCTAssertEqual(try fixture.git("worktree", "list", "--porcelain"), worktrees)
        XCTAssertEqual(try Data(contentsOf: fixture.ghLog), ghRequests)
        try model.openPromptLinkDraft(review)
        XCTAssertEqual(model.project?.isScratch, true)
        XCTAssertEqual(model.draft, fixture.prURL)
        XCTAssertTrue(model.conversation?.pullRequestLinks.isEmpty == true)
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let repo: URL
    let other: URL
    let dirty: URL
    let workspace: URL
    let ghLog: URL
    let prURL = "https://github.com/fixture/repo/pull/17"
    let project: Project
    let unrelatedDraft = Conversation(id: UUID(), title: "Other repository draft", isDraft: true, composerText: "Preserve this")
    let mainDraft = Conversation(id: UUID(), title: "Local draft", isDraft: true, composerText: "Keep my local edit")
    private(set) var oldHead = ""
    private(set) var newHead = ""
    private(set) weak var latestWorker: PiProcess?
    private(set) var connectionDirectories: [String] = []

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        repo = root.appendingPathComponent("Matching repository")
        other = root.appendingPathComponent("Other repository")
        dirty = root.appendingPathComponent("Existing topic checkout")
        ghLog = root.appendingPathComponent("gh.log")
        workspace = root.appendingPathComponent("workspace")
        project = Project(id: UUID(), path: repo.path, title: "Matching project",
                          conversations: [mainDraft], selectedConversation: mainDraft.id)
        let otherProject = Project(id: UUID(), path: other.path, title: "Other project",
                                   conversations: [unrelatedDraft], selectedConversation: unrelatedDraft.id, createdAt: Date())
        try WorkspaceStore(root: workspace).save(Workspace(projects: [project, otherProject], selectedProject: otherProject.id, welcomeCompleted: true))

        for dir in [repo, other] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            _ = try git(in: dir, "init", "--template=", "-b", "main")
            _ = try git(in: dir, "config", "protocol.allow", "never")
            _ = try git(in: dir, "config", "protocol.file.allow", "always")
            _ = try git(in: dir, "commit", "--allow-empty", "-m", "Starting point")
        }
        _ = try git("remote", "add", "origin", "git@github.com:Fixture/Repo.git")
        _ = try git(in: other, "remote", "add", "origin", "git@github.com:fixture/other.git")
        _ = try git("config", "url.\(other.absoluteString).insteadOf", "https://github.com/fixture/repo.git")
        _ = try git("worktree", "add", "-b", "topic", dirty.path)
        try Data("root edit".utf8).write(to: repo.appendingPathComponent("root-edit"))
        try Data("topic edit".utf8).write(to: dirty.appendingPathComponent("topic-edit"))
        oldHead = try git("rev-parse", "HEAD")
        try Data("PR content".utf8).write(to: other.appendingPathComponent("change.txt"))
        _ = try git(in: other, "add", "change.txt")
        _ = try git(in: other, "commit", "-m", "Independent pull request head")
        newHead = try git(in: other, "rev-parse", "HEAD")
        XCTAssertNotEqual(oldHead, newHead)
        try writePR(head: oldHead)
        let gh = root.appendingPathComponent("gh")
        try """
            #!/bin/sh
            test "$#" = 7 && test "$1 $2 $3 $4 $6 $7" = 'pr view 17 --json --repo github.com/fixture/repo' || exit 92
            test "$PWD" = "$FIXTURE_MATCH" || exit 93
            printf '%s\n' "$PWD|$*" >> "$FIXTURE_ROOT/gh.log"
            exec /bin/cat "$FIXTURE_ROOT/pr.json"
            """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
    }

    func open(app: URL? = nil) -> WorkspaceModel {
        let environment = ["PATH": "\(root.path):/usr/bin:/bin", "FIXTURE_ROOT": root.path, "FIXTURE_MATCH": repo.path]
        return WorkspaceModel(root: workspace, keychainService: "unused", credentialExists: { _ in false },
                              readCredential: { _ in nil },
                              makeProcess: { [weak self] config, directory in
            self?.connectionDirectories.append(directory)
            if let app {
                let worker = try PiProcess(config: config, cwd: directory,
                                     executable: app.appendingPathComponent("Contents/Helpers/node"),
                                     arguments: [app.appendingPathComponent("Contents/Resources/Sidecar/worker.mjs").path])
                self?.latestWorker = worker
                return worker
            }
            return FixtureWorker()
        }, makeGitHubReader: { GitHubReader(directory: $0, environment: environment, timeout: .seconds(5)) })
    }

    struct History: Decodable {
        private struct Entry: Decodable { let type: String }

        let latestID: String
        let historyPath: String

        func messages() throws -> [Substring] {
            let log = try String(contentsOfFile: historyPath, encoding: .utf8)
            let decoder = JSONDecoder()
            return try log.split(separator: "\n").filter {
                try decoder.decode(Entry.self, from: Data($0.utf8)).type == "message"
            }
        }
    }

    func seedHistory(app: URL, thread: UUID) throws -> History {
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/Helpers/node")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/fixtures/palette-message-history.mjs")
        process.arguments = [script.path, app.appendingPathComponent("Contents/Resources/Sidecar").path,
                             workspace.path, project.id.uuidString, thread.uuidString, repo.path, "existing PR thread"]
        process.environment = ["PATH": "/usr/bin:/bin", "PI_OFFLINE": "1", "PI_TELEMETRY": "0",
                               "PI_CODING_AGENT_DIR": root.appendingPathComponent("history-config").path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorkspaceError("The Pi fixture history could not be written.") }
        return try JSONDecoder().decode(History.self, from: bytes)
    }

    func link(prompt: String? = nil) throws -> URL {
        let query = prompt.map { "&prompt=" + $0 } ?? ""
        return try XCTUnwrap(URL(string: "pi-workspace://new/v1?pr=fixture/repo/17" + query))
    }

    func saved() throws -> Data { try Data(contentsOf: workspace.appendingPathComponent("workspace.json")) }
    func refs() throws -> String { try git("for-each-ref", "--format=%(objectname) %(refname)") }
    func close() { try? FileManager.default.removeItem(at: root) }

    func writePR(head: String, url: String? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "number": 17, "title": "Fixture pull request", "state": "OPEN", "isDraft": false,
            "headRefName": "topic", "headRefOid": head, "baseRefName": "main", "url": url ?? prURL
        ])
        try data.write(to: root.appendingPathComponent("pr.json"), options: .atomic)
    }

    private var hook: URL { repo.appendingPathComponent(".git/hooks/reference-transaction") }

    func installFailingPreparationHook() throws {
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            #!/bin/sh
            test "$1" = prepared || exit 0
            while read -r old new ref; do
                case "$ref" in
                    refs/heads/pi/pr-*) echo 'fixture rejects PR branch' >&2; exit 1 ;;
                esac
            done
            """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    }

    func removePreparationHook() throws { try FileManager.default.removeItem(at: hook) }

    func checkOriginalCheckouts(in model: WorkspaceModel) throws {
        XCTAssertEqual(try git("branch", "--show-current"), "main")
        XCTAssertEqual(try git("rev-parse", "HEAD"), oldHead)
        XCTAssertEqual(try git(in: dirty, "branch", "--show-current"), "topic")
        XCTAssertEqual(try git(in: dirty, "rev-parse", "HEAD"), oldHead)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("root-edit"), encoding: .utf8), "root edit")
        XCTAssertEqual(try String(contentsOf: dirty.appendingPathComponent("topic-edit"), encoding: .utf8), "topic edit")
        XCTAssertEqual(model.projects.flatMap(\.conversations).first { $0.id == unrelatedDraft.id }?.composerText,
                       unrelatedDraft.composerText)
        XCTAssertEqual(model.projects.flatMap(\.conversations).first { $0.id == mainDraft.id }?.composerText,
                       mainDraft.composerText)
    }

    @discardableResult
    func git(in directory: URL? = nil, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", (directory ?? repo).path, "-c", "user.name=Fixture",
                             "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorkspaceError(text) }
        return text.trimmingCharacters(in: .newlines)
    }
}

@MainActor
private final class LinkPanel {
    private let app = NSApplication.shared
    private let policy: NSApplication.ActivationPolicy
    private let window: OffscreenPanel
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private weak var model: WorkspaceModel?

    init(model: WorkspaceModel) {
        self.model = model
        policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2000, y: 0)
        window = OffscreenPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 565, height: 420)),
                                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.sizingOptions = []
        showReview()
        window.contentView = host
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
    }

    func showReview() {
        guard let model, let review = model.promptLinkReview else { return }
        host.rootView = AnyView(PromptLinkView(model: model, review: review) { [weak model] in
            model?.promptLinkReview = nil
        }.id(review.id))
    }

    func close() {
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        window.close()
        app.setActivationPolicy(policy)
    }

    func element(_ identifier: String) -> AnyObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ node: AnyObject) -> AnyObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.accessibilityIdentifier?() == identifier { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let match = search(child as AnyObject) { return match }
            }
            return nil
        }
        return search(host) ?? search(window)
    }

    func press(_ identifier: String) throws {
        let button = try XCTUnwrap(element(identifier), identifier)
        XCTAssertEqual(button.accessibilityPerformPress?(), true, identifier)
    }

    private func text(_ identifier: String) -> String? {
        guard let node = element(identifier) else { return nil }
        let object = node as? NSObject
        let selector = NSSelectorFromString("accessibilityValue")
        let value = object?.responds(to: selector) == true ? object?.perform(selector)?.takeUnretainedValue() as? String : nil
        return [node.accessibilityLabel?(), node.accessibilityTitle?(), value].compactMap { $0 }.joined(separator: " ")
    }

    func check(_ identifier: String, includes expected: String) throws {
        let actual = try XCTUnwrap(text(identifier), identifier)
        XCTAssertTrue(actual.contains(expected), "\(identifier) expected \(expected), got \(actual)")
    }

    func waitFor(_ identifier: String, includes expected: String? = nil,
                 file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil(identifier, file: file, line: line) {
            if let expected { return text(identifier)?.contains(expected) == true }
            return element(identifier) != nil
        }
    }

    func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                   _ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(description). Review state: \(text("prompt-link-title") ?? "none"), \(text("prompt-link-action-error") ?? "none").",
                file: file, line: line)
        throw WorkspaceError("Timed out waiting for \(description).")
    }
}

private final class OffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FixtureWorker: PiConnection {
    var onEvent: ((PiEvent) -> Void)?
    var onClose: (() -> Void)?
    var onOpen: (() -> Void)?
    func send(_ command: any Encodable) throws {
        guard command is OpenConversation else { return }
        if let onOpen { onOpen() }
        else { onEvent?(.ready([])) }
    }
    func close() { onEvent = nil }
}
