import Foundation
import Security

/// Minimal macOS Keychain wrapper for generic-password items, scoped to this app.
/// Used for the Atlassian credentials (site / email / API token) —
/// never written to config.json or any plaintext file.
enum Keychain {
    static let service = "com.arousseau.timetracker"

    static func set(_ data: Data, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
    }

    // Codable convenience.
    static func setCodable<T: Encodable>(_ value: T, account: String) {
        if let data = try? JSONEncoder().encode(value) { set(data, account: account) }
    }

    static func getCodable<T: Decodable>(_ type: T.Type, account: String) -> T? {
        guard let data = get(account: account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
