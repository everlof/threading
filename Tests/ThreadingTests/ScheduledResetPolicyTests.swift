import XCTest

@testable import Threading

/// How patient a send aimed at a usage window's reset is when the window has not turned over.
///
/// The matrix lives on the policy rather than inside the performer so it can be asserted without
/// a window, a store or a live account — and because the first version of the caller read the
/// state off `resetsAt` and got the boolean exactly backwards, which no test could see while the
/// rule lived inside a view controller.
@MainActor
final class ScheduledResetPolicyTests: XCTestCase {

    // MARK: - Standing Aside

    func testSendAnywayNeverStandsAside() {
        XCTAssertFalse(
            ScheduledResetPolicy.sendAnyway.shouldStandAside(
                alreadyRearmed: 0,
                windowHasReset: false
            ),
            "The time you picked is the time it sends — that is the whole promise of this one"
        )
    }

    func testWaitOnceStandsAsideExactlyOnce() {
        let policy = ScheduledResetPolicy.waitOnce

        XCTAssertTrue(policy.shouldStandAside(alreadyRearmed: 0, windowHasReset: false))
        XCTAssertFalse(
            policy.shouldStandAside(alreadyRearmed: 1, windowHasReset: false),
            "Once, then deliver regardless — otherwise it is the third option under another name"
        )
    }

    func testWaitUntilResetIsBoundedRatherThanEndless() {
        let policy = ScheduledResetPolicy.waitUntilReset
        let cap = ScheduledMessageDefaults.maximumResetRearms

        XCTAssertTrue(policy.shouldStandAside(alreadyRearmed: cap - 1, windowHasReset: false))
        XCTAssertFalse(
            policy.shouldStandAside(alreadyRearmed: cap, windowHasReset: false),
            """
            "Wait until it resets" still has to terminate: a misreported window must not turn \
            one scheduled message into an unbounded chase.
            """
        )
    }

    // MARK: - The Boolean That Was Inverted

    func testNobodyStandsAsideForAWindowThatHasRoom() {
        for policy in ScheduledResetPolicy.allCases {
            XCTAssertFalse(
                policy.shouldStandAside(alreadyRearmed: 0, windowHasReset: true),
                """
                \(policy): a window with room is the moment the send was waiting for. Standing \
                aside here is the inverted-condition bug — it would postpone precisely when it \
                should deliver, and deliver precisely when it should wait.
                """
            )
        }
    }

    // MARK: - Storage

    func testTheDefaultIsToWaitOnce() {
        XCTAssertEqual(ScheduledResetPolicy.default, .waitOnce)
    }

    func testEveryPolicyNamesItselfAndExplainsItself() {
        for policy in ScheduledResetPolicy.allCases {
            XCTAssertFalse(policy.title.isEmpty, "\(policy) has no name to show")
            XCTAssertFalse(policy.explanation.isEmpty, "\(policy) has no consequence to state")
        }
    }

    func testRawValuesAreStableBecauseTheyArePersisted() {
        // A stored preference. Renaming a case silently resets everybody's choice to the
        // default, which is the failure `AttentionAlert` documents one shelf along.
        XCTAssertEqual(
            Set(ScheduledResetPolicy.allCases.map(\.rawValue)),
            ["sendAnyway", "waitOnce", "waitUntilReset"]
        )
    }
}
