import Foundation
import Security
import ThreadingRemoteKit

/// Durable accepted one-target capabilities. Invitations and members are persisted together so
/// the UI promise "until Stop Sharing" survives a Mac restart, while each bearer remains in a
/// ThisDeviceOnly Keychain item rather than a preferences file.
struct RemoteGuestShareRecord: Codable, Equatable, Sendable {
    enum TargetKind: String, Codable, Equatable, Sendable {
        case projectTerminal
    }

    struct Member: Codable, Equatable, Sendable {
        let id: String
        let token: String
        let displayName: String
        let deviceID: String
        let joinedAt: Date
        var lastSeenAt: Date?
    }

    let id: String
    /// Nil is the original one-chat record shape; terminal records opt in explicitly.
    let targetKind: TargetKind?
    let sessionID: String
    var invitationToken: String?
    var hostedInvitationURL: URL?
    let capability: RemoteCapability
    let canApprovePermissions: Bool
    let createdAt: Date
    let expiresAt: Date
    var members: [Member]

    init(
        id: String,
        targetKind: TargetKind? = nil,
        sessionID: String,
        invitationToken: String?,
        hostedInvitationURL: URL? = nil,
        capability: RemoteCapability,
        canApprovePermissions: Bool,
        createdAt: Date,
        expiresAt: Date,
        members: [Member]
    ) {
        self.id = id
        self.targetKind = targetKind
        self.sessionID = sessionID
        self.invitationToken = invitationToken
        self.hostedInvitationURL = hostedInvitationURL
        self.capability = capability
        self.canApprovePermissions = canApprovePermissions
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.members = members
    }
}

protocol RemoteGuestSharePersisting: AnyObject {
    func load() throws -> [RemoteGuestShareRecord]
    func save(_ shares: [RemoteGuestShareRecord]) throws
    func deleteAll() throws
}

enum RemoteGuestShareStoreError: LocalizedError {
    case keychain(OSStatus)
    case corrupt
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "The shared-chat Keychain item could not be accessed (\(status))."
        case .corrupt:
            return "The shared-chat Keychain item is unreadable. It was left untouched."
        case .unsupportedVersion(let version):
            return "The shared-chat Keychain item uses unsupported version \(version)."
        }
    }
}

final class RemoteGuestShareKeychainStore: RemoteGuestSharePersisting {
    private let blobs: MigratingKeychainBlobStore

    init(
        dataProtection: Bool? = nil,
        keychain: any KeychainItemAccessing = SystemKeychainItemAccess()
    ) {
        blobs = MigratingKeychainBlobStore(
            service: "codes.threading.remote-guest-shares",
            account: "guest-shares-v1",
            dataProtection: dataProtection,
            keychain: keychain
        )
    }

    func load() throws -> [RemoteGuestShareRecord] {
        let result: MigratingKeychainBlobStore.ReadResult
        do {
            result = try blobs.read()
        } catch {
            throw mapped(error)
        }
        switch result {
        case .current(let data):
            let shares = try decode(data)
            blobs.discardLegacyCopyAfterValidatedCurrentRead()
            return shares
        case .legacy(let data):
            let shares = try decode(data)
            do {
                try blobs.save(data)
            } catch {
                throw mapped(error)
            }
            return shares
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

    private func decode(_ data: Data) throws -> [RemoteGuestShareRecord] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw RemoteGuestShareStoreError.corrupt
        }
        guard envelope.version == Defaults.version else {
            throw RemoteGuestShareStoreError.unsupportedVersion(envelope.version)
        }
        guard Self.isValid(envelope.shares) else { throw RemoteGuestShareStoreError.corrupt }
        return envelope.shares
    }

    func save(_ shares: [RemoteGuestShareRecord]) throws {
        let data = try encode(shares)
        do {
            try blobs.save(data)
        } catch {
            throw mapped(error)
        }
    }

    private func encode(_ shares: [RemoteGuestShareRecord]) throws -> Data {
        guard Self.isValid(shares),
              let data = try? JSONEncoder().encode(Envelope(
                version: Defaults.version,
                shares: shares
              )) else { throw RemoteGuestShareStoreError.corrupt }
        return data
    }

    func deleteAll() throws {
        do {
            try blobs.deleteAll()
        } catch {
            throw mapped(error)
        }
    }

    private func mapped(_ error: Error) -> RemoteGuestShareStoreError {
        switch error {
        case MigratingKeychainBlobStoreError.keychain(let status):
            return .keychain(status)
        case MigratingKeychainBlobStoreError.malformedResult:
            return .corrupt
        default:
            return .corrupt
        }
    }

    private static func isValid(_ shares: [RemoteGuestShareRecord]) -> Bool {
        guard shares.count <= Defaults.maximumShares,
              Set(shares.map(\.id)).count == shares.count else { return false }
        let members = shares.flatMap(\.members)
        guard members.count <= Defaults.maximumMembers,
              Set(members.map(\.id)).count == members.count,
              Set(members.map(\.token)).count == members.count else { return false }
        return shares.allSatisfy { share in
            (share.targetKind == .projectTerminal
                ? TerminalID(uuidString: share.sessionID) != nil
                : SessionID(uuidString: share.sessionID) != nil)
                && !share.id.isEmpty
                && share.invitationToken.map(RemoteInboundPolicy.acceptsBearerToken) ?? true
                && share.members.allSatisfy { member in
                    RemoteInboundPolicy.acceptsBearerToken(member.token)
                        && RemoteInboundPolicy.normalizedDeviceID(member.deviceID)
                            == member.deviceID
                        && RemoteInboundPolicy.normalizedMemberName(member.displayName)
                            == member.displayName
                }
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let shares: [RemoteGuestShareRecord]
    }

    private enum Defaults {
        static let version = 1
        static let maximumShares = 128
        static let maximumMembers = 256
    }
}

final class InMemoryRemoteGuestShareStore: RemoteGuestSharePersisting {
    var shares: [RemoteGuestShareRecord]

    init(shares: [RemoteGuestShareRecord] = []) { self.shares = shares }
    func load() throws -> [RemoteGuestShareRecord] { shares }
    func save(_ shares: [RemoteGuestShareRecord]) throws { self.shares = shares }
    func deleteAll() throws { shares = [] }
}
