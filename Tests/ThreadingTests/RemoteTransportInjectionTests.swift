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
