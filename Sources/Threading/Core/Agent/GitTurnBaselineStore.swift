import Foundation

/// Remembers what each session's checkout looked like when its agent last started working,
/// so "Last Turn" can diff against that moment.
///
/// The reliable path prepares before provider admission; the later entering-working edge only
/// consumes that preparation. An entering-working capture remains as a fallback for terminal
/// sessions whose lifecycle hooks are unavailable. A baseline taken at stop would fold the
/// user's own between-turn edits into the next turn.
///
/// In-memory on purpose. The snapshot is an unreferenced tree that git's gc eventually prunes,
/// and a persisted hash whose object has vanished is a worse answer after relaunch than
/// "No turn recorded yet". Main-thread only, like the other stores.
@MainActor
final class GitTurnBaselineStore {

    static let shared = GitTurnBaselineStore()
    private init() {}

    // MARK: - Properties

    private var baselines: [SessionID: GitTurnBaseline] = [:]
    private var failures: [SessionID: GitFailure] = [:]
    private var lastActivity: [SessionID: SessionActivity] = [:]
    private var generations: [SessionID: Int] = [:]

    /// A prepared native submission or blocking terminal hook is followed by the ordinary
    /// entering-working activity edge. Consume that edge instead of taking a second snapshot.
    private var preparedActivityEdges: Set<SessionID> = []

    /// A terminal can repaint while its blocking turn-start hook is still waiting. If that
    /// output is inferred as the entering-working edge, consume it here; starting a second
    /// capture at that point could move the baseline to after the agent's first write.
    private var preparingActivityEdges: Set<SessionID> = []

    // MARK: - Public Methods

    /// Feed every activity change through here; the store finds the edges itself.
    func noteActivity(_ activity: SessionActivity, sessionID: SessionID) {
        let previous = lastActivity[sessionID]
        lastActivity[sessionID] = activity

        guard activity == .working, previous != .working else { return }

        // Answering a question mid-turn returns the session to `working`, and that edge is not
        // a new turn — re-baselining there would silently drop everything the turn had already
        // changed out of the Last Turn diff. Only `awaitingUser` marks that resumption, which
        // is the whole reason it is a state of its own.
        guard previous != .awaitingUser else { return }
        if preparingActivityEdges.remove(sessionID) != nil { return }
        if preparedActivityEdges.remove(sessionID) != nil { return }

        // Fallback for a terminal whose hooks are disabled or unavailable. It cannot precede
        // the agent's first write, but clearing the old mark still prevents a failed or late
        // capture from being presented as though it belonged to this turn.
        prepareTurn(sessionID: sessionID, expectsActivityEdge: false) {}
    }

    /// Establishes a new turn baseline and completes only after it is stored (or definitively
    /// failed). Native Chat calls this before provider transport; terminal turn-start hooks hold
    /// their HTTP response on it, making both surfaces share the same admission boundary.
    func prepareTurn(
        sessionID: SessionID,
        expectsActivityEdge: Bool = true,
        completion: @escaping @MainActor () -> Void
    ) {
        // Answering an agent question resumes the same turn. Its prior baseline must survive.
        if lastActivity[sessionID] == .awaitingUser {
            completion()
            return
        }

        let generation = (generations[sessionID] ?? 0) + 1
        generations[sessionID] = generation
        baselines.removeValue(forKey: sessionID)
        failures.removeValue(forKey: sessionID)
        if expectsActivityEdge {
            preparingActivityEdges.insert(sessionID)
            preparedActivityEdges.remove(sessionID)
        }

        guard let project = ProjectStore.shared.executionProject(forSessionID: sessionID),
              let root = GitInfo.repositoryRoot(for: project.folderPath) else {
            if expectsActivityEdge,
               preparingActivityEdges.remove(sessionID) != nil {
                preparedActivityEdges.insert(sessionID)
            }
            completion()
            return
        }

        GitReviewReader.createSnapshot(in: root) { [weak self] result in
            guard let self else {
                completion()
                return
            }

            // Every waiter is released, but only the newest capture may describe the turn.
            guard self.generations[sessionID] == generation else {
                completion()
                return
            }

            // If the activity edge arrived while the snapshot was running, it already consumed
            // `preparingActivityEdges`; do not leave a marker that would swallow the next turn.
            if expectsActivityEdge,
               self.preparingActivityEdges.remove(sessionID) != nil {
                self.preparedActivityEdges.insert(sessionID)
            }
            switch result {
            case .success(let baseline):
                self.baselines[sessionID] = baseline
            case .failure(let failure):
                self.failures[sessionID] = failure
                ThreadingLogger.git.error(
                    "Turn baseline capture failed for \(sessionID, privacy: .public): \(failure.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
            completion()
        }
    }

    func baseline(forSessionID sessionID: SessionID) -> GitTurnBaseline? {
        baselines[sessionID]
    }

    func captureFailure(forSessionID sessionID: SessionID) -> GitFailure? {
        failures[sessionID]
    }

    /// Drops state for sessions that no longer exist.
    func retainOnly(sessionIDs: Set<SessionID>) {
        baselines = baselines.filter { sessionIDs.contains($0.key) }
        failures = failures.filter { sessionIDs.contains($0.key) }
        lastActivity = lastActivity.filter { sessionIDs.contains($0.key) }
        generations = generations.filter { sessionIDs.contains($0.key) }
        preparedActivityEdges.formIntersection(sessionIDs)
        preparingActivityEdges.formIntersection(sessionIDs)
    }
}
