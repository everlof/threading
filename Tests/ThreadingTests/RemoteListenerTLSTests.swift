import Network
import os
import XCTest
import ThreadingRemoteKit
@testable import Threading

/// The listener with an identity: what a routable door presents, what a client that pins it sees,
/// and what a client pinned to something else sees instead.
///
/// These boot the real `RemoteAccessServer` against real sockets and connect to it with a real
/// `URLSession`, because the thing being proved is that Network.framework, CFNetwork and this
/// certificate agree. A mocked handshake would prove that the mock agrees with itself. Nothing
/// here orders a window on screen, so it stays in the fast level.
@MainActor
final class RemoteListenerTLSTests: HostedStoreTestCase {

    /// The same address trick `RemoteListenerDoorTests` uses: `::1` is assignable on every Mac
    /// while `127.0.0.2` is not, and the door rules classify by interface name, so an address
    /// reported on `en9` is the LAN door's whatever the address happens to be. That keeps this
    /// off the developer's real Wi-Fi.
    private static let lanAddress = RemoteNetworkAddress(
        interfaceName: "en9",
        address: "::1",
        isIPv6: true
    )

    /// A tailnet as the classifier sees one: a `utun` carrying a `100.64.0.0/10` address, which
    /// is what makes it Tailscale's rather than somebody's VPN, plus the address beside it on the
    /// same interface. The CGNAT address is not assignable on a build machine, so it is the `::1`
    /// that binds — which is the shape a real tailnet has anyway, an IPv4 and an IPv6 address on
    /// one interface, and it proves the door reports itself bound while one of its addresses
    /// cannot be taken.
    private static let tailnetAddresses = [
        RemoteNetworkAddress(interfaceName: "utun9", address: "100.100.1.1"),
        RemoteNetworkAddress(interfaceName: "utun9", address: "::1", isIPv6: true)
    ]

    private var server: RemoteAccessServer!
    private var identityStore: RemoteAccessIdentityStore!
    private var identityDirectory: URL!
    private var appSettings: AppSettings!
    private var appSettingsDefaults: UserDefaults!
    private var appSettingsSuiteName: String!
    private let addresses = OSAllocatedUnfairLock<[RemoteNetworkAddress]>(initialState: [])
    private var sessions: [URLSession] = []

    override func setUp() {
        super.setUp()
        appSettingsSuiteName = "RemoteListenerTLSTests.\(UUID().uuidString)"
        appSettingsDefaults = UserDefaults(suiteName: appSettingsSuiteName)!
        appSettings = AppSettings(defaults: appSettingsDefaults)
        addresses.withLock { $0 = [Self.lanAddress] }
        let source = addresses
        let identity = RemoteIdentityTestStore.make(label: "RemoteListenerTLSTests")
        identityStore = identity.store
        identityDirectory = identity.directory
        server = RemoteAccessServer(
            services: RemoteAccessCoordinator.makeServerServices(appSettings: appSettings),
            addressSource: { source.withLock { $0 } },
            identityProvider: identity.store
        )
        server.recordListenerDiagnostic = { _, _, _ in }
    }

    override func tearDown() {
        for session in sessions { session.invalidateAndCancel() }
        sessions.removeAll()
        server?.stop()
        server = nil
        RemoteIdentityTestStore.erase(identityDirectory)
        identityDirectory = nil
        identityStore = nil
        if let appSettingsSuiteName {
            appSettingsDefaults?.removePersistentDomain(forName: appSettingsSuiteName)
        }
        appSettingsDefaults = nil
        appSettings = nil
        super.tearDown()
    }

    // MARK: - The pinned door

    func testAPinnedClientReachesTheLanDoorWhileLoopbackStaysCleartext() throws {
        let port = try startWithLanDoor()
        let fingerprint = try XCTUnwrap(identityStore.snapshot.fingerprint)
        let client = pinnedClient(fingerprint: fingerprint)

        XCTAssertEqual(
            client.status(url: url(port: port, path: "/")),
            200,
            "the bundled client answers over TLS exactly as it did over cleartext"
        )
        XCTAssertEqual(
            client.delegate.verdict(forHost: Self.lanAddress.address),
            .accepted,
            "the client reads its own verdict, because a cancelled challenge is URLError -999 "
                + "with nothing in it to read"
        )
        XCTAssertEqual(
            client.status(url: url(port: port, path: "/api/me")),
            401,
            "TLS is not authentication: an unauthenticated request is still refused"
        )

        XCTAssertEqual(
            httpStatus(host: RemoteAccessDefaults.host, port: port),
            200,
            "loopback stays cleartext, because the Hosted bridge and Serve talk plain HTTP to it"
        )
        XCTAssertFalse(RemoteAccessDoor.loopback.requiresTLS)
        XCTAssertTrue(RemoteAccessDoor.lan.requiresTLS)
    }

    func testTheSocketOnThePinnedSessionGoesThroughTheSamePin() throws {
        let port = try startWithLanDoor()
        let fingerprint = try XCTUnwrap(identityStore.snapshot.fingerprint)
        let client = pinnedClient(fingerprint: fingerprint)

        // A server-trust challenge goes to the *session* delegate, which is what makes the
        // socket share the REST path's pinning. A socket on an unpinned session would keep stock
        // evaluation, and stock evaluation refuses this leaf outright.
        var components = try XCTUnwrap(URLComponents(url: url(port: port, path: "/ws/events"), resolvingAgainstBaseURL: false))
        components.scheme = "wss"
        let task = client.session.webSocketTask(with: try XCTUnwrap(components.url))
        task.resume()
        wait(for: [client.socketOpened], timeout: 10)
        task.cancel(with: .goingAway, reason: nil)

        XCTAssertEqual(client.delegate.verdict(forHost: Self.lanAddress.address), .accepted)
    }

    func testACertificateSwappedUnderneathProducesTheNamedRefusalAndNoConnection() throws {
        let port = try startWithLanDoor()
        let stranger = RemoteIdentityTestStore.make(label: "stranger")
        defer { RemoteIdentityTestStore.erase(stranger.directory) }
        let wrongFingerprint = try stranger.store.currentIdentity().get().fingerprint
        XCTAssertNotEqual(wrongFingerprint, identityStore.snapshot.fingerprint)

        let client = pinnedClient(fingerprint: wrongFingerprint)
        XCTAssertNil(
            client.status(url: url(port: port, path: "/")),
            "a mismatch is not a slow connection or a 4xx: nothing connects at all"
        )
        XCTAssertEqual(
            client.delegate.verdict(forHost: Self.lanAddress.address),
            .rejectedFingerprintMismatch,
            "the one network failure that deserves its own sentence has to be distinguishable"
        )
        XCTAssertEqual(
            (client.lastError as? URLError)?.code,
            .cancelled,
            "which the URLError cannot say on its own, which is why the verdict exists"
        )
    }

    func testAnUnpinnedClientIsRefusedByStockEvaluation() throws {
        let port = try startWithLanDoor()
        let client = pinnedClient(fingerprint: nil)

        XCTAssertNil(
            client.status(url: url(port: port, path: "/")),
            "a self-signed leaf is exactly what the system trust store refuses, which is the "
                + "structural proof that the pinned path is doing the work"
        )
        XCTAssertEqual(client.delegate.verdict(forHost: Self.lanAddress.address), .notPinned)
    }

    // MARK: - What is advertised

    func testTheAdvertisedListSaysWhichEndpointsPresentThisMacsOwnIdentity() throws {
        let port = try startWithLanDoor()
        let fingerprint = try XCTUnwrap(identityStore.snapshot.fingerprint)

        var endpoints = RemoteAccessCoordinator.doorEndpoints(
            server.listenerStatus,
            advertisedHostname: "",
            localHostname: "studio.local"
        )
        XCTAssertEqual(endpoints.count, 2)
        XCTAssertTrue(endpoints.allSatisfy { $0.kind == RemoteHostEndpointKind.lan })
        XCTAssertTrue(endpoints.allSatisfy { $0.baseURL.scheme == "https" })
        XCTAssertTrue(endpoints.allSatisfy(\.expectsPinnedIdentity))
        XCTAssertEqual(endpoints.first?.baseURL.absoluteString, "https://[::1]:\(port)/")

        // An endpoint somebody else terminates is advertised without the flag, and must stay
        // that way: a Serve origin holds a real certificate for its `*.ts.net` name, and a phone
        // told to pin it would fail on renewal. **Nothing in this build advertises one** — the
        // tailnet door is a listener with this Mac's own identity — so it is constructed here to
        // prove the wire still distinguishes the two.
        let publiclyTrusted = RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.tailscale,
            baseURL: try XCTUnwrap(URL(string: "https://mac.example.ts.net:8443/")),
            isStable: true
        )
        endpoints.append(publiclyTrusted)
        let host = RemoteAccessCoordinator.ownerHost(
            RemoteHostDTO(id: "mac-1", name: "Studio"),
            endpoints: endpoints,
            policy: .privateOnly,
            identity: identityStore.snapshot
        )
        XCTAssertEqual(host.pinnedFingerprint, fingerprint.hex)
        XCTAssertNil(host.nextPinnedFingerprint)
        XCTAssertFalse(try XCTUnwrap(host.endpoints).last?.expectsPinnedIdentity ?? true)
        XCTAssertEqual(
            RemoteHostEndpointSelection.ordered(try XCTUnwrap(host.endpoints), policy: .privateOnly).count,
            3,
            "all three are private-network candidates now, cleartext being the thing that was "
                + "keeping the LAN ones out"
        )
    }

    /// The tailnet door advertises the address this Mac holds on its tailnet, its MagicDNS name
    /// on the same sticky port, and nothing at all about Serve.
    func testTheTailnetDoorAdvertisesItsOwnAddressAndNameWithThePin() throws {
        let port = try quietPort()
        addresses.withLock { $0 = Self.tailnetAddresses + [Self.lanAddress] }
        XCTAssertEqual(
            start(RemoteListenerConfiguration(preferredPort: port, doors: [.tailscale])),
            .listening(port: port)
        )
        waitUntil("the tailnet door binds") {
            self.server.listenerStatus.state(of: .tailscale).bindings.count == 1
        }

        let endpoints = RemoteAccessCoordinator.doorEndpoints(
            server.listenerStatus,
            advertisedHostname: "",
            localHostname: "studio.local",
            tailnetHostname: "mac-studio.tail1234.ts.net"
        )
        XCTAssertEqual(
            endpoints.map(\.baseURL.absoluteString),
            [
                "https://[::1]:\(port)/",
                "https://mac-studio.tail1234.ts.net:\(port)/"
            ],
            "the tailnet door advertises the address it bound and the name that resolves to it"
        )
        XCTAssertTrue(
            endpoints.allSatisfy { $0.kind == RemoteHostEndpointKind.tailscale },
            "a tailnet address is not a LAN address, and the phone picks by kind"
        )
        XCTAssertTrue(
            endpoints.allSatisfy(\.expectsPinnedIdentity),
            "the tailnet door presents this Mac's own certificate, exactly like the LAN door"
        )
        XCTAssertFalse(
            endpoints.contains { $0.baseURL.port == 8443 },
            "Serve's origin was advertised: it is a public certificate no fingerprint covers"
        )
        XCTAssertEqual(
            RemoteHostEndpointSelection.ordered(endpoints, policy: .privateOnly).count,
            endpoints.count,
            "a phone under the fail-closed policy has both of these to try"
        )
        XCTAssertTrue(
            RemoteAccessCoordinator.doorEndpoints(
                server.listenerStatus,
                advertisedHostname: "",
                localHostname: "studio.local"
            ).allSatisfy { $0.baseURL.host != "mac-studio.tail1234.ts.net" },
            "a name nobody has read from the CLI is not advertised"
        )
    }

    /// A pinned client reaches the tailnet door over TLS, with the same certificate the LAN door
    /// presents. One identity, one code path, whatever address the phone is standing on.
    func testAPinnedClientReachesTheTailnetDoorWithTheSameCertificate() throws {
        let port = try quietPort()
        addresses.withLock { $0 = Self.tailnetAddresses }
        XCTAssertEqual(
            start(RemoteListenerConfiguration(preferredPort: port, doors: [.tailscale])),
            .listening(port: port)
        )
        waitUntil("the tailnet door binds") {
            self.server.listenerStatus.state(of: .tailscale).bindings.count == 1
        }

        let fingerprint = try XCTUnwrap(identityStore.snapshot.fingerprint)
        let client = pinnedClient(fingerprint: fingerprint)
        XCTAssertEqual(client.status(url: url(port: port, path: "/")), 200)
        XCTAssertEqual(client.delegate.verdict(forHost: Self.lanAddress.address), .accepted)
        XCTAssertTrue(RemoteAccessDoor.tailscale.requiresTLS)
    }

    func testAPairingCodeNamesOneLanAddressAndPrefersTheDefaultRoute() throws {
        let primary = RemoteListenerBinding(
            door: .lan,
            address: RemoteNetworkAddress(interfaceName: "en0", address: "192.168.1.42"),
            port: 8760
        )
        let secondary = RemoteListenerBinding(
            door: .lan,
            address: RemoteNetworkAddress(interfaceName: "en5", address: "10.0.9.4"),
            port: 8760
        )
        let sixth = RemoteListenerBinding(
            door: .lan,
            address: RemoteNetworkAddress(interfaceName: "en0", address: "fd00::4", isIPv6: true),
            port: 8760
        )

        XCTAssertEqual(
            RemoteAccessCoordinator.preferredPairingBinding(
                [secondary, sixth, primary],
                primaryInterfaceName: "en0"
            ),
            primary,
            "the interface carrying the default route is the network the phone in the room is on"
        )
        XCTAssertEqual(
            RemoteAccessCoordinator.preferredPairingBinding([sixth, primary], primaryInterfaceName: "en0"),
            primary,
            "IPv4 before IPv6 on the same interface: a bracketed literal is longer in the symbol"
        )
        XCTAssertEqual(
            RemoteAccessCoordinator.preferredPairingBinding([sixth, secondary], primaryInterfaceName: "en0"),
            sixth,
            "but the default route still wins across interfaces, because that is the network the "
                + "phone is on; an IPv6-only Wi-Fi beats a Thunderbolt bridge with an address"
        )
        XCTAssertNil(RemoteAccessCoordinator.preferredPairingBinding([], primaryInterfaceName: "en0"))
    }

    func testTheScannedCodeCarriesTheFingerprintAndPrefersTheLanDoor() throws {
        let made = RemoteIdentityTestStore.make(label: "pairing")
        defer { RemoteIdentityTestStore.erase(made.directory) }
        let fingerprint = try made.store.currentIdentity().get().fingerprint
        let lan = RemoteListenerBinding(
            door: .lan,
            address: RemoteNetworkAddress(interfaceName: "en0", address: "192.168.1.42"),
            port: 8760
        )
        let tailnet = RemoteListenerBinding(
            door: .tailscale,
            address: RemoteNetworkAddress(interfaceName: "utun4", address: "100.65.47.126"),
            port: 8760
        )

        let destination = try XCTUnwrap(RemoteAccessCoordinator.pairingDestination(
            lanBindings: [lan],
            tailnetBindings: [tailnet],
            primaryInterfaceName: "en0",
            pinnedFingerprint: fingerprint
        ))
        XCTAssertEqual(
            destination.origin.absoluteString,
            "https://192.168.1.42:8760/",
            "a bound LAN door wins: it is the network the phone in the room is already on"
        )
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: destination.origin,
            token: "MFRGGZDFMZTWQ2LK",
            pinnedFingerprintCode: destination.pinnedFingerprintCode
        ))
        XCTAssertEqual(
            link.scannablePayload,
            "HTTPS://192.168.1.42:8760/#MFRGGZDFMZTWQ2LK.\(fingerprint.pairingCode)"
        )

        // With no LAN door, the tailnet is the destination — and it carries the fingerprint too,
        // because the listener there presents this Mac's own certificate. It used to fall back to
        // a Serve origin with no fingerprint at all, which is the second trust story §8 removes.
        let withoutLAN = try XCTUnwrap(RemoteAccessCoordinator.pairingDestination(
            lanBindings: [],
            tailnetBindings: [tailnet],
            primaryInterfaceName: "en0",
            pinnedFingerprint: fingerprint
        ))
        XCTAssertEqual(withoutLAN.origin.absoluteString, "https://100.65.47.126:8760/")
        XCTAssertEqual(withoutLAN.pinnedFingerprintCode, fingerprint.pairingCode)

        XCTAssertNil(RemoteAccessCoordinator.pairingDestination(
            lanBindings: [lan],
            tailnetBindings: [tailnet],
            primaryInterfaceName: "en0",
            pinnedFingerprint: nil
        ), "with no identity there is nothing to pair to at all")

        XCTAssertNil(RemoteAccessCoordinator.pairingDestination(
            lanBindings: [],
            tailnetBindings: [],
            primaryInterfaceName: "en0",
            pinnedFingerprint: fingerprint
        ), "and with nothing bound there is nowhere to send a phone")
    }

    // MARK: - Rotation

    func testRotationSwitchesTheCertificateWithoutMovingThePort() throws {
        let port = try startWithLanDoor()
        let original = try XCTUnwrap(identityStore.snapshot.fingerprint)

        let successor = try identityStore.prepareRotation().get()
        let announced = RemoteAccessCoordinator.ownerHost(
            RemoteHostDTO(id: "mac-1", name: "Studio"),
            endpoints: RemoteAccessCoordinator.doorEndpoints(
                server.listenerStatus,
                advertisedHostname: "",
                localHostname: nil
            ),
            policy: .privateOnly,
            identity: identityStore.snapshot
        )
        XCTAssertEqual(announced.pinnedFingerprint, original.hex)
        XCTAssertEqual(
            announced.nextPinnedFingerprint,
            successor.hex,
            "the successor is announced over the channel the current identity authenticates"
        )
        // A phone that has read that announcement pins both, and is therefore not disconnected
        // by the switch.
        let ready = pinnedClient(fingerprint: original, next: successor)
        XCTAssertEqual(ready.status(url: url(port: port, path: "/")), 200)

        XCTAssertEqual(try identityStore.activateRotation().get().fingerprint, successor)
        server.reloadIdentity()
        waitUntil("the lan door binds again after the identity changed") {
            self.server.listenerStatus.state(of: .lan).bindings.count == 1
        }
        XCTAssertEqual(server.port, port, "a rotation must not move the port anybody remembers")

        let updated = pinnedClient(fingerprint: successor)
        XCTAssertEqual(updated.status(url: url(port: port, path: "/")), 200)
        XCTAssertEqual(updated.delegate.verdict(forHost: Self.lanAddress.address), .accepted)

        let stale = pinnedClient(fingerprint: original)
        XCTAssertNil(stale.status(url: url(port: port, path: "/")))
        XCTAssertEqual(
            stale.delegate.verdict(forHost: Self.lanAddress.address),
            .rejectedFingerprintMismatch,
            "a device that never received the announcement is refused, loudly and by name"
        )
        XCTAssertEqual(ready.status(url: url(port: port, path: "/")), 200, "and one that did is not")
    }

    // MARK: - No identity

    func testADoorWithNoIdentityBindsNothingAndSaysWhy() throws {
        let port = try quietPort()
        // A file that is there and unreadable: the case that must never silently mint.
        try FileManager.default.createDirectory(at: identityDirectory, withIntermediateDirectories: true)
        try Data("not an identity".utf8).write(to: identityDirectory.appendingPathComponent("current.json"))

        XCTAssertEqual(
            start(RemoteListenerConfiguration(preferredPort: port, doors: [.lan])),
            .listening(port: port),
            "the server is fine; it is the door that has nothing to present"
        )
        waitUntil("the lan door reports the identity") {
            self.server.listenerStatus.state(of: .lan) == .notReachable(.identityUnavailable)
        }
        XCTAssertEqual(
            server.requestedBindings.map(\.address),
            [RemoteListenerSet.loopbackAddress],
            "there is no cleartext fallback: a door with no identity binds nothing at all"
        )
        XCTAssertEqual(
            httpStatus(host: RemoteAccessDefaults.host, port: port),
            200,
            "and loopback carries on, because the bridge that uses it needs no certificate"
        )
    }

    // MARK: - Helpers

    private func startWithLanDoor() throws -> UInt16 {
        let port = try quietPort()
        XCTAssertEqual(
            start(RemoteListenerConfiguration(preferredPort: port, doors: [.lan])),
            .listening(port: port)
        )
        waitUntil("the lan door binds with an identity") {
            self.server.listenerStatus.state(of: .lan).bindings.count == 1
        }
        return port
    }

    private func url(port: UInt16, path: String) -> URL {
        URL(string: "https://\(Self.lanAddress.urlHost):\(port)\(path)")!
    }

    /// A `URLSession` that pins the way the phone will, plus somewhere to read what it decided.
    private final class PinnedClient: NSObject, URLSessionWebSocketDelegate {
        let delegate: RemoteCertificatePinningDelegate
        let socketOpened = XCTestExpectation(description: "the socket completed its handshake")
        private(set) var lastError: Error?
        private(set) var session: URLSession!

        init(delegate: RemoteCertificatePinningDelegate) {
            self.delegate = delegate
            super.init()
            session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        }

        func status(url: URL) -> Int? {
            let done = XCTestExpectation(description: "request to \(url.path)")
            var status: Int?
            let task = session.dataTask(with: URLRequest(url: url)) { [weak self] _, response, error in
                status = (response as? HTTPURLResponse)?.statusCode
                self?.lastError = error
                done.fulfill()
            }
            task.resume()
            _ = XCTWaiter().wait(for: [done], timeout: 15)
            return status
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            delegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol protocolName: String?
        ) {
            socketOpened.fulfill()
        }
    }

    private func pinnedClient(
        fingerprint: RemoteHostFingerprint?,
        next: RemoteHostFingerprint? = nil
    ) -> PinnedClient {
        var pins: [String: RemoteHostPinSet] = [:]
        if let fingerprint {
            pins[Self.lanAddress.address] = RemoteHostPinSet(
                current: fingerprint.pin,
                next: next?.pin
            )
        }
        let client = PinnedClient(delegate: RemoteCertificatePinningDelegate(pins: pins))
        sessions.append(client.session)
        return client
    }

    @discardableResult
    private func start(_ configuration: RemoteListenerConfiguration) -> RemoteListenerStartOutcome? {
        var result: RemoteListenerStartOutcome?
        let ready = expectation(description: "listener answered")
        server.start(configuration: configuration) { outcome in
            result = outcome
            ready.fulfill()
        }
        wait(for: [ready], timeout: 15)
        return result
    }

    private func quietPort() throws -> UInt16 {
        guard let port = FreeLocalPort.quiet() else {
            throw XCTSkip("No free port in the quiet range")
        }
        return port
    }

    private func httpStatus(host: String, port: UInt16) -> Int? {
        var status: Int?
        let done = expectation(description: "GET / on \(host)")
        let request = URLRequest(url: URL(string: "http://\(host):\(port)/")!)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return status
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) {
        let met = expectation(description: description)
        let poll = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            guard condition() else { return }
            timer.invalidate()
            met.fulfill()
        }
        wait(for: [met], timeout: 15)
        poll.invalidate()
        XCTAssertTrue(condition(), description, file: file, line: line)
    }
}
