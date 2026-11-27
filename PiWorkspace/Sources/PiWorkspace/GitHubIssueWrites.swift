import Foundation

enum GitHubIssueChange: Equatable {
    case title(String)
    case description(String)
    case comment(String)

    var payload: [String: String] {
        switch self {
        case .title(let text): ["title": text]
        case .description(let text), .comment(let text): ["body": text]
        }
    }

    var isComment: Bool {
        if case .comment = self { return true }
        return false
    }

    func matches(title: String, body: String) -> Bool {
        switch self {
        case .title(let text): text.utf8.elementsEqual(title.utf8)
        case .description(let text): text.utf8.elementsEqual(body.utf8)
        case .comment: false
        }
    }

    func validate() throws {
        switch self {
        case .title(let text):
            guard !text.isEmpty, text.utf16.count <= 1024 else { throw GitHubIssueWriteError.invalidTitle }
        case .description(let text):
            guard text.utf16.count <= 65_536 else { throw GitHubIssueWriteError.invalidDescription }
        case .comment(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 65_536 else {
                throw GitHubIssueWriteError.invalidComment
            }
        }
    }
}

enum GitHubIssueWriteError: LocalizedError {
    case invalidTitle, invalidDescription, invalidComment, selectionChanged, editDenied, acknowledgementLost
    case editUnconfirmed, commentUnconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidTitle: "Enter an issue title of 1 to 1,024 characters."
        case .invalidDescription: "Enter an issue description of at most 65,536 characters."
        case .invalidComment: "Enter a comment of 1 to 65,536 characters."
        case .selectionChanged: "The selected issue, thread, or checkout changed. Reopen the issue and try again."
        case .editDenied: "Your GitHub CLI account can’t edit this issue."
        case .acknowledgementLost: "GitHub did not confirm the change. Check the result."
        case .editUnconfirmed: "GitHub does not show the saved edit. Review the issue and try saving again."
        case .commentUnconfirmed: "GitHub has not confirmed this comment. Check again before posting."
        }
    }
}

struct GitHubIssueActivity: Decodable {
    struct Comment: Decodable, Identifiable {
        let id: String
        let author: GitHubAuthor?
        let body: String
        let url: String
        let createdAt: Date
        let viewerDidAuthor: Bool

        private enum CodingKeys: String, CodingKey {
            case id, author, body, url, createdAt, viewerDidAuthor
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(String.self, forKey: .id)
            author = try fields.decodeIfPresent(GitHubAuthor.self, forKey: .author)
            body = try fields.decode(String.self, forKey: .body)
            url = try fields.decode(String.self, forKey: .url)
            viewerDidAuthor = try fields.decode(Bool.self, forKey: .viewerDidAuthor)
            createdAt = try Date(try fields.decode(String.self, forKey: .createdAt), strategy: .iso8601)
        }
    }

    struct Comments: Decodable {
        let totalCount: Int
        let nodes: [Comment]
    }

    let id: String
    let number: Int
    let url: String
    let title: String
    let body: String
    let viewerCanUpdate: Bool
    let comments: Comments
}

struct GitHubIssueSnapshot {
    let viewerID: String
    let activity: GitHubIssueActivity
}

struct GitHubIssueReceipt {
    let change: GitHubIssueChange
    let before: GitHubIssueSnapshot

    func isVisible(in current: GitHubIssueSnapshot) -> Bool {
        guard current.activity.id == before.activity.id else { return false }
        guard case .comment(let text) = change else {
            return change.matches(title: current.activity.title, body: current.activity.body)
        }

        guard current.viewerID == before.viewerID else { return false }
        let previous = before.activity.comments
        let comments = current.activity.comments
        let newComments: ArraySlice<GitHubIssueActivity.Comment>
        if let last = previous.nodes.last, let index = comments.nodes.lastIndex(where: { $0.id == last.id }) {
            let existing = Set(previous.nodes.map(\.id))
            newComments = comments.nodes.suffix(from: index + 1).filter { !existing.contains($0.id) }[...]
        } else if previous.totalCount == 0 {
            newComments = comments.nodes[...]
        } else {
            return false
        }
        // An earlier identical comment cannot acknowledge this request.
        return newComments.filter { $0.viewerDidAuthor && $0.body.utf8.elementsEqual(text.utf8) }.count == 1
    }
}

extension GitHubReader {
    func issueSnapshot(for reference: GitHubIssueReference) async throws -> GitHubIssueSnapshot {
        let parts = reference.repository.slug.split(separator: "/")
        guard reference.number <= Int32.max, parts.count == 2 else { throw ReadError.invalidResponse(.issues) }
        let query = """
        query NativeIssueDetail($owner:String!, $name:String!, $number:Int!) {
          viewer { id }
          repository(owner:$owner, name:$name) {
            issue(number:$number) {
              id number url title body viewerCanUpdate
              comments(last:25) {
                totalCount
                nodes { id author { login } body url createdAt viewerDidAuthor }
              }
            }
          }
        }
        """
        let response: IssueSnapshotResponse = try await read(
            ["api", "graphql", "--hostname", "github.com", "--raw-field", "query=\(query)",
             "--raw-field", "owner=\(parts[0])", "--raw-field", "name=\(parts[1])",
             "--field", "number=\(reference.number)"], for: .issues, outputLimit: 12 * 1024 * 1024
        )
        guard let activity = response.data.repository?.issue,
              !response.data.viewer.id.isEmpty, !activity.id.isEmpty,
              activity.number == reference.number, GitHubIssueReference(url: activity.url) == reference,
              activity.comments.nodes.count <= activity.comments.totalCount,
              Set(activity.comments.nodes.map(\.id)).count == activity.comments.nodes.count else {
            throw ReadError.invalidResponse(.issues)
        }
        return GitHubIssueSnapshot(viewerID: response.data.viewer.id, activity: activity)
    }

    func writeIssue(
        _ change: GitHubIssueChange, to reference: GitHubIssueReference, beforeLaunch: @escaping @MainActor () throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("change.json")
        try JSONEncoder().encode(change.payload).write(to: input)

        let endpoint = "repos/\(reference.repository.slug)/issues/\(reference.number)"
            + (change.isComment ? "/comments" : "")
        let arguments = [
            "api", endpoint, "--hostname", "github.com", "--method", change.isComment ? "POST" : "PATCH",
            "--header", "Content-Type: application/json", "--input", input.path
        ]
        do {
            let output = try await capture(arguments, for: .issues, beforeIssueWrite: beforeLaunch)
            guard !output.truncated else { throw GitHubIssueWriteError.acknowledgementLost }
            if case .comment(let text) = change {
                guard let response = try? JSONDecoder().decode(CommentWriteResponse.self, from: output.bytes),
                      response.id > 0, GitHubIssueReference(url: response.url) == reference,
                      URLComponents(string: response.url)?.fragment == "issuecomment-\(response.id)",
                      response.body.utf8.elementsEqual(text.utf8) else {
                    throw GitHubIssueWriteError.acknowledgementLost
                }
            } else {
                guard let response = try? JSONDecoder().decode(IssueWriteResponse.self, from: output.bytes),
                      GitHubIssueReference(url: response.url) == reference, response.number == reference.number,
                      change.matches(title: response.title, body: response.body ?? "") else {
                    throw GitHubIssueWriteError.acknowledgementLost
                }
            }
        } catch let error as ReadError {
            switch error {
            case .authentication, .accessDenied, .notFound, .gone, .issueValidation, .cliUnavailable:
                throw error
            default:
                throw GitHubIssueWriteError.acknowledgementLost
            }
        }
    }

    private struct IssueSnapshotResponse: Decodable {
        struct Data: Decodable {
            struct Viewer: Decodable { let id: String }
            struct Repository: Decodable { let issue: GitHubIssueActivity? }
            let viewer: Viewer
            let repository: Repository?
        }
        let data: Data
    }

    private struct IssueWriteResponse: Decodable {
        let number: Int
        let title: String
        let body: String?
        let url: String

        private enum CodingKeys: String, CodingKey {
            case number, title, body
            case url = "html_url"
        }
    }

    private struct CommentWriteResponse: Decodable {
        let id: Int
        let body: String
        let url: String

        private enum CodingKeys: String, CodingKey {
            case id, body
            case url = "html_url"
        }
    }
}
