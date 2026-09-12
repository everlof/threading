import Foundation

final class TranscriptSearchProvider: UniversalSearchProvider, @unchecked Sendable {
    let id: SearchProviderID = .transcript
    private let index: TranscriptSearchIndex?

    init(index: TranscriptSearchIndex?) {
        self.index = index
    }

    func search(_ request: SearchProviderRequest) -> AsyncStream<SearchBatch> {
        let pair = AsyncStream<SearchBatch>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task(priority: .userInitiated) { [index, id] in
            let result: TranscriptSearchIndexResult
            if let index {
                result = await index.search(request.query)
            } else {
                result = TranscriptSearchIndexResult(
                    hits: [],
                    coverage: .unavailable(reason: L10n.string(
                        "Conversation history search is unavailable."
                    )),
                    isCapped: false
                )
            }
            guard !Task.isCancelled else {
                pair.continuation.finish()
                return
            }
            pair.continuation.yield(SearchBatch(
                queryGeneration: request.query.generation,
                provider: id,
                group: .conversations,
                hits: result.hits,
                coverage: result.coverage,
                continuation: nil,
                isCapped: result.isCapped
            ))
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }
}

struct TranscriptSearchIndexDidChange: AppEvent {
    static let name = Notification.Name("transcriptSearchIndexDidChange")
}

/// Copies live project/account metadata on the main actor and drives the search actor with
/// complete structural snapshots and coalesced work-source updates. Opening Search only asks for
/// a provider; it never starts a walk.
///
/// **The projection reads no directory on the main actor.** Placing a Codex conversation means
/// finding its rollout in the account's sessions tree, and a retained catalogue is mostly
/// conversations whose rollout is gone — 311 of 343 on the machine that reported the stall —
/// so a projection that looked for each of them walked the same tree once per session, on
/// the main actor, inside a store-change observer: 1.7–3.7 s per sidebar click. The main-actor
/// pass now asks only for what is already known; the accounts it could not place are read once
/// each on a worker, and the sessions on them are projected again from that answer.
@MainActor
final class TranscriptSearchIndexStore {
    private let projectStore: ProjectStore
    private let events: AppEventObservations
    private let index: TranscriptSearchIndex?
    private let resolveAccount: TranscriptSearchProjection.AccountResolver
    private var sourcesByProjectID: [ProjectID: [SessionID: TranscriptSearchSource]] = [:]
    private var projectNames: [ProjectID: String] = [:]
    private var refreshTask: Task<Void, Never>?
    private var needsFullRefresh = false
    private var pendingWorkSources: [SessionID: TranscriptSearchSource] = [:]
    /// Accounts whose sessions tree has to be read before their conversations can be placed,
    /// keyed by config path so a pass over many sessions names each account once.
    private var accountsAwaitingRollouts: [String: AgentAccount] = [:]
    private var rolloutDiscoveryTask: Task<Void, Never>?

    init(
        projectStore: ProjectStore = .shared,
        databaseURL: URL = StateManager.shared.transcriptSearchIndexURL(),
        notificationCenter: NotificationCenter = .default,
        accountResolver: @escaping TranscriptSearchProjection.AccountResolver =
            TranscriptSearchProjection.discoveredAccount
    ) {
        self.projectStore = projectStore
        resolveAccount = accountResolver
        events = AppEventObservations(center: notificationCenter)
        index = try? TranscriptSearchIndex(databaseURL: databaseURL)
        events.observe(ProjectsDidChange.self) { [weak self] event in
            self?.projectsDidChange(event)
        }
        events.observe(SessionWorkDidChange.self) { [weak self] event in
            self?.workDidChange(event.sessionID)
        }
        rebuildAll()
    }

    deinit {
        refreshTask?.cancel()
        rolloutDiscoveryTask?.cancel()
    }

    /// How many conversations the store has placed so far. A test's evidence that the
    /// main-actor pass placed nothing it would have had to walk for, and that the worker's
    /// walk placed the rest.
    var projectedSourceCount: Int {
        sourcesByProjectID.values.reduce(0) { $0 + $1.count }
    }

    func provider() -> TranscriptSearchProvider {
        TranscriptSearchProvider(index: index)
    }

    func conversationWindowLoader() -> ConversationWindowLoader? {
        index.map(ConversationWindowLoader.init(index:))
    }

    private func projectsDidChange(_ event: ProjectsDidChange) {
        switch event.sidebarImpact {
        case .structure:
            rebuildAll()
        case .projectRemoved(let projectID, _, _):
            sourcesByProjectID.removeValue(forKey: projectID)
            projectNames.removeValue(forKey: projectID)
            scheduleRefresh()
        case .projectStructure(let projectID):
            replaceProject(projectID)
        case .projectRow(let projectID):
            guard let project = projectStore.project(withID: projectID) else { return }
            guard projectNames[projectID] != project.name else { return }
            projectNames[projectID] = project.name
            scheduleRefresh()
        case .sessionAdded(let projectID, let sessionID),
             .sessionStructure(let projectID, let sessionID):
            replaceSession(sessionID, in: projectID)
        case .sessionTitle(let sessionID, _), .sessionRow(let sessionID):
            guard let projectID = projectStore.project(forSessionID: sessionID)?.id else { return }
            replaceSession(sessionID, in: projectID)
        case .sessionRemoved(let projectID, let sessionID):
            sourcesByProjectID[projectID]?.removeValue(forKey: sessionID)
            scheduleRefresh()
        case .terminalAdded, .terminalRow:
            break
        }
    }

    private func rebuildAll() {
        sourcesByProjectID = Dictionary(uniqueKeysWithValues: projectStore.projects.map { project in
            (project.id, keyed(project.sessions.compactMap { projected($0, in: project) }))
        })
        projectNames = Dictionary(uniqueKeysWithValues: projectStore.projects.map {
            ($0.id, $0.name)
        })
        scheduleRefresh()
        scheduleRolloutDiscovery()
    }

    private func replaceProject(_ projectID: ProjectID) {
        guard let project = projectStore.project(withID: projectID) else {
            sourcesByProjectID.removeValue(forKey: projectID)
            projectNames.removeValue(forKey: projectID)
            scheduleRefresh()
            return
        }
        sourcesByProjectID[projectID] = keyed(
            project.sessions.compactMap { projected($0, in: project) }
        )
        projectNames[projectID] = project.name
        scheduleRefresh()
        scheduleRolloutDiscovery()
    }

    private func replaceSession(_ sessionID: SessionID, in projectID: ProjectID) {
        guard let project = projectStore.project(withID: projectID),
              let session = projectStore.session(withID: sessionID) else {
            sourcesByProjectID[projectID]?.removeValue(forKey: sessionID)
            scheduleRefresh()
            return
        }
        if let source = projected(session, in: project) {
            sourcesByProjectID[projectID, default: [:]][sessionID] = source
        } else {
            sourcesByProjectID[projectID]?.removeValue(forKey: sessionID)
        }
        projectNames[projectID] = project.name
        scheduleRefresh()
        scheduleRolloutDiscovery()
    }

    /// The session's source from what is already known — dictionary reads, whatever the
    /// catalogue's size. A conversation that only a walk of its account's tree can place is
    /// noted for `scheduleRolloutDiscovery` rather than looked for here.
    private func projected(
        _ session: AgentSession,
        in project: Project
    ) -> TranscriptSearchSource? {
        let source = TranscriptSearchProjection.source(
            session: session,
            in: project,
            effort: .known,
            account: resolveAccount
        )
        if source == nil,
           let account = TranscriptSearchProjection.rolloutAccount(
               for: session,
               account: resolveAccount
           ) {
            accountsAwaitingRollouts[account.configPath] = account
        }
        return source
    }

    /// Reads each waiting account's sessions tree once, on a worker, then places the
    /// conversations on those accounts from the result.
    ///
    /// A later call keeps its accounts pending for the next pass. Cancelling the earlier pass
    /// used to discard its resolved accounts, leaving their conversations unplaced indefinitely.
    /// One worker folds repeated account requests together without losing another account's result.
    private func scheduleRolloutDiscovery() {
        guard rolloutDiscoveryTask == nil, !accountsAwaitingRollouts.isEmpty else { return }
        let accounts = Array(accountsAwaitingRollouts.values)
        accountsAwaitingRollouts.removeAll()

        rolloutDiscoveryTask = Task.detached(priority: .utility) { [weak self] in
            for account in accounts {
                guard !Task.isCancelled else { return }
                CodexTranscript.rolloutIndex(account: account)
            }
            guard !Task.isCancelled else { return }
            await self?.rolloutsDidResolve(for: accounts)
        }
    }

    private func rolloutsDidResolve(for accounts: [AgentAccount]) {
        rolloutDiscoveryTask = nil

        let accountPaths = Set(accounts.map(\.configPath))
        var changed = false
        for project in projectStore.projects {
            for session in project.sessions {
                guard let account = TranscriptSearchProjection.rolloutAccount(
                    for: session,
                    account: resolveAccount
                ), accountPaths.contains(account.configPath) else { continue }

                let source = TranscriptSearchProjection.source(
                    session: session,
                    in: project,
                    effort: .known,
                    account: resolveAccount
                )
                guard sourcesByProjectID[project.id]?[session.id] != source else { continue }
                if let source {
                    sourcesByProjectID[project.id, default: [:]][session.id] = source
                } else {
                    sourcesByProjectID[project.id]?.removeValue(forKey: session.id)
                }
                changed = true
            }
        }
        if changed { scheduleRefresh() }
        scheduleRolloutDiscovery()
    }

    private func workDidChange(_ sessionID: SessionID) {
        guard let project = projectStore.project(forSessionID: sessionID),
              let session = projectStore.session(withID: sessionID) else { return }
        if let source = projected(session, in: project) {
            sourcesByProjectID[project.id, default: [:]][sessionID] = source
            pendingWorkSources[sessionID] = source
            startRefreshIfNeeded()
        }
        scheduleRolloutDiscovery()
    }

    private func scheduleRefresh() {
        needsFullRefresh = true
        startRefreshIfNeeded()
    }

    /// One serial ingestion lane. Work arriving during a scan is folded into the next batch,
    /// so an old full snapshot can neither overwrite a newer work update nor resurrect a removal.
    /// Work boundaries reconcile only the changed transcripts; queries never start a scan.
    private func startRefreshIfNeeded() {
        guard refreshTask == nil, let index,
              needsFullRefresh || !pendingWorkSources.isEmpty else { return }
        let isFullRefresh = needsFullRefresh
        needsFullRefresh = false
        let changedSources = pendingWorkSources
        pendingWorkSources.removeAll(keepingCapacity: true)
        let sourcesByProjectID = sourcesByProjectID
        let projectNames = projectNames
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            if isFullRefresh {
                let sources = sourcesByProjectID.flatMap { projectID, sources in
                    let projectName = projectNames[projectID]
                    return sources.values.map { source in
                        projectName.map { source.replacingProjectName($0) } ?? source
                    }
                }
                await index.refresh(sources: sources)
            } else {
                await index.refreshChanged(sources: Array(changedSources.values))
            }
            guard !Task.isCancelled else { return }
            await self?.acceptRefresh()
        }
    }

    private func acceptRefresh() {
        refreshTask = nil
        NotificationCenter.default.post(TranscriptSearchIndexDidChange())
        startRefreshIfNeeded()
    }

    private func keyed(
        _ sources: [TranscriptSearchSource]
    ) -> [SessionID: TranscriptSearchSource] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0.sessionID, $0) })
    }
}
