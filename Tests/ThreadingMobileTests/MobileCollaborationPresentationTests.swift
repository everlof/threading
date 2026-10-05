import Darwin
import SwiftUI
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// Hosted tests have no UI automation agent to enable SwiftUI's accessibility graph. Keep this
/// runtime switch in the test bundle and restore it after each inspection. AccessibilitySnapshot
/// uses the same runtime seam: https://github.com/cashapp/AccessibilitySnapshot/blob/main/Sources/AccessibilitySnapshot/Parser/ObjC/ASAccessibilityEnabler.m
@MainActor
enum MobileAccessibilityTestRuntime {
    private enum Failure: Error {
        case runtimeUnavailable
    }

    static func enableAutomation() throws -> @MainActor () -> Void {
        let simulatorRoot = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        guard let library = dlopen(simulatorRoot + "/usr/lib/libAccessibility.dylib", RTLD_LAZY | RTLD_LOCAL) else {
            throw Failure.runtimeUnavailable
        }
        guard let readSymbol = dlsym(library, "_AXSAutomationEnabled"),
              let writeSymbol = dlsym(library, "_AXSSetAutomationEnabled") else {
            dlclose(library)
            throw Failure.runtimeUnavailable
        }
        let read = unsafeBitCast(readSymbol, to: (@convention(c) () -> Int32).self)
        let write = unsafeBitCast(writeSymbol, to: (@convention(c) (Int32) -> Void).self)
        let original = read()
        write(1)
        return {
            write(original)
            dlclose(library)
        }
    }

    static func element(labelled label: String, in root: NSObject) -> NSObject? {
        var pending = [root]
        var visited = Set<ObjectIdentifier>()
        while let element = pending.popLast() {
            guard visited.insert(ObjectIdentifier(element)).inserted,
                  (element as? UIView)?.isHidden != true else { continue }
            if element.accessibilityLabel == label { return element }
            // Accessible leaves are atomic even when automation can vend their backing views.
            guard !element.isAccessibilityElement else { continue }
            let children = (element.automationElements as? [NSObject])
                ?? (element.accessibilityElements as? [NSObject]) ?? []
            pending.append(contentsOf: children)
            if children.isEmpty {
                let count = element.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    pending.append(contentsOf: (0..<count).compactMap {
                        element.accessibilityElement(at: $0) as? NSObject
                    })
                }
            }
            pending.append(contentsOf: (element as? UIView)?.subviews ?? [])
        }
        return nil
    }
}

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
    func testTerminalToggleIsSharedAcrossSessionsAndSurvivesRecreation() throws {
        let restoreAccessibility = try MobileAccessibilityTestRuntime.enableAutomation()
        defer { restoreAccessibility() }
        let suiteName = "MobileCollaborationPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        func connection(_ id: String) throws -> RemoteSessionConnection {
            let connection = RemoteSessionConnection(
                session: .init(id: id, title: id, agentKind: "codex", surface: .terminal,
                               state: .idle, projectName: "Fixture"),
                client: RemoteClient(link: try XCTUnwrap(RemoteConnectionLink(
                    string: "https://fixture.invalid/#terminal"
                )))
            )
            func receive(_ value: some Encodable) throws {
                connection.receiveServerTextForTesting(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
            }
            try receive(RemoteHelloDTO(
                surface: .terminal, capability: .interact, cols: 80, rows: 24, title: id,
                features: [RemoteWebSocketFeature.atomicTerminalSubmission.rawValue,
                           RemoteWebSocketFeature.focusedInputControl.rawValue]
            ))
            try receive(inputControlState(participants: [owner]))
            return connection
        }

        let store = MobileSessionContinuityStore(defaults: defaults)
        let model = RemoteAppModel(continuity: store)
        model.startDemo()
        func host(_ connection: RemoteSessionConnection, preferences: UserDefaults) -> UIViewController {
            UIHostingController(rootView: TerminalRemoteView(
                connection: connection, openingLoaderOwner: .terminalSurface,
                inputPreferences: preferences
            )
            .environmentObject(model)
            .environmentObject(store)
            .environmentObject(RemoteNotificationManager())
            .environmentObject(MobileTerminalKeyboardStore(defaults: defaults)))
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let first = try connection("first")
        let navigation = UINavigationController(rootViewController: host(first, preferences: defaults))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func settle() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()
        }
        func element(_ label: String, in root: NSObject) -> NSObject? {
            MobileAccessibilityTestRuntime.element(labelled: MobileL10n.string(label), in: root)
        }
        func toggle(_ label: String) throws {
            let button = try XCTUnwrap(element(label, in: window))
            XCTAssertTrue(button.accessibilityActivate())
            settle()
        }
        settle()
        try toggle("Compose terminal input")
        XCTAssertEqual(defaults.string(forKey: MobileTerminalInputPreference.preferenceKey), "compose")

        let second = try connection("second")
        navigation.pushViewController(host(second, preferences: try XCTUnwrap(UserDefaults(suiteName: suiteName))), animated: false)
        settle()
        try toggle("Use direct terminal input")
        XCTAssertEqual(defaults.string(forKey: MobileTerminalInputPreference.preferenceKey), "direct")
        navigation.popViewController(animated: false)
        settle()
        XCTAssertNotNil(element("Compose terminal input", in: window))

        // The same write as Settings must update an already-mounted terminal too.
        defaults.set("compose", forKey: MobileTerminalInputPreference.preferenceKey)
        settle()
        XCTAssertNotNil(element("Use direct terminal input", in: window))
        defaults.set("direct", forKey: MobileTerminalInputPreference.preferenceKey)
        settle()

        let shared = inputControlState(participants: [owner,
            .init(id: "guest", displayName: "Guest", role: .member, isOnline: true)])
        first.receiveServerTextForTesting(String(decoding: try JSONEncoder().encode(shared), as: UTF8.self))
        settle()
        XCTAssertNotNil(element("Compose terminal input is required", in: window))
        XCTAssertEqual(defaults.string(forKey: MobileTerminalInputPreference.preferenceKey), "direct")
        first.receiveServerTextForTesting(String(decoding: try JSONEncoder().encode(
            inputControlState(participants: [owner])
        ), as: UTF8.self))
        settle()
        XCTAssertNotNil(element("Compose terminal input", in: window))
    }

    @MainActor
    func testLegacySessionInputChoicesDoNotPreventDraftRestoration() throws {
        let suiteName = "MobileCollaborationPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileSessionContinuityStore(defaults: defaults)
        store.setDraft("Unsent", surface: .terminal, hostID: "mac", sessionID: "chat")
        let key = "threading.mobile.session-continuity.v1"
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
        var states = try XCTUnwrap(archive["states"] as? [String: [String: Any]])
        let stateKey = try XCTUnwrap(states.keys.first)
        states[stateKey]?["terminalInputPreference"] = "compose"
        archive["states"] = states
        defaults.set(try JSONSerialization.data(withJSONObject: archive), forKey: key)

        let reloaded = MobileSessionContinuityStore(defaults: defaults)
        XCTAssertNil(reloaded.recoveryMessage)
        XCTAssertEqual(reloaded.draft(surface: .terminal, hostID: "mac", sessionID: "chat"), "Unsent")
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
