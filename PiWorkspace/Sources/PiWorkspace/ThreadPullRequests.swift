import Foundation

struct ThreadPullRequestLink: Codable, Identifiable {
    let reference: GitHubPullRequestReference
    let title: String

    var id: GitHubPullRequestReference { reference }
}

struct ThreadPullRequestScope: Hashable {
    let projectID: UUID
    let threadID: UUID
    let directory: String
    let canReadRepository: Bool

    init(project: Project, thread: Conversation) {
        projectID = project.id
        threadID = thread.id
        directory = thread.workingLocation.directory(in: project)
        canReadRepository = !thread.workingLocation.needsWorktree
    }
}
