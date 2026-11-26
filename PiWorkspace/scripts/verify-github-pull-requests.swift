import Darwin
import Foundation

@main
struct VerifyGitHubPullRequests {
    static func main() async throws {
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("GIT_") {
            unsetenv(key)
        }
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_OPTIONAL_LOCKS", "0", 1)

        let manager = FileManager.default
        guard CommandLine.arguments.count == 2 else {
            throw Failure(message: "Pass the path to scripts/fixtures/github-read")
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        try expect(manager.isExecutableFile(atPath: fixture.appendingPathComponent("gh").path), "fixture gh is executable")
        let temp = manager.temporaryDirectory.appendingPathComponent("pi-github-" + UUID().uuidString)
        try manager.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temp) }

        let project = temp.appendingPathComponent("project")
        try manager.createDirectory(at: project, withIntermediateDirectories: false)
        _ = try git(project, "init", "-b", "main")
        _ = try git(project, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "--allow-empty", "-m", "Base")
        let worktree = temp.appendingPathComponent("linked worktree")
        _ = try git(project, "worktree", "add", "-b", "fixture", worktree.path)
        let directory = worktree.appendingPathComponent("nested $(printf wrong)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("staged\n".utf8).write(to: directory.appendingPathComponent("edit.txt"))
        _ = try git(worktree, "add", "--all")
        try Data("working\n".utf8).write(to: directory.appendingPathComponent("edit.txt"))

        let state = temp.appendingPathComponent("state")
        let log = temp.appendingPathComponent("commands")
        let env = [
            "PATH": fixture.path + ":/usr/bin:/bin",
            "HOME": temp.path,
            "GH_CONFIG_DIR": temp.appendingPathComponent("isolated-gh-config").path,
            "GH_HOST": "example.invalid",
            "GH_REPO": "example.invalid/other/repo",
            "GH_DEBUG": "api",
            "PI_GH_FIXTURE_STATE": state.path,
            "PI_GH_FIXTURE_LOG": log.path,
        ]
        func mode(_ value: String) throws { try Data(value.utf8).write(to: state) }
        try mode("initial")
        let service = GitHubPullRequests(directory: directory.path, environment: env)
        try await expectFailure("no github.com fetch remote") { try await service.list(.open) }
        let nonGit = GitHubPullRequests(directory: temp.path, environment: env)
        try await expectFailure("read Git remotes") { try await nonGit.list(.open) }

        _ = try git(project, "config", "remote.escaped.url",
                    "https://example.invalid/thing (fetch)\norigin\thttps://github.com/fixture/injected.git")
        try await expectFailure("no github.com fetch remote") { try await service.list(.open) }
        _ = try git(project, "config", "--remove-section", "remote.escaped")
        _ = try git(project, "remote", "add", "origin", "git@github.com:fixture/workspace.git")
        _ = try git(project, "remote", "add", "next", "https://github.com/fixture/other.git")
        let noCLI = GitHubPullRequests(directory: directory.path, environment: ["PATH": temp.path])
        try await expectFailure("GitHub CLI (gh) is unavailable") { try await noCLI.list(.open) }
        try expect(!manager.fileExists(atPath: log.path), "unsupported checkouts and missing gh never launch the mock")

        let before = try snapshot(worktree)
        let listing = try await service.list(.open)
        try expect(listing.repository.slug == "fixture/workspace", "GitHub origin wins over other remotes")
        try expect(listing.items.map(\.number) == [42, 43], "open PRs have the expected numbers")
        try expect(listing.items.first?.stateLabel == "Draft", "draft status is visible")
        let details = try await service.details(for: 42, in: listing.repository)
        try expect(details.pullRequest.title == "Update checkout" && details.pullRequest.author?.login == "fixture-author",
                   "details include the selected PR title and author")
        try expect(details.body == "Fixture description" && details.headRef == "fixture-branch" && details.baseRef == "main",
                   "details include the body and branches")
        try expect(details.url.absoluteString == "https://github.com/fixture/workspace/pull/42", "the PR URL matches the checkout and selection")
        try expect(details.checks.map(\.status) == ["FAILURE", "PENDING", "IN_PROGRESS", "SUCCESS"],
                   "check runs and status contexts expose their current states")
        try expect(details.checks[0].url?.absoluteString == "https://checks.example.invalid/build"
                   && details.checks[1].url?.absoluteString == "https://checks.example.invalid/preview",
                   "check and status URLs point to the correct details")
        try expect(details.checks[2].url == nil && details.checks[3].url == nil,
                   "missing and non-web links have no open action")
        let withoutChecks = try await service.details(for: 43, in: listing.repository)
        try expect(withoutChecks.checks.isEmpty && withoutChecks.pullRequest.author == nil,
                   "a PR without checks or an author still loads")
        let merged = try await service.list(.merged)
        let closed = try await service.list(.closed)
        let all = try await service.list(.all)
        try expect(merged.items.map(\.number) == [41] && closed.items.isEmpty && all.items.count == 3,
                   "the state filter and an empty response work")

        try mode("updated")
        let refreshedList = try await service.list(.open)
        let refreshedDetails = try await service.details(for: 42, in: refreshedList.repository)
        try expect(refreshedList.items.map(\.title) == ["Update checkout (updated)"]
                   && refreshedDetails.headRef == "new-head"
                   && refreshedDetails.checks.map(\.status) == ["SUCCESS"],
                   "refresh reads the updated list, head, and checks")
        try mode("missing")
        try await expectFailure("couldn’t find the pull request") {
            try await service.details(for: 42, in: listing.repository)
        }
        for (fixtureMode, message) in [
            ("no-auth", "gh auth login"), ("forbidden", "denied access"),
            ("network", "Couldn’t reach GitHub"), ("malformed", "unreadable pull request response"),
        ] {
            try mode(fixtureMode)
            try await expectFailure(message) { try await service.list(.open) }
        }
        try mode("timeout")
        let deadlineTest = GitHubPullRequests(directory: directory.path, environment: env, timeout: .milliseconds(250))
        try await expectFailure("timed out") { try await deadlineTest.list(.open) }
        try expect(snapshot(worktree) == before, "reads preserve refs, Git config, the index, and working changes")

        _ = try git(project, "remote", "set-url", "origin", "https://github.com/fixture/other.git")
        let beforeStale = try Data(contentsOf: log)
        try await expectFailure("repository changed") { try await service.details(for: 42, in: listing.repository) }
        try expect(Data(contentsOf: log) == beforeStale, "a stale selection cannot query the new repository")
        _ = try git(project, "remote", "remove", "origin")
        _ = try git(project, "remote", "set-url", "next", "ssh://git@ssh.github.com:443/fixture/workspace.git")
        try mode("initial")
        let soleRemote = try await service.list(.open)
        try expect(soleRemote.repository == listing.repository, "a sole GitHub remote works without origin")
        _ = try git(project, "remote", "add", "another", "https://github.com/fixture/other.git")
        try await expectFailure("multiple GitHub remotes") { try await service.list(.open) }
        _ = try git(project, "remote", "remove", "another")
        _ = try git(project, "remote", "set-url", "next", "https://github.com.example.invalid/fixture/workspace.git")
        try await expectFailure("no github.com fetch remote") { try await service.list(.open) }

        guard let physicalPath = directory.path.withCString({ realpath($0, nil) }) else {
            throw Failure(message: "Couldn’t resolve the fixture checkout path")
        }
        defer { free(physicalPath) }
        let prefix = String(cString: physicalPath) + "|pr "
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        let mismatches = calls.filter {
            !($0.hasPrefix(prefix + "list ") || $0.hasPrefix(prefix + "view "))
                || !$0.hasSuffix("--repo github.com/fixture/workspace")
        }
        try expect(!calls.isEmpty && mismatches.isEmpty,
                   "Expected checkout prefix \(prefix), first mismatched call: \(mismatches.first ?? "<none>")")
        print("Verified GitHub PR listing, detail, check links, refresh, checkout scope, and failure states.")
    }

    private static func snapshot(_ worktree: URL) throws -> [Data] {
        let index = try git(worktree, "rev-parse", "--path-format=absolute", "--git-path", "index")
            .trimmingCharacters(in: .newlines)
        return [
            Data(try git(worktree, "show-ref").utf8),
            Data(try git(worktree, "config", "--local", "--list").utf8),
            Data(try git(worktree, "diff", "HEAD").utf8),
            try Data(contentsOf: URL(fileURLWithPath: index)),
        ]
    }

    private static func git(_ directory: URL, _ arguments: String...) throws -> String {
        let command = Process()
        let output = Pipe()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        command.arguments = ["-C", directory.path] + arguments
        command.standardOutput = output
        try command.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        try expect(command.terminationStatus == 0, "git \(arguments.joined(separator: " ")) succeeded")
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func expectFailure<T>(_ message: String, read: () async throws -> T) async throws {
        do {
            _ = try await read()
        } catch {
            try expect(error.localizedDescription.localizedCaseInsensitiveContains(message),
                       "expected \(message), received \(error.localizedDescription)")
            return
        }
        throw Failure(message: "Expected \(message), received a result")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
