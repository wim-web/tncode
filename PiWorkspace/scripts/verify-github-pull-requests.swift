import Darwin
import Foundation

@main
struct VerifyGitHubPullRequests {
    @MainActor
    static func main() async throws {
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("GIT_") {
            unsetenv(key)
        }
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_OPTIONAL_LOCKS", "0", 1)

        let manager = FileManager.default
        if CommandLine.arguments.dropFirst().elementsEqual(["--public-cli"]) {
            try await verifyPublicRepository()
            return
        }
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
        let gate = temp.appendingPathComponent("gh-gate")
        let env = [
            "PATH": fixture.path + ":/usr/bin:/bin",
            "HOME": temp.path,
            "GH_CONFIG_DIR": temp.appendingPathComponent("isolated-gh-config").path,
            "GH_HOST": "example.invalid",
            "GH_REPO": "example.invalid/other/repo",
            "GH_DEBUG": "api",
            "PI_GH_FIXTURE_STATE": state.path,
            "PI_GH_FIXTURE_LOG": log.path,
            "PI_GH_FIXTURE_GATE": gate.path,
        ]
        func mode(_ value: String) throws { try Data(value.utf8).write(to: state, options: .atomic) }
        try mode("initial")
        let service = GitHubReader(directory: directory.path, environment: env)
        try await expectFailure("no github.com fetch remote") { try await service.list(.init(.pullRequests, .open)) }
        let nonGit = GitHubReader(directory: temp.path, environment: env)
        try await expectFailure("read Git remotes") { try await nonGit.list(.init(.pullRequests, .open)) }

        _ = try git(project, "config", "remote.escaped.url",
                    "https://example.invalid/thing (fetch)\norigin\thttps://github.com/fixture/injected.git")
        try await expectFailure("no github.com fetch remote") { try await service.list(.init(.pullRequests, .open)) }
        _ = try git(project, "config", "--remove-section", "remote.escaped")
        _ = try git(project, "remote", "add", "origin", "git@github.com:fixture/workspace.git")
        _ = try git(project, "remote", "add", "next", "https://github.com/fixture/other.git")
        let noCLI = GitHubReader(directory: directory.path, environment: ["PATH": temp.path])
        try await expectFailure("GitHub CLI (gh) is unavailable") { try await noCLI.list(.init(.pullRequests, .open)) }
        try expect(!manager.fileExists(atPath: log.path), "unsupported checkouts and missing gh never launch the mock")

        let before = try snapshot(worktree)
        let listing = try await service.list(.init(.pullRequests, .open))
        try expect(listing.repository.slug == "fixture/workspace", "GitHub origin wins over other remotes")
        try expect(listing.items.map(\.number) == [42, 43], "open PRs have the expected numbers")
        try expect(listing.items.first?.stateLabel == "Draft", "draft status is visible")
        let details = try await service.pullRequestDetails(for: 42, in: listing.repository)
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
        let withoutChecks = try await service.pullRequestDetails(for: 43, in: listing.repository)
        try expect(withoutChecks.checks.isEmpty && withoutChecks.pullRequest.author == nil,
                   "a PR without checks or an author still loads")
        let merged = try await service.list(.init(.pullRequests, .merged))
        let closed = try await service.list(.init(.pullRequests, .closed))
        let all = try await service.list(.init(.pullRequests, .all))
        try expect(merged.items.map(\.number) == [41] && closed.items.isEmpty && all.items.count == 3,
                   "the state filter and an empty response work")

        try mode("updated")
        let refreshedList = try await service.list(.init(.pullRequests, .open))
        let refreshedDetails = try await service.pullRequestDetails(for: 42, in: refreshedList.repository)
        try expect(refreshedList.items.map(\.title) == ["Update checkout (updated)"]
                   && refreshedDetails.headRef == "new-head"
                   && refreshedDetails.checks.map(\.status) == ["SUCCESS"],
                   "refresh reads the updated list, head, and checks")
        try mode("missing")
        try await expectFailure("couldn’t find the pull request") {
            try await service.pullRequestDetails(for: 42, in: listing.repository)
        }
        for (fixtureMode, message) in [
            ("no-auth", "gh auth login"), ("forbidden", "denied access"),
            ("network", "Couldn’t reach GitHub"), ("malformed", "unreadable pull request response"),
        ] {
            try mode(fixtureMode)
            try await expectFailure(message) { try await service.list(.init(.pullRequests, .open)) }
        }
        try mode("timeout")
        let deadlineTest = GitHubReader(directory: directory.path, environment: env, timeout: .milliseconds(250))
        try await expectFailure("timed out") { try await deadlineTest.list(.init(.pullRequests, .open)) }
        try mode("initial")
        let issueCursor = try await verifyBrowsing(service, mode: mode, gate: gate, log: log)
        try expect(snapshot(worktree) == before, "reads preserve refs, Git config, the index, and working changes")

        _ = try git(project, "remote", "set-url", "origin", "https://github.com/fixture/other.git")
        let beforeStale = try Data(contentsOf: log)
        try await expectFailure("repository changed") { try await service.pullRequestDetails(for: 42, in: listing.repository) }
        try await expectFailure("repository changed") {
            try await service.list(.init(.issues), after: issueCursor)
        }
        try await expectFailure("repository changed") {
            try await service.issueDetails(for: 71, in: listing.repository)
        }
        try expect(Data(contentsOf: log) == beforeStale, "a stale selection cannot query the new repository")
        _ = try git(project, "remote", "remove", "origin")
        _ = try git(project, "remote", "set-url", "next", "ssh://git@ssh.github.com:443/fixture/workspace.git")
        try mode("initial")
        let soleRemote = try await service.list(.init(.pullRequests, .open))
        try expect(soleRemote.repository == listing.repository, "a sole GitHub remote works without origin")
        _ = try git(project, "remote", "add", "another", "https://github.com/fixture/other.git")
        try await expectFailure("multiple GitHub remotes") { try await service.list(.init(.pullRequests, .open)) }
        _ = try git(project, "remote", "remove", "another")
        _ = try git(project, "remote", "set-url", "next", "https://github.com.example.invalid/fixture/workspace.git")
        try await expectFailure("no github.com fetch remote") { try await service.list(.init(.pullRequests, .open)) }

        guard let physicalPath = directory.path.withCString({ realpath($0, nil) }) else {
            throw Failure(message: "Couldn’t resolve the fixture checkout path")
        }
        defer { free(physicalPath) }
        let prefix = String(cString: physicalPath) + "|"
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        for call in calls {
            try expect(call.hasPrefix(prefix), "gh runs in the selected worktree subdirectory")
            let arguments = call.dropFirst(prefix.count)
            try expect(arguments.hasPrefix("api graphql --hostname github.com ")
                       || ((arguments.hasPrefix("pr view ") || arguments.hasPrefix("issue view "))
                           && arguments.hasSuffix("--repo github.com/fixture/workspace")),
                       "only GitHub read commands can reach the mock: \(arguments)")
        }
        print("Verified PR and Issue lists and details, query and label filters, cursor pagination, refresh and retry.")
        print("Verified stale response rejection, selected checkout scope, and preservation of Git state.")
    }

    @MainActor
    private static func verifyBrowsing(
        _ service: GitHubReader, mode: (String) throws -> Void, gate: URL, log: URL
    ) async throws -> GitHubListPage.Next {
        let issues = GitHubBrowserModel(kind: .issues, reader: service)
        await issues.load(issues.request)
        let first = try results(issues)
        try expect(first.items.map(\.number) == [71, 72] && first.items.first?.labelNames == ["bug"],
                   "open issues include their state and label metadata")
        let cursor = try require(first.next, "issue repository list has a second page")
        issues.select(first.items[0], in: first.repository)
        let originalSelection = issues.selection
        let selected = try await service.issueDetails(for: 71, in: first.repository)
        try expect(selected.title == "Checkout socket timeout" && selected.state == "OPEN"
                   && selected.author?.login == "fixture-reporter" && selected.labels.map(\.name) == ["bug"]
                   && selected.body == "Fixture issue description."
                   && selected.url.absoluteString == "https://github.com/fixture/workspace/issues/71",
                   "issue detail reads the selected issue with its metadata and checkout link")

        try mode("page-error")
        issues.loadMore()
        await issues.load(issues.request)
        guard case .loaded(let retained, .failed(let error)) = issues.listing else {
            throw Failure(message: "next-page error should keep the first page available")
        }
        try expect(retained.items.map(\.number) == [71, 72] && issues.selection?.number == 71
                   && error.contains("Couldn’t reach GitHub"), "page error preserves rows and selected detail")
        try mode("initial")
        issues.loadMore()
        await issues.load(issues.request)
        let appended = try results(issues)
        try expect(appended.items.map(\.number) == [71, 72, 73] && appended.next == nil
                   && issues.selection == originalSelection, "page retry appends once and keeps the open detail")
        let noBody = try await service.issueDetails(for: 73, in: first.repository)
        try expect(noBody.author == nil && noBody.body.isEmpty, "an issue can have no author or body")
        let allIssues = try await service.list(.init(.issues, .all))
        try expect(allIssues.items.map(\.number) == [71, 72, 73, 70],
                   "the All filter includes both open and closed issues")

        let prs = GitHubBrowserModel(kind: .pullRequests, reader: service)
        prs.searchText = "label:bug"
        prs.applySearch(filter: .open)
        await prs.load(prs.request)
        let bugs = try results(prs)
        try expect(bugs.items.map(\.number) == [42] && bugs.items.first?.stateLabel == "Draft"
                   && bugs.items.first?.labelNames == ["bug"] && bugs.next != nil,
                   "PR label search excludes documentation PRs and exposes the next page")
        prs.loadMore()
        prs.loadMore()
        await prs.load(prs.request)
        let allBugs = try results(prs)
        try expect(allBugs.items.map(\.number) == [42, 44] && allBugs.next == nil,
                   "PR next page deduplicates overlapping results and reaches the end")
        prs.searchText = "checkout"
        prs.applySearch(filter: .open)
        await prs.load(prs.request)
        try expect(results(prs).items.map(\.number) == [42, 44], "plain PR search returns matching PRs")
        prs.searchText = "label:bug"
        prs.applySearch(filter: .closed)
        await prs.load(prs.request)
        try expect(results(prs).items.isEmpty && results(prs).next == nil, "state applies to PR search")

        let issueSearch = GitHubListQuery(.issues, text: "label:bug")
        let firstBug = try await service.list(issueSearch)
        let nextBug = try await service.list(issueSearch, after: try require(firstBug.next, "issue search has another page"))
        try expect(firstBug.items.map(\.number) == [71] && nextBug.items.map(\.number) == [73] && nextBug.next == nil,
                   "Issue label search pages through bug issues")
        let phrase = try await service.list(.init(.issues, text: #""slow worker" label:"needs triage""#))
        try expect(phrase.items.map(\.number) == [73], "quoted text and spaced labels travel as one query argument")
        let plain = try await service.list(.init(.issues, text: "socket"))
        try expect(plain.items.map(\.number) == [71], "plain issue search returns the matching row")
        let restricted = try await service.list(.init(.issues, text: "repo:fixture/unrelated OR $(printf wrong)"))
        try expect(restricted.items.isEmpty, "repository and Boolean qualifiers remain literal search words")
        let empty = try await service.list(.init(.issues, text: "empty"))
        try expect(empty.items.isEmpty && empty.next == nil, "a search with no matches has no next page")

        let invalidStart = try Data(contentsOf: log)
        try await expectFailure("paired quotes") { try await service.list(.init(.issues, text: #"label:"needs triage"#)) }
        try await expectFailure("unreadable issue response") { try await service.list(.init(.issues, .closed), after: cursor) }
        try expect(Data(contentsOf: log) == invalidStart, "invalid search and a cursor from another scope launch no gh")

        for (fixtureMode, message) in [
            ("no-auth", "gh auth login"), ("forbidden", "denied access"),
            ("network", "Couldn’t reach GitHub"), ("malformed", "unreadable issue response"),
            ("wrong-repo", "unreadable issue response"),
        ] {
            try mode(fixtureMode)
            try await expectFailure(message) { try await service.list(.init(.issues)) }
        }
        try mode("missing")
        try await expectFailure("couldn’t find the issue") { try await service.issueDetails(for: 71, in: first.repository) }

        try mode("no-auth")
        issues.refresh()
        await issues.load(issues.request)
        guard case .failed(let signIn) = issues.listing else {
            throw Failure(message: "signed-out list should provide a sign-in and retry path")
        }
        try expect(signIn.contains("gh auth login"), "signed-out list gives CLI sign-in guidance")
        try mode("initial")
        issues.refresh()
        await issues.load(issues.request)
        try expect(results(issues).items.map(\.number) == [71, 72] && issues.selection?.number == 71
                   && issues.selection != originalSelection, "retry recovers the list and reloads the selected detail")

        try mode("held")
        issues.loadMore()
        let pageWork = issues.request
        let oldPage = Task { await issues.load(pageWork) }
        try await waitForMock(gate)
        try mode("updated")
        issues.refresh()
        await issues.load(issues.request)
        try releaseMock(gate)
        await oldPage.value
        try FileManager.default.removeItem(at: gate.appendingPathExtension("release"))
        try FileManager.default.removeItem(at: gate.appendingPathExtension("started"))
        let refreshed = try results(issues)
        try expect(refreshed.items.map(\.number) == [71, 72] && refreshed.items.first?.title.hasSuffix("(updated)") == true,
                   "a stale page cannot append to a refreshed listing")
        let newDetail = try await service.issueDetails(for: 71, in: refreshed.repository)
        try expect(newDetail.body == "Updated fixture issue description.", "detail refresh reads the changed issue body")

        try mode("held-error")
        issues.refresh()
        let replaceWork = issues.request
        let oldFailure = Task { await issues.load(replaceWork) }
        try await waitForMock(gate)
        try mode("initial")
        issues.searchText = "label:bug"
        issues.applySearch(filter: .closed)
        await issues.load(issues.request)
        try releaseMock(gate)
        await oldFailure.value
        try expect(results(issues).items.map(\.number) == [70] && issues.selection == nil,
                   "a stale error cannot replace the newer closed label results")
        return cursor
    }

    @MainActor
    private static func results(_ model: GitHubBrowserModel) throws -> GitHubListPage {
        guard case .loaded(let page, .idle) = model.listing else {
            if case .failed(let message) = model.listing { throw Failure(message: message) }
            throw Failure(message: "Expected a completed list")
        }
        return page
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message: message) }
        return value
    }

    private static func waitForMock(_ gate: URL) async throws {
        let started = gate.appendingPathExtension("started")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: started.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(message: "The paused mock did not start.")
    }

    private static func releaseMock(_ gate: URL) throws {
        let released = gate.appendingPathExtension("release")
        try Data().write(to: released)
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

    private static func verifyPublicRepository() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("pi-public-forge-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        _ = try git(directory, "init", "--quiet", "--initial-branch=main")
        _ = try git(directory, "remote", "add", "origin", "https://github.com/cli/cli.git")
        let reader = GitHubReader(directory: directory.path)
        for kind in [GitHubBrowseKind.pullRequests, .issues] {
            let first = try await reader.list(.init(kind, .all))
            guard first.repository.slug.lowercased() == "cli/cli", let sample = first.items.first else {
                throw Failure(message: "No sample from the expected public repository")
            }
            let label = first.items.flatMap(\.labelNames).first { !$0.contains("\"") && !$0.contains("\\") } ?? "bug"
            let query = GitHubListQuery(kind, .all, text: "label:\"\(label)\"")
            let filtered = try await reader.list(query)
            try expect(!filtered.items.isEmpty && filtered.items.contains { $0.labelNames.contains(label) }, "live label search")
            var added = 0
            if let next = filtered.next {
                let more = try await reader.list(query, after: next)
                let existing = Set(filtered.items.map(\.number))
                added = more.items.filter { !existing.contains($0.number) }.count
                try expect(added > 0, "another page adds new items")
            }
            let number = switch kind {
            case .pullRequests: try await reader.pullRequestDetails(for: sample.number, in: first.repository).pullRequest.number
            case .issues: try await reader.issueDetails(for: sample.number, in: first.repository).number
            }
            try expect(number == sample.number, "detail belongs to the selected item")
            print("\(kind.rawValue) repo=\(first.repository.slug) first=\(first.items.count) labelMatches=\(filtered.items.count) nextNew=\(added) selectedDetailMatches=true")
        }
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
