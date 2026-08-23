import XCTest
import ThreadingDomain
@testable import ThreadingPTYHostKit

/// Every control frame crosses the wire as JSON, so every control frame is round-tripped here.
/// A frame that decodes to something other than what was sent is the failure mode the whole
/// discriminator exists to prevent.
final class PTYHostFrameTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip(_ frame: PTYHostFrame, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try encoder.encode(frame)
        let decoded = try decoder.decode(PTYHostFrame.self, from: data)
        XCTAssertEqual(decoded, frame, file: file, line: line)
    }

    private var identity: PTYHostSessionIdentity {
        PTYHostSessionIdentity.agentSession(SessionID(UUID(uuidString: "6F5B1D0E-2C4A-4F1B-9A77-1D3C5E7F9B11")!))
    }

    private var grid: PTYHostGrid {
        PTYHostGrid(cols: 120, rows: 40, xpixel: 960, ypixel: 640)
    }

    /// One case per frame in the protocol table, so a new frame that forgets its coder fails
    /// here rather than at a customer's socket.
    private var everyFrame: [PTYHostFrame] {
        [
            .hello(PTYHostHello(build: "2026.8.23", pid: 4321)),
            .helloRefused(PTYHostHelloRefusal(compatibility: .peerTooOld, update: .app)),
            .list,
            .sessions([
                PTYHostSessionSummary(
                    id: identity,
                    pid: 900,
                    startedAt: Date(timeIntervalSince1970: 1_770_000_000),
                    executable: "/bin/zsh",
                    grid: grid,
                    isAttached: true,
                    exit: nil
                ),
                PTYHostSessionSummary(
                    id: PTYHostSessionIdentity(.projectTerminal(TerminalID())),
                    pid: 901,
                    startedAt: Date(timeIntervalSince1970: 1_770_000_100),
                    executable: "/bin/zsh",
                    grid: PTYHostGrid(cols: 80, rows: 24),
                    isAttached: false,
                    exit: 130
                )
            ]),
            .spawn(PTYHostSpawnRequest(
                id: identity,
                channel: .pty(grid: grid),
                executable: "/bin/zsh",
                arguments: ["-l", "-c", "claude --session-id x"],
                execName: "-zsh",
                environment: ["TERM=xterm-256color", "PATH=/usr/bin"],
                cwd: "/Users/someone/repo"
            )),
            .spawn(PTYHostSpawnRequest(
                id: identity,
                channel: .pipes,
                executable: "/usr/local/bin/claude",
                arguments: ["--print"],
                execName: nil,
                environment: [],
                cwd: nil
            )),
            .spawned(PTYHostSpawned(
                id: identity,
                pid: 4711,
                startTime: PTYHostProcessStartTime(seconds: 1_770_000_000, microseconds: 123_456)
            )),
            .spawnRefused(PTYHostSpawnRefused(id: identity, reason: .executableUnavailable)),
            .attach(PTYHostAttach(id: identity, replayBudget: 64 * 1024)),
            .attach(PTYHostAttach(id: identity, replayBudget: nil)),
            .attached(PTYHostAttached(
                id: identity,
                pid: 4711,
                grid: grid,
                replay: .exact(fromOffset: 987_654_321),
                totalBytesWritten: 1_000_000_000
            )),
            .attached(PTYHostAttached(id: identity, pid: 1, grid: grid, replay: .cut, totalBytesWritten: 12)),
            .attached(PTYHostAttached(id: identity, pid: 1, grid: grid, replay: .none, totalBytesWritten: 0)),
            .resize(PTYHostResize(id: identity, grid: grid)),
            .detach(PTYHostDetach(
                id: identity,
                screenSeed: Data([0x1B, 0x5B, 0x32, 0x4A]),
                modeSeed: Data([0x18, 0x1B, 0x5B, 0x3F, 0x31, 0x6C]),
                ringOffset: 4096
            )),
            .kill(PTYHostKill(id: identity, escalate: true)),
            .exited(PTYHostExited(id: identity, status: 9, signalled: true)),
            .lost(PTYHostLost(ids: [identity], since: Date(timeIntervalSince1970: 1_770_000_500))),
            .retire,
            .journalTail(PTYHostJournalTail(maxBytes: 32 * 1024)),
            .journal(PTYHostJournal(lines: ["spawned", "exited"])),
            .error(PTYHostErrorFrame(code: .unknownSession, detail: "attach")),
            .error(PTYHostErrorFrame(code: .internalFailure))
        ]
    }

    func testEveryFrameRoundTripsThroughJSON() throws {
        for frame in everyFrame { try roundTrip(frame) }
    }

    /// The set above must actually cover the enum. A new case with no fixture would otherwise
    /// pass this file silently.
    func testTheRoundTripFixtureCoversEveryFrameType() throws {
        var seen = Set<String>()
        for frame in everyFrame {
            let data = try encoder.encode(frame)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            seen.insert(try XCTUnwrap(object["type"] as? String))
        }
        XCTAssertEqual(seen.count, 18, "every frame in the protocol table needs a fixture")
    }

    // MARK: - The discriminator

    func testTheDiscriminatorIsAStableTypeKey() throws {
        let data = try encoder.encode(PTYHostFrame.kill(PTYHostKill(id: identity, escalate: false)))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "kill")
        XCTAssertNotNil(object["body"])
    }

    /// A frame with no fields carries no `body` at all, so adding fields to it later is additive
    /// rather than a reshape.
    func testAFieldlessFrameCarriesOnlyItsType() throws {
        for (frame, token) in [(PTYHostFrame.list, "list"), (PTYHostFrame.retire, "retire")] {
            let data = try encoder.encode(frame)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, token)
            XCTAssertNil(object["body"])
            XCTAssertEqual(object.count, 1)
        }
    }

    /// An unknown frame is a typed refusal, never a default. The `hello` gate is supposed to
    /// catch a newer peer first; if it did not, this is what closes the connection.
    func testAnUnknownFrameTypeIsRefusedWithItsToken() {
        let payload = Data(#"{"type":"teleport","body":{}}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(PTYHostFrame.self, from: payload)) { error in
            XCTAssertEqual(error as? PTYHostFrameRefusal, .unknownFrameType("teleport"))
        }
    }

    func testAFrameMissingItsBodyIsRefusedRatherThanDefaulted() {
        let payload = Data(#"{"type":"kill"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(PTYHostFrame.self, from: payload)) { error in
            XCTAssertEqual(error as? PTYHostFrameRefusal, .missingBody(type: "kill"))
        }
    }

    // MARK: - Value types

    /// `protocol` is the wire spelling and a Swift keyword; the mapping is easy to lose in a
    /// refactor and impossible to notice from Swift alone.
    func testHelloSpellsItsVersionKeyProtocol() throws {
        let data = try encoder.encode(PTYHostFrame.hello(PTYHostHello(build: "b", pid: 7)))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try XCTUnwrap(object["body"] as? [String: Any])
        XCTAssertEqual(body["protocol"] as? Int, PTYHostProtocol.current)
        XCTAssertEqual(body["minimumSupported"] as? Int, PTYHostProtocol.minimumSupported)
        XCTAssertEqual(body["build"] as? String, "b")
    }

    func testEveryTerminalIdentityDomainSurvivesTheWire() throws {
        let sessionID = SessionID()
        let terminalID = TerminalID()
        let ephemeral = UUID()
        let identities: [TerminalInstanceIdentity] = [
            .agentSession(sessionID),
            .projectTerminal(terminalID),
            .sessionShell(sessionID),
            .ephemeral(ephemeral)
        ]
        for value in identities {
            let wrapped = PTYHostSessionIdentity(value)
            let data = try encoder.encode(wrapped)
            XCTAssertEqual(try decoder.decode(PTYHostSessionIdentity.self, from: data).identity, value)
        }
    }

    /// The two domains that both wrap a UUID must not collapse into each other on the wire.
    func testAnAgentSessionAndAShellWithTheSameUUIDStayDistinct() throws {
        let id = SessionID()
        let session = try encoder.encode(PTYHostSessionIdentity(.agentSession(id)))
        let shell = try encoder.encode(PTYHostSessionIdentity(.sessionShell(id)))
        XCTAssertNotEqual(session, shell)
        XCTAssertNotEqual(
            try decoder.decode(PTYHostSessionIdentity.self, from: session),
            try decoder.decode(PTYHostSessionIdentity.self, from: shell)
        )
    }

    func testTheIdentityKindTokensAreTheCaseNames() throws {
        let data = try encoder.encode(PTYHostSessionIdentity(.sessionShell(SessionID())))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "sessionShell")
    }

    func testAMalformedSessionIdentityIsRefused() {
        let payload = Data(#"{"kind":"agentSession","id":"not-a-uuid"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(PTYHostSessionIdentity.self, from: payload)) { error in
            XCTAssertEqual(error as? PTYHostFrameRefusal, .malformedSessionIdentity("not-a-uuid"))
        }
    }

    func testAnUnknownChannelIsRefusedRatherThanTreatedAsPipes() {
        let payload = Data(#"{"mode":"quantum"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(PTYHostChannel.self, from: payload)) { error in
            XCTAssertEqual(error as? PTYHostFrameRefusal, .unknownChannel("quantum"))
        }
    }

    func testAnUnknownReplayModeIsRefusedRatherThanTreatedAsNone() {
        let payload = Data(#"{"mode":"guess"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(PTYHostReplay.self, from: payload)) { error in
            XCTAssertEqual(error as? PTYHostFrameRefusal, .unknownReplay("guess"))
        }
    }

    /// `.pipes` is carried from version 1 precisely so that implementing it later bumps nothing.
    func testThePipesChannelIsAlreadySpeakableAtVersionOne() throws {
        let data = try encoder.encode(PTYHostChannel.pipes)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["mode"] as? String, "pipes")
        XCTAssertNil(object["grid"])
        XCTAssertEqual(try decoder.decode(PTYHostChannel.self, from: data), .pipes)
    }

    // MARK: - Replay budget

    func testAMissingOrNonPositiveBudgetIsNoStatementAtAll() {
        XCTAssertNil(PTYHostAttach.normalizedBudget(nil))
        XCTAssertNil(PTYHostAttach.normalizedBudget(0))
        XCTAssertNil(PTYHostAttach.normalizedBudget(-1))
    }

    func testAStatedBudgetIsClampedRatherThanDiscarded() {
        XCTAssertEqual(PTYHostAttach.normalizedBudget(1), PTYHostReplayDefaults.minimumBudgetBytes)
        XCTAssertEqual(PTYHostAttach.normalizedBudget(64 * 1024), 64 * 1024)
        XCTAssertEqual(
            PTYHostAttach.normalizedBudget(Int.max),
            PTYHostReplayDefaults.ringBufferBytes
        )
    }

    /// The two bounds are restated from `RemoteAccessDefaults` because the daemon cannot link
    /// the app. Pinned so the copies cannot drift silently.
    func testTheReplayBoundsMatchTheRemoteMirrorsOwn() {
        XCTAssertEqual(PTYHostReplayDefaults.minimumBudgetBytes, 16 * 1024)
        XCTAssertEqual(PTYHostReplayDefaults.ringBufferBytes, 512 * 1024)
        XCTAssertEqual(PTYHostFramingDefaults.maximumPayloadBytes, 1 * 1024 * 1024)
    }

    func testTheAttachFrameNormalizesItsOwnBudget() {
        XCTAssertEqual(PTYHostAttach(id: identity, replayBudget: 4).normalizedReplayBudget, 16 * 1024)
        XCTAssertNil(PTYHostAttach(id: identity).normalizedReplayBudget)
    }
}
