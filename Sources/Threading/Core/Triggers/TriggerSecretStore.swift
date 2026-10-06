import Foundation
import Security

enum TriggerSecretStoreError: LocalizedError, Equatable {
    /// The listener's access list could not be built, usually because this build has no
    /// `threading-triggerd` to name.
    case accessList(OSStatus)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .accessList(let status):
            return L10n.format(
                "Threading could not let its background listener read this secret (error %lld).",
                Int64(status)
            )
        case .keychain(let status):
            return L10n.format("Keychain refused to store this secret (error %lld).", Int64(status))
        }
    }
}

/// Decrypt for this app and for the listener in its bundle, each named by its designated
/// requirement — identifier, Apple anchor and team, not a path or a hash — so an update signed by
/// the same team keeps reading, and every other program, `security` included, needs the person's
/// approval. Measured on 2026-10-05 with Developer ID–signed binaries: the trusted helper read
/// without a prompt, a rebuilt helper with the same requirement still did, and an untrusted
/// same-team binary was refused (errSecAuthFailed). Another process running as the person can
/// still overwrite an item's value, as it can rewrite the listener's `sources.json`; neither can
/// read a value.
enum TriggerSecretAccessList {
    static func make(listener: URL) throws -> SecAccess {
        var trusted: [SecTrustedApplication] = []
        // nil names this app; the listener is named by its path inside this bundle.
        for path in [nil, listener.path] as [String?] {
            var application: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &application)
            guard status == errSecSuccess, let application else {
                throw TriggerSecretStoreError.accessList(status)
            }
            trusted.append(application)
        }
        var access: SecAccess?
        let status = SecAccessCreate(TriggerSecretKeychain.label as CFString, trusted as CFArray, &access)
        guard status == errSecSuccess, let access else { throw TriggerSecretStoreError.accessList(status) }
        return access
    }
}

/// Writes trigger secrets where `threading-triggerd` can read them (TriggerDaemonContract.swift).
/// Values go in and are read only by the listener at poll time; the app asks only whether one
/// exists, and nothing returns one to a prompt, a page or MCP.
struct TriggerSecretStore: Sendable {
    struct Migration: Equatable, Sendable {
        var rewritten = 0
        var unreadable = 0
    }

    static let shared = TriggerSecretStore()

    /// Items examined per service by one migration.
    static let migrationLimit = 256

    var keychain: any TriggerSecretKeychainAccessing = SystemTriggerSecretKeychain()
    /// Built for each write, before anything is replaced: a build without a listener to name
    /// keeps the old item rather than losing it.
    var accessList: @Sendable () throws -> SecAccess = {
        try TriggerSecretAccessList.make(listener: TriggerDaemonRegistrationCoordinator.helperURL)
    }

    /// Replaces the item rather than updating it. An update keeps the old access list, and an
    /// item an earlier build stored names only the app.
    func save(_ value: String, service: TriggerSecretService, account: String) throws {
        guard !value.isEmpty else { throw TriggerStore.StoreError.invalidRecord("secret value") }
        let access = try accessList()
        let query = TriggerSecretKeychain.itemQuery(service, account: account)
        let removed = keychain.delete(query)
        guard removed == errSecSuccess || removed == errSecItemNotFound else {
            throw TriggerSecretStoreError.keychain(removed)
        }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccess as String] = access
        item[kSecAttrLabel as String] = TriggerSecretKeychain.label
        item[kSecAttrGeneric as String] = TriggerSecretKeychain.formatMarker
        let added = keychain.add(item)
        guard added == errSecSuccess else { throw TriggerSecretStoreError.keychain(added) }
    }

    /// Attributes only, which no access list gates: this cannot prompt and cannot see a value.
    func exists(service: TriggerSecretService, account: String) -> Bool {
        var query = TriggerSecretKeychain.itemQuery(service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return keychain.copyMatching(query).status == errSecSuccess
    }

    func delete(service: TriggerSecretService, account: String) throws {
        try delete(TriggerSecretKeychain.itemQuery(service, account: account))
    }

    func deleteAll(service: TriggerSecretService) throws {
        try delete(TriggerSecretKeychain.itemQuery(service))
    }

    /// The launch-time pass. Automated runs never migrate: they would rewrite the developer's
    /// real items for a test build's signature. Blocks on `KeychainInteractionGate`, so call it
    /// from a detached worker.
    func migrateEarlierItemsAtLaunch(automatedRun: Bool) -> Migration? {
        automatedRun ? nil : migrateEarlierItems()
    }

    /// Rewrites every item an earlier build stored. Those builds passed an access group outside
    /// the data-protection Keychain, which the login Keychain ignores, so each item's access list
    /// names only the app. The app can therefore read the value without a prompt and store it
    /// again with the listener's access. An item it cannot read stays as it was, and the listener
    /// reports it as one to set again.
    ///
    /// Every read runs with keychain prompts held back, so an item only a differently signed
    /// build may read (a Debug build's, say) is counted, never put in front of the person at
    /// launch, and never re-signed for this build's listener. That makes the pass safe to repeat:
    /// it runs at every launch, retries what a locked keychain refused, and costs one attribute
    /// query per service once every item carries the marker.
    func migrateEarlierItems() -> Migration {
        KeychainInteractionGate.run(allowingPrompt: false) { rewriteUnmarkedItems() }
    }

    private func rewriteUnmarkedItems() -> Migration {
        var result = Migration()
        for service in TriggerSecretService.allCases {
            var listing = TriggerSecretKeychain.itemQuery(service)
            listing[kSecReturnAttributes as String] = true
            listing[kSecMatchLimit as String] = kSecMatchLimitAll
            let answer = keychain.copyMatching(listing)
            guard answer.status == errSecSuccess, let items = answer.result as? [[String: Any]] else { continue }
            for attributes in items.prefix(Self.migrationLimit) {
                guard attributes[kSecAttrGeneric as String] as? Data != TriggerSecretKeychain.formatMarker,
                      let account = attributes[kSecAttrAccount as String] as? String else { continue }
                var read = TriggerSecretKeychain.itemQuery(service, account: account)
                read[kSecReturnData as String] = true
                read[kSecMatchLimit as String] = kSecMatchLimitOne
                let stored = keychain.copyMatching(read)
                guard stored.status == errSecSuccess, let data = stored.result as? Data,
                      let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                    result.unreadable += 1
                    continue
                }
                do {
                    try save(value, service: service, account: account)
                    result.rewritten += 1
                } catch {
                    // `save` may have removed the old item before its add failed. Put the value
                    // back as it was rather than lose it; a duplicate answer means it never left.
                    var restore = TriggerSecretKeychain.itemQuery(service, account: account)
                    restore[kSecValueData as String] = data
                    _ = keychain.add(restore)
                    result.unreadable += 1
                }
            }
        }
        return result
    }

    private func delete(_ query: [String: Any]) throws {
        let status = keychain.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TriggerSecretStoreError.keychain(status)
        }
    }
}
