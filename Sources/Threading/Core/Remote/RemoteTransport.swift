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

/// Why the relay is not carrying traffic, as a content-free code.
///
/// `RemoteTransportState.unavailable` carries the sentence a person reads, which is localised and
/// occasionally parameterised; it cannot also be the token a diagnostic report groups by. This
/// enum is the same split `TailscaleReadinessIssue` already makes, and it exists because the one
/// failure that produced no evidence at all was the relay launching and then never publishing an
/// address: the journal recorded `relayFailed reason=unavailable` for every cause alike, so
/// "cloudflared is not installed" and "cloudflared started and went quiet" read identically.
enum RemoteRelayFailure: String, Equatable, Sendable {
    case notInstalled
    case launchFailed
    case startupTimedOut
    case exitedDuringStartup
    case exitedAfterConnecting

    /// The `reason` token the diagnostics journal groups by, matching the vocabulary
    /// `RemoteAccessCoordinator` already infers for transports that report no code.
    var diagnosticReason: String {
        switch self {
        case .notInstalled, .launchFailed:
            return "unavailable"
        case .startupTimedOut:
            return "timeout"
        case .exitedDuringStartup, .exitedAfterConnecting:
            return "process-exited"
        }
    }
}

/// A typed explanation of how far Tailscale setup reached. The ordinary transport state remains
/// shared with Relay; this finer state powers actionable setup UI and content-free diagnostics.
enum TailscaleReadiness: Equatable, Sendable {
    case notChecked
    case checking
    case publishing
    case ready(URL)
    /// `actionURL`, when present, is the tailnet approval page the CLI asked the user to visit —
    /// the one actionable thing in an otherwise dead-ended setup. It rides beside the issue
    /// rather than inside it so the issue keeps its `String` raw value, which is the
    /// content-free code the diagnostics report.
    case actionRequired(TailscaleReadinessIssue, actionURL: URL?)
}

enum TailscaleReadinessIssue: String, Equatable, Sendable {
    case notInstalled
    case signedOut
    case stopped
    case serveNotEnabled
    case httpsRequired
    case permissionDenied
    case statusUnavailable
    case portInUse
    case serveFailed

    var message: String {
        switch self {
        case .notInstalled:
            return L10n.string("Install Tailscale on this Mac to use private access.")
        case .signedOut:
            return L10n.string("Sign in to Tailscale on this Mac, then retry.")
        case .stopped:
            return L10n.string("Turn on Tailscale on this Mac, then retry.")
        case .serveNotEnabled:
            return L10n.string("Enable Tailscale Serve for this tailnet, then retry.")
        case .httpsRequired:
            return L10n.string("Enable Tailscale HTTPS for this tailnet, then retry.")
        case .permissionDenied:
            return L10n.string("Tailscale did not allow Threading to publish this private service.")
        case .statusUnavailable:
            return L10n.string("Threading could not read Tailscale’s status.")
        case .portInUse:
            return L10n.string(
                "Tailscale HTTPS port 8443 is already configured. Remove that Serve handler, then retry."
            )
        case .serveFailed:
            return L10n.string("Tailscale Serve could not publish Threading on this tailnet.")
        }
    }
}

@MainActor
protocol RemoteAccessTransport: AnyObject {
    func start(
        port: UInt16,
        onStateChange: @escaping @MainActor @Sendable (RemoteTransportState) -> Void
    )
    func stop()
}

/// The public relay door, as the coordinator uses it.
///
/// `lastFailure` is on the protocol rather than only on `RemoteTunnel` because the coordinator
/// reads it when a transport reports itself unavailable, and a substitute that could not answer
/// would silently downgrade that diagnostic to a guess made from a localized sentence.
@MainActor
protocol RemoteRelayTransport: RemoteAccessTransport {
    var lastFailure: RemoteRelayFailure? { get }
}

/// The tailnet door, as the coordinator uses it. Readiness advances while the state sits on
/// `.starting`, so the settings page needs both the value and the change notification.
@MainActor
protocol RemoteTailnetTransport: RemoteAccessTransport {
    var readiness: TailscaleReadiness { get }
    var onReadinessChange: (@MainActor () -> Void)? { get set }
}

/// A door this process refuses to open.
///
/// The unit test bundle is hosted inside the app, so anything that reaches
/// `RemoteAccessCoordinator.shared` gets the real composition root. Left alone, a test that
/// enabled remote access would launch this developer's `cloudflared` and `tailscale`, publish
/// their Mac, and leave the children behind: two such orphans were alive on this machine when
/// the transport plan was written. Refusing at the factory is narrower than refusing at every
/// call site, and it reports a terminal state rather than sitting in `.starting` forever.
@MainActor
final class RefusedRemoteTransport: RemoteRelayTransport, RemoteTailnetTransport {
    let lastFailure: RemoteRelayFailure? = nil
    let readiness: TailscaleReadiness = .notChecked
    var onReadinessChange: (@MainActor () -> Void)?

    func start(
        port: UInt16,
        onStateChange: @escaping @MainActor @Sendable (RemoteTransportState) -> Void
    ) {
        ThreadingLogger.remote.notice(
            "Remote transport refused because this process is a test host"
        )
        onStateChange(.stopped)
    }

    func stop() {}
}

/// How the user wants another device to reach the one remote-access listener.
///
/// Relay remains the compatibility default. `tailscaleAndRelay` keeps owner pairing on the
/// private tailnet and starts the public relay lazily for one-chat invitations. Separate settings
/// may opt owner devices into relay fallback or keep that relay ready.
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
        case .tailscaleAndRelay: return L10n.string("Private + Sharing")
        }
    }
}
