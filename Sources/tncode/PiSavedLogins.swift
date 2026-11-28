import CryptoKit
import Foundation

struct PiSavedLogins {
    let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    private struct Entry: Decodable {
        let type: String?
        let accountId: String?
    }

    private struct Defaults: Decodable {
        let defaultProvider: String?
        let defaultModel: String?
        let defaultThinkingLevel: String?
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let file = directory.appendingPathComponent(name)
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func profiles() -> [ModelSettings] {
        guard let entries = read([String: Entry].self, from: "auth.json") else { return [] }
        let defaults = read(Defaults.self, from: "settings.json")
        var profiles: [ModelSettings] = []
        for provider in Provider.allCases {
            guard let id = provider.piProviderID, let entry = entries[id], entry.type == "oauth" else { continue }
            let preferred = id == defaults?.defaultProvider
            let model = preferred ? defaults?.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let identity = Data((directory.path + "\0" + (entry.accountId ?? "")).utf8)
            let profile = ModelSettings(provider: provider, model: model.flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel,
                                        thinkingLevel: defaults?.defaultThinkingLevel.flatMap(ModelSettings.ThinkingLevel.init(rawValue:)),
                                        piLoginProfile: SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined())
            if preferred { profiles.insert(profile, at: 0) } else { profiles.append(profile) }
        }
        return profiles
    }
}
