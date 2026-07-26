import Foundation

/// The origin an agent is asking Skalman's authenticated browser to expose.
struct BrowserOrigin: Hashable, Equatable {
    let scheme: String
    let host: String
    let port: Int?

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "about" {
            self.scheme = scheme
            host = ""
            port = nil
            return
        }
        guard ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        port = url.port
    }

    var key: String {
        guard !host.isEmpty else { return "\(scheme):" }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    var displayName: String {
        guard !host.isEmpty else { return "this blank page" }
        return host + (port.map { ":\($0)" } ?? "")
    }

    var isLocal: Bool {
        host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "::1"
            || host.hasPrefix("127.")
    }
}

enum BrowserAccessDecision {
    case allowOnce
    case allowPersistently
    case deny
}

/// Test and embedding seam for presenting an origin decision without coupling the policy to a
/// particular window. Production leaves this nil and uses the native alert owned by the
/// coordinator.
typealias BrowserAccessDecisionProvider = (
    _ origin: BrowserOrigin,
    _ purpose: String,
    _ decide: @escaping (BrowserAccessDecision) -> Void
) -> Void

/// Separate from an origin grant because clearing site data is destructive. A persistent
/// "always allow this host" choice must never silently authorize deleting its signed-in state.
typealias BrowserSiteDataDecisionProvider = (
    _ origin: BrowserOrigin,
    _ context: BrowserContextKind,
    _ decide: @escaping (Bool) -> Void
) -> Void

/// Persistent "always allow" choices. Per-session "allow once" choices deliberately live in the
/// coordinator so they vanish with the running app and never become an invisible long-term grant.
@MainActor
final class BrowserAccessStore {
    private enum Keys {
        static let allowedOrigins = "browser.allowedOrigins"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isPersistentlyAllowed(_ origin: BrowserOrigin) -> Bool {
        allowedOrigins.contains(origin.key)
    }

    func allowPersistently(_ origin: BrowserOrigin) {
        var origins = allowedOrigins
        origins.insert(origin.key)
        defaults.set(Array(origins).sorted(), forKey: Keys.allowedOrigins)
    }

    func revoke(_ origin: BrowserOrigin) {
        revoke(key: origin.key)
    }

    func revoke(key: String) {
        var origins = allowedOrigins
        origins.remove(key)
        defaults.set(Array(origins).sorted(), forKey: Keys.allowedOrigins)
    }

    func revokeAll() {
        defaults.removeObject(forKey: Keys.allowedOrigins)
    }

    var allowedOrigins: Set<String> {
        Set(defaults.stringArray(forKey: Keys.allowedOrigins) ?? [])
    }
}
