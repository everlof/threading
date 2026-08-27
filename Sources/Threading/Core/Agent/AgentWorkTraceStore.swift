import Foundation

// MARK: - Presentation identity and change event

struct AgentWorkTarget: Hashable, Sendable {
    let projectID: ProjectID
    let sessionID: SessionID?
    let rootPath: String
    let isDetailed: Bool

    static func session(
        projectID: ProjectID,
        sessionID: SessionID,
        rootPath: String,
        detailed: Bool
    ) -> AgentWorkTarget {
        AgentWorkTarget(
            projectID: projectID,
            sessionID: sessionID,
            rootPath: rootPath,
            isDetailed: detailed
        )
    }

    static func project(
        projectID: ProjectID,
        rootPath: String,
        detailed: Bool
    ) -> AgentWorkTarget {
        AgentWorkTarget(
            projectID: projectID,
            sessionID: nil,
            rootPath: rootPath,
            isDetailed: detailed
        )
    }
}

struct AgentWorkDidChange: AppEvent {
    static let name = Notification.Name("agentWorkDidChange")
    let projectID: ProjectID
    /// A session change also changes the project aggregate. Nil means only project-wide state.
    let sessionID: SessionID?
}

// MARK: - Store

/// Owns the sparse observed-work cache and the repository atlases used to project it.
///
/// `AgentWorkWorker` owns all trace mutation as well as disk, repository and initial-projection
/// work. Main-actor callbacks receive one bounded delta and update only already-visible bins.
@MainActor
final class AgentWorkTraceStore {
    static let shared = AgentWorkTraceStore()

    private enum Limits {
        /// At most a few screenfuls: enough for fast scroll-back, independent of session count.
        static let presentationCache = 256
        /// A sidebar can expose roughly twenty different project rows at once.
        static let repositoryAtlases = 32
    }

    private enum AtlasLoadState {
        case loading
        case ready(RepositoryFileAtlas)
    }

    fileprivate enum Mutation: Sendable {
        case file(
            sessionID: SessionID,
            sessionTitle: String,
            agentLabel: String,
            kind: AgentFileActivityKind,
            relativePath: String,
            date: Date
        )
        case action(
            sessionID: SessionID,
            sessionTitle: String,
            agentLabel: String,
            category: ExecutionAuditRecord.Category,
            operation: String,
            date: Date
        )
        case observed(
            sessionID: SessionID,
            sessionTitle: String,
            agentLabel: String,
            checkpointOrdinal: Int,
            paths: [String],
            claimedPaths: Set<String>?,
            turnStart: Date,
            turnEnd: Date,
            rootPath: String
        )
        case seed(sessionID: SessionID, trace: AgentSessionWorkTrace)
        case hydrate(
            sessionID: SessionID,
            sessionTitle: String,
            agentLabel: String,
            kind: AgentKind,
            transcript: URL,
            rootPath: String
        )
        case removeSession(SessionID)

        var sessionID: SessionID {
            switch self {
            case .file(let id, _, _, _, _, _),
                 .action(let id, _, _, _, _, _),
                 .observed(let id, _, _, _, _, _, _, _, _),
                 .seed(let id, _),
                 .hydrate(let id, _, _, _, _, _),
                 .removeSession(let id):
                return id
            }
        }
    }

    private struct SeenCalls {
        static let limit = 4_096
        var values: Set<String> = []
        var order: [String] = []

        mutating func insert(_ id: String) -> Bool {
            guard values.insert(id).inserted else { return false }
            order.append(id)
            if order.count > Self.limit {
                let excess = order.count - Self.limit
                values.subtract(order.prefix(excess))
                order.removeFirst(excess)
            }
            return true
        }
    }

    private var preparedProjects: Set<ProjectID> = []
    private var projectRevisions: [ProjectID: Int] = [:]
    private var projectGenerations: [ProjectID: Int] = [:]
    /// Deletion can race a final provider callback. IDs are never reused, so tombstones keep a
    /// late event from recreating the rebuildable cache after ProjectStore removed its owner.
    private var removedProjects: Set<ProjectID> = []
    private var removedSessions: Set<SessionID> = []
    private var atlases: [String: AtlasLoadState] = [:]
    private var presentations: [AgentWorkTarget: AgentWorkPresentation] = [:]
    private var requestedTargets: Set<AgentWorkTarget> = []
    private var presentationOrder: [AgentWorkTarget] = []
    private var presentationTargetsByProject: [ProjectID: Set<AgentWorkTarget>] = [:]
    private var presentationBuilds: Set<AgentWorkTarget> = []
    private var atlasOrder: [String] = []
    private var seenCalls: [SessionID: SeenCalls] = [:]

    private let worker: AgentWorkWorker

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let applicationSupport = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent("AgentWork", isDirectory: true)
        worker = AgentWorkWorker(directory: applicationSupport, fileManager: fileManager)
    }

    // MARK: Presentation

    /// Returns only cached, bounded data. Calling this from row configuration never reads a
    /// repository or iterates a trace; a miss starts that work asynchronously and returns nil.
    func presentation(for target: AgentWorkTarget) -> AgentWorkPresentation? {
        guard !removedProjects.contains(target.projectID),
              target.sessionID.map({ !removedSessions.contains($0) }) ?? true else { return nil }
        noteRequested(target)
        prepareProject(target.projectID)
        prepareAtlas(rootPath: target.rootPath)
        schedulePresentationIfReady(target)
        return presentations[target]
    }

    func cachedPresentation(for target: AgentWorkTarget) -> AgentWorkPresentation? {
        presentations[target]
    }

    /// Resolves exact activity for only the filesystem rows the outline has materialized. Trace
    /// ownership stays on the worker queue; the main actor receives at most one screenful.
    func treeItems(
        for target: AgentWorkTarget,
        paths: [AgentWorkTreePath],
        completion: @escaping @MainActor @Sendable ([String: AgentWorkTreeItem]) -> Void
    ) {
        guard !paths.isEmpty,
              !removedProjects.contains(target.projectID),
              target.sessionID.map({ !removedSessions.contains($0) }) ?? true else {
            completion([:])
            return
        }
        prepareProject(target.projectID)
        let generation = projectGenerations[target.projectID, default: 0]
        worker.treeItems(target: target, paths: paths) { [weak self] items in
            guard let self,
                  self.projectGenerations[target.projectID, default: 0] == generation else {
                completion([:])
                return
            }
            completion(items)
        }
    }

    // MARK: Live capture

    func record(
        providerEvent: ProviderExecutionEvent,
        projectID: ProjectID,
        session: AgentSession,
        rootPath: String,
        at date: Date = Date()
    ) {
        guard !removedProjects.contains(projectID), !removedSessions.contains(session.id),
              providerEvent.phase == .requested,
              seenCall(providerEvent.callID, sessionID: session.id) else { return }

        let operation = providerEvent.operation ?? "tool.update"
        enqueue(.action(
            sessionID: session.id,
            sessionTitle: session.displayTitle,
            agentLabel: session.kind.displayName,
            category: providerEvent.category,
            operation: operation,
            date: date
        ), projectID: projectID)

        guard let input = providerEvent.input?.objectValue else { return }
        for signal in AgentFileActivityClassifier.signals(
            tool: ToolIdentity(operation), input: input
        ) {
            record(
                signal: signal,
                projectID: projectID,
                session: session,
                rootPath: rootPath,
                at: date
            )
        }
    }

    /// Fallback for transports whose provider callback does not expose a particular tool item.
    /// Call IDs deduplicate this against `record(providerEvent:)` whichever arrives first.
    func record(
        streamEvent: StreamEvent,
        projectID: ProjectID,
        session: AgentSession,
        rootPath: String,
        at date: Date = Date()
    ) {
        guard !removedProjects.contains(projectID), !removedSessions.contains(session.id),
              case .assistantMessage(let blocks) = streamEvent else { return }
        for block in blocks {
            guard case .toolUse(let callID, let tool, let input) = block,
                  seenCall(callID, sessionID: session.id) else { continue }
            let operation = tool.rawName
            enqueue(.action(
                sessionID: session.id,
                sessionTitle: session.displayTitle,
                agentLabel: session.kind.displayName,
                category: ExecutionAuditStore.category(for: operation),
                operation: operation,
                date: date
            ), projectID: projectID)
            for signal in AgentFileActivityClassifier.signals(tool: tool, input: input) {
                record(
                    signal: signal,
                    projectID: projectID,
                    session: session,
                    rootPath: rootPath,
                    at: date
                )
            }
        }
    }

    /// Folds a session's own transcript into its trace, from wherever the last pass stopped.
    ///
    /// This is the capture path for a session Threading does not render: its tool calls exist for
    /// us only as bytes in a terminal, while the runtime is writing the same calls to a file we
    /// already know how to read. The pass is incremental and its position is persisted with the
    /// trace, so it can be run on every turn boundary without counting a call twice — including
    /// across relaunches, which the in-memory call-id dedupe cannot cover.
    ///
    /// `AgentWorkHydration` decides *when*, and is the only caller. The rules that keep the
    /// reading honest live in the worker beside the trace they protect.
    func record(
        transcriptAt url: URL,
        kind: AgentKind,
        projectID: ProjectID,
        session: AgentSession,
        rootPath: String
    ) {
        guard !removedProjects.contains(projectID), !removedSessions.contains(session.id) else {
            return
        }
        enqueue(.hydrate(
            sessionID: session.id,
            sessionTitle: session.displayTitle,
            agentLabel: session.kind.displayName,
            kind: kind,
            transcript: url,
            rootPath: rootPath
        ), projectID: projectID)
    }

    /// Folds the files one completed turn changed into the session's trace, as observed changes.
    ///
    /// The neutral floor: `paths` came from the turn's own tree pair, so the set is complete and
    /// unattributed, which is the opposite shape of everything else this store records. Two rules
    /// keep it from overstating itself, and both live in the worker beside the trace: a path the
    /// turn's edit tools *claimed* is already exact and is left alone, and so is one this session
    /// exactly edited inside the turn's own window, which is how a transcript-fed session avoids
    /// counting its own edits a second time as anonymous deltas.
    ///
    /// `checkpointOrdinal` is the resume point. Checkpoints are folded in ascending order and a
    /// tree pair is immutable, so re-reading one would count every path in it again.
    func record(
        observedChanges paths: [String],
        checkpointOrdinal: Int,
        turnStart: Date,
        turnEnd: Date,
        claimedPaths: Set<String>?,
        projectID: ProjectID,
        session: AgentSession,
        rootPath: String
    ) {
        guard !removedProjects.contains(projectID), !removedSessions.contains(session.id) else {
            return
        }
        enqueue(.observed(
            sessionID: session.id,
            sessionTitle: session.displayTitle,
            agentLabel: session.kind.displayName,
            checkpointOrdinal: checkpointOrdinal,
            paths: paths,
            claimedPaths: claimedPaths,
            turnStart: turnStart,
            turnEnd: turnEnd,
            rootPath: rootPath
        ), projectID: projectID)
    }

    /// How far the git-observed floor has been folded in for this session, by checkpoint ordinal.
    /// Nil means no checkpoint has been read yet. Answered from the worker's own copy, so the
    /// caller never reasons about a resume point the queue is halfway through moving.
    func observedCheckpointOrdinal(
        sessionID: SessionID,
        projectID: ProjectID,
        completion: @escaping @MainActor @Sendable (Int?) -> Void
    ) {
        guard !removedProjects.contains(projectID), !removedSessions.contains(sessionID) else {
            completion(nil)
            return
        }
        prepareProject(projectID)
        worker.observedCheckpointOrdinal(
            sessionID: sessionID, projectID: projectID, completion: completion
        )
    }

    /// Seeds a conversation that predates the cache from its bounded transcript replay. It is
    /// deliberately conditional: replaying the same transcript on every launch must not count
    /// the same work again.
    func seedReplayIfEmpty(
        _ events: [StreamEvent],
        projectID: ProjectID,
        session: AgentSession,
        rootPath: String
    ) {
        guard !removedProjects.contains(projectID), !removedSessions.contains(session.id) else {
            return
        }
        let sessionID = session.id
        worker.reduceReplay(
            events: events,
            sessionID: session.id,
            sessionTitle: session.displayTitle,
            agentLabel: session.kind.displayName,
            rootPath: rootPath
        ) { [weak self] trace in
            self?.enqueue(.seed(sessionID: sessionID, trace: trace), projectID: projectID)
        }
    }

    // MARK: Removal

    func remove(sessionID: SessionID, projectID: ProjectID) {
        removedSessions.insert(sessionID)
        seenCalls.removeValue(forKey: sessionID)
        for target in Array(requestedTargets) where target.sessionID == sessionID {
            removeTarget(target)
        }
        enqueue(.removeSession(sessionID), projectID: projectID)
    }

    /// Transfers one rebuildable session trace between checkout aggregates.
    func move(sessionID: SessionID, from sourceProjectID: ProjectID, to targetProjectID: ProjectID) {
        guard sourceProjectID != targetProjectID else { return }
        removedSessions.remove(sessionID)
        seenCalls.removeValue(forKey: sessionID)
        for target in Array(requestedTargets)
        where target.projectID == sourceProjectID || target.projectID == targetProjectID {
            removeTarget(target)
        }
        projectGenerations[sourceProjectID, default: 0] += 1
        projectGenerations[targetProjectID, default: 0] += 1
        worker.move(
            sessionID: sessionID,
            from: sourceProjectID,
            to: targetProjectID
        ) { [weak self] sourceRevision, targetRevision in
            guard let self else { return }
            self.preparedProjects.insert(sourceProjectID)
            self.preparedProjects.insert(targetProjectID)
            self.projectRevisions[sourceProjectID] = sourceRevision
            self.projectRevisions[targetProjectID] = targetRevision
            NotificationCenter.default.post(AgentWorkDidChange(
                projectID: sourceProjectID,
                sessionID: sessionID
            ))
            NotificationCenter.default.post(AgentWorkDidChange(
                projectID: targetProjectID,
                sessionID: sessionID
            ))
        }
    }

    func remove(projectID: ProjectID) {
        removedProjects.insert(projectID)
        preparedProjects.remove(projectID)
        projectRevisions.removeValue(forKey: projectID)
        projectGenerations[projectID, default: 0] += 1
        for target in Array(requestedTargets) where target.projectID == projectID {
            removeTarget(target)
        }
        presentationBuilds = presentationBuilds.filter { $0.projectID != projectID }
        worker.remove(projectID: projectID)
        NotificationCenter.default.post(AgentWorkDidChange(projectID: projectID, sessionID: nil))
    }

    // MARK: Mutation

    private func record(
        signal: AgentFileActivitySignal,
        projectID: ProjectID,
        session: AgentSession,
        rootPath: String,
        at date: Date
    ) {
        guard let path = AgentWorkPath.relative(signal.path, root: rootPath) else { return }
        enqueue(.file(
            sessionID: session.id,
            sessionTitle: session.displayTitle,
            agentLabel: session.kind.displayName,
            kind: signal.kind,
            relativePath: path,
            date: date
        ), projectID: projectID)
    }

    private func enqueue(_ mutation: Mutation, projectID: ProjectID) {
        prepareProject(projectID)
        let generation = projectGenerations[projectID, default: 0]
        worker.apply(mutation, projectID: projectID) { [weak self] change, revision in
            guard let self,
                  self.projectGenerations[projectID, default: 0] == generation else { return }
            self.projectRevisions[projectID] = max(
                self.projectRevisions[projectID, default: 0], revision
            )
            guard let change else { return }
            self.apply(change, projectID: projectID)
            NotificationCenter.default.post(AgentWorkDidChange(
                projectID: projectID,
                sessionID: change.sessionID
            ))
        }
    }

    fileprivate enum AppliedChange: Sendable {
        case file(
            sessionID: SessionID,
            path: String,
            kind: AgentFileActivityKind,
            date: Date,
            firstSessionTouch: Bool,
            firstProjectTouch: Bool,
            contributorCount: Int,
            contributor: AgentWorkContributor
        )
        case action(
            sessionID: SessionID,
            category: ExecutionAuditRecord.Category,
            action: AgentWorkAction,
            contributor: AgentWorkContributor
        )
        case rebuilt(sessionID: SessionID?)

        var sessionID: SessionID? {
            switch self {
            case .file(let id, _, _, _, _, _, _, _), .action(let id, _, _, _): return id
            case .rebuilt(let id): return id
            }
        }
    }

    /// Applies one live fact to already-materialized, bounded presentations. No trace scan is
    /// needed after the first projection, even while a project-wide card watches many agents.
    private func apply(_ change: AppliedChange, projectID: ProjectID) {
        let targets = presentationTargetsByProject[projectID] ?? []
        for target in targets {
            guard target.sessionID == nil || target.sessionID == change.sessionID,
                  let atlas = readyAtlas(rootPath: target.rootPath),
                  var presentation = presentations[target] else { continue }

            switch change {
            case .file(
                _, let path, let kind, let date,
                let firstSession, let firstProject, let contributors, let contributor
            ):
                guard let index = atlas.binIndex(for: path, detail: target.isDetailed),
                      presentation.bins.indices.contains(index) else { continue }
                let first = target.sessionID == nil ? firstProject : firstSession
                presentation.bins[index].record(kind, at: date, isFirstTouch: first)
                presentation.bins[index].contributorCount = max(
                    presentation.bins[index].contributorCount,
                    target.sessionID == nil ? contributors : 1
                )
                if first { presentation.touchedFileCount += 1 }
                if target.sessionID == nil {
                    promoteContributor(contributor, in: &presentation)
                }

            case .action(_, let category, let action, let contributor):
                presentation.categoryCounts[category, default: 0] += 1
                presentation.recentActions.append(action)
                if presentation.recentActions.count > AgentSessionWorkTrace.Limits.recentActions {
                    presentation.recentActions.removeFirst(
                        presentation.recentActions.count - AgentSessionWorkTrace.Limits.recentActions
                    )
                }
                if target.sessionID == nil {
                    promoteContributor(contributor, in: &presentation)
                }

            case .rebuilt:
                removeCachedPresentation(target)
                schedulePresentationIfReady(target)
                continue
            }
            presentations[target] = presentation
        }
    }

    private func promoteContributor(
        _ contributor: AgentWorkContributor,
        in presentation: inout AgentWorkPresentation
    ) {
        presentation.recentContributors.removeAll {
            $0.sessionID == contributor.sessionID
        }
        presentation.recentContributors.insert(contributor, at: 0)
        if presentation.recentContributors.count > 8 {
            presentation.recentContributors.removeLast(
                presentation.recentContributors.count - 8
            )
        }
    }

    private func seenCall(_ callID: String, sessionID: SessionID) -> Bool {
        var seen = seenCalls[sessionID] ?? SeenCalls()
        let inserted = seen.insert(callID)
        seenCalls[sessionID] = seen
        return inserted
    }

    // MARK: Loading and projection

    private func prepareProject(_ projectID: ProjectID) {
        guard preparedProjects.insert(projectID).inserted else { return }
        let generation = projectGenerations[projectID, default: 0]
        worker.prepare(projectID: projectID) { [weak self] revision in
            guard let self,
                  self.projectGenerations[projectID, default: 0] == generation else { return }
            self.projectRevisions[projectID] = max(
                self.projectRevisions[projectID, default: 0], revision
            )
            for target in self.requestedTargets where target.projectID == projectID {
                self.schedulePresentationIfReady(target)
            }
            NotificationCenter.default.post(AgentWorkDidChange(
                projectID: projectID, sessionID: nil
            ))
        }
    }

    private func prepareAtlas(rootPath: String) {
        noteAtlasAccess(rootPath)
        guard atlases[rootPath] == nil else { return }
        atlases[rootPath] = .loading
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        GitReviewReader.repositoryFiles(in: root) { [weak self] result in
            guard let self else { return }
            let files = (try? result.get()) ?? []
            self.worker.buildAtlas(files: files) { [weak self] atlas in
                guard let self else { return }
                self.atlases[rootPath] = .ready(atlas)
                self.trimAtlases()
                for target in self.requestedTargets where target.rootPath == rootPath {
                    self.schedulePresentationIfReady(target)
                }
            }
        }
    }

    private func readyAtlas(rootPath: String) -> RepositoryFileAtlas? {
        guard case .ready(let atlas) = atlases[rootPath] else { return nil }
        return atlas
    }

    private func schedulePresentationIfReady(_ target: AgentWorkTarget) {
        guard presentations[target] == nil, !presentationBuilds.contains(target),
              let atlas = readyAtlas(rootPath: target.rootPath) else { return }

        let generation = projectGenerations[target.projectID, default: 0]
        presentationBuilds.insert(target)
        worker.buildPresentation(target: target, atlas: atlas) {
            [weak self] presentation, revision in
            guard let self else { return }
            self.presentationBuilds.remove(target)
            guard self.requestedTargets.contains(target),
                  self.projectGenerations[target.projectID, default: 0] == generation else {
                return
            }
            guard self.projectRevisions[target.projectID, default: 0] <= revision else {
                self.schedulePresentationIfReady(target)
                return
            }
            self.projectRevisions[target.projectID] = revision
            self.cache(presentation, for: target)
            NotificationCenter.default.post(AgentWorkDidChange(
                projectID: target.projectID,
                sessionID: target.sessionID
            ))
        }
    }

    // MARK: Bounded caches

    private func noteRequested(_ target: AgentWorkTarget) {
        requestedTargets.insert(target)
        presentationOrder.removeAll { $0 == target }
        presentationOrder.append(target)
        while presentationOrder.count > Limits.presentationCache {
            let evicted = presentationOrder.removeFirst()
            requestedTargets.remove(evicted)
            presentationBuilds.remove(evicted)
            removeCachedPresentation(evicted)
        }
    }

    private func cache(_ presentation: AgentWorkPresentation, for target: AgentWorkTarget) {
        presentations[target] = presentation
        presentationTargetsByProject[target.projectID, default: []].insert(target)
    }

    private func removeCachedPresentation(_ target: AgentWorkTarget) {
        presentations.removeValue(forKey: target)
        presentationTargetsByProject[target.projectID]?.remove(target)
        if presentationTargetsByProject[target.projectID]?.isEmpty == true {
            presentationTargetsByProject.removeValue(forKey: target.projectID)
        }
    }

    private func removeTarget(_ target: AgentWorkTarget) {
        requestedTargets.remove(target)
        presentationOrder.removeAll { $0 == target }
        presentationBuilds.remove(target)
        removeCachedPresentation(target)
    }

    private func noteAtlasAccess(_ rootPath: String) {
        atlasOrder.removeAll { $0 == rootPath }
        atlasOrder.append(rootPath)
    }

    private func trimAtlases() {
        while atlasOrder.count > Limits.repositoryAtlases {
            let root = atlasOrder.removeFirst()
            atlases.removeValue(forKey: root)
            for target in Array(requestedTargets) where target.rootPath == root {
                removeTarget(target)
            }
        }
    }

}

// MARK: - Utility worker

/// Incremental descendant totals for one directory. Kept as a value so the worker owns every
/// mutation, while the scaling benchmark can exercise the same update primitive as live capture.
struct AgentDirectoryWork: Sendable {
    var work = AgentFileWork()
    var touchedFileCount = 0
    var contributors: Set<SessionID> = []

    mutating func merge(
        _ other: AgentFileWork,
        touchedFileCount: Int,
        contributors: Set<SessionID>
    ) {
        work.merge(other)
        self.touchedFileCount += touchedFileCount
        self.contributors.formUnion(contributors)
    }

    mutating func record(
        _ kind: AgentFileActivityKind,
        at date: Date,
        isFirstTouch: Bool,
        contributor: SessionID
    ) {
        work.record(kind, at: date)
        if isFirstTouch { touchedFileCount += 1 }
        contributors.insert(contributor)
    }

    mutating func recordObservedChange(
        at date: Date,
        isFirstTouch: Bool,
        contributor: SessionID
    ) {
        work.recordObservedChange(at: date)
        if isFirstTouch { touchedFileCount += 1 }
        contributors.insert(contributor)
    }
}

/// A serial owner for filesystem and total-content work. Keeping it outside the main-actor store
/// makes the isolation boundary explicit and testable by construction.
private final class AgentWorkWorker: @unchecked Sendable {
    private struct SaveKey: Hashable {
        let projectID: ProjectID
        let sessionID: SessionID
    }

    /// The sole owner of mutable traces. Projection and JSON work may delay a following event,
    /// but can never make that event copy or scan project state on the main actor.
    private let queue = DispatchQueue(label: "codes.threading.agent-work.state", qos: .utility)
    /// Repository sorting and replay reduction do not need trace state and should not hold it up.
    private let topologyQueue = DispatchQueue(
        label: "codes.threading.agent-work.topology", qos: .utility
    )
    private let directory: URL
    private let fileManager: FileManager
    private var projects: [ProjectID: ProjectMemory] = [:]
    /// Trailing coalescing is per session. A busy agent rewrites only its own sparse trace and
    /// never the other hundreds of conversations in the same project.
    private var saveGenerations: [SaveKey: Int] = [:]

    private final class ProjectMemory {
        var file: AgentProjectWorkFile
        var aggregate: AgentProjectWorkAggregate
        var sessionDirectories: [SessionID: [String: AgentDirectoryWork]] = [:]
        var projectDirectories: [String: AgentDirectoryWork] = [:]
        var revision = 0

        init(file: AgentProjectWorkFile) {
            self.file = file
            aggregate = AgentProjectWorkAggregate(traces: file.sessions)
            rebuildDirectories()
        }

        func rebuildDirectories() {
            sessionDirectories = [:]
            projectDirectories = [:]

            for (sessionID, trace) in file.sessions {
                for (path, work) in trace.files {
                    for directory in AgentWorkPath.directoryAncestors(of: path) {
                        sessionDirectories[sessionID, default: [:]][
                            directory, default: AgentDirectoryWork()
                        ]
                            .merge(work, touchedFileCount: 1, contributors: [sessionID])
                    }
                }
            }
            for (path, fileWork) in aggregate.files {
                for directory in AgentWorkPath.directoryAncestors(of: path) {
                    projectDirectories[directory, default: AgentDirectoryWork()].merge(
                        fileWork.work,
                        touchedFileCount: 1,
                        contributors: fileWork.contributors
                    )
                }
            }
        }
    }

    init(directory: URL, fileManager: FileManager) {
        self.directory = directory
        self.fileManager = fileManager
    }

    func prepare(
        projectID: ProjectID,
        completion: @escaping @MainActor @Sendable (Int) -> Void
    ) {
        queue.async { [self] in
            let revision = memory(for: projectID).revision
            Task { @MainActor in completion(revision) }
        }
    }

    func observedCheckpointOrdinal(
        sessionID: SessionID,
        projectID: ProjectID,
        completion: @escaping @MainActor @Sendable (Int?) -> Void
    ) {
        queue.async { [self] in
            let ordinal = memory(for: projectID)
                .file.sessions[sessionID]?.observedCheckpointOrdinal
            Task { @MainActor in completion(ordinal) }
        }
    }

    func apply(
        _ mutation: AgentWorkTraceStore.Mutation,
        projectID: ProjectID,
        completion: @escaping @MainActor @Sendable (
            AgentWorkTraceStore.AppliedChange?, Int
        ) -> Void
    ) {
        queue.async { [self] in
            let memory = memory(for: projectID)
            let revisionBefore = memory.revision
            let change = Self.apply(mutation, to: memory, fileManager: fileManager)
            // Revision rather than `change != nil`: a hydration pass that found no new work still
            // moved the transcript's resume position, and losing that means re-reading — and
            // re-counting — everything before it after the next launch.
            if memory.revision != revisionBefore {
                switch mutation {
                case .removeSession(let sessionID):
                    removePersistedSession(
                        sessionID,
                        projectID: projectID,
                        remaining: memory.file
                    )
                default:
                    scheduleSave(projectID, sessionID: mutation.sessionID)
                }
            }
            let revision = memory.revision
            Task { @MainActor in completion(change, revision) }
        }
    }

    func move(
        sessionID: SessionID,
        from sourceProjectID: ProjectID,
        to targetProjectID: ProjectID,
        completion: @escaping @MainActor @Sendable (Int, Int) -> Void
    ) {
        queue.async { [self] in
            let source = memory(for: sourceProjectID)
            let target = memory(for: targetProjectID)
            if let trace = source.file.sessions.removeValue(forKey: sessionID) {
                target.file.sessions[sessionID] = trace
                source.aggregate = AgentProjectWorkAggregate(traces: source.file.sessions)
                target.aggregate = AgentProjectWorkAggregate(traces: target.file.sessions)
                source.rebuildDirectories()
                target.rebuildDirectories()
                source.revision += 1
                target.revision += 1
                removePersistedSession(
                    sessionID,
                    projectID: sourceProjectID,
                    remaining: source.file
                )
                scheduleSave(targetProjectID, sessionID: sessionID)
            }
            let sourceRevision = source.revision
            let targetRevision = target.revision
            Task { @MainActor in completion(sourceRevision, targetRevision) }
        }
    }

    func remove(projectID: ProjectID) {
        queue.async { [self] in
            saveGenerations = saveGenerations.filter { $0.key.projectID != projectID }
            projects.removeValue(forKey: projectID)
            try? fileManager.removeItem(at: Self.url(projectID: projectID, directory: directory))
            try? fileManager.removeItem(
                at: Self.sessionDirectory(projectID: projectID, directory: directory)
            )
        }
    }

    func buildAtlas(
        files: [String],
        completion: @escaping @MainActor @Sendable (RepositoryFileAtlas) -> Void
    ) {
        topologyQueue.async {
            let atlas = RepositoryFileAtlas(files: files)
            Task { @MainActor in completion(atlas) }
        }
    }

    func buildPresentation(
        target: AgentWorkTarget,
        atlas: RepositoryFileAtlas,
        completion: @escaping @MainActor @Sendable (AgentWorkPresentation, Int) -> Void
    ) {
        queue.async { [self] in
            let memory = memory(for: target.projectID)
            let presentation: AgentWorkPresentation
            if let sessionID = target.sessionID {
                presentation = .session(
                    memory.file.sessions[sessionID] ?? AgentSessionWorkTrace(),
                    sessionID: sessionID,
                    atlas: atlas,
                    detailed: target.isDetailed
                )
            } else {
                presentation = .project(
                    memory.aggregate,
                    traces: memory.file.sessions,
                    projectID: target.projectID,
                    atlas: atlas,
                    detailed: target.isDetailed
                )
            }
            let revision = memory.revision
            Task { @MainActor in completion(presentation, revision) }
        }
    }

    func treeItems(
        target: AgentWorkTarget,
        paths: [AgentWorkTreePath],
        completion: @escaping @MainActor @Sendable ([String: AgentWorkTreeItem]) -> Void
    ) {
        queue.async { [self] in
            let memory = memory(for: target.projectID)
            var items: [String: AgentWorkTreeItem] = [:]
            items.reserveCapacity(paths.count)

            for path in paths {
                if path.isDirectory {
                    let directory = target.sessionID.flatMap {
                        memory.sessionDirectories[$0]?[path.relativePath]
                    } ?? (target.sessionID == nil
                        ? memory.projectDirectories[path.relativePath]
                        : nil)
                    guard let directory, directory.work.isTouched else { continue }
                    items[path.relativePath] = AgentWorkTreeItem(
                        relativePath: path.relativePath,
                        isDirectory: true,
                        work: directory.work,
                        touchedFileCount: directory.touchedFileCount,
                        contributorCount: directory.contributors.count
                    )
                } else if let sessionID = target.sessionID,
                          let work = memory.file.sessions[sessionID]?.files[path.relativePath] {
                    items[path.relativePath] = AgentWorkTreeItem(
                        relativePath: path.relativePath,
                        isDirectory: false,
                        work: work,
                        touchedFileCount: work.isTouched ? 1 : 0,
                        contributorCount: work.isTouched ? 1 : 0
                    )
                } else if target.sessionID == nil,
                          let file = memory.aggregate.files[path.relativePath] {
                    items[path.relativePath] = AgentWorkTreeItem(
                        relativePath: path.relativePath,
                        isDirectory: false,
                        work: file.work,
                        touchedFileCount: file.work.isTouched ? 1 : 0,
                        contributorCount: file.contributors.count
                    )
                }
            }
            Task { @MainActor in completion(items) }
        }
    }

    func reduceReplay(
        events: [StreamEvent],
        sessionID: SessionID,
        sessionTitle: String,
        agentLabel: String,
        rootPath: String,
        completion: @escaping @MainActor @Sendable (AgentSessionWorkTrace) -> Void
    ) {
        topologyQueue.async {
            var trace = AgentSessionWorkTrace()
            trace.sessionTitle = sessionTitle
            trace.agentLabel = agentLabel
            // Replay has no timestamp in `StreamEvent`. Distant-past heat preserves the
            // footprint without falsely presenting old work as a fresh live glow.
            let date = Date.distantPast
            for event in events {
                guard case .assistantMessage(let blocks) = event else { continue }
                for block in blocks {
                    guard case .toolUse(_, let tool, let input) = block else { continue }
                    trace.recordAction(
                        category: ExecutionAuditStore.category(for: tool.rawName),
                        operation: tool.rawName,
                        at: date,
                        sessionID: sessionID
                    )
                    for signal in AgentFileActivityClassifier.signals(tool: tool, input: input) {
                        _ = trace.recordFile(
                            signal.kind, path: signal.path, root: rootPath, at: date
                        )
                    }
                }
            }
            Task { @MainActor in completion(trace) }
        }
    }

    private func memory(for projectID: ProjectID) -> ProjectMemory {
        if let existing = projects[projectID] { return existing }
        let file = Self.load(
            projectID: projectID,
            directory: directory,
            fileManager: fileManager
        )
        let memory = ProjectMemory(file: file)
        projects[projectID] = memory
        return memory
    }

    private func scheduleSave(_ projectID: ProjectID, sessionID: SessionID) {
        let key = SaveKey(projectID: projectID, sessionID: sessionID)
        let generation = saveGenerations[key, default: 0] + 1
        saveGenerations[key] = generation
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, saveGenerations[key] == generation,
                  let trace = projects[projectID]?.file.sessions[sessionID] else { return }
            saveGenerations.removeValue(forKey: key)
            _ = Self.sessionPersistence(
                projectID: projectID,
                sessionID: sessionID,
                directory: directory,
                fileManager: fileManager
            ).save(trace)
        }
    }

    private static func apply(
        _ mutation: AgentWorkTraceStore.Mutation,
        to memory: ProjectMemory,
        fileManager: FileManager
    ) -> AgentWorkTraceStore.AppliedChange? {
        switch mutation {
        case .file(let sessionID, let title, let agent, let kind, let path, let date):
            var trace = memory.file.sessions[sessionID] ?? AgentSessionWorkTrace()
            let firstSession = trace.files[path]?.isTouched != true
            trace.sessionTitle = title
            trace.agentLabel = agent
            trace.files[path, default: AgentFileWork()].record(kind, at: date)
            trace.lastActivity = max(trace.lastActivity ?? date, date)
            memory.file.sessions[sessionID] = trace

            let firstProject = memory.aggregate.files[path]?.work.isTouched != true
            memory.aggregate.recordFile(kind, path: path, sessionID: sessionID, at: date)
            for directory in AgentWorkPath.directoryAncestors(of: path) {
                memory.sessionDirectories[sessionID, default: [:]][
                    directory, default: AgentDirectoryWork()
                ]
                    .record(
                        kind, at: date, isFirstTouch: firstSession, contributor: sessionID
                    )
                memory.projectDirectories[directory, default: AgentDirectoryWork()].record(
                    kind, at: date, isFirstTouch: firstProject, contributor: sessionID
                )
            }
            memory.revision += 1
            return .file(
                sessionID: sessionID, path: path, kind: kind, date: date,
                firstSessionTouch: firstSession, firstProjectTouch: firstProject,
                contributorCount: memory.aggregate.files[path]?.contributors.count ?? 1,
                contributor: contributor(sessionID: sessionID, trace: trace)
            )

        case .action(let sessionID, let title, let agent, let category, let operation, let date):
            var trace = memory.file.sessions[sessionID] ?? AgentSessionWorkTrace()
            trace.sessionTitle = title
            trace.agentLabel = agent
            trace.recordAction(
                category: category,
                operation: operation,
                at: date,
                sessionID: sessionID
            )
            memory.file.sessions[sessionID] = trace
            memory.aggregate.recordAction(
                category: category,
                operation: operation,
                sessionID: sessionID,
                at: date
            )
            memory.revision += 1
            guard let action = trace.recentActions.last else { return nil }
            return .action(
                sessionID: sessionID,
                category: category,
                action: action,
                contributor: contributor(sessionID: sessionID, trace: trace)
            )

        case .hydrate(
            let sessionID, let title, let agent, let kind, let transcript, let rootPath
        ):
            var trace = memory.file.sessions[sessionID] ?? AgentSessionWorkTrace()
            let size = Self.fileSize(of: transcript, fileManager: fileManager)

            // A transcript that shrank is not this one any more — a fork copied over it, a
            // rollout was rewritten, a file was replaced by an import. Keeping the old counts and
            // reading the new file from the old position would mix two conversations, so the
            // session starts over from the top of what is there now.
            if let consumed = trace.transcriptOffset, size < consumed {
                memory.file.sessions[sessionID] = AgentSessionWorkTrace()
                memory.aggregate.remove(
                    trace, sessionID: sessionID, remainingTraces: memory.file.sessions
                )
                memory.rebuildDirectories()
                trace = AgentSessionWorkTrace()
            }

            // Work already recorded, but never from this file: the conversation was rendered
            // natively and is now in a terminal (or the other way about). Its calls are in the
            // trace once already, so the transcript is adopted at its current end and only what
            // happens next is counted.
            if trace.transcriptOffset == nil, !trace.files.isEmpty || !trace.categoryCounts.isEmpty {
                trace.transcriptOffset = size
                trace.sessionTitle = title
                trace.agentLabel = agent
                memory.file.sessions[sessionID] = trace
                memory.revision += 1
                return nil
            }

            let start = trace.transcriptOffset ?? 0
            // The whole cost of a pass that has nothing to do: one file-size comparison, on this
            // queue. Turn ends, activity edges and tab openings can all ask freely.
            guard size > start else { return nil }

            let scan = TranscriptReplay.toolCalls(at: transcript, kind: kind, from: start)
            trace.sessionTitle = title
            trace.agentLabel = agent
            trace.transcriptOffset = scan.endOffset
            memory.file.sessions[sessionID] = trace
            memory.revision += 1

            // Each call is applied as the live path applies it, so the aggregate and the
            // incremental directory totals stay O(new work). The first shape of this folded a
            // whole delta trace in and called `rebuildDirectories`, which is O(every file every
            // session in the project has ever touched) — per turn, for a reading that changed
            // one directory.
            var recorded = false
            for call in scan.calls {
                let operation = call.tool.rawName
                _ = Self.apply(.action(
                    sessionID: sessionID,
                    sessionTitle: title,
                    agentLabel: agent,
                    category: ExecutionAuditStore.category(for: operation),
                    operation: operation,
                    date: call.date
                ), to: memory, fileManager: fileManager)
                recorded = true

                for signal in AgentFileActivityClassifier.signals(
                    tool: call.tool, input: call.input
                ) {
                    guard let path = AgentWorkPath.relative(signal.path, root: rootPath) else {
                        continue
                    }
                    _ = Self.apply(.file(
                        sessionID: sessionID,
                        sessionTitle: title,
                        agentLabel: agent,
                        kind: signal.kind,
                        relativePath: path,
                        date: call.date
                    ), to: memory, fileManager: fileManager)
                }
            }

            // One rebuild for the whole pass rather than a change per call: a turn's calls land
            // together, and the bounded projection is cheaper once than N incremental patches of
            // the same presentation.
            return recorded ? .rebuilt(sessionID: sessionID) : nil

        case .observed(
            let sessionID, let title, let agent, let ordinal, let paths,
            let claimedPaths, let turnStart, let turnEnd, let rootPath
        ):
            var trace = memory.file.sessions[sessionID] ?? AgentSessionWorkTrace()

            // Ascending and once only. A checkpoint's trees are immutable, so a second pass over
            // the same turn would add every path in it again — the floor's equivalent of
            // re-counting a transcript from the top.
            if let consumed = trace.observedCheckpointOrdinal, ordinal <= consumed { return nil }
            trace.sessionTitle = title
            trace.agentLabel = agent
            trace.observedCheckpointOrdinal = ordinal
            memory.file.sessions[sessionID] = trace
            // Bumped even when the turn changed nothing, so the resume point is saved: losing it
            // means re-reading, and re-counting, every checkpoint before it after a relaunch.
            memory.revision += 1

            var recorded = false
            for suppliedPath in paths {
                guard let path = AgentWorkPath.relative(suppliedPath, root: rootPath) else {
                    continue
                }
                // A path this turn's edit tools named is already exact; saying it again as an
                // anonymous delta would double a file the panel can attribute properly.
                if claimedPaths?.contains(path) == true { continue }
                let existing = memory.file.sessions[sessionID]?.files[path]
                if existing?.wasEdited(between: turnStart, and: turnEnd) == true { continue }

                var session = memory.file.sessions[sessionID] ?? AgentSessionWorkTrace()
                let firstSession = session.files[path]?.isTouched != true
                session.files[path, default: AgentFileWork()].recordObservedChange(at: turnEnd)
                session.lastActivity = max(session.lastActivity ?? turnEnd, turnEnd)
                memory.file.sessions[sessionID] = session

                let firstProject = memory.aggregate.files[path]?.work.isTouched != true
                memory.aggregate.recordObservedChange(
                    path: path, sessionID: sessionID, at: turnEnd
                )
                for directory in AgentWorkPath.directoryAncestors(of: path) {
                    memory.sessionDirectories[sessionID, default: [:]][
                        directory, default: AgentDirectoryWork()
                    ]
                        .recordObservedChange(
                            at: turnEnd, isFirstTouch: firstSession, contributor: sessionID
                        )
                    memory.projectDirectories[directory, default: AgentDirectoryWork()]
                        .recordObservedChange(
                            at: turnEnd, isFirstTouch: firstProject, contributor: sessionID
                        )
                }
                recorded = true
            }

            // One projection rebuild for the whole turn rather than one per path: a turn's
            // changed files land together, and the bounded projection is cheaper once.
            return recorded ? .rebuilt(sessionID: sessionID) : nil

        case .seed(let sessionID, let seed):
            let current = memory.file.sessions[sessionID] ?? AgentSessionWorkTrace()
            guard current.files.isEmpty, current.categoryCounts.isEmpty else { return nil }
            memory.file.sessions[sessionID] = seed
            memory.aggregate.merge(seed, sessionID: sessionID)
            memory.rebuildDirectories()
            memory.revision += 1
            return .rebuilt(sessionID: sessionID)

        case .removeSession(let sessionID):
            guard let removed = memory.file.sessions.removeValue(forKey: sessionID) else {
                return nil
            }
            memory.aggregate.remove(
                removed,
                sessionID: sessionID,
                remainingTraces: memory.file.sessions
            )
            memory.rebuildDirectories()
            memory.revision += 1
            return .rebuilt(sessionID: sessionID)
        }
    }

    /// Zero for a file that is not there, which reads as "nothing new" against any position
    /// already consumed and starts a never-hydrated trace at the top.
    private static func fileSize(of url: URL, fileManager: FileManager) -> UInt64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func contributor(
        sessionID: SessionID,
        trace: AgentSessionWorkTrace
    ) -> AgentWorkContributor {
        AgentWorkContributor(
            sessionID: sessionID,
            sessionTitle: trace.sessionTitle,
            agentLabel: trace.agentLabel,
            touchedFileCount: trace.touchedFileCount,
            actionCount: trace.totalActionCount,
            lastActivity: trace.lastActivity
        )
    }

    /// Loads session shards one at a time. The legacy project document is overlaid first so an
    /// interrupted migration can only retain an older trace, never erase a newer shard.
    private static func load(
        projectID: ProjectID,
        directory: URL,
        fileManager: FileManager
    ) -> AgentProjectWorkFile {
        let legacyURL = url(projectID: projectID, directory: directory)
        let hadLegacy = fileManager.fileExists(atPath: legacyURL.path)
        var file = legacyPersistence(
            projectID: projectID,
            directory: directory,
            fileManager: fileManager
        ).load(defaultValue: AgentProjectWorkFile()) { file in
            guard file.version == AgentProjectWorkFile.currentVersion else {
                throw AgentWorkPersistenceError.unsupportedVersion(file.version)
            }
        }.value

        let shardDirectory = sessionDirectory(projectID: projectID, directory: directory)
        let shards = (try? fileManager.contentsOfDirectory(
            at: shardDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for shard in shards where shard.pathExtension == "json" {
            guard let sessionID = SessionID(
                uuidString: shard.deletingPathExtension().lastPathComponent
            ) else { continue }
            let trace = sessionPersistence(
                projectID: projectID,
                sessionID: sessionID,
                directory: directory,
                fileManager: fileManager
            ).load(defaultValue: AgentSessionWorkTrace()).value
            file.sessions[sessionID] = trace
        }

        // This cache is rebuildable, but migration still uses write-then-delete. A failed shard
        // leaves the old whole document in place and the next launch retries; a successful pass
        // removes the source of the 6.6 MB whole-project rewrites permanently.
        if hadLegacy {
            var migrated = true
            for (sessionID, trace) in file.sessions {
                if !sessionPersistence(
                    projectID: projectID,
                    sessionID: sessionID,
                    directory: directory,
                    fileManager: fileManager
                ).save(trace) {
                    migrated = false
                }
            }
            if migrated { try? fileManager.removeItem(at: legacyURL) }
        }
        return file
    }

    private func removePersistedSession(
        _ sessionID: SessionID,
        projectID: ProjectID,
        remaining: AgentProjectWorkFile
    ) {
        saveGenerations.removeValue(forKey: SaveKey(
            projectID: projectID,
            sessionID: sessionID
        ))
        try? fileManager.removeItem(at: Self.sessionURL(
            projectID: projectID,
            sessionID: sessionID,
            directory: directory
        ))

        // Only possible after an interrupted legacy migration. Keep that fallback honest so a
        // deleted session cannot reappear if the machine loses power before migration retries.
        let legacyURL = Self.url(projectID: projectID, directory: directory)
        if fileManager.fileExists(atPath: legacyURL.path) {
            _ = Self.legacyPersistence(
                projectID: projectID,
                directory: directory,
                fileManager: fileManager
            ).save(remaining)
        }
    }

    private static func legacyPersistence(
        projectID: ProjectID,
        directory: URL,
        fileManager: FileManager
    ) -> RecoverableFileStore<AgentProjectWorkFile> {
        RecoverableFileStore(
            url: url(projectID: projectID, directory: directory),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .millisecondsSince1970,
            dateDecodingStrategy: .millisecondsSince1970
        )
    }

    private static func sessionPersistence(
        projectID: ProjectID,
        sessionID: SessionID,
        directory: URL,
        fileManager: FileManager
    ) -> RecoverableFileStore<AgentSessionWorkTrace> {
        RecoverableFileStore(
            url: sessionURL(
                projectID: projectID,
                sessionID: sessionID,
                directory: directory
            ),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            sizePolicy: .derivedCache,
            dateEncodingStrategy: .millisecondsSince1970,
            dateDecodingStrategy: .millisecondsSince1970
        )
    }

    private static func url(projectID: ProjectID, directory: URL) -> URL {
        directory.appendingPathComponent(projectID.uuidString.lowercased() + ".json")
    }

    private static func sessionDirectory(projectID: ProjectID, directory: URL) -> URL {
        directory.appendingPathComponent(
            projectID.uuidString.lowercased() + ".sessions",
            isDirectory: true
        )
    }

    private static func sessionURL(
        projectID: ProjectID,
        sessionID: SessionID,
        directory: URL
    ) -> URL {
        sessionDirectory(projectID: projectID, directory: directory)
            .appendingPathComponent(sessionID.uuidString.lowercased() + ".json")
    }
}

private enum AgentWorkPersistenceError: Error {
    case unsupportedVersion(Int)
}
