import Foundation

/// The externally reachable doors that may publish Threading's dedicated loopback server.
///
/// Both transports terminate at the same authenticated HTTP/WebSocket surface. Choosing a
/// transport never changes what a remote principal may do; it changes only who can route packets
/// to the listener.
enum RemoteTransportKind: String, CaseIterable, Sendable {
    case relay
    case tailscale
}

enum RemoteTransportState: Equatable, Sendable {
    case stopped
    case starting
    case connected(URL)
    case unavailable(String)
}

@MainActor
protocol RemoteAccessTransport: AnyObject {
    func start(
        port: UInt16,
        onStateChange: @escaping @MainActor @Sendable (RemoteTransportState) -> Void
    )
    func stop()
}

/// How the user wants another device to reach the one remote-access listener.
///
/// Relay remains the compatibility default. `tailscaleAndRelay` deliberately opts into both:
/// owner pairing prefers the private tailnet while one-chat invitations use the relay, so a
/// collaborator does not have to join the owner's network.
enum RemoteAccessConnectionMode: String, CaseIterable, Sendable {
    case relay
    case tailscale
    case tailscaleAndRelay

    var usesRelay: Bool { self != .tailscale }
    var usesTailscale: Bool { self != .relay }

    var settingsTitle: String {
        switch self {
        case .relay: return L10n.string("Relay")
        case .tailscale: return L10n.string("Tailscale")
        case .tailscaleAndRelay: return L10n.string("Both")
        }
    }
}
