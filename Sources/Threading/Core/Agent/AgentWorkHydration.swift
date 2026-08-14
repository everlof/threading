import Foundation

/// The rule that lets the trigger sites be blunt.
///
/// A pass is cheap — a file-size comparison when there is nothing to read — but its callers fire at
/// very different rates: a turn boundary a few times a minute, a display-pane render whenever
/// anything about the pane changes, and an agent rewrites its terminal title constantly. Rather
/// than teach each caller when it is allowed to ask, every ask is admitted here: the first runs,
/// and anything during the quiet window that follows collapses into **one** trailing pass.
///
/// Trailing rather than dropped, because the last ask is the one that matters — it is the one that
/// knows the turn ended.
struct AgentWorkHydrationThrottle {

    enum Decision: Equatable {
        /// Run now.
        case now
        /// Run once after this delay; the caller schedules it.
        case after(TimeInterval)
        /// A trailing pass is already scheduled and will cover this ask.
        case alreadyScheduled
    }

    /// One second: shorter than any turn, longer than any burst of renders.
    static let quietWindow: TimeInterval = 1

    private var lastPass: [SessionID: Date] = [:]
    private var scheduled: Set<SessionID> = []

    mutating func admit(_ sessionID: SessionID, now: Date) -> Decision {
        guard !scheduled.contains(sessionID) else { return .alreadyScheduled }

        if let last = lastPass[sessionID], now.timeIntervalSince(last) < Self.quietWindow {
            scheduled.insert(sessionID)
            return .after(Self.quietWindow - now.timeIntervalSince(last))
        }

        lastPass[sessionID] = now
        prune(now: now)
        return .now
    }

    /// Called when a scheduled trailing pass fires, so it is admitted rather than collapsed into
    /// itself.
    mutating func releaseSchedule(for sessionID: SessionID) {
        scheduled.remove(sessionID)
    }

    /// Keeps the map to the sessions actually being asked about. Entries older than the window
    /// answer the same as no entry at all, so dropping them changes no decision.
    private mutating func prune(now: Date) {
        guard lastPass.count > 256 else { return }
        lastPass = lastPass.filter { now.timeIntervalSince($0.value) < Self.quietWindow }
    }
}

/// Decides when a session Threading does not render has its own transcript folded into the
/// observed work the Activity panel shows.
///
/// The panel used to be fed from one place only — the native conversation controller, which sees
/// every tool call as it streams. A terminal session's calls reach Threading as nothing but PTY
/// bytes, so the panel drew the repository and reported zeros for it: measured here, 179 of one
/// project's 183 sessions. The runtime was writing those same calls to a transcript the whole
/// time, and `TranscriptReplay` already reads it.
///
/// Nothing here is per runtime. `.transcriptReplay` is the capability that says a durable local
/// conversation exists and can be normalized, and `TranscriptReplayFormat` is the closed adapter
/// set behind it — so this covers Claude and Codex today and covers a sixth runtime the day that
/// runtime earns the capability, with no edit to this file.
@MainActor
enum AgentWorkHydration {

    private enum Defaults {
        static let scheduleSlack: TimeInterval = 0.05
    }

    // MARK: - Properties

    private static var throttle = AgentWorkHydrationThrottle()

    // MARK: - Public Methods

    /// Folds anything new in the session's transcript into its trace.
    ///
    /// Safe to call on any edge that might mean "the session did something" — a turn ending, the
    /// Activity tab being shown, an activity change, a pane render. Repeats inside a one-second
    /// window collapse into a single trailing pass, and a pass with nothing new to read stops at a
    /// file-size comparison on the store's own queue.
    static func hydrate(sessionID: SessionID) {
        switch throttle.admit(sessionID, now: Date()) {
        case .alreadyScheduled:
            return

        case .after(let delay):
            // A hair past the window rather than exactly on it: a timer that fires a microsecond
            // early would find the window still open and schedule a second hop to no purpose.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + Defaults.scheduleSlack) {
                MainActor.assumeIsolated {
                    throttle.releaseSchedule(for: sessionID)
                    hydrate(sessionID: sessionID)
                }
            }

        case .now:
            hydrateNow(sessionID: sessionID)
        }
    }

    // MARK: - Private Methods

    private static func hydrateNow(sessionID: SessionID) {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              // The execution project, so both the transcript's location and the root the paths
              // are relativized against are the directory the agent actually ran in. A session in
              // a managed worktree has a different one from its project's own folder, and Claude
              // derives its transcript directory from that same working directory.
              let project = ProjectStore.shared.executionProject(forSessionID: sessionID)
        else { return }

        // A rendered conversation is already recording each call as it arrives, exactly and with
        // its own timing. Reading its transcript as well would count the same work twice, and the
        // trace's adopt-the-end rule exists for the session that changes surface between the two.
        guard !session.usesNativeUI,
              session.kind.supports(.transcriptReplay),
              let url = SessionTranscript.url(for: session, in: project)
        else { return }

        AgentWorkTraceStore.shared.record(
            transcriptAt: url,
            kind: session.kind,
            projectID: project.id,
            session: session,
            rootPath: project.folderPath
        )
    }
}
