import Foundation

struct PromptLink: Equatable {
    struct ModelHint: Equatable {
        let provider: String
        let model: String?
    }

    enum Destination: Equatable {
        case new(repository: GitHubRepository?, modelHint: ModelHint?)
        case pullRequest(GitHubPullRequestReference)
    }

    let prompt: String
    let removedHiddenCharacters: Bool
    let destination: Destination

    var repository: GitHubRepository? {
        switch destination {
        case let .new(repository, _): repository
        case let .pullRequest(reference): reference.repository
        }
    }

    var modelHint: ModelHint? {
        guard case let .new(_, hint) = destination else { return nil }
        return hint
    }

    var pullRequest: GitHubPullRequestReference? {
        guard case let .pullRequest(reference) = destination else { return nil }
        return reference
    }

    static func handles(_ url: URL) -> Bool {
        url.scheme?.lowercased() == ThreadLink.scheme && url.host?.lowercased() == "new"
    }

    init(url: URL) throws {
        let malformed = WorkspaceError("This prompt link is invalid.")
        guard Self.handles(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, components.percentEncodedPath == "/v1" else { throw malformed }

        var fields: [String: String] = [:]
        for part in (components.percentEncodedQuery ?? "").split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let key = Self.decode(pair[0]), let value = Self.decode(pair[1]),
                  fields.updateValue(value, forKey: key) == nil else { throw malformed }
        }
        let raw = fields["prompt"] ?? ""
        guard raw.utf16.count <= 8_000 else { throw WorkspaceError("This prompt exceeds the 8,000 character limit.") }
        let (prompt, removedHiddenCharacters) = Self.sanitize(raw)
        if prompt.isEmpty && removedHiddenCharacters {
            throw WorkspaceError("This prompt contains only hidden characters.")
        }
        self.prompt = prompt
        self.removedHiddenCharacters = removedHiddenCharacters

        if let pr = fields["pr"] {
            guard let reference = Self.parsePullRequest(pr) else {
                throw WorkspaceError("This link names a pull request Pi Workspace couldn’t read.")
            }
            destination = .pullRequest(reference)
            return
        }
        guard !prompt.isEmpty else { throw WorkspaceError("This link has no prompt.") }
        let repository: GitHubRepository?
        if let repo = fields["repo"] {
            guard let parsed = Self.parseRepository(repo) else {
                throw WorkspaceError("This link names a repository Pi Workspace couldn’t read.")
            }
            repository = parsed
        } else {
            repository = nil
        }
        let modelHint = Self.nonempty(fields["provider"]).map {
            ModelHint(provider: $0.lowercased(), model: Self.nonempty(fields["model"]))
        }
        destination = .new(repository: repository, modelHint: modelHint)
    }

    private static func parsePullRequest(_ raw: String) -> GitHubPullRequestReference? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = value.wholeMatch(of: #/(?i:https?:\/\/(?:www\.)?github\.com\/([^\/?#]+)\/([^\/?#]+)\/pull\/([0-9]+)(?:[\/?#].*)?)/#)
            ?? value.wholeMatch(of: #/([^\/\s#]+)\/([^\/\s#]+)[\/#]([0-9]+)/#),
              let repository = parseRepository("\(match.1)/\(match.2)"),
              let number = Int(match.3), number <= 9_007_199_254_740_991 else { return nil }
        return GitHubPullRequestReference(repository: repository, number: number)
    }

    private static func decode(_ value: Substring) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func parseRepository(_ raw: String) -> GitHubRepository? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let url = value.wholeMatch(of: #/(?i:https?:\/\/(?:www\.)?github\.com)\/([^\/?#]+\/[^\/?#]+)\/?/#) {
            path = String(url.1)
        } else {
            path = value
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = parts[0]
        let name = parts[1].lowercased().hasSuffix(".git") ? parts[1].dropLast(4) : parts[1]
        guard owner.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9-]{0,38}/#) != nil,
              name.wholeMatch(of: #/[A-Za-z0-9._-]{1,100}/#) != nil,
              !name.allSatisfy({ $0 == "." }) else { return nil }
        return GitHubRepository(owner: owner, name: name)
    }

    private static func sanitize(_ raw: String) -> (String, Bool) {
        // Match the T3 prompt-link rules, retaining joiners within emoji sequences.
        let lineEndings = raw.replacingOccurrences(of: #"\r\n?|[\u2028\u2029]"#, with: "\n", options: .regularExpression)
        let visible = lineEndings.replacingOccurrences(
            of: #"[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180B-\u180F\u200B\u200C\u200E\u200F\u202A-\u202E\u2060-\u206F\u3164\uFE00-\uFE0D\uFEFF\uFFA0\uFFF0-\uFFFB\U0001BCA0-\U0001BCA3\U0001D173-\U0001D17A\U000E0000-\U000E0FFF]"#,
            with: "", options: .regularExpression
        )
        let scalars = Array(visible.unicodeScalars)
        var removed = lineEndings.utf16.count != visible.utf16.count
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar.value == 0x200D,
               !(index > 0 && index + 1 < scalars.count &&
                 isEmojiPart(scalars[index - 1]) && isEmojiPart(scalars[index + 1])) {
                removed = true
            } else {
                result.append(scalar)
            }
        }
        return (String(result).trimmingCharacters(in: .whitespacesAndNewlines), removed)
    }

    private static func isEmojiPart(_ scalar: Unicode.Scalar) -> Bool {
        (0x1F000...0x1FAFF).contains(scalar.value) || (0x2190...0x2BFF).contains(scalar.value) || scalar.value == 0xFE0F
    }
}

struct PromptLinkReview: Identifiable {
    let id = UUID()
    let link: PromptLink
    let alreadyOpened: Bool
}

struct PromptLinkProject: Identifiable {
    let id: UUID
    let title: String
    let path: String
    let reviewID: UUID
    private let directory: FileHandle

    init?(_ project: Project, review: PromptLinkReview) {
        guard project.folderIsAvailable else { return nil }
        let fd = open(project.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        id = project.id
        title = project.title
        path = project.path
        reviewID = review.id
        directory = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func matches(_ project: Project) -> Bool {
        project.id == id && project.path == path && !project.isScratch && project.detached != true &&
            GitWorkspace.matches(directory, at: path)
    }
}
