import Foundation

struct NavigationSearchIndexDidChange: AppEvent {
    static let name = Notification.Name("navigationSearchIndexDidChange")
}

/// Maintains the warm immutable navigation index for the process. Project mutations copy only
/// value metadata on the main actor, then cancel and replace an off-main index build.
@MainActor
final class NavigationSearchIndexStore {
    private let projectStore: ProjectStore
    private let events: AppEventObservations
    private var index = NavigationSearchIndex(records: [])
    private var requestedRecordCount = 0
    private var generation: UInt64 = 0
    private var buildTask: Task<Void, Never>?

    init(
        projectStore: ProjectStore = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.projectStore = projectStore
        events = AppEventObservations(center: notificationCenter)
        events.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
    }

    deinit {
        buildTask?.cancel()
    }

    func provider() -> NavigationSearchProvider {
        let coverage: SearchCoverage = buildTask == nil
            ? .complete
            : .indexing(indexed: index.recordCount, total: requestedRecordCount)
        return NavigationSearchProvider(index: index, coverage: coverage)
    }

    private func rebuild() {
        generation &+= 1
        let requestedGeneration = generation
        let records = NavigationSearchProjection.records(projects: projectStore.projects)
        requestedRecordCount = records.count
        buildTask?.cancel()
        buildTask = Task.detached(priority: .utility) { [weak self] in
            let built = NavigationSearchIndex(records: records)
            guard !Task.isCancelled else { return }
            await self?.accept(built, generation: requestedGeneration)
        }
    }

    private func accept(_ built: NavigationSearchIndex, generation: UInt64) {
        guard generation == self.generation else { return }
        index = built
        buildTask = nil
        NotificationCenter.default.post(NavigationSearchIndexDidChange())
    }
}
