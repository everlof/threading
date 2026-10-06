import Foundation
import Security

// The contract between Threading and `threading-triggerd` beside the probe pipeline: where a
// trigger secret lives and how the listener reads it, and the heartbeat that says the listener
// is actually running. Compiled into both the daemon and the app, like TriggerProbeSources.swift,
// so the reader the app's tests exercise is the one the daemon runs.
//
// **Why the login Keychain and not an access group.** The listener used to read these items
// through a `keychain-access-groups` entitlement. That entitlement is profile-backed: AMFI honours
// it only when an embedded provisioning profile authorizes it, and a bare executable in
// Contents/Helpers cannot embed one, so launchd's every spawn ended in OS_REASON_CODESIGNING and
// no source ever polled. The writes never reached a group either: `kSecAttrAccessGroup` without
// `kSecUseDataProtectionKeychain` lands in the login Keychain with an access list naming only the
// app (measured 2026-10-05 with a profile-signed bundle). A login-Keychain item whose access list
// names the app and the listener by designated requirement needs no restricted entitlement on
// either side, survives updates signed by the same team, and is still unreadable without a prompt
// to every other program. See docs/architecture/triggers.md.

// MARK: - Secrets

/// The two kinds of trigger secret, each one generic-password service in the login Keychain.
enum TriggerSecretService: CaseIterable, Sendable {
    /// A connected source's credential, by its `credentialReference`.
    case sourceCredential
    /// A probe secret, by its name.
    case probeSecret

    var service: String {
        switch self {
        case .sourceCredential: return "codes.threading.trigger-source"
        case .probeSecret: return TriggerProbeDefaults.secretService
        }
    }
}

/// Why the listener could not read a secret. It names the secret, never its value, and every
/// case is the person's to fix, so a source reports it as authentication required.
struct TriggerSecretReadFailure: LocalizedError, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// No item: never stored, or removed.
        case missing
        /// The item exists, but its access list does not name this program or the login
        /// Keychain is locked. Either would have needed a prompt, and the listener never asks.
        case refused
        case keychain(Int32)
    }

    let service: TriggerSecretService
    let name: String
    let reason: Reason

    init(service: TriggerSecretService, name: String, reason: Reason) {
        self.service = service
        self.name = name
        self.reason = reason
    }

    init(service: TriggerSecretService, name: String, status: OSStatus) {
        let reason: Reason
        switch status {
        case errSecItemNotFound: reason = .missing
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecNoAccessForItem, errSecUserCanceled:
            reason = .refused
        default: reason = .keychain(status)
        }
        self.init(service: service, name: name, reason: reason)
    }

    // The daemon's receipts are plain English, like its other diagnostics; the app shows them as
    // the source's bounded diagnostic.
    var errorDescription: String? {
        let subject = service == .probeSecret ? "secret “\(name)”" : "the source credential"
        switch reason {
        case .missing:
            return service == .probeSecret
                ? "Secret “\(name)” is not set."
                : "The source credential is not set. Reconnect the source."
        case .refused:
            let fix = service == .probeSecret ? "Set it again under Secrets…" : "Reconnect the source"
            return "The background listener may not read \(subject). \(fix), and keep the login keychain unlocked."
        case .keychain(let status):
            return "Keychain could not read \(subject) (error \(status))."
        }
    }
}

/// The Security calls the secret stores make, so hosted tests never touch the developer's
/// Keychain. `SystemTriggerSecretKeychain` is the one conformer that does.
protocol TriggerSecretKeychainAccessing: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemTriggerSecretKeychain: TriggerSecretKeychainAccessing {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

enum TriggerSecretKeychain {
    /// What Keychain Access shows for an item, and the description its access list carries.
    static let label = "Threading automation secret"
    /// Written into every item whose access list names the listener. An item without it was
    /// stored by a build that named only the app, and is rewritten once by the app.
    static let formatMarker = Data("threading-triggerd-acl/1".utf8)

    /// One service's items, or one item, in the login Keychain. Never an access group, and never
    /// the data-protection Keychain: either needs an entitlement the listener cannot carry.
    static func itemQuery(_ service: TriggerSecretService, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.service,
            kSecUseDataProtectionKeychain as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// The listener's read. It never prompts: the daemon switches Keychain user interaction off
    /// for its whole process, so an item it may not read answers with a status instead of a
    /// dialog from a background helper.
    static func read(
        _ service: TriggerSecretService,
        account: String,
        keychain: any TriggerSecretKeychainAccessing = SystemTriggerSecretKeychain()
    ) throws -> String {
        var query = itemQuery(service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let answer = keychain.copyMatching(query)
        guard answer.status == errSecSuccess else {
            throw TriggerSecretReadFailure(service: service, name: account, status: answer.status)
        }
        guard let data = answer.result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw TriggerSecretReadFailure(service: service, name: account, reason: .missing)
        }
        return value
    }
}

/// A probe's secrets, resolved by name through the listener's read.
struct KeychainTriggerProbeSecrets: TriggerProbeSecretResolving {
    var keychain: any TriggerSecretKeychainAccessing = SystemTriggerSecretKeychain()

    func value(forSecret name: String) throws -> String {
        try TriggerSecretKeychain.read(.probeSecret, account: name, keychain: keychain)
    }
}

// MARK: - Heartbeat

/// What a running listener writes to `listener.json` in its directory. ServiceManagement reports
/// `.enabled` for a job launchd kills at every spawn, so a registration alone cannot say the
/// listener runs; this file can, and its absence is what the Sources page explains.
struct TriggerListenerHeartbeat: Codable, Equatable, Sendable {
    static let fileName = "listener.json"
    /// How often the listener rewrites it.
    static let interval: TimeInterval = 30
    /// How old it may be before the app stops believing the listener is running: four missed
    /// beats, so a busy or briefly suspended Mac is not reported as a failure.
    static let staleAfter: TimeInterval = 120

    let processIdentifier: Int32
    let startedAt: Date
    let heartbeatAt: Date

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> TriggerListenerHeartbeat {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TriggerListenerHeartbeat.self, from: data)
    }
}
