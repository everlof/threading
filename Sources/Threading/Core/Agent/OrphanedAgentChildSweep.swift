import Darwin
import Foundation

// MARK: - Agent Child Probe

/// What the machine says about a pid the ledger names.
///
/// Three answers rather than two, because "there is no such process" and "there is one but its
/// identity could not be read" lead to the same action for opposite reasons, and a journal that
/// cannot tell them apart cannot say whether a sweep found nothing or gave up.
enum AgentChildProbe: Equatable {
    case absent
    case running(ProcessStartTime)
    case unreadable
}

// MARK: - Orphaned Agent Child Sweep

/// Ends the native agent children a previous launch left behind.
///
/// The ledger records a child on spawn and forgets it on reap, so a clean quit leaves the file
/// empty and anything still in it belongs to a launch that died. Those children reparent to
/// launchd: alive, unowned, holding a model conversation open and burning quota, with nothing
/// on screen to say so.
///
/// **A pid alone is never acted on.** Pids are handed out again, so a record from a crash three
/// days ago may name a browser now. The decision therefore rests on the pid *and* the kernel's
/// own start timestamp for it, recorded when the child was spawned. Everything else — a
/// mismatch, an unreadable identity, a process that has already gone — is a refusal, and every
/// refusal is journalled, because a sweep that silently does nothing is indistinguishable from
/// one that is broken.
enum OrphanedAgentChildSweep {

    // MARK: - Types

    enum Verdict: Equatable {
        case kill
        case skip(SkipReason)
    }

    /// Journalled verbatim, so the reason a process survived a sweep is legible afterwards.
    enum SkipReason: String {
        case processGone
        case startTimeMismatch
        case identityUnreadable
    }

    struct Summary: Equatable {
        var inspected = 0
        var killed = 0
        var skipped = 0
        /// The ledger existed and could not be read. Distinct from an empty one: nothing was
        /// swept, and nothing can be said about what was running.
        var ledgerWasUnreadable = false
    }

    // MARK: - Decision

    /// The whole rule, separated from the killing so it can be tested without one.
    ///
    /// Fail closed: only an exact match on both halves of the identity authorises a signal.
    static func verdict(for record: AgentChildRecord, probe: AgentChildProbe) -> Verdict {
        switch probe {
        case .absent:
            return .skip(.processGone)
        case .unreadable:
            return .skip(.identityUnreadable)
        case .running(let startTime):
            return startTime == record.startTime ? .kill : .skip(.startTimeMismatch)
        }
    }

    // MARK: - Public Methods

    /// Runs the sweep once, and empties the ledger whether or not anything was killed.
    ///
    /// Synchronous, and called before this launch can start a conversation of its own: the
    /// records name pids, and a pid is only unambiguous for as long as nothing new has been
    /// spawned. It is bounded by the ledger's own record budget, so "once at launch" costs a
    /// file read and at most that many `proc_pidinfo` calls.
    @discardableResult
    static func run(
        ledger: AgentChildLedger = .shared,
        probe: (pid_t) -> AgentChildProbe = liveProbe(of:),
        signalGroup: (pid_t) -> Void = killGroup(of:),
        journal: EventLog = .shared
    ) -> Summary {
        var summary = Summary()

        let outcome = ledger.consumeInheritedRecords()
        if case .unreadable = outcome {
            summary.ledgerWasUnreadable = true
            journal.record(.session, OrphanedAgentChildSweepDefaults.unreadableLedgerMessage)
            return summary
        }

        let records = outcome.value
        guard !records.isEmpty else { return summary }

        for record in records {
            summary.inspected += 1
            switch verdict(for: record, probe: probe(pid_t(record.pid))) {
            case .kill:
                signalGroup(pid_t(record.pid))
                summary.killed += 1
                journal.record(
                    .session,
                    OrphanedAgentChildSweepDefaults.killedMessage,
                    detail(for: record)
                )
            case .skip(let reason):
                summary.skipped += 1
                var fields = detail(for: record)
                fields[OrphanedAgentChildSweepDefaults.reasonField] = reason.rawValue
                journal.record(
                    .session,
                    OrphanedAgentChildSweepDefaults.skippedMessage,
                    fields
                )
            }
        }

        journal.record(.session, OrphanedAgentChildSweepDefaults.summaryMessage, [
            OrphanedAgentChildSweepDefaults.inspectedField: String(summary.inspected),
            OrphanedAgentChildSweepDefaults.killedField: String(summary.killed),
            OrphanedAgentChildSweepDefaults.skippedField: String(summary.skipped)
        ])

        return summary
    }

    /// Asks the machine about a pid.
    ///
    /// Existence is checked with `kill(pid, 0)` rather than a second `proc_pidinfo`, because the
    /// point of the third answer is to use a *different* mechanism: if the first one fails, the
    /// second must not fail identically and turn "cannot read" into "gone".
    static func liveProbe(of pid: pid_t) -> AgentChildProbe {
        guard pid > 0 else { return .absent }
        if let startTime = ProcessUtility.startTime(forPid: pid) {
            return .running(startTime)
        }
        return exists(pid) ? .unreadable : .absent
    }

    /// Ends a verified orphan's whole group.
    ///
    /// `SIGKILL` rather than a term-then-kill escalation, which every other teardown path here
    /// uses. The grace period a `SIGTERM` buys has already elapsed — however long ago the app
    /// died, this child's stdin reached end-of-file then and it did not take the hint — and a
    /// deferred escalation would have to signal a group id whose leader may have been reaped in
    /// between, which is the pid reuse this whole design exists to avoid.
    static func killGroup(of pid: pid_t) {
        Darwin.kill(-pid, SIGKILL)
    }

    // MARK: - Private Methods

    private static func exists(_ pid: pid_t) -> Bool {
        guard Darwin.kill(pid, OrphanedAgentChildSweepDefaults.existenceProbeSignal) != 0 else {
            return true
        }
        // Owned by another user: it exists, and it is emphatically not ours to signal.
        return errno == EPERM
    }

    private static func detail(for record: AgentChildRecord) -> [String: String] {
        var fields = [
            OrphanedAgentChildSweepDefaults.pidField: String(record.pid),
            OrphanedAgentChildSweepDefaults.agentField: record.executable
        ]
        if let sessionID = record.sessionID {
            fields[OrphanedAgentChildSweepDefaults.sessionField] = sessionID
        }
        return fields
    }
}

// MARK: - Orphaned Agent Child Sweep Defaults

enum OrphanedAgentChildSweepDefaults {
    /// `kill`'s "check, do not signal" signal number.
    static let existenceProbeSignal: Int32 = 0

    static let killedMessage = "Ended an orphaned agent process group"
    static let skippedMessage = "Left an orphaned agent record alone"
    static let summaryMessage = "Swept the agent children of the previous launch"
    static let unreadableLedgerMessage =
        "Live-children ledger was unreadable; no agent children were swept"

    static let pidField = "pid"
    static let sessionField = "session"
    static let agentField = "agent"
    static let reasonField = "reason"
    static let inspectedField = "inspected"
    static let killedField = "killed"
    static let skippedField = "skipped"
}
