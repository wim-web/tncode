import Foundation

enum PullRequestPromptLinkTarget {
    case thread(Thread)
    case checkout(Checkout)
    case missingProject

    struct Thread: Equatable {
        let projectID: UUID
        let threadID: UUID
        let title: String
        let directory: String
        let composerText: String?

        func needsReplacement(for prompt: String) -> Bool {
            guard !prompt.isEmpty, let composerText else { return false }
            return !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composerText != prompt
        }
    }

    struct Checkout {
        let project: PromptLinkProject
        let root: String
        let details: GitHubPullRequestDetails
    }
}

struct PendingPullRequestCheckout: Codable {
    let reference: GitHubPullRequestReference
    let checkout: GitWorkspace.PendingCheckout
}

extension GitWorkspace {
    func fetchPullRequestCommit(_ head: String, from reference: GitHubPullRequestReference) async throws {
        guard head.wholeMatch(of: #/[0-9a-f]{40}/#) != nil else {
            throw WorkspaceError.invalidOutput(command: "pull request head")
        }
        let object = try await run(["cat-file", "-t", head], acceptedStatuses: [0, 128])
        if object.output.bytes == Data("commit\n".utf8) { return }
        let url = "https://\(reference.repository.cliName).git"
        _ = try await run(["fetch", "--quiet", "--no-tags", "--no-recurse-submodules",
                           "--no-write-fetch-head", "--refmap=", "--", url, head])
    }
}
