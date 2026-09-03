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
/// coalesced complete snapshots. Opening Search only asks for a provider; it never starts a walk.
@MainActor
final class TranscriptSearchIndexStore {
    private let projectStore: ProjectStore
    private let events: AppEventObservations
    private let index: TranscriptSearchIndex?
    private var sourcesByProjectID: [ProjectID: [SessionID: TranscriptSearchSource]] = [:]
    private var projectNames: [ProjectID: String] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0

    init(
        projectStore: ProjectStore = .shared,
        databaseURL: URL = StateManager.shared.transcriptSearchIndexURL(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.projectStore = projectStore
        events = AppEventObservations(center: notificationCenter)
        index = try? TranscriptSearchIndex(databaseURL: databaseURL)
        events.observe(ProjectsDidChange.self) { [weak self] event in
            self?.projectsDidChange(event)
        }
        rebuildAll()
    }

    deinit {
        refreshTask?.cancel()
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
        case .terminalRow:
            break
        }
    }

    private func rebuildAll() {
        sourcesByProjectID = Dictionary(uniqueKeysWithValues: projectStore.projects.map { project in
            (project.id, keyed(TranscriptSearchProjection.sources(project: project)))
        })
        projectNames = Dictionary(uniqueKeysWithValues: projectStore.projects.map {
            ($0.id, $0.name)
        })
        scheduleRefresh()
    }

    private func replaceProject(_ projectID: ProjectID) {
        guard let project = projectStore.project(withID: projectID) else {
            sourcesByProjectID.removeValue(forKey: projectID)
            projectNames.removeValue(forKey: projectID)
            scheduleRefresh()
            return
        }
        sourcesByProjectID[projectID] = keyed(
            TranscriptSearchProjection.sources(project: project)
        )
        projectNames[projectID] = project.name
        scheduleRefresh()
    }

    private func replaceSession(_ sessionID: SessionID, in projectID: ProjectID) {
        guard let project = projectStore.project(withID: projectID),
              let session = projectStore.session(withID: sessionID) else {
            sourcesByProjectID[projectID]?.removeValue(forKey: sessionID)
            scheduleRefresh()
            return
        }
        if let source = TranscriptSearchProjection.source(session: session, in: project) {
            sourcesByProjectID[projectID, default: [:]][sessionID] = source
        } else {
            sourcesByProjectID[projectID]?.removeValue(forKey: sessionID)
        }
        projectNames[projectID] = project.name
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        // Both dictionaries are copy-on-write value snapshots. Flattening every retained source
        // and applying project-name overlays belong beside SQLite ingestion, off the main actor.
        let sourcesByProjectID = sourcesByProjectID
        let projectNames = projectNames
        guard let index else {
            refreshTask = nil
            return
        }
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let sources = sourcesByProjectID.flatMap { projectID, sources in
                let projectName = projectNames[projectID]
                return sources.values.map { source in
                    projectName.map { source.replacingProjectName($0) } ?? source
                }
            }
            await index.refresh(sources: sources)
            guard !Task.isCancelled else { return }
            await self?.accept(generation: generation)
        }
    }

    private func accept(generation: UInt64) {
        guard refreshGeneration == generation else { return }
        refreshTask = nil
        NotificationCenter.default.post(TranscriptSearchIndexDidChange())
    }

    private func keyed(
        _ sources: [TranscriptSearchSource]
    ) -> [SessionID: TranscriptSearchSource] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0.sessionID, $0) })
    }
}
