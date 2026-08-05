import Foundation

/// Which session rows are showing a spinner, and *why* each one is.
///
/// The reason is the whole point. A row's spinner had two independent owners writing one
/// boolean: the sidebar raised it when a row was selected, and the window raised it while a
/// checkout summary or a review pane read itself. Neither could see the other's, so the
/// selection spinner had no end of its own — it was cleared only as a side effect of a *git*
/// load finishing for the session that happened to be on screen. A session selected in a
/// checkout that reported nothing afterwards span for the rest of the app's life.
///
/// Reasons make each owner responsible for ending what it started, and make "who is still
/// holding this spinner" a question with an answer.
///
/// **A raise also expires.** Reasons fixed the owners overwriting each other, and then an
/// owner's lower was simply dropped: the checkout card's "done loading" rode a monitor that
/// died with the selection, so switching sessions before the first git read landed left that
/// row spinning for the rest of the app's life — the original bug back, one level up. The
/// owners that leaked are fixed, but nothing guarantees the next raiser's lower arrives
/// either, so every raise now remembers when it was made and `lowerExpired` ends the ones
/// nobody lowered. Expiry is a backstop, not the mechanism: it is generous enough that no
/// real load meets it, and the caller logs every raise it has to take, because each one is a
/// raiser that dropped its lower. Being wrong costs a spinner vanishing early on a very slow
/// load; the other direction was a spinner that never stopped.
struct SessionLoadingState {

    /// Why a row is spinning. The raw value is the spelling logs use.
    enum Reason: String, Hashable {
        /// The sidebar is putting this session on screen.
        case presentation
        /// The checkout chrome above the pane is resolving.
        case gitStatus
        /// The review tab is reading the diff.
        case gitReview
    }

    private var raises: [SessionID: [Reason: Date]] = [:]

    // MARK: - Reading

    func isLoading(_ sessionID: SessionID) -> Bool {
        raises[sessionID] != nil
    }

    func reasons(for sessionID: SessionID) -> Set<Reason> {
        guard let held = raises[sessionID] else { return [] }
        return Set(held.keys)
    }

    var loadingSessions: Set<SessionID> {
        Set(raises.keys)
    }

    /// Whether any row is spinning at all — what decides if the expiry sweep needs to run.
    var isEmpty: Bool {
        raises.isEmpty
    }

    // MARK: - Writing

    /// Raises or lowers one reason, returning every session whose row changed.
    ///
    /// Only one session is presented at a time, so raising `.presentation` lowers every other
    /// session's — a row abandoned mid-presentation is no longer being presented, and nothing
    /// else was ever going to say so.
    ///
    /// Re-raising a held reason renews it: the owner just said the load is still real, so its
    /// expiry clock starts over.
    @discardableResult
    mutating func set(
        _ isLoading: Bool,
        reason: Reason,
        for sessionID: SessionID,
        at now: Date = Date()
    ) -> Set<SessionID> {
        var affected: Set<SessionID> = []

        if isLoading {
            if reason == .presentation {
                for other in raises.keys where other != sessionID {
                    if remove(.presentation, from: other) { affected.insert(other) }
                }
            }
            let wasSpinning = raises[sessionID] != nil
            raises[sessionID, default: [:]][reason] = now
            if !wasSpinning { affected.insert(sessionID) }
        } else if remove(reason, from: sessionID) {
            affected.insert(sessionID)
        }

        return affected
    }

    /// Lowers every raise older than the cutoff, returning each one so the caller can log it —
    /// an expiry taken is a raiser that dropped its lower, which is a bug worth a record.
    ///
    /// Rows to refresh are the returned sessions; refreshing one another reason still holds
    /// costs a reconfigure and draws the same spinner.
    @discardableResult
    mutating func lowerExpired(
        raisedBefore cutoff: Date
    ) -> [(sessionID: SessionID, reason: Reason)] {
        var expired: [(sessionID: SessionID, reason: Reason)] = []

        for (sessionID, held) in raises {
            for (reason, raisedAt) in held where raisedAt < cutoff {
                expired.append((sessionID, reason))
                remove(reason, from: sessionID)
            }
        }

        return expired
    }

    /// Drops every reason for a session — used when the row itself goes away, where the owners
    /// that raised them no longer have anything to lower.
    @discardableResult
    mutating func clear(_ sessionID: SessionID) -> Bool {
        raises.removeValue(forKey: sessionID) != nil
    }

    /// Removes one reason, reporting whether the row's *spinner* changed rather than whether
    /// the set did: a row holding two reasons keeps spinning when one of them ends.
    @discardableResult
    private mutating func remove(_ reason: Reason, from sessionID: SessionID) -> Bool {
        guard var current = raises[sessionID],
              current.removeValue(forKey: reason) != nil else { return false }

        if current.isEmpty {
            raises.removeValue(forKey: sessionID)
            return true
        }
        raises[sessionID] = current
        return false
    }
}

// MARK: - Session Loading Defaults

enum SessionLoadingDefaults {
    /// How long a raise may go unlowered before the sweep takes it. Generous on purpose: the
    /// slowest legitimate load here — a review diff over a huge working tree — finishes well
    /// inside it, and an expiry firing means some owner leaked, not that a load is slow.
    static let maxHold: TimeInterval = 30

    /// How often the sweep looks, while anything is spinning at all.
    static let sweepInterval: TimeInterval = 5
}
