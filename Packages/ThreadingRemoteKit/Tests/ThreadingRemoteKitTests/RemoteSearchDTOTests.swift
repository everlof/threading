import XCTest

@testable import ThreadingRemoteKit

final class RemoteSearchDTOTests: XCTestCase {
    func testProjectScopeAndResolutionCarryStableIdentityWithNameOnlyCompatibility() throws {
        let request = RemoteSearchRequestDTO(
            query: "auth",
            scope: .project,
            projectID: "project-id",
            projectName: "Duplicate",
            generation: 7
        )
        let resolution = RemoteSearchResolutionDTO(
            kind: .project,
            projectID: "project-id",
            projectName: "Duplicate"
        )
        let requestData = try JSONEncoder().encode(request)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteSearchRequestDTO.self, from: requestData),
            request
        )
        let resolutionData = try JSONEncoder().encode(resolution)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteSearchResolutionDTO.self, from: resolutionData),
            resolution
        )

        let legacy = Data(
            #"{"query":"auth","scope":"project","projectName":"Duplicate","generation":7}"#.utf8
        )
        let decoded = try JSONDecoder().decode(RemoteSearchRequestDTO.self, from: legacy)
        XCTAssertNil(decoded.projectID)
        XCTAssertEqual(decoded.projectName, "Duplicate")
    }

    func testSearchResponseRoundTripsEveryTypedLandingWithoutPathAuthority() throws {
        let response = RemoteSearchResponseDTO(
            generation: 42,
            groups: [RemoteSearchGroupResultDTO(
                group: .conversations,
                hits: [RemoteSearchHitDTO(
                    id: "result-1",
                    token: "opaque-token",
                    group: .conversations,
                    kind: .conversationMessage,
                    title: "Fix the flaky test",
                    snippet: RemoteSearchSnippetDTO(
                        text: "The flaky test is fixed",
                        matches: [RemoteSearchTextRangeDTO(utf16Location: 4, utf16Length: 5)]
                    ),
                    provenance: RemoteSearchProvenanceDTO(
                        projectName: "Threading",
                        sessionTitle: "Search",
                        provider: "Codex",
                        author: "agent",
                        branch: "feature/search",
                        relativePath: "Tests/SearchTests.swift",
                        timestamp: 123,
                        isArchived: false
                    )
                )],
                coverage: [RemoteSearchCoverageDTO(
                    kind: .indexing,
                    indexed: 8,
                    total: 10
                )],
                isCapped: true
            )],
            isComplete: false
        )

        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(RemoteSearchResponseDTO.self, from: data), response)
        let wire = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(wire.contains("absolutePath"))
        XCTAssertFalse(wire.contains("sqlite"))
        XCTAssertFalse(wire.contains("locator"))
    }

    func testConversationAndFileResolutionsRoundTripBoundedWindows() throws {
        let conversation = RemoteSearchResolutionDTO(
            kind: .conversation,
            sessionID: "session-id",
            conversation: RemoteSearchConversationWindowDTO(
                sessionID: "session-id",
                sessionTitle: "Search design",
                projectName: "Threading",
                rows: [RemoteSearchConversationRowDTO(
                    id: "row-0",
                    kind: "conversationMessage",
                    author: "you",
                    body: "Find this exact text",
                    timestamp: 100
                )],
                anchorRowID: "row-0",
                anchorMatch: RemoteSearchTextRangeDTO(utf16Location: 5, utf16Length: 4),
                hasEarlier: true,
                hasLater: false
            )
        )
        let file = RemoteSearchResolutionDTO(
            kind: .file,
            file: RemoteSearchFileWindowDTO(
                projectName: "Threading",
                relativePath: "Sources/Search.swift",
                lines: [RemoteSearchFileLineDTO(
                    number: 9,
                    text: "let result = search()",
                    match: RemoteSearchTextRangeDTO(utf16Location: 13, utf16Length: 6)
                )],
                anchorLine: 9,
                hasEarlier: true,
                hasLater: true
            )
        )

        for resolution in [conversation, file] {
            let data = try JSONEncoder().encode(resolution)
            XCTAssertEqual(
                try JSONDecoder().decode(RemoteSearchResolutionDTO.self, from: data),
                resolution
            )
        }
    }

    func testWireLimitsStaySmallEnoughForInteractiveSearch() {
        XCTAssertLessThanOrEqual(RemoteSearchWireLimits.maximumVisibleHits, 128)
        XCTAssertLessThanOrEqual(RemoteSearchWireLimits.maximumGroups, 8)
        XCTAssertLessThanOrEqual(RemoteSearchWireLimits.maximumConversationRows, 41)
        XCTAssertLessThanOrEqual(RemoteSearchWireLimits.maximumFileLines, 41)
        XCTAssertLessThanOrEqual(RemoteSearchWireLimits.resultTokenLifetimeSeconds, 60)
    }
}
