import Foundation
import Security
import ThreadingPeerTransport
import ThreadingRemoteKit

/// The durable, device-bound half of a notification registration.
///
/// Authorization deliberately does not live here. On every Remote Access start the coordinator
/// rebinds these records to the current owner-device and accepted-member capability stores. A
/// stale record therefore cannot survive revocation as usable authority, even if removing this
/// secondary Keychain item failed after the authoritative revoke committed.
struct RemoteNotificationSubscriptionRecord: Codable, Equatable, Sendable {
    let shareID: String
    let deviceID: String
    let deviceToken: String
    let hostedRegistrationID: String?
    /// The control-plane origin that minted `hostedRegistrationID`.
    ///
    /// Older records decode this as `nil` and remain valid but inert for hosted delivery until
    /// the phone registers again. Guessing an origin would let a production identifier cross
    /// into the isolated development broker.
    let hostedServiceURL: String?
    let environment: RemoteNotificationEnvironment
    let enabledKinds: [RemoteNotificationKind]
    let soundEnabledKinds: [RemoteNotificationKind]

    init(
        shareID: String,
        deviceID: String,
        deviceToken: String,
        hostedRegistrationID: String? = nil,
        hostedServiceURL: String? = nil,
        environment: RemoteNotificationEnvironment,
        enabledKinds: [RemoteNotificationKind],
        soundEnabledKinds: [RemoteNotificationKind]
    ) {
        self.shareID = shareID
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.hostedRegistrationID = hostedRegistrationID
        self.hostedServiceURL = hostedServiceURL
        self.environment = environment
        self.enabledKinds = enabledKinds
        self.soundEnabledKinds = soundEnabledKinds
    }

    var key: RemoteNotificationSubscriptionKey {
        RemoteNotificationSubscriptionKey(shareID: shareID, deviceID: deviceID)
    }
}

struct RemoteNotificationSubscriptionKey: Hashable, Sendable {
    let shareID: String
    let deviceID: String
}

protocol RemoteNotificationSubscriptionPersisting: AnyObject {
    func load() throws -> [RemoteNotificationSubscriptionRecord]
    func save(_ subscriptions: [RemoteNotificationSubscriptionRecord]) throws
    func deleteAll() throws
}

enum RemoteNotificationSubscriptionStoreError: LocalizedError {
    case keychain(OSStatus)
    case corrupt
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "The notification-registration Keychain item could not be accessed (\(status))."
        case .corrupt:
            return "The notification-registration Keychain item is unreadable."
        case .unsupportedVersion(let version):
            return "The notification-registration Keychain item uses unsupported version \(version)."
        }
    }
}

/// A separate protected item keeps corrupt notification metadata from disabling the underlying
/// paired-device capability. Missing, unreadable, and future-version data remain distinct; a
/// failed load blocks registration writes rather than turning the item into an empty store.
final class RemoteNotificationSubscriptionKeychainStore: RemoteNotificationSubscriptionPersisting {
    private let blobs: MigratingKeychainBlobStore

    init(
        dataProtection: Bool? = nil,
        keychain: any KeychainItemAccessing = SystemKeychainItemAccess()
    ) {
        blobs = MigratingKeychainBlobStore(
            service: "codes.threading.remote-notification-subscriptions",
            account: "notification-subscriptions-v1",
            dataProtection: dataProtection,
            keychain: keychain
        )
    }

    func load() throws -> [RemoteNotificationSubscriptionRecord] {
        let result: MigratingKeychainBlobStore.ReadResult
        do {
            result = try blobs.read()
        } catch {
            throw mapped(error)
        }
        switch result {
        case .current(let data):
            let subscriptions = try decode(data)
            blobs.discardLegacyCopyAfterValidatedCurrentRead()
            return subscriptions
        case .legacy(let data):
            let subscriptions = try decode(data)
            do {
                try blobs.save(data)
            } catch {
                throw mapped(error)
            }
            return subscriptions
        case .missing:
            guard blobs.usesDataProtectionKeychain else { return [] }
            let data = try encode([])
            do {
                try blobs.save(data)
            } catch {
                throw mapped(error)
            }
            return []
        }
    }

    func save(_ subscriptions: [RemoteNotificationSubscriptionRecord]) throws {
        let data = try encode(subscriptions)
        do {
            try blobs.save(data)
        } catch {
            throw mapped(error)
        }
    }

    func deleteAll() throws {
        do {
            try blobs.deleteAll()
        } catch {
            throw mapped(error)
        }
    }

    private func decode(_ data: Data) throws -> [RemoteNotificationSubscriptionRecord] {
        guard data.count <= RemoteNotificationSubscriptionDefaults.maximumEncodedBytes else {
            throw RemoteNotificationSubscriptionStoreError.corrupt
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw RemoteNotificationSubscriptionStoreError.corrupt
        }
        guard envelope.version == RemoteNotificationSubscriptionDefaults.version else {
            throw RemoteNotificationSubscriptionStoreError.unsupportedVersion(envelope.version)
        }
        guard RemoteNotificationSubscriptionDefaults.isValid(envelope.subscriptions) else {
            throw RemoteNotificationSubscriptionStoreError.corrupt
        }
        return envelope.subscriptions
    }

    private func encode(_ subscriptions: [RemoteNotificationSubscriptionRecord]) throws -> Data {
        guard RemoteNotificationSubscriptionDefaults.isValid(subscriptions) else {
            throw RemoteNotificationSubscriptionStoreError.corrupt
        }
        let data = try JSONEncoder().encode(Envelope(
            version: RemoteNotificationSubscriptionDefaults.version,
            subscriptions: subscriptions
        ))
        guard data.count <= RemoteNotificationSubscriptionDefaults.maximumEncodedBytes else {
            throw RemoteNotificationSubscriptionStoreError.corrupt
        }
        return data
    }

    private func mapped(_ error: Error) -> RemoteNotificationSubscriptionStoreError {
        switch error {
        case MigratingKeychainBlobStoreError.keychain(let status):
            return .keychain(status)
        case MigratingKeychainBlobStoreError.malformedResult:
            return .corrupt
        default:
            return .corrupt
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let subscriptions: [RemoteNotificationSubscriptionRecord]
    }
}

/// Keeps hosted tests away from the developer's Keychain and lets lifecycle tests preserve the
/// exact store object while reconstructing the service around it.
final class InMemoryRemoteNotificationSubscriptionStore: RemoteNotificationSubscriptionPersisting {
    var subscriptions: [RemoteNotificationSubscriptionRecord]

    init(subscriptions: [RemoteNotificationSubscriptionRecord] = []) {
        self.subscriptions = subscriptions
    }

    func load() throws -> [RemoteNotificationSubscriptionRecord] { subscriptions }
    func save(_ subscriptions: [RemoteNotificationSubscriptionRecord]) throws {
        self.subscriptions = subscriptions
    }
    func deleteAll() throws { subscriptions = [] }
}

enum RemoteNotificationSubscriptionDefaults {
    static let version = 1
    /// Owner capabilities admit 32 devices and accepted guest memberships admit 256 members.
    /// One device/share pair owns at most one record, so the complete persisted scan is fixed.
    static let maximumSubscriptions = 288
    static let maximumEncodedBytes = 1_048_576
    static let maximumHostedServiceURLBytes = 2_048

    static func isValid(_ subscriptions: [RemoteNotificationSubscriptionRecord]) -> Bool {
        guard subscriptions.count <= maximumSubscriptions,
              Set(subscriptions.map(\.key)).count == subscriptions.count else { return false }
        return subscriptions.allSatisfy { subscription in
            let enabledKinds = Set(subscription.enabledKinds)
            let soundKinds = Set(subscription.soundEnabledKinds)
            return RemoteInboundPolicy.acceptsAttentionRecipientID(subscription.shareID)
                && RemoteInboundPolicy.normalizedDeviceID(subscription.deviceID)
                    == subscription.deviceID
                && acceptsDeviceToken(subscription.deviceToken)
                && acceptsHostedRegistrationID(subscription.hostedRegistrationID)
                && acceptsHostedServiceURL(subscription.hostedServiceURL)
                && (subscription.hostedServiceURL == nil
                    || subscription.hostedRegistrationID != nil)
                && enabledKinds.count == subscription.enabledKinds.count
                && soundKinds.count == subscription.soundEnabledKinds.count
                && soundKinds.isSubset(of: enabledKinds)
        }
    }

    static func acceptsDeviceToken(_ token: String) -> Bool {
        !token.isEmpty
            && token.utf8.count <= RemoteAccessDefaults.maximumPushDeviceTokenBytes
            && token.count.isMultiple(of: 2)
            && token.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 48...57, 97...102: true
                default: false
                }
            }
    }

    static func acceptsHostedRegistrationID(_ identifier: String?) -> Bool {
        guard let identifier else { return true }
        return identifier.hasPrefix("th_push_")
            && (40...256).contains(identifier.utf8.count)
            && identifier.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 45, 48...57, 65...90, 95, 97...122: true
                default: false
                }
            }
    }

    static func normalizedHostedServiceURL(_ url: URL?) -> String? {
        guard let url,
              let endpoint = try? PeerControlPlaneServiceEndpoint(url),
              !endpoint.isLoopback else { return nil }
        return endpoint.baseURL.absoluteString
    }

    static func acceptsHostedServiceURL(_ value: String?) -> Bool {
        guard let value else { return true }
        guard !value.isEmpty,
              value.utf8.count <= maximumHostedServiceURLBytes,
              let url = URL(string: value) else { return false }
        return normalizedHostedServiceURL(url) == value
    }
}
