import Foundation

enum RemoteTransportState: Equatable, Sendable {
    case stopped
    case starting
    case connected(URL)
    case unavailable(String)
}

/// What `tailscale status` says about this Mac's own tailnet membership.
///
/// The tailnet door is a listener on the address this Mac holds on its tailnet, so the *door* is
/// answered by the listener alone: an address is there, or it is not. These are the facts the
/// interface list cannot supply — whether the absence is a CLI that was never installed, a Mac
/// that is signed out, a `tailscaled` that is not running, and what this Mac is called on the
/// tailnet so the door can advertise that name beside its numeric address.
///
/// `.unknown` is a real answer and stays one. The probe is a child process that can fail, and a
/// door that is bound proves the tailnet is up whatever the CLI managed to say.
struct TailscaleHostFacts: Equatable, Sendable {

    enum State: String, Equatable, Sendable {
        /// No `tailscale` executable was found, or the probe has not run yet.
        case unknown
        case notInstalled
        case signedOut
        case stopped
        case running
    }

    let state: State
    /// This Mac's MagicDNS name (`mac.tail1234.ts.net`), without the trailing root label.
    let magicDNSName: String?

    static let unknown = TailscaleHostFacts(state: .unknown, magicDNSName: nil)

    /// The readiness issue these facts amount to, or nil when nothing is wrong with them.
    ///
    /// `.unknown` is deliberately not an issue: a probe that could not answer is not a statement
    /// that the tailnet is down, and the door's own state says whether anything is bound.
    var issue: TailscaleReadinessIssue? {
        switch state {
        case .notInstalled: return .notInstalled
        case .signedOut: return .signedOut
        case .stopped: return .stopped
        case .unknown, .running: return nil
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
///
/// The third row is the tailnet **address** rather than a Serve endpoint. The door is a listener
/// on the address this Mac holds on its tailnet, so what the row reports is what the listener
/// bound. Serve's own failures are not rows here at all: they belong to the browser sub-option
/// that asks for them, which is why `TailscaleReadinessIssue.step` answers nil for those.
enum TailscaleReadinessStep: Int, CaseIterable, Equatable, Sendable {
    case installed
    case signedIn
    case tailnetAddress

    /// The stable component an accessibility identifier is built from. Not copy: never
    /// localized, never shown.
    var identifierComponent: String {
        switch self {
        case .installed: return "installed"
        case .signedIn: return "signed-in"
        case .tailnetAddress: return "tailnet-address"
        }
    }
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

    /// The sentence the transport reports as `RemoteTransportState.unavailable`, which is what
    /// a *remote* caller is told. The settings page reads `failureStatement` and
    /// `remedyStatement` instead, because a status line states the fact first and the remedy
    /// after it, and a row can be terse because it is already titled.
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

    /// The readiness row this issue belongs to, or nil when it belongs to no row.
    ///
    /// Everything above the failing row is met; everything below it is still waiting. The five
    /// Serve issues answer nil because the readiness card is about the *door*, and the door does
    /// not go through Serve any more: those failures are shown on the browser sub-option that
    /// asked for Serve, beside the switch that turns it off again.
    var step: TailscaleReadinessStep? {
        switch self {
        case .notInstalled:
            return .installed
        case .signedOut, .stopped, .statusUnavailable:
            return .signedIn
        case .serveNotEnabled, .httpsRequired, .permissionDenied, .portInUse, .serveFailed:
            return nil
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

/// The `tailscale` CLI, as the coordinator uses it.
///
/// **`start` and `stop` are Tailscale Serve, not the tailnet door.** The door is a listener on
/// this Mac's tailnet address (`RemoteTailscaleDoorImplementation.listenerDoor`); what this starts
/// is the opt-in browser convenience that publishes the same server at the `*.ts.net` name with a
/// publicly trusted certificate, so a browser on the tailnet meets no interstitial.
///
/// `hostFacts` is the other half and is not about Serve at all: it is what `tailscale status` said
/// about this Mac, which is the only way to tell "not installed" from "signed out" from "not
/// running", and where the MagicDNS name the door advertises comes from.
///
/// Readiness advances while the state sits on `.starting`, so the settings page needs both the
/// value and the change notification.
@MainActor
protocol RemoteTailnetTransport: RemoteAccessTransport {
    var readiness: TailscaleReadiness { get }
    var hostFacts: TailscaleHostFacts { get }
    var onReadinessChange: (@MainActor () -> Void)? { get set }
    /// Reads `tailscale status` once, bounded and off the main actor, and publishes `hostFacts`.
    func refreshHostFacts()
}

/// A door this process refuses to open.
///
/// The unit test bundle is hosted inside the app, so anything that reaches
/// `RemoteAccessCoordinator.shared` gets the real composition root. Left alone, a test that
/// enabled remote access would run this developer's `tailscale` and publish their Mac, leaving
/// the child behind: orphans of exactly that shape were alive on this machine when the transport
/// plan was written. Refusing at the factory is narrower than refusing at every call site, and it
/// reports a terminal state rather than sitting in `.starting` forever.
@MainActor
final class RefusedRemoteTransport: RemoteTailnetTransport {
    let readiness: TailscaleReadiness = .notChecked
    /// A refused process reads nothing, so the facts stay unknown rather than becoming a claim
    /// about the developer's own machine.
    let hostFacts: TailscaleHostFacts = .unknown
    var onReadinessChange: (@MainActor () -> Void)?

    func refreshHostFacts() {}

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

/// What the `tailscale` door is made of.
///
/// The door is a switch on the settings page; this is the seam behind it. It used to run
/// `tailscale serve`, which published the loopback listener at the tailnet's HTTPS port and left
/// the phone trusting a certificate this Mac did not hold. §8 of the transport plan replaced that
/// with a listener bound to this Mac's own tailnet address, presenting the same pinned identity
/// as every other routable door, which is what makes the phone's trust one code path everywhere.
/// Serve stayed as the browser convenience (`remoteAccessTailscaleServeEnabled`), off by default.
///
/// The seam remains because it is what let that swap be one constant rather than a settings
/// rewrite: nothing above the coordinator knows which of the two is carrying the door.
enum RemoteTailscaleDoorImplementation: Equatable, Sendable {
    /// `tailscale serve --https=8443` proxying to the loopback listener.
    case serveTransport
    /// An `NWListener` on this Mac's tailnet address, with the pinned identity.
    case listenerDoor

    /// What this build does.
    static let current: RemoteTailscaleDoorImplementation = .listenerDoor
}
