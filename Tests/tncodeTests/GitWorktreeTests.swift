import XCTest
@testable import tncode

final class GitWorktreeTests: XCTestCase {
    func testRetryAfterObstructedDestinationAndInterruptedCheckout() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitWorkspace.createRepository(named: "original", in: root)
        try git(repo, ["commit", "--allow-empty", "-m", "Base"])
        let workspace = GitWorkspace(path: repo.path)
        let path = root.appendingPathComponent("checkout")
        let thread = UUID()
        let pending = try await workspace.pinWorktree(at: path.path, branch: "topic", base: "HEAD", owner: thread)
        try Data("keep".utf8).write(to: path)
        do {
            _ = try await workspace.createWorktree(pending)
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
            _ = try await workspace.createWorktree(pending)
            XCTFail("An unrelated detached checkout must not be adopted.")
        } catch {
            let list = try await workspace.worktrees()
            XCTAssertNil(list.first { $0.path == path.resolvingSymlinksInPath().path }?.branch)
        }
        try git(repo, ["worktree", "lock", "--reason", "tncode preparing " + thread.uuidString, "--", path.path])
        _ = try await workspace.createWorktree(pending)
        _ = try await workspace.createWorktree(pending)
        let checkouts = try await workspace.worktrees()
        XCTAssertEqual(checkouts.count, 2)
        XCTAssertEqual(checkouts.first { $0.path == path.resolvingSymlinksInPath().path }?.branch, "topic")
        XCTAssertEqual(try String(contentsOf: edit, encoding: .utf8), "keep this edit")
    }

    func testCleanupPreservesAChangedHeadAndABranchRecreatedAtThePinnedHead() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitWorkspace.createRepository(named: "original", in: root)
        try git(repo, ["commit", "--allow-empty", "-m", "Base"])
        let workspace = GitWorkspace(path: repo.path)
        let path = root.appendingPathComponent("checkout")
        let pending = try await workspace.pinWorktree(at: path.path, branch: "topic", base: "HEAD", owner: UUID())
        _ = try await workspace.createWorktree(pending)
        try git(path, ["commit", "--allow-empty", "-m", "User commit"])
        try await workspace.discardPendingCheckout(pending, attached: true)
        let checkouts = try await workspace.worktrees()
        let checkout = try XCTUnwrap(checkouts.first { $0.path == path.path })
        XCTAssertNotEqual(checkout.head, pending.head)
        XCTAssertEqual(checkout.branch, "topic")

        try git(repo, ["worktree", "remove", "--", path.path])
        try git(repo, ["branch", "-D", "topic"])
        try git(repo, ["branch", "topic", pending.head])
        try await workspace.discardPendingCheckout(pending, attached: true)
        let state = try await workspace.state()
        XCTAssertTrue(state.branches.contains("topic"))
    }

    func testRetryDoesNotFollowAReplacedStorageAncestor() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let repo = try await GitWorkspace.createRepository(named: "original", in: root)
        try git(repo, ["commit", "--allow-empty", "-m", "Base"])
        let workspace = GitWorkspace(path: repo.path)
        let storage = root.appendingPathComponent("storage")
        let parent = storage.appendingPathComponent("project")
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("checkout")
        let pending = try await workspace.pinWorktree(at: target.path, branch: "topic", base: "HEAD", owner: UUID())
        let outside = root.appendingPathComponent("unowned")
        try files.createDirectory(at: outside, withIntermediateDirectories: false)
        try files.removeItem(at: storage)
        try files.createSymbolicLink(at: storage, withDestinationURL: outside)
        do {
            _ = try await workspace.createWorktree(pending)
            XCTFail("Retry followed the replaced storage folder.")
        } catch {
            XCTAssertEqual(try files.contentsOfDirectory(atPath: outside.path), [])
        }
        let checkouts = try await workspace.worktrees()
        XCTAssertEqual(checkouts.map(\.path), [repo.path])
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
