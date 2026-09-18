import Network
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// Why a phone's terminal hydration ended, as `terminalHydrationEnded` records it.
///
/// The reason is what makes the hold tunable: a program that never stops drawing meets the
/// ceiling, one that does not repaint after a resize meets the first-output timeout, and each
/// wants a different change. Every case here drives the real registry through its public socket
/// operations with a fake terminal, so the reason asserted is the one the app would journal.
@MainActor
final class RemoteTerminalHydrationDiagnosticsTests: HostedStoreTestCase {
    private var connectionDelegates: [HydrationSilentDelegate] = []

    func testAnUnchangedGridEndsAtOnceWithNothingToWaitFor() throws {
        let fixture = try makeFixture()
        let phone = try attachedPhone(to: fixture)
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 60,
            rows: 20
        )
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 60,
            rows: 20,
            hydrationRequestID: "same-grid"
        )

        XCTAssertEqual(fixture.ends.values, [.noResize])
    }

    func testAProgramThatDrawsNothingAfterTheResizeEndsAtTheFirstOutputTimeout() async throws {
        let fixture = try makeFixture()
        let phone = try attachedPhone(to: fixture)
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 60,
            rows: 20,
            hydrationRequestID: "silent"
        )

        await wait { fixture.ends.values == [.firstOutputTimeout] }
    }

    func testARepaintThatSettlesEndsOnQuiet() async throws {
        let fixture = try makeFixture()
        let phone = try attachedPhone(to: fixture)
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 60,
            rows: 20,
            hydrationRequestID: "repaint"
        )
        fixture.capability.emit(Data("repaint".utf8), to: fixture.sessionID)

        await wait { fixture.ends.values == [.quiet] }
    }

    /// The Codex shape: output that never pauses long enough to count as quiet. It is revealed
    /// once the settle window after its first output ends, not at the ceiling.
    func testOutputThatNeverGoesQuietEndsWhenTheSettleWindowCloses() async throws {
        let fixture = try makeFixture()
        let phone = try attachedPhone(to: fixture)
        let requestedAt = ContinuousClock.now
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 60,
            rows: 20,
            hydrationRequestID: "animated"
        )

        let drawing = Task { @MainActor in
            while !Task.isCancelled {
                fixture.capability.emit(Data("frame".utf8), to: fixture.sessionID)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { drawing.cancel() }

        await wait { !fixture.ends.values.isEmpty }
        XCTAssertEqual(fixture.ends.values, [.continuousOutput])
        XCTAssertLessThan(
            ContinuousClock.now - requestedAt,
            Fixture.ceiling,
            "an animating program must not sit out the ceiling"
        )
    }

    /// The ceiling still bounds everything: with a settle window configured longer than it, the
    /// ceiling is what ends the hold.
    func testOutputThatNeverGoesQuietEndsAtTheCeilingWhenThatComesFirst() async throws {
        let fixture = try makeFixture(settle: .seconds(2))
        let phone = try attachedPhone(to: fixture)
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 60,
            rows: 20,
            hydrationRequestID: "animated-past-settle"
        )

        let drawing = Task { @MainActor in
            while !Task.isCancelled {
                fixture.capability.emit(Data("frame".utf8), to: fixture.sessionID)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { drawing.cancel() }

        await wait { !fixture.ends.values.isEmpty }
        XCTAssertEqual(fixture.ends.values, [.ceiling])
    }

    func testASocketThatLeavesDuringTheHoldIsRecordedAsCancelled() throws {
        let fixture = try makeFixture()
        let phone = try attachedPhone(to: fixture)
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 60,
            rows: 20,
            hydrationRequestID: "left"
        )
        fixture.registry.detach(phone)

        XCTAssertEqual(fixture.ends.values, [.cancelled])
    }

    // MARK: - Fixture

    private final class Ends {
        var values: [RemoteTerminalHydrationEnd] = []
    }

    private struct Fixture {
        static let ceiling: Duration = .milliseconds(250)

        let capability: HydrationCapability
        let registry: RemoteSessionMirrorRegistry
        let sessionID: SessionID
        let ends: Ends
    }

    private static let owner = RemoteAuthorization(
        shareID: "owner-device",
        capability: .interact,
        scope: .allSessions
    )

    /// Short, well-separated delays: quiet 40 ms, first output 80 ms, settle 120 ms, ceiling
    /// 250 ms. The animated cases emit every 10 ms, well inside the quiet window.
    private func makeFixture(settle: Duration = .milliseconds(120)) throws -> Fixture {
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-hydration-\(UUID().uuidString)")
        ))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .codex))
        let capability = HydrationCapability(sessionID: session.id)
        let ends = Ends()
        let registry = RemoteSessionMirrorRegistry(
            terminalApplication: capability,
            terminalHydrationOutputQuietDelay: .milliseconds(40),
            terminalHydrationFirstOutputMaximumDelay: .milliseconds(80),
            terminalHydrationOutputSettleDelay: settle,
            terminalHydrationMaximumDelay: Fixture.ceiling,
            terminalHydrationDidEnd: { ends.values.append($0) }
        )
        registry.setInputControlFromOwner(.collaborative, sessionID: session.id)
        return Fixture(capability: capability, registry: registry, sessionID: session.id, ends: ends)
    }

    /// A phone that stays attached, beside a watcher that keeps the mirror alive when the phone
    /// itself leaves.
    private func attachedPhone(to fixture: Fixture) throws -> RemoteConnection {
        let watcher = authenticated(deviceID: "watcher")
        XCTAssertTrue(fixture.registry.attach(
            watcher,
            to: fixture.sessionID,
            authorization: Self.owner
        ))
        let phone = authenticated(deviceID: "phone")
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: Self.owner
        ))
        return phone
    }

    private func authenticated(deviceID: String) -> RemoteConnection {
        let delegate = HydrationSilentDelegate()
        connectionDelegates.append(delegate)
        let connection = RemoteConnection(
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            queue: DispatchQueue(label: "remote-hydration-diagnostics-test"),
            delegate: delegate
        )
        XCTAssertTrue(connection.authenticate(
            authorization: Self.owner,
            deviceID: deviceID,
            deviceName: nil,
            terminalReplayBudget: nil
        ))
        return connection
    }

    private func wait(
        until condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "the hydration never ended", file: file, line: line)
    }
}

// MARK: - Doubles

/// A session terminal whose applied viewport is what was last set on it, and whose output can
/// be emitted on demand through the sink the registry installed.
@MainActor
private final class HydrationCapability: RemoteTerminalApplicationCapability {
    private var appliedViewport: RemoteTerminalGrid?
    private var output: RemoteTerminalOutputSink?
    let identities: Set<TerminalInstanceIdentity>

    init(sessionID: SessionID) {
        identities = [.agentSession(sessionID)]
    }

    func emit(_ data: Data, to sessionID: SessionID) {
        output?(data)
    }

    func state(for identity: TerminalInstanceIdentity) -> RemoteTerminalStateResult {
        guard identities.contains(identity) else { return .unavailable }
        return .available(RemoteTerminalState(
            grid: Self.macGrid,
            title: "Hydration fixture",
            remoteViewport: appliedViewport
        ))
    }

    func currentSnapshot(
        for identity: TerminalInstanceIdentity
    ) -> RemoteTerminalCaptureResult {
        guard identities.contains(identity) else { return .unavailable }
        return .captured(snapshot)
    }

    func beginCapture(
        for identity: TerminalInstanceIdentity,
        output: @escaping RemoteTerminalOutputSink
    ) -> RemoteTerminalCaptureResult {
        guard identities.contains(identity) else { return .unavailable }
        self.output = output
        return .captured(snapshot)
    }

    func endCapture(for identity: TerminalInstanceIdentity) -> RemoteTerminalMutationResult {
        output = nil
        return identities.contains(identity) ? .applied : .unavailable
    }

    func sendInput(
        _ bytes: [UInt8],
        to identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult {
        identities.contains(identity) ? .applied : .unavailable
    }

    func setViewport(
        _ grid: RemoteTerminalGrid?,
        for identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult {
        guard identities.contains(identity) else { return .unavailable }
        appliedViewport = grid
        return .applied
    }

    private static let macGrid = RemoteTerminalGrid(cols: 120, rows: 40)

    private var snapshot: RemoteTerminalSnapshot {
        RemoteTerminalSnapshot(
            grid: Self.macGrid,
            title: "Hydration fixture",
            screenSeed: Data("seed".utf8),
            remoteViewport: appliedViewport
        )
    }
}

/// The socket never upgrades, so nothing is routed and nothing is sent.
private final class HydrationSilentDelegate: RemoteConnection.Delegate, @unchecked Sendable {
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
