import XCTest
@testable import ThreadingMobile

final class MobileSessionNavigationTransitionTests: XCTestCase {
    func testTerminalSessionNavigationCommitsFinalGeometryImmediately() {
        XCTAssertEqual(
            MobileSessionNavigationTransition.forSurface("terminal"),
            .immediate
        )
    }

    func testNativeConversationKeepsTheStandardNavigationTransition() {
        XCTAssertEqual(
            MobileSessionNavigationTransition.forSurface("conversation"),
            .standard
        )
    }
}
