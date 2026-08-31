@testable import Threading
import XCTest

final class WorkspaceMetadataSearchProviderTests: XCTestCase {
    func testAttachmentAndBrowserRowsHaveTypedLandingAndScope() async throws {
        let projectID = ProjectID()
        let otherProjectID = ProjectID()
        let sessionID = SessionID()
        let provider = WorkspaceMetadataSearchProvider(records: [
            record(
                destination: .attachment(SearchAttachmentID(rawValue: "asset-1")),
                projectID: projectID,
                sessionID: sessionID,
                title: "architecture.pdf",
                detail: "docs/architecture.pdf"
            ),
            record(
                destination: .browserTab(SearchBrowserTabID(rawValue: "tab-1")),
                projectID: otherProjectID,
                sessionID: SessionID(),
                title: "Search documentation",
                detail: "https://example.com/search"
            ),
        ])
        let query = try SearchQueryParser.parse(
            "architecture type:attachment",
            scope: .project(projectID),
            generation: 4
        ).get()

        let batches = await collect(provider.search(SearchProviderRequest(
            query: query,
            clientCapabilities: .macOS
        )))

        let hit = try XCTUnwrap(batches.flatMap(\.hits).first)
        guard case let .attachment(landedProject, landedSession, attachmentID) = hit.locator
        else { return XCTFail("Expected attachment locator") }
        XCTAssertEqual(landedProject, projectID)
        XCTAssertEqual(landedSession, sessionID)
        XCTAssertEqual(attachmentID.rawValue, "asset-1")
    }

    func testBrowserCoverageDisclosesMaterializedTabBoundary() async throws {
        let provider = WorkspaceMetadataSearchProvider(records: [
            record(
                destination: .browserTab(SearchBrowserTabID(rawValue: "tab-1")),
                projectID: ProjectID(),
                sessionID: SessionID(),
                title: "API guide",
                detail: "https://example.com/api"
            ),
        ])
        let query = try SearchQueryParser.parse(
            "api type:browser",
            scope: .everywhere,
            generation: 1
        ).get()

        let batches = await collect(provider.search(SearchProviderRequest(
            query: query,
            clientCapabilities: .macOS
        )))

        let browser = try XCTUnwrap(batches.first { $0.group == .destinations })
        XCTAssertEqual(browser.hits.count, 1)
        guard case .partial = browser.coverage else {
            return XCTFail("Expected an honest partial browser catalogue")
        }
    }

    private func record(
        destination: WorkspaceMetadataSearchRecord.Destination,
        projectID: ProjectID,
        sessionID: SessionID,
        title: String,
        detail: String
    ) -> WorkspaceMetadataSearchRecord {
        WorkspaceMetadataSearchRecord(
            destination: destination,
            projectID: projectID,
            projectName: "Project",
            sessionID: sessionID,
            sessionTitle: "Conversation",
            providerName: "Codex",
            title: title,
            detail: detail,
            isArchived: false,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func collect(_ stream: AsyncStream<SearchBatch>) async -> [SearchBatch] {
        var batches: [SearchBatch] = []
        for await batch in stream {
            batches.append(batch)
        }
        return batches
    }
}
