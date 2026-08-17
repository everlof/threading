import XCTest
@testable import Threading

/// Where a shake report sent from a paired phone does its work.
///
/// The choice is made on the Mac, in advance, because the session it governs starts while its
/// owner is somewhere else. These are the rules that decide what the phone is offered.
final class PhoneReportWorkspacePolicyTests: XCTestCase {

    // MARK: - What Each Answer Asks For

    func testTheDefaultIsTheCheckoutTheProjectAlreadyHas() {
        XCTAssertNil(
            PhoneReportWorkspacePolicy.sameCheckout.requestedPlan,
            "the answer that changes nothing asked for a worktree"
        )
    }

    func testEachIsolatedAnswerCarriesItsOwnDelivery() {
        XCTAssertEqual(
            PhoneReportWorkspacePolicy.ownWorkspaceMerged.requestedPlan?.delivery,
            .mergeAndCleanUp
        )
        XCTAssertEqual(
            PhoneReportWorkspacePolicy.ownWorkspaceKept.requestedPlan?.delivery,
            .keepForReview
        )
    }

    /// Publishing is the composer's separate, nested decision. A setting made once in advance
    /// is not the place to agree to open a change request from a phone in somebody's pocket.
    func testNeitherIsolatedAnswerPublishesAChangeRequest() {
        for policy in PhoneReportWorkspacePolicy.allCases {
            XCTAssertNil(
                policy.requestedPlan?.publication,
                "\(policy.rawValue) would have published a review nobody asked for"
            )
        }
    }

    // MARK: - What The Project Allows

    func testAnIsolatedAnswerSurvivesWhenTheProjectCanHostOne() {
        XCTAssertEqual(
            PhoneReportWorkspacePolicy.ownWorkspaceMerged.resolvedPlan(
                canProvisionWorkspace: true,
                supportsFinishHandshake: true
            )?.delivery,
            .mergeAndCleanUp
        )
    }

    /// A report is worth more than the workspace it wanted: the chat still starts, in the
    /// project's own checkout, rather than being refused because a setting could not be honoured.
    func testAProjectThatCannotHostAWorktreeStillGetsItsReport() {
        XCTAssertNil(
            PhoneReportWorkspacePolicy.ownWorkspaceKept.resolvedPlan(
                canProvisionWorkspace: false,
                supportsFinishHandshake: true
            ),
            "a report chat asked for a worktree in a project with no Git checkout"
        )
    }

    /// Without the finish handshake nothing would ever merge the worktree back or remove it, so
    /// the isolation would be a one-way door rather than a delivery.
    func testAnAgentThatCannotFinishIsNotGivenAWorkspace() {
        XCTAssertNil(
            PhoneReportWorkspacePolicy.ownWorkspaceMerged.resolvedPlan(
                canProvisionWorkspace: true,
                supportsFinishHandshake: false
            ),
            "a worktree was handed to an agent that cannot hand it back"
        )
    }

    func testTheDefaultStaysNilWhateverTheProjectSupports() {
        XCTAssertNil(
            PhoneReportWorkspacePolicy.sameCheckout.resolvedPlan(
                canProvisionWorkspace: true,
                supportsFinishHandshake: true
            )
        )
    }

    // MARK: - The Stored Choice

    /// The persisted value is a compatibility contract: a Mac that reads a policy it does not
    /// know must fall back to the behaviour every phone report has always had.
    func testAnUnknownStoredChoiceIsNotAWorkspace() {
        XCTAssertNil(PhoneReportWorkspacePolicy(rawValue: "ownWorkspaceRebased"))
    }
}
