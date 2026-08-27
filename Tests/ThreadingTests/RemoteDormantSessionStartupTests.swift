import Network
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// The host-owned handoff from a dormant row to its first live terminal mirror.
@MainActor
final class RemoteDormantSessionStartupTests: HostedStoreTestCase {
    private var connectionDelegates: [DormantStartupConnectionDelegate] = []

    func testWaitingSocketAttachesWhenDormantTerminalProcessStarts() throws {
        let previousRemoteAccess = AppSettings.shared.remoteAccessEnabled
        AppSettings.shared.remoteAccessEnabled = true
        defer { AppSettings.shared.remoteAccessEnabled = previousRemoteAccess }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-dormant-startup-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let storedSession = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            usesNativeUI: false
        ))
        let registry = RemoteSessionMirrorRegistry.shared
        registry.installTerminalApplication(
            LiveRemoteTerminalApplicationCapability(surfaces: AgentRuntime.shared)
        )
        registry.noteSessionStarting(storedSession.id)

        let phone = authenticatedConnection()
        var didAttach = false
        let initial = registry.attachOrWaitForStartup(
            phone,
            to: storedSession.id,
            authorization: Self.ownerInteract,
            authorizationIsCurrent: { true },
            didAttach: { didAttach = true }
        )
        guard case .waitingForStartup = initial else {
            return XCTFail("the dormant startup should hold its already-open socket")
        }
        XCTAssertFalse(didAttach)

        let controller = AgentRuntime.shared.makeController(for: storedSession)
        defer { AgentRuntime.shared.discard(sessionID: storedSession.id) }
        controller.startRemoteTerminalFixture(plan: AgentLaunchPlan(
            executable: "/bin/sleep",
            arguments: ["30"],
            resumeState: .unavailable
        ))

        XCTAssertTrue(controller.isRunning)
        XCTAssertTrue(
            didAttach,
            "the process-start edge must create the mirror and complete the waiting socket"
        )
        XCTAssertTrue(registry.isAttached(phone, to: storedSession.id))
    }

    private static let ownerInteract = RemoteAuthorization(
        shareID: "dormant-startup-owner",
        capability: .interact,
        scope: .allSessions
    )

    private func authenticatedConnection() -> RemoteConnection {
        let delegate = DormantStartupConnectionDelegate()
        connectionDelegates.append(delegate)
        let connection = RemoteConnection(
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            queue: DispatchQueue(label: "remote-dormant-startup-test"),
            delegate: delegate
        )
        XCTAssertTrue(connection.authenticate(
            authorization: Self.ownerInteract,
            deviceID: "dormant-startup-phone",
            deviceName: nil,
            terminalReplayBudget: nil
        ))
        return connection
    }
}

/// The socket never upgrades, so the registry can exercise attachment without network traffic.
private final class DormantStartupConnectionDelegate: RemoteConnection.Delegate,
    @unchecked Sendable {
    func route(
        _ request: HTTPRequest,
        from connection: RemoteConnection,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {}

    func handleMessage(
        _ message: RemoteWebSocket.Message,
        from connection: RemoteConnection
    ) {}

    func didClose(_ connection: RemoteConnection) {}
}
