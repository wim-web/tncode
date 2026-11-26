import XCTest
@testable import PiWorkspace

final class GitWorktreeTests: XCTestCase {
    func testRetryAfterObstructedDestinationAndInterruptedCheckout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitWorkspace.createRepository(named: "original", in: root)
        try git(repo, ["commit", "--allow-empty", "-m", "Base"])
        let workspace = GitWorkspace(path: repo.path)
        let path = root.appendingPathComponent("checkout")
        let thread = UUID()
        try Data("keep".utf8).write(to: path)
        do {
            _ = try await workspace.createWorktree(at: path.path, branch: "topic", base: "HEAD", for: thread)
            XCTFail("A regular file cannot be a checkout.")
        } catch {
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "keep")
        }
        let afterFailure = try await workspace.state()
        XCTAssertFalse(afterFailure.branches.contains("topic"), "A failed checkout must not reserve the branch name.")
        try FileManager.default.removeItem(at: path)
        try git(repo, ["worktree", "add", "--detach", "--", path.path, "HEAD"])
        let edit = path.appendingPathComponent("note")
        try Data("keep this edit".utf8).write(to: edit)
        do {
            _ = try await workspace.createWorktree(at: path.path, branch: "topic", base: "HEAD", for: thread)
            XCTFail("An unrelated detached checkout must not be adopted.")
        } catch {
            let list = try await workspace.worktrees()
            XCTAssertNil(list.first { $0.path == path.resolvingSymlinksInPath().path }?.branch)
        }
        try git(repo, ["worktree", "lock", "--reason", "Pi Workspace preparing " + thread.uuidString, "--", path.path])
        _ = try await workspace.createWorktree(at: path.path, branch: "topic", base: "HEAD", for: thread)
        _ = try await workspace.createWorktree(at: path.path, branch: "topic", base: "HEAD", for: thread)
        let checkouts = try await workspace.worktrees()
        XCTAssertEqual(checkouts.count, 2)
        XCTAssertEqual(checkouts.first { $0.path == path.resolvingSymlinksInPath().path }?.branch, "topic")
        XCTAssertEqual(try String(contentsOf: edit, encoding: .utf8), "keep this edit")
    }

    private func git(_ directory: URL, _ arguments: [String]) throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        command.arguments = ["-C", directory.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
    }
}
