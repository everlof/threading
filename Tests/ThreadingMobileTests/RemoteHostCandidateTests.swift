import Darwin
import Foundation
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// Which addresses this phone will try for a paired Mac, and in what order.
///
/// Three contracts meet here. The endpoint policy decides which advertised doors are admissible
/// at all, and it is fail-closed. The sticky port range decides how far a `lan` address is
/// followed when the Mac's configured port was taken, and it is bounded. `RemoteDoorWalk`
/// decides when that range stops early, which is what keeps the bound from being paid in full
/// against an address nothing is listening at.
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

    // MARK: - Bounded private-route racing

    /// The real report's shape: Tailscale IPv4 was first, two LAN addresses sat between it and
    /// Tailscale IPv6, and IPv4 failed TLS while IPv6 worked. Each kind gets a lane and the spare
    /// fourth lane starts a second tailnet door, without splitting a LAN sticky-port walk.
    func testPrivateRouteLanesRaceTailnetAddressFamiliesWithinTheFixedBound() {
        let host = pairedHost(endpoints: [
            endpoint(.tailscale, "https://100.65.47.126:8760/"),
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.vpn, "https://10.8.0.3:9443/"),
            endpoint(.tailscale, "https://[fd7a:115c:a1e0::1]:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8760/"),
        ], policy: .privateOnly)

        let lanes = PrivateNetworkRouteRacePlan.lanes(host.candidates)
        let tailnetLanes = lanes.filter {
            $0.first?.kind == RemoteHostEndpointKind.tailscale
        }
        let allPlanned = lanes.flatMap { $0 }

        XCTAssertEqual(lanes.count, PrivateNetworkRouteRacePlan.maximumConcurrentLanes)
        XCTAssertEqual(tailnetLanes.count, PrivateNetworkRouteRacePlan.maximumTailnetLanes)
        XCTAssertEqual(allPlanned.count, host.candidates.count)
        XCTAssertEqual(Set(allPlanned.map(\.link)), Set(host.candidates.map(\.link)))
        XCTAssertTrue(
            tailnetLanes.contains { lane in
                lane.contains { $0.link.baseURL.absoluteString.contains("100.65.47.126") }
            }
        )
        XCTAssertTrue(
            tailnetLanes.contains { lane in
                lane.contains { $0.link.baseURL.absoluteString.contains("fd7a:115c:a1e0") }
            }
        )
        let ipv4Lane = tailnetLanes.firstIndex {
            $0.contains { $0.link.baseURL.absoluteString.contains("100.65.47.126") }
        }
        let ipv6Lane = tailnetLanes.firstIndex {
            $0.contains { $0.link.baseURL.absoluteString.contains("fd7a:115c:a1e0") }
        }
        XCTAssertNotEqual(ipv4Lane, ipv6Lane)

        for doorID in Set(host.candidates.map(\.doorID)) {
            XCTAssertEqual(
                lanes.filter { lane in lane.contains { $0.doorID == doorID } }.count,
                1,
                "one advertised door and all of its sticky ports stay sequential"
            )
        }
    }

    /// Proves the outcome the report needed, not just the shape of the plan: an immediate IPv4
    /// TLS failure advances only its own lane while usable IPv6 wins and cancels sleeping routes.
    func testTailnetIPv6CanWinWhileIPv4TLSAndLANFailIndependently() async throws {
        let host = pairedHost(endpoints: [
            endpoint(.tailscale, "https://100.65.47.126:8760/"),
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.tailscale, "https://[fd7a:115c:a1e0::1]:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8760/"),
        ], policy: .privateOnly)
        let lanes = PrivateNetworkRouteRacePlan.lanes(host.candidates)
        let attempts: [FirstSuccessfulTaskRace.Attempt<URL>] = lanes.enumerated().map {
            index, lane in
            .init(id: "private.\(index)", failurePriority: index) {
                for candidate in lane {
                    let address = candidate.link.baseURL.absoluteString
                    if address.contains("100.65.47.126") {
                        // The observed Tailscale IPv4 certificate failure: fast, but not a
                        // verdict on IPv6 or MagicDNS.
                        continue
                    }
                    if address.contains("fd7a:115c:a1e0") {
                        try await Task.sleep(for: .milliseconds(20))
                        return candidate.link.baseURL
                    }
                    try await Task.sleep(for: .seconds(5))
                    return candidate.link.baseURL
                }
                throw URLError(.secureConnectionFailed)
            }
        }

        let winner = try await FirstSuccessfulTaskRace.run(attempts)

        XCTAssertTrue(winner.value.absoluteString.contains("fd7a:115c:a1e0"))
    }

    // MARK: - When a door is done

    /// URLSession's timeout covers the whole request. It does not prove whether the connection
    /// stalled before TCP connect, at TLS, or after a server accepted it, and one filtered port
    /// says nothing about the listener on another port of the sticky range.
    func testATimedOutAttemptKeepsWalkingTheRange() {
        XCTAssertNil(
            RemoteDoorWalk.ending(for: URLError(.timedOut), trustVerdict: nil)
        )
    }

    /// The walk's entire reason to exist. A Mac that is on this network refuses a port nothing is
    /// listening on, immediately, and the listener is on one of the other nine.
    func testARefusedConnectionKeepsWalkingTheRange() {
        XCTAssertNil(
            RemoteDoorWalk.ending(
                for: URLError(.cannotConnectToHost),
                trustVerdict: nil
            )
        )
    }

    /// The same URL code arrives for a refusal and for a network with no path to that address at
    /// all, including a denied Local Network grant. The POSIX code underneath is what tells them
    /// apart, so the chain decides rather than the code on top.
    func testARefusalCarryingANoRouteCodeEndsTheDoor() {
        let noRoute = URLError(
            .cannotConnectToHost,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EHOSTUNREACH)
                ),
            ]
        )

        XCTAssertEqual(
            RemoteDoorWalk.ending(for: noRoute, trustVerdict: nil),
            .unreachable
        )
    }

    func testANameThatDoesNotResolveEndsTheDoor() {
        XCTAssertEqual(
            RemoteDoorWalk.ending(
                for: URLError(.cannotFindHost),
                trustVerdict: nil
            ),
            .unreachable
        )
    }

    /// An answer is an answer. Knocking on nine more ports after the Mac has refused a bearer or
    /// named a protocol version finds nothing it has not already said.
    func testAnAnsweringDoorEndsWhateverItAnswered() {
        for answer: RemoteClientError in [
            .unauthorized,
            .invalidResponse,
            .server(404),
            .upgradeRequired(.client),
        ] {
            XCTAssertEqual(
                RemoteDoorWalk.ending(for: answer, trustVerdict: nil),
                .answered,
                "\(answer) came from a server"
            )
        }
    }

    /// A cancelled server-trust challenge arrives as `URLError(-999)` with nothing underneath
    /// naming the pin, so the delegate's verdict is the only place the reason exists.
    func testAPinnedIdentityMismatchEndsTheDoor() {
        XCTAssertEqual(
            RemoteDoorWalk.ending(
                for: URLError(.cancelled),
                trustVerdict: .rejectedFingerprintMismatch
            ),
            .answered
        )
    }

    /// Something completed a TLS handshake badly, which means something was there. The listener
    /// may still be on another port of the range, so this is not a fact about the address.
    func testATLSFailureIsNotAVerdictOnTheAddress() {
        XCTAssertNil(
            RemoteDoorWalk.ending(
                for: URLError(.secureConnectionFailed),
                trustVerdict: nil
            )
        )
    }

    /// The walk carries its last failure wrapped in the address it was aimed at. Classification
    /// still follows only the underlying evidence: a DNS failure ends the door and a timeout
    /// remains scoped to one port.
    func testWrappedFailuresAreClassifiedByTheirUnderlyingEvidence() {
        let unreachable = RemoteConnectionAttempt(
            underlying: URLError(.cannotFindHost),
            host: "192.168.1.42"
        )
        let timedOut = RemoteConnectionAttempt(
            underlying: URLError(.timedOut),
            host: "192.168.1.42"
        )

        XCTAssertEqual(
            RemoteDoorWalk.ending(for: unreachable, trustVerdict: nil),
            .unreachable
        )
        XCTAssertNil(RemoteDoorWalk.ending(for: timedOut, trustVerdict: nil))
    }

    /// An ordinary refusal is not a verdict on anything else the phone might try. The rule ends
    /// one door, never the family.
    func testEndingADoorSaysNothingAboutTheOtherDoors() {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8760/"),
        ], policy: .privateOnly)

        let lanDoor = host.candidates.first { $0.kind == RemoteHostEndpointKind.lan }
        let tailnetDoor = host.candidates.first { $0.kind == RemoteHostEndpointKind.tailscale }

        XCTAssertNotNil(tailnetDoor)
        XCTAssertNotEqual(lanDoor?.doorID, tailnetDoor?.doorID)
    }

    // MARK: - What the walk actually attempts

    /// A timeout is deliberately scoped to one attempt. The read-only caller races independent
    /// private-network families, so a slow LAN lane does not hold a viable Tailscale lane behind
    /// it; the sequential walk can preserve its reason for existing and still try a listener on
    /// a later port of this address.
    @MainActor
    func testATimedOutPortStillWalksTheRestOfTheRange() async {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8760/"),
        ], policy: .privateOnly)
        let candidates = connectionCandidates(host)
        var attempted: [URL] = []

        let reached: URL? = try? await RemoteAppModel.walk(
            candidates,
            trace: "walk",
            phase: "request"
        ) { _, candidate -> URL in
            attempted.append(candidate.link.baseURL)
            guard candidate.kind == RemoteHostEndpointKind.tailscale else {
                throw URLError(.timedOut)
            }
            return candidate.link.baseURL
        }

        XCTAssertEqual(
            candidates.count,
            RemoteListenerPorts.fallbackRange.count + 1,
            "ten ports of the LAN address, then the tailnet name"
        )
        XCTAssertEqual(
            attempted.count,
            RemoteListenerPorts.fallbackRange.count + 1,
            "a request timeout is not enough evidence to discard the other ports"
        )
        XCTAssertEqual(attempted.last?.host, "mac.tail1234.ts.net")
        XCTAssertEqual(reached?.host, "mac.tail1234.ts.net")
    }

    /// The other half of the same rule: a refusal is what a Mac on this network says about a port
    /// nothing is listening on, so the range is still walked to the end for it.
    @MainActor
    func testARefusedPortStillWalksTheRestOfTheRange() async {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
        ], policy: .privateOnly)
        let candidates = connectionCandidates(host)
        var attempted: [Int] = []

        _ = try? await RemoteAppModel.walk(
            candidates,
            trace: "walk",
            phase: "request"
        ) { _, candidate -> URL in
            attempted.append(candidate.link.baseURL.port ?? 0)
            throw URLError(.cannotConnectToHost)
        }

        XCTAssertEqual(
            attempted.count,
            RemoteListenerPorts.fallbackRange.count,
            "the walk exists for a listener that moved to another port of its own range"
        )
    }

    /// An answer ends the door for the reason it always has, and the rest of the family is still
    /// tried: one door being finished is not a verdict on another way in.
    @MainActor
    func testAnAnsweringPortEndsItsDoorAndTheWalkMovesToTheNextOne() async {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8760/"),
        ], policy: .privateOnly)
        let candidates = connectionCandidates(host)
        var attempted: [String] = []

        _ = try? await RemoteAppModel.walk(
            candidates,
            trace: "walk",
            phase: "request"
        ) { _, candidate -> URL in
            attempted.append(candidate.kind)
            throw RemoteClientError.unauthorized
        }

        XCTAssertEqual(
            attempted,
            [RemoteHostEndpointKind.lan, RemoteHostEndpointKind.tailscale]
        )
    }

    /// Cancellation is not a door verdict. A refresh that is replaced mid-walk stops, and it does
    /// not leave a conclusion about the address behind it.
    @MainActor
    func testACancelledAttemptStopsTheWalkWithoutJudgingTheDoor() async {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
        ], policy: .privateOnly)
        var attempted = 0

        do {
            _ = try await RemoteAppModel.walk(
                connectionCandidates(host),
                trace: "walk",
                phase: "request"
            ) { _, _ -> URL in
                attempted += 1
                throw CancellationError()
            }
            XCTFail("a cancelled walk does not produce a route")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(attempted, 1)
    }

    // MARK: - Fixtures

    /// The same mapping `RemoteAppModel` makes before it walks: one attempt per candidate, each
    /// still naming the door it belongs to.
    private func connectionCandidates(
        _ host: PairedRemoteHost
    ) -> [RemoteAppModel.ConnectionCandidate] {
        host.candidates.map {
            RemoteAppModel.ConnectionCandidate(
                link: $0.link,
                isHosted: false,
                kind: $0.kind,
                doorID: $0.doorID
            )
        }
    }

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
