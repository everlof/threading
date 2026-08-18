import Foundation

/// What the Remote Access page's status row says once the listener is up.
///
/// It is a value rather than three `updateConnection(...)` calls inside a view controller
/// because the row and the pairing panel have to agree: the panel now carries the reason a door
/// is unavailable, and the row carries the same one. Deciding both from the same inputs is what
/// keeps a fact from existing in one place on the page and not the other, and it lets the states
/// that need a live tailnet to reach be rendered and asserted here.
struct RemoteConnectionStatusPresentation: Equatable {

    /// The mark beside the row. A colour is a `Design` role, which this layer does not read.
    enum Tone: Equatable {
        case ready
        case attention
        case working
    }

    let title: String
    let detail: String
    let tone: Tone
    let isBusy: Bool

    static func resolve(
        mode: RemoteAccessConnectionMode,
        relay: RemoteTransportState,
        tailscale: RemoteTransportState,
        tailscaleReadiness: TailscaleReadiness,
        allowsOwnerRelayFallback: Bool,
        localPort: UInt16
    ) -> RemoteConnectionStatusPresentation {
        if mode == .tailscaleAndRelay,
           case .connected = relay,
           case .connected = tailscale {
            return RemoteConnectionStatusPresentation(
                title: L10n.string("Ready"),
                detail: L10n.string(
                    "Private Tailscale pairing and public share links are both ready."
                ),
                tone: .ready,
                isBusy: false
            )
        }

        if mode == .tailscaleAndRelay,
           allowsOwnerRelayFallback,
           case .connected = relay,
           case .unavailable(let reason) = tailscale {
            return RemoteConnectionStatusPresentation(
                title: L10n.string("Relay fallback ready"),
                detail: L10n.format(
                    "Paired devices can connect through Relay. Tailscale pairing: %@",
                    tailscaleReason(reason, readiness: tailscaleReadiness)
                ),
                tone: .attention,
                isBusy: false
            )
        }

        let pairingState = mode == .relay ? relay : tailscale
        switch pairingState {
        case .connected(let origin):
            return RemoteConnectionStatusPresentation(
                title: L10n.string("Ready"),
                detail: connectedDetail(mode: mode, relay: relay, origin: origin),
                tone: .ready,
                isBusy: false
            )

        case .stopped, .starting:
            // A door that is coming up says what it is waiting for. The local mirror's address
            // follows the wait rather than leading it: the person is looking at this row because
            // nothing has happened yet, not to read a port back.
            if mode != .relay, let statement = tailscaleReadiness.startupStatement {
                return RemoteConnectionStatusPresentation(
                    title: statement.title,
                    detail: L10n.format(
                        "%1$@ The local mirror is ready on 127.0.0.1:%2$@.",
                        statement.detail,
                        String(localPort)
                    ),
                    tone: .working,
                    isBusy: true
                )
            }
            return RemoteConnectionStatusPresentation(
                title: L10n.string("Connecting securely"),
                // The port is an address, not a quantity: formatted through the locale it
                // grew a grouping separator ("127.0.0.1:53,651"), so it crosses as a string.
                detail: L10n.format(
                    "The local mirror is ready on 127.0.0.1:%@. Waiting for %@…",
                    String(localPort),
                    mode == .relay ? L10n.string("the relay") : L10n.string("Tailscale")
                ),
                tone: .working,
                isBusy: true
            )

        case .unavailable(let reason):
            return RemoteConnectionStatusPresentation(
                title: L10n.string("Local access only"),
                detail: mode == .relay
                    ? reason
                    : tailscaleReason(reason, readiness: tailscaleReadiness),
                tone: .attention,
                isBusy: false
            )
        }
    }

    /// The tailnet's own explanation when the readiness model has one, and the transport's
    /// sentence otherwise. The transport's sentence is the readiness row's copy, which reads as
    /// an instruction with no subject once it is lifted out of the row.
    private static func tailscaleReason(
        _ reason: String,
        readiness: TailscaleReadiness
    ) -> String {
        guard case .actionRequired(let issue, _) = readiness else { return reason }
        return issue.explanation
    }

    private static func connectedDetail(
        mode: RemoteAccessConnectionMode,
        relay: RemoteTransportState,
        origin: URL
    ) -> String {
        switch mode {
        case .tailscaleAndRelay:
            switch relay {
            case .connected:
                return L10n.string("Tailscale pairing and share links are ready.")
            case .unavailable(let reason):
                return L10n.format("Private pairing is ready. Sharing relay: %@", reason)
            case .starting:
                return L10n.string("Private pairing is ready; the sharing relay is connecting…")
            case .stopped:
                return L10n.string(
                    "Private pairing is ready. The public relay starts when you share."
                )
            }
        case .tailscale:
            return L10n.format(
                "Available privately through %@.",
                origin.host ?? L10n.string("your tailnet")
            )
        case .relay:
            return L10n.format(
                "Connected through %@.",
                origin.host ?? L10n.string("the secure relay")
            )
        }
    }
}
