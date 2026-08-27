import Foundation
import Security

/// One durable owner-device capability. The bearer is secret and remains in the Keychains on
/// both devices; the other fields are the Mac owner's revocation read model.
struct RemoteOwnerDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let token: String
    let deviceID: String
    let displayName: String
    let pairedAt: Date
    var lastSeenAt: Date?

    var authorization: RemoteAuthorization {
        RemoteAuthorization(
            shareID: id,
            capability: .interact,
            scope: .allSessions,
            principal: .ownerDevice,
            boundDeviceID: deviceID
        )
    }
}

protocol RemoteOwnerDevicePersisting: AnyObject {
    func load() throws -> [RemoteOwnerDeviceRecord]
    func save(_ devices: [RemoteOwnerDeviceRecord]) throws
    func deleteAll() throws
}

enum RemoteOwnerDeviceStoreError: LocalizedError {
    case keychain(OSStatus)
    case corrupt
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "The paired-device Keychain item could not be accessed (\(status))."
        case .corrupt:
            return "The paired-device Keychain item is unreadable."
        case .unsupportedVersion(let version):
            return "The paired-device Keychain item uses unsupported version \(version)."
        }
    }
}

/// A versioned Keychain blob. An unreadable value is never treated as an empty list: pairing and
/// revocation fail closed instead of overwriting the only copy of the user's device grants.
final class RemoteOwnerDeviceKeychainStore: RemoteOwnerDevicePersisting {
    private let blobs: MigratingKeychainBlobStore

    init(
        dataProtection: Bool? = nil,
        keychain: any KeychainItemAccessing = SystemKeychainItemAccess()
    ) {
        blobs = MigratingKeychainBlobStore(
            service: "codes.threading.remote.owner-devices",
            account: "owner-devices-v1",
            dataProtection: dataProtection,
            keychain: keychain
        )
    }

    func load() throws -> [RemoteOwnerDeviceRecord] {
        let result: MigratingKeychainBlobStore.ReadResult
        do {
            result = try blobs.read()
        } catch {
            throw mapped(error)
        }
        switch result {
        case .current(let data):
            let devices = try decode(data)
            blobs.discardLegacyCopyAfterValidatedCurrentRead()
            return devices
        case .legacy(let data):
            let devices = try decode(data)
            do {
                try blobs.save(data)
            } catch {
                throw mapped(error)
            }
            return devices
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

    private func decode(_ data: Data) throws -> [RemoteOwnerDeviceRecord] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw RemoteOwnerDeviceStoreError.corrupt
        }
        guard envelope.version == RemoteOwnerDeviceDefaults.version else {
            throw RemoteOwnerDeviceStoreError.unsupportedVersion(envelope.version)
        }
        guard Self.isValid(envelope.devices) else {
            throw RemoteOwnerDeviceStoreError.corrupt
        }
        return envelope.devices
    }

    func save(_ devices: [RemoteOwnerDeviceRecord]) throws {
        let data = try encode(devices)
        do {
            try blobs.save(data)
        } catch {
            throw mapped(error)
        }
    }

    private func encode(_ devices: [RemoteOwnerDeviceRecord]) throws -> Data {
        guard Self.isValid(devices) else { throw RemoteOwnerDeviceStoreError.corrupt }
        return try JSONEncoder().encode(Envelope(
            version: RemoteOwnerDeviceDefaults.version,
            devices: devices
        ))
    }

    func deleteAll() throws {
        do {
            try blobs.deleteAll()
        } catch {
            throw mapped(error)
        }
    }

    private func mapped(_ error: Error) -> RemoteOwnerDeviceStoreError {
        switch error {
        case MigratingKeychainBlobStoreError.keychain(let status):
            return .keychain(status)
        case MigratingKeychainBlobStoreError.malformedResult:
            return .corrupt
        default:
            return .corrupt
        }
    }

    private static func isValid(_ devices: [RemoteOwnerDeviceRecord]) -> Bool {
        guard devices.count <= RemoteOwnerDeviceDefaults.maximumDevices else { return false }
        let ids = Set(devices.map(\.id))
        let tokens = Set(devices.map(\.token))
        let deviceIDs = Set(devices.map(\.deviceID))
        guard ids.count == devices.count,
              tokens.count == devices.count,
              deviceIDs.count == devices.count else { return false }
        return devices.allSatisfy {
            !$0.id.isEmpty
                && $0.id.utf8.count <= RemoteOwnerDeviceDefaults.maximumIdentifierBytes
                && RemoteInboundPolicy.acceptsBearerToken($0.token)
                && $0.token.utf8.count >= RemoteOwnerDeviceDefaults.minimumTokenBytes
                && RemoteInboundPolicy.normalizedDeviceID($0.deviceID) == $0.deviceID
                && RemoteInboundPolicy.normalizedDeviceName($0.displayName) == $0.displayName
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let devices: [RemoteOwnerDeviceRecord]
    }
}

/// The stateful policy above the persistence adapter. Candidate state is written first; only a
/// successful write changes live authorization, so a failed revoke cannot reappear after reboot
/// and a failed pairing cannot hand out an access token the Mac forgot to record.
@MainActor
final class RemoteOwnerDeviceRegistry {
    private let store: RemoteOwnerDevicePersisting
    private(set) var devices: [RemoteOwnerDeviceRecord] = []
    private(set) var persistenceError: String?

    init(store: RemoteOwnerDevicePersisting) {
        self.store = store
        do {
            devices = try store.load()
            ThreadingLogger.remote.info(
                "Remote owner devices restored count=\(self.devices.count, privacy: .public)"
            )
        } catch {
            persistenceError = error.localizedDescription
            ThreadingLogger.remote.error(
                "Remote owner-device persistence failed stage=load error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    func pair(deviceID: String, displayName: String, token: String, now: Date = Date())
        -> RemoteOwnerDeviceRecord? {
        guard persistenceError == nil else { return nil }
        var candidate = devices
        let record: RemoteOwnerDeviceRecord
        if let index = candidate.firstIndex(where: { $0.deviceID == deviceID }) {
            record = RemoteOwnerDeviceRecord(
                id: candidate[index].id,
                token: token,
                deviceID: deviceID,
                displayName: displayName,
                pairedAt: candidate[index].pairedAt,
                lastSeenAt: now
            )
            candidate[index] = record
        } else {
            guard candidate.count < RemoteOwnerDeviceDefaults.maximumDevices else { return nil }
            record = RemoteOwnerDeviceRecord(
                id: UUID().uuidString.lowercased(),
                token: token,
                deviceID: deviceID,
                displayName: displayName,
                pairedAt: now,
                lastSeenAt: now
            )
            candidate.append(record)
        }
        guard persist(candidate) else { return nil }
        devices = candidate
        return record
    }

    func revoke(id: String) -> RemoteOwnerDeviceRecord? {
        guard persistenceError == nil,
              let record = devices.first(where: { $0.id == id }) else { return nil }
        let candidate = devices.filter { $0.id != id }
        guard persist(candidate) else { return nil }
        devices = candidate
        return record
    }

    func noteSeen(id: String, at date: Date = Date()) {
        guard persistenceError == nil,
              let index = devices.firstIndex(where: { $0.id == id }) else { return }
        var candidate = devices
        candidate[index].lastSeenAt = date
        guard persist(candidate) else { return }
        devices = candidate
    }

    /// `Reset Everything` is explicit authority to remove even an item that could not be
    /// decoded. Ordinary pairing and revocation stay fail-closed and never take this path.
    func deleteAllForAppReset() throws {
        let removedCount = devices.count
        do {
            try store.deleteAll()
        } catch {
            ThreadingLogger.remote.error(
                "Remote owner-device persistence failed stage=delete error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw error
        }
        devices = []
        persistenceError = nil
        ThreadingLogger.remote.notice(
            "Remote owner devices deleted for app reset count=\(removedCount, privacy: .public)"
        )
    }

    private func persist(_ candidate: [RemoteOwnerDeviceRecord]) -> Bool {
        do {
            try store.save(candidate)
            return true
        } catch {
            persistenceError = error.localizedDescription
            ThreadingLogger.remote.error(
                "Remote owner-device persistence failed stage=save count=\(candidate.count, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }
}

/// Keeps hosted tests away from the developer's login Keychain and gives store policy tests a
/// deterministic adapter.
final class InMemoryRemoteOwnerDeviceStore: RemoteOwnerDevicePersisting {
    var devices: [RemoteOwnerDeviceRecord]

    init(devices: [RemoteOwnerDeviceRecord] = []) {
        self.devices = devices
    }

    func load() throws -> [RemoteOwnerDeviceRecord] { devices }
    func save(_ devices: [RemoteOwnerDeviceRecord]) throws { self.devices = devices }
    func deleteAll() throws { devices = [] }
}

private enum RemoteOwnerDeviceDefaults {
    static let version = 1
    static let maximumDevices = 32
    static let maximumIdentifierBytes = 128
    /// A persisted device bearer is generated from 32 bytes and base64url-encoded. This lower
    /// bound rejects a truncated or hand-edited Keychain value without coupling validation to
    /// one textual encoding.
    static let minimumTokenBytes = 32
}
