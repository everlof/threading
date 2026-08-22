import Darwin
import Foundation

// MARK: - Single Instance Takeover

/// Ends a lock owner that has stopped answering, once the user has said to.
///
/// Reached only from `SingleInstanceTriage.Verdict.offerTakeover` and only after an explicit
/// confirmation. Nothing here is automatic, and nothing here signals a process whose identity
/// has not just been checked again.
///
/// The order is the design:
///
/// 1. **Re-probe before signalling.** The alert was on screen while the user read it, which is
///    long enough for a slow launch, a paused debugger or a disk stall to come back. A heartbeat
///    that has ticked since means the owner is alive, and the answer becomes "activate it"
///    rather than "kill it".
/// 2. **Verify identity again**, on the pair the card carries, because the wait above is itself
///    a window in which the owner could exit and its pid be handed to something new.
/// 3. **`SIGTERM`, then the lock, then `SIGKILL`, then the lock again.** The signal is not the
///    success condition; holding the lock is. A wedged process may take the term and unwind, and
///    a process that ignores both leaves the launch exactly where it started, which is a refusal
///    rather than a second escalation.
///
/// Every step is a closure so the whole table can be tested without a process to kill.
///
/// Main-actor throughout, and blocking on purpose: this runs before there is a window, before
/// the journal is open, and before anything else in the launch may proceed. There is no run loop
/// worth turning here and nothing else the app should be doing while it waits.
@MainActor
enum SingleInstanceTakeover {

    // MARK: - Types

    enum Outcome: Equatable {
        /// The heartbeat ticked while we waited. Nothing was signalled.
        case ownerRecovered
        /// The pid no longer means the process the card named. Nothing was signalled.
        case identityUnverified
        /// The lock is held by this process now. `escalated` says whether `SIGKILL` was needed,
        /// which is the difference between an app that unwound and one that had to be stopped.
        case acquired(escalated: Bool)
        /// Signalled, and the lock is still not free. The launch fails closed on this.
        case lockStillHeld
    }

    struct Actions {
        /// How old the heartbeat is *now*.
        var heartbeatAge: () -> TimeInterval?
        /// Blocks for two heartbeat periods, so a live-but-slow owner has a chance to beat.
        var waitForReprobe: () -> Void
        var probe: (pid_t) -> AgentChildProbe
        var signal: (pid_t, Int32) -> Void
        /// Polls for the lock for at most this long, and answers whether it is held now.
        var acquireLock: (TimeInterval) -> Bool
    }

    // MARK: - Public Methods

    static func run(owner card: SingleInstanceOwnerCard, actions: Actions) -> Outcome {
        actions.waitForReprobe()
        if !SingleInstanceHeartbeat.isStale(age: actions.heartbeatAge()) {
            return .ownerRecovered
        }

        let pid = pid_t(card.pid)
        switch actions.probe(pid) {
        case .running(let startTime) where startTime == card.startTime:
            break
        case .absent:
            // Already gone, so there is nothing to signal and possibly nothing holding the lock.
            // Signalling a pid that has since been handed out again is the one thing this must
            // never do, and "absent" is precisely the case where that would happen.
            return actions.acquireLock(SingleInstanceTakeoverDefaults.terminateGrace)
                ? .acquired(escalated: false)
                : .lockStillHeld
        default:
            return .identityUnverified
        }

        actions.signal(pid, SIGTERM)
        if actions.acquireLock(SingleInstanceTakeoverDefaults.terminateGrace) {
            return .acquired(escalated: false)
        }

        actions.signal(pid, SIGKILL)
        if actions.acquireLock(SingleInstanceTakeoverDefaults.killGrace) {
            return .acquired(escalated: true)
        }

        return .lockStillHeld
    }

    // MARK: - Releasing an Inherited Lock

    enum OrphanOutcome: Equatable {
        /// Nothing in the ledger still checks out, so nothing was signalled and nothing can be
        /// said about what is holding the lock.
        case nothingToEnd
        case acquired(ended: Int)
        case lockStillHeld(ended: Int)
    }

    /// Ends the processes a dead owner left holding its lock descriptor, and takes the lock.
    ///
    /// Reached from `Verdict.orphanedLockHolders`: the owner is verifiably gone and the `flock`
    /// is verifiably still held, which can only be a duplicate of its descriptor living on in a
    /// child it spawned. `O_CLOEXEC` on the lock stops that happening again; the children of a
    /// build that shipped without it survive the upgrade, so this is the way out for them.
    ///
    /// **Each candidate is verified on the identity pair the ledger recorded** — the sweep's own
    /// `verdict`, unchanged — because a pid from a crash hours ago may name anything now. A run
    /// that verifies nothing signals nothing.
    static func releaseOrphanedLock(
        records: [AgentChildRecord],
        probe: (pid_t) -> AgentChildProbe = OrphanedAgentChildSweep.liveProbe(of:),
        signalGroup: (pid_t) -> Void = OrphanedAgentChildSweep.killGroup(of:),
        acquireLock: (TimeInterval) -> Bool
    ) -> OrphanOutcome {
        var ended = 0
        for record in records
        where OrphanedAgentChildSweep.verdict(for: record, probe: probe(pid_t(record.pid)))
            == .kill {
            signalGroup(pid_t(record.pid))
            ended += 1
        }

        guard ended > 0 else { return .nothingToEnd }

        return acquireLock(SingleInstanceTakeoverDefaults.killGrace)
            ? .acquired(ended: ended)
            : .lockStillHeld(ended: ended)
    }

    /// The candidates a launch may offer to end: ledger records whose identity still checks out.
    ///
    /// Read separately from ending them so the alert can name what it is about to do. The list is
    /// re-verified inside `releaseOrphanedLock`, because the user reads before they answer.
    static func verifiedHolders(
        in records: [AgentChildRecord],
        probe: (pid_t) -> AgentChildProbe = OrphanedAgentChildSweep.liveProbe(of:)
    ) -> [AgentChildRecord] {
        records.filter {
            OrphanedAgentChildSweep.verdict(for: $0, probe: probe(pid_t($0.pid))) == .kill
        }
    }

    /// The real machine behind the closures.
    static var live: Actions {
        Actions(
            heartbeatAge: { SingleInstanceHeartbeat.age() },
            waitForReprobe: {
                Thread.sleep(forTimeInterval: SingleInstanceTakeoverDefaults.reprobeDelay)
            },
            probe: OrphanedAgentChildSweep.liveProbe(of:),
            signal: { pid, number in Darwin.kill(pid, number) },
            acquireLock: { pollForLock(upTo: $0) }
        )
    }

    /// Retries the ordinary acquire until it wins or the deadline passes.
    ///
    /// The ordinary acquire, not a private `flock` beside it: winning here has to leave the
    /// process holding the descriptor for its lifetime and having written its own owner card,
    /// which is exactly what a normal launch's acquire does. Blocking is correct at this point —
    /// there is no window, no run loop worth turning, and the user is waiting on one answer.
    ///
    /// It inherits the acquire's fail-open answer with it: a lock file that cannot be opened at
    /// all lets the launch through here exactly as it does at the top of one. That is the same
    /// judgment in both places — a permissions oddity must not brick the app — and the user has
    /// already agreed to end the other instance by the time this runs.
    static func pollForLock(
        at url: URL = SingleInstanceLock.lockFileURL,
        upTo seconds: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if SingleInstanceLock.acquire(at: url) { return true }
            Thread.sleep(forTimeInterval: SingleInstanceTakeoverDefaults.lockPollInterval)
        } while Date() < deadline
        return SingleInstanceLock.acquire(at: url)
    }
}

// MARK: - Single Instance Takeover Record

/// What a takeover ended, carried from where it happens to where the journal exists.
struct SingleInstanceTakeoverRecord: Equatable, Sendable {
    let pid: pid_t
    let bundlePath: String
    let staleness: TimeInterval
    let escalated: Bool
    /// How many of the dead owner's leftover children were ended to free the lock. Zero on the
    /// wedged-owner path, where the owner itself was the thing holding it.
    var endedChildren = 0

    /// The whole story in five fields. Built here rather than at the two call sites so it can be
    /// asserted without a launch: this record is the only durable trace of a Threading that was
    /// ended, and the launch that ends one has no window to say so in.
    var journalDetail: [String: String] {
        [
            SingleInstanceDefaults.ownerPIDField: String(pid),
            SingleInstanceDefaults.ownerPathField: bundlePath,
            SingleInstanceDefaults.stalenessField: String(Int(staleness.rounded())),
            SingleInstanceDefaults.escalatedField: escalated ? "yes" : "no",
            SingleInstanceDefaults.endedChildrenField: String(endedChildren)
        ]
    }
}

// MARK: - Single Instance Takeover Defaults

enum SingleInstanceTakeoverDefaults {
    /// Two heartbeat periods: one full period could be missed by a tick that was merely late.
    static let reprobeDelay: TimeInterval = SingleInstanceDefaults.heartbeatInterval * 2

    /// What a terminating app is given to close its store and drop the lock, and then what a
    /// killed one is given to be reaped. Both are the kernel's business rather than the app's,
    /// so they are short.
    static let terminateGrace: TimeInterval = 5
    static let killGrace: TimeInterval = 5

    static let lockPollInterval: TimeInterval = 0.1
}
