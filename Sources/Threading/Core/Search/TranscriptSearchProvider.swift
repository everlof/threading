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
        events.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.refresh()
        }
        refresh()
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

    private func refresh() {
        let sources = TranscriptSearchProjection.sources(projects: projectStore.projects)
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let index else {
            refreshTask = nil
            return
        }
        refreshTask = Task { [weak self] in
            await index.refresh(sources: sources)
            guard !Task.isCancelled else { return }
            guard let self, self.refreshGeneration == generation else { return }
            self.refreshTask = nil
            NotificationCenter.default.post(TranscriptSearchIndexDidChange())
        }
    }
}
