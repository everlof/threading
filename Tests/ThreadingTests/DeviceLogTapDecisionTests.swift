import XCTest
@testable import Threading

/// The consent record for linking the log tap into a user's own app.
///
/// The tap changes what that app publishes: printed output stops being ephemeral and becomes a
/// public `os_log` entry that persists on the device and leaves it in a sysdiagnose. So the rule
/// worth holding is narrow and absolute — an answer belongs to the chat that was asked, and is
/// never inherited by another.
final class DeviceLogTapDecisionTests: XCTestCase {

    private let first = SessionID()
    private let second = SessionID()

    func testNothingIsGrantedBeforeAnyoneIsAsked() {
        XCTAssertNil(DeviceLogTapDecisions().decision(for: first))
    }

    func testAnApprovalBelongsOnlyToTheChatThatGaveIt() {
        var decisions = DeviceLogTapDecisions()
        decisions.remember(true, for: first)
        XCTAssertEqual(decisions.decision(for: first), true)
        XCTAssertNil(
            decisions.decision(for: second),
            "one chat's grant must never authorise another chat's agent"
        )
    }

    /// A refusal is remembered for the same reason an approval is: an agent that retries must not
    /// turn a "no" into repeated prompting.
    func testARefusalIsRememberedRatherThanReAsked() {
        var decisions = DeviceLogTapDecisions()
        decisions.remember(false, for: first)
        XCTAssertEqual(decisions.decision(for: first), false)
    }

    func testAnAnswerCanBeChangedAndTheNewestWins() {
        var decisions = DeviceLogTapDecisions()
        decisions.remember(false, for: first)
        decisions.remember(true, for: first)
        XCTAssertEqual(decisions.decision(for: first), true)
        XCTAssertEqual(
            decisions.entries.filter { $0.hasPrefix(first.rawValue.uuidString) }.count,
            1,
            "changing an answer replaces it rather than stacking a second one"
        )
    }

    /// The record is capped because a chat list is externally sized. Dropping the oldest costs one
    /// extra question; it must never silently turn into a grant.
    func testTheRecordIsCappedAndForgetsOldestFirst() {
        var decisions = DeviceLogTapDecisions()
        var identifiers: [SessionID] = []
        for _ in 0..<(DeviceLogTapDecisions.capacity + 5) {
            let id = SessionID()
            identifiers.append(id)
            decisions.remember(true, for: id)
        }
        XCTAssertEqual(decisions.entries.count, DeviceLogTapDecisions.capacity)
        XCTAssertNil(
            decisions.decision(for: identifiers[0]),
            "the oldest answer is forgotten, which means asking again"
        )
        XCTAssertEqual(decisions.decision(for: identifiers.last!), true)
    }

    func testForgettingFallsBackToAskingRatherThanToAllowing() {
        var decisions = DeviceLogTapDecisions()
        let denied = SessionID()
        decisions.remember(false, for: denied)
        for _ in 0..<DeviceLogTapDecisions.capacity {
            decisions.remember(true, for: SessionID())
        }
        XCTAssertNil(
            decisions.decision(for: denied),
            "an evicted refusal becomes a question, never an inherited yes"
        )
    }
}
