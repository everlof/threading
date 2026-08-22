import Foundation
import Network
import XCTest
@testable import Threading

/// The stdio shim, exercised as the process it ships as.
///
/// Every test here runs the real `threading-mcp-bridge` out of `Contents/Helpers` with real
/// pipes, against a listener built from the app's own `MCPConnection`. Nothing is stubbed on
/// either side, because the two things that were worth getting wrong are both dialect: the HTTP
/// framing the bridge writes and the `text/event-stream` framing it reads. A fake speaking a
/// convenient dialect would agree with a bridge that speaks the wrong one.
///
/// The listener is the test's, not `MCPServer.shared`'s, so a handler can hold a response open
/// for as long as a test needs — which is how "a slow tool call does not block a ping" is asked.
final class MCPBridgeTests: XCTestCase {

    // MARK: - Constants

    private enum Fixture {
        /// Generous: these bound a process launch plus a socket round trip, and the point of
        /// each assertion is *that it happens at all*, never how quickly.
        static let replyTimeout: TimeInterval = 10
        /// Longer, because the bridge's own reconnect backoff is in the path.
        static let reconnectTimeout: TimeInterval = 20
        static let exitTimeout: TimeInterval = 10
        /// A tool call the fake app never answers has to look slow, not broken.
        static let concurrencyProbeTimeout: TimeInterval = 5

        static let token = "test-token-0123456789"
        static let helperName = "threading-mcp-bridge"

        static let toolName = "display_image"
    }

    // MARK: - Fixture state

    private var directory: URL!
    private var runners: [BridgeRunner] = []
    private var apps: [FakeThreadingApp] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `sockaddr_un.sun_path` holds 104 bytes, and the system temporary directory is already
        // ~48 of them, so the fixture's own names are kept to a handful of characters.
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tmb-\(UInt32.random(in: 0..<0xFFFF_FFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for runner in runners { runner.terminate() }
        runners.removeAll()
        for app in apps { app.stop() }
        apps.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Forwarding

    func testForwardsTheHandshakeAndCachesWhatCameBack() throws {
        let bridge = try helperURL()
        let app = try startApp(answering: Self.catalogueHandler())
        let cache = cacheURL()

        let runner = try run(bridge, socketPath: app.socketPath, cache: cache)

        runner.send(Self.initializeRequest(id: 1))
        let handshake = try runner.reply(to: 1, timeout: Fixture.replyTimeout)
        XCTAssertEqual(Self.string(handshake, "result", "serverInfo", "name"), "threading")
        XCTAssertEqual(Self.string(handshake, "result", "protocolVersion"), Self.protocolVersion)

        runner.send(Self.toolsListRequest(id: 2))
        let listing = try runner.reply(to: 2, timeout: Fixture.replyTimeout)
        let tools = try XCTUnwrap(
            (listing["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        )
        XCTAssertEqual(tools.first?["name"] as? String, Fixture.toolName)

        // The cache is what makes the *next* launch work with no app, so it is written as a
        // consequence of a successful reply rather than on a schedule.
        try waitForFile(at: cache, timeout: Fixture.replyTimeout)
        let permissions = try FileManager.default
            .attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(
            permissions?.int16Value,
            0o600,
            "the catalogue cache is owner-only; it sits beside per-session secrets"
        )

        let cached = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any]
        )
        XCTAssertNotNil(cached["initializeResult"])
        XCTAssertNotNil(cached["toolsListResult"])
    }

    // MARK: - Answering without the app

    func testAnswersFromTheCacheAndRefusesAToolCallWithNoAppRunning() throws {
        let bridge = try helperURL()
        let cache = cacheURL()
        let socketPath = self.socketPath()

        // First, one full session against a live app, purely to fill the cache.
        let app = try startApp(at: socketPath, answering: Self.catalogueHandler())
        let seeding = try run(bridge, socketPath: socketPath, cache: cache)
        seeding.send(Self.initializeRequest(id: 1))
        _ = try seeding.reply(to: 1, timeout: Fixture.replyTimeout)
        seeding.send(Self.toolsListRequest(id: 2))
        _ = try seeding.reply(to: 2, timeout: Fixture.replyTimeout)
        try waitForFile(at: cache, timeout: Fixture.replyTimeout)
        seeding.terminate()
        app.stop()

        // Then the case this whole helper exists for: the CLI starts, Threading does not.
        let runner = try run(bridge, socketPath: socketPath, cache: cache)

        runner.send(Self.initializeRequest(id: 10))
        let handshake = try runner.reply(to: 10, timeout: Fixture.replyTimeout)
        XCTAssertEqual(Self.string(handshake, "result", "serverInfo", "name"), "threading")
        XCTAssertEqual(
            Self.string(handshake, "result", "protocolVersion"),
            Self.protocolVersion,
            "the handshake echoes the version this client asked for, not one from the cache"
        )

        runner.send(Self.toolsListRequest(id: 11))
        let listing = try runner.reply(to: 11, timeout: Fixture.replyTimeout)
        let tools = try XCTUnwrap(
            (listing["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        )
        XCTAssertEqual(
            tools.first?["name"] as? String,
            Fixture.toolName,
            "the tool list came from the cache, so the session starts with a working server"
        )

        runner.send(Self.toolCallRequest(id: 12))
        let refusal = try runner.reply(to: 12, timeout: Fixture.replyTimeout)
        XCTAssertNil(
            refusal["error"],
            "a refusal is a result, not a transport error — a transport error never reaches "
                + "the model, which is who has to read it and move on"
        )
        let result = try XCTUnwrap(refusal["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue(
            (content.first?["text"] as? String ?? "").contains("Threading is not running"),
            "\(content)"
        )
    }

    func testAnswersAHandshakeWithNeitherAnAppNorACache() throws {
        let bridge = try helperURL()
        let runner = try run(bridge, socketPath: socketPath(), cache: cacheURL())

        runner.send(Self.initializeRequest(id: 1))
        let handshake = try runner.reply(to: 1, timeout: Fixture.replyTimeout)
        XCTAssertEqual(Self.string(handshake, "result", "serverInfo", "name"), "threading")
        XCTAssertTrue(
            (Self.string(handshake, "result", "instructions") ?? "")
                .contains("Threading is not running"),
            "an empty tool list has to say why, or it looks like a server with no tools"
        )

        runner.send(Self.toolsListRequest(id: 2))
        let listing = try runner.reply(to: 2, timeout: Fixture.replyTimeout)
        let tools = try XCTUnwrap(
            (listing["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        )
        XCTAssertTrue(
            tools.isEmpty,
            "empty rather than invented: no tool name is compiled into the bridge, which is "
                + "what keeps it from drifting away from MCPToolCatalog"
        )

        runner.send(Self.toolCallRequest(id: 3))
        let refusal = try runner.reply(to: 3, timeout: Fixture.replyTimeout)
        XCTAssertEqual((refusal["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    // MARK: - The event stream

    func testAnnouncesToolsListChangedWhenTheAppAppearsAfterTheBridge() throws {
        let bridge = try helperURL()
        let socketPath = self.socketPath()

        // No listener yet: the bridge's first connect fails, which is the condition that makes
        // its next successful one worth announcing.
        let runner = try run(bridge, socketPath: socketPath, cache: cacheURL())
        runner.send(Self.toolsListRequest(id: 1))
        _ = try runner.reply(to: 1, timeout: Fixture.replyTimeout)

        _ = try startApp(at: socketPath, answering: Self.catalogueHandler())

        let announcement = try runner.line(
            where: { $0["method"] as? String == Self.toolsListChangedMethod },
            timeout: Fixture.reconnectTimeout
        )
        XCTAssertEqual(announcement["jsonrpc"] as? String, "2.0")
        XCTAssertNil(
            announcement["id"],
            "a notification has no id; a client that saw one would wait for a reply to it"
        )
    }

    func testWritesAServerPushedEventToStandardOutput() throws {
        let bridge = try helperURL()
        let app = try startApp(answering: Self.catalogueHandler())
        let runner = try run(bridge, socketPath: app.socketPath, cache: cacheURL())

        // The stream is opened without prompting, but nothing says when. One forwarded request
        // proves the socket is up; the poll below waits for the GET behind it.
        runner.send(Self.initializeRequest(id: 1))
        _ = try runner.reply(to: 1, timeout: Fixture.replyTimeout)
        try app.waitForEventStream(timeout: Fixture.replyTimeout)

        app.broadcast(MCPServer.toolsListChangedEvent)

        let announcement = try runner.line(
            where: { $0["method"] as? String == Self.toolsListChangedMethod },
            timeout: Fixture.replyTimeout
        )
        XCTAssertEqual(announcement["jsonrpc"] as? String, "2.0")
        XCTAssertNil(announcement["params"])
    }

    // MARK: - Concurrency

    func testASlowToolCallDoesNotBlockAPing() throws {
        let bridge = try helperURL()
        let held = HeldResponse()
        let app = try startApp(answering: { request, respond in
            guard request.method == "POST" else { return respond(.status(405, "Method Not Allowed")) }
            guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let method = message["method"] as? String else {
                return respond(.status(400, "Bad Request"))
            }
            if method == "tools/call" {
                // Held, not slow: the app does this for real whenever a permission prompt is
                // waiting on a person, and it is why requests cannot be answered one at a time.
                held.hold { respond(.json(Self.toolResultReply(for: message))) }
                return
            }
            respond(.json(Self.reply(to: message, result: [:])))
        })

        let runner = try run(bridge, socketPath: app.socketPath, cache: cacheURL())

        runner.send(Self.toolCallRequest(id: 1))
        try held.waitUntilHeld(timeout: Fixture.replyTimeout)

        runner.send(Self.pingRequest(id: 2))
        let pong = try runner.reply(to: 2, timeout: Fixture.concurrencyProbeTimeout)
        XCTAssertNotNil(pong["result"])
        XCTAssertFalse(
            runner.hasReply(to: 1),
            "the tool call is still held; if it had been answered this test proves nothing"
        )

        held.release()
        let answered = try runner.reply(to: 1, timeout: Fixture.replyTimeout)
        XCTAssertNotNil(answered["result"])
    }

    // MARK: - Malformed input

    func testAMalformedLineIsAnsweredAndTheBridgeKeepsGoing() throws {
        let bridge = try helperURL()
        let app = try startApp(answering: Self.catalogueHandler())
        let runner = try run(bridge, socketPath: app.socketPath, cache: cacheURL())

        runner.sendRaw("{ this is not json")
        let failure = try runner.line(
            where: { ($0["error"] as? [String: Any])?["code"] as? Int == -32700 },
            timeout: Fixture.replyTimeout
        )
        XCTAssertTrue(
            failure.index(forKey: "id") != nil && failure["id"] is NSNull,
            "the id is an explicit null: there was no id to echo, and omitting the member "
                + "would make the reply itself malformed"
        )

        runner.send(Self.initializeRequest(id: 1))
        let handshake = try runner.reply(to: 1, timeout: Fixture.replyTimeout)
        XCTAssertEqual(Self.string(handshake, "result", "serverInfo", "name"), "threading")
    }

    // MARK: - Lifetime

    func testEndOfFileOnStandardInputExitsCleanly() throws {
        let bridge = try helperURL()
        let app = try startApp(answering: Self.catalogueHandler())
        let runner = try run(bridge, socketPath: app.socketPath, cache: cacheURL())

        runner.send(Self.initializeRequest(id: 1))
        _ = try runner.reply(to: 1, timeout: Fixture.replyTimeout)

        runner.closeStandardInput()
        let status = try runner.waitForExit(timeout: Fixture.exitTimeout)
        XCTAssertEqual(
            status,
            0,
            "the client going away is an ordinary ending, not a failure — a non-zero status "
                + "would show in the CLI as the MCP server having crashed"
        )
    }

    // MARK: - Signing

    /// The bridge is the one helper here that is deliberately *not* sandboxed, and the reason is
    /// mechanical: its whole job is to connect to a unix socket under Application Support, which
    /// a container cannot reach. That is worth a tripwire, because a sandboxed bridge would fail
    /// to connect on every launch and be indistinguishable from an app that was simply closed.
    func testTheEmbeddedBridgeCarriesItsOwnIdentityAndNoSandbox() throws {
        let bridge = try helperURL()

        let entitlements = try Self.run(
            "/usr/bin/codesign",
            ["-d", "--entitlements", "-", bridge.path]
        )
        XCTAssertFalse(
            entitlements.contains("com.apple.security.app-sandbox"),
            "the bridge must not be sandboxed:\n\(entitlements)"
        )

        let signature = try Self.run("/usr/bin/codesign", ["-d", "-v", bridge.path])
        XCTAssertTrue(
            signature.contains("codes.threading.mcp-bridge"),
            "the Info.plist embedded with -sectcreate has to survive the copy into "
                + "Contents/Helpers, or the helper has no identity at all:\n\(signature)"
        )
    }

    /// The hardened runtime is asserted against the **project**, not against the signature.
    ///
    /// A `xcodebuild test` build signs nothing with the hardened runtime — not the app, not any
    /// of the four helpers — because a hardened process cannot be attached to by the debugger.
    /// So the flag a `fast` run can read says nothing about what ships, and a test that asserted
    /// it would fail for a build that is correct. What *can* regress is one line in the most
    /// contended file in the repository, so that is what this reads;
    /// `scripts/release.sh` re-checks `flags=.*runtime` on every binary at signing time, which is
    /// the build where the question is answerable.
    func testTheBridgeTargetAsksForTheHardenedRuntimeAndCarriesEmptyEntitlements() throws {
        let root = try XCTUnwrap(Self.repositoryRoot)
        let project = try String(
            contentsOf: root.appendingPathComponent("Threading.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let configurations = project
            .components(separatedBy: "isa = XCBuildConfiguration;")
            .filter { $0.contains("PRODUCT_NAME = \"threading-mcp-bridge\"") }
        XCTAssertEqual(
            configurations.count,
            2,
            "the bridge has a Debug and a Release configuration"
        )
        for configuration in configurations {
            XCTAssertTrue(
                configuration.contains("ENABLE_HARDENED_RUNTIME = YES;"),
                "the shipping bridge is hardened:\n\(configuration)"
            )
            XCTAssertTrue(
                configuration.contains("CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;"),
                "nothing may be added to the bridge's entitlements behind its file:"
                    + "\n\(configuration)"
            )
        }

        let entitlements = root
            .appendingPathComponent("Targets/MCPBridge/threading-mcp-bridge.entitlements")
        let declared = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: entitlements),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertTrue(
            declared.isEmpty,
            "the bridge asks for no capability at all; its containment is the 0700 socket "
                + "directory and the per-session token, not an entitlement: \(declared)"
        )
    }

    // MARK: - Fixture helpers

    /// Located from `#filePath` rather than the test bundle: the project file is not a resource
    /// and has no reason to be copied into one.
    private static let repositoryRoot: URL? = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let protocolVersion = "2025-03-26"
    private static let toolsListChangedMethod = "notifications/tools/list_changed"

    private func helperURL() throws -> URL {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(Fixture.helperName, isDirectory: false)
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: url.path),
            "no \(Fixture.helperName) in this bundle — build the Threading target, which embeds "
                + "it through the Embed Extension Helpers phase, and run the hosted test target"
        )
        return url
    }

    private func socketPath() -> String {
        directory.appendingPathComponent("s\(apps.count).sock").path
    }

    private func cacheURL() -> URL {
        directory.appendingPathComponent("cache/catalogue.json")
    }

    @discardableResult
    private func startApp(
        at path: String? = nil,
        answering handler: @escaping FakeThreadingApp.Handler
    ) throws -> FakeThreadingApp {
        let app = try FakeThreadingApp(socketPath: path ?? socketPath(), handler: handler)
        apps.append(app)
        try app.waitUntilReady(timeout: Fixture.replyTimeout)
        return app
    }

    private func run(_ bridge: URL, socketPath: String, cache: URL) throws -> BridgeRunner {
        let runner = try BridgeRunner(
            executable: bridge,
            socketPath: socketPath,
            token: Fixture.token,
            cachePath: cache.path
        )
        runners.append(runner)
        return runner
    }

    private func waitForFile(at url: URL, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw BridgeTestFailure("\(url.lastPathComponent) never appeared")
    }

    // MARK: - Wire fixtures

    private static func initializeRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": ["protocolVersion": protocolVersion, "capabilities": [:]]
        ]
    }

    private static func toolsListRequest(id: Int) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/list"]
    }

    private static func toolCallRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": Fixture.toolName, "arguments": [:]]
        ]
    }

    private static func pingRequest(id: Int) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "ping"]
    }

    /// A fake app answering the two handshake calls with a one-tool catalogue.
    ///
    /// The tool is named rather than empty because the cache test has to distinguish "answered
    /// from the cache" from "answered with the empty fallback", and an empty list would let both
    /// pass.
    private static func catalogueHandler() -> FakeThreadingApp.Handler {
        { request, respond in
            guard request.method == "POST" else {
                return respond(.status(405, "Method Not Allowed"))
            }
            guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let method = message["method"] as? String else {
                return respond(.status(400, "Bad Request"))
            }
            guard message.index(forKey: "id") != nil else { return respond(.accepted) }

            switch method {
            case "initialize":
                respond(.json(reply(to: message, result: [
                    "protocolVersion": (message["params"] as? [String: Any])?["protocolVersion"]
                        ?? protocolVersion,
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "threading", "version": "0.1.0"],
                    "instructions": "You have a display panel."
                ])))
            case "tools/list":
                respond(.json(reply(to: message, result: [
                    "tools": [[
                        "name": Fixture.toolName,
                        "description": "Show an image in the panel.",
                        "inputSchema": ["type": "object"]
                    ]]
                ])))
            case "tools/call":
                respond(.json(toolResultReply(for: message)))
            default:
                respond(.json(reply(to: message, result: [:])))
            }
        }
    }

    private static func toolResultReply(for message: [String: Any]) -> Data {
        reply(to: message, result: ["content": [["type": "text", "text": "done"]]])
    }

    private static func reply(to message: [String: Any], result: [String: Any]) -> Data {
        var body: [String: Any] = ["jsonrpc": "2.0", "result": result]
        body["id"] = message["id"] ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private static func string(_ object: [String: Any], _ path: String...) -> String? {
        var current: Any? = object
        for key in path {
            current = (current as? [String: Any])?[key]
        }
        return current as? String
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Failure

/// A timeout in this file is a failure, not a skip: every wait here bounds something the bridge
/// promises to do, so running out of time *is* the defect the test exists to find.
private struct BridgeTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - A response the test decides when to send

/// Lets a handler park a response until the test releases it.
///
/// The app does this for real: `MCPConnection` holds the connection open while a permission
/// prompt waits for a person, which is exactly the condition under which a bridge that answered
/// one request at a time would make the CLI declare the server dead.
private final class HeldResponse: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: (() -> Void)?
    private var isHeld = false

    func hold(_ send: @escaping () -> Void) {
        condition.lock()
        pending = send
        isHeld = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilHeld(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isHeld {
            guard condition.wait(until: deadline) else {
                throw BridgeTestFailure("the fake app never received the tool call")
            }
        }
    }

    func release() {
        condition.lock()
        let send = pending
        pending = nil
        condition.unlock()
        send?()
    }
}

// MARK: - The fake app

/// A listener on a unix socket that answers with the app's own `MCPConnection`.
///
/// The framing is therefore the shipping framing — `Content-Length`, `Connection: keep-alive`,
/// the header-terminated event stream — rather than something written to make the bridge pass.
/// That is the whole reason this is not a hand-rolled socket server.
private final class FakeThreadingApp: @unchecked Sendable {

    typealias Handler = @Sendable (HTTPRequest, @escaping @Sendable (HTTPResponse) -> Void) -> Void

    // MARK: - Properties

    let socketPath: String

    private let queue = DispatchQueue(label: "codes.threading.tests.mcp-bridge.app")
    private let handler: Handler
    private var listener: NWListener?

    private let condition = NSCondition()
    private var isReady = false
    private var failure: Error?
    private var connections: [ObjectIdentifier: MCPConnection] = [:]
    private var eventStreams: Set<ObjectIdentifier> = []

    // MARK: - Initialization

    init(socketPath: String, handler: @escaping Handler) throws {
        self.socketPath = socketPath
        self.handler = handler

        try? FileManager.default.removeItem(atPath: socketPath)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketPath)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                condition.lock()
                isReady = true
                condition.broadcast()
                condition.unlock()
            case .failed(let error):
                condition.lock()
                failure = error
                condition.broadcast()
                condition.unlock()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    // MARK: - Public Methods

    func waitUntilReady(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isReady, failure == nil {
            guard condition.wait(until: deadline) else {
                throw BridgeTestFailure("the fixture listener never became ready at \(socketPath)")
            }
        }
        if let failure { throw failure }
    }

    /// Waits until a client has held `GET` open, so a test can push an event and know somebody
    /// is listening for it.
    func waitForEventStream(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while eventStreams.isEmpty {
            guard condition.wait(until: deadline) else {
                throw BridgeTestFailure("no client opened the event stream")
            }
        }
    }

    func broadcast(_ event: Data) {
        condition.lock()
        let streams = eventStreams.compactMap { connections[$0] }
        condition.unlock()
        for stream in streams { stream.sendServerEvent(event) }
    }

    func stop() {
        condition.lock()
        let open = Array(connections.values)
        connections.removeAll()
        eventStreams.removeAll()
        condition.unlock()

        for connection in open { connection.cancel() }
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Private Methods

    private func accept(_ nwConnection: NWConnection) {
        let connection = MCPConnection(
            connection: nwConnection,
            queue: queue,
            handler: { [weak self] connection, request, respond in
                self?.route(request, on: connection, respond: respond)
            },
            onClose: { [weak self] closed in
                guard let self else { return }
                let identifier = ObjectIdentifier(closed)
                condition.lock()
                connections.removeValue(forKey: identifier)
                eventStreams.remove(identifier)
                condition.unlock()
            }
        )
        condition.lock()
        connections[ObjectIdentifier(connection)] = connection
        condition.unlock()
        connection.start()
    }

    private func route(
        _ request: HTTPRequest,
        on connection: MCPConnection,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        guard request.method != "GET" else {
            guard request.header("accept")?.contains("text/event-stream") == true else {
                return respond(.status(404, "Not Found"))
            }
            condition.lock()
            eventStreams.insert(ObjectIdentifier(connection))
            condition.broadcast()
            condition.unlock()
            respond(.eventStream)
            return
        }
        handler(request, respond)
    }
}

// MARK: - The bridge under test

/// One `threading-mcp-bridge` process, with its stdout split into lines.
///
/// Replies are matched by id rather than by position, because the bridge answers concurrently
/// and is entitled to: a test that assumed stdout order would be asserting something JSON-RPC
/// never promised, and would fail exactly when the concurrency it is meant to allow happens.
private final class BridgeRunner: @unchecked Sendable {

    // MARK: - Properties

    private let process = Process()
    private let standardInput = Pipe()
    private let standardOutput = Pipe()
    private let standardError = Pipe()

    private let condition = NSCondition()
    private var pending = Data()
    private var lines: [[String: Any]] = []
    private var diagnostics = Data()
    private var terminationStatus: Int32?
    private var hasClosedInput = false

    // MARK: - Initialization

    init(executable: URL, socketPath: String, token: String, cachePath: String) throws {
        process.executableURL = executable
        process.arguments = [
            "--socket", socketPath,
            "--token", token,
            "--cache", cachePath
        ]
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
            self?.receivedDiagnostics(data)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            condition.lock()
            terminationStatus = process.terminationStatus
            condition.broadcast()
            condition.unlock()
        }

        try process.run()
    }

    // MARK: - Public Methods

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        sendRaw(String(decoding: data, as: UTF8.self))
    }

    func sendRaw(_ line: String) {
        condition.lock()
        let isClosed = hasClosedInput
        condition.unlock()
        guard !isClosed else { return }
        try? standardInput.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func closeStandardInput() {
        condition.lock()
        hasClosedInput = true
        condition.unlock()
        try? standardInput.fileHandleForWriting.close()
    }

    /// The reply carrying `id`, or a failure naming what did arrive.
    func reply(to id: Int, timeout: TimeInterval) throws -> [String: Any] {
        try line(where: { ($0["id"] as? NSNumber)?.intValue == id }, timeout: timeout)
    }

    func hasReply(to id: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return lines.contains { ($0["id"] as? NSNumber)?.intValue == id }
    }

    /// Waits for the first line satisfying `predicate`, scanning lines already received first.
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
        let seen = lines.map { "\($0)" }.joined(separator: "\n")
        let stderr = String(decoding: diagnostics, as: UTF8.self)
        throw BridgeTestFailure(
            "no matching line within \(timeout)s.\nstdout:\n\(seen)\nstderr:\n\(stderr)"
        )
    }

    func waitForExit(timeout: TimeInterval) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while terminationStatus == nil {
            guard condition.wait(until: deadline) else {
                throw BridgeTestFailure("the bridge did not exit within \(timeout)s")
            }
        }
        return terminationStatus ?? -1
    }

    func terminate() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        condition.lock()
        let wasClosed = hasClosedInput
        hasClosedInput = true
        condition.unlock()
        if !wasClosed { try? standardInput.fileHandleForWriting.close() }
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
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            lines.append(object)
        }
    }

    private func receivedDiagnostics(_ data: Data) {
        condition.lock()
        diagnostics.append(data)
        condition.unlock()
    }
}
