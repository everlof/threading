import Foundation

// MARK: - Mail Stop Continuation Ledger

/// Keeps a terminal session's activity honest when a mail notice blocks its `Stop`.
///
/// The answering mail hook (`/mail-notice/…?event=stop`) may return `decision: "block"` once per
/// unread message, and both Claude Code and Codex then **continue the same turn** — Codex was
/// measured firing `Stop` twice with one `turn_id`. The silent lifecycle `Stop` hook beside it
/// knows nothing of that and reports a finished turn for the first `Stop` too. Relayed as it
/// stands, the tracker would show a working agent as idle, and the control plane would then type
/// a delivery into a turn that is still running — the exact hazard `.busyTerminal` exists for.
///
/// The two hooks race, so the ledger handles both orders:
///
/// - **Block first** (the usual order — the lifecycle report waits on a git checkpoint): the
///   next finished-turn report is held rather than relayed. Any mail-hook call from the session
///   afterwards is evidence the turn went on (the block's reason tells the agent to call
///   `mail_inbox`, which fires `PostToolUse`; a second `Stop` calls the hook again), and the held
///   report is dropped. With no evidence within `evidenceWindow`, the held report is relayed
///   after all — a block the agent never saw (a hook that timed out) must not leave a session
///   spinning.
/// - **Finish first**: the block arrives within `finishWindow` of a relayed finish, and the
///   caller reopens the turn with a synthesized start.
///
/// Bounded: at most one entry per session, removed when it resolves or expires.
@MainActor
enum MailStopContinuationLedger {

    // MARK: - Types

    enum BlockOutcome: Equatable {
        /// The finish has not been relayed yet; it will be held.
        case holdNextFinish
        /// The finish was already relayed; reopen the turn.
        case reopenTurn
    }

    private struct Entry {
        let blockedAt: Date
        /// The host's clock at the block, when a host-local hook reported it.
        var blockHostTime: UInt64?
        var sawEvidence = false
        var held: HookLifecycleReport?
        var generation: Int
    }

    // MARK: - Properties

    static let finishWindow: TimeInterval = 10
    static let holdWindow: TimeInterval = 30
    static let evidenceWindow: TimeInterval = 20

    private static var entries: [SessionID: Entry] = [:]
    private static var lastRelayedFinish: [SessionID: Date] = [:]
    private static var generation = 0

    /// How a held report is relayed when no evidence arrives. Injected for tests.
    static var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }

    // MARK: - Public Methods

    /// Records that the mail hook blocked a `Stop` for this session.
    static func recordBlock(_ sessionID: SessionID, now: Date = Date(), hostTime: UInt64? = nil) -> BlockOutcome {
        if let finished = lastRelayedFinish[sessionID], now.timeIntervalSince(finished) <= finishWindow {
            lastRelayedFinish[sessionID] = nil
            entries[sessionID] = nil
            return .reopenTurn
        }
        generation += 1
        entries[sessionID] = Entry(blockedAt: now, blockHostTime: hostTime, generation: generation)
        return .holdNextFinish
    }

    /// A turn reported its own start: the finish remembered for "finish first" belonged to the
    /// turn before, so a block from here on is in a turn whose finish has not been relayed yet.
    static func recordTurnStarted(_ sessionID: SessionID) {
        lastRelayedFinish[sessionID] = nil
    }

    /// Any mail-hook call from the session: the agent is still running its turn.
    ///
    /// A host-local hook reports in the background, so its report can arrive after a later
    /// block. Stamped by the same host's clock as that block, one that fired before it is not
    /// evidence of anything after it.
    static func recordEvidence(_ sessionID: SessionID, hostTime: UInt64? = nil) {
        guard var entry = entries[sessionID] else { return }
        if let blockedAt = entry.blockHostTime, let hostTime, hostTime <= blockedAt { return }
        if entry.held != nil {
            // The turn went on after the stop the lifecycle hook reported; that report is void.
            entries[sessionID] = nil
            return
        }
        entry.sawEvidence = true
        entries[sessionID] = entry
    }

    /// Whether a finished-turn report should be withheld from the tracker. When it is, the
    /// ledger owns it and relays it through `relay` if the turn turns out to have ended after all.
    static func absorbsFinish(
        _ report: HookLifecycleReport,
        now: Date = Date(),
        relay: @escaping @MainActor (HookLifecycleReport) -> Void
    ) -> Bool {
        let sessionID = report.sessionID
        guard var entry = entries[sessionID], entry.held == nil else {
            lastRelayedFinish[sessionID] = now
            return false
        }
        guard now.timeIntervalSince(entry.blockedAt) <= holdWindow else {
            entries[sessionID] = nil
            lastRelayedFinish[sessionID] = now
            return false
        }
        if entry.sawEvidence {
            entries[sessionID] = nil
            return true
        }
        entry.held = report
        entries[sessionID] = entry
        let expected = entry.generation
        schedule(evidenceWindow) {
            guard let current = entries[sessionID], current.generation == expected,
                  let held = current.held else { return }
            entries[sessionID] = nil
            lastRelayedFinish[sessionID] = Date()
            relay(held)
        }
        return true
    }

    /// Forgets everything. Tests only.
    static func reset() {
        entries.removeAll()
        lastRelayedFinish.removeAll()
    }
}
