import XCTest
@testable import Threading

/// The selection-history rules, as pure state: what a visit pushes, what Back and Forward
/// retrace, and what pruning a deleted page leaves behind.
final class NavigationHistoryTests: XCTestCase {

    private let sessionA = SessionID()
    private let sessionB = SessionID()
    private let sessionC = SessionID()

    func testVisitingPushesAndBackRetraces() {
        var history = NavigationHistory()
        history.visit(.session(sessionA))
        history.visit(.session(sessionB))

        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        XCTAssertEqual(history.goBack(), .session(sessionA))
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.goForward(), .session(sessionB))
        XCTAssertFalse(history.canGoForward)
    }

    func testRevisitingTheCurrentPageSpendsNothing() {
        var history = NavigationHistory()
        history.visit(.session(sessionA))
        history.visit(.session(sessionA))

        XCTAssertFalse(history.canGoBack, "Selecting the row already on screen is not a step")
    }

    func testAFreshVisitForksTheTimeline() {
        var history = NavigationHistory()
        history.visit(.session(sessionA))
        history.visit(.session(sessionB))
        _ = history.goBack()

        history.visit(.session(sessionC))

        XCTAssertFalse(history.canGoForward, "A new visit discards what was ahead")
        XCTAssertEqual(history.goBack(), .session(sessionA))
    }

    func testBackAtTheBeginningAndForwardAtTheEndReportNil() {
        var history = NavigationHistory()
        XCTAssertNil(history.goBack())
        XCTAssertNil(history.goForward())

        history.visit(.session(sessionA))
        XCTAssertNil(history.goBack())
        XCTAssertNil(history.goForward())
    }

    func testMixedPageKindsRetraceInOrder() {
        var history = NavigationHistory()
        let projectID = ProjectID()
        history.visit(.session(sessionA))
        history.visit(.composer(projectID))
        history.visit(.settings("general"))

        XCTAssertEqual(history.goBack(), .composer(projectID))
        XCTAssertEqual(history.goBack(), .session(sessionA))
        XCTAssertEqual(history.goForward(), .composer(projectID))
    }

    // MARK: - Pruning

    func testPruneDropsInvalidPagesFromBothStacks() {
        var history = NavigationHistory()
        history.visit(.session(sessionA))
        history.visit(.session(sessionB))
        history.visit(.session(sessionC))
        _ = history.goBack()
        // back: [A], current: B, forward: [C]

        history.prune { page in
            page != .session(sessionA) && page != .session(sessionC)
        }

        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.current, .session(sessionB))
    }

    func testPruneCollapsesTheDuplicatesDeletionCreates() {
        var history = NavigationHistory()
        history.visit(.session(sessionA))
        history.visit(.session(sessionB))
        history.visit(.session(sessionA))
        history.visit(.session(sessionB))
        history.visit(.session(sessionC))
        // back: [A, B, A, B], current: C

        history.prune { $0 != .session(sessionB) }

        // [A, _, A, _] would leave Back visibly doing nothing between the two As.
        XCTAssertEqual(history.goBack(), .session(sessionA))
        XCTAssertNil(history.goBack(), "The adjacent duplicate must have collapsed")
    }

    func testPruneDropsAStackEndingInTheCurrentPage() {
        var history = NavigationHistory()
        history.visit(.session(sessionA))
        history.visit(.session(sessionB))
        history.visit(.session(sessionC))
        // back: [A, B], current: C

        history.prune { $0 != .session(sessionB) }
        // back would be [A]; a boundary equal to current would be a no-op step.
        XCTAssertEqual(history.goBack(), .session(sessionA))

        history = NavigationHistory()
        history.visit(.session(sessionA))
        history.visit(.session(sessionC))
        history.visit(.session(sessionA))
        // back: [A, C], current: A
        history.prune { $0 != .session(sessionC) }

        XCTAssertFalse(
            history.canGoBack,
            "Back to the page already on screen is not a step anyone asked for"
        )
    }

    func testPruneInvalidatesTheCurrentPage() {
        var history = NavigationHistory()
        history.visit(.session(sessionA))
        history.visit(.session(sessionB))

        history.prune { $0 != .session(sessionB) }

        XCTAssertNil(history.current)
        XCTAssertEqual(history.goBack(), .session(sessionA))
    }
}
