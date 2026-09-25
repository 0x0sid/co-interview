import Foundation
import Security

/// The credential the backend issued to this installation (`POST /v1/installations`).
///
/// **The app never chooses its own identity.** The installation id, its secret and the RevenueCat app
/// user id all come from the server; the backend looks entitlement up for the app user id *it* bound
/// to this installation, so nothing the app sends can point that check at another customer.
struct InstallationCredential: Codable, Equatable, Sendable {
    let installationID: String
    let secret: String
    /// The RevenueCat identity the server bound to this installation. Passed to RevenueCat so
    /// purchases land on the customer the server checks.
    let appUserID: String

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case secret
        case appUserID = "app_user_id"
    }

    /// `Authorization` header value for every backend request from this installation.
    var authorizationHeader: String { "Installation \(installationID).\(secret)" }
}

/// Small Keychain wrapper for this app's access records.
///
/// Items are `AfterFirstUnlock` (a Live session can start from a locked-then-unlocked phone) and not
/// synchronised. They often survive deleting and reinstalling the app, **but iOS does not promise
/// that**, so nothing here depends on it: a lost credential means a new installation, and purchases
/// come back through Restore Purchases.
enum AccessKeychain {
    static let service = "talk.cointerview.access"

    static func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        let query = baseQuery(account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Where the installation credential is kept. Injectable so tests never touch the real Keychain.
struct InstallationCredentialStore: Sendable {
    var load: @Sendable () -> InstallationCredential?
    var save: @Sendable (InstallationCredential) -> Void

    static let keychain = InstallationCredentialStore(
        load: {
            AccessKeychain.data(for: "installation").flatMap { try? JSONDecoder().decode(InstallationCredential.self, from: $0) }
        },
        save: { credential in
            if let data = try? JSONEncoder().encode(credential) { AccessKeychain.set(data, for: "installation") }
        }
    )

    static func inMemory(_ initial: InstallationCredential? = nil) -> InstallationCredentialStore {
        let box = LockedBox(initial)
        return InstallationCredentialStore(load: { box.value }, save: { box.value = $0 })
    }
}

/// A tiny lock-protected value, for the in-memory store.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
