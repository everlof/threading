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
/// Held apart from the view for the reason `ConversationMinimap` and `CodeStatsBar` are: the
/// invariant worth protecting — *every* raise can be lowered by the owner that made it, and a
/// presentation ends whatever the previous one left behind — is a property of the bookkeeping,
/// not of the drawing, and standing up an outline view to check it is how it went untested.
struct SessionLoadingState {

    /// Why a row is spinning.
    enum Reason: Hashable {
        /// The sidebar is putting this session on screen.
        case presentation
        /// The checkout chrome above the pane is resolving.
        case gitStatus
        /// The review tab is reading the diff.
        case gitReview
    }

    private var reasons: [SessionID: Set<Reason>] = [:]

    // MARK: - Reading

    func isLoading(_ sessionID: SessionID) -> Bool {
        reasons[sessionID] != nil
    }

    func reasons(for sessionID: SessionID) -> Set<Reason> {
        reasons[sessionID] ?? []
    }

    var loadingSessions: Set<SessionID> {
        Set(reasons.keys)
    }

    // MARK: - Writing

    /// Raises or lowers one reason, returning every session whose row changed.
    ///
    /// Only one session is presented at a time, so raising `.presentation` lowers every other
    /// session's — a row abandoned mid-presentation is no longer being presented, and nothing
    /// else was ever going to say so.
    @discardableResult
    mutating func set(
        _ isLoading: Bool,
        reason: Reason,
        for sessionID: SessionID
    ) -> Set<SessionID> {
        var affected: Set<SessionID> = []

        if isLoading {
            if reason == .presentation {
                for other in reasons.keys where other != sessionID {
                    if remove(.presentation, from: other) { affected.insert(other) }
                }
            }
            let wasSpinning = reasons[sessionID] != nil
            reasons[sessionID, default: []].insert(reason)
            if !wasSpinning { affected.insert(sessionID) }
        } else if remove(reason, from: sessionID) {
            affected.insert(sessionID)
        }

        return affected
    }

    /// Drops every reason for a session — used when the row itself goes away, where the owners
    /// that raised them no longer have anything to lower.
    @discardableResult
    mutating func clear(_ sessionID: SessionID) -> Bool {
        reasons.removeValue(forKey: sessionID) != nil
    }

    /// Removes one reason, reporting whether the row's *spinner* changed rather than whether
    /// the set did: a row holding two reasons keeps spinning when one of them ends.
    private mutating func remove(_ reason: Reason, from sessionID: SessionID) -> Bool {
        guard var current = reasons[sessionID], current.remove(reason) != nil else { return false }

        if current.isEmpty {
            reasons.removeValue(forKey: sessionID)
            return true
        }
        reasons[sessionID] = current
        return false
    }
}
