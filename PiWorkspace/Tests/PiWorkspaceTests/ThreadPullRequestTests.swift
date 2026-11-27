import Darwin
import Foundation
import XCTest
@testable import PiWorkspace

@MainActor
final class ThreadPullRequestTests: XCTestCase {
    func testProjectSwitchMovesADraftContainingOnlyAPullRequestLink() async throws {
        let fixture = try ThreadGitHubFixture()
        let source: ThreadGitHubScope
        let destination: UUID
        do {
            let model = fixture.open()
            source = try XCTUnwrap(model.gitHubScope)
            let folder = fixture.root.appendingPathComponent("other-project", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try model.openProject(folder)
            destination = try XCTUnwrap(model.project?.id)
            model.selectConversation(source.threadID, in: source.projectID)
            let repository = try await model.gitHubRepository(in: source)
            try await model.linkPullRequest("#42", in: source, repository: repository)
            XCTAssertNil(model.conversation?.composerText)
            model.switchDraftProject(to: destination)
            XCTAssertEqual(model.project?.id, destination)
            XCTAssertEqual(model.conversation?.id, source.threadID)
            XCTAssertEqual(model.conversation?.pullRequestLinks.first?.reference.url.absoluteString,
                           "https://github.com/fixture/workspace/pull/42")
            let prior = try XCTUnwrap(model.workspace.projects.first { $0.id == source.projectID })
            XCTAssertFalse(prior.conversations.contains { $0.id == source.threadID })
            XCTAssertTrue(model.terminate())
        }
        let reopened = fixture.open()
        XCTAssertEqual(reopened.project?.id, destination)
        XCTAssertEqual(reopened.conversation?.id, source.threadID)
        XCTAssertEqual(reopened.conversation?.pullRequestLinks.first?.reference.number, 42)
    }

    func testLinksPersistByThreadAndRepository() async throws {
        let fixture = try ThreadGitHubFixture()
        let workspaceURL = fixture.workspace.appendingPathComponent("workspace.json")
        XCTAssertFalse(try String(contentsOf: workspaceURL, encoding: .utf8).contains("linkedPullRequests"))
        let first: ThreadGitHubScope
        let firstURL = "https://github.com/fixture/workspace/pull/42"
        let otherURL = "https://github.com/fixture/other/pull/42"
        do {
            let model = fixture.open()
            first = try XCTUnwrap(model.gitHubScope)
            XCTAssertEqual(first.directory, fixture.checkout.path)
            XCTAssertTrue(try XCTUnwrap(model.conversation).pullRequestLinks.isEmpty)
            let repository = try await model.gitHubRepository(in: first)
            try await model.linkPullRequest(" #42 ", in: first, repository: repository)

            try fixture.setRemote("https://GitHub.com/FIXTURE/Workspace.git")
            try await model.linkPullRequest("https://GitHub.com/Fixture/Workspace/pull/42/files#diff-123", in: first,
                                            repository: repository)
            let linked = try XCTUnwrap(model.conversation)
            XCTAssertTrue(model.showsInSidebar(linked), "A linked draft is available in the sidebar")
            XCTAssertEqual(linked.pullRequestLinks.map(\.reference.url.absoluteString), [firstURL])
            XCTAssertEqual(linked.pullRequestLinks.first?.title, "Update checkout")

            model.selectConversation(fixture.secondThread, in: first.projectID)
            XCTAssertTrue(try XCTUnwrap(model.conversation).pullRequestLinks.isEmpty)
            XCTAssertThrowsError(try model.unlinkPullRequest(XCTUnwrap(linked.pullRequestLinks.first).reference, in: first))
            model.selectConversation(first.threadID, in: first.projectID)

            try fixture.setRemote("https://github.com/fixture/other.git")
            await expectFailure("repository changed") {
                try await model.linkPullRequest("42", in: first, repository: repository)
            }
            fixture.expectedRepository = "github.com/fixture/other"
            let other = try await model.gitHubRepository(in: first)
            try await model.linkPullRequest("42", in: first, repository: other)
            XCTAssertEqual(model.conversation?.pullRequestLinks.map(\.reference.url.absoluteString), [firstURL, otherURL])
            model.terminate()
        }

        let relaunched = fixture.open()
        defer { relaunched.terminate() }
        relaunched.start()
        XCTAssertEqual(relaunched.gitHubScope, first)
        let saved = try XCTUnwrap(relaunched.conversation?.pullRequestLinks)
        XCTAssertEqual(saved.map(\.reference.url.absoluteString), [firstURL, otherURL])
        XCTAssertEqual(saved.map(\.reference.number), [42, 42])
        XCTAssertEqual(Set(saved.map(\.id)).count, 2)

        try fixture.setRemote("https://example.invalid/fixture/other.git")
        await expectFailure("no github.com fetch remote") { try await relaunched.gitHubRepository(in: first) }
        try relaunched.unlinkPullRequest(saved[0].reference, in: first)
        XCTAssertEqual(relaunched.conversation?.pullRequestLinks.map(\.reference.url.absoluteString), [otherURL])
        try relaunched.unlinkPullRequest(saved[1].reference, in: first)
        XCTAssertTrue(try XCTUnwrap(relaunched.conversation).pullRequestLinks.isEmpty)
        XCTAssertFalse(try String(contentsOf: workspaceURL, encoding: .utf8).contains("linkedPullRequests"))
        XCTAssertEqual(try fixture.commands().count, 3)
    }

    func testInvalidReferencesAndFailedReadsLeaveNoLink() async throws {
        let fixture = try ThreadGitHubFixture()
        let model = fixture.open()
        defer { model.terminate() }
        let scope = try XCTUnwrap(model.gitHubScope)
        let repository = try await model.gitHubRepository(in: scope)
        for input in ["#0", "-42", "https://github.com/fixture/workspace/issues/42",
                      "https://github.com.evil.invalid/fixture/workspace/pull/42",
                      "https://user@github.com/fixture/workspace/pull/42"] {
            await expectFailure("Enter a GitHub pull request URL") {
                try await model.linkPullRequest(input, in: scope, repository: repository)
            }
        }
        await expectFailure("uses fixture/workspace") {
            try await model.linkPullRequest("https://github.com/fixture/other/pull/42", in: scope, repository: repository)
        }
        XCTAssertTrue(try fixture.commands().isEmpty)

        for (mode, error) in [("missing", "couldn’t find the pull request"), ("no-auth", "gh auth login"),
                              ("wrong-repo", "unreadable pull request response")] {
            try fixture.setMode(mode)
            await expectFailure(error) { try await model.linkPullRequest("#42", in: scope, repository: repository) }
            XCTAssertTrue(try XCTUnwrap(model.conversation).pullRequestLinks.isEmpty)
        }
        let path = try XCTUnwrap(fixture.checkout.path.withCString { realpath($0, nil) })
        defer { free(path) }
        for command in try fixture.commands() {
            XCTAssertTrue(command.hasPrefix(String(cString: path) + "|pr view 42 "), String(command))
            XCTAssertTrue(command.hasSuffix("--repo github.com/fixture/workspace"), String(command))
        }
    }

    func testStaleReadCannotLinkAfterThreadSwitchOrRemoteChange() async throws {
        let fixture = try ThreadGitHubFixture()
        let model = fixture.open()
        defer { model.terminate() }
        let scope = try XCTUnwrap(model.gitHubScope)
        let repository = try await model.gitHubRepository(in: scope)
        try await fixture.holdRead {
            let task = Task { try await model.linkPullRequest("#42", in: scope, repository: repository) }
            try await fixture.waitForRead()
            model.selectConversation(fixture.secondThread, in: scope.projectID)
            model.selectConversation(scope.threadID, in: scope.projectID)
            try fixture.releaseRead()
            await expectFailure("selected thread or checkout changed") { try await task.value }
        }
        try await fixture.holdRead {
            let task = Task { try await model.linkPullRequest("#42", in: scope, repository: repository) }
            try await fixture.waitForRead()
            try fixture.setRemote("https://github.com/fixture/other.git")
            try fixture.releaseRead()
            await expectFailure("repository changed") { try await task.value }
        }
        try fixture.setRemote("git@github.com:fixture/workspace.git")
        try await fixture.holdRead {
            let task = Task { try await model.linkPullRequest("#42", in: scope, repository: repository) }
            try await fixture.waitForRead()
            task.cancel()
            try fixture.releaseRead()
            do {
                try await task.value
                XCTFail("A dismissed request completed")
            } catch is CancellationError {}
        }
        XCTAssertTrue(try XCTUnwrap(model.project).conversations.allSatisfy { $0.pullRequestLinks.isEmpty })
    }

    private func expectFailure<T>(_ message: String, operation: () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(message)", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(message), error.localizedDescription,
                          file: file, line: line)
        }
    }
}

final class ThreadGitHubFixture {
    let root: URL
    let workspace: URL
    let checkout: URL
    let secondThread = UUID()
    var issueWrites = false
    var expectedRepository = "github.com/fixture/workspace"
    var index: URL { workspace.appendingPathComponent("workspace.json") }
    private var state: URL { root.appendingPathComponent("state") }
    private var log: URL { root.appendingPathComponent("commands") }
    private var gate: URL { root.appendingPathComponent("gh-gate") }

    private let ownsRoot: Bool

    init(reopening existingRoot: URL? = nil) throws {
        ownsRoot = existingRoot == nil
        root = existingRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        checkout = root.appendingPathComponent("selected checkout", isDirectory: true)
        if existingRoot != nil { return }
        let projectFolder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        try git("init", "--quiet")
        try git("remote", "add", "origin", "git@github.com:fixture/workspace.git")
        try setMode("initial")
        let first = Conversation(id: UUID(), title: "First", location: .worktree(path: checkout.path, base: nil), isDraft: true)
        let second = Conversation(id: secondThread, title: "Second")
        let project = Project(id: UUID(), path: projectFolder.path, title: "Project",
                              conversations: [first, second], selectedConversation: first.id)
        try WorkspaceStore(root: workspace).save(Workspace(projects: [project], selectedProject: project.id))
    }

    deinit { if ownsRoot { try? FileManager.default.removeItem(at: root) } }

    @MainActor
    func open() -> WorkspaceModel {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let mock = package.appendingPathComponent("scripts/fixtures/\(issueWrites ? "github-issue" : "github-read")",
                                                  isDirectory: true)
        return WorkspaceModel(root: workspace, keychainService: "pi-workspace-github-fixture",
                              credentialExists: { _ in false }, readCredential: { _ in nil },
                              makeProcess: { _, _ in throw FixtureError.noSidecar },
                              makeGitHubReader: { directory in
            GitHubReader(directory: directory, environment: [
                "PATH": mock.path + ":/usr/bin:/bin",
                "HOME": self.root.path,
                "PI_GH_FIXTURE_REPO": self.expectedRepository,
                "PI_GH_FIXTURE_STATE": self.state.path,
                "PI_GH_FIXTURE_LOG": self.log.path,
                "PI_GH_FIXTURE_GATE": self.gate.path,
                "PI_GH_ISSUE_DIR": self.root.path,
            ])
        })
    }

    func setRemote(_ url: String) throws { try git("remote", "set-url", "origin", url) }
    func setMode(_ mode: String) throws { try Data(mode.utf8).write(to: state, options: .atomic) }

    func makeOtherCheckout() throws -> URL {
        let folder = root.appendingPathComponent("other checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try git("init", "--quiet", in: folder)
        try git("remote", "add", "origin", "https://GitHub.com/FIXTURE/Other.git", in: folder)
        return folder
    }

    func commands() throws -> [Substring] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    }

    @MainActor
    func holdRead(_ operation: () async throws -> Void) async throws {
        try setMode("held")
        defer {
            try? releaseRead()
            try? FileManager.default.removeItem(at: gate.appendingPathExtension("started"))
        }
        try? FileManager.default.removeItem(at: gate.appendingPathExtension("release"))
        try await operation()
    }

    func waitForRead() async throws {
        let started = gate.appendingPathExtension("started")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: started.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.readDidNotStart
    }

    func releaseRead() throws { try Data().write(to: gate.appendingPathExtension("release")) }

    struct IssueWireRequest: Decodable {
        let kind: String
        let repo: String
        let number: Int
        let cwd: String
        let method: String?
        let mode: String?
        let payload: [String: String]?
    }

    func issueRequestsLog() throws -> [IssueWireRequest] {
        let requests = root.appendingPathComponent("issue-requests.jsonl")
        guard FileManager.default.fileExists(atPath: requests.path) else { return [] }
        return try String(contentsOf: requests, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(IssueWireRequest.self, from: Data($0.utf8)) }
    }

    func issueWritesLog() throws -> [IssueWireRequest] {
        try issueRequestsLog().filter { $0.kind == "write" }
    }

    func waitForIssuePreflight() async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("issue-read-started").path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.readDidNotStart
    }

    func releaseIssueWrite() throws { try Data().write(to: root.appendingPathComponent("issue-write-released")) }

    func resetIssuePreflight() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("issue-read-started"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("issue-write-released"))
    }

    private func git(_ arguments: String..., in folder: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", (folder ?? checkout).path] + arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            .merging(["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], uniquingKeysWith: { _, new in new })
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError.gitFailure(arguments) }
    }

    private enum FixtureError: Error {
        case noSidecar, readDidNotStart, gitFailure([String])
    }
}
