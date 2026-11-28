import Foundation

struct CommitWritingSettings: Codable, Equatable {
    enum Style: String, Codable, CaseIterable {
        case repository = "repo_conventions"
        case conventional = "conventional_commits"
        case custom

        var title: String {
            switch self {
            case .repository: String(localized: "Repository conventions")
            case .conventional: String(localized: "Conventional Commits")
            case .custom: String(localized: "Custom instructions")
            }
        }
    }

    var style: Style = .repository
    var customInstructions = ""
    var writerModel: ModelSettings?
}
