import XCTest

@testable import Threading

final class UniversalSearchCoordinatorTests: XCTestCase {
    func testCoordinatorWithoutProvidersFinishesImmediately() async throws {
        let coordinator = UniversalSearchCoordinator(providers: [])

        let final = try await finalSnapshot(
            from: coordinator,
            query: query(generation: 1),
            capabilities: .macOS
        )

        XCTAssertTrue(final.isComplete)
        XCTAssertTrue(final.hits.isEmpty)
    }

    func testCoordinatorSortsDeduplicatesAndKeepsProviderFairness() async throws {
        let projectID = ProjectID()
        let first = Provider(
            id: SearchProviderID(rawValue: "first"),
            batches: [Self.batch(
                provider: SearchProviderID(rawValue: "first"),
                hits: (0 ..< 6).map {
                    Self.hit(id: "shared-\($0)", title: "A \($0)", projectID: projectID)
                }
            )]
        )
        let second = Provider(
            id: SearchProviderID(rawValue: "second"),
            batches: [Self.batch(
                provider: SearchProviderID(rawValue: "second"),
                hits: [
                    Self.hit(id: "shared-0", title: "Duplicate", projectID: projectID),
                    Self.hit(id: "second-only", title: "B", projectID: projectID),
                ]
            )]
        )
        let coordinator = UniversalSearchCoordinator(
            providers: [first, second],
            budget: SearchCoordinatorBudget(
                maximumHitsPerProviderGroup: 2,
                maximumHitsPerGroup: 10,
                maximumInitialHits: 10
            )
        )

        let final = try await finalSnapshot(
            from: coordinator,
            query: query(generation: 1),
            capabilities: .macOS
        )

        XCTAssertEqual(final.hits.map(\.id.rawValue), ["shared-0", "shared-1", "second-only"])
        XCTAssertTrue(try XCTUnwrap(final.groups.first).isCapped)
        XCTAssertEqual(final.groups.first?.providers.count, 2)
    }

    func testCoordinatorDropsIneligibleHitsBeforeTheyConsumeQuota() async throws {
        let projectID = ProjectID()
        let providerID = SearchProviderID(rawValue: "mixed")
        let provider = Provider(id: providerID, batches: [Self.batch(provider: providerID, hits: [
            Self.commandHit(id: "mac-only"),
            Self.hit(id: "mobile-1", title: "Mobile One", projectID: projectID),
            Self.hit(id: "mobile-2", title: "Mobile Two", projectID: projectID),
        ])])
        let coordinator = UniversalSearchCoordinator(
            providers: [provider],
            budget: SearchCoordinatorBudget(
                maximumHitsPerProviderGroup: 2,
                maximumHitsPerGroup: 2,
                maximumInitialHits: 2
            )
        )

        let final = try await finalSnapshot(
            from: coordinator,
            query: query(generation: 1),
            capabilities: .remoteIOS
        )

        XCTAssertEqual(final.hits.map(\.id.rawValue), ["mobile-1", "mobile-2"])
    }

    func testStartingANewGenerationCancelsOldWorkAndDropsItsLateBatch() async throws {
        let providerID = SearchProviderID(rawValue: "delayed")
        let provider = DelayedProvider(id: providerID)
        let coordinator = UniversalSearchCoordinator(providers: [provider])

        let oldStream = await coordinator.start(
            query: query(generation: 1),
            clientCapabilities: .macOS
        )
        var oldIterator = oldStream.makeAsyncIterator()
        _ = await oldIterator.next()

        let currentStream = await coordinator.start(
            query: query(generation: 2),
            clientCapabilities: .macOS
        )
        var final: SearchSnapshot?
        for await snapshot in currentStream {
            final = snapshot
        }

        XCTAssertEqual(final?.queryGeneration, 2)
        XCTAssertEqual(final?.hits.map(\.id.rawValue), ["generation-2"])
        let oldFinal = await oldIterator.next()
        XCTAssertNil(oldFinal)
    }

    func testSelectionRemainsOnIdentityWhenEarlierRowsArrive() async throws {
        let providerID = SearchProviderID(rawValue: "progressive")
        let projectID = ProjectID()
        let batches = [
            Self.batch(provider: providerID, hits: [
                Self.hit(id: "b", title: "Bravo", projectID: projectID),
                Self.hit(id: "c", title: "Charlie", projectID: projectID),
            ]),
            Self.batch(provider: providerID, hits: [
                Self.hit(id: "a", title: "Alpha", projectID: projectID),
                Self.hit(id: "b", title: "Bravo", projectID: projectID),
                Self.hit(id: "c", title: "Charlie", projectID: projectID),
            ]),
        ]
        let coordinator = UniversalSearchCoordinator(providers: [Provider(id: providerID, batches: batches)])
        let stream = await coordinator.start(
            query: query(generation: 9),
            clientCapabilities: .macOS,
            selectedHitID: SearchHitID(rawValue: "c")
        )

        var final: SearchSnapshot?
        for await snapshot in stream {
            final = snapshot
        }

        XCTAssertEqual(final?.hits.map(\.id.rawValue), ["a", "b", "c"])
        XCTAssertEqual(final?.selectedHitID?.rawValue, "c")
    }

    func testSelectionCanBeExplicitlyCleared() async throws {
        let providerID = SearchProviderID(rawValue: "persistent")
        let coordinator = UniversalSearchCoordinator(providers: [PersistentProvider(
            id: providerID,
            batch: Self.batch(provider: providerID, hits: [
                Self.hit(id: "only", title: "Only", projectID: ProjectID()),
            ])
        )])
        let stream = await coordinator.start(
            query: query(generation: 10),
            clientCapabilities: .macOS
        )
        var iterator = stream.makeAsyncIterator()

        var populated: SearchSnapshot?
        while let snapshot = await iterator.next() {
            if !snapshot.hits.isEmpty {
                populated = snapshot
                break
            }
        }
        XCTAssertEqual(populated?.selectedHitID?.rawValue, "only")

        await coordinator.select(nil)
        let cleared = await iterator.next()
        XCTAssertNil(cleared?.selectedHitID)
        await coordinator.cancel()
    }

    func testGuestCapabilitySetProducesNoDeadRows() async throws {
        let projectID = ProjectID()
        let providerID = SearchProviderID(rawValue: "all")
        let coordinator = UniversalSearchCoordinator(providers: [Provider(
            id: providerID,
            batches: [Self.batch(provider: providerID, hits: [
                Self.hit(id: "project", title: "Project", projectID: projectID),
                Self.commandHit(id: "command"),
            ])]
        )])

        let final = try await finalSnapshot(
            from: coordinator,
            query: query(generation: 1),
            capabilities: []
        )

        XCTAssertTrue(final.hits.isEmpty)
    }

    private struct Provider: UniversalSearchProvider {
        let id: SearchProviderID
        let batches: [SearchBatch]

        func search(_ request: SearchProviderRequest) -> AsyncStream<SearchBatch> {
            AsyncStream { continuation in
                for batch in batches {
                    continuation.yield(SearchBatch(
                        queryGeneration: request.query.generation,
                        provider: batch.provider,
                        group: batch.group,
                        hits: batch.hits,
                        coverage: batch.coverage,
                        continuation: batch.continuation,
                        isCapped: batch.isCapped
                    ))
                }
                continuation.finish()
            }
        }
    }

    private struct DelayedProvider: UniversalSearchProvider {
        let id: SearchProviderID

        func search(_ request: SearchProviderRequest) -> AsyncStream<SearchBatch> {
            AsyncStream { continuation in
                let task = Task {
                    if request.query.generation == 1 {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(UniversalSearchCoordinatorTests.batch(
                        provider: id,
                        generation: request.query.generation,
                        hits: [UniversalSearchCoordinatorTests.hit(
                            id: "generation-\(request.query.generation)",
                            title: "Generation",
                            projectID: ProjectID()
                        )]
                    ))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private struct PersistentProvider: UniversalSearchProvider {
        let id: SearchProviderID
        let batch: SearchBatch

        func search(_ request: SearchProviderRequest) -> AsyncStream<SearchBatch> {
            AsyncStream { continuation in
                continuation.yield(SearchBatch(
                    queryGeneration: request.query.generation,
                    provider: batch.provider,
                    group: batch.group,
                    hits: batch.hits,
                    coverage: batch.coverage,
                    continuation: batch.continuation,
                    isCapped: batch.isCapped
                ))
            }
        }
    }

    private func finalSnapshot(
        from coordinator: UniversalSearchCoordinator,
        query: SearchQuery,
        capabilities: SearchClientCapabilities
    ) async throws -> SearchSnapshot {
        let stream = await coordinator.start(
            query: query,
            clientCapabilities: capabilities
        )
        var value: SearchSnapshot?
        for await snapshot in stream {
            value = snapshot
        }
        return try XCTUnwrap(value)
    }

    private func query(generation: UInt64) -> SearchQuery {
        try! SearchQueryParser.parse("result", scope: .everywhere, generation: generation).get()
    }

    private static func batch(
        provider: SearchProviderID,
        generation: UInt64 = 0,
        hits: [SearchHit]
    ) -> SearchBatch {
        SearchBatch(
            queryGeneration: generation,
            provider: provider,
            group: .destinations,
            hits: hits,
            coverage: .complete,
            continuation: nil,
            isCapped: false
        )
    }

    private static func hit(
        id: String,
        title: String,
        projectID: ProjectID
    ) -> SearchHit {
        let hitID = SearchHitID(rawValue: id)
        return SearchHit(
            id: hitID,
            provider: .navigation,
            kind: .project,
            title: title,
            snippet: nil,
            provenance: SearchProvenance(projectID: projectID),
            stableOrder: SearchStableOrder(
                group: .destinations,
                scoreTier: .literalText,
                recency: nil,
                title: title,
                stableID: hitID
            ),
            locator: .project(projectID)
        )
    }

    private static func commandHit(id: String) -> SearchHit {
        let hitID = SearchHitID(rawValue: id)
        return SearchHit(
            id: hitID,
            provider: .registry,
            kind: .command,
            title: "Command",
            snippet: nil,
            provenance: SearchProvenance(),
            stableOrder: SearchStableOrder(
                group: .destinations,
                scoreTier: .exactMetadata,
                recency: nil,
                title: "Command",
                stableID: hitID
            ),
            locator: .command(id)
        )
    }
}
