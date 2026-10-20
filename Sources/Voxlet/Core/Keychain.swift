import Foundation
import Security

/// The API key lives in the login keychain, never in UserDefaults.
/// Without a Team ID the item's keychain partition is the app's cdhash, so the first read after each rebuild
/// prompts once; the key is cached for the rest of the process so that stays a single prompt.
enum Keychain {
    private static let service = "dev.seiry.voxlet"
    private static let account = "gemini-api-key"
    private static var cached: String??

    static var apiKey: String? {
        if let override = ProcessInfo.processInfo.environment["VOXLET_API_KEY"], !override.isEmpty {
            return override
        }
        if let cached { return cached }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let value = (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        // Cache a definite answer only; a denied or cancelled prompt should be able to ask again later.
        if status == errSecSuccess || status == errSecItemNotFound {
            cached = .some(value)
        }
        return value
    }

    @discardableResult
    static func setAPIKey(_ value: String) -> Bool {
        let trimmed = value.trimmed
        guard trimmed != (apiKey ?? "") else { return true }
        guard !trimmed.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            cached = .some(nil)
            return true
        }
        let data = Data(trimmed.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        if status == errSecSuccess { cached = .some(trimmed) }
        return status == errSecSuccess
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
