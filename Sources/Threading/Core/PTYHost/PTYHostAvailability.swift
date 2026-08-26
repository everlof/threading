import Foundation
import ThreadingPTYHostKit

// MARK: - Unavailability

/// Why this launch is not using the background PTY host.
///
/// Every case degrades to the same behaviour — today's in-process `forkpty`, unchanged — so the
/// distinction is never a branch in feature code. It exists because "the daemon is off", "the
/// daemon is not installed", "the daemon is not running" and "the daemon is the wrong one" are
/// four different things to *say*, in a journal and in the Advanced settings page, and collapsing
/// them into a `Bool` is how a feature that quietly stopped working becomes unexplainable.
///
/// Structural tokens rather than sentences, for the reason
/// [`reliability-and-type-safety.md`](../../../../docs/architecture/reliability-and-type-safety.md)
/// gives: a journal groups by cause, and a cause spelled as prose can only be grepped.
enum PTYHostUnavailability: Equatable, Sendable {

    /// `AppSettings.ptyHostEnabled` is off. Decided first and without touching the filesystem:
    /// while the feature is off — which is every launch until R1 is answered on a SIP-enabled
    /// Mac — this costs nothing at all, which is what makes it safe to ask on a session launch.
    case disabled

    /// The rendezvous path is longer than `sockaddr_un.sun_path` can carry. A home directory
    /// long enough to hit this must cost the daemon and nothing else.
    case socketPathTooLong(bytes: Int)

    /// No `Contents/Helpers/threading-ptyd` in the bundle. True of every build until the daemon
    /// target lands, and true afterwards of any build whose copy phase did not run — which is
    /// worth distinguishing from `notRunning`, because one is a broken build and the other is an
    /// ordinary Tuesday.
    case helperMissing

    /// Nothing is listening at the rendezvous: no socket file, or a connect the kernel refused
    /// because the daemon that left the file behind is gone.
    case notRunning

    /// Registration or daemon replacement is in progress. Existing hosted sessions may reattach,
    /// but new sessions stay in-process so they cannot race into the daemon being drained.
    case registrationRefreshing

    /// A daemon answered and the protocol pair does not admit it. The app refuses to attach,
    /// refuses to spawn and never signals anything; a `peerTooOld` daemon has already been sent
    /// `retire` by the client, so `KeepAlive` will relaunch the new binary.
    case protocolMismatch(PTYHostCompatibility)

    /// launchd knows the label and the service is currently off — the user turned it off in
    /// System Settings ▸ Login Items, or the app unregistered it.
    ///
    /// **Set by registration, not by this probe.** `PTYHostAvailability.resolve` never produces
    /// it: it has no `SMAppService` and deliberately none, because a probe that asked launchd
    /// would be a launch-path call into a framework that can block. The registration slice maps
    /// `SMAppService.Status` onto this case and `notFound`, which is why the two are spelled out
    /// now — the distinction is P2's, and collapsing "seen, currently off" into "never seen"
    /// loses the only signal that says whether re-registering would help.
    case notRegistered

    /// launchd has never seen the label. Also **set by registration, not by this probe** — see
    /// `notRegistered`.
    case notFound

    /// launchd has the registration and is waiting for the user to allow it in System Settings ▸
    /// General ▸ Login Items.
    ///
    /// **Also set by registration, not by this probe**, and the one unavailability with an action
    /// attached to it: `PTYHostRegistration.openLoginItemsSettings()` takes the user to the row.
    /// Never observed on this machine — every measured registration from an ad-hoc Debug bundle
    /// went straight to `enabled` with the Background Task Management record already
    /// `[enabled, allowed, notified]` — but a managed Mac can require the approval, and a feature
    /// that silently does nothing because a switch is off somewhere else is exactly what the
    /// separate reasons exist to prevent.
    case requiresApproval

    /// The journal token. Public in a log line: a cause, never a path or a user's text.
    var token: String {
        switch self {
        case .disabled: return "disabled"
        case .socketPathTooLong: return "socketPathTooLong"
        case .helperMissing: return "helperMissing"
        case .notRunning: return "notRunning"
        case .registrationRefreshing: return "registrationRefreshing"
        case .protocolMismatch(let compatibility): return "protocolMismatch.\(compatibility.rawValue)"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        case .requiresApproval: return "requiresApproval"
        }
    }
}

// MARK: - Availability

/// Whether this launch may put a session's PTY in the background host, as one value.
///
/// One value rather than a scattering of checks because the *degrade* is the feature: §7 of the
/// draft asks that removing the daemon degrade to today's behaviour rather than to a broken app,
/// and that is structural only if there is a single place that answers the question and a single
/// answer that carries the reason with it. It is `Sendable` so the answer can be resolved off the
/// main actor — the probe connects to a socket — and applied on it.
enum PTYHostAvailability: Equatable, Sendable {

    /// A compatible daemon is listening here.
    case available(socketPath: String)

    /// It is not, and this is why.
    case unavailable(PTYHostUnavailability)

    var socketPath: String? {
        switch self {
        case .available(let socketPath): return socketPath
        case .unavailable: return nil
        }
    }

    var isAvailable: Bool { socketPath != nil }

    var unavailability: PTYHostUnavailability? {
        switch self {
        case .available: return nil
        case .unavailable(let reason): return reason
        }
    }
}

// MARK: - Probe

/// What one connect-and-`hello` round trip to the rendezvous found.
///
/// Three answers, not two: a daemon that refused the version gate is emphatically not "not
/// running", and treating it as such would have the app keep trying to attach to a host it has
/// already been told it cannot talk to.
enum PTYHostProbeOutcome: Equatable, Sendable {
    /// A daemon answered `hello` and `PTYHostProtocol.evaluate` admitted it.
    case ready
    /// Nothing is listening, or the connection could not be completed inside its deadline.
    case notRunning
    /// A daemon answered and the gate refused it.
    case mismatched(PTYHostCompatibility)
}

/// What a probe is asked.
struct PTYHostProbeRequest: Sendable {
    let socketPath: String
    /// This app's generation, for the daemon's journal and graceful replacement. It never gates
    /// admission.
    let build: String

    init(socketPath: String, build: String) {
        self.socketPath = socketPath
        self.build = build
    }
}

/// The one step of the decision that has to talk to another process.
///
/// Injectable, and separate from the rest on purpose. Everything else — the setting, the path
/// length, the helper's presence — is decided from values the caller already holds, so a test can
/// force each of those branches with no daemon, no socket and no filesystem; and the branch that
/// *does* need a peer is one closure, so a test can force that one too. Without the split, half
/// the degrade paths would only be reachable by arranging a real daemon to be absent in the
/// right way.
struct PTYHostProbe: Sendable {

    private let answer: @Sendable (PTYHostProbeRequest) -> PTYHostProbeOutcome

    init(_ answer: @escaping @Sendable (PTYHostProbeRequest) -> PTYHostProbeOutcome) {
        self.answer = answer
    }

    func outcome(for request: PTYHostProbeRequest) -> PTYHostProbeOutcome {
        answer(request)
    }

    /// The production probe: connect, say `hello` first, wait for the daemon's, run the gate,
    /// close.
    ///
    /// It blocks for at most `connectTimeout + helloTimeout`, so it belongs on a background
    /// queue and never on the main actor. The client it uses is the same client the session will
    /// use afterwards, which is the point — a probe that spoke a simplified dialect could admit a
    /// daemon the real link then refuses.
    static func connecting(eventLog: EventLog = .shared) -> PTYHostProbe {
        PTYHostProbe { request in
            PTYHostClient.probe(
                socketPath: request.socketPath,
                build: request.build,
                eventLog: eventLog
            )
        }
    }

    /// A probe that answers the same way every time, for a test that is forcing a branch.
    static func answering(_ outcome: PTYHostProbeOutcome) -> PTYHostProbe {
        PTYHostProbe { _ in outcome }
    }

    /// A probe that must never be called. Used to prove that `.disabled` and
    /// `.socketPathTooLong` are decided without reaching for a daemon.
    static func unreachable(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> PTYHostProbe {
        PTYHostProbe { _ in
            assertionFailure("The PTY host probe was called on a path that must not probe", file: file, line: line)
            return .notRunning
        }
    }
}

// MARK: - Generation Identity

/// The installed generation `hello` carries.
///
/// The release version/build spelling used elsewhere, plus the source revision local installs
/// inject while those two values remain `0.0.0`. It is compared only for graceful replacement;
/// the independently versioned protocol pair remains the admission gate.
enum PTYHostBuild {
    static let unknown = PTYHostGeneration.unknown

    static func string(for bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary
        return PTYHostGeneration.string(
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            bundleVersion: info?["CFBundleVersion"] as? String,
            sourceRevision: info?["ThreadingSourceRevision"] as? String
        )
    }
}

// MARK: - Decision

/// Everything about one launch's PTY-host question that can be answered without a peer.
///
/// `MCPBridgeDecision`'s shape, deliberately: every dependency is named by the caller, so
/// reusable code never recovers settings, bundle state or a singleton on demand, and a test can
/// force the setting on, name a helper that is not there, or name a socket path too long to bind,
/// without touching process defaults or the real bundle.
///
/// The split from `PTYHostAvailability.resolve` is also a concurrency boundary: this half reads
/// `AppSettings`, which is `@MainActor`, and the other half connects to a socket, which must not
/// happen on the main actor. Snapshot here, resolve there.
struct PTYHostDecision: Equatable, Sendable {

    /// The hidden opt-in. Off runs every PTY in-process, exactly as before the daemon existed.
    let isEnabled: Bool

    /// Where the daemon would be. Presence is checked at resolve, not here.
    let helperURL: URL

    /// The rendezvous, already through `addressableSocketPath` — nil when it cannot be bound.
    let socketPath: String?

    /// The unaddressable path's length, so the refusal can say how far over it was.
    let socketPathBytes: Int

    /// This app's build, for the daemon's journal.
    let build: String

    init(
        isEnabled: Bool,
        helperURL: URL,
        socketPath: String?,
        socketPathBytes: Int,
        build: String
    ) {
        self.isEnabled = isEnabled
        self.helperURL = helperURL
        self.socketPath = socketPath
        self.socketPathBytes = socketPathBytes
        self.build = build
    }

    /// Production composition. Nothing is recovered from a singleton inside.
    @MainActor
    static func live(settings: AppSettings, bundle: Bundle) -> PTYHostDecision {
        let path = PTYHostLocation.socketPath
        return PTYHostDecision(
            isEnabled: settings.ptyHostEnabled,
            helperURL: PTYHostLocation.helperURL(in: bundle),
            socketPath: PTYHostLocation.addressableSocketPath(path),
            socketPathBytes: path.utf8.count,
            build: PTYHostBuild.string(for: bundle)
        )
    }
}

// MARK: - Resolution

extension PTYHostAvailability {

    /// The whole decision, in the order that spends the least.
    ///
    /// The order is load-bearing rather than tidy. `disabled` is first and touches nothing —
    /// while the feature is off, which is every launch until R1 is answered, asking costs a
    /// `UserDefaults` read already taken. The path bound is next because it is arithmetic on a
    /// string. The helper's presence is one `stat`. Only then does anything connect.
    ///
    /// Deliberately **not** `@MainActor`: the probe blocks for as long as its deadlines allow.
    static func resolve(
        _ decision: PTYHostDecision,
        probing probe: PTYHostProbe,
        fileManager: FileManager = .default
    ) -> PTYHostAvailability {
        guard decision.isEnabled else { return .unavailable(.disabled) }

        guard let socketPath = decision.socketPath else {
            return .unavailable(.socketPathTooLong(bytes: decision.socketPathBytes))
        }

        guard fileManager.fileExists(atPath: decision.helperURL.path) else {
            ThreadingLogger.ptyHost.info(
                "PTY host helper is not in the bundle; sessions run their PTY in-process"
            )
            return .unavailable(.helperMissing)
        }

        let request = PTYHostProbeRequest(socketPath: socketPath, build: decision.build)
        switch probe.outcome(for: request) {
        case .ready:
            return .available(socketPath: socketPath)
        case .notRunning:
            return .unavailable(.notRunning)
        case .mismatched(let compatibility):
            return .unavailable(.protocolMismatch(compatibility))
        }
    }

    /// Snapshot and resolve in one call.
    ///
    /// `MCPBridgeDecision.live`'s shape with the probe added, for a caller that has one answer to
    /// give and one answer to take. A caller on the main actor that must genuinely *connect*
    /// snapshots with `PTYHostDecision.live(settings:bundle:)` here and calls `resolve` on its own
    /// queue instead — the probe is the caller's, and `PTYHostProbe.connecting` blocks.
    @MainActor
    static func live(
        settings: AppSettings,
        bundle: Bundle,
        probe: PTYHostProbe,
        fileManager: FileManager = .default
    ) -> PTYHostAvailability {
        resolve(
            PTYHostDecision.live(settings: settings, bundle: bundle),
            probing: probe,
            fileManager: fileManager
        )
    }
}
