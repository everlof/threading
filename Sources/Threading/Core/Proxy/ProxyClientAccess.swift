import Foundation

enum ProxyClientLimits {
    static let pendingPerCapture = 8
    static let pendingAcrossCaptures = 32
    static let savedGrants = 32
    static let savedGrantBytes = 160_000
    static let pollMilliseconds = 500
}

struct ProxyClientRequest: Equatable, Sendable {
    let generation: String
    let id: String
    let address: String
}

struct ProxyClientSnapshot: Sendable {
    let revision: UInt64
    let requests: [ProxyClientRequest]
}

enum ProxyClientDecision: Sendable {
    case deny, once, capture, always

    var wireValue: String {
        switch self {
        case .deny: "deny"
        case .once: "once"
        case .capture, .always: "session"
        }
    }
}

/// IP grants are routing hints, never device identity. Limit them to the exact listener,
/// source and TLS host scope the person saw. File/preferences work stays off the main actor.
actor ProxyClientGrantStore {
    static let shared = ProxyClientGrantStore()
    private let suiteName: String?
    private let key = "proxyClientIPGrants.v1"
    private var revision: UInt64 = 0
    private struct Grant: Codable, Equatable {
        let listener: String
        let client: String
        let hosts: [String]
    }

    init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? PreferenceStore.shared
    }

    private func read() -> [Grant] {
        guard let bytes = defaults.data(forKey: key), bytes.count <= ProxyClientLimits.savedGrantBytes,
              let grants = try? JSONDecoder().decode([Grant].self, from: bytes), grants.count <= ProxyClientLimits.savedGrants else { return [] }
        return grants
    }

    func contains(address: String, scope: ProxyLaunchScope) -> Bool {
        lookup(address: address, scope: scope).remembered
    }

    func lookup(address: String, scope: ProxyLaunchScope) -> (remembered: Bool, revision: UInt64) {
        (read().contains(Grant(listener: scope.listenAddress, client: address, hosts: scope.hosts)), revision)
    }

    func remember(address: String, scope: ProxyLaunchScope, revision expectedRevision: UInt64) {
        guard revision == expectedRevision else { return }
        let grant = Grant(listener: scope.listenAddress, client: address, hosts: scope.hosts)
        var grants = read().filter { $0 != grant }
        grants.append(grant)
        grants = Array(grants.suffix(ProxyClientLimits.savedGrants))
        if let bytes = try? JSONEncoder().encode(grants) { defaults.set(bytes, forKey: key) }
    }

    func removeAll() {
        revision += 1
        defaults.removeObject(forKey: key)
    }
}
