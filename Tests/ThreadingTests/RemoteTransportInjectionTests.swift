import XCTest
@testable import Threading

/// A relay door that records what the coordinator asked of it and launches nothing.
@MainActor
final class RecordingRelayTransport: RemoteRelayTransport {
    private(set) var startedPorts: [UInt16] = []
    private(set) var stopCount = 0
    var lastFailure: RemoteRelayFailure?

    func start(
        port: UInt16,
        onStateChange: @escaping @MainActor @Sendable (RemoteTransportState) -> Void
    ) {
        startedPorts.append(port)
        onStateChange(.starting)
    }

    func stop() {
        stopCount += 1
    }
}

/// The tailnet half of the same seam.
@MainActor
final class RecordingTailnetTransport: RemoteTailnetTransport {
    private(set) var startedPorts: [UInt16] = []
    private(set) var stopCount = 0
    var readiness: TailscaleReadiness = .notChecked
    var onReadinessChange: (@MainActor () -> Void)?

    func start(
        port: UInt16,
        onStateChange: @escaping @MainActor @Sendable (RemoteTransportState) -> Void
    ) {
        startedPorts.append(port)
        onStateChange(.starting)
    }

    func stop() {
        stopCount += 1
    }
}

/// The seam that keeps a test run from publishing the developer's Mac.
///
/// `RemoteAccessCoordinator` used to build `RemoteTunnel()` and `TailscaleRemoteTransport()`
/// itself, with the shipping executable locators, so any test that reached relay mode launched
/// the real `cloudflared`. Two of those children were still alive on this machine when the
/// transport plan was written, because nothing in the test run owned them.
@MainActor
final class RemoteTransportInjectionTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testHostedTestProcessGetsRefusedTransportsRatherThanRealChildProcesses() {
        XCTAssertTrue(
            RemoteAccessCoordinator.defaultRelayTransport() is RefusedRemoteTransport,
            "A hosted test process must never construct the real cloudflared transport."
        )
        XCTAssertTrue(
            RemoteAccessCoordinator.defaultTailnetTransport() is RefusedRemoteTransport,
            "A hosted test process must never construct the real tailscale transport."
        )
    }

    /// Refusal is still a terminal state. A door that reported nothing would put the settings
    /// page back into the indefinite `.starting` that `reliability-and-type-safety.md` calls a
    /// hole in the ledger.
    func testRefusedTransportReportsATerminalStateAndStartsNoChild() {
        let transport = RefusedRemoteTransport()
        var states: [RemoteTransportState] = []
        transport.start(port: 51_000) { states.append($0) }
        transport.stop()

        XCTAssertEqual(states, [.stopped])
        XCTAssertNil(transport.lastFailure)
        XCTAssertEqual(transport.readiness, .notChecked)
    }

    func testCoordinatorDrivesTheInjectedTransportsAndNotItsOwn() {
        let relay = RecordingRelayTransport()
        let tailnet = RecordingTailnetTransport()
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: isolatedAppSettings(),
            guestShareStore: InMemoryRemoteGuestShareStore(shares: []),
            relayTransport: relay,
            tailnetTransport: tailnet
        )

        XCTAssertEqual(relay.startedPorts, [])
        XCTAssertEqual(tailnet.startedPorts, [])

        coordinator.stop()

        XCTAssertGreaterThan(relay.stopCount, 0)
        XCTAssertGreaterThan(tailnet.stopCount, 0)
    }

    private func isolatedAppSettings() -> AppSettings {
        let name = "RemoteTransportInjectionTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return AppSettings(defaults: UserDefaults(suiteName: name)!)
    }
}

/// The Mac's half of the "which address were we even talking about" question.
///
/// `Remote access started {port}` recorded the loopback port and nothing about what the Mac had
/// published, so a support report could not corroborate the address a phone was failing against.
final class MacAdvertisedOriginDiagnosticsTests: XCTestCase {

    func testTheAdvertisedOriginIsRecordedAsAHashRatherThanAnAddress() {
        let origin = URL(string: "https://calm-forest-1234.trycloudflare.com")!
        let digest = MacRemoteDiagnostics.originDigest(origin)

        XCTAssertTrue(digest.hasPrefix("origin-"))
        XCTAssertFalse(digest.contains("trycloudflare"))
        XCTAssertFalse(digest.contains("calm-forest"))
        XCTAssertEqual(digest, MacRemoteDiagnostics.originDigest(origin))
    }

    func testTheHashIgnoresPathAndFragmentAndSeparatesRealOrigins() {
        let plain = URL(string: "https://mac.ts.net:8443")!
        let decorated = URL(string: "https://mac.ts.net:8443/api/me#BEARER")!
        let other = URL(string: "https://other.ts.net:8443")!

        XCTAssertEqual(
            MacRemoteDiagnostics.originDigest(plain),
            MacRemoteDiagnostics.originDigest(decorated)
        )
        XCTAssertNotEqual(
            MacRemoteDiagnostics.originDigest(plain),
            MacRemoteDiagnostics.originDigest(other)
        )
    }

    /// Both sides derive the same value from the same origin, which is what lets a joined report
    /// say whether the phone was pointed at the address this Mac published.
    func testTheHostAndTheClientCanonicaliseAnOriginTheSameWay() {
        XCTAssertEqual(
            RemoteOriginIdentity.canonical(URL(string: "HTTPS://Mac.TS.net:8443/api")!),
            "https://mac.ts.net:8443"
        )
        XCTAssertEqual(
            RemoteOriginIdentity.canonical(URL(string: "https://mac.ts.net")!),
            "https://mac.ts.net:default"
        )
    }
}

/// What a switch on the Remote Access page is allowed to start.
///
/// The page used to offer a *mode*, and two of its rows existed only to start the public relay:
/// one let owner devices fall back to it, the other kept it warm for a share nobody had created.
/// Neither survives, because a Quick Tunnel address changes every launch and cannot be an owner
/// route. The relay now has exactly one trigger left, and it is not on this page: creating a
/// one-chat guest link.
///
/// Driven through the injected transports rather than through `relayRequired` alone, because the
/// question is not whether the policy says no. It is whether anything in the lifecycle reaches
/// `cloudflared` anyway.
@MainActor
final class RemoteAccessDoorTransportTests: HostedStoreTestCase {

    private var suiteNames: [String] = []
    private var coordinators: [RemoteAccessCoordinator] = []

    override func tearDown() async throws {
        await MainActor.run {
            for coordinator in coordinators { coordinator.stop() }
            coordinators.removeAll()
            for name in suiteNames {
                UserDefaults().removePersistentDomain(forName: name)
            }
            suiteNames.removeAll()
        }
        try await super.tearDown()
    }

    func testNoSwitchOnThePageStartsTheRelay() throws {
        let relay = RecordingRelayTransport()
        let tailnet = RecordingTailnetTransport()
        let settings = isolatedAppSettings()
        // A port nothing else on this machine is holding, so the test never fights the app the
        // developer is running on the shipped default.
        settings.remoteAccessListenerPort = try XCTUnwrap(FreeLocalPort.quiet())
        settings.remoteAccessDoors = []
        settings.remoteAccessTailscaleEnabled = false
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: settings,
            guestShareStore: InMemoryRemoteGuestShareStore(shares: []),
            relayTransport: relay,
            tailnetTransport: tailnet
        )
        coordinators.append(coordinator)

        coordinator.setEnabled(true)
        waitForListening(coordinator)
        XCTAssertEqual(relay.startedPorts, [], "the master switch started the relay")
        XCTAssertEqual(tailnet.startedPorts, [], "a way in that is off started its transport")

        // The tailnet switch starts what that way in is made of, and nothing else.
        coordinator.setTailscaleDoorEnabled(true)
        XCTAssertEqual(tailnet.startedPorts.count, 1)
        XCTAssertEqual(relay.startedPorts, [], "the tailnet switch started the relay")

        // The reserved browser convenience is stored and starts nothing at all.
        coordinator.setTailscaleServeEnabled(true)
        XCTAssertTrue(settings.remoteAccessTailscaleServeEnabled)
        XCTAssertEqual(relay.startedPorts, [], "the Serve sub-option started the relay")

        // And the network way in is the listener's own business.
        coordinator.setDoors([.lan])
        XCTAssertEqual(relay.startedPorts, [], "This network started the relay")

        coordinator.setTailscaleDoorEnabled(false)
        XCTAssertGreaterThan(tailnet.stopCount, 0, "switching the tailnet off left it running")
        XCTAssertEqual(relay.startedPorts, [], "switching a way in off started the relay")
    }

    /// The seam under the tailnet switch. Swapping the implementation is what §8 of the transport
    /// plan does, and it must not need the settings page to change.
    func testTheTailnetSwitchRunsWhicheverImplementationTheBuildCarries() throws {
        let relay = RecordingRelayTransport()
        let tailnet = RecordingTailnetTransport()
        let settings = isolatedAppSettings()
        settings.remoteAccessListenerPort = try XCTUnwrap(FreeLocalPort.quiet())
        settings.remoteAccessDoors = []
        settings.remoteAccessTailscaleEnabled = true
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: settings,
            guestShareStore: InMemoryRemoteGuestShareStore(shares: []),
            relayTransport: relay,
            tailnetTransport: tailnet,
            tailscaleDoor: .listenerDoor
        )
        coordinators.append(coordinator)

        coordinator.setEnabled(true)
        waitForListening(coordinator)

        // With the raw bind carrying the door, Serve is not started at all: the listener set is
        // what answers on the tailnet.
        XCTAssertEqual(
            tailnet.startedPorts, [],
            "the Serve transport ran for a build whose tailnet door is a listener"
        )
        XCTAssertEqual(relay.startedPorts, [])
        XCTAssertEqual(
            RemoteTailscaleDoorImplementation.current,
            .serveTransport,
            "the shipped implementation changed without the page being reviewed again"
        )
    }

    /// Spins the run loop until the listener has answered. `start` completes on main, so a plain
    /// `await` would never let it in.
    private func waitForListening(
        _ coordinator: RemoteAccessCoordinator,
        timeout: TimeInterval = 5
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .listening = coordinator.status { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("the listener never reported itself listening: \(coordinator.status)")
    }

    private func isolatedAppSettings() -> AppSettings {
        let name = "RemoteAccessDoorTransportTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.register(defaults: AppSettingDefinitions.registeredDefaults)
        return AppSettings(defaults: defaults)
    }
}
