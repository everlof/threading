import XCTest
@testable import ThreadingMobile

/// The socket's reconnect ladder. What resets the count it reads is the model's rule, held by an
/// architecture check; this pins the steps the count buys.
final class MobileSocketRecoveryBackoffTests: XCTestCase {
    func testTheLadderDoublesFromOneSecondToTheCeiling() {
        let delays = [0, 1, 2, 3, 4, 5, 6, 7, 40].map(MobileSocketRecoveryBackoff.delay(forAttempt:))
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 32, 60, 60, 60])
    }

    func testACountBelowZeroIsTheFirstStep() {
        XCTAssertEqual(MobileSocketRecoveryBackoff.delay(forAttempt: -3), MobileSocketRecoveryBackoff.firstDelay)
    }
}
