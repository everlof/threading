import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

final class MobileCollaborationPresentationTests: XCTestCase {
    func testOwnerOnlyStateHidesControlAndUsesDirectTerminalInput() {
        let state = inputControlState(participants: [owner])

        XCTAssertFalse(MobileCollaborationPresentation.showsInputControl(
            featureSupported: true,
            capability: .interact,
            state: state
        ))
        XCTAssertFalse(MobileCollaborationPresentation.usesIndependentTerminalComposer(
            settingEnabled: true,
            supportsAtomicSubmission: true,
            capability: .interact,
            inputControlFeatureSupported: true,
            state: state
        ))
    }

    func testAcceptedParticipantKeepsCollaborationVisibleWhileAway() {
        let state = inputControlState(participants: [
            owner,
            .init(id: "member-anna", displayName: "Anna", role: "member", isOnline: false),
        ])

        XCTAssertTrue(MobileCollaborationPresentation.showsInputControl(
            featureSupported: true,
            capability: .interact,
            state: state
        ))
        XCTAssertTrue(MobileCollaborationPresentation.usesIndependentTerminalComposer(
            settingEnabled: true,
            supportsAtomicSubmission: true,
            capability: .interact,
            inputControlFeatureSupported: true,
            state: state
        ))
    }

    func testInteractiveGuestSeesOwnerAsAnotherParticipant() {
        let guest = RemoteCollaborationParticipantDTO(
            id: "member-anna",
            displayName: "Anna",
            role: "member",
            isOnline: true
        )
        let state = inputControlState(
            currentParticipantID: guest.id,
            participants: [owner, guest]
        )

        XCTAssertTrue(MobileCollaborationPresentation.showsInputControl(
            featureSupported: true,
            capability: .interact,
            state: state
        ))
    }

    func testUnresolvedOrLegacyRosterConservativelyKeepsAtomicComposer() {
        XCTAssertTrue(MobileCollaborationPresentation.usesIndependentTerminalComposer(
            settingEnabled: true,
            supportsAtomicSubmission: true,
            capability: .interact,
            inputControlFeatureSupported: true,
            state: nil
        ))
        XCTAssertTrue(MobileCollaborationPresentation.usesIndependentTerminalComposer(
            settingEnabled: true,
            supportsAtomicSubmission: true,
            capability: .interact,
            inputControlFeatureSupported: false,
            state: nil
        ))
    }

    func testViewOnlySessionOffersNoInputSurface() {
        let state = inputControlState(participants: [owner])

        XCTAssertFalse(MobileCollaborationPresentation.showsInputControl(
            featureSupported: true,
            capability: .view,
            state: state
        ))
        XCTAssertFalse(MobileCollaborationPresentation.usesIndependentTerminalComposer(
            settingEnabled: true,
            supportsAtomicSubmission: true,
            capability: .view,
            inputControlFeatureSupported: true,
            state: state
        ))
    }

    private var owner: RemoteCollaborationParticipantDTO {
        .init(id: "owner", displayName: "David", role: "owner", isOnline: true)
    }

    private func inputControlState(
        currentParticipantID: String = "owner",
        participants: [RemoteCollaborationParticipantDTO]
    ) -> RemoteInputControlStateDTO {
        RemoteInputControlStateDTO(
            mode: .collaborative,
            currentParticipantID: currentParticipantID,
            canWrite: true,
            canManage: currentParticipantID == "owner",
            canHandOff: false,
            participants: participants,
            revision: 0
        )
    }
}
