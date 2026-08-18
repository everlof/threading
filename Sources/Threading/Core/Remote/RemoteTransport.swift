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

    /// What the page may truthfully say while this door is still coming up, or `nil` when the
    /// readiness is not a step on the way to one.
    ///
    /// The vocabulary is bounded by what the transport actually observes, which is narrow: it
    /// has a `tailscale status` command running, or it has asked `tailscale serve` to publish
    /// and has not been answered yet. Nothing here probes the tailnet HTTPS endpoint, so the
    /// page must not claim to be waiting on a certificate specifically — it names what it is
    /// waiting for and how long that normally takes. The state changes when the command's
    /// stage changes and at no other time, so nothing here is a timer dressed as progress.
    var startupStatement: TailscaleStartupStatement? {
        switch self {
        case .notChecked, .ready, .actionRequired:
            return nil
        case .checking:
            return TailscaleStartupStatement(
                title: L10n.string("Checking Tailscale"),
                detail: L10n.string("Reading this Mac’s Tailscale status.")
            )
        case .publishing:
            return TailscaleStartupStatement(
                title: L10n.string("Publishing on your tailnet"),
                detail: L10n.string(
                    "Waiting for the tailnet HTTPS endpoint to answer. The first time can take "
                        + "up to a minute."
                )
            )
        }
    }
}

/// One in-progress fact, in the two lines every status surface on the page is built from.
struct TailscaleStartupStatement: Equatable, Sendable {
    let title: String
    let detail: String
}

/// Which readiness row an issue lands on.
///
/// The page draws the rows above the failing one as met and the rows below it as waiting, so
/// adding an issue cannot leave it landing nowhere — the previous `switch` repeated all three
/// rows per case and was where a new issue silently got no mark at all.
enum TailscaleReadinessStep: Int, CaseIterable, Equatable, Sendable {
    case installed
    case signedIn
    case privateEndpoint
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

    /// The readiness row this issue belongs to. Everything above it is met; everything below it
    /// is still waiting.
    var step: TailscaleReadinessStep {
        switch self {
        case .notInstalled:
            return .installed
        case .signedOut, .stopped, .statusUnavailable:
            return .signedIn
        case .serveNotEnabled, .httpsRequired, .permissionDenied, .portInUse, .serveFailed:
            return .privateEndpoint
        }
    }

    /// What the readiness row says. The row is already titled with the step it belongs to, so
    /// it only has to say what to do about it.
    var rowDetail: String {
        switch self {
        case .notInstalled:
            return L10n.string("Install Tailscale on this Mac, then retry.")
        case .signedOut:
            return L10n.string("Sign in to Tailscale on this Mac, then retry.")
        case .stopped:
            return L10n.string("Turn on Tailscale on this Mac, then retry.")
        case .statusUnavailable:
            return L10n.string("Threading could not read Tailscale’s status.")
        case .serveNotEnabled:
            return L10n.string("Enable Tailscale Serve for this tailnet, then retry.")
        case .httpsRequired:
            return L10n.string("Enable Tailscale HTTPS for this tailnet, then retry.")
        case .permissionDenied:
            return L10n.string("Allow Threading to publish this private service, then retry.")
        case .portInUse:
            return L10n.string(
                "HTTPS port 8443 already has a Tailscale Serve handler. Remove it, then retry."
            )
        case .serveFailed:
            return L10n.string("Tailscale Serve could not publish Threading. Retry the connection.")
        }
    }

    /// What failed, stated as a fact.
    ///
    /// A readiness row can be terse because the row it sits on already names the step. The
    /// unavailable panel names nothing, so it states the fact first and the remedy after it —
    /// see `explanation`. Both halves live here so a reason can never exist in a row and be
    /// missing from the panel, which is exactly how "Private connection unavailable" shipped
    /// with its only explanation three rows further up the page.
    var failureStatement: String {
        switch self {
        case .notInstalled:
            return L10n.string("Tailscale is not installed on this Mac.")
        case .signedOut:
            return L10n.string("This Mac is not signed in to Tailscale.")
        case .stopped:
            return L10n.string("Tailscale is not running on this Mac.")
        case .statusUnavailable:
            return L10n.string("Threading could not read Tailscale’s status.")
        case .serveNotEnabled:
            return L10n.string("Tailscale Serve is not enabled for this tailnet.")
        case .httpsRequired:
            return L10n.string("HTTPS certificates are not enabled for this tailnet.")
        case .permissionDenied:
            return L10n.string("Tailscale did not allow Threading to publish this private service.")
        case .portInUse:
            return L10n.string("HTTPS port 8443 already has a Tailscale Serve handler.")
        case .serveFailed:
            return L10n.string("Tailscale Serve could not publish Threading on this tailnet.")
        }
    }

    /// What the person does about it.
    var remedyStatement: String {
        switch self {
        case .notInstalled:
            return L10n.string("Install Tailscale on this Mac, then retry.")
        case .signedOut:
            return L10n.string("Sign in to Tailscale on this Mac, then retry.")
        case .stopped:
            return L10n.string("Turn on Tailscale on this Mac, then retry.")
        case .statusUnavailable:
            return L10n.string("Check that Tailscale is running on this Mac, then retry.")
        case .serveNotEnabled, .httpsRequired:
            return L10n.string(
                "Enable HTTPS certificates in the Tailscale admin console, then retry."
            )
        case .permissionDenied:
            return L10n.string("Approve this Mac in the Tailscale admin console, then retry.")
        case .portInUse:
            return L10n.string("Remove that handler, then retry.")
        case .serveFailed:
            return L10n.string("Retry the connection.")
        }
    }

    /// The failure and its remedy as the one paragraph a panel carries.
    var explanation: String {
        failureStatement + " " + remedyStatement
    }

    /// The button that opens the page this issue is fixed on, when the CLI offered one. `nil`
    /// where there is nothing to open, so the panel shows Retry alone rather than a button that
    /// goes nowhere.
    var remedyActionTitle: String? {
        switch self {
        case .serveNotEnabled:
            return L10n.string("Enable Tailscale Serve…")
        case .httpsRequired:
            return L10n.string("Enable HTTPS…")
        case .notInstalled, .signedOut, .stopped, .statusUnavailable,
             .permissionDenied, .portInUse, .serveFailed:
            return nil
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
