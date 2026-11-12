import Foundation
import Security

/// Minimal Keychain wrapper for the two secrets Sentinel can hold: the radio
/// node token and the helper pairing key. Items are device-only and never synced.
enum Keychain {
    enum Item: String {
        case nodeToken = "radio-node-token"
        case helperPairingKey = "helper-pairing-key"
    }

    private static let service = "com.hcg.sentinel"

    private static func baseQuery(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: item.rawValue]
    }

    static func read(_ item: Item) -> Data? {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func readString(_ item: Item) -> String? {
        read(item).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func write(_ data: Data, for item: Item) -> Bool {
        delete(item)
        var query = baseQuery(item)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ item: Item) -> Bool {
        let status = SecItemDelete(baseQuery(item) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(_ item: Item) -> Bool {
        read(item) != nil
    }
}
