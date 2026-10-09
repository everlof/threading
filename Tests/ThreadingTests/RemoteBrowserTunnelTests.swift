import Network
import ThreadingRemoteKit
import XCTest
@testable import Threading

@MainActor
final class RemoteBrowserTunnelTests: HostedStoreTestCase {
    func testGrantBoundsConnectionsAndRevokesExistingPipes() throws {
        let origin = try XCTUnwrap(RemoteBrowserLocalOrigin(url: URL(string: "http://localhost:3000")!))
        let grant = RemoteBrowserTunnelGrant(sessionID: SessionID(), tabID: UUID(), authorization: owner,
                                             origin: origin)
        let revoked = expectation(description: "all admitted streams revoked")
        revoked.expectedFulfillmentCount = RemoteBrowserTunnelDefaults.maximumConnectionsPerLease
        for _ in 0..<RemoteBrowserTunnelDefaults.maximumConnectionsPerLease {
            XCTAssertNotNil(grant.admit { revoked.fulfill() })
        }
        XCTAssertNil(grant.admit {})
        grant.revoke()
        XCTAssertFalse(grant.isValid)
        XCTAssertNil(grant.admit {})
        wait(for: [revoked], timeout: 1)
        let expired = RemoteBrowserTunnelGrant(sessionID: SessionID(), tabID: UUID(), authorization: owner,
                                               origin: origin, now: .distantPast)
        XCTAssertNil(expired.admit {})
    }

    func testOnlyScopedProxyCredentialsAreAccepted() {
        XCTAssertNil(RemoteBrowserTunnelStore.token(from: "Bearer owner-secret"))
        XCTAssertNil(RemoteBrowserTunnelStore.token(from: "Basic " + Data("owner:secret".utf8).base64EncodedString()))
        XCTAssertEqual(RemoteBrowserTunnelStore.token(from:
            "Basic " + Data("threading-preview:scoped".utf8).base64EncodedString()), "scoped")
    }

    func testRealProxyCarriesLargeResponsesFormsAndWebSocketsThenRefusesClosedLease() async throws {
        try await exerciseLoopbackSite(host: "127.0.0.1")
    }

    func testLocalhostAlsoReachesAnIPv6OnlyDevServer() async throws {
        try await exerciseLoopbackSite(host: "::1")
    }

    private func exerciseLoopbackSite(host: String) async throws {
        let site = try BrowserTunnelSite(host: host)
        let sitePort = try await site.start()
        defer { site.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: directory))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
        let tabID = UUID()
        let siteURL = try XCTUnwrap(URL(string: "http://localhost:\(sitePort)/page"))
        let provider = BrowserTunnelWorkspace(url: siteURL, tabID: tabID)
        RemoteWorkspaceBridge.install(provider)
        let identity = RemoteIdentityTestStore.make(label: "BrowserTunnel")
        defer { try? FileManager.default.removeItem(at: identity.directory) }
        let authority = RemoteAuthorityStore()
        authority.set(owner, forToken: "owner-token")
        let suite = "BrowserTunnel.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = RemoteAccessServer(
            services: RemoteAccessCoordinator.makeServerServices(appSettings: AppSettings(defaults: defaults)),
            identityProvider: identity.store
        )
        server.authorizer = authority
        defer { server.stop() }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.start(configuration: RemoteListenerConfiguration(preferredPort: FreeLocalPort.quiet() ?? 0)) {
                if let port = $0.port { continuation.resume(returning: port) }
                else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
            }
        }
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/session/\(session.id)/browser-tunnel"))
        func request(_ token: String, closing: String? = nil, expectedOrigin: String? = nil) async throws -> (Data, Int) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("device", forHTTPHeaderField: "X-Threading-Device")
            request.httpBody = try JSONEncoder().encode(RemoteBrowserTunnelRequest(
                tabID: tabID.uuidString, closingToken: closing,
                expectedOrigin: expectedOrigin ?? RemoteBrowserLocalOrigin(url: siteURL)?.key
            ))
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
        }
        authority.set(RemoteAuthorization(shareID: "guest", capability: .interact,
                                         scope: .session(session.id), principal: .guest), forToken: "guest-token")
        let guest = try await request("guest-token")
        XCTAssertEqual(guest.1, 403)
        provider.isPrivate = true
        let hidden = try await request("owner-token")
        XCTAssertEqual(hidden.1, 404)
        provider.isPrivate = false
        let changedOrigin = try await request("owner-token", expectedOrigin: "http://localhost:1")
        XCTAssertEqual(changedOrigin.1, 409, "a navigation between link lookup and opening must not retarget the preview")
        let admitted = try await request("owner-token")
        XCTAssertEqual(admitted.1, 200)
        let lease = try JSONDecoder().decode(RemoteBrowserTunnelDTO.self, from: admitted.0)
        let origin = try XCTUnwrap(RemoteBrowserLocalOrigin(url: lease.url))
        // macOS URLSession bypasses CONNECT proxies for loopback even with matchDomains.
        // Speak the wire protocol here; the iOS test separately exercises real WebKit.
        let browser = BrowserTunnelProbe(port: port)
        let connected = try await browser.open(authority: origin.authority, token: lease.token)
        XCTAssertTrue(connected.hasPrefix("HTTP/1.1 200"), connected)
        try await browser.send("GET /page HTTP/1.1\r\nHost: \(origin.authority)\r\n\r\n")
        let pageHead = try await browser.readHead()
        XCTAssertTrue(pageHead.hasPrefix("HTTP/1.1 200"), pageHead)
        let page = try await browser.readToEnd()
        XCTAssertEqual(page, BrowserTunnelSite.body, "the final bytes of a large response survive the tunnel")
        await browser.close()

        let form = BrowserTunnelProbe(port: port)
        let formConnected = try await form.open(authority: origin.authority, token: lease.token)
        XCTAssertTrue(formConnected.hasPrefix("HTTP/1.1 200"), formConnected)
        try await form.send("POST /page HTTP/1.1\r\nHost: \(origin.authority)\r\nContent-Length: 10\r\n\r\nname=phone")
        _ = try await form.readHead()
        let formReply = try await form.readToEnd()
        XCTAssertEqual(formReply, Data("name=phone".utf8))
        await form.close()

        let socket = BrowserTunnelProbe(port: port)
        let socketConnected = try await socket.open(authority: origin.authority, token: lease.token)
        XCTAssertTrue(socketConnected.hasPrefix("HTTP/1.1 200"), socketConnected)
        try await socket.send("GET /socket HTTP/1.1\r\nHost: \(origin.authority)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
        let upgrade = try await socket.readHead()
        XCTAssertTrue(upgrade.hasPrefix("HTTP/1.1 101"), upgrade)
        let expectedFrame = RemoteWebSocket.textFrame("live reload ready")
        let frame = try await socket.read(count: expectedFrame.count)
        XCTAssertEqual(frame, expectedFrame)
        XCTAssertFalse(site.sawProxyCredential, "the preview credential belongs to the proxy, never the dev server")

        let forbidden = BrowserTunnelProbe(port: port)
        let denied = try await forbidden.open(authority: "127.0.0.1:\(sitePort)", token: lease.token)
        XCTAssertTrue(denied.hasPrefix("HTTP/1.1 403"), denied)
        await forbidden.close()
        let closed = try await request("owner-token", closing: lease.token)
        XCTAssertEqual(closed.1, 200)
        let closeStarted = Date()
        let disconnected = await socket.waitForClose()
        XCTAssertTrue(disconnected, "closing a lease closes an existing WebSocket")
        XCTAssertLessThan(Date().timeIntervalSince(closeStarted), 5, "revocation must close existing pipes promptly")
        await socket.close()

        let reopened = BrowserTunnelProbe(port: port)
        let refused = try await reopened.open(authority: origin.authority, token: lease.token)
        XCTAssertTrue(refused.hasPrefix("HTTP/1.1 403"), refused)
        await reopened.close()
        withExtendedLifetime(provider) {}
    }

    private var owner: RemoteAuthorization {
        RemoteAuthorization(shareID: "owner", capability: .interact, scope: .allSessions, principal: .ownerDevice)
    }
}

@MainActor
private final class BrowserTunnelWorkspace: RemoteWorkspaceProviding {
    let url: URL
    let tabID: UUID
    var isPrivate = false
    init(url: URL, tabID: UUID) { self.url = url; self.tabID = tabID }
    func remoteBrowserTabs(for sessionID: SessionID) -> [RemoteBrowserTabDTO] { [] }
    func remoteBrowserPreview(for sessionID: SessionID, tabID: UUID) async -> Data? { nil }
    func remoteBrowserLink(for sessionID: SessionID, tabID: UUID) -> URL? {
        tabID == self.tabID && !isPrivate ? url : nil
    }
}

/// Queue-owned bounded HTTP fixture; the large body tests relay backpressure and final EOF.
private final class BrowserTunnelSite: @unchecked Sendable {
    static let body = Data(repeating: 65, count: 2 * 1_024 * 1_024)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BrowserTunnelSite")
    private let lock = NSLock()
    private var credentialSeen = false
    private var sockets: [NWConnection] = []
    var sawProxyCredential: Bool { lock.withLock { credentialSeen } }

    init(host: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init(host), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                }
            }
            listener.newConnectionHandler = { [self] socket in
                sockets.append(socket)
                socket.start(queue: queue)
                receive(socket, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() { queue.async { self.sockets.forEach { $0.cancel() }; self.listener.cancel() } }

    private func receive(_ socket: NWConnection, buffer: Data) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count < 128 * 1_024 else { socket.cancel(); return }
            if case let .request(request, _) = MCPConnection.parseRequest(from: buffer, maximumBodyBytes: 65_536) {
                if request.header("Proxy-Authorization") != nil { lock.withLock { credentialSeen = true } }
                if request.path == "/socket", let upgrade = RemoteWebSocket.upgradeResponseData(for: request) {
                    socket.send(content: upgrade + RemoteWebSocket.textFrame("live reload ready"), completion: .idempotent)
                } else {
                    let body = request.method == "POST" ? request.body : Self.body
                    let head = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    socket.send(content: head + body, contentContext: .finalMessage, completion: .idempotent)
                }
            } else if !complete, error == nil { receive(socket, buffer: buffer) }
        }
    }
}

/// A bounded raw CONNECT client, so macOS's automatic loopback bypass cannot make this pass.
private actor BrowserTunnelProbe {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "BrowserTunnelProbe")
    private var buffer = Data()
    private var ended = false

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp)
    }

    deinit { connection.cancel() }
    func close() { connection.cancel() }

    func open(authority: String, token: String) async throws -> String {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: URLError(.timedOut))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 20) { connection.cancel() }
        }
        let credential = Data("threading-preview:\(token)".utf8).base64EncodedString()
        try await send("CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\nProxy-Authorization: Basic \(credential)\r\n\r\n")
        return try await readHead()
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func readHead() async throws -> String {
        let marker = Data("\r\n\r\n".utf8)
        while buffer.range(of: marker) == nil { try await receive() }
        let end = buffer.range(of: marker)!.upperBound
        let head = String(decoding: buffer[..<end], as: UTF8.self)
        buffer = Data(buffer[end...])
        return head
    }

    func read(count: Int) async throws -> Data {
        while buffer.count < count { try await receive() }
        let result = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return result
    }

    func readToEnd() async throws -> Data {
        while !ended { try await receive() }
        let result = buffer
        buffer.removeAll()
        return result
    }

    func waitForClose() async -> Bool {
        do { try await receive(); return ended && buffer.isEmpty }
        catch { return buffer.isEmpty }
    }

    private func receive() async throws {
        guard !ended else { throw URLError(.networkConnectionLost) }
        let (data, complete): (Data, Bool) = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1_024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), complete)) }
            }
        }
        guard buffer.count + data.count <= 4 * 1_024 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
        buffer.append(data)
        ended = complete
    }
}
