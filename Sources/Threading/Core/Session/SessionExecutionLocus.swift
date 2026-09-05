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
/// **Execution is observed, never inferred from command text.** A provider lifecycle report is
/// the cheapest source when its `cwd` follows tool execution. Some runtimes instead keep that
/// value and the PTY root process in the launch directory while spawning each tool beneath a
/// temporary `cd x && …`; for those, a coalesced sample of the root's live descendants supplies
/// the missing fact. The host therefore follows ordinary Git use without teaching the model a
/// special spelling or parsing shell commands whose quoting and composition are unbounded.
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

    /// The bounded descendant sample last considered for each terminal session. Kept separate
    /// from `lastReportedPath`: a lifecycle report that repeats the launch directory after a
    /// tool ran elsewhere says nothing new and must not erase that stronger execution evidence.
    private var lastProcessPathSignature: [SessionID: String] = [:]

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

    /// Records the working directories of a bounded set of live tool descendants.
    ///
    /// The process observer has already paid for one shared process-table walk and supplies at
    /// most `SessionExecutionLocusDefaults.processCandidatesPerSession` paths. Only paths outside
    /// the project's lexical root reach Git resolution. A project may itself be a subdirectory
    /// of its checkout, so resolution still decides whether those paths are truly elsewhere.
    func observeProcessWorkingDirectories(_ paths: [String], sessionID: SessionID) {
        let unique = Array(Set(paths.filter { !$0.isEmpty })).sorted()
        guard !unique.isEmpty,
              let owned = ownedCheckoutPath(
                forSessionID: sessionID,
                requiresLifecycleCapability: false
              ) else { return }

        let signature = unique.joined(separator: "\u{0}")
        guard lastProcessPathSignature[sessionID] != signature else { return }
        lastProcessPathSignature[sessionID] = signature

        let ownedRoot = URL(fileURLWithPath: owned, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let candidates = unique.filter {
            let path = URL(fileURLWithPath: $0, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path
            return path != ownedRoot && !path.hasPrefix(ownedRoot + "/")
        }
        if candidates.isEmpty {
            classificationsApplied &+= 1
            applyDrift(.none, sessionID: sessionID)
            return
        }

        let resolver = self.resolver
        resolutionQueue.async {
            let reported = candidates.compactMap(resolver)
            let ownedCheckout = resolver(owned)
            Task { @MainActor [weak self] in
                self?.applyProcessObservation(
                    reported,
                    against: ownedCheckout,
                    signature: signature,
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
        lastProcessPathSignature[sessionID] = nil
        SessionExecutionProcessObserver.shared.forget(sessionID: sessionID)
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
    private func ownedCheckoutPath(
        forSessionID sessionID: SessionID,
        requiresLifecycleCapability: Bool = true
    ) -> String? {
        guard let session = projects.session(withID: sessionID),
              session.managedWorkspace == nil,
              (!requiresLifecycleCapability
                || session.kind.supports(.lifecycleReportedWorkingDirectory)),
              let project = projects.project(forSessionID: sessionID) else { return nil }
        return project.folderPath
    }

    /// Applies descendant evidence only when it names one unambiguous sibling checkout.
    /// Incidental children in `/tmp` or another repository are not ownership evidence, and two
    /// sibling roots active at once do not tell the host which one should own the chat.
    private func applyProcessObservation(
        _ reported: [ObservedCheckout],
        against owned: ObservedCheckout?,
        signature: String,
        sessionID: SessionID
    ) {
        guard lastProcessPathSignature[sessionID] == signature,
              let owned else { return }

        var siblingsByIdentity: [String: ObservedCheckout] = [:]
        for checkout in reported
        where checkout.repositoryIdentity == owned.repositoryIdentity
            && checkout.worktreeIdentity != owned.worktreeIdentity {
            siblingsByIdentity[checkout.worktreeIdentity] = checkout
        }
        classificationsApplied &+= 1
        if siblingsByIdentity.isEmpty,
           reported.contains(where: { $0.worktreeIdentity == owned.worktreeIdentity }) {
            applyDrift(.none, sessionID: sessionID)
            return
        }
        guard siblingsByIdentity.count == 1,
              let checkout = siblingsByIdentity.values.first else { return }

        applyDrift(.siblingCheckout(checkout), sessionID: sessionID)
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
        applyDrift(drift, sessionID: sessionID)
    }

    private func applyDrift(_ drift: SessionExecutionDrift, sessionID: SessionID) {
        if let pending = projects.session(withID: sessionID)?.pendingCheckoutMove {
            switch drift {
            case .siblingCheckout(let checkout)
            where checkout.worktreeIdentity == pending.worktreeIdentity:
                break
            case .none:
                // The root process returning to its launch directory between tool calls is not
                // stronger than the sibling-checkout evidence that created the durable move.
                return
            case .siblingCheckout(let checkout):
                EventLog.shared.record(.session, "Checkout observation conflicted with pending move", [
                    "session": sessionID.uuidString,
                    "pending": pending.checkoutPath,
                    "observed": checkout.root
                ])
                return
            case .unrelated(let path):
                EventLog.shared.record(.session, "Checkout observation conflicted with pending move", [
                    "session": sessionID.uuidString,
                    "pending": pending.checkoutPath,
                    "observed": path
                ])
                return
            }
        }
        // Absent *is* `.none`, so a chat that has only ever worked where it belongs — nearly all
        // of them — stores nothing and announces nothing. Only a chat that leaves, or returns,
        // is news.
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
    static let processQueueLabel = "com.threading.session-execution-process"
    static let processInitialDelay: TimeInterval = 0.12
    static let processMinimumScanInterval: TimeInterval = 1.0
    static let processCandidatesPerSession = 8
}

// MARK: - Descendant Process Observation

/// One process-table snapshot shared by every session whose output arrived in the same burst.
///
/// Building parentage is O(system processes) once. Agent roots are disjoint, so walking their
/// descendants is O(the descendants that actually exist), and the retained candidates are a
/// fixed eight per session even for a build that fans out into thousands of workers.
struct SessionExecutionProcessSnapshot {
    private let table: [pid_t: ProcessSummary]
    private let childrenByParent: [pid_t: [pid_t]]

    init(table: [pid_t: ProcessSummary]) {
        self.table = table
        self.childrenByParent = Dictionary(grouping: table.values, by: \.parentPid)
            .mapValues { $0.map(\.pid) }
    }

    func candidateProcessIDs(
        below rootPID: pid_t,
        limit: Int = SessionExecutionLocusDefaults.processCandidatesPerSession
    ) -> [pid_t] {
        guard rootPID > 0, limit > 0 else { return [] }

        var visited: Set<pid_t> = [rootPID]
        var pending = childrenByParent[rootPID] ?? []
        var candidates: [ProcessSummary] = []
        candidates.reserveCapacity(limit)

        while let pid = pending.popLast() {
            guard visited.insert(pid).inserted else { continue }
            if let summary = table[pid] {
                insertNewest(summary, into: &candidates, limit: limit)
            }
            pending.append(contentsOf: childrenByParent[pid] ?? [])
        }

        return candidates.map(\.pid)
    }

    private func insertNewest(
        _ candidate: ProcessSummary,
        into candidates: inout [ProcessSummary],
        limit: Int
    ) {
        let insertion = candidates.firstIndex { isNewer(candidate, than: $0) }
            ?? candidates.endIndex
        candidates.insert(candidate, at: insertion)
        if candidates.count > limit { candidates.removeLast() }
    }

    private func isNewer(_ lhs: ProcessSummary, than rhs: ProcessSummary) -> Bool {
        switch (lhs.startTime, rhs.startTime) {
        case let (left?, right?):
            if left.seconds != right.seconds { return left.seconds > right.seconds }
            if left.microseconds != right.microseconds {
                return left.microseconds > right.microseconds
            }
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): break
        }
        return lhs.pid > rhs.pid
    }
}

/// Coalesces terminal-output edges into a bounded, background process sample.
///
/// Expected load is one to ten simultaneously working sessions on a machine with hundreds of
/// processes; the stress boundary is every live session reporting output together. They share
/// one process-table walk per second, and each contributes at most eight cwd syscalls. The output
/// callback itself only replaces one dictionary value and schedules work on the main queue.
@MainActor
final class SessionExecutionProcessObserver: @unchecked Sendable {
    static let shared = SessionExecutionProcessObserver()

    typealias TableReader = @Sendable () -> [pid_t: ProcessSummary]
    typealias WorkingDirectoryReader = @Sendable (pid_t) -> String?

    private struct Request: Sendable {
        let rootPID: pid_t
        let generation: UInt64
    }

    private let scanQueue: DispatchQueue
    private let tableReader: TableReader
    private let workingDirectoryReader: WorkingDirectoryReader
    private var pending: [SessionID: Request] = [:]
    private var generations: [SessionID: UInt64] = [:]
    private var scanScheduled = false
    private var scanInFlight = false
    private var lastScanAt: TimeInterval = 0

    init(
        scanQueue: DispatchQueue = DispatchQueue(
            label: SessionExecutionLocusDefaults.processQueueLabel,
            qos: .utility
        ),
        tableReader: @escaping TableReader = { ProcessUtility.processTable() },
        workingDirectoryReader: @escaping WorkingDirectoryReader = {
            ProcessUtility.workingDirectory(forPid: $0)?.path
        }
    ) {
        self.scanQueue = scanQueue
        self.tableReader = tableReader
        self.workingDirectoryReader = workingDirectoryReader
    }

    func noteOutput(sessionID: SessionID, rootPID: pid_t) {
        guard rootPID > 0 else { return }
        pending[sessionID] = Request(
            rootPID: rootPID,
            generation: generations[sessionID, default: 0]
        )
        scheduleIfNeeded()
    }

    func forget(sessionID: SessionID) {
        generations[sessionID, default: 0] &+= 1
        pending[sessionID] = nil
    }

    private func scheduleIfNeeded() {
        guard !pending.isEmpty, !scanScheduled, !scanInFlight else { return }
        scanScheduled = true
        let elapsed = ProcessInfo.processInfo.systemUptime - lastScanAt
        let intervalDelay = max(
            SessionExecutionLocusDefaults.processMinimumScanInterval - elapsed,
            0
        )
        let delay = max(SessionExecutionLocusDefaults.processInitialDelay, intervalDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.startScan() }
        }
    }

    private func startScan() {
        scanScheduled = false
        guard !pending.isEmpty else { return }
        let requests = pending
        pending.removeAll(keepingCapacity: true)
        scanInFlight = true
        lastScanAt = ProcessInfo.processInfo.systemUptime
        let tableReader = self.tableReader
        let workingDirectoryReader = self.workingDirectoryReader

        scanQueue.async { [self] in
            let snapshot = SessionExecutionProcessSnapshot(table: tableReader())
            var pathsBySession: [SessionID: (Request, [String])] = [:]
            pathsBySession.reserveCapacity(requests.count)
            for (sessionID, request) in requests {
                var seen: Set<String> = []
                let paths = snapshot.candidateProcessIDs(below: request.rootPID).compactMap {
                    workingDirectoryReader($0)
                }.filter { seen.insert($0).inserted }
                pathsBySession[sessionID] = (request, paths)
            }
            let completed = pathsBySession
            DispatchQueue.main.async { [self, completed] in
                MainActor.assumeIsolated {
                    finishScan(completed)
                }
            }
        }
    }

    private func finishScan(_ observations: [SessionID: (Request, [String])]) {
        scanInFlight = false
        for (sessionID, observation) in observations
        where generations[sessionID, default: 0] == observation.0.generation {
            SessionExecutionLocusTracker.shared.observeProcessWorkingDirectories(
                observation.1,
                sessionID: sessionID
            )
        }
        scheduleIfNeeded()
    }
}
