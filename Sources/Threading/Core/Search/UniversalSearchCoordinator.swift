import Foundation

struct SearchProviderRequest: Sendable {
    let query: SearchQuery
    let clientCapabilities: SearchClientCapabilities
}

protocol UniversalSearchProvider: Sendable {
    var id: SearchProviderID { get }
    func search(_ request: SearchProviderRequest) -> AsyncStream<SearchBatch>
}

struct SearchCoordinatorBudget: Equatable, Sendable {
    let maximumHitsPerProviderGroup: Int
    let maximumHitsPerGroup: Int
    let maximumInitialHits: Int

    static let standard = SearchCoordinatorBudget(
        maximumHitsPerProviderGroup: 32,
        maximumHitsPerGroup: UniversalSearchDefaults.maximumHitsPerGroup,
        maximumInitialHits: UniversalSearchDefaults.maximumInitialHits
    )

    init(
        maximumHitsPerProviderGroup: Int,
        maximumHitsPerGroup: Int,
        maximumInitialHits: Int
    ) {
        precondition(maximumHitsPerProviderGroup > 0)
        precondition(maximumHitsPerGroup > 0)
        precondition(maximumInitialHits > 0)
        self.maximumHitsPerProviderGroup = maximumHitsPerProviderGroup
        self.maximumHitsPerGroup = maximumHitsPerGroup
        self.maximumInitialHits = maximumInitialHits
    }
}

struct SearchProviderCoverage: Equatable, Sendable {
    let provider: SearchProviderID
    let coverage: SearchCoverage
    let continuation: SearchContinuation?
    let isCapped: Bool
}

struct SearchGroupSnapshot: Equatable, Sendable {
    let group: SearchResultGroup
    let hits: [SearchHit]
    let providers: [SearchProviderCoverage]
    let isCapped: Bool
}

struct SearchSnapshot: Equatable, Sendable {
    let queryGeneration: UInt64
    let groups: [SearchGroupSnapshot]
    let selectedHitID: SearchHitID?
    let isComplete: Bool

    var hits: [SearchHit] { groups.flatMap(\.hits) }
}

/// Owns one window's active query. Providers may finish in any order; every published snapshot is
/// deterministically sorted, capability-filtered and bounded before presentation can observe it.
actor UniversalSearchCoordinator {
    private struct ProviderGroupKey: Hashable, Sendable {
        let provider: SearchProviderID
        let group: SearchResultGroup
    }

    private struct Accumulator {
        var batches: [ProviderGroupKey: SearchBatch] = [:]
        var finishedProviders: Set<SearchProviderID> = []
        var selectedHitID: SearchHitID?
        var selectedFlatIndex: Int?
        var selectionWasCleared = false
    }

    private let providers: [any UniversalSearchProvider]
    private let budget: SearchCoordinatorBudget
    private var activeGeneration: UInt64?
    private var activeTask: Task<Void, Never>?
    private var activeContinuation: AsyncStream<SearchSnapshot>.Continuation?
    private var accumulator = Accumulator()

    init(
        providers: [any UniversalSearchProvider],
        budget: SearchCoordinatorBudget = .standard
    ) {
        self.providers = providers
        self.budget = budget
    }

    func start(
        query: SearchQuery,
        clientCapabilities: SearchClientCapabilities,
        selectedHitID: SearchHitID? = nil
    ) -> AsyncStream<SearchSnapshot> {
        cancelActiveQuery()
        activeGeneration = query.generation
        accumulator = Accumulator(selectedHitID: selectedHitID)

        let pair = AsyncStream<SearchSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        activeContinuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.consumerDidTerminate(generation: query.generation) }
        }
        pair.continuation.yield(snapshot())

        guard !providers.isEmpty else {
            pair.continuation.finish()
            activeContinuation = nil
            return pair.stream
        }

        let providers = self.providers
        activeTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for provider in providers {
                    group.addTask {
                        let request = SearchProviderRequest(
                            query: query,
                            clientCapabilities: clientCapabilities
                        )
                        for await batch in provider.search(request) {
                            guard !Task.isCancelled else { return }
                            await self?.accept(
                                batch,
                                from: provider.id,
                                generation: query.generation,
                                clientCapabilities: clientCapabilities
                            )
                        }
                        await self?.providerFinished(
                            provider.id,
                            generation: query.generation
                        )
                    }
                }
                await group.waitForAll()
            }
        }
        return pair.stream
    }

    func select(_ hitID: SearchHitID?) {
        guard activeGeneration != nil else { return }
        let hits = snapshot().hits
        accumulator.selectedHitID = hitID
        accumulator.selectedFlatIndex = hitID.flatMap { id in
            hits.firstIndex { $0.id == id }
        }
        accumulator.selectionWasCleared = hitID == nil
        activeContinuation?.yield(snapshot())
    }

    func cancel() {
        cancelActiveQuery()
    }

    private func accept(
        _ batch: SearchBatch,
        from providerID: SearchProviderID,
        generation: UInt64,
        clientCapabilities: SearchClientCapabilities
    ) {
        guard generation == activeGeneration,
              batch.queryGeneration == generation,
              batch.provider == providerID else { return }

        let eligible = batch.hits.filter { $0.isEligible(for: clientCapabilities) }
        let sorted = eligible.sorted { $0.stableOrder < $1.stableOrder }
        let capped = Array(sorted.prefix(budget.maximumHitsPerProviderGroup))
        let normalized = SearchBatch(
            queryGeneration: batch.queryGeneration,
            provider: batch.provider,
            group: batch.group,
            hits: capped,
            coverage: batch.coverage,
            continuation: batch.continuation,
            isCapped: batch.isCapped || capped.count < sorted.count
        )
        accumulator.batches[ProviderGroupKey(provider: providerID, group: batch.group)] = normalized
        activeContinuation?.yield(snapshot())
    }

    private func providerFinished(_ providerID: SearchProviderID, generation: UInt64) {
        guard generation == activeGeneration else { return }
        accumulator.finishedProviders.insert(providerID)
        activeContinuation?.yield(snapshot())
        guard accumulator.finishedProviders.count == providers.count else { return }
        activeContinuation?.finish()
        activeContinuation = nil
        activeTask = nil
    }

    private func snapshot() -> SearchSnapshot {
        let batchesByGroup = Dictionary(grouping: accumulator.batches.values, by: \.group)
        var remainingTotal = budget.maximumInitialHits
        var groups: [SearchGroupSnapshot] = []

        for group in SearchResultGroup.allCases where remainingTotal > 0 {
            guard let batches = batchesByGroup[group], !batches.isEmpty else { continue }
            var hitByID: [SearchHitID: SearchHit] = [:]
            for batch in batches {
                for hit in batch.hits {
                    if let existing = hitByID[hit.id] {
                        if hit.stableOrder < existing.stableOrder { hitByID[hit.id] = hit }
                    } else {
                        hitByID[hit.id] = hit
                    }
                }
            }

            let ordered = hitByID.values.sorted { $0.stableOrder < $1.stableOrder }
            let groupLimit = min(budget.maximumHitsPerGroup, remainingTotal)
            let visible = Array(ordered.prefix(groupLimit))
            remainingTotal -= visible.count

            let providerCoverage = batches
                .sorted { $0.provider.rawValue < $1.provider.rawValue }
                .map {
                    SearchProviderCoverage(
                        provider: $0.provider,
                        coverage: $0.coverage,
                        continuation: $0.continuation,
                        isCapped: $0.isCapped
                    )
                }
            groups.append(SearchGroupSnapshot(
                group: group,
                hits: visible,
                providers: providerCoverage,
                isCapped: visible.count < ordered.count || batches.contains(where: \.isCapped)
            ))
        }

        let flatHits = groups.flatMap(\.hits)
        let selectedID: SearchHitID?
        if let current = accumulator.selectedHitID,
           flatHits.contains(where: { $0.id == current })
        {
            selectedID = current
        } else if !flatHits.isEmpty, !accumulator.selectionWasCleared {
            let index = min(accumulator.selectedFlatIndex ?? 0, flatHits.count - 1)
            selectedID = flatHits[index].id
        } else {
            selectedID = nil
        }

        return SearchSnapshot(
            queryGeneration: activeGeneration ?? 0,
            groups: groups,
            selectedHitID: selectedID,
            isComplete: accumulator.finishedProviders.count == providers.count
        )
    }

    private func consumerDidTerminate(generation: UInt64) {
        guard generation == activeGeneration else { return }
        cancelActiveQuery()
    }

    private func cancelActiveQuery() {
        activeTask?.cancel()
        activeTask = nil
        activeContinuation?.finish()
        activeContinuation = nil
        activeGeneration = nil
        accumulator = Accumulator()
    }
}
