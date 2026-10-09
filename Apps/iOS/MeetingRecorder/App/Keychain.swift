import Foundation
import Security

/// One secret per account name, kept in the keychain — the pairing code is a bearer token for the hub, so it
/// doesn't belong in UserDefaults.
enum Keychain {
    private static let service = "local.meetingrecorder.ios"

    static func read(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, to account: String) -> Bool {
        delete(account)
        var item = base(account)
        item[kSecValueData as String] = Data(value.utf8)
        // Uploads finish in the background, possibly while the device is locked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
