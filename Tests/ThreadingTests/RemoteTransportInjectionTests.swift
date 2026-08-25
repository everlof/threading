import XCTest
@testable import Threading

/// The `tailscale` CLI seam. `start` is Tailscale Serve, not the tailnet door: the door is a
/// listener, so a test that turns it on must see nothing started here at all.
@MainActor
final class RecordingTailnetTransport: RemoteTailnetTransport {
    private(set) var startedPorts: [UInt16] = []
    private(set) var stopCount = 0
    private(set) var factsRefreshes = 0
    var readiness: TailscaleReadiness = .notChecked
    var hostFacts: TailscaleHostFacts = .unknown
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

    func refreshHostFacts() {
        factsRefreshes += 1
    }
}

@MainActor
private final class RecordingRemoteAccessProcessActivity: RemoteAccessProcessActivityManaging {
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func begin() { beginCount += 1 }
    func end() { endCount += 1 }
}

/// The seam that keeps a test run from publishing the developer's Mac.
///
/// `RemoteAccessCoordinator` used to build its transports itself, with the shipping executable
/// locators, so any test that reached one launched a real child. Orphans of exactly that shape
/// were still alive on this machine when the transport plan was written, because nothing in the
/// test run owned them.
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
        XCTAssertEqual(transport.readiness, .notChecked)
    }

    func testCoordinatorDrivesTheInjectedTransportAndNotItsOwn() {
        let tailnet = RecordingTailnetTransport()
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: isolatedAppSettings(),
            guestShareStore: InMemoryRemoteGuestShareStore(shares: []),
            tailnetTransport: tailnet
        )

        XCTAssertEqual(tailnet.startedPorts, [])

        coordinator.stop()

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
        let origin = URL(string: "https://mac-studio.tail1234.ts.net:8443")!
        let digest = MacRemoteDiagnostics.originDigest(origin)

        XCTAssertTrue(digest.hasPrefix("origin-"))
        XCTAssertFalse(digest.contains("ts.net"))
        XCTAssertFalse(digest.contains("mac-studio"))
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
/// The relay is gone and so are they. What is left that can start a child process is the browser
/// convenience, and these are the switches that may and may not reach it.
///
/// Driven through the injected transport rather than through a policy function, because the
/// question is not whether the policy says no. It is whether anything in the lifecycle starts a
/// child anyway.
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

    func testOnlyTheBrowserConvenienceStartsAChild() throws {
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
            tailnetTransport: tailnet
        )
        coordinators.append(coordinator)

        coordinator.setEnabled(true)
        waitForListening(coordinator)
        XCTAssertEqual(tailnet.startedPorts, [], "a way in that is off started its transport")

        // The tailnet switch is a bind. It starts no transport at all: it asks the listener for
        // another door, and asks the CLI what it can say about why that door might not come up.
        coordinator.setTailscaleDoorEnabled(true)
        XCTAssertEqual(
            tailnet.startedPorts, [],
            "the tailnet way in started Tailscale Serve, which no phone uses"
        )
        XCTAssertGreaterThan(tailnet.factsRefreshes, 0, "the door was switched on unexplained")

        // The browser convenience is the one thing that does start Serve.
        coordinator.setTailscaleServeEnabled(true)
        XCTAssertTrue(settings.remoteAccessTailscaleServeEnabled)
        XCTAssertEqual(tailnet.startedPorts.count, 1, "the Serve sub-option started nothing")

        // And the network way in is the listener's own business: a door is a bind, so switching
        // one on starts nothing that could outlive the app.
        coordinator.setDoors([.lan])
        XCTAssertEqual(
            tailnet.startedPorts.count, 1,
            "This network started a second child of somebody else's transport"
        )

        coordinator.setTailscaleServeEnabled(false)
        XCTAssertGreaterThan(tailnet.stopCount, 0, "switching Serve off left it running")
    }

    func testRemoteAccessPreventsAppNapOnlyWhileItsListenerIsAvailable() throws {
        let activity = RecordingRemoteAccessProcessActivity()
        let settings = isolatedAppSettings()
        settings.remoteAccessListenerPort = try XCTUnwrap(FreeLocalPort.quiet())
        settings.remoteAccessDoors = []
        settings.remoteAccessTailscaleEnabled = false
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: settings,
            guestShareStore: InMemoryRemoteGuestShareStore(shares: []),
            tailnetTransport: RecordingTailnetTransport(),
            processActivity: activity
        )
        coordinators.append(coordinator)

        coordinator.setEnabled(true)
        waitForListening(coordinator)
        XCTAssertEqual(activity.beginCount, 1)
        XCTAssertEqual(activity.endCount, 0)

        coordinator.setEnabled(true)
        XCTAssertEqual(activity.beginCount, 1, "an already-live listener duplicated its activity")

        coordinator.stop()
        XCTAssertEqual(activity.endCount, 1)
    }

    /// The sub-option and the door are independent in both directions, which is the whole claim
    /// behind "the Threading app does not need this": Serve is a browser convenience, so it
    /// neither follows the door nor takes a route away when it stops.
    func testServeRunsAndStopsWithoutTouchingTheTailnetDoor() throws {
        let tailnet = RecordingTailnetTransport()
        let settings = isolatedAppSettings()
        settings.remoteAccessListenerPort = try XCTUnwrap(FreeLocalPort.quiet())
        settings.remoteAccessDoors = []
        settings.remoteAccessTailscaleEnabled = false
        settings.remoteAccessTailscaleServeEnabled = true
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: settings,
            guestShareStore: InMemoryRemoteGuestShareStore(shares: []),
            tailnetTransport: tailnet
        )
        coordinators.append(coordinator)

        coordinator.setEnabled(true)
        waitForListening(coordinator)

        // Serve is on and the tailnet door is off: it publishes anyway, because a browser on the
        // tailnet is a different audience from the phone.
        XCTAssertEqual(tailnet.startedPorts.count, 1)
        XCTAssertFalse(coordinator.isTailscaleDoorEnabled)

        // Turning the door on does not start a second one, and turning Serve off does not take
        // the door with it.
        coordinator.setTailscaleDoorEnabled(true)
        XCTAssertEqual(tailnet.startedPorts.count, 1)
        let stopsBefore = tailnet.stopCount
        coordinator.setTailscaleServeEnabled(false)
        XCTAssertGreaterThan(tailnet.stopCount, stopsBefore)
        XCTAssertTrue(coordinator.isTailscaleDoorEnabled, "stopping Serve closed the door")
    }

    /// The seam under the tailnet switch. Swapping the implementation is what §8 of the transport
    /// plan did, and it did not need the settings page to change.
    func testTheTailnetSwitchRunsWhicheverImplementationTheBuildCarries() throws {
        let tailnet = RecordingTailnetTransport()
        let settings = isolatedAppSettings()
        settings.remoteAccessListenerPort = try XCTUnwrap(FreeLocalPort.quiet())
        settings.remoteAccessDoors = []
        settings.remoteAccessTailscaleEnabled = true
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: settings,
            guestShareStore: InMemoryRemoteGuestShareStore(shares: []),
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
        XCTAssertEqual(
            RemoteTailscaleDoorImplementation.current,
            .listenerDoor,
            "the shipped implementation changed without the page being reviewed again"
        )
    }

    /// The other side of the same seam: a build pinned to the old Serve handler still runs it,
    /// and still keeps the tailnet out of the listener's door set.
    func testABuildPinnedToServeStillRunsServeForItsDoor() throws {
        let tailnet = RecordingTailnetTransport()
        let settings = isolatedAppSettings()
        settings.remoteAccessListenerPort = try XCTUnwrap(FreeLocalPort.quiet())
        settings.remoteAccessDoors = []
        settings.remoteAccessTailscaleEnabled = true
        let coordinator = RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: settings,
            guestShareStore: InMemoryRemoteGuestShareStore(shares: []),
            tailnetTransport: tailnet,
            tailscaleDoor: .serveTransport
        )
        coordinators.append(coordinator)

        coordinator.setEnabled(true)
        waitForListening(coordinator)

        XCTAssertEqual(tailnet.startedPorts.count, 1)
        XCTAssertEqual(
            coordinator.listenerStatus.state(of: .tailscale),
            .off,
            "a Serve build bound the tailnet address as well, which is two doors for one switch"
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

@MainActor
final class RemoteAccessProcessActivityTests: XCTestCase {
    func testShippingActivityPreventsAppNapButAllowsIdleSystemSleep() {
        XCTAssertEqual(
            RemoteAccessProcessActivity.options,
            .userInitiatedAllowingIdleSystemSleep
        )
    }

    func testActivityIsIdempotentAndEndsItsTokenOnDeinit() {
        var beginCount = 0
        var endedTokens: [NSObject] = []
        var activity: RemoteAccessProcessActivity? = RemoteAccessProcessActivity(
            beginActivity: {
                beginCount += 1
                return NSObject()
            },
            endActivity: { token in
                endedTokens.append(token as! NSObject)
            }
        )

        activity?.begin()
        activity?.begin()
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(endedTokens.count, 0)

        activity = nil
        XCTAssertEqual(endedTokens.count, 1)
    }
}
