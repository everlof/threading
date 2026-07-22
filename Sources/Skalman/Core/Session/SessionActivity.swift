import Foundation

// MARK: - Session Activity

/// What a session is currently doing, as shown in the sidebar.
enum SessionActivity {
    /// No terminal allocated; the session can be resumed.
    case dormant

    /// Running but producing no output — an agent waiting at its prompt.
    case idle

    /// Producing output, i.e. the agent is working.
    case working

    /// Finished working while the session was not on screen.
    case needsAttention
}

// MARK: - Session Activity Tracker

/// Derives a session's activity from its terminal output.
///
/// An idle agent writes nothing to its PTY, so output is a reliable signal that work is
/// happening, and it holds for any program rather than just one agent. Two details keep it
/// honest: a byte threshold, so echoed keystrokes are not mistaken for work, and a quiet
/// period, so the brief gaps within a burst of output do not flicker the state.
@MainActor
final class SessionActivityTracker {

    // MARK: - Properties

    private(set) var activity: SessionActivity = .idle {
        didSet {
            guard activity != oldValue else { return }
            onChange?(activity)
        }
    }

    /// Called whenever the activity changes.
    var onChange: ((SessionActivity) -> Void)?

    /// Whether the session is currently on screen, which decides if finishing work is
    /// worth flagging.
    var isVisible: Bool = false {
        didSet {
            // Looking at a session clears its pending attention.
            if isVisible, activity == .needsAttention {
                activity = .idle
            }
        }
    }

    private var bytesSinceQuiet = 0
    private var quietTimer: Timer?

    /// Output arriving before this instant is a redraw we provoked, not the agent working.
    private var suppressOutputUntil: Date?

    // MARK: - Public Methods

    /// Records a chunk of output.
    func recordOutput(byteCount: Int) {
        if isSuppressed {
            // A redraw we caused. It must not start a session working, but it also must not
            // end one that already is — so an in-flight session keeps its timer alive.
            if activity == .working {
                restartQuietTimer()
            }
            return
        }

        bytesSinceQuiet += byteCount

        // Below the threshold this is most likely the terminal echoing typed characters.
        guard bytesSinceQuiet >= ActivityDefaults.workingByteThreshold else { return }

        activity = .working
        restartQuietTimer()
    }

    /// Notes that the terminal was resized.
    ///
    /// Resizing sends `SIGWINCH`, and full-screen terminal apps answer it by repainting
    /// everything — a burst of output indistinguishable from real work. Ignoring output
    /// briefly afterwards keeps a window drag from looking like the agent is busy.
    func noteTerminalResized() {
        suppressOutputUntil = Date().addingTimeInterval(ActivityDefaults.resizeQuietPeriod)
    }

    /// Notes that a scroll was forwarded to the process as mouse input.
    ///
    /// A program tracking the mouse answers each wheel report by repainting its content —
    /// output we caused, exactly like a resize. Each event extends the window, so it covers
    /// a whole momentum gesture and ends soon after the last one.
    func noteScrollForwarded() {
        suppressOutputUntil = Date().addingTimeInterval(ActivityDefaults.scrollQuietPeriod)
    }

    private var isSuppressed: Bool {
        guard let suppressOutputUntil else { return false }
        return Date() < suppressOutputUntil
    }

    /// Records a terminal bell, which agents ring to ask for attention.
    func recordBell() {
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0

        activity = isVisible ? .idle : .needsAttention
    }

    /// Marks the session as having no terminal.
    func markDormant() {
        quietTimer?.invalidate()
        quietTimer = nil
        bytesSinceQuiet = 0
        activity = .dormant
    }

    /// Marks the session as running again after being dormant.
    func markRunning() {
        bytesSinceQuiet = 0
        activity = .idle
    }

    // MARK: - Private Methods

    /// Output has stopped once this fires, so the session has finished whatever it was doing.
    private func restartQuietTimer() {
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(
            withTimeInterval: ActivityDefaults.quietInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishWorking()
            }
        }
    }

    private func finishWorking() {
        quietTimer = nil
        bytesSinceQuiet = 0

        guard activity == .working else { return }

        // Finishing while the session is on screen needs no flag; the user saw it happen.
        activity = isVisible ? .idle : .needsAttention
    }
}

// MARK: - Activity Defaults

enum ActivityDefaults {
    /// Output below this size in a quiet period reads as echoed input rather than work.
    static let workingByteThreshold = 200

    /// How long output must stop before a session counts as finished.
    static let quietInterval: TimeInterval = 0.8

    /// How long a resize's repaint is ignored. Each resize during a drag extends it, so the
    /// window only covers the final repaint once the drag ends.
    static let resizeQuietPeriod: TimeInterval = 0.75

    /// How long a forwarded scroll's repaint is ignored, extended by each wheel event.
    static let scrollQuietPeriod: TimeInterval = 0.5
}
