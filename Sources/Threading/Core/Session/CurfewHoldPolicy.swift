import Foundation

// MARK: - Curfew Hold

/// Whether one session's own curfew is holding it, and everything a refusal needs to say so.
///
/// The mirror of `CustomLimitHold`, and kept apart from it for the reason that type's own
/// documentation gives: two holds that meant subtly different things at four call sites would
/// print four subtly different sentences, and the user drew one line. What differs is *whose*
/// line it is — a custom limit is a statement about an account's spend, and a curfew is a
/// statement about one conversation's clock — so they are separate values rather than one with a
/// reason string.
///
/// The associated values are what the surfaces need and nothing more: `since` for the sentence,
/// the resolved curfew for the moment a stand-aside can re-arm to, and the session's own state
/// for the strip's ledger. Carrying them here means a caller never re-resolves and cannot
/// disagree with the decision it was just handed.
enum CurfewHold: Equatable, Sendable {

    /// No curfew resolves for this session, or its deadline has not arrived.
    case clear

    /// Threading has stopped spending this session on its own since `since`.
    ///
    /// `since` is the **deadline**, not the moment the hold was noticed. A hold that materialized
    /// on relaunch at 09:00 is still a hold that began at 04:00, and a sentence saying otherwise
    /// would describe the app's uptime rather than the user's curfew.
    case held(since: Date, curfew: ResolvedCurfew, state: SessionCurfewState?)

    var isHolding: Bool {
        if case .held = self { return true }
        return false
    }
}

// MARK: - Curfew Hold Policy

/// Whether one session is held by its curfew, resolved from the stores.
///
/// `CustomLimitParkPolicy`'s shape exactly: the decision itself is pure and takes the resolution's
/// answer, and this is the thin layer that finds the records and asks. Kept apart for the same two
/// reasons — every seam that needs the answer (the outbox's turn boundary, the scheduled send, the
/// control plane's admission, the strip) asks it the same way, and the pure half stays assertable
/// with no database and no preferences suite.
///
/// **One question, asked of the clock.** A hold is not a stored flag: it is `now >= deadline`
/// against whatever `CurfewResolution` answers right now. So lifting a curfew, moving the standing
/// window, or a quiet-hours window simply ending all release the session on the next read, with
/// nothing to migrate and no state to have gone stale while the app was quit.
@MainActor
enum CurfewHoldPolicy {

    // MARK: - The Decision

    /// Whether this answer holds at `now`.
    ///
    /// Pure, and deliberately small: a curfew resolves, its deadline has passed, and — for a
    /// standing quiet-hours instance — its window has not closed yet.
    ///
    /// **Two lifts need no check here, and that is by construction.** A lifted quiet-hours
    /// instance is already answered as *no curfew* by `CurfewResolution`, which reads the state's
    /// `liftedAt` against the window it belongs to; and a lifted one-shot has had its own
    /// `.until` rule cleared off the record, so there is nothing left to resolve. Re-testing
    /// `liftedAt` here would therefore be either redundant or wrong: a `liftedAt` left over from
    /// a *previous* instance must not release the deadline the session is under now.
    static func hold(
        answer: CurfewResolution.Answer,
        state: SessionCurfewState?,
        at now: Date
    ) -> CurfewHold {
        guard let curfew = answer.curfew, now >= curfew.deadline else { return .clear }

        // A standing window ends by itself. Ordinarily the resolution has already moved on to
        // tomorrow's window by this point — its deadline is then in the future and the guard
        // above answers — but the check is stated rather than inferred, because "held" and "the
        // window is over" must never be able to disagree about the same instant.
        if let endsAt = curfew.endsAt, now >= endsAt { return .clear }

        return .held(since: curfew.deadline, curfew: curfew, state: state)
    }

    // MARK: - Reading The Records

    /// The curfew holding this session, or `.clear`.
    ///
    /// The store is a parameter for `CurfewResolution`'s reason: merely touching
    /// `ProjectStore.shared` in a test loads the real database, and a surface built against
    /// another store must ask that one.
    static func hold(
        sessionID: SessionID,
        in store: ProjectStore = .shared,
        at now: Date = Date()
    ) -> CurfewHold {
        hold(
            answer: CurfewResolution.answer(forSessionID: sessionID, in: store, now: now),
            state: store.session(withID: sessionID)?.curfewState,
            at: now
        )
    }

    static func isHeld(
        sessionID: SessionID,
        in store: ProjectStore = .shared,
        at now: Date = Date()
    ) -> Bool {
        hold(sessionID: sessionID, in: store, at: now).isHolding
    }

    /// The one sentence every refusing consumer prints, or nil when nothing is holding.
    ///
    /// Single-sourced through `CurfewReceiptWords` so a scheduled send's receipt, a control-plane
    /// refusal and the strip all say the same thing in the same words — the difference between a
    /// user reading one fact three times and reading three facts.
    static func holdReason(
        sessionID: SessionID,
        in store: ProjectStore = .shared,
        at now: Date = Date()
    ) -> String? {
        guard case .held(let since, _, _) = hold(sessionID: sessionID, in: store, at: now) else {
            return nil
        }
        return CurfewReceiptWords.holdReason(since: since)
    }
}

// MARK: - Curfew Stand Aside

/// What a due scheduled send should do about the curfew on its target.
///
/// Split out of `SessionCoordinator+ScheduledMessages` so the *decision* can be asserted without
/// a window, a sidebar and a live store, while the coordinator keeps the *performance* — the
/// store writes and the journal line. The same division `CustomLimitBounds.hold` and
/// `standAsideForCustomLimit` already have, arrived at here for the more pressing reason: this
/// rule fires while nobody is watching, and its three answers are three different things to have
/// done to somebody's message overnight.
enum CurfewStandAside: Equatable, Sendable {

    /// Nothing is holding, or this send is exempt. Hand it on to the next guard.
    case deliver

    /// The hold ends by itself, so the send is re-armed for that moment rather than left waiting.
    ///
    /// Only a standing quiet-hours window has an end the app can name. **Not counted as a rearm**:
    /// `resetRearmCount` bounds how many times a *usage window* may defer a message, which exists
    /// because a reset can slip repeatedly and a message must not be deferred forever. A quiet
    /// window's end is a wall-clock fact the user chose, it arrives once, and spending the reset
    /// budget on it would let a night of quiet hours cancel a send aimed at a reset days away.
    case rescheduleTo(Date)

    /// The hold has no end but the user's own hand, so the send waits and says why.
    case waitUntilLifted(String)

    /// Pure. `hold` is the target's, already resolved by the caller.
    static func decide(
        message: ScheduledMessage,
        hold: CurfewHold,
        now: Date
    ) -> CurfewStandAside {
        // The wrap-up is the one message a curfew's own hold lets through: it is what buys an
        // interrupted agent the single turn it needs to commit what is safe and write its
        // handoff note. Held first, before the hold is even read, because it is exempt by what
        // it is rather than by what the clock says.
        guard message.purpose != .curfewWindDown else { return .deliver }
        guard case .held(let since, let curfew, _) = hold else { return .deliver }

        // Only a clock-triggered send can be moved: `rescheduled(to:)` answers with the record
        // unchanged for a finish trigger, and writing that back would look like a re-arm while
        // leaving the send pinned to an edge that may never come again. A finish-triggered send
        // waits instead, and the scheduler re-offers it when the curfew lifts.
        if let endsAt = curfew.endsAt, endsAt > now, message.trigger.time != nil {
            return .rescheduleTo(endsAt)
        }
        return .waitUntilLifted(CurfewReceiptWords.holdReason(since: since))
    }
}
