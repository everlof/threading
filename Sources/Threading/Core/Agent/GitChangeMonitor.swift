import Foundation

enum GitChangeMonitorDefaults {
    /// The floor between two summary reads.
    ///
    /// A summary is several `git` child processes and measured 80-110 ms of them per reading.
    /// The read-side coalescing below already refused to run two at once, but it re-read the
    /// instant one finished — so an agent writing files continuously held `needsAnotherRead` set
    /// and the reads ran back to back for as long as it worked: 1061 child processes and 46
    /// seconds of process time in one 70 minute trace.
    ///
    /// A floor fixes that without weakening the contract. The card is a status readout a person
    /// glances at, and re-reading it more often than this buys nothing anyone can see, while a
    /// burst of writes still ends with a reading taken after the last of them.
    static let minimumReadInterval: TimeInterval = 1
}

/// Feeds the floating git status card: watches a checkout and reports its branch and
/// uncommitted totals whenever a write changes what they would say.
///
/// One monitor serves the session pane's *selected* session — created when a session appears,
/// stopped when it leaves the screen — so the FSEvents stream and the summary reads exist
/// only while something draws them. `GitCheckoutWatcher` already coalesces the event bursts;
/// this type adds the read-side half of that discipline: one read in flight at a time, with a
/// change arriving mid-read queueing exactly one more, so a burst of writes always ends with
/// a reading taken after the last of them — and that owed reading waits out
/// `GitChangeMonitorDefaults.minimumReadInterval`, so continuous writing cannot turn "one more
/// read" into an unbroken chain of them.
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
    private let onInitialReadComplete: () -> Void

    private var watcher: GitCheckoutWatcher?
    private var lastReading: Reading?
    private var isReading = false
    private var needsAnotherRead = false
    private var didCompleteInitialRead = false
    private var lastReadStartedAt: Date?
    private var queuedRead: Task<Void, Never>?

    // MARK: - Initialization

    /// Fails outside a repository — there is then nothing for the card to say.
    init?(
        root: URL,
        onChange: @escaping (Reading) -> Void,
        onInitialReadComplete: @escaping () -> Void = {}
    ) {
        guard GitInfo.worktreeLocation(for: root.path) != nil else { return nil }
        self.root = root
        self.onChange = onChange
        self.onInitialReadComplete = onInitialReadComplete
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
        queuedRead?.cancel()
        queuedRead = nil
    }

    // MARK: - Private Methods

    private func refresh() {
        guard !isReading else {
            needsAnotherRead = true
            return
        }
        isReading = true
        lastReadStartedAt = Date()

        let branch = GitInfo.currentBranch(for: root.path)
        GitReviewReader.uncommittedSummary(in: root) { [weak self] result in
            guard let self else { return }
            self.isReading = false

            if !self.didCompleteInitialRead {
                self.didCompleteInitialRead = true
                self.onInitialReadComplete()
            }

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
                self.scheduleRefresh()
            }
        }
    }

    /// Takes the reading the burst still owes, but never sooner than the floor.
    ///
    /// The delay is measured from when the last read *started*, so a slow summary already pays
    /// for its own interval and a fast one on a quiet checkout is not made artificially slow.
    private func scheduleRefresh() {
        let elapsed = lastReadStartedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let remaining = GitChangeMonitorDefaults.minimumReadInterval - elapsed
        guard remaining > 0 else {
            refresh()
            return
        }

        queuedRead?.cancel()
        queuedRead = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.queuedRead = nil
            self.refresh()
        }
    }
}
