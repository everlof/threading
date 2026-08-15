import XCTest
@testable import Threading

@MainActor
final class BrowserNavigationCoordinatorTests: XCTestCase {
    func testNewNavigationSupersedesThePreviousCompletion() {
        let coordinator = BrowserNavigationCoordinator()
        var first: (Bool, String)?

        coordinator.begin(waitUntil: .load) { first = ($0, $1) }
        coordinator.begin(waitUntil: .load) { _, _ in }

        XCTAssertEqual(first?.0, false)
        XCTAssertEqual(first?.1, "Superseded by a newer navigation.")
        XCTAssertTrue(coordinator.hasPendingNavigation)
    }

    func testCommitReadinessCompletesAtCommit() {
        let coordinator = BrowserNavigationCoordinator()
        var result: (Bool, String)?
        coordinator.begin(waitUntil: .commit) { result = ($0, $1) }

        XCTAssertEqual(coordinator.didCommit(), .none)

        XCTAssertEqual(result?.0, true)
        XCTAssertEqual(
            result?.1,
            "Navigation committed; the document and subresources may still be loading."
        )
        XCTAssertFalse(coordinator.hasPendingNavigation)
    }

    func testDOMContentLoadedRequiresTheEventAndCommittedDocumentToken() {
        let coordinator = BrowserNavigationCoordinator()
        var result: (Bool, String)?
        coordinator.begin(waitUntil: .domContentLoaded) { result = ($0, $1) }
        guard case .readDocumentToken(let navigationID) = coordinator.didCommit() else {
            return XCTFail("A DOM-ready navigation must request its committed document token")
        }

        coordinator.observedDOMContentLoaded("document-1")
        XCTAssertNil(result)
        coordinator.recordDocumentToken("document-1", for: navigationID)

        XCTAssertEqual(result?.0, true)
        XCTAssertTrue(result?.1.contains("DOMContentLoaded") == true)
        XCTAssertFalse(coordinator.hasPendingNavigation)
    }

    func testStaleDocumentTokenCannotCompleteANewerNavigation() {
        let coordinator = BrowserNavigationCoordinator()
        var first: (Bool, String)?
        var second: (Bool, String)?
        coordinator.begin(waitUntil: .domContentLoaded) { first = ($0, $1) }
        guard case .readDocumentToken(let staleID) = coordinator.didCommit() else {
            return XCTFail("Expected a document-token read")
        }
        coordinator.begin(waitUntil: .domContentLoaded) { second = ($0, $1) }

        coordinator.recordDocumentToken("stale", for: staleID)
        coordinator.observedDOMContentLoaded("stale")

        XCTAssertEqual(first?.0, false)
        XCTAssertNil(second)
        XCTAssertTrue(coordinator.hasPendingNavigation)
    }

    func testTimeoutCompletesOnlyTheNavigationItNames() {
        let coordinator = BrowserNavigationCoordinator()
        var current: (Bool, String)?
        let staleID = coordinator.begin(waitUntil: .load) { _, _ in }
        let currentID = coordinator.begin(waitUntil: .domContentLoaded) { current = ($0, $1) }

        coordinator.timeout(staleID, after: 20)
        XCTAssertNil(current)
        coordinator.timeout(currentID, after: 20)

        XCTAssertEqual(current?.0, true)
        XCTAssertEqual(
            current?.1,
            "Did not reach domcontentloaded after 20s; returning what has rendered."
        )
    }

    func testFullLoadCompletesTheCurrentNavigation() {
        let coordinator = BrowserNavigationCoordinator()
        var result: (Bool, String)?
        coordinator.begin(waitUntil: .load) { result = ($0, $1) }

        coordinator.didFinishLoading()

        XCTAssertEqual(result?.0, true)
        XCTAssertEqual(result?.1, "")
        XCTAssertFalse(coordinator.hasPendingNavigation)
    }
}
