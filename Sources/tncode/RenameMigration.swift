import Darwin
import Foundation
import Security

/// Carries data saved under the app's former name, Pi Workspace, over to tncode.
enum RenameMigration {
    static let legacyBundleID = "dev.piworkspace.app"
    static let legacySupportFolder = "Pi Workspace"
    static let legacyKeychainService = "dev.piworkspace.model-key"
    static let legacyLinkScheme = "pi-workspace"
    private static let legacyLanguageKey = "PiWorkspaceLanguage"
    private static let migratedDefaultsKey = "migratedLegacyDefaults"

    /// The data folder, after moving the former folder into place when only that one exists.
    /// While a former build still holds its lock, the former folder stays in use so the usual
    /// "open in another process" recovery applies, and the move happens on a later launch.
    static func supportDirectory(in base: URL = .applicationSupportDirectory) -> URL {
        let files = FileManager.default
        let current = base.appendingPathComponent("tncode", isDirectory: true)
        let legacy = base.appendingPathComponent(legacySupportFolder, isDirectory: true)
        guard !files.fileExists(atPath: current.path), files.fileExists(atPath: legacy.path) else { return current }
        let lock = open(legacy.appendingPathComponent(".lock").path, O_RDONLY | O_CLOEXEC)
        defer { if lock >= 0 { close(lock) } }
        if lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0 { return legacy }
        do {
            try files.moveItem(at: legacy, to: current)
        } catch {
            return legacy
        }
        return current
    }

    /// Copies the former preferences once, without replacing anything tncode already saved.
    static func migrateDefaults(_ defaults: UserDefaults = .standard,
                                domain: String? = Bundle.main.bundleIdentifier,
                                legacyDomain: String = legacyBundleID) {
        guard let domain, domain != legacyDomain else { return }
        var current = defaults.persistentDomain(forName: domain) ?? [:]
        guard current[migratedDefaultsKey] == nil else { return }
        for (key, value) in defaults.persistentDomain(forName: legacyDomain) ?? [:] {
            let name = key == legacyLanguageKey ? AppLanguage.key : key
            if current[name] == nil { current[name] = value }
        }
        current[migratedDefaultsKey] = true
        defaults.setPersistentDomain(current, forName: domain)
    }

    /// Moves API keys saved under the former Keychain service to `service`.
    static func migrateKeychain(to service: String, from legacyService: String = legacyKeychainService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        let legacy = KeyVault(service: legacyService)
        let current = KeyVault(service: service)
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
            guard (try? current.exists(account)) == false, let key = try? legacy.read(account),
                  (try? current.save(key, account: account)) != nil else { continue }
            try? legacy.remove(account)
        }
    }
}
