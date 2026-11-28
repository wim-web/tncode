import Foundation

struct ComposerModelOption: Identifiable {
    let settings: ModelSettings
    let name: String
    let unavailableReason: String?
    /// The instance's display name from Settings → Providers.
    var providerName: String?

    var id: ModelSettings.Identity { settings.identity }
    var accessibilityID: String { "composer-model-\(settings.provider.rawValue)-\(settings.model)" }
    var detail: String {
        let label = providerName ?? settings.provider.label
        return settings.provider == .local ? "\(label) · \(settings.endpoint)" : label
    }

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            [name, settings.model, detail].contains { $0.localizedStandardContains(String(term)) }
        }
    }
}

/// One account in the model picker's provider rail.
struct ComposerModelProvider: Identifiable {
    let account: String
    let provider: Provider
    let endpoint: String
    var options: [ComposerModelOption]
    /// Another account owns this thread's history.
    let locked: Bool
    /// The account cannot run yet; the picker offers its setup instead of its models.
    var setupReason: String?

    var id: String { account }
    /// The instance's display name from Settings → Providers, else the provider's own name.
    var title: String {
        let label = options.first?.providerName ?? provider.label
        return provider == .local ? "\(label) · \(endpoint)" : label
    }
}
