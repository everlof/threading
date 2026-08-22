import AppKit

// MARK: - Drawing A Standing Refusal

/// Turns the stored refusal into what the strip draws.
///
/// One place rather than one per host. Both composers — a terminal pane's, a rendered
/// conversation's — showed the same strip from the same store through their own copy of this
/// mapping, which is fine while there is one field to copy and a slow drift the moment there are
/// five. The strip deliberately does not take the model itself (`LimitEscapeStripView.Offer`
/// says why: a view holding it would have to decide which of its states are the user's
/// business), so the decision lives here, above both.
extension LimitEscapeStripView.Offer {

    /// What a surface should draw for one session's standing refusal.
    ///
    /// The wait is offered unless a continuation is already owed — asked of the same predicate
    /// the arm itself guards on, so the button cannot offer what the code behind it would
    /// decline. A refusal with neither answer left still draws: the sentence is the point, and
    /// a session that stopped without explanation is the bug this whole strip exists to fix.
    @MainActor
    init(_ suggestion: LimitEscapeSuggestion) {
        self.init(
            accountName: suggestion.accountName,
            reading: suggestion.reading,
            offersWaitForReset: !LimitRecoveryCoordinator.hasOwedContinuation(
                for: suggestion.sessionID
            ),
            resetHint: suggestion.resetHint,
            problem: suggestion.problem,
            busy: suggestion.busy
        )
    }

    /// What a surface should draw for one session held by its own curfew.
    ///
    /// The line is written by `CurfewReceiptWords` and handed over whole: it is a ledger read
    /// against a clock, and the two hosts must not each assemble their own. Neither answer the
    /// refusal path carries applies — there is no login to move to and no window to wait for,
    /// because nothing about the provider has stopped this — so this states the one it does have.
    static func curfew(line: String) -> Self {
        LimitEscapeStripView.Offer(source: .curfew, curfewLine: line)
    }
}
