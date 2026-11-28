import Foundation
import Security

struct KeyVault {
    let service: String

    static func validatedKey(_ key: String) throws -> String {
        guard key.count >= 8, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw WorkspaceError("Enter the API key as a single line of at least eight characters.")
        }
        return key
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw WorkspaceError(String(localized: "Keychain access failed (\(status)).")) }
    }

    func read(_ account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw WorkspaceError("The saved API key is invalid.")
        }
        return key
    }

    func exists(_ account: String) throws -> Bool {
        let status = SecItemCopyMatching(query(account) as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    func save(_ key: String, account: String) throws {
        let request = query(account)
        let changes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(request as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = request
            item[kSecValueData as String] = changes[kSecValueData as String]
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}
