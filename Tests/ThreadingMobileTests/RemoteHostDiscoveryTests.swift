import Foundation
import Network
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// Finding a paired Mac on this network, and refusing to find anything else.
///
/// Discovery is the one path where a stranger's broadcast reaches this phone's pairing logic, so
/// most of these tests are about what it must *not* do: an unpaired Mac advertising the same
/// service type is ignored, a matching host id with the wrong fingerprint is ignored, a guest
/// capability never matches, and nothing anywhere learns a pin.
@MainActor
final class RemoteHostDiscoveryTests: XCTestCase {

    private static let bearer = String(repeating: "a", count: 43)
    private static let certificate = Data("this Mac's certificate".utf8)
    private static let successor = Data("the certificate this Mac will present next".utf8)
    private static let strangerCertificate = Data("somebody else's Mac".utf8)

    private var fingerprint: RemoteHostFingerprint {
        RemoteHostFingerprint(certificateDER: Self.certificate)
    }
    private var nextFingerprint: RemoteHostFingerprint {
        RemoteHostFingerprint(certificateDER: Self.successor)
    }
    private var strangerFingerprint: RemoteHostFingerprint {
        RemoteHostFingerprint(certificateDER: Self.strangerCertificate)
    }

    private var discovery: RemoteHostDiscovery?

    override func tearDown() {
        // A browse is a live multicast listener. Nothing may outlive the test that started it.
        discovery?.stop()
        discovery = nil
        super.tearDown()
    }

    // MARK: - Matching

    func testAServiceWhoseFingerprintMatchesAPairedMacIsThatMac() throws {
        let host = try pairedHost()

        let match = RemoteDiscoveryMatch.pairedHost(
            for: advertisement(hostID: "mac-1", fingerprint: fingerprint),
            in: [host]
        )

        XCTAssertEqual(match?.id, host.id)
    }

    /// The whole promise of §6: discovery finds a *known* Mac's current address and never
    /// acquires a new one. Pairing stays QR-only.
    func testAnUnpairedMacAdvertisingTheSameServiceTypeIsIgnored() throws {
        let host = try pairedHost()

        XCTAssertNil(
            RemoteDiscoveryMatch.pairedHost(
                for: advertisement(hostID: "some-other-mac", fingerprint: strangerFingerprint),
                in: [host]
            ),
            "an unpaired Mac is exactly a fingerprint this phone holds no pin for"
        )
        XCTAssertNil(
            RemoteDiscoveryMatch.pairedHost(
                for: advertisement(hostID: "mac-1", fingerprint: strangerFingerprint),
                in: [host]
            ),
            "claiming a paired Mac's id with another certificate must not be a match either"
        )
    }

    func testAPhoneWithNoPairedMacMatchesNothing() {
        XCTAssertNil(
            RemoteDiscoveryMatch.pairedHost(
                for: advertisement(hostID: "mac-1", fingerprint: fingerprint),
                in: []
            )
        )
    }

    /// A one-chat capability is not the owner of the Mac. It holds no pin, and it must not be
    /// handed an address because something on the network claimed a fingerprint.
    func testAGuestCapabilityIsNeverAMatch() throws {
        var guest = try pairedHost()
        guest = PairedRemoteHost(
            id: "mac-1:share:chat",
            hostID: "mac-1",
            shareID: "chat",
            scope: "session",
            name: guest.name,
            link: guest.link,
            lastConnectedAt: Date(),
            endpoints: guest.endpoints,
            connectionPolicy: .privateOnly,
            pinnedFingerprint: fingerprint.hex
        )

        XCTAssertNil(
            RemoteDiscoveryMatch.pairedHost(
                for: advertisement(hostID: "mac-1", fingerprint: fingerprint),
                in: [guest]
            )
        )
    }

    /// A record that has only ever seen the QR code holds 128 bits, which is a pin like any
    /// other: the advertised digest is compared against its leading bytes.
    func testARecordHoldingOnlyTheScannedCodeStillMatches() throws {
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            token: Self.bearer,
            pinnedFingerprintCode: fingerprint.pairingCode
        ))
        let host = PairedRemoteHost(
            id: "mac-1",
            hostID: "mac-1",
            shareID: "my-devices",
            scope: "all",
            name: "Mac",
            link: link,
            lastConnectedAt: Date(),
            endpoints: [lanEndpoint("https://192.168.1.42:8760/")],
            connectionPolicy: .privateOnly
        )

        XCTAssertNotNil(host.pinSet)
        XCTAssertEqual(
            RemoteDiscoveryMatch.pairedHost(
                for: advertisement(hostID: "mac-1", fingerprint: fingerprint),
                in: [host]
            )?.id,
            "mac-1"
        )
    }

    /// A successor announced over the pinned channel is accepted beside the current one, so a Mac
    /// that has rotated is still found on the network rather than looking like a stranger.
    func testAnAnnouncedSuccessorIsMatchedToo() throws {
        var host = try pairedHost()
        host.nextPinnedFingerprint = nextFingerprint.hex

        XCTAssertEqual(
            RemoteDiscoveryMatch.pairedHost(
                for: advertisement(hostID: "mac-1", fingerprint: nextFingerprint),
                in: [host]
            )?.id,
            "mac-1"
        )
    }

    /// One Mac can be present twice. The fingerprint is what makes either record a match; the
    /// host id is what decides between them.
    func testTheHostIDDecidesBetweenTwoRecordsPinningTheSameCertificate() throws {
        var first = try pairedHost()
        first = PairedRemoteHost(
            id: "old-record",
            hostID: "mac-0",
            shareID: "my-devices",
            scope: "all",
            name: "Mac",
            link: first.link,
            lastConnectedAt: Date(),
            endpoints: first.endpoints,
            connectionPolicy: .privateOnly,
            pinnedFingerprint: fingerprint.hex
        )
        let second = try pairedHost()

        XCTAssertEqual(
            RemoteDiscoveryMatch.pairedHost(
                for: advertisement(hostID: "mac-1", fingerprint: fingerprint),
                in: [first, second]
            )?.id,
            second.id
        )
    }

    // MARK: - What a match changes

    func testADiscoveredAddressIsTriedBeforeTheAdvertisedOnes() throws {
        let host = try pairedHost()
        let discovered = try XCTUnwrap(URL(string: "https://192.168.1.77:8760/"))

        let candidates = host.candidates(preferring: discovered)

        XCTAssertEqual(
            candidates.first?.link.baseURL.host,
            "192.168.1.77",
            "the address the Mac is at now leads; the list it last advertised follows"
        )
        XCTAssertTrue(
            candidates.contains { $0.link.baseURL.host == "192.168.1.42" },
            "and the advertised address stays as the fallback"
        )
        XCTAssertEqual(
            candidates.map(\.link.baseURL).count,
            Set(candidates.map(\.link.baseURL)).count,
            "no address is attempted twice"
        )
    }

    func testADiscoveredAddressThatIsAlreadyAdvertisedDoesNotDuplicateAttempts() throws {
        let host = try pairedHost()
        let same = try XCTUnwrap(URL(string: "https://192.168.1.42:8760/"))

        let withDiscovery = host.candidates(preferring: same)

        XCTAssertEqual(
            withDiscovery.map(\.link.baseURL),
            host.candidates.map(\.link.baseURL),
            "re-finding the address already in use changes nothing"
        )
    }

    func testNoDiscoveryLeavesTheAdvertisedOrderAlone() throws {
        let host = try pairedHost()

        XCTAssertEqual(
            host.candidates(preferring: nil).map(\.link.baseURL),
            host.candidates.map(\.link.baseURL)
        )
    }

    /// The policy still decides. A record that admits no private-network endpoint does not
    /// acquire one because something answered a broadcast.
    func testAPolicyThatRefusesPrivateAddressesRefusesTheDiscoveredOneToo() throws {
        var host = try pairedHost()
        host.connectionPolicy = .relayOnly
        let discovered = try XCTUnwrap(URL(string: "https://192.168.1.77:8760/"))

        XCTAssertFalse(
            host.candidates(preferring: discovered).contains {
                $0.link.baseURL.host == "192.168.1.77"
            }
        )
    }

    /// A discovered address is a new host name, and a pin is registered per host name. Without
    /// this the phone would find the Mac and then have stock evaluation refuse the very
    /// certificate it is paired to.
    func testAMatchPutsTheRecordsExistingPinsInForceForTheNewAddress() throws {
        let delegate = RemoteCertificatePinningDelegate()
        let host = try pairedHost()
        let discovered = try XCTUnwrap(URL(string: "https://192.168.1.77:8760/"))

        let registered = RemoteHostTrust.register(
            discoveredHost: host,
            at: discovered,
            with: delegate
        )

        XCTAssertNotNil(registered)
        XCTAssertEqual(delegate.pins(forHost: "192.168.1.77"), host.pinSet)
        XCTAssertTrue(
            delegate.pins(forHost: "192.168.1.77")?.matches(certificateDER: Self.certificate) == true
        )
        XCTAssertFalse(
            delegate.pins(forHost: "192.168.1.77")?
                .matches(certificateDER: Self.strangerCertificate) == true,
            "the pins put in force are the ones already held, not anything the network said"
        )
    }

    func testARecordWithNoPinRegistersNothingForADiscoveredAddress() throws {
        let delegate = RemoteCertificatePinningDelegate()
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            token: Self.bearer
        ))
        let legacy = PairedRemoteHost(
            id: "mac-1",
            hostID: "mac-1",
            shareID: "my-devices",
            scope: "all",
            name: "Mac",
            link: link,
            lastConnectedAt: Date()
        )

        XCTAssertNil(RemoteHostTrust.register(
            discoveredHost: legacy,
            at: try XCTUnwrap(URL(string: "https://192.168.1.77:8760/")),
            with: delegate
        ))
        XCTAssertNil(delegate.pins(forHost: "192.168.1.77"))
    }

    // MARK: - Bounds

    /// The input is a network full of strangers, so the tracked set has a ceiling rather than a
    /// hope. A café advertising hundreds of services costs a fixed amount of memory.
    func testTrackingIsBoundedWhateverTheNetworkAdvertises() {
        let discovery = RemoteHostDiscovery()
        self.discovery = discovery
        let flood = (0..<200).map { index in
            DiscoveredRemoteService(
                endpoint: .service(
                    name: "SERVICE\(index)",
                    type: RemoteDiscoveryDefaults.serviceType,
                    domain: RemoteDiscoveryDefaults.serviceDomain,
                    interface: nil
                ),
                advertisement: advertisement(
                    hostID: "mac-\(index)",
                    fingerprint: RemoteHostFingerprint(certificateDER: Data("cert-\(index)".utf8))
                )
            )
        }

        discovery.apply(flood)

        XCTAssertEqual(
            discovery.trackedServiceCount,
            RemoteDiscoveryLimits.maximumTrackedServices
        )
        XCTAssertFalse(discovery.isBrowsing, "nothing was started, so nothing is running")
    }

    func testRememberedAddressesAreBoundedAndForgottenWithTheirMac() throws {
        var addresses = RemoteDiscoveredAddresses()
        for index in 0..<(RemoteDiscoveryLimits.maximumTrackedHosts + 4) {
            addresses.record(
                try XCTUnwrap(URL(string: "https://10.0.0.\(index):8760/")),
                forHostRecordID: "mac-\(index)"
            )
        }

        XCTAssertEqual(addresses.count, RemoteDiscoveryLimits.maximumTrackedHosts)
        XCTAssertNil(addresses["mac-0"], "the oldest entry is the one that goes")

        let survivor = "mac-\(RemoteDiscoveryLimits.maximumTrackedHosts + 3)"
        XCTAssertNotNil(addresses[survivor])
        addresses.retain(hostRecordIDs: [])
        XCTAssertEqual(addresses.count, 0, "forgetting a Mac forgets where it was")
    }

    func testRecordingTheSameAddressTwiceReportsNoChange() throws {
        var addresses = RemoteDiscoveredAddresses()
        let url = try XCTUnwrap(URL(string: "https://192.168.1.77:8760/"))

        XCTAssertTrue(addresses.record(url, forHostRecordID: "mac-1"))
        XCTAssertFalse(
            addresses.record(url, forHostRecordID: "mac-1"),
            "a re-announcement at the same address is not news"
        )
        XCTAssertTrue(addresses.record(
            try XCTUnwrap(URL(string: "https://192.168.1.78:8760/")),
            forHostRecordID: "mac-1"
        ))
    }

    /// A Mac that moves says goodbye and announces again. Forgetting the name on the goodbye is
    /// what makes the re-announcement something to resolve rather than something already known
    /// at an address that has stopped existing.
    func testAServiceThatWentAwayIsResolvedAgainWhenItComesBack() {
        let discovery = RemoteHostDiscovery()
        self.discovery = discovery
        let service = DiscoveredRemoteService(
            endpoint: .service(
                name: "OPAQUE",
                type: RemoteDiscoveryDefaults.serviceType,
                domain: RemoteDiscoveryDefaults.serviceDomain,
                interface: nil
            ),
            advertisement: advertisement(hostID: "mac-1", fingerprint: fingerprint)
        )

        discovery.apply([service])
        XCTAssertEqual(discovery.trackedServiceCount, 1)

        discovery.forget(["OPAQUE"])
        XCTAssertEqual(discovery.trackedServiceCount, 0)

        discovery.apply([service])
        XCTAssertEqual(discovery.trackedServiceCount, 1)

        discovery.forgetTracking()
        XCTAssertEqual(
            discovery.trackedServiceCount,
            0,
            "a failed connection clears the tracking so the next announcement is resolved again"
        )
    }

    // MARK: - Starting and stopping

    /// Nothing is browsed for until there is a Mac a discovery could mean, which is also what
    /// keeps iOS from asking for Local Network access before the app has a reason to want it.
    func testBrowsingDoesNotStartWithoutAPairedPinnedMac() throws {
        let discovery = RemoteHostDiscovery()
        self.discovery = discovery

        discovery.start(hosts: [])
        XCTAssertFalse(discovery.isBrowsing)

        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            token: Self.bearer
        ))
        discovery.start(hosts: [PairedRemoteHost(
            id: "mac-1",
            hostID: "mac-1",
            shareID: "my-devices",
            scope: "all",
            name: "Mac",
            link: link,
            lastConnectedAt: Date()
        )])
        XCTAssertFalse(
            discovery.isBrowsing,
            "a record with no pin cannot match an advertisement, so browsing would find nothing"
        )
    }

    func testBrowsingStartsForAPinnedMacAndStopsOnDemand() throws {
        let discovery = RemoteHostDiscovery()
        self.discovery = discovery

        discovery.start(hosts: [try pairedHost()])
        XCTAssertTrue(discovery.isBrowsing)

        discovery.stop()
        XCTAssertFalse(discovery.isBrowsing)
        XCTAssertEqual(discovery.trackedServiceCount, 0)
    }

    // MARK: - Resolution

    func testAResolvedEndpointBecomesAPinnableHTTPSOrigin() {
        let ipv4 = RemoteHostDiscovery.baseURL(
            for: .hostPort(host: .ipv4(.init("192.168.1.77")!), port: 8760)
        )
        XCTAssertEqual(ipv4?.absoluteString, "https://192.168.1.77:8760/")

        let ipv6 = RemoteHostDiscovery.baseURL(
            for: .hostPort(host: .ipv6(.init("fd00::1")!), port: 8760)
        )
        XCTAssertEqual(
            ipv6?.absoluteString,
            "https://[fd00::1]:8760/",
            "an IPv6 literal keeps its brackets or URLComponents builds nothing at all"
        )
        XCTAssertNil(
            RemoteHostDiscovery.baseURL(for: .service(
                name: "OPAQUE",
                type: RemoteDiscoveryDefaults.serviceType,
                domain: RemoteDiscoveryDefaults.serviceDomain,
                interface: nil
            )),
            "an unresolved service endpoint is not an address"
        )
    }

    // MARK: - Helpers

    private func advertisement(
        hostID: String,
        fingerprint: RemoteHostFingerprint
    ) -> RemoteHostAdvertisement {
        RemoteHostAdvertisement(
            hostID: hostID,
            protocolVersion: RemoteProtocol.current,
            fingerprint: fingerprint
        )
    }

    private func lanEndpoint(_ url: String) -> RemoteHostEndpointDTO {
        RemoteHostEndpointDTO(
            kind: RemoteHostEndpointKind.lan,
            baseURL: URL(string: url)!,
            isStable: true,
            identity: RemoteHostEndpointIdentity.pinned
        )
    }

    private func pairedHost() throws -> PairedRemoteHost {
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            token: Self.bearer,
            pinnedFingerprintCode: fingerprint.pairingCode
        ))
        return PairedRemoteHost(
            id: "mac-1",
            hostID: "mac-1",
            shareID: "my-devices",
            scope: "all",
            name: "Mac",
            link: link,
            lastConnectedAt: Date(),
            endpoints: [lanEndpoint("https://192.168.1.42:8760/")],
            connectionPolicy: .privateOnly,
            pinnedFingerprint: fingerprint.hex
        )
    }
}
