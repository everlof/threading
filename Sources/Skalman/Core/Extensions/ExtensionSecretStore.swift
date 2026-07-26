import Foundation
import Security
import SkalmanExtensionKit

enum ExtensionSecretStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case tooManyKeys(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain returned status \(status)."
        case .tooManyKeys(let maximum):
            return "An extension cannot store more than \(maximum) secrets."
        }
    }
}

/// Host-side persistence seam. Tests use an in-memory implementation; production uses Keychain.
protocol ExtensionSecretStoring: AnyObject {
    func data(extensionIdentifier: String, key: String) throws -> Data?
    func setData(_ data: Data, extensionIdentifier: String, key: String) throws
    func remove(extensionIdentifier: String, key: String) throws
    func keys(extensionIdentifier: String) throws -> [String]
}

/// Keeps extension credentials outside packages, ordinary KV JSON, backups, and sandbox grants.
final class KeychainExtensionSecretStore: ExtensionSecretStoring {
    static let shared = KeychainExtensionSecretStore()

    /// Internal so the containment probe can target the exact namespace production uses.
    /// This is not a credential; secrecy here would only make the isolation test less honest.
    static let servicePrefix = "se.mjukis.Skalman.extension-secrets.v1."

    private init() {}

    func data(extensionIdentifier: String, key: String) throws -> Data? {
        var query = baseQuery(extensionIdentifier: extensionIdentifier)
        query[kSecAttrAccount as String] = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ExtensionSecretStoreError.keychain(status)
        }
        return result as? Data
    }

    func setData(
        _ data: Data,
        extensionIdentifier: String,
        key: String
    ) throws {
        var query = baseQuery(extensionIdentifier: extensionIdentifier)
        query[kSecAttrAccount as String] = key

        let update: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            update as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ExtensionSecretStoreError.keychain(updateStatus)
        }

        let existingKeys = try keys(extensionIdentifier: extensionIdentifier)
        guard existingKeys.count < ExtensionSecretConstraints.maximumKeys else {
            throw ExtensionSecretStoreError.tooManyKeys(
                maximum: ExtensionSecretConstraints.maximumKeys
            )
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ExtensionSecretStoreError.keychain(addStatus)
        }
    }

    func remove(extensionIdentifier: String, key: String) throws {
        var query = baseQuery(extensionIdentifier: extensionIdentifier)
        query[kSecAttrAccount as String] = key
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExtensionSecretStoreError.keychain(status)
        }
    }

    func keys(extensionIdentifier: String) throws -> [String] {
        var query = baseQuery(extensionIdentifier: extensionIdentifier)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw ExtensionSecretStoreError.keychain(status)
        }
        let attributes: [[String: Any]]
        if let many = result as? [[String: Any]] {
            attributes = many
        } else if let one = result as? [String: Any] {
            attributes = [one]
        } else {
            attributes = []
        }
        return attributes.compactMap {
            $0[kSecAttrAccount as String] as? String
        }.sorted()
    }

    private func baseQuery(extensionIdentifier: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.servicePrefix + extensionIdentifier
        ]
    }
}
