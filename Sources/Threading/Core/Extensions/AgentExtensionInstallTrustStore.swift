import Foundation

struct AgentExtensionInstallTrustDidChange: AppEvent {
    static let name = Notification.Name("agentExtensionInstallTrustDidChange")
}

/// An explicit user grant to one authenticated chat, never to a provider, project or child chat.
/// Defaults stores property-list values; package inspection and copying remain on their workers.
@MainActor
final class AgentExtensionInstallTrustStore {
    static let shared = AgentExtensionInstallTrustStore()
    static let maximumNameLength = 160
    private static let key = "agentExtensionInstallTrust.v1"

    struct Grant: Equatable {
        let sessionID: SessionID
        let name: String
    }

    private let defaults: UserDefaults
    private var names: [String: String]

    init(defaults: UserDefaults = PreferenceStore.shared) {
        self.defaults = defaults
        names = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func allows(_ sessionID: SessionID) -> Bool {
        names[sessionID.uuidString] != nil
    }

    var grants: [Grant] {
        names.compactMap { key, name in
            SessionID(uuidString: key).map { Grant(sessionID: $0, name: name) }
        }.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    func allow(_ sessionID: SessionID, name: String) {
        names[sessionID.uuidString] = String(name.prefix(Self.maximumNameLength))
        persist()
    }

    func revoke(_ sessionID: SessionID) {
        guard names.removeValue(forKey: sessionID.uuidString) != nil else { return }
        persist()
    }

    private func persist() {
        defaults.set(names, forKey: Self.key)
        NotificationCenter.default.post(AgentExtensionInstallTrustDidChange())
    }
}
