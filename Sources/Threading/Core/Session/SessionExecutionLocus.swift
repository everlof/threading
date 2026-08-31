import Foundation

// MARK: - Observed Checkout

/// A checkout an agent was observed working in, resolved once so no reader has to shell out.
///
/// Carried rather than re-derived because every consumer is main-actor UI and `GitInfo`'s
/// resolution is a child process on a cold path. The resolution happens once, off-main, at the
/// moment the drift is classified; a sidebar row asking what to draw reads these fields.
struct ObservedCheckout: Equatable, Sendable {

    /// The checkout's own root, which is what a move must be asked for — never the reported
    /// directory itself. An agent reports the directory it is *in*, and that is routinely a
    /// subdirectory: two of the three drifting chats measured here reported paths several
    /// levels down inside their worktree, and `SessionCheckoutCoordinator.validate` refuses
    /// anything but a checkout root (`targetNotCheckoutRoot`).
    let root: String

    let worktreeIdentity: String
    let repositoryIdentity: String

    /// The branch the checkout stands on, for display only. Nil on a detached head, which is
    /// also a checkout no chat can be moved to.
    let branch: String?

    /// What to call this checkout in a row: the linked worktree's name where there is one, the
    /// root's own last component for a repository's main tree.
    let displayName: String
}

// MARK: - Session Execution Drift

/// Where a session's agent is executing, measured against the checkout that owns the chat.
///
/// The distinction this type exists to keep is the one the app was missing. A chat's **owned
/// checkout** is where Threading launches and resumes it, it is durable, and it moves only
/// through `SessionCheckoutCoordinator`. Where the agent is **executing** is a separate,
/// observed fact that an ordinary `cd` moves without asking anyone. Threading modelled only the
/// first and displayed it as though it were also the second, so a chat that had spent an hour
/// building in a sibling worktree was still filed, grouped and labelled under the branch it
/// launched from.
enum SessionExecutionDrift: Equatable, Sendable {

    /// The agent is inside the checkout that owns the chat — its root or any subdirectory.
    /// The overwhelmingly common answer, and the one that must cost nothing to reach.
    case none

    /// Another checkout of the same repository. Ownership can follow this one.
    case siblingCheckout(ObservedCheckout)

    /// Somewhere ownership cannot follow: another repository, or no repository at all.
    ///
    /// Kept rather than discarded because the sidebar still owes the user the truth. A chat
    /// working outside its repository is not a chat Threading may silently re-file, but it is
    /// also not a chat whose row may go on naming a branch it is not standing on.
    case unrelated(path: String)
}

// MARK: - Session Execution Locus Tracker

/// Reconciles what agents report about their working directory against the checkouts that own
/// their chats.
///
/// **The reported directory is the only sound source, and the alternatives were measured.**
/// `TerminalSession.effectiveWorkingDirectory()` reads OSC 7 or the PTY root process's real
/// cwd, and neither moves when a runtime runs `cd x && …` per tool call: a chat observed
/// building in a sibling worktree for over three hours had a root process still sitting in the
/// directory it launched from. A provider's own report sees what a process reading cannot.
///
/// **Scaling.** These reports arrive on every turn boundary and every brokered tool call of
/// every running session, which is the highest-frequency callback in the app that carries a
/// path. So the hot path is one dictionary read and one string comparison, and an unchanged
/// directory — practically all of them — spawns nothing, touches no disk and posts no event.
/// Only a *changed* directory is resolved, that resolution runs off the main actor because
/// `GitInfo.repositoryRoot` is a child process, and `GitInfo`'s own memo then absorbs the
/// repeat traffic from the subdirectories a single agent walks through.
@MainActor
final class SessionExecutionLocusTracker {

    // MARK: - Properties

    static let shared = SessionExecutionLocusTracker()

    /// Resolves a reported directory to the checkout containing it. Injected so tests can
    /// classify without a repository on disk and without a child process.
    typealias Resolver = @Sendable (String) -> ObservedCheckout?

    /// What each session last reported, verbatim and uninterpreted. The comparison that keeps
    /// this callback cheap happens against these strings, before anything is resolved.
    private var lastReportedPath: [SessionID: String] = [:]

    private var drifts: [SessionID: SessionExecutionDrift] = [:]

    /// How many reported directories have been resolved and classified.
    ///
    /// The one seam tests have on a step that is deliberately asynchronous: the classification
    /// runs off the main actor because it may start `git rev-parse`, so "nothing changed" and
    /// "not finished yet" are otherwise the same observation. It also states the property the
    /// scaling argument rests on — that this number stays far below the number of reports — in
    /// a form a test can assert rather than a comment can claim.
    private(set) var classificationsApplied = 0

    private let projects: ProjectStore
    private let resolver: Resolver
    private let resolutionQueue: DispatchQueue

    // MARK: - Initialization

    init(
        projects: ProjectStore = .shared,
        resolutionQueue: DispatchQueue = DispatchQueue(
            label: SessionExecutionLocusDefaults.queueLabel,
            qos: .utility
        ),
        resolver: @escaping Resolver = SessionExecutionLocusTracker.gitResolver
    ) {
        self.projects = projects
        self.resolutionQueue = resolutionQueue
        self.resolver = resolver
    }

    // MARK: - Public Methods

    /// Records one lifecycle report's working directory.
    ///
    /// Every early return here is on the hot path and each is one comparison. A report that
    /// names no directory is a runtime without the capability or a user with lifecycle
    /// reporting off, and both mean *unknown* rather than *unchanged* — so the previous
    /// classification is left alone rather than being cleared to `.none`, which would have the
    /// sidebar assert the chat came home when nothing said so.
    func observe(_ report: HookLifecycleReport) {
        guard let reported = report.workingDirectory else { return }
        guard lastReportedPath[report.sessionID] != reported else { return }

        // Asked *before* the path is recorded, and the order is load-bearing. Recording first
        // would mark a directory as already handled even when nothing handled it, so a session
        // whose record was not yet readable — or whose managed workspace was later disposed —
        // would need the agent to move somewhere else before it could ever be classified, and
        // an agent that stays in one directory would never be classified at all. Two dictionary
        // reads on a report this cheap is the right side of that trade.
        guard let owned = ownedCheckoutPath(forSessionID: report.sessionID) else { return }

        // Recorded before the resolution is dispatched, so the reports that keep arriving while
        // it runs are filtered by the comparison above instead of queueing a second pass.
        lastReportedPath[report.sessionID] = reported

        let sessionID = report.sessionID
        let resolver = self.resolver
        resolutionQueue.async {
            let reportedCheckout = resolver(reported)
            let ownedCheckout = resolver(owned)
            Task { @MainActor [weak self] in
                self?.apply(
                    reportedCheckout,
                    against: ownedCheckout,
                    reportedPath: reported,
                    sessionID: sessionID
                )
            }
        }
    }

    /// What the sidebar and the session inspector draw. `.none` for anything never observed,
    /// which is the same thing they drew before this existed.
    func drift(forSessionID sessionID: SessionID) -> SessionExecutionDrift {
        drifts[sessionID] ?? .none
    }

    /// Drops a session's observation.
    ///
    /// Called when its ownership moves and when it ends. A committed move makes every stored
    /// reading stale in the same instant: the directory the agent reported has not changed, but
    /// what it is measured *against* has, so keeping the old classification would leave a
    /// just-repaired chat marked as drifting until its next turn.
    func forget(sessionID: SessionID) {
        lastReportedPath[sessionID] = nil
        guard drifts.removeValue(forKey: sessionID) != nil else { return }
        NotificationCenter.default.post(SessionExecutionDriftDidChange(sessionID: sessionID))
    }

    // MARK: - Private Methods

    /// The checkout that owns a chat, or nil where the question does not arise.
    ///
    /// A managed workspace is excluded at the top rather than left to be refused later: its
    /// whole purpose is to run in a worktree of Threading's own making, so every report it ever
    /// sends would classify as drift, and the coordinator would refuse every one of them
    /// (`.managedWorkspace`) after paying for the git resolution first.
    private func ownedCheckoutPath(forSessionID sessionID: SessionID) -> String? {
        guard let session = projects.session(withID: sessionID),
              session.managedWorkspace == nil,
              session.kind.supports(.lifecycleReportedWorkingDirectory),
              let project = projects.project(forSessionID: sessionID) else { return nil }
        return project.folderPath
    }

    private func apply(
        _ reported: ObservedCheckout?,
        against owned: ObservedCheckout?,
        reportedPath: String,
        sessionID: SessionID
    ) {
        // The report may have been overtaken while the resolution ran, or the session may have
        // gone away entirely. Either way this answer is about a question nobody is asking now.
        guard lastReportedPath[sessionID] == reportedPath else { return }

        let drift: SessionExecutionDrift
        switch (reported, owned) {
        case let (reported?, owned?) where reported.worktreeIdentity == owned.worktreeIdentity:
            drift = .none
        case let (reported?, owned?) where reported.repositoryIdentity == owned.repositoryIdentity:
            drift = .siblingCheckout(reported)
        default:
            drift = .unrelated(path: reportedPath)
        }

        classificationsApplied &+= 1

        // Absent *is* `.none`, so a chat that has only ever worked where it belongs — nearly all
        // of them — stores nothing and announces nothing, however many directories it walks
        // through inside its own checkout. Only a chat that leaves, or returns, is news.
        let previous = drifts[sessionID] ?? .none
        guard previous != drift else { return }
        drifts[sessionID] = drift == .none ? nil : drift
        NotificationCenter.default.post(SessionExecutionDriftDidChange(sessionID: sessionID))

        guard case .siblingCheckout(let checkout) = drift else { return }
        // Announced rather than acted on. Reconciling ownership means a policy decision, a
        // possible confirmation and a receipt in a band, none of which belong to a Core type
        // that knows nothing about windows — the same division `SessionArchiveScheduler` keeps.
        // The event above is the announcement; `SessionCoordinator` is what listens.
        EventLog.shared.record(.session, "Chat observed in another checkout", [
            "session": sessionID.uuidString,
            "checkout": checkout.root,
            "branch": checkout.branch ?? ""
        ])
    }

    /// The production resolver. Runs off the main actor by construction: `GitInfo` memoizes per
    /// path, but the first reading of any path is `git rev-parse`.
    private static let gitResolver: Resolver = { path in
        guard let location = GitInfo.worktreeLocation(for: path) else { return nil }
        return ObservedCheckout(
            root: location.root.standardizedFileURL.resolvingSymlinksInPath().path,
            worktreeIdentity: location.worktreeIdentity,
            repositoryIdentity: location.repositoryIdentity,
            branch: GitInfo.currentBranch(for: location.root.path),
            displayName: location.worktreeName ?? location.root.lastPathComponent
        )
    }
}

// MARK: - Events

/// One session's observed execution location changed relative to the checkout that owns it.
struct SessionExecutionDriftDidChange: AppEvent {
    static let name = Notification.Name("sessionExecutionDriftDidChange")
    let sessionID: SessionID
}

// MARK: - Defaults

enum SessionExecutionLocusDefaults {
    static let queueLabel = "com.threading.session-execution-locus"
}
