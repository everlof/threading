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
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                settingEnabled: true,
                supportsAtomicSubmission: true,
                capability: .interact,
                inputControlFeatureSupported: true,
                canWrite: true,
                state: state
            ),
            .direct
        )
    }

    func testAcceptedParticipantKeepsCollaborationVisibleWhileAway() {
        let state = inputControlState(participants: [
            owner,
            .init(id: "member-anna", displayName: "Anna", role: .member, isOnline: false),
        ])

        XCTAssertTrue(MobileCollaborationPresentation.showsInputControl(
            featureSupported: true,
            capability: .interact,
            state: state
        ))
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                settingEnabled: true,
                supportsAtomicSubmission: true,
                capability: .interact,
                inputControlFeatureSupported: true,
                canWrite: true,
                state: state
            ),
            .independentComposer
        )
    }

    func testInteractiveGuestSeesOwnerAsAnotherParticipant() {
        let guest = RemoteCollaborationParticipantDTO(
            id: "member-anna",
            displayName: "Anna",
            role: .member,
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

    /// A host too old to describe its roster will never describe it, so the atomic composer is
    /// its settled answer rather than a placeholder.
    func testLegacyHostWithNoRosterKeepsTheAtomicComposer() {
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                settingEnabled: true,
                supportsAtomicSubmission: true,
                capability: .interact,
                inputControlFeatureSupported: false,
                canWrite: true,
                state: nil
            ),
            .independentComposer
        )
    }

    /// The gap between `hello` and the first `inputControl` frame, which is a render or two on a
    /// current host. Answering `.independentComposer` here drew the line composer and then took
    /// it away again the instant the roster said "just you" — the non-TUI text area flashing on
    /// the way into every solo terminal session. Nothing is offered until the roster settles it,
    /// which also keeps raw keystrokes from starting before we know who else is here.
    func testARosterThatHasNotArrivedYetOffersNothingRatherThanFlashingAComposer() {
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                settingEnabled: true,
                supportsAtomicSubmission: true,
                capability: .interact,
                inputControlFeatureSupported: true,
                canWrite: true,
                state: nil
            ),
            MobileTerminalInputMode.none
        )
    }

    /// The same window with the setting off: no composer was ever coming, so direct input is
    /// not being withheld for a roster it does not depend on.
    func testIndependentDraftsOffKeepsDirectInputWhileTheRosterIsUnknown() {
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                settingEnabled: false,
                supportsAtomicSubmission: true,
                capability: .interact,
                inputControlFeatureSupported: true,
                canWrite: true,
                state: nil
            ),
            .direct
        )
    }

    /// Someone else holding Focused control is not a reason to type into the PTY.
    func testAWithheldTurnOffersNoInputEvenSolo() {
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                settingEnabled: true,
                supportsAtomicSubmission: true,
                capability: .interact,
                inputControlFeatureSupported: true,
                canWrite: false,
                state: inputControlState(participants: [owner])
            ),
            MobileTerminalInputMode.none
        )
    }

    func testViewOnlySessionOffersNoInputSurface() {
        let state = inputControlState(participants: [owner])

        XCTAssertFalse(MobileCollaborationPresentation.showsInputControl(
            featureSupported: true,
            capability: .view,
            state: state
        ))
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                settingEnabled: true,
                supportsAtomicSubmission: true,
                capability: .view,
                inputControlFeatureSupported: true,
                canWrite: false,
                state: state
            ),
            MobileTerminalInputMode.none
        )
    }

    private var owner: RemoteCollaborationParticipantDTO {
        .init(id: "owner", displayName: "David", role: .owner, isOnline: true)
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
