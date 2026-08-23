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
    /// retires when its last session ends, which is what `retire` already means, and which is why
    /// nothing has to be killed for an upgrade to happen.
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
/// already attached, exit when the last session ends.
///
/// The post-commit hook reinstalls `/Applications/Threading.app` several times a day, which is why
/// the build string is *not* the admission gate (`PTYHostProtocol` is) and why this decision is
/// separate from it: a daemon of a different build is perfectly able to serve, and the only
/// question is whether now is a free moment to replace it. A daemon holding zero sessions is that
/// moment; one holding somebody's agents is not, and the answer there is to leave it — it retires
/// on its own once it has been asked, and until then it goes on doing exactly what it was doing.
///
/// One function with four value arguments and no I/O, because every interesting case is a
/// combination rather than a code path: same build, different build with nothing held, different
/// build with work held, and a peer the gate already refused.
enum PTYHostUpgradePolicy {

    /// - Parameters:
    ///   - peerBuild: the daemon's `hello` build string. Reported, never compared for admission.
    ///   - ownBuild: this app's, from `PTYHostBuild.string(for:)`.
    ///   - compatibility: what `PTYHostProtocol.evaluate` said about the pair.
    ///   - heldSessions: what `list` answered — every session the daemon holds, attached or not.
    static func decide(
        peerBuild: String,
        ownBuild: String,
        compatibility: PTYHostCompatibility,
        heldSessions: Int
    ) -> PTYHostUpgradeDecision {
        // The gate outranks everything below it. A `peerTooOld` daemon has already been sent
        // `retire` by the handshake, and a `selfTooOld` one must never be: retiring a daemon
        // newer than this app would take working agents down in order to install an older host.
        guard compatibility == .compatible else { return .refuse(compatibility) }

        // Identical builds are the common case — one reinstall in ten leaves the daemon actually
        // stale — and there is nothing to gain from replacing a process with its own image.
        guard peerBuild != ownBuild else { return .leave(.sameBuild) }

        // A different build holding work stays. This is the whole reason the daemon exists.
        guard heldSessions == 0 else { return .leave(.holdsSessions(heldSessions)) }

        return .retire
    }
}

// MARK: - What one round trip found

/// A daemon's answer to "who are you and what are you holding".
struct PTYHostSurvey: Equatable, Sendable {
    /// The daemon's `hello` build. Empty when the gate refused the peer before it said.
    let build: String
    let compatibility: PTYHostCompatibility
    /// Every session the daemon holds, attached or not, as `list` answered.
    let heldSessions: Int
}

// MARK: - The round trip

/// Connect, ask who is there and what they are holding, and act on the answer.
///
/// This is P2's half of the design made real: nothing in the OS ends a daemon whose bundle was
/// replaced, so the app asks — once per launch, off the main actor, bounded by
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
    @discardableResult
    static func run(
        socketPath: String,
        ownBuild: String,
        eventLog: EventLog = .shared,
        timeout: TimeInterval = PTYHostRegistrationDefaults.surveyTimeout
    ) -> PTYHostUpgradeDecision? {
        switch connectAndCount(
            socketPath: socketPath,
            ownBuild: ownBuild,
            eventLog: eventLog,
            timeout: timeout
        ) {
        case .noAnswer:
            return nil

        case .refusedByGate(let compatibility):
            // The handshake has already done whatever was correct — including sending `retire` to
            // a daemon too old to talk to. Saying it twice is how a newer daemon gets retired by
            // an older app, which is exactly what must never happen.
            return .refuse(compatibility)

        case .counted(let client, let survey, let closed):
            let decision = PTYHostUpgradePolicy.decide(
                peerBuild: survey.build,
                ownBuild: ownBuild,
                compatibility: survey.compatibility,
                heldSessions: survey.heldSessions
            )
            if decision.retires {
                try? client.retire()
                // Wait for the daemon to hang up rather than closing on top of the frame: the
                // write is asynchronous, and `close()` stops the channel. A retiring daemon with
                // nothing to drain exits immediately, so this is the ending, not a delay.
                _ = closed.wait(timeout)
            }
            client.close()
            journal(decision, survey: survey, ownBuild: ownBuild, eventLog: eventLog)
            return decision
        }
    }

    /// How many sessions the daemon holds, or nil when nothing answered.
    ///
    /// What the removal decision needs: `unregister()` kills the running helper, so turning the
    /// feature off has to know whether that would end somebody's turn.
    ///
    /// **Blocking.** Never call it from the main actor.
    static func heldSessions(
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
        case .counted(let client, let survey, _):
            client.close()
            return survey.heldSessions
        case .refusedByGate, .noAnswer:
            return nil
        }
    }

    // MARK: - Private Methods

    private enum Outcome {
        /// The link is open and the caller owns closing it.
        case counted(client: PTYHostClient, survey: PTYHostSurvey, closed: PTYHostLatch<Void>)
        case refusedByGate(PTYHostCompatibility)
        case noAnswer
    }

    private static func connectAndCount(
        socketPath: String,
        ownBuild: String,
        eventLog: EventLog,
        timeout: TimeInterval
    ) -> Outcome {
        let sessions = PTYHostLatch<Int>()
        let closed = PTYHostLatch<Void>()
        let client = PTYHostClient(
            socketPath: socketPath,
            build: ownBuild,
            events: PTYHostClient.Events(
                frame: { frame in
                    if case .sessions(let summaries) = frame { sessions.complete(summaries.count) }
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

        guard let count = sessions.wait(timeout) else {
            client.close()
            return .noAnswer
        }
        return .counted(
            client: client,
            survey: PTYHostSurvey(
                build: hello.build,
                compatibility: .compatible,
                heldSessions: count
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
            "sessions": String(survey.heldSessions)
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
                it retires when idle
                """
            )
        case .leave, .refuse:
            break
        }
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
