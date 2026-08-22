import Foundation
import XCTest
import os

@testable import Threading

/// The wiring itself: the launch files the app writes, and what happens when a CLI does exactly
/// what one of them says.
///
/// `MCPBridgeTests` proves the helper against a fake app, and `MCPSocketListenerTests` proves the
/// rendezvous against `curl`. Neither asks the question this file exists for, which is whether
/// **the app's own configuration** produces a working tool channel: the end-to-end test starts a
/// real `MCPServer`, writes the real `--mcp-config`, spawns whatever that file names, and asserts
/// the tools that come back are the session's own catalogue as the app would have served it.
///
/// Everything else here is the fallback contract. The bridge is opt-in for the length of rollout
/// step 2 of `docs/feature-drafts/durable-sessions.md`, so three separate conditions each have to
/// leave the launch on HTTP rather than half-way between the two.
final class MCPBridgeLaunchIntegrationTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        /// Generous: each bounds a process launch plus a socket round trip, and every assertion
        /// here is about *whether* something happens rather than how quickly.
        static let replyTimeout: TimeInterval = 20
        /// Longer, because the bridge's own reconnect backoff is in the path.
        static let reconnectTimeout: TimeInterval = 30
        static let sweepTimeout: TimeInterval = 10
        static let listenerTimeout: TimeInterval = 15

        static let protocolVersion = "2025-03-26"

        /// The second-hop measurement's sample count. Large enough for a stable median and a
        /// meaningful p95, small enough that the opt-in run is over in seconds.
        static let hopSamples = 200
        static let hopStressKey = "THREADING_MCP_BRIDGE_HOP_STRESS"
    }

    // MARK: - Fixture state

    private var directory: URL!
    private var spawned: [SpawnedBridge] = []
    private var sessionIDs: [SessionID] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `sockaddr_un.sun_path` holds 104 bytes and the system temporary directory already
        // spends nearly half of them, so the fixture's own names stay short.
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tbl-\(UInt32.random(in: 0..<0xFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @MainActor
    override func tearDown() {
        for bridge in spawned { bridge.terminate() }
        spawned.removeAll()
        for sessionID in sessionIDs { MCPSessionRegistry.remove(sessionID: sessionID) }
        sessionIDs.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    // MARK: - End to end

    /// A CLI handed the written `--mcp-config` spawns the helper it names and lists this
    /// session's real tools.
    ///
    /// Nothing is stubbed on either side: the server is the app's, the catalogue is the app's,
    /// the helper is the one in `Contents/Helpers`, and the command line comes out of the file
    /// rather than out of this test. That is the whole claim of rollout step 2 — that a session
    /// configured this way is as capable as one configured with a URL.
    @MainActor
    func testAToolChannelBuiltFromTheWrittenConfigurationServesTheSessionsOwnCatalogue() throws {
        let helper = try helperURL()
        let server = try startedServer()
        defer { server.stop() }

        let sessionID = registeredSession()
        let expectedTools = MCPToolCatalog.definitions(for: sessionID).map(\.name)
        XCTAssertFalse(expectedTools.isEmpty, "the session has no catalogue to compare against")

        let bridge = try spawnBridgeFromWrittenConfiguration(
            for: sessionID,
            helper: helper,
            socketPath: rendezvousPath
        )

        let handshake = try roundTrip(bridge, request: Self.initialize(id: 1), id: 1)
        XCTAssertEqual(
            Self.string(handshake, "result", "serverInfo", "name"),
            MCPDefaults.serverName
        )

        let listing = try roundTrip(bridge, request: Self.toolsList(id: 2), id: 2)
        let tools = try XCTUnwrap(
            (listing["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        )
        XCTAssertEqual(
            tools.compactMap { $0["name"] as? String },
            expectedTools,
            "the bridge served something other than what the app would have served"
        )
    }

    /// With the app gone the same bridge refuses a tool call as a *result*, and picks the app
    /// back up when it returns.
    ///
    /// Both halves are asserted through the app's own listener rather than a fake, because both
    /// are claims about this pairing: the refusal is what the model reads instead of a hang, and
    /// the re-announcement is what makes a client that listed an empty catalogue during the
    /// outage list the real one afterwards.
    @MainActor
    func testTheChannelRefusesWhileThreadingIsGoneAndRecoversWhenItComesBack() throws {
        let helper = try helperURL()
        let server = try startedServer()

        let sessionID = registeredSession()
        let bridge = try spawnBridgeFromWrittenConfiguration(
            for: sessionID,
            helper: helper,
            socketPath: rendezvousPath
        )

        _ = try roundTrip(bridge, request: Self.initialize(id: 1), id: 1)
        _ = try roundTrip(bridge, request: Self.toolsList(id: 2), id: 2)

        server.stop()

        let refusal = try roundTrip(bridge, request: Self.toolCall(id: 3), id: 3)
        XCTAssertNil(
            refusal["error"],
            "a refusal is a result, not a transport error — a transport error never reaches the "
                + "model, and the model is who has to read it and move on"
        )
        let result = try XCTUnwrap(refusal["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)

        let recovered = try startedServer()
        defer { recovered.stop() }

        let announcement = try awaitOffMain(
            "the bridge re-announced the tool list",
            timeout: Fixture.reconnectTimeout
        ) {
            WireLine(object: try bridge.line(
                where: { $0["method"] as? String == Self.listChangedMethod },
                timeout: Fixture.reconnectTimeout
            ))
        }
        XCTAssertEqual(
            announcement.object["method"] as? String,
            Self.listChangedMethod
        )
    }

    // MARK: - Which form a launch gets

    /// The stdio form needs no port. That independence is the point of the shim: a session can
    /// be configured before the listener is up, or while the app is closed, and still hold a
    /// working tool channel — where the HTTP form has nothing to write down at all.
    @MainActor
    func testTheStdioConfigurationIsWrittenWithNoTCPPortAvailable() throws {
        let helper = try helperURL()
        let sessionID = registeredSession()
        try XCTSkipUnless(
            MCPServer.shared.port == nil,
            "the shared listener is up in this process, so 'no port' cannot be observed"
        )
        XCTAssertNil(MCPSessionRegistry.endpointURL(for: sessionID, port: nil))

        let path = try XCTUnwrap(MCPSessionRegistry.writeConfiguration(
            for: sessionID,
            decision: decision(helper: helper, socketPath: rendezvousPath)
        ))
        let server = try Self.claudeServerObject(atConfigurationPath: path)

        XCTAssertEqual(server["type"] as? String, "stdio")
        XCTAssertEqual(server["command"] as? String, helper.path)
        XCTAssertNil(server["url"], "the stdio form names a helper, never also an address")

        // All three flags, in the order the helper's usage line states them. It exits 64 without
        // any one of them, because every path on that line is the app's decision.
        let arguments = try XCTUnwrap(server["args"] as? [String])
        XCTAssertEqual(arguments.count, 6, "unexpected bridge command line: \(arguments)")
        XCTAssertEqual(arguments.first, MCPBridgeDefaults.socketArgument)
        XCTAssertEqual(
            Self.value(after: MCPBridgeDefaults.socketArgument, in: arguments),
            rendezvousPath
        )
        XCTAssertEqual(
            Self.value(after: MCPBridgeDefaults.tokenArgument, in: arguments),
            MCPSessionRegistry.token(for: sessionID)
        )
        XCTAssertEqual(
            Self.value(after: MCPBridgeDefaults.cacheArgument, in: arguments)
                .map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent },
            MCPDefaults.bridgeCacheDirectoryName
        )
    }

    /// Off is the shipped state, and it has to be indistinguishable from the app before the
    /// bridge existed: no invocation, and `writeConfiguration` nil when there is no port.
    @MainActor
    func testTheSettingLeftOffKeepsTodaysHTTPForm() throws {
        let helper = try helperURL()
        let sessionID = registeredSession()
        let off = MCPBridgeDecision(
            isEnabled: false,
            helperURL: helper,
            socketPath: rendezvousPath
        )

        XCTAssertNil(MCPSessionRegistry.bridgeInvocation(for: sessionID, decision: off))
        try XCTSkipUnless(
            MCPServer.shared.port == nil,
            "the shared listener is up in this process, so the no-port fallback is unobservable"
        )
        XCTAssertNil(MCPSessionRegistry.binding(for: sessionID, decision: off))
        XCTAssertNil(MCPSessionRegistry.writeConfiguration(for: sessionID, decision: off))
    }

    /// A `command` naming a file that will not run produces a CLI reporting a broken MCP server,
    /// which is worse than the port. The setting being on is not enough on its own.
    @MainActor
    func testASettingOnWithNoHelperInTheBundleFallsBackToHTTP() {
        let sessionID = registeredSession()
        let missing = directory.appendingPathComponent(MCPBridgeDefaults.helperName)

        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: missing.path))
        XCTAssertNil(MCPSessionRegistry.bridgeInvocation(
            for: sessionID,
            decision: decision(helper: missing, socketPath: rendezvousPath)
        ))
    }

    /// A socket that can never bind is a bridge that can never connect. A home directory long
    /// enough to overflow `sun_path` must cost the *bridge* and nothing else — shipping a tool
    /// channel that refuses every call for the life of the session would be a worse bug than the
    /// one the whole rendezvous exists to fix.
    @MainActor
    func testASocketPathTooLongToBindFallsBackToHTTP() throws {
        let helper = try helperURL()
        let sessionID = registeredSession()
        let overlong = "/tmp/" + String(
            repeating: "x",
            count: MCPBridgeDefaults.maximumSocketPathBytes
        ) + "/\(MCPBridgeDefaults.socketFileName)"
        XCTAssertNil(MCPBridgeLocation.addressableSocketPath(overlong))

        XCTAssertNil(MCPSessionRegistry.bridgeInvocation(
            for: sessionID,
            decision: MCPBridgeDecision(
                isEnabled: true,
                helperURL: helper,
                socketPath: MCPBridgeLocation.addressableSocketPath(overlong)
            )
        ))
    }

    // MARK: - The per-session cache

    /// The catalogue cache is a per-session file, so it goes when the session does.
    ///
    /// Asserted on the path the *invocation* names rather than on a path this test computes, so
    /// a cache written somewhere the sweep does not reach would fail here rather than accumulate
    /// one file per deleted session forever.
    @MainActor
    func testTheCatalogueCacheIsSweptWithTheSession() throws {
        let helper = try helperURL()
        XCTAssertTrue(
            MCPDefaults.cleanupDirectories.contains(MCPDefaults.bridgeCacheDirectoryName),
            "a directory absent from the sweep is a directory that grows without bound"
        )

        let sessionID = SessionID()
        let invocation = try XCTUnwrap(MCPSessionRegistry.bridgeInvocation(
            for: sessionID,
            decision: decision(helper: helper, socketPath: rendezvousPath)
        ))
        let cachePath = try XCTUnwrap(
            Self.value(after: MCPBridgeDefaults.cacheArgument, in: invocation.arguments)
        )
        let cache = URL(fileURLWithPath: cachePath)

        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"toolsListResult":{}}"#.utf8).write(to: cache)

        MCPSessionRegistry.remove(sessionID: sessionID)

        // Removal is detached so revocation never waits on the filesystem; the assertion is that
        // it lands, not that it lands synchronously.
        let deadline = Date().addingTimeInterval(Fixture.sweepTimeout)
        while Date() < deadline, FileManager.default.fileExists(atPath: cache.path) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cache.path),
            "the session's catalogue cache outlived the session"
        )
    }

    // MARK: - The three rendered forms

    /// Claude's `mcpServers` entry, both ways round. The two are alternatives: whichever address
    /// this session has, the other key is absent rather than empty.
    func testTheClaudeServerObjectCarriesOneAddressOrTheOther() {
        let http = MCPServerBinding.http(url: "http://127.0.0.1:9/mcp/t").claudeServerObject
        XCTAssertEqual(http["type"] as? String, "http")
        XCTAssertEqual(http["url"] as? String, "http://127.0.0.1:9/mcp/t")
        XCTAssertNil(http["command"])

        let stdio = MCPServerBinding.stdio(Self.sampleInvocation).claudeServerObject
        XCTAssertEqual(stdio["type"] as? String, "stdio")
        XCTAssertEqual(stdio["command"] as? String, Self.sampleInvocation.command)
        XCTAssertEqual(stdio["args"] as? [String], Self.sampleInvocation.arguments)
        XCTAssertNil(stdio["url"])
    }

    /// ACP's `McpServer` union tags only the extra transports. The stdio variant is the
    /// unconditional baseline and is required to be exactly `name`, `command`, `args` and `env`
    /// — a `type` here would be a member the schema does not define.
    func testTheACPServerObjectUsesTheUntaggedStdioBaseline() {
        let name = MCPDefaults.serverName

        let http = MCPServerBinding.http(url: "http://127.0.0.1:9/mcp/t")
            .acpServerObject(named: name)
        XCTAssertEqual(Set(http.keys), ["type", "name", "url", "headers"])
        XCTAssertEqual(http["type"] as? String, "http")
        XCTAssertEqual(http["name"] as? String, name)

        let stdio = MCPServerBinding.stdio(Self.sampleInvocation).acpServerObject(named: name)
        XCTAssertEqual(Set(stdio.keys), ["name", "command", "args", "env"])
        XCTAssertEqual(stdio["name"] as? String, name)
        XCTAssertEqual(stdio["command"] as? String, Self.sampleInvocation.command)
        XCTAssertEqual(stdio["args"] as? [String], Self.sampleInvocation.arguments)
        XCTAssertEqual((stdio["env"] as? [Any])?.isEmpty, true)
    }

    // MARK: - The second hop

    /// The claim the draft asks the rollout to check rather than assume: that the bridge's extra
    /// local hop is not measurable against a call that already crosses into the app and back.
    ///
    /// Opt-in because it spawns a process and drives 200 round trips twice; the numbers it
    /// prints are recorded in `docs/architecture/performance.md`. Both halves ask the *same*
    /// server for the *same* session's `tools/list`, one over the loopback port with
    /// `URLSession` and one through the spawned bridge over the socket, so the difference
    /// between them is the hop and nothing else.
    @MainActor
    func testStressTheBridgeHopAgainstTheDirectPortWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment[Fixture.hopStressKey] == "1" else {
            throw XCTSkip("Set \(Fixture.hopStressKey)=1 to measure the bridge's second hop.")
        }

        let helper = try helperURL()
        let server = try startedServer()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)

        let sessionID = registeredSession()
        let token = MCPSessionRegistry.token(for: sessionID)
        let endpoint = try XCTUnwrap(
            URL(string: "http://\(MCPDefaults.host):\(port)\(MCPDefaults.pathPrefix)\(token)")
        )

        let direct = try awaitOffMain("direct samples", timeout: 600) {
            try Self.samplesOverHTTP(
                endpoint: endpoint,
                count: Fixture.hopSamples,
                reusesConnection: true
            )
        }
        let directFresh = try awaitOffMain("direct fresh-connection samples", timeout: 600) {
            try Self.samplesOverHTTP(
                endpoint: endpoint,
                count: Fixture.hopSamples,
                reusesConnection: false
            )
        }

        let bridge = try spawnBridgeFromWrittenConfiguration(
            for: sessionID,
            helper: helper,
            socketPath: rendezvousPath
        )
        _ = try roundTrip(bridge, request: Self.initialize(id: 1), id: 1)

        let hopped = try awaitOffMain("bridge samples", timeout: 600) {
            try bridge.samples(
                method: "tools/list",
                count: Fixture.hopSamples,
                timeout: Fixture.replyTimeout
            )
        }

        let rendezvous = rendezvousPath
        let socketDirect = try awaitOffMain("rendezvous samples", timeout: 600) {
            try Self.samplesOverUnixSocket(
                path: rendezvous,
                requestPath: "\(MCPDefaults.pathPrefix)\(token)",
                count: Fixture.hopSamples
            )
        }

        // The last series is the attribution: `ping` is answered by the bridge itself and never
        // reaches the socket, so it prices the stdio pipes and the bridge's own scheduling.
        // Whatever is left between it and the bridge series is the second hop.
        let local = try awaitOffMain("bridge-local samples", timeout: 600) {
            try bridge.samples(
                method: "ping",
                count: Fixture.hopSamples,
                timeout: Fixture.replyTimeout
            )
        }

        print(
            "THREADING_PERF mcp-bridge-hop samples=\(Fixture.hopSamples) "
                + "direct_median_ms=\(Self.formatted(Self.median(direct))) "
                + "direct_p95_ms=\(Self.formatted(Self.percentile95(direct))) "
                + "direct_fresh_median_ms=\(Self.formatted(Self.median(directFresh))) "
                + "direct_fresh_p95_ms=\(Self.formatted(Self.percentile95(directFresh))) "
                + "bridge_median_ms=\(Self.formatted(Self.median(hopped))) "
                + "bridge_p95_ms=\(Self.formatted(Self.percentile95(hopped))) "
                + "socket_direct_median_ms=\(Self.formatted(Self.median(socketDirect))) "
                + "socket_direct_p95_ms=\(Self.formatted(Self.percentile95(socketDirect))) "
                + "bridge_local_median_ms=\(Self.formatted(Self.median(local))) "
                + "bridge_local_p95_ms=\(Self.formatted(Self.percentile95(local))) "
                + "delta_median_ms="
                + Self.formatted(Self.median(hopped) - Self.median(direct))
        )
    }

    // MARK: - Fixture helpers

    private static let listChangedMethod = "notifications/tools/list_changed"

    private static let sampleInvocation = MCPBridgeInvocation(
        command: "/Applications/Threading.app/Contents/Helpers/threading-mcp-bridge",
        arguments: ["--socket", "/tmp/b/mcp.sock", "--token", "t0", "--cache", "/tmp/c.json"]
    )

    /// The real helper, found the way the app finds it.
    ///
    /// `Bundle.main` is Threading.app in an ordinary hosted run, because the test bundle is
    /// hosted in it. The opt-in measurement runs this same bundle under `xcrun xctest` — the
    /// only way to give a test an environment variable, since a test plan sanitizes what it
    /// launches with — and there `Bundle.main` is the tool. The helper is one bundle away
    /// either way, which is why `MCPBridgeLocation.helperURL(in:)` takes the bundle.
    private func helperURL() throws -> URL {
        let hosted = MCPBridgeLocation.helperURL()
        if FileManager.default.isExecutableFile(atPath: hosted.path) { return hosted }

        let enclosingApplication = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()  // Contents/PlugIns
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // Threading.app
        let sideloaded = Bundle(url: enclosingApplication)
            .map(MCPBridgeLocation.helperURL(in:)) ?? hosted

        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: sideloaded.path),
            "no \(MCPBridgeDefaults.helperName) in this bundle — build the Threading target, "
                + "which embeds it through the Embed Extension Helpers phase"
        )
        return sideloaded
    }

    /// One rendezvous per test. Short on purpose: `sun_path` is 104 bytes and the system
    /// temporary directory already spends nearly half of them.
    private var rendezvousPath: String {
        directory.appendingPathComponent(MCPBridgeDefaults.socketFileName).path
    }

    private func decision(helper: URL, socketPath: String) -> MCPBridgeDecision {
        MCPBridgeDecision(isEnabled: true, helperURL: helper, socketPath: socketPath)
    }

    /// A session whose token this test owns and whose files it cleans up.
    @MainActor
    private func registeredSession() -> SessionID {
        let sessionID = SessionID()
        sessionIDs.append(sessionID)
        return sessionID
    }

    @MainActor
    private func startedServer() throws -> MCPServer {
        let path = rendezvousPath
        let server = MCPServer(socketPath: path)

        let started = expectation(description: "the loopback listener settled")
        server.start { started.fulfill() }
        wait(for: [started], timeout: Fixture.listenerTimeout)

        let bound = expectation(description: "the rendezvous settled")
        DispatchQueue.global().async {
            for _ in 0..<1_500 {
                if server.socketPath != nil { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            bound.fulfill()
        }
        wait(for: [bound], timeout: Fixture.listenerTimeout)

        XCTAssertEqual(server.socketPath, path, "the rendezvous never bound")
        return server
    }

    /// Writes the real per-session configuration, then spawns exactly what it names.
    ///
    /// Going through the file rather than through `bridgeInvocation` is the point: a launch is
    /// only as good as the words the CLI is handed, and this is the only test that reads them
    /// back the way the CLI does.
    @MainActor
    private func spawnBridgeFromWrittenConfiguration(
        for sessionID: SessionID,
        helper: URL,
        socketPath: String
    ) throws -> SpawnedBridge {
        let path = try XCTUnwrap(MCPSessionRegistry.writeConfiguration(
            for: sessionID,
            decision: decision(helper: helper, socketPath: socketPath)
        ))
        let server = try Self.claudeServerObject(atConfigurationPath: path)
        XCTAssertEqual(server["type"] as? String, "stdio")

        let bridge = try SpawnedBridge(
            executable: URL(fileURLWithPath: try XCTUnwrap(server["command"] as? String)),
            arguments: try XCTUnwrap(server["args"] as? [String])
        )
        spawned.append(bridge)
        return bridge
    }

    private static func claudeServerObject(
        atConfigurationPath path: String
    ) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))
        ) as? [String: Any]
        let servers = try XCTUnwrap(object?["mcpServers"] as? [String: Any])
        return try XCTUnwrap(servers[MCPDefaults.serverName] as? [String: Any])
    }

    /// Sends and waits for one reply off the main queue.
    ///
    /// The server answers `initialize` and `tools/list` by hopping to main, so a test blocking
    /// there would deadlock against the code it is exercising. Waiting on an expectation instead
    /// keeps the main run loop servicing those hops.
    @MainActor
    private func roundTrip(
        _ bridge: SpawnedBridge,
        request: [String: Any],
        id: Int
    ) throws -> [String: Any] {
        let line = try JSONSerialization.data(withJSONObject: request)
        return try awaitOffMain(
            "the bridge answered \(id)",
            timeout: Fixture.replyTimeout
        ) {
            bridge.send(line)
            return WireLine(object: try bridge.reply(to: id, timeout: Fixture.replyTimeout))
        }.object
    }

    @MainActor
    private func awaitOffMain<T: Sendable>(
        _ description: String,
        timeout: TimeInterval,
        _ work: @escaping @Sendable () throws -> T
    ) throws -> T {
        let finished = expectation(description: description)
        let outcome = OSAllocatedUnfairLock<Result<T, BridgeLaunchFailure>?>(initialState: nil)

        DispatchQueue.global().async {
            do {
                let value = try work()
                outcome.withLock { $0 = .success(value) }
            } catch {
                outcome.withLock { $0 = .failure(BridgeLaunchFailure("\(error)")) }
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: timeout + 5)
        switch outcome.withLock({ $0 }) {
        case .success(let value): return value
        case .failure(let failure): throw failure
        case nil: throw BridgeLaunchFailure("\(description) never finished")
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }

    // MARK: - Wire fixtures

    private static func initialize(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": ["protocolVersion": Fixture.protocolVersion, "capabilities": [:]]
        ]
    }

    private static func toolsList(id: Int) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/list"]
    }

    private static func toolCall(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": MCPBuiltInTool.displayImage.rawValue, "arguments": [:]]
        ]
    }

    private static func string(_ object: [String: Any], _ path: String...) -> String? {
        var current: Any? = object
        for key in path {
            current = (current as? [String: Any])?[key]
        }
        return current as? String
    }

    // MARK: - Measurement helpers

    /// `tools/list` over the loopback port.
    ///
    /// `reusesConnection` is the fourth axis of the attribution and not a detail: `URLSession`
    /// keeps its connection alive between calls while the bridge opens one per request, so a
    /// comparison that let only one of them reuse would be pricing connection setup and calling
    /// it a hop.
    private static func samplesOverHTTP(
        endpoint: URL,
        count: Int,
        reusesConnection: Bool
    ) throws -> [Double] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: toolsList(id: 1))

        let shared = reusesConnection ? URLSession(configuration: .ephemeral) : nil
        defer { shared?.finishTasksAndInvalidate() }

        var samples: [Double] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            let session = shared ?? URLSession(configuration: .ephemeral)
            let started = DispatchTime.now().uptimeNanoseconds
            let done = DispatchSemaphore(value: 0)
            let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
            session.dataTask(with: request) { data, _, error in
                if let error {
                    failure.withLock { $0 = "\(error)" }
                } else if data == nil {
                    failure.withLock { $0 = "no body" }
                }
                done.signal()
            }.resume()
            guard done.wait(timeout: .now() + Fixture.replyTimeout) == .success else {
                throw BridgeLaunchFailure("a direct sample never came back")
            }
            if let message = failure.withLock({ $0 }) {
                throw BridgeLaunchFailure("direct sample failed: \(message)")
            }
            samples.append(milliseconds(DispatchTime.now().uptimeNanoseconds - started))
            if shared == nil { session.finishTasksAndInvalidate() }
        }
        return samples
    }

    /// The same `tools/list`, posted straight at the rendezvous with no bridge in the path.
    ///
    /// This is what separates "the shim is slow" from "the rendezvous is slow". It speaks the
    /// same three-line HTTP the bridge speaks, one connection per request, so the only thing it
    /// removes from the bridge series is the helper process itself.
    private static func samplesOverUnixSocket(
        path: String,
        requestPath: String,
        count: Int
    ) throws -> [Double] {
        let body = try JSONSerialization.data(withJSONObject: toolsList(id: 1))
        var head = "POST \(requestPath) HTTP/1.1\r\n"
        head += "Host: localhost\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let request = Data(head.utf8) + body

        var samples: [Double] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            let started = DispatchTime.now().uptimeNanoseconds
            try oneUnixExchange(path: path, request: request)
            samples.append(milliseconds(DispatchTime.now().uptimeNanoseconds - started))
        }
        return samples
    }

    /// Connect, write, read the head and exactly the declared body, close.
    ///
    /// Reading to end of file would hang: `MCPConnection` answers `Connection: keep-alive` and
    /// leaves the socket open, so the client is the side that decides a response is finished —
    /// which is also exactly what the bridge does, and what makes this series comparable to it.
    private static func oneUnixExchange(path: String, request: Data) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeLaunchFailure("socket() failed") }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw BridgeLaunchFailure("socket path does not fit sun_path")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw BridgeLaunchFailure("connect() failed") }

        try request.withUnsafeBytes { raw -> Void in
            var sent = 0
            while sent < raw.count {
                let written = write(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard written > 0 else { throw BridgeLaunchFailure("write() failed") }
                sent += written
            }
        }

        let terminator = Data("\r\n\r\n".utf8)
        var chunk = [UInt8](repeating: 0, count: 8_192)
        var received = Data()
        var bodyLength: Int?
        var headEnd: Int?

        while true {
            if headEnd == nil, let range = received.range(of: terminator) {
                headEnd = range.upperBound - received.startIndex
                let head = String(decoding: received[received.startIndex..<range.lowerBound],
                                  as: UTF8.self)
                bodyLength = head
                    .components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap {
                        Int($0.drop { $0 != ":" }.dropFirst()
                            .trimmingCharacters(in: .whitespaces))
                    }
            }
            if let headEnd, let bodyLength, received.count - headEnd >= bodyLength { break }

            let read = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            guard read > 0 else {
                throw BridgeLaunchFailure("the endpoint closed before answering")
            }
            received.append(contentsOf: chunk[0..<read])
        }
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private static func median(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func percentile95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))
        return sorted[index]
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

// MARK: - Crossing a queue

/// One parsed JSON-RPC line, handed from the queue that read it to the test that asserts on it.
///
/// `[String: Any]` is not `Sendable` and cannot be made so. The box states the property that
/// makes the crossing safe here: the dictionary is parsed once, never mutated afterwards, and
/// handed over exactly once.
private struct WireLine: @unchecked Sendable {
    let object: [String: Any]
}

// MARK: - Failures

private struct BridgeLaunchFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Spawned Bridge

/// One `threading-mcp-bridge` process, driven over real pipes.
///
/// Replies are matched by id rather than by position: the bridge answers concurrently and is
/// entitled to, so a runner that assumed stdout order would be asserting something JSON-RPC never
/// promised.
private final class SpawnedBridge: @unchecked Sendable {

    // MARK: - Properties

    private let process = Process()
    private let standardInput = Pipe()
    private let standardOutput = Pipe()
    private let standardError = Pipe()

    private let condition = NSCondition()
    private var pending = Data()
    private var lines: [[String: Any]] = []
    private var diagnostics = Data()
    private var nextRequestID = 1_000

    // MARK: - Initialization

    init(executable: URL, arguments: [String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.received(data)
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.condition.lock()
            self?.diagnostics.append(data)
            self?.condition.unlock()
        }

        try process.run()
    }

    // MARK: - Public Methods

    /// Takes bytes rather than a dictionary, because the caller is usually on the main actor
    /// and `[String: Any]` cannot cross to the queue this process is driven from.
    func send(_ line: Data) {
        try? standardInput.fileHandleForWriting.write(contentsOf: line + Data("\n".utf8))
    }

    func reply(to id: Int, timeout: TimeInterval) throws -> [String: Any] {
        try line(where: { ($0["id"] as? NSNumber)?.intValue == id }, timeout: timeout)
    }

    func line(
        where predicate: ([String: Any]) -> Bool,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let match = lines.first(where: predicate) { return match }
            guard condition.wait(until: deadline) else { break }
        }
        throw BridgeLaunchFailure(
            "no matching line within \(timeout)s. stderr:\n"
                + String(decoding: diagnostics, as: UTF8.self)
        )
    }

    /// One request per sample, each timed from write to matching reply — the same unit the direct
    /// measurement times, so the two are comparable.
    func samples(method: String, count: Int, timeout: TimeInterval) throws -> [Double] {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for _ in 0..<count {
            condition.lock()
            nextRequestID += 1
            let id = nextRequestID
            condition.unlock()

            guard let line = try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": id, "method": method
            ]) else { throw BridgeLaunchFailure("could not encode a sample request") }

            let started = DispatchTime.now().uptimeNanoseconds
            send(line)
            _ = try reply(to: id, timeout: timeout)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        return samples
    }

    func terminate() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        try? standardInput.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    // MARK: - Private Methods

    private func received(_ data: Data) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex..<newline])
            pending = Data(pending[pending.index(after: newline)...])
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            lines.append(object)
        }
    }
}
