import XCTest

@testable import Threading

final class NavigationSearchProviderTests: XCTestCase {
    func testLiteralFilterScopeAndArchivedResults() async throws {
        let projectA = ProjectID()
        let projectB = ProjectID()
        let activeID = SessionID()
        let archivedID = SessionID()
        let records = [
            NavigationSearchRecord(
                destination: .session(projectID: projectA, sessionID: activeID),
                title: "Fix login callback",
                projectName: "Acme",
                providerName: "Codex",
                branch: "auth",
                updatedAt: Date(timeIntervalSince1970: 30)
            ),
            NavigationSearchRecord(
                destination: .archivedSession(projectID: projectA, sessionID: archivedID),
                title: "Old login investigation",
                projectName: "Acme",
                providerName: "Claude",
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
            NavigationSearchRecord(
                destination: .session(projectID: projectB, sessionID: SessionID()),
                title: "Fix login callback",
                projectName: "Other",
                providerName: "Codex",
                updatedAt: Date(timeIntervalSince1970: 40)
            ),
        ]
        let provider = NavigationSearchProvider(index: NavigationSearchIndex(records: records))

        let active = try await batches(
            from: provider,
            query: "login provider:codex -is:archived",
            scope: .project(projectA)
        )
        XCTAssertEqual(active.flatMap(\.hits).map(\.id.rawValue), ["navigation:session:\(activeID.uuidString)"])

        let archived = try await batches(
            from: provider,
            query: "login is:archived",
            scope: .everywhere
        )
        XCTAssertEqual(archived.map(\.group), [.archived])
        XCTAssertEqual(archived.flatMap(\.hits).map(\.id.rawValue), [
            "navigation:archived:\(archivedID.uuidString)",
        ])
    }

    func testExactIdentifierRanksAheadOfMetadata() async throws {
        let projectID = ProjectID()
        let exactID = SessionID()
        let provider = NavigationSearchProvider(index: NavigationSearchIndex(records: [
            NavigationSearchRecord(
                destination: .session(projectID: projectID, sessionID: exactID),
                title: "Unrelated",
                projectName: "Project",
                updatedAt: Date(timeIntervalSince1970: 1)
            ),
            NavigationSearchRecord(
                destination: .session(projectID: projectID, sessionID: SessionID()),
                title: exactID.uuidString,
                projectName: "Project",
                updatedAt: Date(timeIntervalSince1970: 2)
            ),
        ]))

        let hits = try await batches(
            from: provider,
            query: exactID.uuidString,
            scope: .everywhere
        ).flatMap(\.hits)

        XCTAssertEqual(hits.first?.locator, .session(projectID: projectID, sessionID: exactID))
        XCTAssertEqual(hits.first?.scoreTier, .exactIdentifier)
    }

    func testCommonTermWorkAndVisibleResultsAreBoundedAtStressCardinality() async throws {
        let projectID = ProjectID()
        let records = (0 ..< 25000).map { index in
            NavigationSearchRecord(
                destination: .session(projectID: projectID, sessionID: SessionID()),
                title: "Common destination \(index)",
                projectName: "Stress",
                providerName: "Codex",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let provider = NavigationSearchProvider(index: NavigationSearchIndex(records: records))

        let results = try await batches(from: provider, query: "common", scope: .everywhere)

        XCTAssertLessThanOrEqual(results.flatMap(\.hits).count, UniversalSearchDefaults.maximumHitsPerGroup)
        XCTAssertTrue(try XCTUnwrap(results.first).isCapped)
    }

    func testEmptyQueryReturnsBoundedRecentDestinations() async throws {
        let projectID = ProjectID()
        let provider = NavigationSearchProvider(index: NavigationSearchIndex(records: (0 ..< 700).map { index in
            NavigationSearchRecord(
                destination: .project(projectID),
                title: "Project \(index)",
                projectName: "Project \(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }))

        let results = try await batches(from: provider, query: "", scope: .everywhere)

        XCTAssertEqual(results.flatMap(\.hits).count, UniversalSearchDefaults.maximumHitsPerGroup)
        XCTAssertTrue(try XCTUnwrap(results.first).isCapped)
    }

    private func batches(
        from provider: NavigationSearchProvider,
        query text: String,
        scope: SearchScope
    ) async throws -> [SearchBatch] {
        let query = try SearchQueryParser.parse(text, scope: scope, generation: 1).get()
        var values: [SearchBatch] = []
        for await batch in provider.search(SearchProviderRequest(
            query: query,
            clientCapabilities: .macOS
        )) {
            values.append(batch)
        }
        return values
    }
}
