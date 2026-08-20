import XCTest
import ThreadingRemoteKit
@testable import Threading

@MainActor
final class RemoteProjectTerminalAccessTests: XCTestCase {
    func testTypedRuntimeDoesNotCollapseChatAndStandaloneTerminalWithSameUUID() {
        let uuid = UUID()
        let sessionID = SessionID(uuid)
        let terminalID = TerminalID(uuid)
        let sessionSurface = Surface(title: "Chat")
        let terminalSurface = Surface(title: "Project terminal")
        let query = Query(surfaces: [
            .agentSession(sessionID): sessionSurface,
            .projectTerminal(terminalID): terminalSurface,
        ])
        let capability = LiveRemoteTerminalApplicationCapability(surfaces: query)

        XCTAssertEqual(capability.sessionIDs, [sessionID])
        XCTAssertEqual(capability.terminalIDs, [terminalID])
        XCTAssertEqual(capability.sendInput([1], to: sessionID), .applied)
        XCTAssertEqual(capability.sendInput([2], to: terminalID), .applied)
        XCTAssertEqual(sessionSurface.inputs, [[1]])
        XCTAssertEqual(terminalSurface.inputs, [[2]])
    }

    func testTerminalAuthorizationIsExactAndCannotGainAIApproval() {
        let uuid = UUID()
        let terminalID = TerminalID(uuid)
        let sameBytesSessionID = SessionID(uuid)
        let authorization = RemoteAuthorization(
            shareID: "terminal-guest",
            capability: .interact,
            scope: .projectTerminal(terminalID),
            principal: .guest,
            canApprovePermissions: true
        )

        XCTAssertTrue(authorization.scope.covers(terminalID))
        XCTAssertFalse(authorization.scope.covers(sameBytesSessionID))
        XCTAssertFalse(authorization.canApprovePermissions)
        XCTAssertFalse(authorization.canManageHost)
        XCTAssertFalse(authorization.canReadHostUsage)
    }

    func testTerminalInvitationRestoresAndRedeemsAsTerminalOnlyMembership() throws {
        let terminalID = TerminalID()
        let invitationToken = String(repeating: "c", count: 43)
        let store = InMemoryRemoteGuestShareStore(shares: [RemoteGuestShareRecord(
            id: "terminal-share",
            targetKind: .projectTerminal,
            sessionID: terminalID.uuidString,
            invitationToken: invitationToken,
            capability: .interact,
            canApprovePermissions: true,
            createdAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            members: []
        )])
        let suiteName = "RemoteProjectTerminalAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.register(defaults: AppSettingDefinitions.registeredDefaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: AppSettings(defaults: defaults),
            guestShareStore: store
        )
        defer { coordinator.stop() }

        XCTAssertTrue(coordinator.hasTerminalShares(terminalID))
        let redemption = try XCTUnwrap(coordinator.redeemInvitation(
            token: invitationToken,
            deviceID: "anna-phone",
            displayName: "Anna",
            persistsOwnerDevice: false
        ))
        XCTAssertEqual(redemption.authorization.scope, .projectTerminal(terminalID))
        XCTAssertFalse(redemption.authorization.canApprovePermissions)
        XCTAssertEqual(store.shares.first?.targetKind, .projectTerminal)
        XCTAssertFalse(store.shares.first?.canApprovePermissions ?? true)
    }

    func testTerminalRoutesAcceptExactlyOneTypedIdentifier() {
        XCTAssertEqual(
            RemoteRouter.resumeTerminalID(forPath: "/api/terminal/terminal-1/resume"),
            "terminal-1"
        )
        XCTAssertEqual(
            RemoteRouter.shareTerminalID(forPath: "/api/terminal/terminal-1/share"),
            "terminal-1"
        )
        XCTAssertEqual(
            RemoteRouter.unshareTerminalID(forPath: "/api/terminal/terminal-1/unshare"),
            "terminal-1"
        )
        XCTAssertEqual(
            RemoteRouter.webSocketTerminalID(forPath: "/ws/terminal/terminal-1"),
            "terminal-1"
        )
        XCTAssertNil(RemoteRouter.resumeTerminalID(forPath: "/api/terminal/a/b/resume"))
        XCTAssertNil(RemoteRouter.webSocketTerminalID(forPath: "/ws/terminal/a/b"))
    }

    private final class Query: RemoteTerminalSurfaceQuerying {
        let surfaces: [TerminalInstanceIdentity: Surface]

        init(surfaces: [TerminalInstanceIdentity: Surface]) {
            self.surfaces = surfaces
        }

        var remoteTerminalIdentities: Set<TerminalInstanceIdentity> {
            Set(surfaces.keys)
        }

        func remoteTerminalSurface(
            for identity: TerminalInstanceIdentity
        ) -> (any RemoteTerminalSurface)? {
            surfaces[identity]
        }
    }

    private final class Surface: RemoteTerminalSurface {
        let title: String
        private(set) var inputs: [[UInt8]] = []
        private var output: RemoteTerminalOutputSink?

        init(title: String) {
            self.title = title
        }

        var isRunning: Bool { true }

        var remoteTerminalState: RemoteTerminalState {
            .init(grid: .init(cols: 80, rows: 24), title: title, remoteViewport: nil)
        }

        var remoteTerminalSnapshot: RemoteTerminalSnapshot {
            .init(
                grid: .init(cols: 80, rows: 24),
                title: title,
                screenSeed: Data(),
                remoteViewport: nil
            )
        }

        func setRemoteOutputSink(_ sink: RemoteTerminalOutputSink?) {
            output = sink
        }

        func sendRemoteInput(_ bytes: [UInt8]) {
            inputs.append(bytes)
        }

        func setRemoteViewport(_: RemoteTerminalGrid?) {}
    }
}
