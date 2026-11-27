import Foundation

struct CommitWritingSettings: Codable, Equatable {
    enum Style: String, Codable, CaseIterable {
        case repository = "repo_conventions"
        case conventional = "conventional_commits"
        case custom

        var title: String {
            switch self {
            case .repository: "Repository conventions"
            case .conventional: "Conventional Commits"
            case .custom: "Custom instructions"
            }
        }
    }

    var style: Style = .repository
    var customInstructions = ""
    var writerModel: ModelSettings?
}
