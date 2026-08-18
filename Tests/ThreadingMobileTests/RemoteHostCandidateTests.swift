import Foundation
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// Which addresses this phone will try for a paired Mac, and in what order.
///
/// Two separate contracts meet here. The endpoint policy decides which advertised doors are
/// admissible at all, and it is fail-closed. The sticky port range decides how far a `lan`
/// address is followed when the Mac's configured port was taken, and it is bounded.
final class RemoteHostCandidateTests: XCTestCase {

    private static let bearer = String(repeating: "a", count: 43)

    // MARK: - Which doors

    /// `lan` and `vpn` are addresses of the Mac on a network the user is already on, so
    /// `privateOnly` admits them beside the tailnet. Before doors existed only `tailscale` could
    /// be, which is why a `lan` endpoint went unused for a whole phase.
    func testPrivateOnlyOffersLanAndVpnBesideTheTailnetAndNeverTheRelay() {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.vpn, "https://10.8.0.3:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8443/"),
            endpoint(.relay, "https://abc.trycloudflare.com/"),
        ], policy: .privateOnly)

        let hosts = host.candidates.compactMap(\.link.baseURL.host)

        XCTAssertTrue(hosts.contains("192.168.1.42"))
        XCTAssertTrue(hosts.contains("10.8.0.3"))
        XCTAssertTrue(hosts.contains("mac.tail1234.ts.net"))
        XCTAssertFalse(
            hosts.contains("abc.trycloudflare.com"),
            "a third party terminates that TLS, and private-only means private"
        )
    }

    /// The https filter is what kept a cleartext `lan` endpoint out of use before the listener
    /// had an identity to present, and it still holds now that it has one.
    func testACleartextCandidateIsNeverOffered() {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "http://192.168.1.42:8760/"),
            endpoint(.lan, "https://192.168.1.43:8760/"),
        ], policy: .privateOnly)

        let schemes = Set(host.candidates.compactMap(\.link.baseURL.scheme))

        XCTAssertEqual(schemes, ["https"])
        XCTAssertFalse(host.candidates.contains { $0.link.baseURL.host == "192.168.1.42" })
    }

    /// An explicitly empty list means the Mac authorizes nothing under its policy right now.
    /// Falling back to a remembered address there would be the phone overruling it.
    func testAnEmptyAdvertisedListOffersNothing() {
        XCTAssertTrue(pairedHost(endpoints: [], policy: .privateOnly).candidates.isEmpty)
    }

    // MARK: - The sticky port range

    func testALanEndpointOnTheRangeWalksTheRemainingPortsInOrder() {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8762/"),
        ], policy: .privateOnly)

        let ports = host.candidates.compactMap(\.link.baseURL.port)

        XCTAssertEqual(ports.first, 8762, "the address the Mac advertised is tried first")
        XCTAssertEqual(ports, [8762, 8760, 8761, 8763, 8764, 8765, 8766, 8767, 8768, 8769])
        XCTAssertEqual(
            ports.count,
            RemoteListenerPorts.fallbackRange.count,
            "bounded by the range the Mac walks, and no wider"
        )
        XCTAssertEqual(
            Set(host.candidates.map(\.doorID)).count,
            1,
            "every attempt belongs to the one door it is a port of"
        )
        XCTAssertEqual(host.candidates.filter { !$0.isPortWalk }.count, 1)
    }

    /// The walk is for a Mac whose sticky port moved under it. A tailnet name, a relay hostname
    /// and a VPN address are not ports somebody guessed, and knocking on nine more of them would
    /// be a fan-out with nothing behind it.
    func testOnlyALanAddressInsideTheRangeIsWalked() {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:9443/"),
            endpoint(.vpn, "https://10.8.0.3:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8443/"),
        ], policy: .privateOnly)

        XCTAssertEqual(host.candidates.count, 3)
        XCTAssertTrue(host.candidates.allSatisfy { !$0.isPortWalk })
    }

    func testTheWalkNeverRepeatsAnAddressAnotherEndpointAlreadyOffered() {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.lan, "https://192.168.1.42:8763/"),
        ], policy: .privateOnly)

        let urls = host.candidates.map(\.link.baseURL)

        XCTAssertEqual(Set(urls).count, urls.count, "each address is attempted exactly once")
        XCTAssertEqual(urls.count, RemoteListenerPorts.fallbackRange.count)
    }

    /// A record from before hosts advertised routes still has one address, and it is a `lan`
    /// address as often as not.
    func testALegacyRecordWithNoAdvertisedListStillWalksItsOwnPort() {
        var host = pairedHost(endpoints: [], policy: .privateOnly)
        host.endpoints = nil

        let ports = host.candidates.compactMap(\.link.baseURL.port)

        XCTAssertEqual(ports.first, 8760)
        XCTAssertEqual(ports.count, RemoteListenerPorts.fallbackRange.count)
    }

    // MARK: - What the connection is called

    func testTheLabelComesFromTheDoorTheMacNamedRatherThanFromTheAddress() {
        var host = pairedHost(endpoints: [
            endpoint(.vpn, "https://10.8.0.3:8760/"),
        ], policy: .privateOnly)
        let vpnLink = RemoteConnectionLink(
            baseURL: URL(string: "https://10.8.0.3:8760/")!,
            token: Self.bearer
        )!

        host.merge(identity: nil, successfulLink: vpnLink)

        XCTAssertEqual(host.activeEndpointKind, RemoteHostEndpointKind.vpn)
        XCTAssertEqual(host.connectionLabel, "VPN")
        XCTAssertEqual(
            PairedRemoteHost.endpointKind(for: vpnLink.baseURL),
            RemoteHostEndpointKind.lan,
            "the address alone cannot tell a VPN tunnel from the Wi-Fi it looks like"
        )
    }

    // MARK: - Fixtures

    private func pairedHost(
        endpoints: [RemoteHostEndpointDTO],
        policy: RemoteHostConnectionPolicy
    ) -> PairedRemoteHost {
        PairedRemoteHost(
            id: "mac",
            hostID: "mac",
            shareID: "my-devices",
            scope: "all",
            name: "Mac",
            link: RemoteConnectionLink(
                baseURL: URL(string: "https://192.168.1.42:8760/")!,
                token: Self.bearer
            )!,
            lastConnectedAt: Date(),
            endpoints: endpoints,
            connectionPolicy: policy
        )
    }

    private enum Kind {
        case lan, vpn, tailscale, relay

        var wireValue: String {
            switch self {
            case .lan: return RemoteHostEndpointKind.lan
            case .vpn: return RemoteHostEndpointKind.vpn
            case .tailscale: return RemoteHostEndpointKind.tailscale
            case .relay: return RemoteHostEndpointKind.relay
            }
        }

        var isPinned: Bool {
            switch self {
            case .lan, .vpn: return true
            case .tailscale, .relay: return false
            }
        }
    }

    private func endpoint(_ kind: Kind, _ url: String) -> RemoteHostEndpointDTO {
        RemoteHostEndpointDTO(
            kind: kind.wireValue,
            baseURL: URL(string: url)!,
            isStable: true,
            identity: kind.isPinned ? RemoteHostEndpointIdentity.pinned : nil
        )
    }
}
