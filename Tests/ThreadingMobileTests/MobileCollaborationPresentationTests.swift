import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

final class MobileCollaborationPresentationTests: XCTestCase {
    func testOwnerOnlyStateHidesControlAndUsesTheDirectPreference() {
        let state = inputControlState(participants: [owner])

        XCTAssertFalse(MobileCollaborationPresentation.showsInputControl(
            featureSupported: true,
            capability: .interact,
            state: state
        ))
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                preference: .direct,
                supportsAtomicSubmission: true,
                capability: .interact,
                inputControlFeatureSupported: true,
                canWrite: true,
                state: state
            ),
            .direct
        )
    }

    func testSoloTerminalCanForceTheComposer() {
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                preference: .compose,
                supportsAtomicSubmission: true,
                capability: .interact,
                inputControlFeatureSupported: true,
                canWrite: true,
                state: inputControlState(participants: [owner])
            ),
            .independentComposer
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
                preference: .direct,
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
                preference: .direct,
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
                preference: .compose,
                supportsAtomicSubmission: true,
                capability: .interact,
                inputControlFeatureSupported: true,
                canWrite: true,
                state: nil
            ),
            MobileTerminalInputMode.none
        )
    }

    func testTheDirectPreferenceStillWaitsForTheCurrentHostRoster() {
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                preference: .direct,
                supportsAtomicSubmission: true,
                capability: .interact,
                inputControlFeatureSupported: true,
                canWrite: true,
                state: nil
            ),
            .none
        )
    }

    /// Someone else holding Focused control is not a reason to type into the PTY.
    func testAWithheldTurnOffersNoInputEvenSolo() {
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                preference: .compose,
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
                preference: .direct,
                supportsAtomicSubmission: true,
                capability: .view,
                inputControlFeatureSupported: true,
                canWrite: false,
                state: state
            ),
            MobileTerminalInputMode.none
        )
    }

    func testHostWithoutAtomicSubmissionFallsBackToDirectInput() {
        XCTAssertEqual(
            MobileCollaborationPresentation.terminalInputMode(
                preference: .compose,
                supportsAtomicSubmission: false,
                capability: .interact,
                inputControlFeatureSupported: false,
                canWrite: true,
                state: nil
            ),
            .direct
        )
    }

    @MainActor
    func testTerminalInputPreferenceIsRememberedPerSessionOnThisDevice() {
        let suiteName = "MobileCollaborationPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MobileSessionContinuityStore(defaults: defaults)
        store.setTerminalInputPreference(.compose, hostID: "mac-a", sessionID: "terminal-a")

        XCTAssertEqual(
            MobileSessionContinuityStore(defaults: defaults)
                .state(hostID: "mac-a", sessionID: "terminal-a")
                .terminalInputPreference,
            .compose
        )
        XCTAssertNil(
            MobileSessionContinuityStore(defaults: defaults)
                .state(hostID: "mac-a", sessionID: "terminal-b")
                .terminalInputPreference
        )

        store.setTerminalInputPreference(.direct, hostID: "mac-a", sessionID: "terminal-a")
        XCTAssertEqual(
            MobileSessionContinuityStore(defaults: defaults)
                .state(hostID: "mac-a", sessionID: "terminal-a")
                .terminalInputPreference,
            .direct
        )
    }

    func testOwnDevicesNeverShowPresenceOrTypingEvenWithAcceptedMembers() {
        let presence = MobileCollaborationPresence([
            activity("phone", person: "owner:phone", name: "iPhone", state: .typing),
            activity("tablet", person: "owner:tablet", name: "iPad"),
            activity("canonical", person: "owner", name: "David"),
        ])
        XCTAssertNil(presence.label(currentParticipantID: "owner", showsTyping: true, showsViewing: true))
        XCTAssertNil(presence.label(currentParticipantID: nil, showsTyping: true, showsViewing: true))
    }

    func testCollaboratorUsesTheirNameAndCountsTheirDevicesOnce() {
        let presence = MobileCollaborationPresence([
            activity("phone", person: "anna", name: "Anna"),
            activity("tablet", person: "anna", name: "Anna"),
            activity("self", person: "owner:phone", name: "iPhone", state: .typing),
        ])
        XCTAssertEqual(label(presence), MobileL10n.string("%@ is here", "Anna"))
    }

    func testOneSocketLeavingPreservesAnotherSocketAndItsTypingState() {
        var presence = MobileCollaborationPresence([
            activity("phone", person: "anna", name: "Anna", state: .typing),
            activity("tablet", person: "anna", name: "Anna"),
        ])
        XCTAssertEqual(label(presence), MobileL10n.string("%@ is typing…", "Anna"))
        // A repeated typing frame is a replacement, not a second live connection.
        presence.apply(activity("phone", person: "anna", name: "Anna", state: .typing))
        presence.apply(activity("phone", person: "anna", name: "Anna", state: .left))
        XCTAssertEqual(label(presence), MobileL10n.string("%@ is here", "Anna"))
        presence.apply(activity("tablet", person: "anna", name: "Anna", state: .left))
        XCTAssertNil(label(presence))
    }

    func testGuestExcludesTheirOtherDevicesAndOwnerIsNeverNamedIPhone() {
        let presence = MobileCollaborationPresence([
            activity("own", person: "anna", name: "Anna", state: .typing),
            activity("host", person: "owner:phone", name: "iPhone"),
        ])
        XCTAssertEqual(
            presence.label(currentParticipantID: "anna", showsTyping: true, showsViewing: true),
            MobileL10n.string("%@ is here", MobileL10n.string("Owner"))
        )
    }

    func testDifferentPeopleWithTheSameNameAreNotMerged() {
        let presence = MobileCollaborationPresence([
            activity("a", person: "anna-a", name: "Anna"),
            activity("b", person: "anna-b", name: "Anna"),
        ])
        XCTAssertEqual(label(presence), MobileL10n.string(
            "%@ are here", ["Anna", "Anna"].joined(separator: MobileL10n.string(" and "))
        ))
    }

    func testPresenceAndTypingPreferencesRemainIndependent() {
        let presence = MobileCollaborationPresence([
            activity("anna", person: "anna", name: "Anna", state: .typing),
        ])
        XCTAssertEqual(
            presence.label(currentParticipantID: "owner", showsTyping: false, showsViewing: true),
            MobileL10n.string("%@ is here", "Anna")
        )
        XCTAssertEqual(
            presence.label(currentParticipantID: "owner", showsTyping: true, showsViewing: false),
            MobileL10n.string("%@ is typing…", "Anna")
        )
        XCTAssertNil(presence.label(currentParticipantID: "owner", showsTyping: false, showsViewing: false))
    }

    @MainActor
    func testWirePresenceWaitsForIdentityAndClearsWhenTheOtherPersonLeaves() throws {
        let connection = RemoteSessionConnection(
            session: .init(id: "presence", title: "Presence", agentKind: "codex",
                           surface: .terminal, state: .working, projectName: "Fixture"),
            client: RemoteClient(link: RemoteConnectionLink(string: "https://presence.invalid/#fixture")!)
        )
        func receive(_ value: some Encodable) throws {
            connection.receiveServerTextForTesting(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
        }
        func visibleLabel() -> String? {
            connection.presence.label(currentParticipantID: connection.inputControl?.currentParticipantID,
                                      showsTyping: true, showsViewing: true)
        }
        try receive(activity("self", person: "owner:phone", name: "iPhone"))
        XCTAssertNil(visibleLabel())
        try receive(inputControlState(participants: [owner]))
        XCTAssertNil(visibleLabel())
        try receive(activity("anna", person: "anna", name: "Anna", state: .typing))
        XCTAssertEqual(visibleLabel(), MobileL10n.string("%@ is typing…", "Anna"))
        try receive(activity("anna", person: "anna", name: "Anna", state: .left))
        XCTAssertNil(visibleLabel())
    }

    func testThousandSocketsCountPeopleAndClearWithoutStalePresence() {
        var presence = MobileCollaborationPresence()
        for index in 0..<1_000 {
            presence.apply(activity("socket-\(index)", person: "person-\(index / 2)", name: "Person"))
        }
        XCTAssertEqual(label(presence), MobileL10n.string("%lld people are here", Int64(500)))
        for index in stride(from: 0, to: 1_000, by: 2) {
            presence.apply(activity("socket-\(index)", person: "person-\(index / 2)", name: "Person", state: .left))
        }
        XCTAssertEqual(label(presence), MobileL10n.string("%lld people are here", Int64(500)))
        presence.removeAll()
        XCTAssertNil(label(presence))
    }

    private func activity(
        _ socket: String, person: String, name: String, state: RemotePresenceState = .viewing
    ) -> RemotePresenceDTO {
        .init(presenceID: socket, memberID: person, displayName: name, deviceName: "iPhone", state: state)
    }

    private func label(_ presence: MobileCollaborationPresence) -> String? {
        presence.label(currentParticipantID: "owner", showsTyping: true, showsViewing: true)
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
