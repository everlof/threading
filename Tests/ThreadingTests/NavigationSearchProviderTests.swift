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

    func testCurrentNamesWinEqualMatchesAndHistoricalNamesUseTheirOwnRecency() async throws {
        let projectID = ProjectID()
        let currentID = SessionID()
        let recentID = SessionID()
        let oldID = SessionID()
        let records = [
            NavigationSearchRecord(
                destination: .session(projectID: projectID, sessionID: currentID),
                title: "MIRRORING", projectName: "Phone work",
                updatedAt: Date(timeIntervalSince1970: 1)
            ),
            NavigationSearchRecord(
                destination: .session(projectID: projectID, sessionID: oldID),
                title: "CAMERA", projectName: "Phone work",
                nameHistory: [.init(name: "MIRRORING", lastSeenAt: Date(timeIntervalSince1970: 10))],
                updatedAt: Date(timeIntervalSince1970: 1000)
            ),
            NavigationSearchRecord(
                destination: .session(projectID: projectID, sessionID: recentID),
                title: "IPHONE", projectName: "Phone work",
                nameHistory: [.init(name: "MIRRORING", lastSeenAt: Date(timeIntervalSince1970: 30))],
                updatedAt: Date(timeIntervalSince1970: 2)
            ),
        ]
        let provider = NavigationSearchProvider(index: NavigationSearchIndex(records: records))

        for query in ["MIRRORING", "mir"] {
            let hits = try await batches(from: provider, query: query, scope: .everywhere).flatMap(\.hits)
            XCTAssertEqual(hits.map(\.provenance.sessionID), [currentID, recentID, oldID])
            XCTAssertNil(hits.first?.snippet)
            XCTAssertEqual(hits.dropFirst().map(\.stableOrder.recency), [30, 10])
            XCTAssertTrue(hits.dropFirst().allSatisfy(\.stableOrder.isHistoricalNameMatch))
            XCTAssertTrue(hits.dropFirst().allSatisfy { $0.snippet?.text.contains("MIRRORING") == true })
        }
    }

    func testOldNamesKeepExactArchivedLocatorsFiltersAndUnicodeMatchRanges() async throws {
        let projectID = ProjectID()
        let sessionID = SessionID()
        let provider = NavigationSearchProvider(index: NavigationSearchIndex(records: [
            NavigationSearchRecord(
                destination: .archivedSession(projectID: projectID, sessionID: sessionID),
                title: "CAMERA", projectName: "Phone work", providerName: "Codex",
                nameHistory: [.init(name: "LÄNKAR", lastSeenAt: Date(timeIntervalSince1970: 10))],
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
        ]))
        let hits = try await batches(
            from: provider, query: "lankar type:session provider:codex is:archived",
            scope: .project(projectID)
        ).flatMap(\.hits)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hit.title, "CAMERA")
        XCTAssertEqual(hit.locator, .archivedSession(projectID: projectID, sessionID: sessionID))
        let snippet = try XCTUnwrap(hit.snippet)
        let match = try XCTUnwrap(snippet.matches.first)
        XCTAssertEqual((snippet.text as NSString).substring(with: NSRange(
            location: match.utf16Location, length: match.utf16Length
        )), "LÄNKAR")

        let excluded = try await batches(from: provider, query: "CAMERA -lankar", scope: .everywhere)
        XCTAssertTrue(excluded.flatMap(\.hits).isEmpty)
        let wrongProject = try await batches(from: provider, query: "lankar", scope: .project(ProjectID()))
        XCTAssertTrue(wrongProject.flatMap(\.hits).isEmpty)
        let empty = try await batches(from: provider, query: "", scope: .everywhere).flatMap(\.hits)
        XCTAssertNil(empty.first?.snippet)
        XCTAssertEqual(empty.first?.stableOrder.recency, 100)
    }

    func testOneSessionWithSeveralOldNamesProducesOneHitAndUsesTheBestMatchingName() async throws {
        let projectID = ProjectID()
        let sessionID = SessionID()
        let provider = NavigationSearchProvider(index: NavigationSearchIndex(records: [
            NavigationSearchRecord(
                destination: .session(projectID: projectID, sessionID: sessionID),
                title: "PHONE", projectName: "Devices",
                nameHistory: [
                    .init(name: "MIRRORING", lastSeenAt: Date(timeIntervalSince1970: 10)),
                    .init(name: "MIRRORING UI", lastSeenAt: Date(timeIntervalSince1970: 20)),
                ],
                updatedAt: Date(timeIntervalSince1970: 30)
            ),
        ]))
        let exact = try await batches(from: provider, query: "mirroring", scope: .everywhere).flatMap(\.hits)
        XCTAssertEqual(exact.count, 1)
        XCTAssertEqual(exact.first?.scoreTier, .exactMetadata)
        XCTAssertEqual(exact.first?.stableOrder.recency, 10)
        let prefix = try await batches(from: provider, query: "mirror", scope: .everywhere).flatMap(\.hits)
        XCTAssertEqual(prefix.count, 1)
        XCTAssertEqual(prefix.first?.stableOrder.recency, 20)
    }

    func testCandidateCapAdmitsCurrentAndRecentlyUsedNamesBeforeUnrelatedChatActivity() async throws {
        let projectID = ProjectID()
        let currentID = SessionID()
        let recentID = SessionID()
        var records = (0 ..< 5000).map { index in
            NavigationSearchRecord(
                destination: .session(projectID: projectID, sessionID: index == 4999 ? recentID : SessionID()),
                title: "Device \(index)", projectName: "Stress",
                nameHistory: [.init(name: "MIRRORING", lastSeenAt: Date(timeIntervalSince1970: Double(index)))],
                updatedAt: Date(timeIntervalSince1970: Double(10000 - index))
            )
        }
        records.append(NavigationSearchRecord(
            destination: .session(projectID: projectID, sessionID: currentID),
            title: "MIRRORING", projectName: "Stress", updatedAt: Date(timeIntervalSince1970: 1)
        ))
        let provider = NavigationSearchProvider(index: NavigationSearchIndex(records: records))
        for query in ["mirroring", "mirror", "mi"] {
            let results = try await batches(from: provider, query: query, scope: .everywhere)
            let hits = results.flatMap(\.hits)
            XCTAssertEqual(Array(hits.prefix(2)).map(\.provenance.sessionID), [currentID, recentID])
            XCTAssertLessThanOrEqual(hits.count, UniversalSearchDefaults.maximumHitsPerGroup)
            XCTAssertTrue(try XCTUnwrap(results.first).isCapped)
        }
    }

    /// Opt-in timing of the production provider. Manufacture and cold index work are separate
    /// from warm queries; the normal tests above hold correctness without a CI stopwatch limit.
    func testProfileNavigationNameHistoryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_NAME_HISTORY_PROFILE"] == "1" else {
            throw XCTSkip("Set THREADING_NAME_HISTORY_PROFILE=1 to profile navigation name history")
        }
        let projectID = ProjectID()
        let records = (0 ..< 5000).map { index in
            NavigationSearchRecord(
                destination: .session(projectID: projectID, sessionID: SessionID()),
                title: "Device \(index)", projectName: "Profile", providerName: "Codex",
                nameHistory: (0 ..< 8).map { name in
                    .init(name: "Former name \(name)", lastSeenAt: Date(timeIntervalSince1970: Double(index - name)))
                },
                updatedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let indexStart = ProcessInfo.processInfo.systemUptime
        let provider = NavigationSearchProvider(index: NavigationSearchIndex(records: records))
        let indexMilliseconds = (ProcessInfo.processInfo.systemUptime - indexStart) * 1000
        var timings: [Double] = []
        for _ in 0 ..< 21 {
            let queryStart = ProcessInfo.processInfo.systemUptime
            let results = try await batches(from: provider, query: "former", scope: .everywhere)
            timings.append((ProcessInfo.processInfo.systemUptime - queryStart) * 1000)
            XCTAssertEqual(results.flatMap(\.hits).count, UniversalSearchDefaults.maximumHitsPerGroup)
            XCTAssertTrue(try XCTUnwrap(results.first).isCapped)
        }
        timings.sort()
        print("name-history profile: 5000 sessions × 8 names; index \(indexMilliseconds) ms; "
              + "warm query median \(timings[timings.count / 2]) ms, max \(timings.last ?? 0) ms")
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
