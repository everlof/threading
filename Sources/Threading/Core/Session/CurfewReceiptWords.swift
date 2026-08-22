import Foundation

// MARK: - Curfew Receipt Words

/// Every sentence the curfew prints — in the strip, in a row's mark, in a refusal, in the
/// message it sends the agent and in the alert it posts when it gives up.
///
/// Separate from the resolution chain and from the engine on purpose, the way
/// `CustomLimitReceipt` is separate from `CustomLimitEvaluator`: the judgement stays free of
/// `L10n` and testable on its answer rather than on this month's wording, and the wording stays
/// assertable with no notification center and no live session.
///
/// **A curfew never speaks as the provider.** Every sentence here says the user's own line —
/// *your* curfew, at *your* time — and borrows none of the vocabulary a real rate-limit refusal
/// uses. Conflating the two would teach the reader that the provider's refusals are sometimes
/// negotiable, and that this one is not liftable when it is the one thing here that always is.
enum CurfewReceiptWords {

    // MARK: - Holds

    /// The one sentence a hold prints: why nothing is being sent, in terms of a decision the
    /// reader made themselves.
    static func holdReason(since: Date, locale: Locale = .current) -> String {
        L10n.format(
            "This session has been under a curfew since %@, so Threading is not spending it on its own.",
            ScheduledTimePresets.time(since, locale: locale),
            locale: locale
        )
    }

    // MARK: - The Strip

    /// What happened to this session, in the order it happened, on one line.
    ///
    /// Clauses rather than sentences, joined by `CurfewDefaults.receiptSeparator`, because this
    /// is read the morning after as a ledger — "Curfew since 04:00 · wrap-up sent 03:50 ·
    /// interrupted 04:05 ×2" answers *what did you do to my session* faster than three sentences
    /// would.
    ///
    /// `canTellWorking` is the honest half. Where Threading cannot see whether a turn is in
    /// flight — a runtime that reports no turns, a terminal whose CLI does not take Escape — the
    /// curfew still holds, but it never types, and the line says so rather than implying a fence
    /// that is not there.
    static func stripSentence(
        curfew: ResolvedCurfew,
        state: SessionCurfewState?,
        canTellWorking: Bool,
        locale: Locale = .current,
        now: Date
    ) -> String {
        let time = ScheduledTimePresets.time(curfew.deadline, locale: locale)
        // Two tenses, because a fence that has not closed yet and one that has are different
        // news. The strip names the curfew itself; the row's mark below leads with the *hold*,
        // which is the louder half where a row has one line and a session looks idle.
        var clauses: [String] = [
            now >= curfew.deadline
                ? L10n.format("Curfew since %@", time, locale: locale)
                : L10n.format("Curfew at %@", time, locale: locale)
        ]

        if let sentAt = state?.momentOf(.windDownSent) {
            clauses.append(
                L10n.format(
                    "wrap-up sent %@",
                    ScheduledTimePresets.time(sentAt, locale: locale),
                    locale: locale
                )
            )
        }

        if let state, state.interruptCount > 0, let lastInterruptAt = state.lastInterruptAt {
            clauses.append(
                L10n.format(
                    "interrupted %1$@ ×%2$lld",
                    ScheduledTimePresets.time(lastInterruptAt, locale: locale),
                    Int64(state.interruptCount),
                    locale: locale
                )
            )
        }

        // The give-up is last and stated plainly: the curfew stopped trying, and what happens
        // next is the user's to decide. A line that ended at "interrupted ×3" would read as a
        // fence that held.
        if let state, state.gaveUpAt != nil {
            clauses.append(
                L10n.format(
                    "kept working after %lld interrupts",
                    Int64(state.interruptCount),
                    locale: locale
                )
            )
        }

        if !canTellWorking {
            clauses.append(
                L10n.string(
                    "Threading cannot tell whether this session is working, so it only stops delivering messages."
                )
            )
        }

        return clauses.joined(separator: CurfewDefaults.receiptSeparator)
    }

    // MARK: - Conduct

    /// The line a row and the session popover carry: what this session is *doing*, rather than
    /// what is happening to it.
    ///
    /// Held comes first and louder than armed, because a held session looks idle and is not:
    /// nothing is being sent to it, and the reader is owed the reason before they go looking for
    /// one. An exemption is worth a line only where a standing window would otherwise apply —
    /// "Exempt from quiet hours" on a machine with no quiet hours names a rule nobody set.
    static func conductStatement(
        curfew: ResolvedCurfew?,
        isExempt: Bool,
        now: Date,
        locale: Locale = .current
    ) -> String? {
        guard let curfew else {
            return isExempt ? L10n.string("Exempt from quiet hours") : nil
        }
        let time = ScheduledTimePresets.time(curfew.deadline, locale: locale)
        guard now >= curfew.deadline else {
            return L10n.format("Curfew at %@", time, locale: locale)
        }
        return L10n.format("Held by curfew since %@", time, locale: locale)
    }

    // MARK: - The Wrap-Up

    /// The wrap-up as the agent receives it, with the placeholder replaced by the curfew's own
    /// time in the user's clock convention.
    ///
    /// Substitution rather than a format string: the template is a user-editable message, and a
    /// `%@` somebody typed by accident — or a literal percent in a sentence about usage — would
    /// turn a message into a crash or into garbage. `{time}` is text that means nothing to
    /// `String(format:)`.
    static func windDownText(
        template: String,
        deadline: Date,
        locale: Locale = .current
    ) -> String {
        template.replacingOccurrences(
            of: CurfewDefaults.timePlaceholder,
            with: ScheduledTimePresets.time(deadline, locale: locale)
        )
    }

    /// Why a wrap-up that was never delivered is being failed rather than sent late.
    ///
    /// A wrap-up arriving at nine in the morning would ask an agent to stop work it is not
    /// doing, in a conversation whose owner is reading it — and would spend a turn to do it. The
    /// record fails instead, and the sentence says which of the two things went wrong.
    static var windDownFailureReason: String {
        L10n.string("Its curfew passed before the session was free.")
    }

    /// The other way a wrap-up misses its window: the app was not running to send it. Stated as
    /// a fact about Threading rather than about the session, because nothing was wrong with the
    /// session.
    static var notRunningFailureReason: String {
        L10n.string("Threading was not running.")
    }

    // MARK: - Giving Up

    /// The alert body when a session keeps starting turns after every interrupt it was given.
    ///
    /// Actionable rather than informational: it names the count so the reader can tell a loop
    /// that ignored one interrupt from one that ignored three, and the alert it belongs to opens
    /// the session, where the strip offers Lift.
    static func gaveUpAlertBody(count: Int) -> String {
        L10n.format("Kept working after %lld interrupts", Int64(count))
    }
}
