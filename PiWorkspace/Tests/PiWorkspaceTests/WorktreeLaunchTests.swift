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
            let observation = model.$error.compactMap { $0 }.first().sink { _ in disconnected.fulfill() }
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

    private func failed(_ model: WorkspaceModel) async {
        let failure = expectation(description: "The preparation failure was saved")
        let observation = model.$workspace.filter {
            $0.activeProject?.conversations.first?.worktreeLaunch?.failure != nil
        }.first().sink { _ in failure.fulfill() }
        await fulfillment(of: [failure], timeout: 10)
        observation.cancel()
    }

    private final class Fixture {
        struct Prompt: Equatable {
            let cwd: String
            let text: String
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
                           readCredential: { _ in "fixture-key" }) { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", Self.piHelper, "launch-fixture", self.root.path, self.repo.path])
            }
        }

        func savedThread() throws -> Conversation {
            let index = workspace.appendingPathComponent("workspace.json")
            let data = try Data(contentsOf: index)
            return try XCTUnwrap(JSONDecoder().decode(Workspace.self, from: data).activeProject?.conversations.first)
        }

        func target() throws -> URL {
            let data = try Data(contentsOf: workspace.appendingPathComponent("workspace.json"))
            let project = try XCTUnwrap(JSONDecoder().decode(Workspace.self, from: data).activeProject)
            return try workspace.appendingPathComponent("worktrees").appendingPathComponent(project.id.uuidString)
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

        @discardableResult
        func git(_ arguments: [String]) throws -> String {
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            command.arguments = ["-C", repo.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
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
                        printf '{"type":"finished","messages":[{"id":"fixture","role":"user","text":"Use the original prompt"}]}\n'
                        ;;
                esac
            done
            """#
    }
}
