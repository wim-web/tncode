import Foundation

enum CodexAccountStatus: String, Decodable {
    case ready, loginRequired, notInstalled, unavailable

    var label: String {
        switch self {
        case .ready: String(localized: "Codex is connected")
        case .loginRequired: String(localized: "Sign in to Codex")
        case .notInstalled: String(localized: "Codex executable not found")
        case .unavailable: String(localized: "Could not connect to Codex")
        }
    }
}

struct CodexCapabilities: Decodable, Equatable {
    enum WebSearch: String, Decodable {
        case live, cached, disabled, unknown
        var label: String {
            switch self {
            case .live: String(localized: "Live")
            case .cached: String(localized: "Cached")
            case .disabled: String(localized: "Disabled")
            case .unknown: String(localized: "Not reported")
            }
        }
    }
    let webSearch: WebSearch
    let computerUse: Bool?
    var computerUseLabel: String {
        switch computerUse {
        case true: String(localized: "Tool available")
        case false: String(localized: "Tool not available in this Codex session")
        default: String(localized: "Not reported")
        }
    }
}
