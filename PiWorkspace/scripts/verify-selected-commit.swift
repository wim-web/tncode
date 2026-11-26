import Darwin
import Foundation

// swiftc Sources/PiWorkspace/GitWorkspace.swift scripts/verify-selected-commit.swift -o /tmp/verify-selected-commit
@main
struct VerifySelectedCommit {
    static func main() async throws {
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("GIT_") {
            unsetenv(key)
        }
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_OPTIONAL_LOCKS", "0", 1)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }

        let project = try repository(at: temp.appendingPathComponent("project"))
        let tracked = ["subdir/unstaged.txt", "staged.txt", "mixed.txt", "excluded.txt", "deleted.txt", "rename.txt"]
        try FileManager.default.createDirectory(at: project.appendingPathComponent("subdir"),
                                                withIntermediateDirectories: false)
        for path in tracked { try write("base\n", path, in: project) }
        _ = try git(project, "add", "--all")
        _ = try git(project, "commit", "-m", "Base")

        let checkout = temp.appendingPathComponent("linked worktree")
        _ = try git(project, "worktree", "add", "-b", "selected", checkout.path)
        let workspace = GitWorkspace(path: checkout.appendingPathComponent("subdir").path)
        for path in ["staged.txt", "mixed.txt", "excluded.txt"] { try write("index\n", path, in: checkout) }
        _ = try git(checkout, "add", "staged.txt", "mixed.txt", "excluded.txt")
        try write("index\nworktree\n", "excluded.txt", in: checkout)
        try write("worktree version\n", "mixed.txt", in: checkout)
        try write("unstaged edit\n", "subdir/unstaged.txt", in: checkout)
        let untracked = ":(glob)*\nnew.txt"
        try write("selected new file\n", untracked, in: checkout)
        try write("excluded new file\n", "untracked.txt", in: checkout)
        try FileManager.default.removeItem(at: checkout.appendingPathComponent("deleted.txt"))
        _ = try git(checkout, "mv", "rename.txt", "renamed.txt")

        let excludedEdits = try git(checkout, "diff", "HEAD", "--", "excluded.txt")
        let selected: Set = ["subdir/unstaged.txt", "staged.txt", "mixed.txt", "deleted.txt", "renamed.txt", untracked]
        let changes = try await workspace.state().files
        try expect(selected.isSubset(of: Set(changes.map(\.path))), "all selected paths appear in status")
        try await workspace.commit(message: "Selected", paths: selected)

        let committed = try git(checkout, "show", "--format=", "--name-only", "--no-renames", "-z", "HEAD")
        try expect(Set(committed.split(separator: "\0").map(String.init)) == selected.union(["rename.txt"]),
                   "HEAD changes exactly the selected paths and the rename source")
        try expect(git(checkout, "show", "HEAD:mixed.txt") == "worktree version\n", "mixed file uses its worktree contents")
        try expect(git(checkout, "show", "HEAD:staged.txt") == "index\n", "staged-only contents are committed")
        try expect(git(checkout, "show", "HEAD:\(untracked)") == "selected new file\n", "literal new path is committed")
        try expect(git(checkout, "diff", "--cached").isEmpty, "excluded changes are unstaged")
        try expect(git(checkout, "diff") == excludedEdits, "both excluded edits survive in the worktree")
        try expect(git(checkout, "status", "--porcelain") == " M excluded.txt\n?? untracked.txt\n",
                   "excluded file matches the observed MM to unstaged transition")
        try expect(git(project, "log", "-1", "--format=%s") == "Base\n", "project HEAD is untouched")
        try expect(git(project, "status", "--porcelain").isEmpty, "project index and files are untouched")

        let hooks = temp.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
        let hook = hooks.appendingPathComponent("pre-commit")
        try write("#!/bin/sh\nprintf 'fixture rejected commit\\n' >&2\nexit 1\n", "pre-commit", in: hooks)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try git(checkout, "config", "core.hooksPath", hooks.path)
        let indexPath = try git(checkout, "rev-parse", "--path-format=absolute", "--git-path", "index").dropLast()
        let index = URL(fileURLWithPath: String(indexPath))
        _ = try git(checkout, "add", "excluded.txt")
        let before = try Data(contentsOf: index)
        try await expectCommitFailure(workspace, paths: ["untracked.txt"], containing: "fixture rejected commit")
        try expect(Data(contentsOf: index) == before, "hook failure preserves the index byte-for-byte")
        try expect(git(checkout, "log", "-1", "--format=%s") == "Selected\n", "hook failure leaves HEAD in place")
        try expect(String(contentsOf: checkout.appendingPathComponent("untracked.txt"), encoding: .utf8)
                   == "excluded new file\n", "hook failure leaves the selected worktree file in place")
        let lock = URL(fileURLWithPath: index.path + ".lock")
        try expect(!FileManager.default.fileExists(atPath: lock.path), "hook failure releases the index lock")
        try Data("other Git process".utf8).write(to: lock)
        try await expectCommitFailure(workspace, paths: ["untracked.txt"], containing: "index is locked")
        try expect(String(contentsOf: lock, encoding: .utf8) == "other Git process", "an existing lock is preserved")
        try FileManager.default.removeItem(at: lock)
        try await expectCommitFailure(workspace, paths: ["missing.txt"], containing: "selected changes have changed")
        try await expectCommitFailure(workspace, paths: [], containing: "Select at least one file")

        _ = try git(checkout, "mv", "renamed.txt", "again.txt")
        try write("excluded replacement\n", "renamed.txt", in: checkout)
        let renameIndex = try Data(contentsOf: index)
        try await expectCommitFailure(workspace, paths: ["again.txt"], containing: "overlap renamed.txt")
        try expect(Data(contentsOf: index) == renameIndex, "a conflicting selection preserves the index")

        let unborn = try repository(at: temp.appendingPathComponent("unborn"))
        try write("initial\n", "first.txt", in: unborn)
        try write("left out\n", "second.txt", in: unborn)
        try await GitWorkspace(path: unborn.path).commit(message: "Initial", paths: ["first.txt"])
        try expect(git(unborn, "ls-tree", "--name-only", "HEAD") == "first.txt\n", "initial commit respects selection")
        try expect(git(unborn, "status", "--porcelain") == "?? second.txt\n", "excluded file remains untracked")
        print("Selected commits passed in a linked worktree and an unborn repository.")
    }

    private static func repository(at directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try git(directory, "init", "--initial-branch", "main")
        _ = try git(directory, "config", "user.name", "Fixture")
        _ = try git(directory, "config", "user.email", "fixture@example.invalid")
        _ = try git(directory, "config", "commit.gpgsign", "false")
        _ = try git(directory, "config", "core.hooksPath", directory.appendingPathComponent("no-hooks").path)
        return directory
    }

    private static func write(_ text: String, _ path: String, in directory: URL) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(path))
    }

    private static func git(_ directory: URL, _ arguments: String...) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "--literal-pathspecs", "-C", directory.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func expectCommitFailure(_ workspace: GitWorkspace, paths: Set<String>, containing reason: String) async throws {
        do {
            try await workspace.commit(message: "Should fail", paths: paths)
        } catch {
            try expect(error.localizedDescription.contains(reason), "commit rejected: \(error.localizedDescription)")
            return
        }
        throw CheckFailure(message: "commit should fail with \(reason)")
    }

    private static func expect(_ pass: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try pass() else { throw CheckFailure(message: message) }
    }

    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
