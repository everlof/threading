import Darwin
import Foundation
import ThreadingPTYHostKit

// MARK: - Hold reasons

/// Why a daemon running a different build than this app was left alone.
///
/// Structural tokens rather than sentences, for the reason
/// [`reliability-and-type-safety.md`](../../../../docs/architecture/reliability-and-type-safety.md)
/// gives: a journal groups by cause, and a cause spelled as prose can only be grepped.
enum PTYHostUpgradeHold: Equatable, Sendable {

    /// The daemon is already this build. Nothing to upgrade — and this is the ordinary answer,
    /// because a daemon is normally the one the running app installed.
    case sameBuild

    /// The daemon is a different build and is holding somebody's agents. It keeps them; it
    /// remains reachable until a later event-driven or fallback survey sees its last session end,
    /// then receives `retire`. Nothing has to be killed for the upgrade to happen.
    case holdsSessions(Int)

    /// The version gate refused the peer. The handshake has already done whatever was correct —
    /// a `peerTooOld` daemon was sent `retire` there, and a `selfTooOld` one is deliberately left
    /// alone — so this policy must not act a second time.
    case incompatible(PTYHostCompatibility)

    /// The journal token. A cause, never a path or a user's text.
    var token: String {
        switch self {
        case .sameBuild: return "sameBuild"
        case .holdsSessions: return "holdsSessions"
        case .incompatible(let compatibility): return "incompatible.\(compatibility.rawValue)"
        }
    }
}

// MARK: - Decision

/// What to do about the daemon that answered.
enum PTYHostUpgradeDecision: Equatable, Sendable {

    /// Send `retire`. The daemon unlinks its socket immediately, drains nothing because it holds
    /// nothing, and exits; `KeepAlive` then starts whatever binary is on disk, which is the
    /// upgrade.
    case retire

    /// Leave it running, and say why.
    case leave(PTYHostUpgradeHold)

    /// Say nothing further to it at all. Distinct from `leave` because the two are different
    /// promises: `leave` is "this daemon is fine where it is", `refuse` is "this link is over and
    /// the app is falling back to in-process PTYs".
    case refuse(PTYHostCompatibility)

    var retires: Bool { self == .retire }

    var token: String {
        switch self {
        case .retire: return "retire"
        case .leave(let hold): return "leave.\(hold.token)"
        case .refuse(let compatibility): return "refuse.\(compatibility.rawValue)"
        }
    }
}

// MARK: - Policy

/// Whether a running daemon should be asked to stand down so the current binary can take over.
///
/// **This exists because launchd binds a registration to a path, not to a code identity.**
/// Measured on 2026-08-23: replacing the whole app bundle leaves the registration `enabled` and
/// the old daemon running the deleted binary's image, and launchd execs the new binary only on
/// the next start. Nothing in the OS will end it. So the app has to ask — and `retire` is the ask:
/// stop accepting, unlink the socket now so a replacement can bind it, keep serving what is
/// already attached, exit when the last session ends. A busy daemon is not asked yet, because
/// unlinking its socket would make a detached session impossible to take back; the monitor below
/// asks again after an exit edge and has a low-frequency backstop for unobserved detached work.
///
/// The post-commit hook reinstalls `/Applications/Threading.app` several times a day, which is why
/// the build string is *not* the admission gate (`PTYHostProtocol` is) and why this decision is
/// separate from it: a daemon of a different build is perfectly able to serve, and the only
/// question is whether now is a free moment to replace it. A daemon holding zero sessions is that
/// moment; one holding somebody's agents is not, and the answer there is to leave it reachable
/// until a later survey finds that the work has ended.
///
/// One function with four value arguments and no I/O, because every interesting case is a
/// combination rather than a code path: same build, different build with nothing held, different
/// build with work held, and a peer the gate already refused.
enum PTYHostUpgradePolicy {

    /// - Parameters:
    ///   - peerBuild: the daemon's `hello` build string. Reported, never compared for admission.
    ///   - ownBuild: this app's, from `PTYHostBuild.string(for:)`.
    ///   - compatibility: what `PTYHostProtocol.evaluate` said about the pair.
    ///   - activeSessions: what `list` answered is still running, attached or not. Ended sessions
    ///     retained for a late observer are safe because `retire` releases them itself.
    static func decide(
        peerBuild: String,
        ownBuild: String,
        compatibility: PTYHostCompatibility,
        activeSessions: Int,
        requiresRegistrationRefresh: Bool = false
    ) -> PTYHostUpgradeDecision {
        // The gate outranks everything below it. A `peerTooOld` daemon has already been sent
        // `retire` by the handshake, and a `selfTooOld` one must never be: retiring a daemon
        // newer than this app would take working agents down in order to install an older host.
        guard compatibility == .compatible else { return .refuse(compatibility) }

        // Identical generations are the common case, unless the registration receipt says this
        // daemon came from another bundle or from files replaced in place. In that case the
        // launchd association still has to be refreshed even though the wire generation agrees.
        if peerBuild == ownBuild, !requiresRegistrationRefresh { return .leave(.sameBuild) }

        // A different build holding work stays. This is the whole reason the daemon exists.
        guard activeSessions == 0 else { return .leave(.holdsSessions(activeSessions)) }

        return .retire
    }
}

// MARK: - What one round trip found

/// A daemon's answer to "who are you and what are you holding".
struct PTYHostSurvey: Equatable, Sendable {
    /// The daemon's `hello` build. Empty when the gate refused the peer before it said.
    let build: String
    let compatibility: PTYHostCompatibility
    /// Every still-running session the daemon holds, attached or not.
    let activeSessions: Int
}

// MARK: - Process identity

/// The kernel identity of the daemon that accepted a retirement request.
///
/// A pid alone is unsafe because macOS reuses it. The start timestamp lets the monitor wait for a
/// retiring daemon that raced from zero to one session between `list` and `retire`, without ever
/// mistaking a later process for the one it was waiting on or killing the raced session.
struct PTYHostProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let startTime: ProcessStartTime
}

/// Read-only kernel questions used by the upgrade monitor, behind a deterministic test seam.
struct PTYHostKernelProcessProbe: Sendable {
    private let identifyProcess: @Sendable (Int32) -> PTYHostProcessIdentity?
    private let matchProcess: @Sendable (PTYHostProcessIdentity) -> Bool

    init(
        identify: @escaping @Sendable (Int32) -> PTYHostProcessIdentity?,
        matches: @escaping @Sendable (PTYHostProcessIdentity) -> Bool
    ) {
        self.identifyProcess = identify
        self.matchProcess = matches
    }

    func identity(for pid: Int32) -> PTYHostProcessIdentity? { identifyProcess(pid) }
    func matches(_ identity: PTYHostProcessIdentity) -> Bool { matchProcess(identity) }

    static let live = PTYHostKernelProcessProbe(
        identify: { pid in
            guard let startTime = ProcessUtility.startTime(forPid: pid) else { return nil }
            return PTYHostProcessIdentity(pid: pid, startTime: startTime)
        },
        matches: { identity in
            ProcessUtility.startTime(forPid: identity.pid) == identity.startTime
        }
    )
}

/// What launchd says about the process behind the registered label when no socket answers.
enum PTYHostRegisteredProcessState: Equatable, Sendable {
    case running(PTYHostProcessIdentity)
    case notRunning
    case unknown
}

/// Whether a newly launched conversation may join the background daemon.
///
/// Reattach and stop clients deliberately do not consult this gate: existing work remains
/// reachable while a stale daemon drains. Only a new spawn is held back, closing the race where
/// launchd restarts an old registered image between confirmed retirement and re-registration.
final class PTYHostNewSessionAdmission: @unchecked Sendable {

    /// Three states rather than a `Bool`, because "we have not asked yet" and "we asked and the
    /// answer was no" are different facts and only the first is temporary.
    ///
    /// This mattered on a real machine. The withheld answer was re-asserted by every 30-second
    /// re-survey, and the journal line every launch got for it said `registrationRefreshing` —
    /// a token whose documented meaning is "a stale or ambiguous launchd association is being
    /// replaced safely". Nothing was being replaced: a compatible daemon of another build was
    /// holding thirty agents and would go on holding them for the rest of the day. Every new
    /// conversation degraded to an in-process PTY with a reason that was not the reason.
    enum State: Equatable, Sendable {
        /// This launch has not had an answer from the daemon yet. The only state that means
        /// "ask again in a moment", and the only one `registrationRefreshing` describes.
        case unresolved
        /// A survey answered, and new conversations may join the daemon.
        case allowed
        /// A survey answered, and a replacement this launch is waiting for is in the way.
        case withheld

        /// The structural cause a refused launch is journalled with.
        var token: String {
            switch self {
            case .unresolved: return PTYHostUnavailability.registrationRefreshing.token
            case .allowed: return "allowed"
            case .withheld: return "upgradePending"
            }
        }
    }

    static let shared = PTYHostNewSessionAdmission()

    private let lock = NSLock()
    private var state: State = .allowed

    var permitsHostedSpawn: Bool { current == .allowed }

    /// What the last survey settled on, or `.unresolved` before the first one answers.
    var current: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Moves the gate, and answers whether it moved.
    ///
    /// Idempotent on purpose: a re-survey that reaches the same conclusion is a survey that
    /// changed nothing, and availability during a refresh has to be whatever it was last
    /// resolved to. Callers use the answer to decide whether there is anything worth journalling.
    @discardableResult
    func resolve(_ next: State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state != next else { return false }
        state = next
        return true
    }
}

/// A bounded, read-only `launchctl print` probe for the exact launchd label.
///
/// This is not used on the ordinary path. It exists for the one ambiguous state
/// `SMAppService` cannot answer: an enabled stale association with no socket. A retiring daemon
/// has deliberately unlinked the socket and must be allowed to drain; a missing DerivedData
/// bundle has no process and can be reclaimed immediately.
struct PTYHostRegisteredProcessProbe: Sendable {
    private let answer: @Sendable () -> PTYHostRegisteredProcessState

    init(_ answer: @escaping @Sendable () -> PTYHostRegisteredProcessState) {
        self.answer = answer
    }

    func state() -> PTYHostRegisteredProcessState { answer() }

    /// Interprets one captured `launchctl print` answer without assigning meaning to prose other
    /// than launchctl's explicit missing-service diagnostic. Kept pure so malformed, repeated and
    /// pid-reuse-sensitive answers are regression cases rather than machine-state tests.
    static func interpret(
        output text: String,
        terminationStatus: Int32,
        kernel: PTYHostKernelProcessProbe
    ) -> PTYHostRegisteredProcessState {
        if text.localizedCaseInsensitiveContains("could not find service") {
            return .notRunning
        }
        guard terminationStatus == 0 else { return .unknown }

        let pidValues = text.split(whereSeparator: \.isNewline).compactMap { line -> Substring? in
            let value = line.trimmingCharacters(in: .whitespaces)
            let prefix = "pid = "
            guard value.hasPrefix(prefix) else { return nil }
            return value.dropFirst(prefix.count)
        }
        guard pidValues.count <= 1 else { return .unknown }
        guard let pidValue = pidValues.first else {
            // A successful print with no pid is absence proof only when launchctl also gave one
            // unambiguous inactive state. Empty, truncated, or changed-format output must not
            // become permission to call `unregister()`, which can kill a draining helper.
            let states = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let value = line.trimmingCharacters(in: .whitespaces)
                let prefix = "state = "
                guard value.hasPrefix(prefix) else { return nil }
                return String(value.dropFirst(prefix.count))
            }
            guard states.count == 1 else { return .unknown }
            switch states[0] {
            case "waiting", "not running", "exited":
                return .notRunning
            default:
                return .unknown
            }
        }
        guard let pid = Int32(pidValue), pid > 0 else { return .unknown }
        guard let identity = kernel.identity(for: pid) else { return .unknown }
        return .running(identity)
    }

    static func live(
        kernel: PTYHostKernelProcessProbe = .live
    ) -> PTYHostRegisteredProcessProbe {
        PTYHostRegisteredProcessProbe {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = [
                "print",
                "gui/\(getuid())/\(PTYHostRegistrationDefaults.label)"
            ]
            process.standardOutput = output
            process.standardError = output

            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do {
                try process.run()
            } catch {
                return .unknown
            }
            guard exited.wait(
                timeout: .now() + PTYHostRegistrationDefaults.launchctlProbeTimeout
            ) == .success else {
                process.terminate()
                return .unknown
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return .unknown }
            return interpret(
                output: text,
                terminationStatus: process.terminationStatus,
                kernel: kernel
            )
        }
    }
}

/// More precise than the policy decision because re-registering launchd needs proof that the
/// daemon which received `retire` is actually gone.
enum PTYHostUpgradeProgress: Equatable, Sendable {
    case noAnswer
    case settled(PTYHostUpgradeDecision)
    case retirementConfirmed
    case retirementPending(PTYHostProcessIdentity?)
}

// MARK: - The round trip

/// Connect, ask who is there and what they are holding, and act on the answer.
///
/// This is P2's half of the design made real: nothing in the OS ends a daemon whose bundle was
/// replaced, so the app first asks at launch, off the main actor, bounded by
/// `PTYHostRegistrationDefaults.surveyTimeout`, and costing an idle machine one connect and two
/// frames.
///
/// It is deliberately built on the shipping `PTYHostClient` rather than on a simplified dialect:
/// a check that spoke less than the link does could reach a conclusion about a daemon the link
/// then refuses.
enum PTYHostUpgradeCheck {

    // MARK: - Public Methods

    /// Surveys the daemon, applies `PTYHostUpgradePolicy`, and sends `retire` if it said to.
    ///
    /// Returns nil when nothing answered — no daemon, a refused connect, or a `list` that did not
    /// come back inside the deadline. Every one of those means "leave it alone", which is also
    /// what happens when there was never a daemon at all.
    ///
    /// **Blocking.** Never call it from the main actor.
    /// - Parameter journalsDecision: whether this answer is worth a journal line. The monitor
    ///   says no to a decision it has already recorded, because a re-survey that reaches the same
    ///   conclusion is not news — and a stale daemon holding somebody's agents is re-surveyed for
    ///   as long as it holds them.
    @discardableResult
    static func run(
        request: PTYHostUpgradeRequest,
        eventLog: EventLog = .shared,
        timeout: TimeInterval = PTYHostRegistrationDefaults.surveyTimeout,
        kernel: PTYHostKernelProcessProbe = .live,
        journalsDecision: (PTYHostUpgradeDecision) -> Bool = { _ in true }
    ) -> PTYHostUpgradeProgress {
        switch connectAndCount(
            socketPath: request.socketPath,
            ownBuild: request.ownBuild,
            eventLog: eventLog,
            timeout: timeout
        ) {
        case .noAnswer:
            return .noAnswer

        case .refusedByGate(let compatibility):
            // The handshake has already done whatever was correct — including sending `retire` to
            // a daemon too old to talk to. Saying it twice is how a newer daemon gets retired by
            // an older app, which is exactly what must never happen.
            return .settled(.refuse(compatibility))

        case .counted(let client, let hello, let survey, let closed):
            let decision = PTYHostUpgradePolicy.decide(
                peerBuild: survey.build,
                ownBuild: request.ownBuild,
                compatibility: survey.compatibility,
                activeSessions: survey.activeSessions,
                requiresRegistrationRefresh: request.requiresRegistrationRefresh
            )
            guard decision.retires else {
                client.close()
                if journalsDecision(decision) {
                    journal(
                        decision,
                        survey: survey,
                        ownBuild: request.ownBuild,
                        eventLog: eventLog
                    )
                }
                return .settled(decision)
            }

            // Capture the pid's other half before asking it to exit. If a spawn raced the list,
            // the daemon now drains instead of closing inside the short survey deadline; the
            // monitor follows this exact process until it is gone and only then re-registers.
            let identity = kernel.identity(for: hello.pid)
            do {
                try client.retire()
            } catch {
                client.close()
                return .noAnswer
            }
            let didClose = closed.wait(timeout) != nil
            client.close()
            if journalsDecision(decision) {
                journal(decision, survey: survey, ownBuild: request.ownBuild, eventLog: eventLog)
            }
            if didClose { return .retirementConfirmed }
            if let identity, !kernel.matches(identity) { return .retirementConfirmed }
            return .retirementPending(identity)
        }
    }

    /// Compatibility surface for callers interested only in the policy answer. Registration
    /// handoff uses the richer request overload above because it must distinguish "retire sent"
    /// from "the retiring process is confirmed gone".
    @discardableResult
    static func run(
        socketPath: String,
        ownBuild: String,
        eventLog: EventLog = .shared,
        timeout: TimeInterval = PTYHostRegistrationDefaults.surveyTimeout
    ) -> PTYHostUpgradeDecision? {
        switch run(
            request: PTYHostUpgradeRequest(socketPath: socketPath, ownBuild: ownBuild),
            eventLog: eventLog,
            timeout: timeout
        ) {
        case .noAnswer:
            return nil
        case .settled(let decision):
            return decision
        case .retirementConfirmed, .retirementPending:
            return .retire
        }
    }

    /// How many sessions the daemon holds, or nil when nothing answered.
    ///
    /// What the removal decision needs: `unregister()` kills the running helper, so turning the
    /// feature off has to know whether that would end somebody's turn.
    ///
    /// **Blocking.** Never call it from the main actor.
    static func activeSessions(
        socketPath: String,
        ownBuild: String,
        eventLog: EventLog = .shared,
        timeout: TimeInterval = PTYHostRegistrationDefaults.surveyTimeout
    ) -> Int? {
        switch connectAndCount(
            socketPath: socketPath,
            ownBuild: ownBuild,
            eventLog: eventLog,
            timeout: timeout
        ) {
        case .counted(let client, _, let survey, _):
            client.close()
            return survey.activeSessions
        case .refusedByGate, .noAnswer:
            return nil
        }
    }

    // MARK: - Private Methods

    private enum Outcome {
        /// The link is open and the caller owns closing it.
        case counted(
            client: PTYHostClient,
            hello: PTYHostHello,
            survey: PTYHostSurvey,
            closed: PTYHostLatch<Void>
        )
        case refusedByGate(PTYHostCompatibility)
        case noAnswer
    }

    private static func connectAndCount(
        socketPath: String,
        ownBuild: String,
        eventLog: EventLog,
        timeout: TimeInterval
    ) -> Outcome {
        let sessions = PTYHostLatch<[PTYHostSessionSummary]>()
        let closed = PTYHostLatch<Void>()
        let client = PTYHostClient(
            socketPath: socketPath,
            build: ownBuild,
            events: PTYHostClient.Events(
                frame: { frame in
                    if case .sessions(let summaries) = frame { sessions.complete(summaries) }
                },
                closed: { _ in
                    // Both latches: a link that ended before answering must not hold the caller
                    // for the whole deadline.
                    sessions.abandon()
                    closed.complete(())
                }
            ),
            eventLog: eventLog
        )

        let hello: PTYHostHello
        do {
            hello = try client.connect()
        } catch PTYHostClientError.incompatible(let compatibility) {
            return .refusedByGate(compatibility)
        } catch {
            return .noAnswer
        }

        do {
            try client.list()
        } catch {
            client.close()
            return .noAnswer
        }

        guard let summaries = sessions.wait(timeout) else {
            client.close()
            return .noAnswer
        }
        return .counted(
            client: client,
            hello: hello,
            survey: PTYHostSurvey(
                build: hello.build,
                compatibility: .compatible,
                activeSessions: summaries.lazy.filter { $0.exit == nil }.count
            ),
            closed: closed
        )
    }

    private static func journal(
        _ decision: PTYHostUpgradeDecision,
        survey: PTYHostSurvey,
        ownBuild: String,
        eventLog: EventLog
    ) {
        // The same-build answer is the ordinary one and happens on every launch; journalling it
        // would be journalling nothing happening.
        guard decision != .leave(.sameBuild) else { return }
        eventLog.record(.session, "PTY host upgrade decision", [
            "decision": decision.token,
            "daemonBuild": survey.build,
            "appBuild": ownBuild,
            "sessions": String(survey.activeSessions)
        ])
        switch decision {
        case .retire:
            ThreadingLogger.ptyHost.info(
                "Retiring the idle PTY host so launchd can start this build's daemon"
            )
        case .leave(.holdsSessions(let count)):
            ThreadingLogger.ptyHost.info(
                """
                A stale PTY host holds \(count, privacy: .public) sessions; \
                retirement is pending
                """
            )
        case .leave, .refuse:
            break
        }
    }
}

// MARK: - Eventual retirement

/// A host-owned child ended, so a stale daemon which was busy at launch may now be idle.
///
/// PTY links, native pipe links, and the background-session stop client all post this same edge.
/// The registration coordinator ignores it unless its launch survey found a different generation
/// with live work, so ordinary same-generation sessions add no socket traffic when they end.
struct PTYHostMayHaveDrained: AppEvent {
    static let name = Notification.Name("ptyHostMayHaveDrained")
}

/// The values a deferred upgrade check needs after the launch-time request has gone away.
struct PTYHostUpgradeRequest: Equatable, Sendable {
    let socketPath: String
    let ownBuild: String
    let registrationRequest: PTYHostRegistrationRequest?
    /// Whether an otherwise-current registration is allowed to accept new work. False after a
    /// refused/approval-pending registration even though the upgrade survey itself may settle.
    let allowsNewSessionsWhenCurrent: Bool

    var requiresRegistrationRefresh: Bool { registrationRequest != nil }

    init(
        socketPath: String,
        ownBuild: String,
        registrationRequest: PTYHostRegistrationRequest? = nil,
        allowsNewSessionsWhenCurrent: Bool = true
    ) {
        self.socketPath = socketPath
        self.ownBuild = ownBuild
        self.registrationRequest = registrationRequest
        self.allowsNewSessionsWhenCurrent = allowsNewSessionsWhenCurrent
    }
}

/// The blocking survey seam used by `PTYHostUpgradeMonitor`.
struct PTYHostUpgradeProbe: Sendable {
    private let answer: @Sendable (
        PTYHostUpgradeRequest,
        @escaping (PTYHostUpgradeDecision) -> Bool
    ) -> PTYHostUpgradeProgress

    init(
        _ answer: @escaping @Sendable (
            PTYHostUpgradeRequest,
            @escaping (PTYHostUpgradeDecision) -> Bool
        ) -> PTYHostUpgradeProgress
    ) {
        self.answer = answer
    }

    /// Convenience for a fake that does not care whether the answer was journalled.
    init(_ answer: @escaping @Sendable (PTYHostUpgradeRequest) -> PTYHostUpgradeProgress) {
        self.answer = { request, journalsDecision in
            let progress = answer(request)
            if case .settled(let decision) = progress { _ = journalsDecision(decision) }
            return progress
        }
    }

    func progress(
        for request: PTYHostUpgradeRequest,
        journalsDecision: @escaping (PTYHostUpgradeDecision) -> Bool = { _ in true }
    ) -> PTYHostUpgradeProgress {
        answer(request, journalsDecision)
    }

    static func live(eventLog: EventLog = .shared) -> PTYHostUpgradeProbe {
        PTYHostUpgradeProbe { request, journalsDecision in
            PTYHostUpgradeCheck.run(
                request: request,
                eventLog: eventLog,
                journalsDecision: journalsDecision
            )
        }
    }
}

/// Remembers the one upgrade that could not happen because the stale host still had live work.
///
/// `PTYHostRegistrationCoordinator` calls every method on its serial background queue. A session
/// ending re-runs the real `hello` + `list` decision rather than trusting an app-side count: the
/// daemon may also hold detached sessions this process has never represented in memory. One
/// scheduled retry covers those unobservable endings without polling an ordinary current daemon.
final class PTYHostUpgradeMonitor: @unchecked Sendable {
    private let probe: PTYHostUpgradeProbe
    private let scheduleRetry: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let registeredProcessProbe: PTYHostRegisteredProcessProbe
    private let kernelProcessProbe: PTYHostKernelProcessProbe
    private let refreshRegistration: @Sendable (PTYHostRegistrationRequest) -> Bool
    private let setNewSessionAdmission: @Sendable (PTYHostNewSessionAdmission.State) -> Void
    private var pending: PTYHostUpgradeRequest?
    private var observedProcess: PTYHostProcessIdentity?
    private var hasScheduledRetry = false

    /// The next fallback delay, doubling from `upgradeRetryInterval` towards
    /// `upgradeRetryMaximumInterval`.
    ///
    /// **A backstop is not a poll.** The retry that matters is event-driven — a host-owned child
    /// ending posts `PTYHostMayHaveDrained` and re-runs the real decision at once — and this
    /// exists only for a *detached* child this launch could not adopt and therefore cannot
    /// observe ending. A daemon holding somebody's thirty agents holds them for hours, and a
    /// fixed 30-second timer against it is 2,880 connects and 5,760 journal lines a day saying
    /// the same thing. So it retries promptly at first, when a drain really might be seconds
    /// away, and settles into a long interval when it plainly is not.
    private var nextRetryInterval = PTYHostRegistrationDefaults.upgradeRetryInterval

    /// The decision the journal last recorded for the pending upgrade, so a re-survey that
    /// reaches the same one records nothing.
    private var journalledDecision: PTYHostUpgradeDecision?

    init(
        probe: PTYHostUpgradeProbe = .live(),
        scheduleRetry: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
            = { _, _ in },
        registeredProcessProbe: PTYHostRegisteredProcessProbe = .live(),
        kernelProcessProbe: PTYHostKernelProcessProbe = .live,
        refreshRegistration: @escaping @Sendable (PTYHostRegistrationRequest) -> Bool = { _ in true },
        setNewSessionAdmission: @escaping @Sendable (PTYHostNewSessionAdmission.State) -> Void
            = { _ in }
    ) {
        self.probe = probe
        self.scheduleRetry = scheduleRetry
        self.registeredProcessProbe = registeredProcessProbe
        self.kernelProcessProbe = kernelProcessProbe
        self.refreshRegistration = refreshRegistration
        self.setNewSessionAdmission = setNewSessionAdmission
    }

    /// Runs the once-per-launch survey. Only a stale daemon with active work stays pending.
    /// Silence means there was no old process to replace; a daemon launched later comes from the
    /// bundle currently on disk.
    func begin(_ request: PTYHostUpgradeRequest) {
        // Unresolved rather than withheld: this launch has not heard from the daemon yet, and a
        // launch that lands in this window is degrading because nobody has asked, not because
        // the answer was no.
        setNewSessionAdmission(.unresolved)
        pending = request
        observedProcess = nil
        journalledDecision = nil
        nextRetryInterval = PTYHostRegistrationDefaults.upgradeRetryInterval
        evaluate(request, preservesPendingOnSilence: false)
        scheduleFallbackIfNeeded()
    }

    /// Rechecks after a host-owned child ended. A transient silence keeps the pending generation
    /// so another ending can retry; it never turns into permission to signal a process.
    ///
    /// An ending is real evidence that the count moved, so it also resets the backoff: the next
    /// backstop is prompt again rather than an hour away because nothing had happened for an hour.
    func hostMayHaveDrained() {
        guard let pending else { return }
        nextRetryInterval = PTYHostRegistrationDefaults.upgradeRetryInterval
        evaluate(pending, preservesPendingOnSilence: true)
    }

    /// Turning the host off cancels upgrade work as well as future hosted launches.
    func cancel() {
        setNewSessionAdmission(.unresolved)
        pending = nil
        observedProcess = nil
        journalledDecision = nil
    }

    /// Runs the scheduled backstop. Kept separate from session-ending retries so one timer stays
    /// outstanding however many hosted children end in the interval.
    private func scheduledRetry() {
        hasScheduledRetry = false
        guard let pending else { return }
        evaluate(pending, preservesPendingOnSilence: true)
        scheduleFallbackIfNeeded()
    }

    private func evaluate(
        _ request: PTYHostUpgradeRequest,
        preservesPendingOnSilence: Bool
    ) {
        switch progress(of: request) {
        case .settled(.leave(.holdsSessions)):
            setNewSessionAdmission(.withheld)
            pending = request
            observedProcess = nil
        case .noAnswer where request.requiresRegistrationRefresh:
            evaluateUnansweredRefresh(request)
        case .noAnswer where preservesPendingOnSilence:
            setNewSessionAdmission(.withheld)
            pending = request
        case .retirementPending(let identity) where request.requiresRegistrationRefresh:
            setNewSessionAdmission(.withheld)
            pending = request
            observedProcess = identity ?? observedProcess
            if observedProcess == nil { observeRegisteredProcess(for: request) }
        case .retirementConfirmed where request.requiresRegistrationRefresh:
            completeRefresh(request)
        case .settled(.leave(.sameBuild)), .retirementConfirmed, .noAnswer:
            setNewSessionAdmission(request.allowsNewSessionsWhenCurrent ? .allowed : .withheld)
            pending = nil
            observedProcess = nil
        case .settled, .retirementPending:
            setNewSessionAdmission(.withheld)
            pending = nil
            observedProcess = nil
        }
    }

    /// Runs the survey, telling it whether this answer is worth a journal line.
    ///
    /// The same decision reached again is not news. It was two lines every thirty seconds for the
    /// whole life of an app whose daemon was never going to be free, which is how a journal stops
    /// being read.
    private func progress(of request: PTYHostUpgradeRequest) -> PTYHostUpgradeProgress {
        let answer = probe.progress(for: request, journalsDecision: { [weak self] decision in
            guard let self else { return true }
            guard self.journalledDecision != decision else { return false }
            self.journalledDecision = decision
            return true
        })
        if case .noAnswer = answer { journalledDecision = nil }
        return answer
    }

    private func evaluateUnansweredRefresh(_ request: PTYHostUpgradeRequest) {
        // A process already observed behind the now-silent label is allowed to drain. Once that
        // exact pid/start-time pair is gone, a later launchd restart can only be idle: the stale
        // socket never admitted a new app-side spawn after retirement.
        if let observedProcess {
            if kernelProcessProbe.matches(observedProcess) {
                pending = request
            } else {
                completeRefresh(request)
            }
            return
        }
        observeRegisteredProcess(for: request)
    }

    private func observeRegisteredProcess(for request: PTYHostUpgradeRequest) {
        switch registeredProcessProbe.state() {
        case .running(let identity):
            setNewSessionAdmission(.withheld)
            pending = request
            observedProcess = identity
        case .notRunning:
            completeRefresh(request)
        case .unknown:
            setNewSessionAdmission(.withheld)
            // Uncertainty is never permission to call `unregister()`, because that call kills a
            // helper which may simply have unlinked its socket to drain.
            pending = request
        }
    }

    private func completeRefresh(_ request: PTYHostUpgradeRequest) {
        guard let registrationRequest = request.registrationRequest else {
            pending = nil
            observedProcess = nil
            return
        }
        if refreshRegistration(registrationRequest) {
            setNewSessionAdmission(.allowed)
            pending = nil
            observedProcess = nil
        } else {
            setNewSessionAdmission(.withheld)
            // `SMAppService` can fail transiently. With no old daemon left, the next backstop
            // retries only the bounded registration handoff; sessions meanwhile use in-process.
            pending = request
            observedProcess = nil
        }
    }

    private func scheduleFallbackIfNeeded() {
        guard pending != nil, !hasScheduledRetry else { return }
        hasScheduledRetry = true
        let delay = nextRetryInterval
        nextRetryInterval = min(
            delay * 2,
            PTYHostRegistrationDefaults.upgradeRetryMaximumInterval
        )
        scheduleRetry(delay) { [weak self] in self?.scheduledRetry() }
    }
}

// MARK: - Latch

/// A one-shot value handed from a client callback to a blocked caller.
///
/// A semaphore plus a lock rather than a continuation, because the caller here is a blocking
/// function on a background queue by design — the whole check is bounded, off-main work — and
/// because `PTYHostClient` delivers on its own serial queue with no async surface at all.
final class PTYHostLatch<Value>: @unchecked Sendable {

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Value?
    private var settled = false

    /// Delivers the value, once. Later calls are ignored.
    func complete(_ value: Value) {
        lock.lock()
        guard !settled else { return lock.unlock() }
        settled = true
        self.value = value
        lock.unlock()
        semaphore.signal()
    }

    /// Wakes the waiter with nothing — the link ended before an answer arrived.
    func abandon() {
        lock.lock()
        guard !settled else { return lock.unlock() }
        settled = true
        lock.unlock()
        semaphore.signal()
    }

    /// Blocks for at most `timeout` and answers what arrived, or nil.
    func wait(_ timeout: TimeInterval) -> Value? {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
