import Foundation
import Security

/// API keys live in the login keychain, never in UserDefaults.
/// Without a Team ID the item's keychain partition is the app's cdhash, so the first read after each rebuild
/// prompts once; each key is cached for the rest of the process so that stays a single prompt.
enum Keychain {
    private static let service = "dev.seiry.voxlet"
    private static let geminiAccount = "gemini-api-key"
    private static let gatewayAccount = "gateway-api-key"
    private static var cached: [String: String?] = [:]

    static var apiKey: String? {
        if let override = ProcessInfo.processInfo.environment["VOXLET_API_KEY"], !override.isEmpty {
            return override
        }
        return read(geminiAccount)
    }

    /// The new-api gateway key for meeting notes, kept apart from the Gemini key.
    static var gatewayKey: String? {
        if let override = ProcessInfo.processInfo.environment["VOXLET_GATEWAY_KEY"], !override.isEmpty {
            return override
        }
        return read(gatewayAccount)
    }

    @discardableResult
    static func setAPIKey(_ value: String) -> Bool { write(value, account: geminiAccount) }

    @discardableResult
    static func setGatewayKey(_ value: String) -> Bool { write(value, account: gatewayAccount) }

    private static func read(_ account: String) -> String? {
        if let hit = cached[account] { return hit }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let value = (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        // Cache a definite answer only; a denied or cancelled prompt should be able to ask again later.
        if status == errSecSuccess || status == errSecItemNotFound {
            cached[account] = .some(value)
        }
        return value
    }

    private static func write(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmed
        guard trimmed != (read(account) ?? "") else { return true }
        guard !trimmed.isEmpty else {
            SecItemDelete(baseQuery(account) as CFDictionary)
            cached[account] = .some(nil)
            return true
        }
        let data = Data(trimmed.utf8)
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(account)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        if status == errSecSuccess { cached[account] = .some(trimmed) }
        return status == errSecSuccess
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
