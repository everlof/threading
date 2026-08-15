import XCTest
@testable import Threading

@MainActor
final class BrowserAgentNavigationPolicyTests: XCTestCase {
    func testSubmissionWithoutAgentActionRemainsUserNavigation() {
        let policy = BrowserAgentNavigationPolicy()

        XCTAssertEqual(policy.decideFormSubmission(), .allow)
    }

    func testUnapprovedAgentSubmissionIsCancelledAndRecorded() {
        let policy = BrowserAgentNavigationPolicy()
        let actionID = policy.beginAction(allowsFormSubmission: false)

        XCTAssertEqual(policy.decideFormSubmission(), .cancel)
        XCTAssertTrue(policy.wasFormSubmissionBlocked(during: actionID))
    }

    func testApprovedAgentActionMaySubmitExactlyOnce() {
        let policy = BrowserAgentNavigationPolicy()
        let actionID = policy.beginAction(allowsFormSubmission: true)

        XCTAssertEqual(policy.decideFormSubmission(), .allow)
        XCTAssertFalse(policy.wasFormSubmissionBlocked(during: actionID))
        XCTAssertEqual(policy.decideFormSubmission(), .cancel)
        XCTAssertTrue(policy.wasFormSubmissionBlocked(during: actionID))
    }

    func testStaleActionCannotClearNewerPolicyState() {
        let policy = BrowserAgentNavigationPolicy()
        let staleID = policy.beginAction(allowsFormSubmission: true)
        let currentID = policy.beginAction(allowsFormSubmission: false)

        policy.endAction(staleID)

        XCTAssertEqual(policy.decideFormSubmission(), .cancel)
        XCTAssertFalse(policy.wasFormSubmissionBlocked(during: staleID))
        XCTAssertTrue(policy.wasFormSubmissionBlocked(during: currentID))
    }

    func testEndingCurrentActionRestoresOrdinaryNavigation() {
        let policy = BrowserAgentNavigationPolicy()
        let actionID = policy.beginAction(allowsFormSubmission: false)

        policy.endAction(actionID)

        XCTAssertEqual(policy.decideFormSubmission(), .allow)
        XCTAssertFalse(policy.wasFormSubmissionBlocked(during: actionID))
    }
}
