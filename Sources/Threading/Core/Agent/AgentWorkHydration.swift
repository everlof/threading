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
///
/// Two feeds run from the same edges, because both answer "what has this session done" and both
/// are cheap when the answer is "nothing new". The transcript is exact and incomplete: it holds
/// every call the runtime wrote down and can never name the file a shell command changed. Under
/// it, for every runtime including the ones Threading renders itself, the git turn checkpoints
/// already captured for the Review pane give the complete, unattributed other half — which is
/// recorded as its own kind of fact rather than folded into the exact counts.
@MainActor
enum AgentWorkHydration {

    private enum Defaults {
        static let scheduleSlack: TimeInterval = 0.05

        /// Turn checkpoints folded into the git-observed floor in one pass.
        ///
        /// A checkpoint that changed something costs one `git diff --name-only`, and a session
        /// keeps up to `GitTurnCheckpointDefaults.maximumPerSession` of them — so a session whose
        /// floor is being read for the first time would otherwise spend fifty processes inside a
        /// single tab opening. This is pacing, not truncation: the pass re-arms itself while any
        /// checkpoint is still unread, and the throttle spaces the passes a second apart.
        static let checkpointsPerPass = 8
    }

    // MARK: - Properties

    private static var throttle = AgentWorkHydrationThrottle()

    /// Sessions whose checkpoint pass is mid-flight. The worker refuses a checkpoint it has
    /// already consumed, so a second pass could not double-count — but it could spawn the same
    /// `git diff` twice, and the answer is already on its way.
    private static var observingSessions: Set<SessionID> = []

    // MARK: - Public Methods

    /// Folds anything new in the session's transcript into its trace.
    ///
    /// Safe to call on any edge that might mean "the session did something" — a turn ending, the
    /// Overview being shown on Activity, an activity change, a pane render. Repeats inside a
    /// one-second window collapse into a single trailing pass, and a pass with nothing new to read
    /// stops at a file-size comparison on the store's own queue.
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

        hydrateTranscript(session: session, in: project)
        hydrateObservedChanges(session: session, in: project)
    }

    /// Feed A: the session's own transcript, from wherever the last pass stopped.
    private static func hydrateTranscript(session: AgentSession, in project: Project) {
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

    /// Feed D: the neutral floor, from the turn checkpoints every session in a checkout already
    /// leaves behind.
    ///
    /// This is the only feed that runs for *every* runtime, and the only one that can show a file
    /// no tool named — the shell edit, the formatter a script ran, the generated file. It is also
    /// the weakest: a tree pair says a path differs and nothing else, so what it records is
    /// counted, drawn and spoken apart from the exact signals rather than folded into them.
    private static func hydrateObservedChanges(session: AgentSession, in project: Project) {
        let sessionID = session.id
        guard !observingSessions.contains(sessionID) else { return }

        // Completed only: an in-flight turn has no end tree, and its diff would be a moving
        // answer recorded as a settled one.
        let checkpoints = GitTurnBaselineStore.shared
            .checkpoints(forSessionID: sessionID)
            .filter(\.isComplete)
        guard !checkpoints.isEmpty else { return }

        observingSessions.insert(sessionID)
        AgentWorkTraceStore.shared.observedCheckpointOrdinal(
            sessionID: sessionID, projectID: project.id
        ) { consumed in
            let pending = checkpoints.filter { $0.ordinal > (consumed ?? Int.min) }
            fold(
                Array(pending.prefix(Defaults.checkpointsPerPass)),
                hasMore: pending.count > Defaults.checkpointsPerPass,
                resumedFrom: consumed,
                session: session,
                project: project
            )
        }
    }

    /// Reads one turn's changed paths, records them, then continues with the next.
    ///
    /// Sequential by construction. The resume point is a single ordinal that only moves forward,
    /// so recording a later turn first would silently swallow every turn before it — and reading
    /// them concurrently would spend one process per turn at once for a panel nobody is watching.
    private static func fold(
        _ checkpoints: [GitTurnCheckpoint],
        hasMore: Bool,
        resumedFrom: Int?,
        session: AgentSession,
        project: Project
    ) {
        guard let checkpoint = checkpoints.first else {
            finish(hasMore: hasMore, resumedFrom: resumedFrom, session: session, project: project)
            return
        }

        let rest = Array(checkpoints.dropFirst())
        let root = URL(fileURLWithPath: project.folderPath, isDirectory: true)
        GitReviewReader.checkpointChangedPaths(checkpoint, in: root) { result in
            // An unreadable checkpoint still moves the resume point. Its refs are gone — retention
            // collected them, or the checkout did — and no later pass can read it either, so
            // retrying would spend a process per turn on every trigger, forever.
            record((try? result.get()) ?? [], for: checkpoint, session: session, in: project)
            fold(
                rest, hasMore: hasMore, resumedFrom: resumedFrom,
                session: session, project: project
            )
        }
    }

    /// Ends the pass, and re-arms only if this one actually got somewhere.
    ///
    /// Re-arming at all is what drains a session whose turns outnumber one pass without waiting
    /// for an edge that may never come: a dormant session's tab can be opened once and never
    /// touched again. Requiring the resume point to have *moved* is what keeps that from becoming
    /// a permanent one-second loop if the store is refusing this session's writes — a deleted
    /// project's tombstone, say — because then every pass would find the same work pending.
    private static func finish(
        hasMore: Bool,
        resumedFrom: Int?,
        session: AgentSession,
        project: Project
    ) {
        guard hasMore else {
            observingSessions.remove(session.id)
            return
        }
        AgentWorkTraceStore.shared.observedCheckpointOrdinal(
            sessionID: session.id, projectID: project.id
        ) { consumed in
            observingSessions.remove(session.id)
            guard let consumed, consumed > (resumedFrom ?? Int.min) else { return }
            hydrate(sessionID: session.id)
        }
    }

    private static func record(
        _ paths: [String],
        for checkpoint: GitTurnCheckpoint,
        session: AgentSession,
        in project: Project
    ) {
        // The turn's own window, used to tell an exact edit this session already recorded from an
        // anonymous delta. `requestedAt` is the floor for both ends: a checkpoint that failed
        // somewhere in the middle still has one, and an empty window simply claims nothing.
        let start = checkpoint.beforeCapturedAt ?? checkpoint.requestedAt
        let end = checkpoint.completedAt ?? checkpoint.finalRequestedAt ?? checkpoint.requestedAt

        AgentWorkTraceStore.shared.record(
            observedChanges: paths,
            checkpointOrdinal: checkpoint.ordinal,
            turnStart: start,
            turnEnd: max(start, end),
            claimedPaths: checkpoint.hasUsableEditClaims
                ? claims(of: checkpoint, relativeTo: project.folderPath)
                : nil,
            projectID: project.id,
            session: session,
            rootPath: project.folderPath
        )
    }

    /// A turn's claimed paths, moved onto the axis the trace and the changed paths already use.
    ///
    /// Claims are stored relative to the *checkout*, while the trace is relative to the session's
    /// execution folder, and a project added as a subdirectory of a repository makes those two
    /// different. Comparing them unshifted would match nothing, and every file the turn's own
    /// tools named would be recorded a second time as an anonymous delta.
    ///
    /// Internal rather than private for its test: this is the rule, and it is a string shift with
    /// two ways to be silently wrong.
    static func claims(
        of checkpoint: GitTurnCheckpoint,
        relativeTo folderPath: String
    ) -> Set<String> {
        let claimed = checkpoint.claimedEditPaths ?? []
        guard let checkout = checkpoint.executionCheckoutPath,
              let prefix = AgentWorkPath.relative(folderPath, root: checkout),
              !prefix.isEmpty
        else { return Set(claimed) }

        // Outside the execution folder is outside the atlas too, so those claims describe no mark
        // this card could draw and are simply dropped.
        return Set(claimed.compactMap { claim in
            claim.hasPrefix(prefix + "/") ? String(claim.dropFirst(prefix.count + 1)) : nil
        })
    }
}
