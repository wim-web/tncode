import Darwin
import Foundation

struct GitHubRepository: Hashable, Sendable {
    let slug: String

    var cliName: String { "github.com/" + slug }

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
        let owner = parts[0]
        let name = parts[1].hasSuffix(".git") ? parts[1].dropLast(4) : parts[1]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard [owner, name].allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        slug = "\(owner)/\(name)"
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
    let url: URL
    let headRef: String
    let baseRef: String
    let body: String
    let checks: [GitHubCheck]
}

struct GitHubCheck: Decodable, Sendable {
    let name: String
    let workflowName: String?
    let status: String
    let url: URL?

    private enum CodingKeys: String, CodingKey {
        case name, workflowName, status, conclusion, detailsUrl
        case context, state, targetUrl
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        workflowName = try fields.decodeIfPresent(String.self, forKey: .workflowName)
        let link: String?
        if let context = try fields.decodeIfPresent(String.self, forKey: .context) {
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
    }
}

struct GitHubReader: Sendable {
    private let directory: String
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
        guard number > 0 else { throw ReadError.invalidResponse(.pullRequests) }
        let repository = try await repository(matching: expectedRepository)
        let response: DetailResponse = try await read(
            ["pr", "view", String(number), "--json",
             GitHubPullRequest.fields + ",headRefName,baseRefName,body,statusCheckRollup", "--repo", repository.cliName],
            for: .pullRequests
        )
        guard response.pullRequest.number == number,
              let url = URL(string: "https://\(repository.cliName)/pull/\(number)") else {
            throw ReadError.invalidResponse(.pullRequests)
        }
        return GitHubPullRequestDetails(
            pullRequest: response.pullRequest,
            url: url,
            headRef: response.headRefName,
            baseRef: response.baseRefName,
            body: response.body ?? "",
            checks: response.statusCheckRollup ?? []
        )
    }

    func repository(matching expected: GitHubRepository? = nil) async throws -> GitHubRepository {
        let repository = try await checkoutRepository()
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
            if !repositories.contains(where: { $0.slug.caseInsensitiveCompare(repository.slug) == .orderedSame }) {
                repositories.append(repository)
            }
        }
        guard let repository = repositories.first else { throw ReadError.noGitHubRemote }
        guard repositories.count == 1 else { throw ReadError.ambiguousRemote }
        return repository
    }

    func read<Value: Decodable>(_ arguments: [String], for kind: GitHubBrowseKind) async throws -> Value {
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
            result = try await WorkspaceCommand.capture(process, outputLimit: 2 * 1024 * 1024, timeout: timeout)
        } catch {
            throw ReadError.launchFailed
        }
        try Task.checkCancellation()
        guard result.exitedNormally else {
            throw result.status == SIGTERM ? ReadError.timedOut : ReadError.readFailed(kind)
        }
        guard result.status == 0 else {
            let stderr = result.errorMessage.lowercased()
            if result.status == 4 || stderr.contains("http 401") || stderr.contains("gh auth login") {
                throw ReadError.authentication
            }
            if stderr.contains("http 403") || stderr.contains("resource not accessible") {
                throw ReadError.accessDenied
            }
            if stderr.contains("http 404") || stderr.contains("could not resolve to") {
                throw ReadError.notFound(kind)
            }
            if ["error connecting", "dial tcp", "network is unreachable", "timeout", "no such host"]
                .contains(where: stderr.contains) {
                throw ReadError.network
            }
            throw ReadError.readFailed(kind)
        }
        guard !result.output.truncated else { throw ReadError.responseTooLarge }
        do {
            return try JSONDecoder().decode(Value.self, from: result.output.bytes)
        } catch {
            throw ReadError.invalidResponse(kind)
        }
    }

    private struct DetailResponse: Decodable {
        let pullRequest: GitHubPullRequest
        let headRefName: String
        let baseRefName: String
        let body: String?
        let statusCheckRollup: [GitHubCheck]?

        private enum CodingKeys: CodingKey {
            case headRefName, baseRefName, body, statusCheckRollup
        }

        init(from decoder: Decoder) throws {
            pullRequest = try GitHubPullRequest(from: decoder)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            headRefName = try fields.decode(String.self, forKey: .headRefName)
            baseRefName = try fields.decode(String.self, forKey: .baseRefName)
            body = try fields.decodeIfPresent(String.self, forKey: .body)
            statusCheckRollup = try fields.decodeIfPresent([GitHubCheck].self, forKey: .statusCheckRollup)
        }
    }

    enum ReadError: LocalizedError {
        case checkoutUnavailable, noGitHubRemote, ambiguousRemote, repositoryChanged
        case cliUnavailable, launchFailed, authentication, accessDenied, network, timedOut
        case notFound(GitHubBrowseKind), readFailed(GitHubBrowseKind), invalidResponse(GitHubBrowseKind)
        case responseTooLarge, invalidSearch

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
            }
        }
    }
}
