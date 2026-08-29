import AppKit
import XCTest
@testable import Threading

@MainActor
final class ArchivedPreferencesSearchTests: XCTestCase {
    func testMatcherFindsTitlesAndProjectsCaseInsensitively() {
        let records = [
            ArchivedSessionSearchRecord(
                sourceIndex: 0,
                title: "Parser cleanup",
                projectName: "Threading"
            ),
            ArchivedSessionSearchRecord(
                sourceIndex: 1,
                title: "Release notes",
                projectName: "Website"
            ),
        ]

        XCTAssertEqual(
            ArchivedSessionSearch.matchingIndexes(in: records, query: "PARSER"),
            [0]
        )
        XCTAssertEqual(
            ArchivedSessionSearch.matchingIndexes(in: records, query: "website"),
            [1]
        )
    }

    func testSearchIncludesMatchesBehindTheRecentFoldAndClearingRestoresIt() async {
        let project = Project(
            name: "Archive search",
            folderURL: URL(fileURLWithPath: "/tmp/threading-archive-search")
        )
        let now = Date()
        let entries: [ArchivedPreferencesViewController.Entry] = (0..<20).map { index in
            var session = AgentSession(
                kind: .codex,
                title: index == 15 ? "Needle conversation" : "Archived conversation \(index)"
            )
            session.isArchived = true
            session.archivedAt = now.addingTimeInterval(TimeInterval(-index))
            return (project, session)
        }
        let controller = ArchivedPreferencesViewController(rowsProvider: { entries })
        _ = controller.view
        controller.viewWillAppear()

        XCTAssertEqual(controller.filteredArchiveCountForTesting, entries.count)
        XCTAssertEqual(controller.virtualRowCountForTesting, 12)

        controller.searchFieldForTesting.stringValue = "needle"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: controller.searchFieldForTesting
        ))
        for _ in 0..<100 where controller.filteredArchiveCountForTesting != 1 {
            await Task.yield()
        }

        XCTAssertEqual(controller.filteredArchiveCountForTesting, 1)
        XCTAssertEqual(controller.virtualRowCountForTesting, 2)

        controller.searchFieldForTesting.clear()
        await Task.yield()

        XCTAssertEqual(controller.filteredArchiveCountForTesting, entries.count)
        XCTAssertEqual(controller.virtualRowCountForTesting, 12)
    }
}
