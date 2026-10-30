import Foundation
import Security

/// API-key storage behind a protocol: the app uses the Keychain, tests use
/// the in-memory store (Keychain prompts must never block the suite).
protocol CredentialStore: Sendable {
    func apiKey() -> String?
    func setAPIKey(_ key: String?) throws
}

/// Keychain-backed store (generic password, this app only). Values never
/// touch UserDefaults or logs. Hardware-adjacent: verify once manually
/// (save → relaunch → still there); unit tests use the in-memory store.
final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let lock = NSLock()

    init(service: String = "com.gesturecue.metamodel", account: String = "apiKey") {
        self.service = service
        self.account = account
    }

    func apiKey() -> String? {
        lock.withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let key = String(data: data, encoding: .utf8), !key.isEmpty
            else { return nil }
            return key
        }
    }

    func setAPIKey(_ key: String?) throws {
        try lock.withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            guard let key, !key.isEmpty else {
                SecItemDelete(query as CFDictionary)
                return
            }
            let data = Data(key.utf8)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                let addStatus = SecItemAdd(add as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw GenerationError.keychain("Save failed (\(addStatus))")
                }
            } else if status != errSecSuccess {
                throw GenerationError.keychain("Update failed (\(status))")
            }
        }
    }
}

/// In-memory store for tests and previews. Same semantics, no persistence.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    init(key: String? = nil) {
        self.key = key
    }

    func apiKey() -> String? {
        lock.withLock { key }
    }

    func setAPIKey(_ key: String?) {
        lock.withLock { self.key = key }
    }
}
