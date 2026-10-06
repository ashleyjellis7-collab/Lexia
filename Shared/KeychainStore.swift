import Foundation
import Security

/// Small values shared by the Lexia app and keyboard through a Keychain
/// access group: the TypeSafe API key, settings and the personal dictionary.
///
/// The Keychain (rather than an App Group) is used because it also works with
/// a free Apple developer account, which can't use App Groups.
enum KeychainStore {
    private static let service = "app.lexia"

    /// From Info.plist (`LexiaKeychainGroup`), set in project.yml.
    private static var accessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "LexiaKeychainGroup") as? String
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup, !accessGroup.isEmpty { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    static func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func set(_ data: Data?, for account: String) -> Bool {
        guard let data else {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        // Readable by the keyboard after the phone's first unlock.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - API key

    private static let apiKeyAccount = "typesafe-api-key"

    static func readAPIKey() -> String? {
        data(for: apiKeyAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return set(trimmed.isEmpty ? nil : Data(trimmed.utf8), for: apiKeyAccount)
    }
}
