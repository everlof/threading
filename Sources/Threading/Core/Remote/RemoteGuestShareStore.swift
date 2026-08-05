import Foundation
import Security
import ThreadingRemoteKit

/// Durable accepted one-chat capabilities. Invitations and members are persisted together so
/// the UI promise "until Stop Sharing" survives a Mac restart, while each bearer remains in a
/// ThisDeviceOnly Keychain item rather than a preferences file.
struct RemoteGuestShareRecord: Codable, Equatable, Sendable {
    struct Member: Codable, Equatable, Sendable {
        let id: String
        let token: String
        let displayName: String
        let deviceID: String
        let joinedAt: Date
        var lastSeenAt: Date?
    }

    let id: String
    let sessionID: String
    var invitationToken: String?
    let capability: RemoteCapability
    let canApprovePermissions: Bool
    let createdAt: Date
    let expiresAt: Date
    var members: [Member]
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
    private let service = "codes.threading.remote-guest-shares"
    private let account = "guest-shares-v1"

    func load() throws -> [RemoteGuestShareRecord] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw RemoteGuestShareStoreError.keychain(status) }
        guard let data = result as? Data,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw RemoteGuestShareStoreError.corrupt
        }
        guard envelope.version == Defaults.version else {
            throw RemoteGuestShareStoreError.unsupportedVersion(envelope.version)
        }
        guard Self.isValid(envelope.shares) else { throw RemoteGuestShareStoreError.corrupt }
        return envelope.shares
    }

    func save(_ shares: [RemoteGuestShareRecord]) throws {
        guard Self.isValid(shares),
              let data = try? JSONEncoder().encode(Envelope(
                version: Defaults.version,
                shares: shares
              )) else { throw RemoteGuestShareStoreError.corrupt }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw RemoteGuestShareStoreError.keychain(status)
        }
        var add = baseQuery
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RemoteGuestShareStoreError.keychain(addStatus)
        }
    }

    func deleteAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteGuestShareStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private var readQuery: [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private static func isValid(_ shares: [RemoteGuestShareRecord]) -> Bool {
        guard shares.count <= Defaults.maximumShares,
              Set(shares.map(\.id)).count == shares.count else { return false }
        let members = shares.flatMap(\.members)
        guard members.count <= Defaults.maximumMembers,
              Set(members.map(\.id)).count == members.count,
              Set(members.map(\.token)).count == members.count else { return false }
        return shares.allSatisfy { share in
            SessionID(uuidString: share.sessionID) != nil
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
