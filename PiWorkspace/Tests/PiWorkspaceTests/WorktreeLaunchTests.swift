import Darwin
import Foundation
import XCTest
@testable import PiWorkspace

@MainActor
final class WorktreeLaunchTests: XCTestCase {
    func testCancelDuringGitCheckoutRestoresTheDraftAndAllowsAnotherSend() async throws {
        let fixture = try await Fixture()
        let model = try await draft(in: fixture)
        defer { model.terminate() }
        try fixture.mark("hold-git")
        model.send()
        try await fixture.readSignal("git-entered")
        let launch = try XCTUnwrap(model.conversation?.worktreeLaunch)
        XCTAssertEqual(launch.stage, .createCheckout)
        XCTAssertEqual(launch.targetPath, try fixture.target().path)
        XCTAssertNil(launch.failure)
        XCTAssertTrue(model.canInterruptWorktree)
        XCTAssertTrue(model.canWorkLocally)
        try interrupt(.cancel, launch: launch, in: model)
        XCTAssertFalse(model.canInterruptWorktree)
        try await fixture.release("git-release")
        await ready(model)

        XCTAssertNil(model.conversation?.worktreeLaunch)
        XCTAssertTrue(model.conversation?.canDiscardDraft == true)
        XCTAssertEqual(model.draft, Fixture.draft)
        XCTAssertEqual(try fixture.savedThread().composerText, Fixture.draft)
        XCTAssertEqual(try fixture.prompts(), [])
        try await fixture.assertCheckouts([fixture.repo.path])
        XCTAssertFalse(try fixture.branches().contains("topic"))

        model.send()
        try interrupt(.cancel, launch: launch, in: model)
        await recorded(model)
        let checkout = try fixture.target()
        XCTAssertEqual(try fixture.prompts(), [.init(cwd: checkout.path, text: Fixture.prompt)])
        try await fixture.assertCheckouts([fixture.repo.path, checkout.path])
        XCTAssertTrue(try fixture.branches().contains("topic"))
    }

    func testWorkLocallyIgnoresLateReadyFromTheCancelledHelper() async throws {
        let fixture = try await Fixture()
        let model = try await draft(in: fixture)
        defer { model.terminate() }
        try fixture.mark("hold-pi")
        model.send()
        try await fixture.readSignal("pi-entered")
        let launch = try XCTUnwrap(model.conversation?.worktreeLaunch)
        XCTAssertEqual(launch.stage, .openThread)
        XCTAssertEqual(launch.checkout?.branch, "topic")
        XCTAssertEqual(model.workingDirectory, try fixture.target().path)
        XCTAssertNil(launch.failure)
        XCTAssertTrue(model.canWorkLocally)
        XCTAssertEqual(model.phase, .connecting)
        XCTAssertTrue(try fixture.branches().contains("topic"))

        try interrupt(.workLocally, launch: launch, in: model)
        try interrupt(.workLocally, launch: launch, in: model)
        try await fixture.release("pi-release")
        try await fixture.readSignal("pi-replied")
        await recorded(model)

        XCTAssertNil(model.conversation?.worktreeLaunch)
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertEqual(try fixture.savedThread().workingLocation, .project)
        XCTAssertEqual(model.messages.filter { $0.role == .user }.map(\.text), [Fixture.prompt])
        XCTAssertEqual(try fixture.prompts(), [.init(cwd: fixture.repo.path, text: Fixture.prompt)])
        try await fixture.assertCheckouts([fixture.repo.path])
        XCTAssertFalse(try fixture.branches().contains("topic"))
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("README.md"), encoding: .utf8),
                       "original edit\n")
    }

    func testWorkLocallyAfterReopeningAFailedLaunchPreservesADirtyCheckout() async throws {
        let fixture = try await Fixture()
        try fixture.mark("fail-pi")
        do {
            let model = try await draft(in: fixture)
            defer { model.terminate() }
            model.send()
            await failed(model)
            XCTAssertTrue(model.canRetryWorktree)
            XCTAssertTrue(model.canInterruptWorktree)
            XCTAssertEqual(try fixture.prompts(), [])
        }
        let checkout = try fixture.target()
        let ignored = checkout.appendingPathComponent("my-notes.private")
        try Data("keep the ignored file".utf8).write(to: ignored)

        let reopened = fixture.open()
        defer { reopened.terminate() }
        reopened.start()
        XCTAssertTrue(reopened.canRetryWorktree)
        XCTAssertTrue(reopened.canWorkLocally)
        let launch = try XCTUnwrap(reopened.conversation?.worktreeLaunch)
        try interrupt(.workLocally, launch: launch, in: reopened)
        await recorded(reopened)

        XCTAssertEqual(try fixture.prompts(), [.init(cwd: fixture.repo.path, text: Fixture.prompt)])
        try await fixture.assertCheckouts([fixture.repo.path, checkout.path])
        XCTAssertTrue(try fixture.branches().contains("topic"))
        XCTAssertEqual(try String(contentsOf: ignored, encoding: .utf8), "keep the ignored file")
    }

    func testWorkLocallyPreservesAnUnownedCheckoutAtThePlannedPath() async throws {
        let fixture = try await Fixture()
        let model = try await draft(in: fixture)
        defer { model.terminate() }
        let target = try fixture.target()
        try fixture.git(["worktree", "add", "-b", "unrelated", "--", target.path, "HEAD"])
        model.send()
        await failed(model)
        XCTAssertTrue(model.canWorkLocally)
        XCTAssertTrue(model.canRetryWorktree)
        let launch = try XCTUnwrap(model.conversation?.worktreeLaunch)
        try interrupt(.workLocally, launch: launch, in: model)
        await recorded(model)
        XCTAssertEqual(try fixture.prompts(), [.init(cwd: fixture.repo.path, text: Fixture.prompt)])
        try await fixture.assertCheckouts([fixture.repo.path, target.path])
        XCTAssertTrue(try fixture.branches().contains("unrelated"))
        XCTAssertFalse(try fixture.branches().contains("topic"))
    }

    func testWorktreeLocationPersistsAndResetKeepsExistingAndPinnedCheckouts() async throws {
        let fixture = try await Fixture()
        let custom = fixture.root.appendingPathComponent("Custom Worktree Storage")
        let alternate = fixture.root.appendingPathComponent("Unused Worktree Storage")
        let projectID: UUID
        let firstThreadID: UUID
        let target: URL
        let obstruction = Data("keep this occupied path".utf8)
        do {
            let model = try await draft(in: fixture)
            defer { model.terminate() }
            projectID = try XCTUnwrap(model.project?.id)
            firstThreadID = try XCTUnwrap(model.conversation?.id)
            try model.updateWorktreesDirectory("  \(custom.path)\n")
            target = try fixture.target(in: custom)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try obstruction.write(to: target)
            model.send()
            await failed(model)
            XCTAssertEqual(try fixture.savedThread().worktreeLaunch?.checkout?.path, target.path)
            XCTAssertEqual(try fixture.savedThread().worktreeLaunch?.prompt, Fixture.prompt)
            XCTAssertEqual(try fixture.savedThread().worktreeLaunch?.stage, .createCheckout)
            XCTAssertEqual(try Data(contentsOf: target), obstruction)
            XCTAssertEqual(try fixture.prompts(), [])
            try await fixture.assertCheckouts([fixture.repo.path])
        }

        do {
            let model = fixture.open()
            defer { model.terminate() }
            model.start()
            XCTAssertEqual(model.workspace.worktreesDirectory, custom.path)
            XCTAssertEqual(model.conversation?.id, firstThreadID)
            XCTAssertTrue(model.canRetryWorktree)
            XCTAssertEqual(try fixture.prompts(), [])
            try await fixture.assertCheckouts([fixture.repo.path])
            try model.updateWorktreesDirectory(alternate.path)
            let previous = try Data(contentsOf: fixture.workspace.appendingPathComponent("workspace.previous.json"))
            XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: previous).worktreesDirectory, custom.path)
            try FileManager.default.removeItem(at: target)
            let launchID = try XCTUnwrap(model.conversation?.worktreeLaunch).id
            model.retryWorktree(threadID: firstThreadID, launchID: launchID)
            await recorded(model)
            model.retryWorktree(threadID: firstThreadID, launchID: launchID)
            XCTAssertEqual(model.workingDirectory, target.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.path))
            XCTAssertEqual(try fixture.prompts(), [.init(cwd: target.path, text: Fixture.prompt)])
            try await fixture.assertCheckouts([fixture.repo.path, target.path])

            try Data("custom checkout edit\n".utf8).write(to: target.appendingPathComponent("README.md"))
            try model.updateWorktreesDirectory(" ")
            XCTAssertNil(model.workspace.worktreesDirectory)
            XCTAssertEqual(model.workingDirectory, target.path)
        }

        let reopened = fixture.open()
        defer { reopened.terminate() }
        XCTAssertNil(reopened.workspace.worktreesDirectory)
        reopened.start()
        reopened.selectConversation(firstThreadID, in: projectID)
        await ready(reopened)
        XCTAssertEqual(reopened.workingDirectory, target.path)
        XCTAssertEqual(try fixture.prompts(), [.init(cwd: target.path, text: Fixture.prompt)])
        reopened.addConversation(in: projectID)
        try await reopened.changeThreadLocation(.create(branch: "after-reset", base: "HEAD"))
        await ready(reopened)
        reopened.draft = Fixture.draft
        reopened.send()
        await recorded(reopened)
        let defaultTarget = try fixture.target()
        XCTAssertEqual(reopened.workingDirectory, defaultTarget.path)
        XCTAssertEqual(try fixture.prompts(), [target, defaultTarget].map { .init(cwd: $0.path, text: Fixture.prompt) })
        try await fixture.assertCheckouts([fixture.repo.path, target.path, defaultTarget.path])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("README.md"), encoding: .utf8),
                       "custom checkout edit\n")
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("README.md"), encoding: .utf8),
                       "original edit\n")
    }

    func testNewWorktreeDefaultsAndExplicitRefsUseTheExpectedCommits() async throws {
        let fixture = try await Fixture()
        let remote = try fixture.installRemote()
        let model = fixture.open()
        defer { model.terminate() }
        try model.openProject(fixture.repo)
        let projectID = try XCTUnwrap(model.project?.id)
        let status = try fixture.git(["status", "--porcelain"])
        XCTAssertTrue(model.workspace.startNewWorktreesFromRemote)

        let base = try await fixture.defaultBase()
        try await model.changeThreadLocation(.create(branch: "from-default", base: base))
        await ready(model)
        XCTAssertEqual(model.conversation?.workingLocation, .newWorktree(branch: "from-default", base: "refs/heads/stable"))
        XCTAssertEqual(model.conversation?.worktreeStartsFromRemote, true)
        _ = try await GitWorkspace(path: fixture.repo.path).branchChoices()
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/remotes/origin/stable"]), remote.cachedHead)
        try await fixture.assertCheckouts([fixture.repo.path])
        model.draft = Fixture.draft
        model.send()
        await recorded(model)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], at: fixture.target()), remote.remoteHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/remotes/origin/stable"]), remote.remoteHead)

        try model.updateNewWorktreesStartFromRemote(false)
        model.addConversation(in: projectID)
        try await model.changeThreadLocation(.create(branch: "from-local", base: base))
        await ready(model)
        XCTAssertEqual(model.conversation?.worktreeStartsFromRemote, false)
        try model.updateNewWorktreesStartFromRemote(true)
        model.draft = Fixture.draft
        model.send()
        await recorded(model)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], at: fixture.target()), remote.localHead)

        model.addConversation(in: projectID)
        try await model.changeThreadLocation(.create(branch: "from-tracking-ref", base: base))
        await ready(model)
        let scope = try XCTUnwrap(model.branchPickerScope)
        try model.updateWorktreeStartsFromRemote(false, in: scope)
        try await model.changeThreadBranch(.existing("refs/remotes/origin/stable"), in: scope)
        XCTAssertEqual(try fixture.savedThread().workingLocation,
                       .newWorktree(branch: "from-tracking-ref", base: "refs/remotes/origin/stable"))
        XCTAssertEqual(try fixture.savedThread().worktreeStartsFromRemote, false)
        try fixture.git(["remote", "set-url", "origin", fixture.root.appendingPathComponent("missing.git").absoluteString])
        model.draft = Fixture.draft
        model.send()
        await recorded(model)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], at: fixture.target()), remote.remoteHead)
        XCTAssertEqual(try fixture.git(["status", "--porcelain"]), status)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), remote.cachedHead)
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("README.md"), encoding: .utf8),
                       "original edit\n")
    }

    func testRemoteStartsFallBackToTheLocalRefWhenTheRemoteBranchIsMissing() async throws {
        let fixture = try await Fixture()
        let remote = try fixture.installRemote()
        try fixture.git(["update-ref", "-d", "refs/heads/stable"], at: remote.url)
        let model = fixture.open()
        defer { model.terminate() }
        try model.openProject(fixture.repo)
        let base = try await fixture.defaultBase()
        try await model.changeThreadLocation(.create(branch: "from-missing-remote-branch", base: base))
        await ready(model)
        model.draft = Fixture.draft
        model.send()
        await recorded(model)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], at: fixture.target()), remote.localHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/remotes/origin/stable"]), remote.cachedHead)

        try fixture.git(["update-ref", "refs/heads/release", remote.remoteHead.trimmingCharacters(in: .newlines)], at: remote.url)
        try fixture.git(["remote", "add", "upstream", remote.url.absoluteString])
        try fixture.git(["config", "branch.stable.remote", "upstream"])
        try fixture.git(["config", "branch.stable.merge", "refs/heads/release"])
        model.addConversation()
        try await model.changeThreadLocation(.create(branch: "from-tracked-release", base: base))
        await ready(model)
        model.draft = Fixture.draft
        model.send()
        await recorded(model)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], at: fixture.target()), remote.remoteHead)
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/remotes/upstream/release"]), remote.remoteHead)
    }

    func testRemoteRetryKeepsTheSelectedRefAndThenThePinnedCommitAndPath() async throws {
        let fixture = try await Fixture()
        let remote = try fixture.installRemote()
        let custom = fixture.root.appendingPathComponent("Remote Worktrees")
        let missing = fixture.root.appendingPathComponent("missing.git").absoluteString
        let threadID: UUID
        let target: URL
        let fetchFailure: String
        do {
            let model = fixture.open()
            defer { model.terminate() }
            try model.openProject(fixture.repo)
            try model.updateWorktreesDirectory(custom.path)
            try await model.changeThreadLocation(.create(branch: "retry-remote", base: "refs/remotes/origin/stable"))
            await ready(model)
            threadID = try XCTUnwrap(model.conversation?.id)
            target = try fixture.target(in: custom)
            try fixture.git(["remote", "set-url", "origin", missing])
            model.draft = Fixture.draft
            model.send()
            await failed(model)
            fetchFailure = try XCTUnwrap(fixture.savedThread().worktreeLaunch?.failure)
            XCTAssertTrue(fetchFailure.contains("missing.git"), fetchFailure)
            XCTAssertEqual(try fixture.savedThread().worktreeLaunch?.targetPath, target.path)
            XCTAssertNil(try fixture.savedThread().worktreeLaunch?.checkout)
            XCTAssertTrue(model.canRetryWorktree)
            XCTAssertEqual(try fixture.prompts(), [])
            try model.updateNewWorktreesStartFromRemote(false)
        }

        try fixture.git(["remote", "set-url", "origin", remote.url.absoluteString])
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let obstruction = Data("occupied".utf8)
        try obstruction.write(to: target)
        do {
            let model = fixture.open()
            defer { model.terminate() }
            model.start()
            XCTAssertEqual(model.conversation?.id, threadID)
            XCTAssertEqual(model.conversation?.workingLocation,
                           .newWorktree(branch: "retry-remote", base: "refs/remotes/origin/stable"))
            XCTAssertEqual(model.conversation?.worktreeStartsFromRemote, true)
            XCTAssertFalse(model.workspace.startNewWorktreesFromRemote)
            let launch = try XCTUnwrap(model.conversation?.worktreeLaunch)
            XCTAssertEqual(launch.targetPath, target.path)
            model.retryWorktree(threadID: UUID(), launchID: launch.id)
            model.retryWorktree(threadID: threadID, launchID: UUID())
            XCTAssertFalse(model.preparingWorktree)
            XCTAssertEqual(model.conversation?.worktreeLaunch?.failure, fetchFailure)
            model.retryWorktree(threadID: threadID, launchID: launch.id)
            XCTAssertTrue(model.preparingWorktree)
            XCTAssertNil(model.conversation?.worktreeLaunch?.failure)
            let pinned = expectation(description: "Fresh remote commit was pinned")
            let observation = model.$workspace.filter {
                $0.activeProject?.conversations.first?.worktreeLaunch?.checkout?.head ==
                    remote.remoteHead.trimmingCharacters(in: .newlines)
            }.first().sink { _ in pinned.fulfill() }
            await fulfillment(of: [pinned], timeout: 10)
            observation.cancel()
            await failed(model, after: fetchFailure)
            XCTAssertEqual(try fixture.savedThread().worktreeLaunch?.checkout?.path, target.path)
            XCTAssertEqual(try Data(contentsOf: target), obstruction)
            XCTAssertEqual(try fixture.prompts(), [])
            try model.updateWorktreesDirectory("")
        }

        try fixture.git(["remote", "set-url", "origin", missing])
        try fixture.git(["update-ref", "refs/remotes/origin/stable", remote.cachedHead.trimmingCharacters(in: .newlines)])
        try FileManager.default.removeItem(at: target)
        let reopened = fixture.open()
        defer { reopened.terminate() }
        reopened.start()
        XCTAssertTrue(reopened.canRetryWorktree, reopened.error ?? "")
        XCTAssertEqual(reopened.conversation?.worktreeLaunch?.checkout?.head,
                       remote.remoteHead.trimmingCharacters(in: .newlines))
        reopened.retryWorktree(threadID: threadID, launchID: reopened.conversation?.worktreeLaunch?.id)
        await recorded(reopened)
        XCTAssertEqual(reopened.workingDirectory, target.path,
                       reopened.conversation?.worktreeLaunch?.failure ?? reopened.error ?? "")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], at: target), remote.remoteHead)
        XCTAssertEqual(try fixture.prompts(), [.init(cwd: target.path, text: Fixture.prompt)])
        XCTAssertEqual(try String(contentsOf: fixture.repo.appendingPathComponent("README.md"), encoding: .utf8),
                       "original edit\n")
    }

    func testRelaunchKeepsAnEmptyDraftsSelectedRefAndToggle() async throws {
        let fixture = try await Fixture()
        _ = try fixture.installRemote()
        let threadID: UUID
        do {
            let model = fixture.open()
            defer { model.terminate() }
            try model.openProject(fixture.repo)
            try await model.changeThreadLocation(.create(branch: "saved", base: "refs/heads/stable"))
            let scope = try XCTUnwrap(model.branchPickerScope)
            try model.updateWorktreeStartsFromRemote(false, in: scope)
            try await model.changeThreadBranch(.existing("refs/remotes/origin/stable"), in: scope)
            threadID = try XCTUnwrap(model.conversation?.id)
        }
        do {
            let store = try WorkspaceStore(root: fixture.workspace)
            var workspace = try store.load()
            workspace.projects.append(Project(id: UUID(), path: fixture.root.path, title: "Recent", createdAt: .distantFuture))
            try store.save(workspace)
        }

        let reopened = fixture.open()
        defer { reopened.terminate() }
        XCTAssertNil(reopened.startupFailure)
        reopened.start()
        await ready(reopened)
        XCTAssertEqual(reopened.conversation?.id, threadID)
        XCTAssertEqual(reopened.conversation?.workingLocation, .newWorktree(branch: "saved", base: "refs/remotes/origin/stable"))
        XCTAssertEqual(reopened.conversation?.worktreeStartsFromRemote, false)
        try await fixture.assertCheckouts([fixture.repo.path])
    }

    func testRelaunchDoesNotResendAnUnconfirmedLocalFallback() async throws {
        let fixture = try await Fixture()
        try fixture.mark("fail-pi")
        do {
            let model = try await draft(in: fixture)
            defer { model.terminate() }
            model.send()
            await failed(model)
            let launch = try XCTUnwrap(model.conversation?.worktreeLaunch)
            try fixture.mark("disconnect-on-prompt")
            try interrupt(.workLocally, launch: launch, in: model)
            let disconnected = expectation(description: "Pi disconnected after it received the prompt")
            let observation = model.$errorNotice.compactMap { $0?.message }.first().sink { _ in disconnected.fulfill() }
            await fulfillment(of: [disconnected], timeout: 10)
            observation.cancel()
            XCTAssertEqual(try fixture.savedThread().worktreeLaunch?.awaitingHistory, true)
            XCTAssertFalse(model.canRetryWorktree)
            XCTAssertFalse(model.canInterruptWorktree)
        }

        let reopened = fixture.open()
        defer { reopened.terminate() }
        reopened.start()
        await ready(reopened)
        XCTAssertEqual(reopened.conversation?.worktreeLaunch?.awaitingHistory, true)
        XCTAssertFalse(reopened.canRetryWorktree)
        XCTAssertFalse(reopened.canInterruptWorktree)
        XCTAssertEqual(try fixture.prompts(), [.init(cwd: fixture.repo.path, text: Fixture.prompt)])
        try await fixture.assertCheckouts([fixture.repo.path])
    }

    func testRelaunchFinishesACancellationSavedDuringGitCheckout() async throws {
        let fixture = try await Fixture()
        do {
            let model = try await draft(in: fixture)
            try fixture.mark("hold-git")
            model.send()
            try await fixture.readSignal("git-entered")
            let launch = try XCTUnwrap(model.conversation?.worktreeLaunch)
            try interrupt(.cancel, launch: launch, in: model)
            XCTAssertEqual(try fixture.savedThread().worktreeLaunch?.interruption, .cancel)
            let gitFinished = expectation(description: "The interrupted Git command exited")
            let observation = model.$gitMutationInProgress.filter { !$0 }.first().sink { _ in gitFinished.fulfill() }
            model.terminate()
            try await fixture.release("git-release")
            await fulfillment(of: [gitFinished], timeout: 10)
            observation.cancel()
        }
        let reopened = fixture.open()
        defer { reopened.terminate() }
        reopened.start()
        await ready(reopened)
        XCTAssertNil(try fixture.savedThread().worktreeLaunch)
        XCTAssertEqual(reopened.draft, Fixture.draft)
        XCTAssertEqual(try fixture.prompts(), [])
        try await fixture.assertCheckouts([fixture.repo.path])
        XCTAssertFalse(try fixture.branches().contains("topic"))
    }

    private func interrupt(_ action: WorktreeLaunch.Interruption, launch: WorktreeLaunch,
                           in model: WorkspaceModel) throws {
        let threadID = try XCTUnwrap(model.conversation?.id)
        model.interruptWorktree(action, threadID: threadID, launchID: launch.id)
    }

    private func draft(in fixture: Fixture) async throws -> WorkspaceModel {
        let model = fixture.open()
        try model.openProject(fixture.repo)
        try await model.changeThreadLocation(.create(branch: "topic", base: "HEAD"))
        await ready(model)
        model.draft = Fixture.draft
        return model
    }

    private func ready(_ model: WorkspaceModel) async {
        let ready = expectation(description: "Pi is ready")
        let observation = model.$phase.filter { $0 == .ready }.first().sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 10)
        observation.cancel()
    }

    private func recorded(_ model: WorkspaceModel) async {
        let received = expectation(description: "Pi received the original prompt")
        let observation = model.$messages.filter { $0.contains { $0.role == .user } }.first()
            .sink { _ in received.fulfill() }
        await fulfillment(of: [received], timeout: 10)
        observation.cancel()
        await ready(model)
    }

    private func failed(_ model: WorkspaceModel, after previous: String? = nil) async {
        let failure = expectation(description: "The preparation failure was saved")
        let observation = model.$workspace.filter {
            guard let message = $0.activeProject?.conversations.first?.worktreeLaunch?.failure else { return false }
            return message != previous
        }.first().sink { _ in failure.fulfill() }
        await fulfillment(of: [failure], timeout: 10)
        observation.cancel()
    }

    private final class Fixture {
        struct Prompt: Equatable {
            let cwd: String
            let text: String
        }

        struct Remote {
            let url: URL
            let cachedHead: String
            let localHead: String
            let remoteHead: String
        }

        static let prompt = "Use the original prompt"
        static let draft = "  " + prompt + "\n"
        let root: URL
        let repo: URL
        var workspace: URL { root.appendingPathComponent("workspace") }

        init() async throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            self.root = root
            repo = try await GitWorkspace.createRepository(named: "project", in: root)
            try WorkspaceStore(root: workspace).save(.init(model: ModelSettings(provider: .openai)))
            let hooks = root.appendingPathComponent("hooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
            let hook = hooks.appendingPathComponent("post-checkout")
            try Data(Self.checkoutHook.utf8).write(to: hook)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
            try git(["config", "core.hooksPath", hooks.path])
            try git(["config", "user.name", "Fixture"])
            try git(["config", "user.email", "fixture@example.invalid"])
            let readme = repo.appendingPathComponent("README.md")
            try Data("base\n".utf8).write(to: readme)
            try Data("*.private\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
            try git(["add", "."])
            try git(["commit", "--no-gpg-sign", "-m", "Base"])
            try Data("original edit\n".utf8).write(to: readme)
            for name in ["git-entered", "git-release", "pi-entered", "pi-release", "pi-replied"] {
                let path = root.appendingPathComponent(name).path
                guard mkfifo(path, 0o600) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @MainActor
        func open() -> WorkspaceModel {
            WorkspaceModel(root: workspace, keychainService: "dev.piworkspace.launch-tests",
                           readCredential: { _ in "fixture-key" }, makeProcess: { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", Self.piHelper, "launch-fixture", self.root.path, self.repo.path])
            })
        }

        func savedThread() throws -> Conversation {
            let index = workspace.appendingPathComponent("workspace.json")
            let data = try Data(contentsOf: index)
            return try XCTUnwrap(JSONDecoder().decode(Workspace.self, from: data).activeProject?.conversations.first)
        }

        func target(in directory: URL? = nil) throws -> URL {
            let data = try Data(contentsOf: workspace.appendingPathComponent("workspace.json"))
            let project = try XCTUnwrap(JSONDecoder().decode(Workspace.self, from: data).activeProject)
            let root = directory ?? workspace.appendingPathComponent("worktrees")
            return try root.appendingPathComponent(project.id.uuidString)
                .appendingPathComponent(XCTUnwrap(project.selectedConversation).uuidString)
        }

        func mark(_ name: String) throws {
            try Data().write(to: root.appendingPathComponent(name))
        }

        func readSignal(_ name: String) async throws {
            try await signal(name, script: "IFS= read -r line < \"$1\"")
        }

        func release(_ name: String) async throws {
            try await signal(name, script: "printf 'release\\n' > \"$1\"")
        }

        private func signal(_ name: String, script: String) async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script, "signal", root.appendingPathComponent(name).path]
            let result = try await WorkspaceCommand.capture(process, outputLimit: 1024, timeout: .seconds(10))
            guard result.status == 0 else { throw WorkspaceError("Fixture timed out at \(name).") }
        }

        func prompts() throws -> [Prompt] {
            let log = root.appendingPathComponent("prompts")
            guard FileManager.default.fileExists(atPath: log.path) else { return [] }
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                let command = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: String])
                let cwd = URL(fileURLWithPath: String(parts[0])).resolvingSymlinksInPath().path
                return Prompt(cwd: cwd, text: try XCTUnwrap(command["text"]))
            }
        }

        func assertCheckouts(_ paths: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
            let checkouts = try await GitWorkspace(path: repo.path).worktrees()
            XCTAssertEqual(Set(checkouts.map(\.path)), Set(paths), file: file, line: line)
        }

        func branches() throws -> [String] {
            try git(["for-each-ref", "--format=%(refname:short)", "refs/heads"]).split(separator: "\n").map(String.init)
        }

        func defaultBase() async throws -> String {
            let choices = try await GitWorkspace(path: repo.path).branchChoices()
            return try XCTUnwrap(GitBranchRef.defaultWorktreeBase(in: choices.refs, current: choices.current)?.id)
        }

        func installRemote() throws -> Remote {
            let bare = root.appendingPathComponent("remote.git")
            let publisher = root.appendingPathComponent("publisher")
            try git(["init", "--bare", "-b", "stable", bare.path])
            try git(["remote", "add", "origin", bare.absoluteString])
            try git(["push", "origin", "HEAD:refs/heads/stable"])
            try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/stable"])
            let cachedHead = try git(["rev-parse", "HEAD"])
            try git(["branch", "stable"])
            try git(["switch", "stable"])
            try git(["commit", "--allow-empty", "--no-gpg-sign", "-m", "Local only"])
            let localHead = try git(["rev-parse", "HEAD"])
            try git(["switch", "-"])
            try git(["clone", bare.absoluteString, publisher.path])
            try Data("remote commit\n".utf8).write(to: publisher.appendingPathComponent("README.md"))
            try git(["commit", "-a", "--no-gpg-sign", "-m", "Remote only"], at: publisher)
            try git(["push", "origin", "stable"], at: publisher)
            let remoteHead = try git(["rev-parse", "HEAD"], at: publisher)
            XCTAssertNotEqual(localHead, remoteHead)
            return Remote(url: bare, cachedHead: cachedHead, localHead: localHead, remoteHead: remoteHead)
        }

        @discardableResult
        func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            command.arguments = ["-C", (directory ?? repo).path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
                + arguments
            let output = Pipe()
            command.standardOutput = output
            try command.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            command.waitUntilExit()
            guard command.terminationStatus == 0 else { throw WorkspaceError("Fixture Git command failed.") }
            return String(decoding: data, as: UTF8.self)
        }

        private static let checkoutHook = #"""
            #!/bin/sh
            root="$(dirname "$0")/.."
            if [ -f "$root/hold-git" ]; then
                rm "$root/hold-git"
                printf 'entered\n' > "$root/git-entered"
                IFS= read -r release < "$root/git-release"
            fi
            """#

        private static let piHelper = #"""
            root="$1"
            cwd="$(pwd -P)"
            project="$(cd "$2" && pwd -P)"
            while IFS= read -r command; do
                case "$command" in
                    *'"type":"open"'*)
                        if [ "$cwd" != "$project" ] && [ -f "$root/fail-pi" ]; then
                            printf '{"type":"fatal","error":"Fixture could not open the worktree."}\n'
                            exit 0
                        fi
                        if [ "$cwd" != "$project" ] && [ -f "$root/hold-pi" ]; then
                            printf 'entered\n' > "$root/pi-entered"
                            IFS= read -r release < "$root/pi-release"
                            printf '{"type":"ready","messages":[]}\n'
                            printf 'replied\n' > "$root/pi-replied"
                        else
                            printf '{"type":"ready","messages":[]}\n'
                        fi
                        ;;
                    *'"type":"prompt"'*)
                        printf '%s\t%s\n' "$cwd" "$command" >> "$root/prompts"
                        if [ -f "$root/disconnect-on-prompt" ]; then exit 0; fi
                        turn=$(printf '%s' "$command" | sed -En 's/.*"turnID":"([^"]+)".*/\1/p')
                        printf '{"type":"finished","turnID":"%s","messages":[{"id":"fixture","role":"user","text":"Use the original prompt"}]}\n' "$turn"
                        ;;
                esac
            done
            """#
    }
}
