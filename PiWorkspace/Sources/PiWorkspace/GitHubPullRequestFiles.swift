import Foundation

struct GitHubPullRequestFile: Decodable, Sendable {
    enum Patch: Equatable {
        case text(String, partial: Bool)
        case unavailable
        case tooLarge
    }

    static let byteLimit = 32 * 1024
    static let projection = """
        map(((.patch // "") | tojson | utf8bytelength > \(byteLimit)) as $large |
        {filename, previous_filename, status, additions, deletions,
        patch: (if $large then null else .patch end), patch_too_large: $large})
        """

    let path: String
    let previousPath: String?
    let status: String
    let additions: Int
    let deletions: Int
    private let patchText: String?
    private let patchTooLarge: Bool

    var patch: Patch {
        if patchTooLarge { return .tooLarge }
        guard let patchText, !patchText.isEmpty else { return .unavailable }
        guard patchText.utf8.count <= Self.byteLimit else { return .tooLarge }
        var added = 0
        var removed = 0
        for line in patchText.utf8.split(separator: 10) {
            if line.first == 43 { added += 1 }
            if line.first == 45 { removed += 1 }
        }
        return .text(patchText, partial: added < additions || removed < deletions)
    }

    var statusLabel: String {
        status == "removed" ? "Deleted" : status.capitalized
    }

    private enum CodingKeys: String, CodingKey {
        case path = "filename"
        case previousPath = "previous_filename"
        case status, additions, deletions
        case patchText = "patch"
        case patchTooLarge = "patch_too_large"
    }
}

struct GitHubPullRequestFileRevision: Decodable, Equatable, Sendable {
    struct Commit: Decodable, Equatable, Sendable {
        let sha: String
    }

    let number: Int
    let htmlURL: String
    let head: Commit
    let base: Commit
    let changedFiles: Int

    private enum CodingKeys: String, CodingKey {
        case number, head, base
        case htmlURL = "html_url"
        case changedFiles = "changed_files"
    }
}

struct GitHubPullRequestFileCheckout: Equatable, Sendable {
    let directory: String
    let branch: String?
    let head: String?
}

struct GitHubPullRequestFilePage: Sendable {
    static let pageSize = 30
    static let fileLimit = 3000

    let files: [GitHubPullRequestFile]
    let revision: GitHubPullRequestFileRevision
    let checkout: GitHubPullRequestFileCheckout
    let nextPage: Int?

    var fileCount: Int { revision.changedFiles }
}

enum GitHubPullRequestFilesError: LocalizedError {
    case revisionChanged, checkoutChanged

    var errorDescription: String? {
        switch self {
        case .revisionChanged: "The pull request changed while reading its files."
        case .checkoutChanged: "The checkout changed while reading the pull request’s files."
        }
    }
}
