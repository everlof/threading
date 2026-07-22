import Foundation

/// Feeds the floating git status card: watches a checkout and reports its branch and
/// uncommitted totals whenever a write changes what they would say.
///
/// One monitor serves the session pane's *selected* session — created when a session appears,
/// stopped when it leaves the screen — so the FSEvents stream and the summary reads exist
/// only while something draws them. `GitCheckoutWatcher` already coalesces the event bursts;
/// this type adds the read-side half of that discipline: one read in flight at a time, with a
/// change arriving mid-read queueing exactly one more, so a burst of writes always ends with
/// a reading taken after the last of them.
@MainActor
final class GitChangeMonitor {

    /// What the card draws: the checkout's branch (nil when detached or unborn) and the
    /// uncommitted totals.
    struct Reading: Equatable {
        let branch: String?
        let summary: GitChangeSummary
    }

    // MARK: - Properties

    private let root: URL
    private let onChange: (Reading) -> Void

    private var watcher: GitCheckoutWatcher?
    private var lastReading: Reading?
    private var isReading = false
    private var needsAnotherRead = false

    // MARK: - Initialization

    /// Fails outside a repository — there is then nothing for the card to say.
    init?(root: URL, onChange: @escaping (Reading) -> Void) {
        guard GitInfo.worktreeLocation(for: root.path) != nil else { return nil }
        self.root = root
        self.onChange = onChange
    }

    // MARK: - Public Methods

    /// Begins watching and takes the first reading. Idempotent.
    func start() {
        guard watcher == nil else { return }

        watcher = GitCheckoutWatcher(root: root) { [weak self] in
            self?.refresh()
        }
        watcher?.start()
        refresh()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: - Private Methods

    private func refresh() {
        guard !isReading else {
            needsAnotherRead = true
            return
        }
        isReading = true

        let branch = GitInfo.currentBranch(for: root.path)
        GitReviewReader.uncommittedSummary(in: root) { [weak self] result in
            guard let self else { return }
            self.isReading = false

            // A failed read keeps the last reading on screen rather than blanking the card:
            // the likeliest failure is a transient one mid-write, and the stale answer is
            // corrected by the very next event.
            if case .success(let summary) = result {
                let reading = Reading(branch: branch, summary: summary)
                if reading != self.lastReading {
                    self.lastReading = reading
                    self.onChange(reading)
                }
            }

            if self.needsAnotherRead {
                self.needsAnotherRead = false
                self.refresh()
            }
        }
    }
}
