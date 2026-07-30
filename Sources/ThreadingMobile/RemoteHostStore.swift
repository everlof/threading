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

    var displayAddress: String {
        link.baseURL.host ?? link.baseURL.absoluteString
    }

    var isOwnerDevice: Bool { scope == nil || scope == "all" }

    var menuTitle: String {
        isOwnerDevice ? name : MobileL10n.string("%@ · Shared chat", name)
    }
}

/// Capability links are credentials, so paired Macs live in Keychain rather than UserDefaults.
final class RemoteHostStore {
    private let service = "codes.threading.mobile.remote-hosts"
    private let account = "paired-hosts-v1"

    func load() -> [PairedRemoteHost] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return []
        }
        return (try? JSONDecoder().decode([PairedRemoteHost].self, from: data)) ?? []
    }

    func save(_ hosts: [PairedRemoteHost]) {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
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
        guard status == errSecItemNotFound else { return }
        var add = match
        attributes.forEach { add[$0.key] = $0.value }
        SecItemAdd(add as CFDictionary, nil)
    }
}
