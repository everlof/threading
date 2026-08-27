import Foundation
import Security

/// The strongest Keychain this build can actually use.
///
/// The data-protection Keychain needs a team-backed `keychain-access-groups` entitlement. Debug
/// builds are ad-hoc signed, so selecting it from the build configuration alone would turn every
/// write into `errSecMissingEntitlement`. Probe once and make every credential store report the
/// same answer instead.
enum KeychainStoragePolicy {
    private static let probeService = "codes.threading.keychain.data-protection.probe"
    private static let probeAccount = "data-protection-v1"

    static let usesDataProtectionKeychain: Bool = {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        _ = SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data("probe".utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { return false }
        _ = SecItemDelete(base as CFDictionary)
        return true
    }()

    /// Whether `security add-generic-password` or `security delete-generic-password` can address
    /// the selected store from the agent's own shell.
    static var isShellReachable: Bool { !usesDataProtectionKeychain }

    /// The one honest description used anywhere Settings exposes a store under this policy.
    /// Keeping the words beside the probe prevents one credential surface from claiming the
    /// protected boundary while another silently fell back to the login Keychain.
    static func storageDescription(isShellReachable: Bool) -> String {
        isShellReachable
            ? L10n.string("""
                Stored in your login Keychain, and removed by Reset Everything. This build cannot \
                use the protected Keychain, so a command line on this Mac — including an agent's — \
                could add or delete entries here.
                """)
            : L10n.string("""
                Stored in your protected Keychain, out of reach of the command line, and removed \
                by Reset Everything.
                """)
    }
}

/// The four Security.framework operations used by the versioned remote-capability blobs.
///
/// Keeping the adapter below the stores makes the migration executable in a hosted test without
/// writing capabilities into the developer's real Keychain.
protocol KeychainItemAccessing {
    func data(matching query: [String: Any]) -> (status: OSStatus, data: Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainItemAccess: KeychainItemAccessing, Sendable {
    func data(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

enum MigratingKeychainBlobStoreError: Error {
    case keychain(OSStatus)
    case malformedResult
}

/// One generic-password item that prefers the data-protection Keychain and can promote the
/// previous login-Keychain item without ever treating unvalidated bytes as current authority.
///
/// Decoding and domain validation deliberately remain in the owner/guest stores. `legacy` is a
/// candidate, not an instruction to copy: the caller validates it first and only then calls
/// `save(_:)`. Once a protected item exists it is the sole authority. A best-effort legacy delete
/// removes the obsolete duplicate, but its failure cannot make a committed protected save appear
/// to have failed to the registry above it.
final class MigratingKeychainBlobStore {
    enum ReadResult: Equatable {
        case current(Data)
        case legacy(Data)
        case missing
    }

    let usesDataProtectionKeychain: Bool

    private let service: String
    private let account: String
    private let accessible: CFString
    private let keychain: any KeychainItemAccessing

    init(
        service: String,
        account: String,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        dataProtection: Bool? = nil,
        keychain: any KeychainItemAccessing = SystemKeychainItemAccess()
    ) {
        self.service = service
        self.account = account
        self.accessible = accessible
        usesDataProtectionKeychain = dataProtection
            ?? KeychainStoragePolicy.usesDataProtectionKeychain
        self.keychain = keychain
    }

    func read() throws -> ReadResult {
        if let data = try read(query(dataProtection: usesDataProtectionKeychain)) {
            return .current(data)
        }
        guard usesDataProtectionKeychain else { return .missing }
        if let data = try read(query(dataProtection: false)) {
            return .legacy(data)
        }
        return .missing
    }

    /// A protected blob is authoritative only after its owner has decoded and validated it.
    /// Keeping cleanup out of `read()` preserves a valid legacy recovery copy when a partial or
    /// future writer left an unreadable protected item behind.
    func discardLegacyCopyAfterValidatedCurrentRead() {
        removeLegacyCopyIfNeeded()
    }

    func save(_ data: Data) throws {
        let base = query(dataProtection: usesDataProtectionKeychain)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ]
        let updateStatus = keychain.update(base, attributes: attributes)
        if updateStatus != errSecSuccess {
            guard updateStatus == errSecItemNotFound else {
                throw MigratingKeychainBlobStoreError.keychain(updateStatus)
            }
            var add = base
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = keychain.add(add)
            guard addStatus == errSecSuccess else {
                throw MigratingKeychainBlobStoreError.keychain(addStatus)
            }
        }
        removeLegacyCopyIfNeeded()
    }

    /// Reset is explicit authority to remove both the current item and any legacy copy. Attempt
    /// both even when the first deletion fails, then surface the first refusal.
    func deleteAll() throws {
        let currentStatus = keychain.delete(query(
            dataProtection: usesDataProtectionKeychain
        ))
        let legacyStatus = usesDataProtectionKeychain
            ? keychain.delete(query(dataProtection: false))
            : errSecItemNotFound
        for status in [currentStatus, legacyStatus]
        where status != errSecSuccess && status != errSecItemNotFound {
            throw MigratingKeychainBlobStoreError.keychain(status)
        }
    }

    private func read(_ base: [String: Any]) throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = keychain.data(matching: query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw MigratingKeychainBlobStoreError.keychain(result.status)
        }
        guard let data = result.data else {
            throw MigratingKeychainBlobStoreError.malformedResult
        }
        return data
    }

    private func query(dataProtection: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
    }

    private func removeLegacyCopyIfNeeded() {
        guard usesDataProtectionKeychain else { return }
        // A protected item is already authoritative. The login-Keychain copy can no longer grant
        // access, so a cleanup refusal must not turn a committed save into an apparent failure.
        _ = keychain.delete(query(dataProtection: false))
    }
}
