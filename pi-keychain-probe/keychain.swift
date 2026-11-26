import Foundation
import Security

let args = CommandLine.arguments
guard args.count == 3, let id = UUID(uuidString: args[2]) else { exit(64) }

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "dev.pi-keychain-probe.\(id.uuidString)",
    kSecAttrAccount as String: "model-api-key"
]

func check(_ status: OSStatus) {
    guard status == errSecSuccess else {
        if status == errSecItemNotFound { exit(44) }
        FileHandle.standardError.write(Data("Keychain OSStatus \(status)\n".utf8))
        exit(1)
    }
}

switch args[1] {
case "add":
    let key = FileHandle.standardInput.readDataToEndOfFile()
    guard !key.isEmpty else { exit(64) }
    var item = query
    item[kSecValueData as String] = key
    check(SecItemAdd(item as CFDictionary, nil))
case "read", "exists":
    var lookup = query
    if args[1] == "read" {
        lookup[kSecReturnData as String] = true
    }
    var result: CFTypeRef?
    check(SecItemCopyMatching(lookup as CFDictionary, &result))
    if args[1] == "read" {
        guard let data = result as? Data else { exit(1) }
        FileHandle.standardOutput.write(data)
    }
case "delete":
    check(SecItemDelete(query as CFDictionary))
default:
    exit(64)
}
