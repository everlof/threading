import XCTest
@testable import Threading

@MainActor
final class WindowNavigationCoordinatorTests: XCTestCase {
    private let sessionA = SessionID()
    private let sessionB = SessionID()
    private let sessionC = SessionID()

    func testReplayArrivalDoesNotCreateANewHistoryBranch() {
        let navigation = WindowNavigationCoordinator()
        navigation.recordVisit(.session(sessionA))
        navigation.recordVisit(.session(sessionB))

        guard let target = navigation.goBack() else {
            return XCTFail("The second visit must leave a Back destination")
        }
        XCTAssertEqual(target, .session(sessionA))
        navigation.recordVisit(target)

        XCTAssertFalse(navigation.canGoBack)
        XCTAssertTrue(navigation.canGoForward)
    }

    func testUnexpectedArrivalClearsADeferredReplay() {
        let navigation = WindowNavigationCoordinator()
        navigation.recordVisit(.session(sessionA))
        navigation.recordVisit(.session(sessionB))
        _ = navigation.goBack()

        navigation.recordVisit(.session(sessionC))

        XCTAssertFalse(navigation.canGoForward)
        XCTAssertEqual(navigation.goBack(), .session(sessionA))
    }

    func testSettingsDetourReturnsAComposerExactlyOnce() {
        let navigation = WindowNavigationCoordinator()
        let projectID = ProjectID()

        navigation.beginSettingsDetour(from: .composer(projectID))

        XCTAssertEqual(navigation.takeSettingsReturnTarget(), .composer(projectID))
        XCTAssertNil(navigation.takeSettingsReturnTarget())
    }

    func testSidewaysNavigationAbandonsTheSettingsReturnTarget() {
        let navigation = WindowNavigationCoordinator()
        navigation.beginSettingsDetour(from: .session(sessionA))

        navigation.abandonSettingsDetour()

        XCTAssertNil(navigation.takeSettingsReturnTarget())
    }

    func testPruningRemovesDeletedPagesFromHistoryAndSettingsReturn() {
        let navigation = WindowNavigationCoordinator()
        navigation.recordVisit(.session(sessionA))
        navigation.recordVisit(.session(sessionB))
        navigation.beginSettingsDetour(from: .session(sessionB))

        navigation.prune { $0 != .session(self.sessionB) }

        XCTAssertNil(navigation.takeSettingsReturnTarget())
        XCTAssertEqual(navigation.goBack(), .session(sessionA))
    }
}
