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
        case seed(sessionID: SessionID, trace: AgentSessionWorkTrace)
        case removeSession(SessionID)
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
}

/// A serial owner for filesystem and total-content work. Keeping it outside the main-actor store
/// makes the isolation boundary explicit and testable by construction.
private final class AgentWorkWorker: @unchecked Sendable {
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
    private var saveGenerations: [ProjectID: Int] = [:]

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

    func apply(
        _ mutation: AgentWorkTraceStore.Mutation,
        projectID: ProjectID,
        completion: @escaping @MainActor @Sendable (
            AgentWorkTraceStore.AppliedChange?, Int
        ) -> Void
    ) {
        queue.async { [self] in
            let memory = memory(for: projectID)
            let change = Self.apply(mutation, to: memory)
            if change != nil { scheduleSave(projectID) }
            let revision = memory.revision
            Task { @MainActor in completion(change, revision) }
        }
    }

    func remove(projectID: ProjectID) {
        queue.async { [self] in
            saveGenerations.removeValue(forKey: projectID)
            projects.removeValue(forKey: projectID)
            try? fileManager.removeItem(at: Self.url(projectID: projectID, directory: directory))
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
        let store = Self.persistence(
            projectID: projectID, directory: directory, fileManager: fileManager
        )
        let file = store.load(defaultValue: AgentProjectWorkFile()) { file in
            guard file.version == AgentProjectWorkFile.currentVersion else {
                throw AgentWorkPersistenceError.unsupportedVersion(file.version)
            }
        }.value
        let memory = ProjectMemory(file: file)
        projects[projectID] = memory
        return memory
    }

    private func scheduleSave(_ projectID: ProjectID) {
        let generation = saveGenerations[projectID, default: 0] + 1
        saveGenerations[projectID] = generation
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, saveGenerations[projectID] == generation,
                  let memory = projects[projectID] else { return }
            saveGenerations.removeValue(forKey: projectID)
            _ = Self.persistence(
                projectID: projectID, directory: directory, fileManager: fileManager
            ).save(memory.file)
        }
    }

    private static func apply(
        _ mutation: AgentWorkTraceStore.Mutation,
        to memory: ProjectMemory
    ) -> AgentWorkTraceStore.AppliedChange? {
        switch mutation {
        case .file(let sessionID, let title, let agent, let kind, let path, let date):
            if memory.file.sessions[sessionID] == nil {
                memory.file.sessions[sessionID] = AgentSessionWorkTrace()
            }
            let firstSession = memory.file.sessions[sessionID]?.files[path]?.isTouched != true
            memory.file.sessions[sessionID]!.sessionTitle = title
            memory.file.sessions[sessionID]!.agentLabel = agent
            memory.file.sessions[sessionID]!.files[path, default: AgentFileWork()]
                .record(kind, at: date)
            let previousActivity = memory.file.sessions[sessionID]!.lastActivity
            memory.file.sessions[sessionID]!.lastActivity = max(previousActivity ?? date, date)
            let trace = memory.file.sessions[sessionID]!

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
            if memory.file.sessions[sessionID] == nil {
                memory.file.sessions[sessionID] = AgentSessionWorkTrace()
            }
            memory.file.sessions[sessionID]!.sessionTitle = title
            memory.file.sessions[sessionID]!.agentLabel = agent
            memory.file.sessions[sessionID]!.recordAction(
                category: category,
                operation: operation,
                at: date,
                sessionID: sessionID
            )
            let trace = memory.file.sessions[sessionID]!
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

    private static func persistence(
        projectID: ProjectID,
        directory: URL,
        fileManager: FileManager
    ) -> RecoverableFileStore<AgentProjectWorkFile> {
        RecoverableFileStore(
            url: url(projectID: projectID, directory: directory),
            fileManager: fileManager,
            criticality: .rebuildableCache,
            dateEncodingStrategy: .millisecondsSince1970,
            dateDecodingStrategy: .millisecondsSince1970
        )
    }

    private static func url(projectID: ProjectID, directory: URL) -> URL {
        directory.appendingPathComponent(projectID.uuidString.lowercased() + ".json")
    }
}

private enum AgentWorkPersistenceError: Error {
    case unsupportedVersion(Int)
}
