import Darwin
import Foundation

struct GitHubRepository: Hashable, Sendable {
    let slug: String

    var cliName: String { "github.com/" + slug }

    init?(owner: Substring, name: Substring) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard [owner, name].allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        slug = "\(owner)/\(name)".lowercased()
    }

    static func webPath(in url: String) -> String? {
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com", components.port == nil,
              components.user == nil, components.password == nil else { return nil }
        return components.percentEncodedPath
    }

    fileprivate init?(remote: String) {
        let path: String
        if remote.lowercased().hasPrefix("git@github.com:") {
            path = String(remote.dropFirst("git@github.com:".count))
        } else {
            guard let url = URLComponents(string: remote),
                  let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased(),
                  (host == "github.com" && ["https", "http", "ssh", "git"].contains(scheme))
                    || (scheme == "ssh" && host == "ssh.github.com") else { return nil }
            path = url.path
        }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let name = parts[1].lowercased().hasSuffix(".git") ? parts[1].dropLast(4) : parts[1]
        self.init(owner: parts[0], name: name)
    }
}

struct GitHubPullRequestReference: Codable, Hashable, Sendable {
    let repository: GitHubRepository
    let number: Int
    let url: URL

    init?(repository: GitHubRepository, number: Int) {
        guard number > 0, let url = URL(string: "https://\(repository.cliName)/pull/\(number)") else { return nil }
        self.repository = repository
        self.number = number
        self.url = url
    }

    init?(url: String) {
        guard let path = GitHubRepository.webPath(in: url)?.wholeMatch(of: #/\/([^\/]+)\/([^\/]+)\/pull\/([0-9]+)(?:\/(?:files|commits|checks))?\/?/#),
              let repository = GitHubRepository(owner: path.1, name: path.2),
              let number = Int(path.3) else { return nil }
        self.init(repository: repository, number: number)
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let reference = Self(url: try value.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid GitHub pull request URL")
        }
        self = reference
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(url.absoluteString)
    }
}

struct GitHubAuthor: Decodable, Sendable {
    let login: String
}

struct GitHubPullRequest: Decodable, Sendable {
    let number: Int
    let title: String
    let state: String
    let isDraft: Bool
    let author: GitHubAuthor?

    var stateLabel: String { state == "OPEN" && isDraft ? "Draft" : state.capitalized }

    fileprivate static let fields = "number,title,state,isDraft,author"
}

struct GitHubPullRequestDetails: Sendable {
    let pullRequest: GitHubPullRequest
    let reference: GitHubPullRequestReference
    let headRef: String
    let headOID: String
    let baseRef: String
    let body: String
    let checks: [GitHubCheck]

    var url: URL { reference.url }
}

struct GitHubCheck: Decodable, Sendable {
    let name: String
    let workflowName: String?
    let status: String
    let url: URL?
    let actionsJob: GitHubActionsJob?

    var hasFailureLog: Bool {
        ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"].contains(status)
    }

    private enum CodingKeys: String, CodingKey {
        case name, workflowName, status, conclusion, detailsUrl
        case context, state, targetUrl
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        workflowName = try fields.decodeIfPresent(String.self, forKey: .workflowName)
        let link: String?
        let context = try fields.decodeIfPresent(String.self, forKey: .context)
        if let context {
            name = context
            status = try fields.decode(String.self, forKey: .state)
            link = try fields.decodeIfPresent(String.self, forKey: .targetUrl)
        } else {
            name = try fields.decode(String.self, forKey: .name)
            let phase = try fields.decode(String.self, forKey: .status)
            if phase == "COMPLETED", let conclusion = try fields.decodeIfPresent(String.self, forKey: .conclusion),
               !conclusion.isEmpty {
                status = conclusion
            } else {
                status = phase
            }
            link = try fields.decodeIfPresent(String.self, forKey: .detailsUrl)
        }
        if let link, let components = URLComponents(string: link),
           ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
           let host = components.host, !host.isEmpty,
           components.user == nil, components.password == nil {
            url = components.url
        } else {
            url = nil
        }
        actionsJob = context == nil ? url.flatMap(GitHubActionsJob.init(url:)) : nil
    }
}

struct GitHubActionsJob: Equatable, Sendable {
    let repository: GitHubRepository
    let runID: Int
    let jobID: Int

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host?.lowercased() == "github.com",
              components.port == nil, components.user == nil, components.password == nil,
              let path = components.percentEncodedPath.wholeMatch(of: #/\/([^\/]+)\/([^\/]+)\/actions\/runs\/([0-9]+)\/job\/([0-9]+)\/?/#),
              let repository = GitHubRepository(owner: path.1, name: path.2),
              let runID = Int(path.3), runID > 0, let jobID = Int(path.4), jobID > 0 else { return nil }
        self.repository = repository
        self.runID = runID
        self.jobID = jobID
    }
}

struct GitHubCheckLog: Sendable {
    static let lineLimit = 200
    static let byteLimit = 96 * 1024

    let text: String
    let truncated: Bool

    fileprivate init(output: WorkspaceCommand.Output) {
        var log = String(decoding: output.bytes, as: UTF8.self)
        log = log.replacingOccurrences(
            of: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\))|[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]"#,
            with: "",
            options: .regularExpression
        )
        var lines = log.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        if output.truncated, lines.count > 1 { lines.removeFirst() }
        text = lines.suffix(Self.lineLimit).joined(separator: "\n")
        truncated = output.truncated || lines.count > Self.lineLimit
    }
}

enum GitHubCheckLogError: LocalizedError {
    case unsupported, pending, unavailable, checkoutChanged, checkChanged

    var errorDescription: String? {
        switch self {
        case .unsupported: "There is no GitHub Actions job log for this check in the pull request’s repository."
        case .pending: "This Actions job is still running or waiting to start."
        case .unavailable: "GitHub couldn’t provide this job’s log. It may have expired, the job may never have started, or your account may lack access."
        case .checkoutChanged: "The checkout changed while reading the log. Refresh the pull request and try again."
        case .checkChanged: "This check no longer matches the pull request’s current head. Refresh the pull request and try again."
        }
    }
}

struct GitHubReader: Sendable {
    let directory: String
    private let environment: [String: String]
    private let timeout: DispatchTimeInterval

    init(directory: String, environment: [String: String]? = nil, timeout: DispatchTimeInterval = .seconds(20)) {
        self.directory = directory
        self.timeout = timeout
        if let environment {
            self.environment = environment
        } else {
            var inherited = ProcessInfo.processInfo.environment
            let standardPaths = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin"
            inherited["PATH"] = [inherited["PATH"], standardPaths].compactMap { $0 }.joined(separator: ":")
            self.environment = inherited
        }
    }

    func pullRequestDetails(for number: Int, in expectedRepository: GitHubRepository) async throws -> GitHubPullRequestDetails {
        guard let reference = GitHubPullRequestReference(repository: expectedRepository, number: number) else {
            throw ReadError.invalidResponse(.pullRequests)
        }
        let repository = try await repository(matching: expectedRepository)
        let response: DetailResponse = try await read(
            ["pr", "view", String(number), "--json",
             GitHubPullRequest.fields + ",headRefName,headRefOid,baseRefName,body,statusCheckRollup,url", "--repo", repository.cliName],
            for: .pullRequests
        )
        guard response.pullRequest.number == number,
              GitHubPullRequestReference(url: response.url) == reference else {
            throw ReadError.invalidResponse(.pullRequests)
        }
        _ = try await self.repository(matching: repository)
        return GitHubPullRequestDetails(
            pullRequest: response.pullRequest,
            reference: reference,
            headRef: response.headRefName,
            headOID: response.headRefOid,
            baseRef: response.baseRefName,
            body: response.body ?? "",
            checks: response.statusCheckRollup ?? []
        )
    }

    func pullRequestFiles(
        in details: GitHubPullRequestDetails, after previous: GitHubPullRequestFilePage? = nil
    ) async throws -> GitHubPullRequestFilePage {
        guard previous == nil || previous?.nextPage != nil else {
            throw ReadError.invalidResponse(.pullRequests)
        }
        let reference = details.reference
        let checkout = try await fileCheckout(for: reference)
        let revision = try await fileRevision(for: reference)
        guard revision.head.sha == details.headOID, previous == nil || previous?.revision == revision else {
            throw GitHubPullRequestFilesError.revisionChanged
        }
        guard previous == nil || previous?.checkout == checkout else {
            throw GitHubPullRequestFilesError.checkoutChanged
        }

        let page = previous?.nextPage ?? 1
        let firstIndex = (page - 1) * GitHubPullRequestFilePage.pageSize
        let remaining = min(revision.changedFiles, GitHubPullRequestFilePage.fileLimit) - firstIndex
        let files: [GitHubPullRequestFile]
        if remaining == 0 {
            files = []
        } else {
            files = try await read(
                ["api", "repos/\(reference.repository.slug)/pulls/\(reference.number)/files?per_page=\(GitHubPullRequestFilePage.pageSize)&page=\(page)",
                 "--hostname", "github.com", "--method", "GET", "--jq", GitHubPullRequestFile.projection],
                for: .pullRequests
            )
            guard files.count <= min(remaining, GitHubPullRequestFilePage.pageSize),
                  files.allSatisfy({ !$0.path.isEmpty && $0.additions >= 0 && $0.deletions >= 0 }) else {
                throw ReadError.invalidResponse(.pullRequests)
            }
        }
        let result = GitHubPullRequestFilePage(
            files: files, revision: revision, checkout: checkout,
            nextPage: files.count == GitHubPullRequestFilePage.pageSize && remaining > files.count ? page + 1 : nil
        )
        try await verifyFileSnapshot(result, for: reference)
        return result
    }

    func validatePullRequestFiles(
        _ page: GitHubPullRequestFilePage, for reference: GitHubPullRequestReference
    ) async throws {
        guard try await fileCheckout(for: reference) == page.checkout else {
            throw GitHubPullRequestFilesError.checkoutChanged
        }
        try await verifyFileSnapshot(page, for: reference)
    }

    private func verifyFileSnapshot(
        _ page: GitHubPullRequestFilePage, for reference: GitHubPullRequestReference
    ) async throws {
        guard try await fileRevision(for: reference) == page.revision else {
            throw GitHubPullRequestFilesError.revisionChanged
        }
        guard try await fileCheckout(for: reference) == page.checkout else {
            throw GitHubPullRequestFilesError.checkoutChanged
        }
        try Task.checkCancellation()
    }

    private func fileRevision(for reference: GitHubPullRequestReference) async throws -> GitHubPullRequestFileRevision {
        let revision: GitHubPullRequestFileRevision = try await read(
            ["api", "repos/\(reference.repository.slug)/pulls/\(reference.number)", "--hostname", "github.com",
             "--method", "GET", "--jq", "{number, html_url, head: {sha: .head.sha}, base: {sha: .base.sha}, changed_files}"],
            for: .pullRequests
        )
        guard revision.number == reference.number, GitHubPullRequestReference(url: revision.htmlURL) == reference,
              !revision.head.sha.isEmpty, !revision.base.sha.isEmpty, revision.changedFiles >= 0 else {
            throw ReadError.invalidResponse(.pullRequests)
        }
        return revision
    }

    private func fileCheckout(for reference: GitHubPullRequestReference) async throws -> GitHubPullRequestFileCheckout {
        _ = try await repository(matching: reference.repository)
        let git = GitWorkspace(path: directory)
        let (branch, head) = try await (git.currentBranch(), git.headObjectID())
        return GitHubPullRequestFileCheckout(directory: directory, branch: branch, head: head)
    }

    func checkLog(for check: GitHubCheck, in details: GitHubPullRequestDetails) async throws -> GitHubCheckLog {
        guard check.hasFailureLog, let target = check.actionsJob, target.repository == details.reference.repository else {
            throw GitHubCheckLogError.unsupported
        }
        let repository = try await repository(matching: target.repository)
        let git = GitWorkspace(path: directory)
        let checkout = try await (git.currentBranch(), git.headObjectID())
        let endpoint = "repos/\(repository.slug)/actions/jobs/\(target.jobID)"
        let options = ["--hostname", "github.com", "--method", "GET"]
        let log: GitHubCheckLog
        do {
            let job: ActionsJobResponse = try await read(["api", endpoint] + options, for: .pullRequests)
            guard job.id == target.jobID, job.runID == target.runID, job.headSHA == details.headOID,
                  GitHubActionsJob(url: job.url) == target else {
                throw GitHubCheckLogError.checkChanged
            }
            guard job.status == "completed" else { throw GitHubCheckLogError.pending }

            // gh writes only to the capture pipe. GitHubCheckLog strips control sequences before display.
            let output = try await capture(
                ["api", endpoint + "/logs"] + options + ["--allow-escape-sequences"],
                for: .pullRequests, tailLimit: GitHubCheckLog.byteLimit
            )
            log = GitHubCheckLog(output: output)
        } catch ReadError.notFound, ReadError.gone, ReadError.readFailed {
            throw GitHubCheckLogError.unavailable
        }
        guard !log.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubCheckLogError.unavailable
        }
        let current: CheckSnapshot = try await read(
            ["pr", "view", String(details.reference.number), "--json", "headRefOid,statusCheckRollup,url",
             "--repo", repository.cliName], for: .pullRequests
        )
        guard GitHubPullRequestReference(url: current.url) == details.reference,
              current.headRefOid == details.headOID,
              current.statusCheckRollup?.contains(where: { $0.hasFailureLog && $0.actionsJob == target }) == true else {
            throw GitHubCheckLogError.checkChanged
        }
        _ = try await self.repository(matching: repository)
        guard try await (git.currentBranch(), git.headObjectID()) == checkout else {
            throw GitHubCheckLogError.checkoutChanged
        }
        try Task.checkCancellation()
        return log
    }

    func repository(matching expected: GitHubRepository? = nil) async throws -> GitHubRepository {
        let repository = try await checkoutRepository()
        try Task.checkCancellation()
        guard expected == nil || repository == expected else { throw ReadError.repositoryChanged }
        return repository
    }

    private func checkoutRepository() async throws -> GitHubRepository {
        try Task.checkCancellation()
        let remotes: [(name: String, url: String)]
        do {
            remotes = try await GitWorkspace(path: directory).fetchRemotes()
        } catch {
            throw ReadError.checkoutUnavailable
        }
        var repositories: [GitHubRepository] = []
        for remote in remotes {
            guard let repository = GitHubRepository(remote: remote.url) else { continue }
            if remote.name == "origin" { return repository }
            if !repositories.contains(repository) {
                repositories.append(repository)
            }
        }
        guard let repository = repositories.first else { throw ReadError.noGitHubRemote }
        guard repositories.count == 1 else { throw ReadError.ambiguousRemote }
        return repository
    }

    func read<Value: Decodable>(_ arguments: [String], for kind: GitHubBrowseKind) async throws -> Value {
        let output = try await capture(arguments, for: kind)
        guard !output.truncated else { throw ReadError.responseTooLarge }
        do {
            return try JSONDecoder().decode(Value.self, from: output.bytes)
        } catch {
            throw ReadError.invalidResponse(kind)
        }
    }

    private func capture(
        _ arguments: [String], for kind: GitHubBrowseKind, tailLimit: Int? = nil
    ) async throws -> WorkspaceCommand.Output {
        try Task.checkCancellation()
        let cli = (environment["PATH"] ?? "").split(separator: ":")
            .lazy.filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("gh") }
            .first {
                var isDirectory: ObjCBool = false
                let manager = FileManager.default
                return manager.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue && manager.isExecutableFile(atPath: $0.path)
            }
        guard let cli else { throw ReadError.cliUnavailable }

        var childEnvironment = environment
        for key in ["GH_DEBUG", "GH_FORCE_TTY", "GH_REPO", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_PREFIX"] {
            childEnvironment.removeValue(forKey: key)
        }
        childEnvironment["GH_HOST"] = "github.com"
        childEnvironment["GH_PROMPT_DISABLED"] = "1"
        childEnvironment["GH_NO_UPDATE_NOTIFIER"] = "1"
        childEnvironment["GH_NO_EXTENSION_UPDATE_NOTIFIER"] = "1"
        childEnvironment["GH_PAGER"] = "cat"
        childEnvironment["GIT_TERMINAL_PROMPT"] = "0"

        let process = Process()
        process.executableURL = cli
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.arguments = arguments
        process.environment = childEnvironment

        let result: WorkspaceCommand.Capture
        do {
            result = try await WorkspaceCommand.capture(
                process, outputLimit: tailLimit ?? 2 * 1024 * 1024, timeout: timeout,
                cancelOnTaskCancellation: true, keepOutputTail: tailLimit != nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReadError.launchFailed
        }
        try Task.checkCancellation()
        guard result.exitedNormally else {
            throw result.status == SIGTERM ? ReadError.timedOut : ReadError.readFailed(kind)
        }
        guard result.status == 0 else {
            let stderr = result.errorMessage.lowercased()
            if tailLimit != nil, arguments.last == "--allow-escape-sequences",
               stderr.contains("unknown flag: --allow-escape-sequences") {
                return try await capture(Array(arguments.dropLast()), for: kind, tailLimit: tailLimit)
            }
            if result.status == 4 || stderr.contains("http 401") || stderr.contains("gh auth login") {
                throw ReadError.authentication
            }
            if stderr.contains("http 403") || stderr.contains("resource not accessible") {
                throw ReadError.accessDenied
            }
            if stderr.contains("http 404") || stderr.contains("could not resolve to") {
                throw ReadError.notFound(kind)
            }
            if stderr.contains("http 410") {
                throw ReadError.gone
            }
            if ["error connecting", "dial tcp", "network is unreachable", "timeout", "no such host"]
                .contains(where: stderr.contains) {
                throw ReadError.network
            }
            throw ReadError.readFailed(kind)
        }
        return result.output
    }

    private struct ActionsJobResponse: Decodable {
        let id: Int
        let runID: Int
        let headSHA: String
        let url: URL
        let status: String

        private enum CodingKeys: String, CodingKey {
            case id, status
            case runID = "run_id"
            case headSHA = "head_sha"
            case url = "html_url"
        }
    }

    private struct CheckSnapshot: Decodable {
        let url: String
        let headRefOid: String
        let statusCheckRollup: [GitHubCheck]?
    }

    private struct DetailResponse: Decodable {
        let pullRequest: GitHubPullRequest
        let headRefName: String
        let headRefOid: String
        let baseRefName: String
        let body: String?
        let statusCheckRollup: [GitHubCheck]?
        let url: String

        private enum CodingKeys: CodingKey {
            case headRefName, headRefOid, baseRefName, body, statusCheckRollup, url
        }

        init(from decoder: Decoder) throws {
            pullRequest = try GitHubPullRequest(from: decoder)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            headRefName = try fields.decode(String.self, forKey: .headRefName)
            headRefOid = try fields.decode(String.self, forKey: .headRefOid)
            baseRefName = try fields.decode(String.self, forKey: .baseRefName)
            body = try fields.decodeIfPresent(String.self, forKey: .body)
            statusCheckRollup = try fields.decodeIfPresent([GitHubCheck].self, forKey: .statusCheckRollup)
            url = try fields.decode(String.self, forKey: .url)
        }
    }

    enum ReadError: LocalizedError {
        case checkoutUnavailable, noGitHubRemote, ambiguousRemote, repositoryChanged
        case cliUnavailable, launchFailed, authentication, accessDenied, network, timedOut
        case notFound(GitHubBrowseKind), readFailed(GitHubBrowseKind), invalidResponse(GitHubBrowseKind)
        case responseTooLarge, invalidSearch, gone

        var errorDescription: String? {
            switch self {
            case .checkoutUnavailable: "Couldn’t read Git remotes from this checkout."
            case .noGitHubRemote: "This checkout has no github.com fetch remote."
            case .ambiguousRemote: "This checkout has multiple GitHub remotes and no GitHub origin."
            case .repositoryChanged: "The checkout’s GitHub repository changed. Refresh the list."
            case .cliUnavailable: "GitHub CLI (gh) is unavailable. Install it and make it available on the app’s PATH."
            case .launchFailed: "Couldn’t start GitHub CLI (gh) in this checkout."
            case .authentication: "Sign in with `gh auth login` in Terminal, then refresh."
            case .accessDenied: "GitHub denied access. Check your GitHub CLI account’s repository permissions."
            case .notFound(let kind): "GitHub couldn’t find the \(kind.itemName) or repository. Check access and refresh."
            case .network: "Couldn’t reach GitHub. Check your connection and refresh."
            case .timedOut: "The GitHub request timed out. Check your connection and refresh."
            case .readFailed(let kind): "Couldn’t read \(kind.itemName)s from GitHub. Check your GitHub CLI setup and refresh."
            case .responseTooLarge: "The GitHub response was too large to display."
            case .invalidResponse(let kind): "GitHub CLI returned an unreadable \(kind.itemName) response."
            case .invalidSearch: "Enter search words or a label such as label:bug. Use paired quotes around phrases and labels with spaces."
            case .gone: "GitHub no longer has this resource."
            }
        }
    }
}
