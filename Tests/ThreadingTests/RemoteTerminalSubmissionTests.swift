import Network
import XCTest

@testable import Threading

/// How a line composed on a phone is pressed into the Mac's PTY.
///
/// The rule under test is one write for the text and another for the Return. Bundled into a
/// single write — which is what this path did — the Return is part of the chunk a TUI's paste
/// heuristic reads as pasted content: Claude Code inserts it as a line break, and the message
/// the phone sent sits unsent in its composer while the phone is told it was accepted.
/// `SessionCoordinator` measured the same thing for the rename request and
/// `SessionMessageDelivery` types the Mac's own cross-session sends this way; this is the
/// remote composer's half of the same rule.
@MainActor
final class RemoteTerminalSubmissionTests: HostedStoreTestCase {

    /// Held for the test's lifetime: `RemoteConnection` keeps its delegate weakly.
    private var connectionDelegates: [SilentSubmissionDelegate] = []

    // MARK: - The Two Writes

    func testASubmittedLineIsTypedWithoutItsReturn() throws {
        let fixture = try makeFixture()
        try attachWatcher(to: fixture)

        let status = fixture.registry.submitTerminalLine(
            "plan for both a and b",
            to: fixture.sessionID,
            device: "phone",
            authorization: Self.ownerInteract,
            requestID: "req-1"
        )

        XCTAssertEqual(status, .accepted)
        XCTAssertEqual(fixture.capability.writes, ["plan for both a and b"])
    }

    func testTheReturnFollowsInAWriteOfItsOwn() async throws {
        let fixture = try makeFixture()
        try attachWatcher(to: fixture)

        _ = fixture.registry.submitTerminalLine(
            "plan for both a and b",
            to: fixture.sessionID,
            device: "phone",
            authorization: Self.ownerInteract,
            requestID: "req-1"
        )

        await wait(until: { fixture.capability.writes.count == 2 })
        XCTAssertEqual(fixture.capability.writes, ["plan for both a and b", "\r"])
        // A zero delay would be two writes in one runloop turn, which the PTY's reader is free
        // to hand the CLI as one chunk — the same bug through a narrower door.
        XCTAssertGreaterThan(TerminalDefaults.submitSequenceDelay, 0)
    }

    // MARK: - Ordering

    func testASecondSubmissionPressesTheFirstReturnBeforeTypingItsOwnText() throws {
        let fixture = try makeFixture()
        try attachWatcher(to: fixture)

        for (index, line) in ["first message", "second message"].enumerated() {
            _ = fixture.registry.submitTerminalLine(
                line,
                to: fixture.sessionID,
                device: "phone",
                authorization: Self.ownerInteract,
                requestID: "req-\(index)"
            )
        }

        // Not "first message", "second message", "\r", "\r" — that is both messages on one
        // composer line, arriving at the agent as a single merged prompt.
        XCTAssertEqual(
            fixture.capability.writes,
            ["first message", "\r", "second message"]
        )
    }

    func testTypingDirectlyPressesAReturnTheSubmittedLineIsStillOwed() throws {
        let fixture = try makeFixture()
        try attachWatcher(to: fixture)

        _ = fixture.registry.submitTerminalLine(
            "first message",
            to: fixture.sessionID,
            device: "phone",
            authorization: Self.ownerInteract,
            requestID: "req-1"
        )
        XCTAssertTrue(fixture.registry.sendInput(
            Array("y".utf8),
            to: fixture.sessionID,
            device: "phone",
            authorization: Self.ownerInteract
        ))

        XCTAssertEqual(fixture.capability.writes, ["first message", "\r", "y"])
    }

    /// The phone's direct-input attachment route used the ordinary typing primitive. The Mac
    /// acknowledged those bytes, but both supported agent TUIs treated them as prompt text rather
    /// than as an attached image. It must be the same bracketed, escaped paste as a local drop,
    /// with no Return because the person still owns the TUI's draft.
    func testTerminalAttachmentInsertionIsAnUnsubmittedPaste() throws {
        let fixture = try makeFixture(bracketedPaste: true)
        try attachWatcher(to: fixture)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            "phone attachment \(UUID().uuidString).png"
        )
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        ))
        try png.write(to: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }

        let status = fixture.registry.insertTerminalAttachments(
            stagedPaths: [source.path],
            into: fixture.sessionID,
            device: "phone",
            authorization: Self.ownerInteract,
            requestID: "attachment-1"
        )

        let storedPath = try XCTUnwrap(
            SessionAttachmentStore.shared.attachments(for: fixture.sessionID).first?.url.path
        )
        XCTAssertEqual(status, .accepted)
        XCTAssertEqual(
            fixture.capability.writes,
            [RemoteTerminalPaste.delimited(
                RemoteTerminalPaste.filePathText(for: [storedPath]),
                bracketedPaste: true
            )]
        )
        XCTAssertFalse(
            try XCTUnwrap(fixture.capability.writes.first).contains("\r"),
            "insertion submitted the draft"
        )
    }

    func testAnOwedReturnIsPressedRatherThanDroppedWhenRemoteAccessStops() throws {
        let fixture = try makeFixture()
        try attachWatcher(to: fixture)

        _ = fixture.registry.submitTerminalLine(
            "first message",
            to: fixture.sessionID,
            device: "phone",
            authorization: Self.ownerInteract,
            requestID: "req-1"
        )
        fixture.registry.remoteAccessStopped()

        XCTAssertEqual(fixture.capability.writes, ["first message", "\r"])
    }

    // MARK: - Refusals

    func testARefusedSubmissionOwesNoReturn() async throws {
        let fixture = try makeFixture()
        try attachWatcher(to: fixture)

        let status = fixture.registry.submitTerminalLine(
            "plan for both a and b",
            to: fixture.sessionID,
            device: "phone",
            authorization: Self.viewOnly,
            requestID: "req-1"
        )

        XCTAssertEqual(status, .rejected)
        try await Task.sleep(for: .seconds(TerminalDefaults.submitSequenceDelay * 2))
        XCTAssertEqual(fixture.capability.writes, [])
    }

    // MARK: - Fixture

    private struct Fixture {
        let capability: SubmissionCapability
        let registry: RemoteSessionMirrorRegistry
        let sessionID: SessionID
    }

    private static let ownerInteract = RemoteAuthorization(
        shareID: "owner-device",
        capability: .interact,
        scope: .allSessions
    )

    private static let viewOnly = RemoteAuthorization(
        shareID: "owner-device-view",
        capability: .view,
        scope: .allSessions
    )

    private func makeFixture(bracketedPaste: Bool = false) throws -> Fixture {
        let store = ProjectStore.shared
        // A folder of its own: `addProject` returns the existing project for a folder it
        // already knows, so a shared temporary directory would hand this test a sibling's.
        let project = try XCTUnwrap(store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-terminal-submit-\(UUID().uuidString)")
        ))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let capability = SubmissionCapability(
            sessionID: session.id,
            bracketedPaste: bracketedPaste
        )
        let registry = RemoteSessionMirrorRegistry(terminalApplication: capability)
        registry.setInputControlFromOwner(.collaborative, sessionID: session.id)
        return Fixture(capability: capability, registry: registry, sessionID: session.id)
    }

    /// A watcher keeps the mirror alive without switching the developer's own Remote Access on,
    /// the way `RemoteViewportLeaseGraceTests` does — and a mirror is what makes this session a
    /// terminal target at all.
    private func attachWatcher(to fixture: Fixture) throws {
        let delegate = SilentSubmissionDelegate()
        connectionDelegates.append(delegate)
        let watcher = RemoteConnection(
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            queue: DispatchQueue(label: "remote-terminal-submit-test"),
            delegate: delegate
        )
        XCTAssertTrue(watcher.authenticate(
            authorization: Self.viewOnly,
            deviceID: "watcher",
            deviceName: nil,
            terminalReplayBudget: nil
        ))
        XCTAssertTrue(fixture.registry.attach(
            watcher,
            to: fixture.sessionID,
            authorization: Self.viewOnly
        ))
    }

    private func wait(
        until condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out waiting for the Return", file: file, line: line)
    }
}

// MARK: - Doubles

/// Records what reached the PTY, as text, in order — which is the whole question here.
@MainActor
private final class SubmissionCapability: RemoteTerminalApplicationCapability {
    private(set) var writes: [String] = []
    let identities: Set<TerminalInstanceIdentity>
    private let bracketedPaste: Bool

    init(sessionID: SessionID, bracketedPaste: Bool) {
        identities = [.agentSession(sessionID)]
        self.bracketedPaste = bracketedPaste
    }

    private var identity: TerminalInstanceIdentity { identities.first! }

    func state(for identity: TerminalInstanceIdentity) -> RemoteTerminalStateResult {
        identity == self.identity ? .available(state) : .unavailable
    }

    func currentSnapshot(for identity: TerminalInstanceIdentity) -> RemoteTerminalCaptureResult {
        identity == self.identity ? .captured(snapshot) : .unavailable
    }

    func beginCapture(
        for identity: TerminalInstanceIdentity,
        output: @escaping RemoteTerminalOutputSink
    ) -> RemoteTerminalCaptureResult {
        identity == self.identity ? .captured(snapshot) : .unavailable
    }

    func endCapture(for identity: TerminalInstanceIdentity) -> RemoteTerminalMutationResult {
        identity == self.identity ? .applied : .unavailable
    }

    func sendInput(
        _ bytes: [UInt8],
        to identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult {
        guard identity == self.identity else { return .unavailable }
        writes.append(String(decoding: bytes, as: UTF8.self))
        return .applied
    }

    func setViewport(
        _ grid: RemoteTerminalGrid?,
        for identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult {
        identity == self.identity ? .applied : .unavailable
    }

    private var state: RemoteTerminalState {
        RemoteTerminalState(
            grid: RemoteTerminalGrid(cols: 120, rows: 40),
            title: "Submission fixture",
            remoteViewport: nil,
            modes: RemoteTerminalModes(
                mouseReporting: nil,
                applicationCursorKeys: false,
                bracketedPaste: bracketedPaste
            )
        )
    }

    private var snapshot: RemoteTerminalSnapshot {
        RemoteTerminalSnapshot(
            grid: RemoteTerminalGrid(cols: 120, rows: 40),
            title: "Submission fixture",
            screenSeed: Data("seed".utf8),
            remoteViewport: nil
        )
    }
}

/// The socket never upgrades, so nothing is routed and nothing is sent.
private final class SilentSubmissionDelegate: RemoteConnection.Delegate, @unchecked Sendable {
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
