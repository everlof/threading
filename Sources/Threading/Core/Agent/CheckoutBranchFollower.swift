import Foundation

/// Keeps sessions' branch records following their checkout while nothing is running in it.
///
/// `ProjectStore.refreshBranch(forSessionID:)` fires when a session stops working — the
/// moment *that* session may have moved its checkout. This service covers every other mover:
/// a different session in the same checkout, the shell drawer, a terminal outside Threading
/// entirely. One branch-scoped `GitCheckoutWatcher` per unique checkout among the added
/// projects — keyed by `GitInfo.worktreeIdentity`, the durable "which checkout" key — each
/// watching only the worktree's own `HEAD`, so builds and agent edits never wake one.
///
/// Gated on `AppSettings.followsCheckoutBranch` and reconciled on every settings or project
/// change: toggling the setting off stops every stream and leaves the records frozen at
/// whatever they last said, which is the original rule (see `docs/architecture/git.md`).
@MainActor
final class CheckoutBranchFollower {

    // MARK: - Singleton

    static let shared = CheckoutBranchFollower(store: .shared)

    // MARK: - Properties

    private let store: ProjectStore
    private let appEvents = AppEventObservations()

    /// Live watchers by worktree identity. A checkout appears once however many projects
    /// stand in it.
    private var watchers: [String: GitCheckoutWatcher] = [:]

    /// The checkouts currently watched, for tests and diagnostics.
    var watchedIdentities: Set<String> { Set(watchers.keys) }

    // MARK: - Initialization

    init(store: ProjectStore) {
        self.store = store
    }

    // MARK: - Public Methods

    /// Begins following: watches the store and the settings, and reconciles immediately.
    /// Called once at launch.
    func start() {
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcile()
    }

    // MARK: - Private Methods

    /// Aligns the watcher set with the added projects: one per unique checkout, none while
    /// the setting is off. Cheap enough to run on every store change — `worktreeIdentity`
    /// is memoised, and an unchanged checkout keeps its running stream.
    ///
    /// Catch-up reads run after the set is aligned: a refresh that changes a record posts
    /// `ProjectsDidChange`, which re-enters here synchronously, and against an aligned set
    /// that re-entry is a no-op instead of a walk over half-built state.
    private func reconcile() {
        guard AppSettings.shared.followsCheckoutBranch else {
            for watcher in watchers.values { watcher.stop() }
            watchers = [:]
            return
        }

        // One representative folder per checkout; the identity, not the folder, is what
        // must be unique, or two projects in one checkout would race duplicate streams
        // over the same HEAD.
        var desired: [String: String] = [:]
        for project in store.projects {
            guard let identity = GitInfo.worktreeIdentity(for: project.folderPath),
                  desired[identity] == nil else { continue }
            desired[identity] = project.folderPath
        }

        for (identity, watcher) in watchers where desired[identity] == nil {
            watcher.stop()
            watchers[identity] = nil
        }

        var added: [String] = []
        for (identity, folderPath) in desired where watchers[identity] == nil {
            guard let watcher = GitCheckoutWatcher(
                root: URL(fileURLWithPath: folderPath),
                scope: .branch,
                onChange: { [weak self] in
                    self?.store.refreshBranches(forCheckoutAt: folderPath)
                }
            ) else { continue }

            watcher.start()
            watchers[identity] = watcher
            added.append(folderPath)
        }

        // A checkout may have moved while it went unwatched — before launch, or while the
        // setting was off — so every new watcher starts with a catch-up read.
        for folderPath in added {
            store.refreshBranches(forCheckoutAt: folderPath)
        }
    }
}
