import XCTest
import os

@testable import Threading

/// The second endpoint: a unix socket at a path that does not change between launches.
///
/// It exists because a loopback port is minted per launch, so everything addressed by one — a
/// hook command, a `hooks.json` Codex trusts by its text — was addressed to a single run of the
/// app. These tests drive it the way the hooks do, through `curl --unix-socket`, because that is
/// the thing that has to work rather than an approximation of it.
final class MCPSocketListenerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("thr-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    override func tearDownWithError() throws {
        // The servers are stopped by each test's own `defer`, on the main actor `stop()`
        // requires. Only the directory is left to sweep here.
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Short on purpose: `sun_path` is 104 bytes and the temporary directory already spends
    /// nearly half of them.
    private var socketPath: String {
        directory.appendingPathComponent(MCPBridgeDefaults.socketFileName).path
    }

    @MainActor
    private func startedServer(at path: String) -> MCPServer {
        let server = MCPServer(socketPath: path)

        let started = expectation(description: "the loopback listener settled")
        server.start { started.fulfill() }
        wait(for: [started], timeout: 10)
        return server
    }

    /// Waits for the rendezvous to bind, or gives up and lets the assertion say so.
    private func waitForRendezvous(_ server: MCPServer) {
        let ready = expectation(description: "the rendezvous settled")
        DispatchQueue.global().async {
            for _ in 0..<500 {
                if server.socketPath != nil { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 15)
    }

    private struct Reply: Sendable {
        let status: Int
        let body: String
    }

    /// One POST over the socket, exactly as a hook makes it.
    ///
    /// Runs off the main queue and is joined through an expectation, because the server answers
    /// `tools/list` and `initialize` by hopping to main — a test blocking there would deadlock
    /// against the very code it is exercising.
    private func post(_ path: String, json: String, over socket: String) -> Reply? {
        let answered = expectation(description: "the endpoint answered \(path)")
        let outcome = OSAllocatedUnfairLock<Reply?>(initialState: nil)

        DispatchQueue.global().async {
            let reply = Self.curl(path, json: json, over: socket)
            outcome.withLock { $0 = reply }
            answered.fulfill()
        }

        wait(for: [answered], timeout: 30)
        return outcome.withLock { $0 }
    }

    private static func curl(_ path: String, json: String, over socket: String) -> Reply? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("thr-reply-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-s",
            "--unix-socket", socket,
            "-H", "Content-Type: application/json",
            "--data-binary", json,
            "-o", output.path,
            "-w", "%{http_code}",
            "\(MCPDefaults.socketURLBase)\(path)"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        let statusData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let status = Int(
            String(decoding: statusData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            return nil
        }

        let body = (try? Data(contentsOf: output)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Reply(status: status, body: body)
    }

    // MARK: - Routing

    /// A request over the rendezvous is attributed by its token exactly as one over the port is.
    ///
    /// Asserted through a scoped endpoint rather than a bare `ping`, because a `ping` proves the
    /// socket carries HTTP and nothing about *which session* answered. A scope is visible in the
    /// answer: the endpoint is advertised its one tool and nothing of the session surface.
    @MainActor
    func testAValidTokenReachesItsOwnSessionOverTheRendezvous() throws {
        let server = startedServer(at: socketPath)
        defer { server.stop() }
        waitForRendezvous(server)
        XCTAssertEqual(server.socketPath, socketPath, "the rendezvous never bound")

        let scoped = MCPSessionRegistry.beginAdHoc(
            allowedTools: [MCPBuiltInTool.listSettings.rawValue]
        )
        defer { MCPSessionRegistry.endAdHoc(scoped) }
        let token = MCPSessionRegistry.token(for: scoped)

        let reply = try XCTUnwrap(post(
            "\(MCPDefaults.pathPrefix)\(token)",
            json: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            over: socketPath
        ))

        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(
            reply.body.contains(MCPBuiltInTool.listSettings.rawValue),
            "the scoped endpoint's own tool did not come back: \(reply.body)"
        )
        XCTAssertFalse(
            reply.body.contains(MCPBuiltInTool.displayImage.rawValue),
            "the request was answered for some session other than the one it named"
        )
    }

    /// Fail loudly rather than quietly. A token nothing recognises is refused with the same
    /// status the loopback endpoint refuses it with — not accepted and dropped.
    @MainActor
    func testAnUnknownTokenIsRefusedOnBothTokenBearingPaths() throws {
        let server = startedServer(at: socketPath)
        defer { server.stop() }
        waitForRendezvous(server)
        XCTAssertNotNil(server.socketPath)

        let stale = UUID().uuidString.lowercased()

        let tools = try XCTUnwrap(post(
            "\(MCPDefaults.pathPrefix)\(stale)",
            json: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            over: socketPath
        ))
        XCTAssertEqual(tools.status, 404)

        let permission = try XCTUnwrap(post(
            "\(MCPDefaults.permissionPathPrefix)\(stale)",
            json: #"{"tool_name":"Bash","tool_input":{}}"#,
            over: socketPath
        ))
        XCTAssertEqual(permission.status, 404)
    }

    /// A lifecycle report over the rendezvous is accepted and its session identified. The
    /// endpoint answers `202` either way by design — a report is told and forgotten — so the
    /// refusal above is asserted on the two paths that do have a status to give.
    @MainActor
    func testALifecycleReportPostsOverTheRendezvous() throws {
        let server = startedServer(at: socketPath)
        defer { server.stop() }
        waitForRendezvous(server)
        XCTAssertNotNil(server.socketPath)

        let sessionID = SessionID()
        let token = MCPSessionRegistry.token(for: sessionID)
        defer { MCPSessionRegistry.remove(sessionID: sessionID) }

        let reply = try XCTUnwrap(post(
            "\(MCPDefaults.lifecyclePathPrefix)\(token)"
                + "?\(MCPDefaults.lifecycleEventParameter)="
                + HookLifecycleEvent.sessionStarted.rawValue,
            json: #"{"session_id":"abc","hook_event_name":"SessionStart"}"#,
            over: socketPath
        ))

        XCTAssertEqual(reply.status, 202)
    }

    // MARK: - Binding

    /// A crash never reaches `stop`, so there is always a leftover file to bind past.
    @MainActor
    func testAStaleSocketFileIsUnlinkedRatherThanRefused() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: socketPath))

        let server = startedServer(at: socketPath)
        defer { server.stop() }
        waitForRendezvous(server)

        XCTAssertEqual(server.socketPath, socketPath, "a leftover file blocked the rendezvous")
    }

    /// The `0700` directory is the whole security claim of the second endpoint: a loopback port
    /// is reachable by any local process that guesses a token, and this is not.
    @MainActor
    func testTheRendezvousDirectoryIsOwnerOnly() throws {
        let server = startedServer(at: socketPath)
        defer { server.stop() }
        waitForRendezvous(server)
        XCTAssertNotNil(server.socketPath)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(mode.intValue, MCPBridgeDefaults.directoryPermissions)
    }

    /// Stopping takes the file with it, so nothing is left addressing a listener that is gone.
    @MainActor
    func testStoppingRemovesTheSocketFile() throws {
        let server = startedServer(at: socketPath)
        defer { server.stop() }
        waitForRendezvous(server)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        server.stop()

        XCTAssertNil(server.socketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    // MARK: - Degradation

    /// A home directory long enough to overflow `sun_path` costs the socket and nothing else.
    ///
    /// `sockaddr_un.sun_path` is 104 bytes with the path NUL-terminated inside it, so a path of
    /// 104 characters cannot be bound. The listener is skipped, the loopback one still comes up,
    /// and every hook keeps working through it — an app broken by a long user name would be a
    /// worse bug than the one the rendezvous exists to fix.
    @MainActor
    func testATooLongPathSkipsTheRendezvousWithoutCostingTheLoopbackListener() throws {
        let overlong = "/tmp/" + String(
            repeating: "x",
            count: MCPBridgeDefaults.maximumSocketPathBytes
        ) + "/mcp.sock"
        XCTAssertNil(MCPBridgeLocation.addressableSocketPath(overlong))

        let atTheLimit = "/tmp/" + String(
            repeating: "x",
            count: MCPBridgeDefaults.maximumSocketPathBytes - "/tmp/".count
        )
        XCTAssertEqual(MCPBridgeLocation.addressableSocketPath(atTheLimit), atTheLimit)

        let server = startedServer(at: overlong)
        defer { server.stop() }
        XCTAssertNotNil(server.port, "the loopback listener was taken down with the rendezvous")

        // Nothing is pending: the path is refused before a listener is ever constructed, so a
        // short settle is enough to prove it never arrives.
        let settled = expectation(description: "no rendezvous appeared")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertNil(server.socketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlong))
    }

    /// The path a hook is written against answers before any listener binds it — which is what
    /// let `writeHookSettings` delete its "no port, no hooks" branch.
    func testTheRendezvousPathIsKnowableWithNoServerRunning() {
        let path = MCPBridgeLocation.socketPath
        XCTAssertTrue(path.hasSuffix("/\(MCPBridgeDefaults.socketFileName)"))
        XCTAssertEqual(
            URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
            MCPBridgeDefaults.directoryName
        )
        XCTAssertEqual(path, MCPBridgeLocation.socketPath, "the rendezvous moved between calls")
    }

    /// A path with a space in it — every real one has, since it lives under
    /// `Application Support` — has to survive being pasted into a hook command.
    func testTheRendezvousIsQuotedAsOneShellWord() {
        XCTAssertEqual(
            MCPBridgeLocation.shellQuoted("/a/Application Support/mcp.sock"),
            "'/a/Application Support/mcp.sock'"
        )
        XCTAssertEqual(
            MCPBridgeLocation.shellQuoted("/a/it's/mcp.sock"),
            #"'/a/it'\''s/mcp.sock'"#
        )
    }
}
