import Foundation
import ThreadingPeerTransport
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// Which route carries the sockets: the one that answered the catalogue last.
///
/// The 2026-09-06 iOS report dialled a hosted loopback origin every second, failing in 20 ms,
/// while every conditional refresh beside it answered `304` over Tailscale. These pin the rule
/// that ends that: a prepared tunnel carries the sockets only when hosted is what answered last,
/// and only while the tunnel stands.
final class MobileLiveRoutePolicyTests: XCTestCase {
    private enum Fixture {
        static let now = Date(timeIntervalSince1970: 1_800_000_000)
        static let token = "bearer-fixture"
        static let tailnetURL = URL(string: "https://david-mac.tailnet-demo.ts.net:8443/")!
        static let loopbackURL = URL(string: "http://127.0.0.1:53817/")!
        static let replacementLoopbackURL = URL(string: "http://127.0.0.1:53818/")!
        static let hostedLink = RemoteConnectionLink(baseURL: loopbackURL, token: token)!
        static let replacementHostedLink = RemoteConnectionLink(
            baseURL: replacementLoopbackURL,
            token: token
        )!

        static func host(activeKind: RemoteHostEndpointKind? = .tailscale) -> PairedRemoteHost {
            PairedRemoteHost(
                id: "mac",
                hostID: "mac",
                shareID: "my-devices",
                scope: "all",
                name: "Mac",
                link: RemoteConnectionLink(baseURL: tailnetURL, token: token)!,
                lastConnectedAt: now,
                endpoints: [
                    RemoteHostEndpointDTO(kind: .tailscale, baseURL: tailnetURL, isStable: true),
                ],
                connectionPolicy: .privateOnly,
                activeEndpointKind: activeKind
            )
        }

        static func answered(
            over kind: RemoteHostEndpointKind,
            at url: URL,
            isHosted: Bool,
            hostID: String = "mac"
        ) -> MobileConnectionRecord {
            MobileConnectionRecord(
                hostID: hostID,
                kind: kind,
                baseURL: url,
                isHosted: isHosted,
                connectedAt: now,
                metrics: nil,
                serverProtocol: nil
            )
        }
    }

    /// The report's shape: Tailscale answered the catalogue, and a hosted tunnel had been
    /// prepared beside it. The sockets go where the answer came from.
    func testTheSocketsFollowTheRouteThatAnsweredLast() {
        let host = Fixture.host()
        let route = MobileLiveRoutePolicy.route(
            for: host,
            lastConnection: Fixture.answered(over: .tailscale, at: Fixture.tailnetURL, isHosted: false),
            hostedLink: Fixture.hostedLink
        )
        XCTAssertEqual(route, MobileLiveRoute(link: host.link, kind: .tailscale, isHosted: false))
    }

    func testAHostedAnswerKeepsTheSocketsOnTheTunnel() {
        let route = MobileLiveRoutePolicy.route(
            for: Fixture.host(activeKind: .hosted),
            lastConnection: Fixture.answered(over: .hosted, at: Fixture.loopbackURL, isHosted: true),
            hostedLink: Fixture.hostedLink
        )
        XCTAssertEqual(route, MobileLiveRoute(link: Fixture.hostedLink, kind: .hosted, isHosted: true))
    }

    /// Hosted answered, then its tunnel ended: the origin in memory is no route, and the kind is
    /// read from the paired address rather than from the record still saying "hosted".
    func testATunnelThatHasEndedIsNotARoute() {
        let host = Fixture.host(activeKind: .hosted)
        let route = MobileLiveRoutePolicy.route(
            for: host,
            lastConnection: Fixture.answered(over: .hosted, at: Fixture.loopbackURL, isHosted: true),
            hostedLink: nil
        )
        XCTAssertEqual(route, MobileLiveRoute(link: host.link, kind: .tailscale, isHosted: false))
    }

    func testAMacThatHasNotAnsweredYetGetsItsPairedLink() {
        let host = Fixture.host()
        let route = MobileLiveRoutePolicy.route(
            for: host,
            lastConnection: nil,
            hostedLink: Fixture.hostedLink
        )
        XCTAssertEqual(route, MobileLiveRoute(link: host.link, kind: .tailscale, isHosted: false))
    }

    func testAnotherMacsAnswerDoesNotChooseThisOnesRoute() {
        let host = Fixture.host()
        let route = MobileLiveRoutePolicy.route(
            for: host,
            lastConnection: Fixture.answered(
                over: .hosted,
                at: Fixture.loopbackURL,
                isHosted: true,
                hostID: "another-mac"
            ),
            hostedLink: Fixture.hostedLink
        )
        XCTAssertEqual(route, MobileLiveRoute(link: host.link, kind: .tailscale, isHosted: false))
    }

    /// The 2026-09-21 report lost its hosted tunnel during a path change, prepared another while
    /// racing LAN, and then received the LAN catalogue. The constructible client therefore moved
    /// hosted -> LAN -> hosted -> LAN, but those first two moves were not answers and restarted
    /// the same terminal dial each time. Adoption stays on the committed hosted answer until LAN
    /// actually wins.
    func testSessionAdoptionWaitsForARouteToAnswer() {
        let hostedAnswer = Fixture.answered(
            over: .hosted,
            at: Fixture.loopbackURL,
            isHosted: true
        )
        let host = Fixture.host(activeKind: .hosted)

        let safeClientAfterTunnelLoss = MobileLiveRoutePolicy.route(
            for: host,
            lastConnection: hostedAnswer,
            hostedLink: nil
        )
        XCTAssertEqual(
            safeClientAfterTunnelLoss,
            MobileLiveRoute(link: host.link, kind: .tailscale, isHosted: false),
            "a new request must not dial the ended tunnel"
        )
        XCTAssertEqual(
            MobileRouteAdoptionPolicy.identity(
                activeHostID: host.id,
                lastConnection: hostedAnswer
            ),
            MobileRouteIdentity(origin: Fixture.loopbackURL, endpointKind: .hosted),
            "a provisional fallback is not an authenticated route move"
        )

        let safeClientAfterReplacementPreparation = MobileLiveRoutePolicy.route(
            for: host,
            lastConnection: hostedAnswer,
            hostedLink: Fixture.replacementHostedLink
        )
        XCTAssertEqual(
            safeClientAfterReplacementPreparation,
            MobileLiveRoute(
                link: Fixture.replacementHostedLink,
                kind: .hosted,
                isHosted: true
            ),
            "a new request may use the standing replacement tunnel"
        )
        XCTAssertEqual(
            MobileRouteAdoptionPolicy.identity(
                activeHostID: host.id,
                lastConnection: hostedAnswer
            ),
            MobileRouteIdentity(origin: Fixture.loopbackURL, endpointKind: .hosted),
            "tunnel preparation alone does not supersede an unanswered dial"
        )

        let lanAnswer = Fixture.answered(
            over: .lan,
            at: host.link.baseURL,
            isHosted: false
        )
        XCTAssertEqual(
            MobileRouteAdoptionPolicy.identity(
                activeHostID: host.id,
                lastConnection: lanAnswer
            ),
            MobileRouteIdentity(origin: host.link.baseURL, endpointKind: .lan),
            "the winning catalogue response commits the adoption"
        )
    }

    func testSessionAdoptionDoesNotCrossHostsOrInventAnUnansweredRoute() {
        XCTAssertNil(
            MobileRouteAdoptionPolicy.identity(activeHostID: "mac", lastConnection: nil)
        )
        XCTAssertNil(
            MobileRouteAdoptionPolicy.identity(
                activeHostID: "another-mac",
                lastConnection: Fixture.answered(
                    over: .hosted,
                    at: Fixture.loopbackURL,
                    isHosted: true
                )
            )
        )
    }
}

final class HostedRemoteConnectionManagerTests: XCTestCase {
    func testLegacyHostedFingerprintIsNotAProofOfPairing() async throws {
        var legacy = try host()
        legacy.link = RemoteConnectionLink(baseURL: URL(string: "http://127.0.0.1:53817")!, token: "fixture-bearer")!
        legacy.pinnedFingerprint = RemoteHostFingerprint(certificateDER: Data("untrusted api/me".utf8)).hex
        XCTAssertTrue(legacy.candidates.isEmpty, "A saved tunnel port may now belong to another process")
        let manager = HostedRemoteConnectionManager { _, _, _ in
            XCTFail("Legacy hosted identity must be paired again before signaling")
            return HostedTunnelFixture()
        }
        do {
            _ = try await manager.route(for: legacy)
            XCTFail("An unpinned legacy pairing must be refused")
        } catch HostedRemoteConnectionManager.Failure.pairingRequired {}
    }

    func testHTTPFromAConnectorIsNotInstalledAsADirectRoute() async throws {
        let tunnel = HostedTunnelFixture(origin: URL(string: "http://127.0.0.1:53817")!)
        let manager = HostedRemoteConnectionManager { _, _, _ in tunnel }
        do {
            _ = try await manager.route(for: host())
            XCTFail("The native client must not downgrade to HTTP")
        } catch {
            XCTAssertFalse(tunnel.isActive)
        }
    }

    func testConcurrentCallersKeepTheSharedTunnelAlive() async throws {
        let tunnel = HostedTunnelFixture()
        let gate = HostedTunnelGate(tunnel: tunnel)
        let started = expectation(description: "connector started")
        let callers = expectation(description: "callers started")
        callers.expectedFulfillmentCount = 16
        let manager = HostedRemoteConnectionManager { _, _, _ in
            started.fulfill()
            return await gate.connect()
        }
        let host = try host()
        let tasks = (0..<16).map { _ in
            Task {
                callers.fulfill()
                return try await manager.route(for: host)
            }
        }
        await fulfillment(of: [started, callers], timeout: 2)
        // Let the callers enter the actor while its connector is deliberately suspended.
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        for task in tasks {
            let route = try await task.value
            XCTAssertTrue(try XCTUnwrap(route).isActive)
        }
        let connections = await gate.connections
        XCTAssertEqual(connections, 1)
        XCTAssertTrue(tunnel.isActive)
        await manager.invalidate()
        XCTAssertFalse(tunnel.isActive)
    }

    func testInvalidationDisposesOfALateConnectionWithoutRestoringItsRoute() async throws {
        let tunnel = HostedTunnelFixture()
        let gate = HostedTunnelGate(tunnel: tunnel)
        let started = expectation(description: "connector started")
        let manager = HostedRemoteConnectionManager { _, _, _ in
            started.fulfill()
            return await gate.connect()
        }
        let host = try host()
        let task = Task { try await manager.route(for: host) }
        await fulfillment(of: [started], timeout: 2)
        await manager.invalidate()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("A cancelled preparation must not restore remote access")
        } catch is CancellationError {
            XCTAssertFalse(tunnel.isActive)
        }
    }

    func testAnEndedTunnelIsNotInstalled() async throws {
        let tunnel = HostedTunnelFixture()
        tunnel.stop()
        let manager = HostedRemoteConnectionManager { _, _, _ in tunnel }
        do {
            _ = try await manager.route(for: host())
            XCTFail("An ended tunnel is not a route")
        } catch is CancellationError {}
    }

    private func host() throws -> PairedRemoteHost {
        PairedRemoteHost(
            id: "mac", hostID: "mac", shareID: "my-devices", scope: "all", name: "Mac",
            link: RemoteConnectionLink(
                baseURL: URL(string: "https://mac.example")!, token: "fixture-bearer",
                pinnedFingerprintCode: RemoteHostFingerprint(certificateDER: Data("fixture".utf8)).pairingCode
            )!,
            lastConnectedAt: Date(),
            hostedServiceURL: URL(string: "https://service.example"),
            hostedCredential: PeerDeviceServiceCredential(
                hostID: "mac", deviceID: RemoteDeviceIdentity.current,
                credential: try PeerControlPlaneBearer("fixture-service-credential"),
                expiresAt: Date().addingTimeInterval(3600)
            )
        )
    }
}

private final class HostedTunnelFixture: HostedRemoteTunnel, @unchecked Sendable {
    let origin: URL
    init(origin: URL = URL(string: "https://127.0.0.1:53817")!) { self.origin = origin }
    private let lock = NSLock()
    private var stopped = false
    var isActive: Bool { lock.withLock { !stopped } }
    func stop() { lock.withLock { stopped = true } }
}

private actor HostedTunnelGate {
    let tunnel: HostedTunnelFixture
    private(set) var connections = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(tunnel: HostedTunnelFixture) { self.tunnel = tunnel }

    func connect() async -> HostedTunnelFixture {
        connections += 1
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        return tunnel
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// The order a sequential walk takes, and which attempt may replay a lost response.
///
/// After the 2026-09-06 relaunch, notification registration tried a refused Tailscale address, two
/// LAN addresses at sixteen seconds each, and only then the Tailscale address that had answered
/// the catalogue thirty-three seconds earlier. Every mutation negotiated a hosted tunnel first
/// and tried it first. These pin the plan that ends both.
final class MobileRouteWalkPlanTests: XCTestCase {
    private enum Fixture {
        static let now = Date(timeIntervalSince1970: 1_800_000_000)
        static let stableTailnet = URL(string: "https://mac-a.tailnet-demo.ts.net:8443/")!
        static let lanOne = URL(string: "https://192.168.1.42:8760/")!
        static let lanTwo = URL(string: "https://10.0.0.7:8760/")!
        static let answeringTailnet = URL(string: "https://mac-b.tailnet-demo.ts.net:8443/")!
        static let persistedOrder = [stableTailnet, lanOne, lanTwo, answeringTailnet]

        static func answered(_ url: URL, isHosted: Bool = false, hostID: String = "mac") -> MobileConnectionRecord {
            MobileConnectionRecord(
                hostID: hostID,
                kind: isHosted ? .hosted : .tailscale,
                baseURL: url,
                isHosted: isHosted,
                connectedAt: now,
                metrics: nil,
                serverProtocol: nil
            )
        }
    }

    private func plan(
        lastConnection: MobileConnectionRecord?,
        hasHostedRoute: Bool = true
    ) -> MobileRouteWalkPlan.Plan<URL> {
        MobileRouteWalkPlan.plan(
            direct: Fixture.persistedOrder,
            hasHostedRoute: hasHostedRoute,
            hostID: "mac",
            lastConnection: lastConnection,
            origin: { $0 }
        )
    }

    /// The report's registration walk: the address that answered last was attempt 4 of 14.
    func testTheRouteThatAnsweredLastLeadsAndHostedFollowsIt() {
        let plan = plan(lastConnection: Fixture.answered(Fixture.answeringTailnet))
        XCTAssertEqual(
            plan.direct,
            [Fixture.answeringTailnet, Fixture.stableTailnet, Fixture.lanOne, Fixture.lanTwo]
        )
        XCTAssertEqual(plan.steps, [.direct(0), .hosted, .direct(1), .direct(2), .direct(3)])
    }

    func testAHostedAnswerKeepsHostedFirstAndTheDirectOrderAlone() {
        let plan = plan(lastConnection: Fixture.answered(URL(string: "http://127.0.0.1:5001/")!, isHosted: true))
        XCTAssertEqual(plan.direct, Fixture.persistedOrder)
        XCTAssertEqual(plan.steps, [.hosted, .direct(0), .direct(1), .direct(2), .direct(3)])
    }

    func testNothingAnsweredYetWalksTheGivenOrderWithHostedFirst() {
        let plan = plan(lastConnection: nil)
        XCTAssertEqual(plan.direct, Fixture.persistedOrder)
        XCTAssertEqual(plan.steps, [.hosted, .direct(0), .direct(1), .direct(2), .direct(3)])
    }

    func testAnAnswerNoLongerAmongTheCandidatesChangesNothing() {
        let plan = plan(lastConnection: Fixture.answered(URL(string: "https://gone.example:8443/")!))
        XCTAssertEqual(plan.direct, Fixture.persistedOrder)
        XCTAssertEqual(plan.steps, [.hosted, .direct(0), .direct(1), .direct(2), .direct(3)])
    }

    func testAnotherMacsAnswerChangesNothing() {
        let plan = plan(lastConnection: Fixture.answered(Fixture.lanTwo, hostID: "other-mac"))
        XCTAssertEqual(plan.direct, Fixture.persistedOrder)
    }

    func testAMacWithoutAHostedRouteWalksOnlyItsAddresses() {
        let plan = plan(lastConnection: Fixture.answered(Fixture.lanTwo), hasHostedRoute: false)
        XCTAssertEqual(plan.direct, [Fixture.lanTwo, Fixture.stableTailnet, Fixture.lanOne, Fixture.answeringTailnet])
        XCTAssertEqual(plan.steps, [.direct(0), .direct(1), .direct(2), .direct(3)])
    }

    /// Inside a walk the next address is the replay; only the last attempt has no next address.
    func testOnlyTheLastAttemptReplaysALostResponse() {
        XCTAssertEqual(
            (0 ..< 4).map { MobileRouteWalkPlan.replaysLostResponse(at: $0, of: 4) },
            [false, false, false, true]
        )
        XCTAssertTrue(MobileRouteWalkPlan.replaysLostResponse(at: 0, of: 1))
    }
}
