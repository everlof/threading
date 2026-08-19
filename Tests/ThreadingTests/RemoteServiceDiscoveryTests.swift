import Network
import SystemConfiguration
import ThreadingRemoteKit
import XCTest
import os
@testable import Threading

/// What this Mac broadcasts when it advertises its LAN door, and what it must never broadcast.
///
/// A Bonjour advertisement is the one part of remote access that goes out unasked, to everyone on
/// the network, before any authentication exists. So the assertions here are mostly about what is
/// *not* in it: no computer name, no user name, and no key beyond the three the phone reads.
///
/// The registrations are recorded rather than published. A hosted test runs inside the shipping
/// app, so a real registration here would announce the developer's own Mac on whatever network it
/// is on and could outlive the test; `RemoteServiceAdvertisers.standard()` returns an inert
/// advertiser under XCTest for that reason, and these tests inject a recorder to see the value.
@MainActor
final class RemoteServiceDiscoveryTests: HostedStoreTestCase {

    /// A LAN address the test can bind. `::1` is assignable on every Mac, and the door rules
    /// classify by interface name, so an address reported on `en9` is the LAN door's whatever the
    /// address is. That keeps the test off the developer's real Wi-Fi.
    private static let lanAddress = RemoteNetworkAddress(
        interfaceName: "en9",
        address: "::1",
        isIPv6: true
    )
    private static let tailscaleAddress = RemoteNetworkAddress(
        interfaceName: "utun9",
        address: "100.100.1.1"
    )
    private static let hostID = "11111111-2222-3333-4444-555555555555"

    /// Every registration and withdrawal, in order.
    private final class RecordingAdvertiser: RemoteServiceAdvertising, @unchecked Sendable {
        private let storage = OSAllocatedUnfairLock<[RemoteServiceRegistration?]>(initialState: [])

        var applied: [RemoteServiceRegistration?] { storage.withLock { $0 } }
        var current: RemoteServiceRegistration? { storage.withLock { $0.last ?? nil } }
        var registrations: [RemoteServiceRegistration] { applied.compactMap { $0 } }
        var withdrawals: Int { applied.filter { $0 == nil }.count }

        func apply(_ registration: RemoteServiceRegistration?, to listener: NWListener?) {
            storage.withLock { $0.append(registration) }
        }
    }

    private var server: RemoteAccessServer!
    private var advertiser: RecordingAdvertiser!
    private var identityStore: RemoteAccessIdentityStore!
    private var identityDirectory: URL!
    private var appSettings: AppSettings!
    private var appSettingsDefaults: UserDefaults!
    private var appSettingsSuiteName: String!
    private let addresses = OSAllocatedUnfairLock<[RemoteNetworkAddress]>(initialState: [])
    private var journalled: [RemoteDiagnosticEvent] {
        journalStorage.withLock { $0 }
    }
    private let journalStorage =
        OSAllocatedUnfairLock<[RemoteDiagnosticEvent]>(initialState: [])
    private let journalFields =
        OSAllocatedUnfairLock<[[RemoteDiagnosticField: String]]>(initialState: [])

    override func setUp() {
        super.setUp()
        appSettingsSuiteName = "RemoteServiceDiscoveryTests.\(UUID().uuidString)"
        appSettingsDefaults = UserDefaults(suiteName: appSettingsSuiteName)!
        appSettings = AppSettings(defaults: appSettingsDefaults)
        addresses.withLock { $0 = [Self.lanAddress, Self.tailscaleAddress] }
        journalStorage.withLock { $0 = [] }
        journalFields.withLock { $0 = [] }
        let source = addresses
        let identity = RemoteIdentityTestStore.make(label: "RemoteServiceDiscoveryTests")
        identityStore = identity.store
        identityDirectory = identity.directory
        advertiser = RecordingAdvertiser()
        server = RemoteAccessServer(
            services: RemoteAccessCoordinator.makeServerServices(appSettings: appSettings),
            addressSource: { source.withLock { $0 } },
            identityProvider: identity.store,
            advertiser: advertiser,
            hostIDSource: { Self.hostID }
        )
        let events = journalStorage
        let fields = journalFields
        server.recordListenerDiagnostic = { event, _, recorded in
            events.withLock { $0.append(event) }
            fields.withLock { $0.append(recorded) }
        }
    }

    override func tearDown() {
        // `stop()` withdraws before it cancels the listeners, so nothing is left announced.
        server?.stop()
        server = nil
        advertiser = nil
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

    // MARK: - Which doors are advertised

    /// The LAN door is the only one whose addresses are announced. Loopback reaches this Mac
    /// alone, and multicast does not cross the tunnel a tailnet or VPN address lives on, so an
    /// advertisement there would be a broadcast to nobody that is still a broadcast.
    func testOnlyTheLanDoorIsAdvertisedOverBonjour() {
        XCTAssertEqual(
            RemoteAccessDoor.allCases.filter(\.isAdvertisedOverBonjour),
            [.lan]
        )
    }

    func testTheLoopbackOnlyDefaultAnnouncesNothing() throws {
        let port = try quietPort()

        XCTAssertEqual(start(configuration(port: port)), .listening(port: port))

        XCTAssertNil(server.advertisedService, "no routable door is on, so nothing is announced")
        XCTAssertTrue(advertiser.registrations.isEmpty)
        XCTAssertFalse(journalled.contains(.hostDiscoveryRegistered))
    }

    func testTheLanDoorRegistersOneServiceOnItsOwnPort() throws {
        let port = try quietPort()
        XCTAssertEqual(start(configuration(port: port, doors: [.lan])), .listening(port: port))

        waitUntil("the service is registered") { self.server.advertisedService != nil }
        let registration = try XCTUnwrap(server.advertisedService)

        XCTAssertEqual(registration.type, RemoteDiscoveryDefaults.serviceType)
        XCTAssertEqual(registration.domain, RemoteDiscoveryDefaults.serviceDomain)
        XCTAssertEqual(
            registration.port,
            port,
            "the announced port is the port the LAN door actually took"
        )
        XCTAssertEqual(
            advertiser.registrations.count,
            1,
            "one registration for the host, not one per LAN address: the SRV record names this "
                + "Mac's .local name and the addresses behind it already cover every interface"
        )
        XCTAssertTrue(journalled.contains(.hostDiscoveryRegistered))
    }

    /// The registration follows what is *bound*, not what was selected. A LAN door with no
    /// address on it announces a port nothing answers on, which is worse than silence.
    func testALanDoorWithNoAddressAnnouncesNothing() throws {
        let port = try quietPort()
        addresses.withLock { $0 = [Self.tailscaleAddress] }

        XCTAssertEqual(start(configuration(port: port, doors: [.lan])), .listening(port: port))

        XCTAssertEqual(server.listenerStatus.state(of: .lan), .notReachable(.noInterface))
        XCTAssertNil(server.advertisedService)
        XCTAssertTrue(advertiser.registrations.isEmpty)
    }

    // MARK: - The instance name

    /// `NWListener.Service(name: nil, …)` advertises under the computer name, which usually
    /// contains the user's own name. The name is therefore explicit, opaque, and derived from the
    /// host id — which the TXT record carries anyway, so the name discloses nothing further.
    func testTheInstanceNameNamesNeitherThisMacNorItsUser() throws {
        let port = try quietPort()
        XCTAssertEqual(start(configuration(port: port, doors: [.lan])), .listening(port: port))
        waitUntil("the service is registered") { self.server.advertisedService != nil }
        let name = try XCTUnwrap(server.advertisedService?.name).lowercased()

        var forbidden: [String] = [NSFullUserName(), NSUserName()]
        if let localized = Host.current().localizedName { forbidden.append(localized) }
        if let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            forbidden.append(computer)
        }
        for candidate in forbidden where candidate.count > 2 {
            XCTAssertFalse(
                name.contains(candidate.lowercased()),
                "the advertised name must not contain \(candidate)"
            )
        }

        XCTAssertEqual(
            name,
            RemoteDiscoveryDefaults.instanceName(hostID: Self.hostID).lowercased(),
            "the name is derived from the host id and from nothing else"
        )
        XCTAssertTrue(
            server.advertisedService?.name.allSatisfy {
                RemoteHostPinningDefaults.base32Alphabet.contains($0)
            } == true,
            "base32 upper case, so a DNS label never has to be escaped"
        )
    }

    func testTheInstanceNameIsStablePerHostAndDiffersBetweenHosts() {
        let first = RemoteDiscoveryDefaults.instanceName(hostID: Self.hostID)

        XCTAssertEqual(
            first,
            RemoteDiscoveryDefaults.instanceName(hostID: Self.hostID),
            "a name that moved would leave stale registrations and make one Mac look like two"
        )
        XCTAssertNotEqual(first, RemoteDiscoveryDefaults.instanceName(hostID: "another-mac"))
        XCTAssertEqual(first.count, 16, "10 bytes of digest, far inside a 63-byte DNS label")
    }

    // MARK: - The TXT record

    func testTheTXTRecordCarriesTheHostProtocolAndFingerprintAndNothingElse() throws {
        let port = try quietPort()
        XCTAssertEqual(start(configuration(port: port, doors: [.lan])), .listening(port: port))
        waitUntil("the service is registered") { self.server.advertisedService != nil }
        let registration = try XCTUnwrap(server.advertisedService)
        let expected = try XCTUnwrap(identityStore.snapshot.fingerprint)

        XCTAssertEqual(
            Set(registration.advertisement.txtDictionary.keys),
            ["id", "v", "fp"],
            "the payload is the whole disclosure surface, so a fourth key is a decision, not a "
                + "detail"
        )
        XCTAssertEqual(registration.advertisement.txtDictionary["id"], Self.hostID)
        XCTAssertEqual(
            registration.advertisement.txtDictionary["v"],
            String(RemoteProtocol.current)
        )
        XCTAssertEqual(registration.advertisement.txtDictionary["fp"], expected.hex)
        XCTAssertEqual(
            registration.advertisement.txtDictionary["fp"],
            expected.hex.lowercased(),
            "the wire spelling is lower-case hex, the same one /api/me carries"
        )
    }

    /// One TXT entry is length-prefixed by a single byte, so 255 is its ceiling; RFC 6763 asks
    /// for the whole record to stay small enough for one response. The full 64-character
    /// fingerprint fits with room to spare, which is why it is not truncated: a shortened
    /// fingerprint would be a pin that matches more than one certificate.
    func testTheRecordFitsTheTXTLimitsWithTheWholeFingerprint() throws {
        let advertisement = RemoteHostAdvertisement(
            hostID: UUID().uuidString.lowercased(),
            protocolVersion: RemoteProtocol.current,
            fingerprint: try XCTUnwrap(RemoteHostFingerprint(digest: Data(repeating: 0xAB, count: 32)))
        )

        XCTAssertTrue(advertisement.fitsTXTLimits)
        XCTAssertLessThanOrEqual(
            advertisement.txtRecordByteCount,
            RemoteDiscoveryDefaults.recommendedTXTRecordBytes
        )
        for entry in advertisement.txtEntries {
            XCTAssertLessThanOrEqual(
                "\(entry.key)=\(entry.value)".utf8.count,
                RemoteDiscoveryDefaults.maximumTXTEntryBytes
            )
        }
        XCTAssertEqual(advertisement.txtDictionary["fp"]?.count, 64)
    }

    func testAnAdvertisementRoundTripsAndAnUnknownKeyIsRefused() throws {
        let advertisement = RemoteHostAdvertisement(
            hostID: Self.hostID,
            protocolVersion: RemoteProtocol.current,
            fingerprint: try XCTUnwrap(RemoteHostFingerprint(digest: Data(repeating: 0x01, count: 32)))
        )

        XCTAssertEqual(RemoteHostAdvertisement.parse(txt: advertisement.txtDictionary), advertisement)

        var extra = advertisement.txtDictionary
        extra["name"] = "David's MacBook Pro"
        XCTAssertNil(
            RemoteHostAdvertisement.parse(txt: extra),
            "a record carrying more than the three known keys is not one this build made"
        )

        var missing = advertisement.txtDictionary
        missing["fp"] = nil
        XCTAssertNil(RemoteHostAdvertisement.parse(txt: missing))

        var malformed = advertisement.txtDictionary
        malformed["fp"] = "not-a-fingerprint"
        XCTAssertNil(RemoteHostAdvertisement.parse(txt: malformed))
    }

    // MARK: - Turning it off, and rotation

    func testTurningDiscoveryOffWithdrawsAndTurningItOnRegistersAgain() throws {
        let port = try quietPort()
        XCTAssertEqual(start(configuration(port: port, doors: [.lan])), .listening(port: port))
        waitUntil("the service is registered") { self.server.advertisedService != nil }

        server.updateDiscovery(isEnabled: false)
        waitUntil("the service is withdrawn") { self.server.advertisedService == nil }
        XCTAssertEqual(advertiser.withdrawals, 1)
        XCTAssertTrue(journalled.contains(.hostDiscoveryWithdrawn))
        XCTAssertEqual(
            server.listenerStatus.state(of: .lan).bindings.count,
            1,
            "the announcement stopped; the door did not close"
        )

        server.updateDiscovery(isEnabled: true)
        waitUntil("the service is registered again") { self.server.advertisedService != nil }
        XCTAssertEqual(advertiser.registrations.count, 2)
    }

    func testRotatingTheIdentityReAdvertisesWithTheNewFingerprint() throws {
        let port = try quietPort()
        XCTAssertEqual(start(configuration(port: port, doors: [.lan])), .listening(port: port))
        waitUntil("the service is registered") { self.server.advertisedService != nil }
        let before = try XCTUnwrap(server.advertisedService?.advertisement.fingerprint)

        XCTAssertNoThrow(try identityStore.prepareRotation().get())
        XCTAssertNoThrow(try identityStore.activateRotation().get())
        server.reloadIdentity()

        waitUntil("the new fingerprint is announced") {
            self.server.advertisedService?.advertisement.fingerprint != before
        }
        let after = try XCTUnwrap(server.advertisedService?.advertisement.fingerprint)
        XCTAssertEqual(after, identityStore.snapshot.fingerprint)
        XCTAssertEqual(
            server.advertisedService?.name,
            RemoteDiscoveryDefaults.instanceName(hostID: Self.hostID),
            "the name is the Mac, not the certificate, so a rotation is not a new machine"
        )
        XCTAssertEqual(server.advertisedService?.port, port, "and the port does not move")
    }

    /// A Wi-Fi change rebuilds the LAN listeners, and the registration lives on a socket. Left
    /// alone it would die with the listener it was applied to while the published value still
    /// claimed the Mac was announcing itself.
    func testTheRegistrationIsReAppliedWhenItsListenerIsRebuilt() throws {
        let port = try quietPort()
        XCTAssertEqual(start(configuration(port: port, doors: [.lan])), .listening(port: port))
        waitUntil("the service is registered") { self.server.advertisedService != nil }
        let firstListener = server.listenerIdentities[Self.lanAddress]
        XCTAssertEqual(advertiser.registrations.count, 1)

        // The address goes away and comes back, which is what a Wi-Fi change looks like.
        addresses.withLock { $0 = [Self.tailscaleAddress] }
        server.refreshListenerAddresses()
        waitUntil("the door reports no interface") {
            self.server.listenerStatus.state(of: .lan) == .notReachable(.noInterface)
        }
        XCTAssertNil(server.advertisedService, "an absent door announces nothing")

        addresses.withLock { $0 = [Self.lanAddress, Self.tailscaleAddress] }
        server.refreshListenerAddresses()
        waitUntil("the service is registered again") { self.server.advertisedService != nil }

        XCTAssertNotEqual(
            server.listenerIdentities[Self.lanAddress],
            firstListener,
            "the fixture only proves anything if the listener really was replaced"
        )
        XCTAssertEqual(
            advertiser.registrations.count,
            2,
            "the registration follows the socket that carries it"
        )
        XCTAssertEqual(advertiser.applied.last??.port, port)
    }

    // MARK: - The journal

    /// An advertisement is exactly the disclosure a support report must not repeat. The journal
    /// says the LAN door started being announced and carries a hash of the addresses behind it.
    func testTheJournalRecordsTheOriginAsAHashAndNamesNoAddress() throws {
        let port = try quietPort()
        XCTAssertEqual(start(configuration(port: port, doors: [.lan])), .listening(port: port))
        waitUntil("the service is registered") { self.server.advertisedService != nil }

        let recorded = journalFields.withLock { $0 }
        let indexed = zip(journalled, recorded).first { $0.0 == .hostDiscoveryRegistered }
        let fields = try XCTUnwrap(indexed?.1)

        let origin = try XCTUnwrap(fields[.origin])
        XCTAssertTrue(origin.hasPrefix("origin-"))
        XCTAssertFalse(origin.contains(Self.lanAddress.address))
        XCTAssertFalse(origin.contains(Self.lanAddress.interfaceName))
        for value in fields.values {
            XCTAssertFalse(
                value.contains(RemoteDiscoveryDefaults.instanceName(hostID: Self.hostID)),
                "the instance name is broadcast on the network and still stays out of a report"
            )
        }
    }

    // MARK: - Wake on Demand

    /// "Can wake this Mac" is only claimable when both inputs hold: with "Wake for network
    /// access" off macOS never registers with a proxy, and with no proxy on the network there is
    /// nothing to answer for a sleeping Mac. Unknown is never yes.
    func testWakingIsClaimedOnlyWhenBothFactsHold() {
        func facts(_ womp: Bool?, _ proxy: Bool?) -> RemoteWakeOnDemandFacts {
            RemoteWakeOnDemandFacts(
                wakeForNetworkAccess: womp,
                sleepProxyPresent: proxy,
                readAt: Date()
            )
        }

        XCTAssertTrue(facts(true, true).canWakeThisMac)
        XCTAssertFalse(facts(true, false).canWakeThisMac)
        XCTAssertFalse(facts(false, true).canWakeThisMac)
        XCTAssertFalse(facts(nil, true).canWakeThisMac)
        XCTAssertFalse(facts(true, nil).canWakeThisMac)
        XCTAssertFalse(RemoteWakeOnDemandFacts.unknown.canWakeThisMac)
    }

    func testWakeForNetworkAccessIsReadFromThePowerSettings() {
        let on = """
         hibernatefile        /var/vm/sleepimage
         networkoversleep     0
         disksleep            0
         womp                 1
        """
        let off = on.replacingOccurrences(of: "womp                 1", with: "womp                 0")

        XCTAssertEqual(RemoteWakeOnDemandProbe.wakeForNetworkAccess(from: on), true)
        XCTAssertEqual(RemoteWakeOnDemandProbe.wakeForNetworkAccess(from: off), false)
        XCTAssertNil(
            RemoteWakeOnDemandProbe.wakeForNetworkAccess(from: " disksleep            0"),
            "a machine that does not report the setting leaves the fact unknown, not false"
        )
        XCTAssertNil(RemoteWakeOnDemandProbe.wakeForNetworkAccess(from: nil))
    }

    // MARK: - Helpers

    private func configuration(
        port: UInt16,
        doors: Set<RemoteAccessDoor> = []
    ) -> RemoteListenerConfiguration {
        RemoteListenerConfiguration(preferredPort: port, doors: doors, isDiscoveryEnabled: true)
    }

    @discardableResult
    private func start(_ configuration: RemoteListenerConfiguration) -> RemoteListenerStartOutcome? {
        var result: RemoteListenerStartOutcome?
        let ready = expectation(description: "listener answered")
        server.start(configuration: configuration) { outcome in
            result = outcome
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        return result
    }

    private func quietPort() throws -> UInt16 {
        guard let port = FreeLocalPort.quiet() else {
            throw XCTSkip("No free port in the quiet range")
        }
        return port
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
        wait(for: [met], timeout: 5)
        poll.invalidate()
        XCTAssertTrue(condition(), description, file: file, line: line)
    }
}

// **The real Bonjour round trip is a manual check, not a test here, and the reason is the
// finding.**
//
// A hosted test runs inside Threading.app, and macOS 15 brought iOS's local network privacy to
// the Mac: TN3179's table says every Bonjour operation needs the privilege, registering
// included. `xcodebuild test` starts the app through testmanagerd rather than as a child of the
// shell, so the Terminal exemption does not apply, the app's privilege is undetermined, and the
// registration is **silently blocked** — no alert, no error, no `add`. Measured on macOS 26.5:
// a round trip written against these same types registered nothing and found nothing in 30
// seconds, three runs out of three, while the identical `NWListener.Service` sequence in a
// Terminal-run binary registered in about 0.7 seconds and was browsable immediately.
//
// So the mechanism is checked by hand, with the app the user actually runs:
//
// 1. Turn Remote Access on with the `lan` door selected
//    (`defaults write codes.threading remoteAccessDoors -array lan`).
// 2. `dns-sd -B _threading._tcp` on the same Mac or another machine on the network. The
//    instance name is the 16-character opaque token, never the computer name.
// 3. `dns-sd -L <name> _threading._tcp local.` shows the port and the TXT record: `id`, `v`,
//    `fp` and nothing else.
// 4. Turn discovery off in Settings and watch the browse report the removal.
//
// Everything above this line asserts what would be published, which is the part that can be
// wrong in a way a person would not notice.
