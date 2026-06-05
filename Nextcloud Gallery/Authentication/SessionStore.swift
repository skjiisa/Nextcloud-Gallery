//
//  SessionStore.swift
//  Nextcloud Gallery
//
//  Keychain-backed persistence for the signed-in account.
//

import Foundation
import Security

/// Stores ``AccountCredentials`` (which include the app password) in the Keychain
/// as a single JSON blob. The Keychain is the right home because the payload is
/// secret; storing it whole avoids splitting secret/non-secret fields.
nonisolated enum SessionStore {
    private static let service = "app.lyons.Nextcloud-Gallery.credentials"
    private static let account = "primary"

    /// Persists the credentials, replacing any existing entry.
    static func save(_ credentials: AccountCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    /// Loads the persisted credentials, if any.
    static func load() -> AccountCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(AccountCredentials.self, from: data)
        else { return nil }
        return credentials
    }

    /// Removes the persisted credentials (used on sign out).
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
