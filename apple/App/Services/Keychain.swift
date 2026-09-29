// API keys live in the macOS Keychain, filed under the environment variable the pipeline reads (ANTHROPIC_API_KEY, …).
// They're only ever handed to the pipeline as environment variables, never written to files or command lines.

import Foundation
import Security

enum Keychain {
    static let service = "app.neuralloop.books"

    static func read(_ name: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves (or, for an empty value, removes) a key. Updates in place, so a refused write never loses the old key.
    /// Returns nil on success, or what went wrong in plain words.
    @discardableResult
    static func save(_ name: String, _ value: String, availableWhileLocked: Bool = false) -> String? {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: name]
        var status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(base as CFDictionary)
            if status == errSecItemNotFound { status = errSecSuccess }
        } else {
            let fields: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: availableWhileLocked
                                             ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            status = SecItemUpdate(base as CFDictionary, fields as CFDictionary)
            if status == errSecItemNotFound { status = SecItemAdd(base.merging(fields) { $1 } as CFDictionary, nil) }
        }
        guard status != errSecSuccess else { return nil }
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The Keychain didn't accept \(name) (\(reason)). Your previous key is unchanged."
    }
}
