import Foundation
import Security

/// Keys, client secrets and sign-in tokens, kept in the macOS Keychain (never in files or UserDefaults).
/// Settings can replace or remove each one; nothing reads them back out to show you.
enum Secrets {
    static let service = "ClaudeDesk"

    enum Key {
        static let jevAPIKey = "jev.apiKey"
        static let googleClientID = "google.clientID"
        static let googleClientSecret = "google.clientSecret"
        static func googleRefreshToken(_ account: String) -> String { "google.refresh." + account.lowercased() }
    }

    static func get(_ key: String) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a value is saved, without reading it: attribute lookups don't trigger macOS's "allow access" prompt,
    /// so Settings can call this on the main thread. Reading values (`get`) belongs off the main thread.
    static func has(_ key: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Saves (or replaces) a value. An empty value removes it.
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(key) }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let data = Data(trimmed.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        // Only on this Mac, and only after first unlock: not synced to iCloud Keychain.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "ClaudeDesk · \(key)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(_ key: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
