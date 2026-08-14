import Darwin
import Foundation

/// Stops one process an info-panel row points at — and nothing else.
///
/// It follows the live-children ledger's grammar (`docs/architecture/sessions.md`): the pid is
/// never enough, so a kill is authorised only by an exact match of pid **and** the kernel's
/// start identity, everything else fails closed, and every outcome — the refusals included —
/// is journalled to `EventLog`.
///
/// Two deliberate differences from the post-crash sweep it borrows the grammar from:
///
/// - **A single pid, never the group.** A session's whole tree shares the agent's process
///   group, so `kill(-pid, …)` from a row would take the session down — the one thing this
///   panel's action must not be able to do. Teardown owns groups.
/// - **SIGTERM, never SIGKILL.** The user is stopping a dev server they can see, not sweeping
///   corpses after a crash; a process that traps SIGTERM and stays is a fact the next poll
///   shows honestly. SIGKILL stays the sweep's.
enum SessionProcessTerminator {

    // MARK: - Types

    enum Outcome: Equatable {
        case terminated
        case skipped(SkipReason)
    }

    /// Every way the answer is "do nothing". They journal distinctly because "it was already
    /// gone" and "the pid means somebody else now" are different facts about the machine.
    enum SkipReason: String {
        case identityUnreadable
        case identityMismatch
        case signalFailed
    }

    // MARK: - Public Methods

    /// Sends SIGTERM to `pid` if — and only if — the kernel still reports the start identity
    /// the caller captured when the row was read.
    @discardableResult
    static func terminate(
        pid: pid_t,
        expectedStart: ProcessStartTime,
        journal: EventLog = .shared,
        currentStart: (pid_t) -> ProcessStartTime? = ProcessUtility.startTime(forPid:),
        signal: (pid_t) -> Int32 = { Darwin.kill($0, SIGTERM) }
    ) -> Outcome {
        let outcome = decide(
            pid: pid,
            expectedStart: expectedStart,
            currentStart: currentStart,
            signal: signal
        )

        var fields = [
            SessionProcessTerminatorDefaults.pidField: String(pid),
            SessionProcessTerminatorDefaults.startField:
                "\(expectedStart.seconds).\(expectedStart.microseconds)"
        ]
        switch outcome {
        case .terminated:
            journal.record(.session, SessionProcessTerminatorDefaults.terminatedMessage, fields)
        case .skipped(let reason):
            fields[SessionProcessTerminatorDefaults.reasonField] = reason.rawValue
            journal.record(.session, SessionProcessTerminatorDefaults.skippedMessage, fields)
        }

        return outcome
    }

    // MARK: - Private Methods

    private static func decide(
        pid: pid_t,
        expectedStart: ProcessStartTime,
        currentStart: (pid_t) -> ProcessStartTime?,
        signal: (pid_t) -> Int32
    ) -> Outcome {
        // Gone, a zombie, or unreadable — all the same answer, which is to do nothing.
        guard let current = currentStart(pid) else { return .skipped(.identityUnreadable) }
        guard current == expectedStart else { return .skipped(.identityMismatch) }
        guard signal(pid) == 0 else { return .skipped(.signalFailed) }
        return .terminated
    }
}

// MARK: - Defaults

enum SessionProcessTerminatorDefaults {
    static let terminatedMessage = "Stopped a session process at the user's request"
    static let skippedMessage = "Declined to stop a session process"
    static let pidField = "pid"
    static let startField = "start"
    static let reasonField = "reason"
}
