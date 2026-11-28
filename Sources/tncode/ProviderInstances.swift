import Foundation

/// The agent runtime behind a provider instance (T3 Code's provider driver).
enum ProviderDriver: String {
    case codex, pi

    var label: String { self == .codex ? "Codex" : "Pi" }
}

/// How an instance proves who it is, which decides its Setup section.
enum ProviderAuthKind: Equatable {
    case codexAccount
    case piSignIn
    case apiKey
    case customEndpoint
}

extension Provider {
    /// Settings → Providers lists one instance per account kind tncode can run, in this order.
    static let instanceOrder: [Provider] = [.codexAgent, .piAnthropic, .piCodex, .piOpenAI, .piCopilot,
                                            .openai, .anthropic, .local]

    var driver: ProviderDriver { self == .codexAgent ? .codex : .pi }

    var authKind: ProviderAuthKind {
        switch self {
        case .codexAgent: .codexAccount
        case .openai, .anthropic: .apiKey
        case .local: .customEndpoint
        default: .piSignIn
        }
    }

    /// Name shown when the instance has no display name of its own.
    var instanceLabel: String { self == .codexAgent ? "Codex" : label }

    /// The account a sign-in instance uses, as T3 Code names an auth method.
    var signInMethodLabel: String {
        switch self {
        case .piAnthropic, .anthropic: "Claude"
        case .piCopilot: "GitHub Copilot"
        default: "ChatGPT"
        }
    }

    /// Placeholder for "Add custom model".
    var customModelPlaceholder: String {
        switch self {
        case .codexAgent: "gpt-6.2-codex"
        case .anthropic, .piAnthropic: "claude-opus-5-5"
        case .local: "llama3.3:70b"
        default: "model-slug"
        }
    }
}

/// Per-instance settings saved in the workspace, like T3 Code's provider instance config.
struct ProviderPreferences: Codable, Equatable {
    var enabled: Bool?
    var displayName: String?
    var accentColor: String?
    var hiddenModels: [String]?
    /// Order of shown and hidden models after the Move up/down buttons. Favorites live in
    /// `Workspace.favoriteModels`, shared with the composer's model picker, and keep the order they were starred.
    var modelOrder: [String]?
    var customModels: [String]?
    /// Codex runtime.
    var binaryPath: String?
    var homePath: String?
    var launchArgs: String?
    /// Custom endpoint runtime (Local OpenAI-compatible).
    var endpoint: String?
    var contextWindow: Int?
    var localTools: Bool?
    var localImages: Bool?

    var isEnabled: Bool { enabled ?? true }
    var hidden: Set<String> { Set(hiddenModels ?? []) }

    /// Values a reset returns to: everything except the switch.
    var withoutCustomizations: ProviderPreferences { ProviderPreferences(enabled: enabled) }
    var isCustomized: Bool { withoutCustomizations != ProviderPreferences() }

    /// Keeps the stored form small: empty strings and lists are not saved.
    var normalized: ProviderPreferences {
        func text(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        func list(_ value: [String]?) -> [String]? { value?.isEmpty == false ? value : nil }
        var next = self
        next.enabled = enabled == false ? false : nil
        next.displayName = text(displayName)
        next.accentColor = text(accentColor)
        next.hiddenModels = list(hiddenModels)
        next.modelOrder = list(modelOrder)
        next.customModels = list(customModels)
        next.binaryPath = text(binaryPath)
        next.homePath = text(homePath)
        next.launchArgs = text(launchArgs)
        next.endpoint = text(endpoint)
        return next
    }
}

/// Provider status in T3 Code's terms (`getProviderSummary`, `PROVIDER_STATUS_STYLES`).
struct ProviderInstanceStatus: Equatable {
    enum Key { case disabled, ready, warning, error, neutral }

    let key: Key
    let headline: String
    let detail: String?

    var needsAttention: Bool { key == .warning || key == .error }
}

/// The sign-in and process environment Codex uses, from the Codex instance's Runtime settings.
enum CodexRuntimeEnvironment {
    @MainActor static var preferences = ProviderPreferences()

    /// Applied over the app's own environment when a Codex helper starts.
    @MainActor static func apply(to environment: inout [String: String]) {
        if let path = preferences.binaryPath { environment["TNCODE_CODEX_BIN"] = (path as NSString).expandingTildeInPath }
        if let home = preferences.homePath { environment["CODEX_HOME"] = (home as NSString).expandingTildeInPath }
        if let arguments = preferences.launchArgs { environment["TNCODE_CODEX_ARGS"] = arguments }
    }
}
