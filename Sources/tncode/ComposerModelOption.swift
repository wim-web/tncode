import Foundation

struct ComposerModelOption: Identifiable {
    let settings: ModelSettings
    let name: String
    let unavailableReason: String?

    var id: ModelSettings.Identity { settings.identity }
    var accessibilityID: String { "composer-model-\(settings.provider.rawValue)-\(settings.model)" }
    var detail: String {
        settings.provider == .local ? "\(settings.provider.label) · \(settings.endpoint)" : settings.provider.label
    }

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            [name, settings.model, detail].contains { $0.localizedStandardContains(String(term)) }
        }
    }
}
