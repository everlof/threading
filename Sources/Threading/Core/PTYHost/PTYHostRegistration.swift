import Foundation
import ServiceManagement
import ThreadingPTYHostKit

// MARK: - Registration Defaults

/// Names and bounds for the launchd registration.
///
/// The label and the plist's file name are the same string with a suffix, and they are still
/// written out separately: `SMAppService.agent(plistName:)` addresses the *file* and launchd
/// addresses the *label*, and a build that got one of them wrong would register a service nobody
/// can find rather than fail.
enum PTYHostRegistrationDefaults {

    /// The launchd label, matching `Label` in the plist.
    static let label = "codes.threading.ptyd"

    /// The file `SMAppService.agent(plistName:)` reads, relative to
    /// `Contents/Library/LaunchAgents`.
    static let plistName = "codes.threading.ptyd.plist"

    /// Where the bundle keeps it. Named so a test can read the shipped file rather than a copy of
    /// what it is supposed to say.
    static let launchAgentsDirectoryPath = "Contents/Library/LaunchAgents"

    /// How long the survey waits for a `sessions` frame before giving up on counting.
    ///
    /// Bounded because a daemon that will not answer must cost a launch nothing: an unanswered
    /// survey is "no usable answer", and every caller's response to that is to leave the daemon
    /// alone, which is also what happens if it turns out there was no daemon at all.
    static let surveyTimeout: TimeInterval = 5

    /// The serial queue registration and surveying run on. Never main: `SMAppService.register()`
    /// is an XPC round trip to `smd`, and the survey blocks on a socket handshake.
    static let queueLabel = "codes.threading.ptyhost.registration"
}

// MARK: - Status

/// `SMAppService.Status`, restated as a value this app can act on.
///
/// A restatement rather than the framework enum, for two reasons. It is where `@unknown default`
/// is handled once, so a macOS release adding a case cannot silently take a branch meant for
/// something else. And it is what lets `PTYHostAgentService` be a `Sendable` seam a test can
/// implement without touching launchd — the framework type is not the interesting part, the
/// mapping to a `PTYHostUnavailability` is.
enum PTYHostRegistrationStatus: Equatable, Sendable {

    /// launchd has the job and it is on. The daemon may still not be *running* — that is what the
    /// socket probe answers — but nothing about the registration says it cannot be.
    case enabled

    /// Registered and waiting for the user in System Settings ▸ General ▸ Login Items.
    case requiresApproval

    /// launchd knows the label and the service is currently off.
    case notRegistered

    /// launchd has never seen the label.
    case notFound

    /// A status this build does not know. Journalled with its raw value and treated as
    /// `notRegistered`: "seen, currently off" is the answer whose fix is to register again, which
    /// is the only useful thing to try against a status nobody here can interpret.
    case unknown(Int)

    /// The one place `SMAppService.Status` becomes ours.
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .unknown(status.rawValue)
        }
    }

    /// What this status means for a launch that wants the host, or nil when it means nothing —
    /// `enabled` is a *candidate*, and whether a daemon is actually listening is the socket
    /// probe's question, not launchd's.
    var unavailability: PTYHostUnavailability? {
        switch self {
        case .enabled: return nil
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        case .unknown: return .notRegistered
        }
    }

    /// Whether launchd is holding the job at all — approval pending counts, because the fix is
    /// the user's switch and not another `register()`.
    var isRegistered: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound, .unknown: return false
        }
    }

    /// The journal token. A cause, never a path or a user's text.
    var token: String {
        switch self {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        case .unknown(let raw): return "unknown.\(raw)"
        }
    }
}

// MARK: - The ServiceManagement seam

/// The three `SMAppService` calls this feature makes, behind a protocol.
///
/// Injectable so `PTYHostRegistrationTests` can drive every status, a throwing `register()` and a
/// throwing `unregister()` with no launchd involved at all — which matters more here than it
/// usually does: **a hosted test bundle lives inside the shipping app**, so a test that reached
/// the real `SMAppService` would register the developer's own login item and start a daemon on
/// their machine. The guards below refuse that too; the seam is what makes refusing it testable.
protocol PTYHostAgentService: Sendable {
    var status: PTYHostRegistrationStatus { get }
    func register() throws
    func unregister() throws
}

/// The production seam: `SMAppService.agent(plistName:)` against the bundle's own plist.
///
/// `@unchecked Sendable` around an immutable `SMAppService` reference. The framework type is not
/// `Sendable`, the calls are made from one serial queue, and the alternative — hopping to the main
/// actor for an XPC round trip at launch — is the thing this queue exists to avoid.
final class PTYHostLaunchAgentService: PTYHostAgentService, @unchecked Sendable {

    private let service: SMAppService

    init(plistName: String = PTYHostRegistrationDefaults.plistName) {
        self.service = SMAppService.agent(plistName: plistName)
    }

    var status: PTYHostRegistrationStatus { PTYHostRegistrationStatus(service.status) }

    func register() throws { try service.register() }

    func unregister() throws { try service.unregister() }
}

// MARK: - What the registration was asked

/// Everything one registration attempt needs to know, snapshotted on the main actor.
///
/// `PTYHostDecision`'s shape, and for its reason: reusable code never recovers settings, launch
/// mode or bundle state on demand, so a test can force recovery, force a hosted bundle, or name a
/// helper that is not there without touching either.
struct PTYHostRegistrationRequest: Sendable {

    /// The setting, the helper's path, the rendezvous and this build's string.
    let decision: PTYHostDecision

    /// Recovery never registers. `crash-recovery.md`: recovery starts no background machinery and
    /// spawns no processes, and a launch that came up because the last one did not is the worst
    /// possible moment to install a daemon that outlives it.
    let isRecovery: Bool

    /// A hosted test bundle never registers. The bundle a test runs in *is* the shipping app, so
    /// the registration would be the developer's, pointing at their app, starting a daemon on
    /// their machine — and `unregister()` kills the running helper, so a test that tidied up
    /// would also stop whatever the developer's own app was doing.
    let isHostedTest: Bool

    init(decision: PTYHostDecision, isRecovery: Bool, isHostedTest: Bool) {
        self.decision = decision
        self.isRecovery = isRecovery
        self.isHostedTest = isHostedTest
    }

    @MainActor
    static func live(settings: AppSettings, bundle: Bundle = .main) -> PTYHostRegistrationRequest {
        PTYHostRegistrationRequest(
            decision: PTYHostDecision.live(settings: settings, bundle: bundle),
            isRecovery: RecoveryMode.isActive,
            isHostedTest: StateManager.isHostedTest
        )
    }
}

// MARK: - Outcomes

/// Why a registration attempt did not happen. Never a failure — every one of these leaves the app
/// on today's in-process `forkpty`, which is the whole posture of the feature.
enum PTYHostRegistrationSkip: Equatable, Sendable {
    case disabled
    case recoveryMode
    case hostedTest
    case socketPathTooLong(bytes: Int)
    case helperMissing
    case alreadySettled

    var token: String {
        switch self {
        case .disabled: return "disabled"
        case .recoveryMode: return "recoveryMode"
        case .hostedTest: return "hostedTest"
        case .socketPathTooLong: return "socketPathTooLong"
        case .helperMissing: return "helperMissing"
        case .alreadySettled: return "alreadySettled"
        }
    }
}

/// What one `register()` or `unregister()` did.
enum PTYHostRegistrationOutcome: Equatable, Sendable {

    /// launchd now holds the job and it is on.
    case registered

    /// Registered, and the user has to allow it. `PTYHostRegistration.openLoginItemsSettings()`
    /// is the affordance; this slice ships no UI for it.
    case awaitingApproval

    /// The registration is gone, or was never there.
    case unregistered

    /// Nothing was attempted, and this is why.
    case skipped(PTYHostRegistrationSkip)

    /// The daemon still holds this many sessions, so the registration was left in place —
    /// `unregister()` kills the running helper, and the helper is holding somebody's agents.
    case leftForRunningSessions(Int)

    /// `register()` or `unregister()` threw. The `NSError` code, for the journal; never the
    /// message, which is a localized sentence.
    case failed(code: Int)

    /// The call returned without throwing and launchd still says the job is not on. Distinct from
    /// `failed` because nothing went wrong — a managed Mac can simply refuse.
    case refused(PTYHostRegistrationStatus)

    var token: String {
        switch self {
        case .registered: return "registered"
        case .awaitingApproval: return "awaitingApproval"
        case .unregistered: return "unregistered"
        case .skipped(let skip): return "skipped.\(skip.token)"
        case .leftForRunningSessions: return "leftForRunningSessions"
        case .failed(let code): return "failed.\(code)"
        case .refused(let status): return "refused.\(status.token)"
        }
    }
}

// MARK: - Removal

/// Whether turning the feature off may take the registration with it.
///
/// It is a decision rather than a call because `unregister()` **kills the running helper** —
/// measured on 2026-08-23, along with everything else in the registration probe — and the running
/// helper may be holding a person's working agents. Turning a hidden preference off must not be a
/// way to end somebody's turn.
enum PTYHostRemovalDecision: Equatable, Sendable {

    /// Nothing is held. Remove it.
    case unregister

    /// This many sessions are still hosted, so the job stays registered and the app simply stops
    /// using it — `AppSettings.ptyHostEnabled` being off short-circuits the availability decision
    /// before anything connects. The next launch that finds the daemon idle removes it.
    ///
    /// Deliberately **not** `retire`: retiring unlinks the socket, and a user who turns the key
    /// back on would then be unable to reach the sessions still running under it.
    case leave(heldSessions: Int)

    var token: String {
        switch self {
        case .unregister: return "unregister"
        case .leave: return "leave"
        }
    }
}

// MARK: - Registration

/// Registering, unregistering and surveying the launchd agent that starts `threading-ptyd`.
///
/// **Attempted and never required.** Every refusal here is a `PTYHostUnavailability` and every
/// unavailability is today's in-process `forkpty`, unchanged. Nothing in this type can fail a
/// launch, and nothing in it runs on the main actor.
///
/// It journals at the edges only — registered, unregistered, left alone, refused, failed — because
/// a status read happens on every launch and a journal that recorded them would be a journal of
/// nothing happening.
final class PTYHostRegistration: Sendable {

    // MARK: - Properties

    private let service: PTYHostAgentService
    private let eventLog: EventLog
    private let fileProbe: PTYHostFileProbe

    // MARK: - Initialization

    init(
        service: PTYHostAgentService = PTYHostLaunchAgentService(),
        eventLog: EventLog = .shared,
        fileProbe: PTYHostFileProbe = .live
    ) {
        self.service = service
        self.eventLog = eventLog
        self.fileProbe = fileProbe
    }

    // MARK: - Public Properties

    /// What launchd says, right now. A cheap read; it is not journalled.
    var status: PTYHostRegistrationStatus { service.status }

    /// What launchd's answer means for a launch that wants the host, or nil when it means the
    /// registration is no obstacle. The socket probe still decides whether a daemon is listening.
    var unavailability: PTYHostUnavailability? { service.status.unavailability }

    // MARK: - Public Methods

    /// Registers the agent if the request allows it and launchd is not already holding the job.
    ///
    /// Idempotent by construction: an `enabled` status is answered `.skipped(.alreadySettled)`
    /// without calling `register()`, so the ordinary launch — which is every launch after the
    /// first — costs one status read.
    @discardableResult
    func register(_ request: PTYHostRegistrationRequest) -> PTYHostRegistrationOutcome {
        if let skip = refusal(for: request) { return .skipped(skip) }

        let before = service.status
        guard before != .enabled else { return .skipped(.alreadySettled) }

        do {
            try service.register()
        } catch let error as NSError {
            journal("PTY host registration failed", outcome: .failed(code: error.code))
            ThreadingLogger.ptyHost.error(
                """
                Could not register \(PTYHostRegistrationDefaults.label, privacy: .public): \
                code \(error.code, privacy: .public); sessions run their PTY in-process
                """
            )
            return .failed(code: error.code)
        }

        let after = service.status
        switch after {
        case .enabled:
            journal("PTY host agent registered", outcome: .registered)
            return .registered
        case .requiresApproval:
            journal("PTY host agent awaits approval", outcome: .awaitingApproval)
            return .awaitingApproval
        case .notRegistered, .notFound, .unknown:
            journal("PTY host registration refused", outcome: .refused(after))
            return .refused(after)
        }
    }

    /// Removes the registration, unless the daemon is holding sessions.
    ///
    /// `heldSessions` is what a survey found: nil when nothing answered, which is the same as
    /// nothing being held — there is no daemon to kill, so removing the job costs nobody a turn.
    @discardableResult
    func unregister(
        _ request: PTYHostRegistrationRequest,
        heldSessions: Int?
    ) -> PTYHostRegistrationOutcome {
        // Recovery and a hosted test bundle refuse this direction too. A test that unregistered
        // would be reaching into the developer's launchd exactly as one that registered would.
        if request.isRecovery { return .skipped(.recoveryMode) }
        if request.isHostedTest { return .skipped(.hostedTest) }

        guard service.status.isRegistered else { return .skipped(.alreadySettled) }

        switch Self.removalDecision(heldSessions: heldSessions) {
        case .leave(let count):
            journal(
                "PTY host agent left registered",
                outcome: .leftForRunningSessions(count),
                extra: ["sessions": String(count)]
            )
            ThreadingLogger.ptyHost.info(
                """
                PTY host is off but the daemon still holds \(count, privacy: .public) \
                sessions; the agent is removed once it is idle
                """
            )
            return .leftForRunningSessions(count)
        case .unregister:
            break
        }

        do {
            try service.unregister()
        } catch let error as NSError {
            journal("PTY host unregistration failed", outcome: .failed(code: error.code))
            return .failed(code: error.code)
        }
        journal("PTY host agent unregistered", outcome: .unregistered)
        return .unregistered
    }

    /// Takes the user to the Login Items row, for the `requiresApproval` case.
    ///
    /// Wrapped rather than called directly at a future call site so `ServiceManagement` is
    /// imported in exactly one file — the same containment `MCPBridgeLocation` gives the bridge.
    @MainActor
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether removing the registration would end work somebody is doing.
    ///
    /// Pure, and separate from the call, because it is the interesting half: `unregister()` kills
    /// the running helper, so the count is the difference between a tidy removal and ending a
    /// person's turn.
    static func removalDecision(heldSessions: Int?) -> PTYHostRemovalDecision {
        guard let heldSessions, heldSessions > 0 else { return .unregister }
        return .leave(heldSessions: heldSessions)
    }

    // MARK: - Private Methods

    /// The refusals that are decided from the request alone, in the order that spends the least —
    /// the same ordering argument `PTYHostAvailability.resolve` makes, and for the same reason.
    private func refusal(for request: PTYHostRegistrationRequest) -> PTYHostRegistrationSkip? {
        guard request.decision.isEnabled else { return .disabled }
        if request.isRecovery { return .recoveryMode }
        if request.isHostedTest { return .hostedTest }
        guard request.decision.socketPath != nil else {
            // A daemon that cannot bind its rendezvous exits at start-up, and `KeepAlive` would
            // then restart it once per `ThrottleInterval` forever. Not registering is the correct
            // answer to a home directory too long for `sockaddr_un`.
            return .socketPathTooLong(bytes: request.decision.socketPathBytes)
        }
        guard fileProbe.isExecutable(request.decision.helperURL.path) else {
            return .helperMissing
        }
        return nil
    }

    private func journal(
        _ message: String,
        outcome: PTYHostRegistrationOutcome,
        extra: [String: String] = [:]
    ) {
        var fields = ["outcome": outcome.token, "label": PTYHostRegistrationDefaults.label]
        fields.merge(extra) { _, new in new }
        eventLog.record(.session, message, fields)
    }
}

// MARK: - File probe

/// The one filesystem question registration asks, behind a seam.
///
/// A `FileManager` would do, and a closure is what makes "the helper is not in this bundle"
/// reachable from a test running inside a bundle that does have one.
struct PTYHostFileProbe: Sendable {

    private let answer: @Sendable (String) -> Bool

    init(_ answer: @escaping @Sendable (String) -> Bool) {
        self.answer = answer
    }

    func isExecutable(_ path: String) -> Bool { answer(path) }

    static let live = PTYHostFileProbe { FileManager.default.isExecutableFile(atPath: $0) }

    static let nothingIsThere = PTYHostFileProbe { _ in false }

    static let everythingIsThere = PTYHostFileProbe { _ in true }
}
