import Foundation
import Security
import ThreadingRemoteKit

struct PairedRemoteHost: Codable, Hashable, Identifiable {
    let id: String
    /// Stable Mac identity, separate from `id` because one Mac may have an owner pairing and
    /// several one-chat guest capabilities without either overwriting another in Keychain.
    var hostID: String?
    var shareID: String?
    var scope: String?
    var name: String
    var link: RemoteConnectionLink
    var lastConnectedAt: Date
    /// Owner hosts can advertise more than one route without duplicating the Mac in the device
    /// picker. Optional fields keep Keychain records written by older versions decodable.
    var endpoints: [RemoteHostEndpointDTO]? = nil
    var connectionPolicy: RemoteHostConnectionPolicy? = nil
    var activeEndpointKind: String? = nil

    var displayAddress: String {
        link.baseURL.host ?? link.baseURL.absoluteString
    }

    var isOwnerDevice: Bool { scope == nil || scope == "all" }

    var candidateLinks: [RemoteConnectionLink] {
        // `nil` is a legacy record from before hosts advertised routes. An explicitly empty
        // list is different: the Mac currently authorizes no endpoint under its policy, so
        // falling back to a remembered relay here would violate private-only.
        guard let endpoints else { return [link] }
        guard !endpoints.isEmpty else { return [] }
        return RemoteHostEndpointSelection.ordered(
            endpoints,
            policy: connectionPolicy ?? .privateOnly,
            currentBaseURL: link.baseURL
        ).compactMap { RemoteConnectionLink(baseURL: $0.baseURL, token: link.token) }
    }

    var connectionLabel: String {
        switch activeEndpointKind ?? Self.endpointKind(for: link.baseURL) {
        case "tailscale": return MobileL10n.string("Tailscale")
        case "relay": return MobileL10n.string("Relay")
        default: return MobileL10n.string("Direct")
        }
    }

    var menuTitle: String {
        isOwnerDevice ? name : MobileL10n.string("%@ · Shared chat", name)
    }

    mutating func merge(identity: RemoteHostDTO?, successfulLink: RemoteConnectionLink) {
        link = successfulLink
        activeEndpointKind = Self.endpointKind(for: successfulLink.baseURL)
        lastConnectedAt = Date()
        guard let identity else { return }
        hostID = identity.id
        name = identity.name
        if let advertised = identity.endpoints {
            endpoints = advertised
        }
        if let policy = identity.connectionPolicy {
            connectionPolicy = policy
        }
    }

    static func endpointKind(for baseURL: URL) -> String {
        guard let host = baseURL.host?.lowercased() else { return "direct" }
        return host.hasSuffix(".ts.net") ? "tailscale" : "relay"
    }
}

/// Capability links are credentials, so paired Macs live in Keychain rather than UserDefaults.
final class RemoteHostStore {
    private let service = "codes.threading.mobile.remote-hosts"
    private let account = "paired-hosts-v1"

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case unreadable
        case encoding

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "Paired Macs could not be saved securely (Keychain \(status))."
            case .unreadable:
                return "Saved paired-Mac credentials could not be read."
            case .encoding:
                return "Paired-Mac credentials could not be encoded."
            }
        }
    }

    private(set) var writesAllowed = true

    func load() -> Result<[PairedRemoteHost], StoreError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .success([]) }
        guard status == errSecSuccess, let data = result as? Data else {
            MobileDiagnostics.logFailure(
                .hostStorage,
                domain: .keychain,
                code: Int(status)
            )
            writesAllowed = false
            return .failure(.keychain(status))
        }
        do {
            return .success(try JSONDecoder().decode([PairedRemoteHost].self, from: data))
        } catch {
            MobileDiagnostics.logFailure(.hostStorage, error: error)
            // Keychain is already the protected recovery copy. Refuse future writes so an
            // ordinary pairing cannot replace bytes a newer/older build may still understand.
            writesAllowed = false
            return .failure(.unreadable)
        }
    }

    func save(_ hosts: [PairedRemoteHost]) throws {
        guard writesAllowed else {
            MobileDiagnostics.logFailure(.hostStorage, code: .writeVerification)
            throw StoreError.unreadable
        }
        guard let data = try? JSONEncoder().encode(hosts) else {
            MobileDiagnostics.logFailure(.hostStorage, code: .encode)
            throw StoreError.encoding
        }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // The bearer grants interactive access to agent sessions and the app only needs it
            // while the user is actively using the unlocked device.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            MobileDiagnostics.logFailure(
                .hostStorage,
                domain: .keychain,
                code: Int(status)
            )
            throw StoreError.keychain(status)
        }
        var add = match
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            MobileDiagnostics.logFailure(
                .hostStorage,
                domain: .keychain,
                code: Int(addStatus)
            )
            throw StoreError.keychain(addStatus)
        }
    }
}
