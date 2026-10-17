import XCTest
import Network
import ThreadingController
import ThreadingWorkroomPortal
@testable import Threading

/// The portal's socket and its tunnel, as processes and connections rather than as values: the
/// listener answers on loopback only, refuses ambiguous headers, and a tunnel's address comes from
/// what its child process prints.
@MainActor
final class WorkroomPortalServerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workroom-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheListenerServesThePortalOnLoopbackOnly() async throws {
        let store = try ControllerStore(path: directory.appendingPathComponent("controller.db").path)
        let portal = WorkroomPortal(backend: StoreParticipantBackend(store: store))
        let server = WorkroomPortalServer(portal: portal)
        let port = try await start(server)
        defer { server.stop() }
        await portal.configure(WorkroomPortalConfiguration(publicOrigin: "https://rooms.example.test", loopbackPort: port))

        let (css, cssResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/assets/portal.css")!)
        let http = try XCTUnwrap(cssResponse as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(String(decoding: css, as: UTF8.self).contains("--accent"))
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")

        let (_, inbox) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual((inbox as? HTTPURLResponse)?.statusCode, 401)

        let ambiguous = try await raw("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nHost: rooms.example.test\r\n\r\n", port: port)
        XCTAssertTrue(ambiguous.hasPrefix("HTTP/1.1 400"), ambiguous)
        let foreign = try await raw("GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n", port: port)
        XCTAssertTrue(foreign.hasPrefix("HTTP/1.1 421"), foreign)
    }

    func testATunnelPublishesTheAddressItsProcessPrintsAndCleansUp() async throws {
        let script = try fakeTunnel("echo 'INF |  https://fake-room-1.trycloudflare.com  |'\nexec sleep 30")
        let tunnel = WorkroomTunnel(recipe: .cloudflare(), childLedger: AgentChildLedger(url: directory.appendingPathComponent("ledger.json")),
                                    locateExecutable: { script })
        let connected = expectation(description: "connected")
        tunnel.start(port: 1) { state in
            if case .connected(let url) = state, url.host == "fake-room-1.trycloudflare.com" { connected.fulfill() }
        }
        await fulfillment(of: [connected], timeout: 10)
        let privateDirectories = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("threading-workroom-tunnel-") }
        tunnel.stop()
        XCTAssertEqual(tunnel.state, .stopped)
        try await Task.sleep(for: .milliseconds(300))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("threading-workroom-tunnel-") }
        XCTAssertTrue(Set(remaining).isDisjoint(with: Set(privateDirectories)), "a stopped tunnel leaves no private directory")
    }

    func testATunnelThatNeverPublishesIsStoppedAndSaysSo() async throws {
        let script = try fakeTunnel("exec sleep 30")
        let tunnel = WorkroomTunnel(recipe: .cloudflare(), childLedger: AgentChildLedger(url: directory.appendingPathComponent("ledger.json")),
                                    locateExecutable: { script }, startupTimeout: .milliseconds(300))
        let failed = expectation(description: "unavailable")
        tunnel.start(port: 1) { state in if case .unavailable = state { failed.fulfill() } }
        await fulfillment(of: [failed], timeout: 10)
        tunnel.stop()
    }

    func testAMissingExecutableIsAStatedReason() {
        let tunnel = WorkroomTunnel(recipe: .ngrok(domain: nil, userConfiguration: nil), locateExecutable: { nil })
        tunnel.start(port: 1) { _ in }
        guard case .unavailable(let message) = tunnel.state else { return XCTFail("a missing ngrok must be said") }
        XCTAssertTrue(message.contains("ngrok"))
    }

    // MARK: - Helpers

    private func start(_ server: WorkroomPortalServer) async throws -> UInt16 {
        let port: UInt16? = await withCheckedContinuation { continuation in
            server.start { continuation.resume(returning: $0) }
        }
        return try XCTUnwrap(port)
    }

    private func fakeTunnel(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("cloudflared")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// One raw request on a fresh connection; returns the response head and body as text.
    private nonisolated func raw(_ request: String, port: UInt16) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                guard case .ready = state else {
                    if case .failed(let error) = state, once.claim() { continuation.resume(throwing: error) }
                    return
                }
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                        guard once.claim() else { return }
                        connection.cancel()
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self)) }
                    }
                })
            }
            connection.start(queue: .global())
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
