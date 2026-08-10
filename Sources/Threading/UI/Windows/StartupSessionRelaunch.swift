import AppKit

// MARK: - Startup Session Relaunch

/// Decides which sessions a launch brings back after the app was quit with agents running.
///
/// The candidate set is exactly what was live at the last quit, which is what keeps the
/// feature's cost honest: the machine already ran those agents side by side a moment before
/// the quit, so bringing the same set back returns it to a load it has demonstrably carried.
/// A rule like "every session in the sidebar" has no such bound — a store with forty dormant
/// conversations would boot forty CLIs nobody asked for.
enum StartupSessionRelaunch {

    /// Orders and filters the recorded sessions into the relaunch plan.
    ///
    /// The record is navigation state that outlives the sessions it names: anything deleted or
    /// archived since the quit is dropped by lookup rather than trusted. The excluded id is the
    /// one `restoreSelectedSession` is already bringing back on screen — launching it here as
    /// well would race the selection's own launch. Most recently active goes first, because the
    /// stagger means the last in line waits the whole line, and the session touched last is the
    /// one most likely to be wanted first.
    static func plan(
        recorded: [SessionID],
        sessions: [AgentSession],
        excluding excludedID: SessionID?
    ) -> [SessionID] {
        let byID = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return recorded
            .compactMap { byID[$0] }
            .filter { !$0.isArchived && $0.id != excludedID }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .map(\.id)
    }
}

// MARK: - Startup Session Relauncher

/// Walks the plan one session per tick, so the launches spread out instead of landing at once.
///
/// The stagger is the performance half of the feature. Each launch spawns a login shell that
/// `exec`s an agent CLI, and the CLI's own boot is the expensive part — a burst of CPU per
/// process. Fired together, N of those all contend through the app's first seconds; spread a
/// second apart, each gets the machine roughly to itself, and the per-launch main-thread work
/// (the MCP config writes, building and laying out the surface) stays a small slice of its own
/// run-loop turn instead of N slices of one. The first launch waits a full interval too, which
/// is the restored selected session's head start.
@MainActor
final class StartupSessionRelauncher {

    // MARK: - Properties

    private var pending: [SessionID]
    private let interval: TimeInterval
    private let launch: (SessionID) -> Void
    private let timer = MainRunLoopTimer()

    // MARK: - Initialization

    /// The launch closure re-validates its session against the store at fire time; the plan
    /// was computed at startup and the user may have clicked, archived, or deleted since.
    /// The interval is injectable so a test is not a two-second wait on a wall clock.
    init(
        sessionIDs: [SessionID],
        interval: TimeInterval = StartupRelaunchDefaults.staggerInterval,
        launch: @escaping (SessionID) -> Void
    ) {
        self.pending = sessionIDs
        self.interval = interval
        self.launch = launch
    }

    // MARK: - Public Methods

    /// Begins the stagger. Idempotent while running; the timer retires itself with the plan.
    func start() {
        guard !timer.isInstalled, !pending.isEmpty else { return }

        let timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.launchNext()
            }
        }
        timer.tolerance = StartupRelaunchDefaults.staggerTolerance
        self.timer.install(timer)
    }

    // MARK: - Private Methods

    private func launchNext() {
        guard !pending.isEmpty else {
            timer.invalidate()
            return
        }

        launch(pending.removeFirst())

        if pending.isEmpty {
            timer.invalidate()
        }
    }
}

// MARK: - Startup Relaunch Defaults

enum StartupRelaunchDefaults {
    /// How long each relaunch waits behind the previous one. Long enough for an agent CLI's
    /// boot burst to pass its peak; short enough that five sessions are all up within seconds.
    static let staggerInterval: TimeInterval = 1.0

    /// The timing is pacing, not a deadline, so the system may coalesce the wakeups.
    static let staggerTolerance: TimeInterval = 0.25

    /// The frame a background-launched surface is laid out at when the pane cannot be asked.
    /// Matches the remote-browser E2E fixture's terminal, a size every agent TUI handles.
    static let fallbackSize = NSSize(width: 900, height: 620)

    /// Bounds below this are a pane mid-setup, not an answer worth adopting.
    static let minimumPaneDimension: CGFloat = 200
}
