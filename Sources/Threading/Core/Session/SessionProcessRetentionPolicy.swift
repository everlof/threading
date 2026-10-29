import Foundation

// MARK: - Policy

/// One live conversation as the process-retention policy sees it.
///
/// Every field is an already-known scalar. Deciding whether to retire a process must never read a
/// transcript, inspect a process tree, or materialize a dormant surface: the number of live
/// runtimes is the bound, and lifecycle owners hand their facts in here.
struct SessionProcessRetentionCandidate: Equatable {
    let sessionID: SessionID
    let lastWarmUseAt: Date
    let isResumable: Bool
    let isHostBacked: Bool
    let runtime: SessionRuntimeSnapshot
    let isLocallyVisible: Bool
    let hasRemoteViewers: Bool
    let hasPendingInput: Bool
    let hasPendingCheckoutMove: Bool
}

struct SessionProcessRetentionPlan: Equatable {
    /// Settled, resumable processes that no longer belong in the warm set.
    let retire: Set<SessionID>

    /// Settled processes kept warm, paired with the absolute time at which age alone retires
    /// them. The same dates are handed to `threading-ptyd` when the app quits.
    let warmIdleExpirations: [SessionID: Date]

    var nextEvaluationAt: Date? { warmIdleExpirations.values.min() }

    static let empty = SessionProcessRetentionPlan(retire: [], warmIdleExpirations: [:])
}

enum SessionProcessRetentionPolicy {
    /// Keeps the most recently used settled conversations inside the age window and retires the
    /// rest. Anything whose safety cannot be proved is outside the idle pool and is kept.
    ///
    /// A terminal that only infers turns is deliberately protected. Silence is not proof that a
    /// command finished, and killing one long-running quiet command would be worse than retaining
    /// an old process. Native conversations and terminals with lifecycle reports can make the
    /// stronger claim.
    static func plan(
        candidates: [SessionProcessRetentionCandidate],
        windowDays: Int,
        limit: Int,
        now: Date = Date(),
        protectsLocalVisibility: Bool = true
    ) -> SessionProcessRetentionPlan {
        let days = SessionRestoreDefaults.clampWindowDays(windowDays)
        let capacity = SessionRestoreDefaults.clampLimit(limit)
        let lifetime = Double(days) * SessionRestoreDefaults.secondsPerDay

        let eligible = candidates.filter { candidate in
            guard candidate.isResumable,
                  candidate.runtime.process == .ready,
                  candidate.runtime.reportsOwnTurns,
                  !candidate.runtime.hasPendingOutcome,
                  candidate.runtime.blocker != .awaitingUser,
                  !candidate.hasRemoteViewers,
                  !candidate.hasPendingInput,
                  !candidate.hasPendingCheckoutMove
            else {
                return false
            }
            return !protectsLocalVisibility || !candidate.isLocallyVisible
        }.sorted {
            if $0.lastWarmUseAt != $1.lastWarmUseAt {
                return $0.lastWarmUseAt > $1.lastWarmUseAt
            }
            return $0.sessionID.uuidString < $1.sessionID.uuidString
        }

        var warm: [SessionID: Date] = [:]
        var retire: Set<SessionID> = []
        for (index, candidate) in eligible.enumerated() {
            let expiration = candidate.lastWarmUseAt.addingTimeInterval(lifetime)
            if index < capacity, expiration > now {
                warm[candidate.sessionID] = expiration
            } else {
                retire.insert(candidate.sessionID)
            }
        }
        return SessionProcessRetentionPlan(retire: retire, warmIdleExpirations: warm)
    }
}

// MARK: - Residency recency

/// The local-view half of process residency, deliberately separate from durable conversation
/// recency. Opening a chat is enough reason to keep its already-running process warm, but it must
/// not reorder the sidebar, refresh search results, or make the next launch restore a conversation
/// in which no work ran.
///
/// The map is bounded by live runtime ownership: `AgentRuntime.discard` forgets an entry when the
/// corresponding process/controller leaves its cache. Selection and lookup are both O(1).
struct SessionProcessResidencyRecency: Equatable {
    private var localViews: [SessionID: Date] = [:]

    mutating func noteLocalView(of sessionID: SessionID, at date: Date = Date()) {
        localViews[sessionID] = max(localViews[sessionID] ?? .distantPast, date)
    }

    func lastWarmUseAt(for sessionID: SessionID, conversationUseAt: Date) -> Date {
        max(conversationUseAt, localViews[sessionID] ?? .distantPast)
    }

    mutating func forget(_ sessionID: SessionID) {
        localViews.removeValue(forKey: sessionID)
    }

    mutating func retainOnly(_ sessionIDs: Set<SessionID>) {
        localViews = localViews.filter { sessionIDs.contains($0.key) }
    }
}
