@testable import Threading
import XCTest

final class ProjectTextSearchProviderTests: XCTestCase {
    private actor Flag {
        private var value = false
        func mark() { value = true }
        func read() -> Bool { value }
    }

    private var directory: URL!
    private let projectID = ProjectID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectTextSearchProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("let needleValue = 1\n".utf8)
            .write(to: directory.appendingPathComponent("Example.swift"))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    func testProjectScopeEmitsExactFileLineLocator() async throws {
        let provider = ProjectTextSearchProvider(projects: [project()]) { _, literal in
            XCTAssertEqual(literal, "needle")
            return .success(ProjectTextSearchPage(
                matches: [ProjectTextSearchMatch(
                    relativePath: "Example.swift",
                    line: 1,
                    text: "let needleValue = 1"
                )],
                isCapped: false
            ))
        }

        let output = try await batches(
            from: provider,
            query: query("needle", scope: .project(projectID))
        )
        let batch = try XCTUnwrap(output.first)
        let hit = try XCTUnwrap(batch.hits.first)
        XCTAssertEqual(hit.kind, .projectText)
        XCTAssertEqual(hit.snippet?.text, "let needleValue = 1")
        XCTAssertEqual(hit.snippet?.matches, [
            SearchTextRange(utf16Location: 4, utf16Length: 6),
        ])
        guard case let .workspaceFile(locatorProjectID, sessionID, location) = hit.locator else {
            return XCTFail("Expected a workspace file locator")
        }
        XCTAssertEqual(locatorProjectID, projectID)
        XCTAssertNil(sessionID)
        XCTAssertEqual(location.relativePath, "Example.swift")
        XCTAssertEqual(location.line, 1)
        XCTAssertEqual(location.column, 5)
        XCTAssertEqual(location.matchLength, 6)
    }

    func testEverywhereDoesNotStartProjectTextWork() async throws {
        let ran = Flag()
        let provider = ProjectTextSearchProvider(projects: [project()]) { _, _ in
            await ran.mark()
            return .success(ProjectTextSearchPage(matches: [], isCapped: false))
        }

        let output = try await batches(
            from: provider,
            query: query("needle", scope: .everywhere)
        )
        let batch = try XCTUnwrap(output.first)

        let didRun = await ran.read()
        XCTAssertFalse(didRun)
        XCTAssertTrue(batch.hits.isEmpty)
        XCTAssertEqual(batch.coverage, .complete)
    }

    func testShortQueryAdmitsNoFilesystemProcess() async throws {
        let ran = Flag()
        let provider = ProjectTextSearchProvider(projects: [project()]) { _, _ in
            await ran.mark()
            return .success(ProjectTextSearchPage(matches: [], isCapped: false))
        }

        let output = try await batches(
            from: provider,
            query: query("ab", scope: .project(projectID))
        )
        let batch = try XCTUnwrap(output.first)

        let didRun = await ran.read()
        XCTAssertFalse(didRun)
        XCTAssertTrue(batch.hits.isEmpty)
        guard case .partial = batch.coverage else {
            return XCTFail("The minimum query requirement must be visible")
        }
    }

    func testExactlyThreeMatchesInAFileAreNotReportedAsCapped() {
        let page = ProjectTextSearchProvider.boundedPage(from: matches(count: 3))

        XCTAssertEqual(page.matches.count, 3)
        XCTAssertFalse(page.isCapped)
    }

    func testFourthMatchInAFileReportsCapAndIsNotDisplayed() {
        let page = ProjectTextSearchProvider.boundedPage(from: matches(count: 4))

        XCTAssertEqual(page.matches.map(\.line), [1, 2, 3])
        XCTAssertTrue(page.isCapped)
    }

    private func project() -> WorkspaceFileSearchProject {
        WorkspaceFileSearchProject(
            projectID: projectID,
            projectName: "Search Project",
            root: directory,
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    private func matches(count: Int) -> [ProjectTextSearchMatch] {
        (1 ... count).map { line in
            ProjectTextSearchMatch(
                relativePath: "Example.swift",
                line: line,
                text: "needle \(line)"
            )
        }
    }

    private func query(_ text: String, scope: SearchScope) throws -> SearchQuery {
        try SearchQueryParser.parse(text, scope: scope, generation: 7).get()
    }

    private func batches(
        from provider: ProjectTextSearchProvider,
        query: SearchQuery
    ) async -> [SearchBatch] {
        var result: [SearchBatch] = []
        for await batch in provider.search(SearchProviderRequest(
            query: query,
            clientCapabilities: .macOS
        )) {
            result.append(batch)
        }
        return result
    }
}
