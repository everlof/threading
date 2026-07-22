import Foundation

/// Remembers what each session's checkout looked like when its agent last started working,
/// so "Last Turn" can diff against that moment.
///
/// Captures on the *entering-working* edge, not the stopped one: the mode should mean "since
/// this turn began", live while the agent works, and a baseline taken at stop would fold the
/// user's own between-turn edits into the next turn.
///
/// In-memory on purpose. The snapshot is an unreferenced `stash create` commit that git's gc
/// eventually prunes, and a persisted hash whose object has vanished is a worse answer after
/// relaunch than "No turn recorded yet". Main-thread only, like the other stores.
@MainActor
final class GitTurnBaselineStore {

    static let shared = GitTurnBaselineStore()
    private init() {}

    // MARK: - Properties

    private var baselines: [SessionID: GitTurnBaseline] = [:]
    private var lastActivity: [SessionID: SessionActivity] = [:]

    /// Sessions with a snapshot run in flight, so a flickering edge cannot stack captures.
    private var capturing: Set<SessionID> = []

    // MARK: - Public Methods

    /// Feed every activity change through here; the store finds the edges itself.
    func noteActivity(_ activity: SessionActivity, sessionID: SessionID) {
        let previous = lastActivity[sessionID]
        lastActivity[sessionID] = activity

        guard activity == .working, previous != .working else { return }
        guard !capturing.contains(sessionID) else { return }
        guard let project = ProjectStore.shared.project(forSessionID: sessionID),
              let root = GitInfo.repositoryRoot(for: project.folderPath) else { return }

        capturing.insert(sessionID)
        GitReviewReader.createSnapshot(in: root) { [weak self] result in
            guard let self else { return }
            self.capturing.remove(sessionID)

            switch result {
            case .success(let baseline):
                self.baselines[sessionID] = baseline
            case .failure(let failure):
                // The previous baseline (if any) stays; a failed capture only means this
                // turn starts from the older mark.
                SkalmanLogger.git.error(
                    "Turn baseline capture failed for \(sessionID, privacy: .public): \(failure.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func baseline(forSessionID sessionID: SessionID) -> GitTurnBaseline? {
        baselines[sessionID]
    }

    /// Drops state for sessions that no longer exist.
    func retainOnly(sessionIDs: Set<SessionID>) {
        baselines = baselines.filter { sessionIDs.contains($0.key) }
        lastActivity = lastActivity.filter { sessionIDs.contains($0.key) }
    }
}
