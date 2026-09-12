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

    private actor CancellationFlag {
        private(set) var wasCancelled = false

        func markCancelled() {
            wasCancelled = true
        }
    }

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

    // MARK: - Which pass an attempt belongs to

    /// The ordering rule the 2026-08-21 incident is about. Every route contributes one address
    /// before any route contributes a second, so a phone whose LAN has gone silent finds out
    /// about the tailnet within one timeout rather than after twenty.
    func testEveryRouteGetsItsOwnAddressBeforeAnyRouteGetsASecondAttempt() {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.lan, "https://mac-two.local:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8760/"),
            endpoint(.vpn, "https://10.8.0.3:8760/"),
        ], policy: .privateOnly)

        let candidates = host.candidates
        let leading = candidates.prefix(while: { $0.wave == .route })

        XCTAssertEqual(
            Set(leading.map(\.kind)),
            [
                RemoteHostEndpointKind.lan,
                RemoteHostEndpointKind.tailscale,
                RemoteHostEndpointKind.vpn,
            ],
            "the first wave is one address per route, and every route is in it"
        )
        XCTAssertEqual(leading.count, 3, "one address each, not one attempt each")
        XCTAssertEqual(
            candidates.map(\.wave),
            candidates.map(\.wave).sorted(),
            "attempts are ordered by wave, never interleaved back into endpoint order"
        )
        XCTAssertTrue(
            candidates.allSatisfy { $0.wave != .route || !$0.isPortWalk },
            "a guessed port is never part of the first wave"
        )
    }

    /// The first wave keeps the endpoint policy's own deterministic order. Interleaving is about
    /// *which* attempt comes next, not about inventing a preference between private kinds.
    func testTheFirstWaveKeepsThePolicysDeterministicOrder() {
        let host = pairedHost(endpoints: [
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8760/"),
            endpoint(.vpn, "https://10.8.0.3:8760/"),
            endpoint(.lan, "https://192.168.1.42:8760/"),
        ], policy: .privateOnly)

        let ordered = RemoteHostEndpointSelection.ordered(
            host.endpoints ?? [],
            policy: .privateOnly,
            currentBaseURL: host.link.baseURL
        )
        let leading = host.candidates.filter { $0.wave == .route }

        XCTAssertEqual(
            leading.map(\.link.baseURL),
            ordered.map(\.baseURL),
            "one per route, in the order the shared kit already fixes"
        )
    }

    /// Ten ports answer "which port did this Mac's listener take". The answer does not change
    /// between two addresses of the same Mac, and the incident paid for it twice: twenty LAN
    /// attempts for two addresses, eighty seconds, before another route was tried at all.
    func testTheStickyRangeIsWalkedOncePerRouteRatherThanOncePerAddress() {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.181:8760/"),
            endpoint(.lan, "https://mac.local:8760/"),
        ], policy: .privateOnly)

        let candidates = host.candidates
        let walked = candidates.filter(\.isPortWalk)

        XCTAssertEqual(
            candidates.count,
            RemoteListenerPorts.fallbackRange.count + 1,
            "two addresses and one range, not two ranges"
        )
        XCTAssertEqual(walked.count, RemoteListenerPorts.fallbackRange.count - 1)
        XCTAssertEqual(
            Set(walked.map(\.doorID)).count,
            1,
            "the range belongs to the one address that carries it"
        )
        XCTAssertEqual(
            walked.first?.link.baseURL.host,
            "192.168.1.181",
            "the address that leads the route is the one that carries its range"
        )
        XCTAssertEqual(
            candidates.first { $0.link.baseURL.host == "mac.local" }?.wave,
            .address,
            "the Mac's other LAN address is tried, and it is tried before any guessed port"
        )
    }

    /// A second address of a route already represented is still tried. Skipping it would trade
    /// one incident for another: a Mac that moved between two of its own LAN addresses.
    func testASecondAddressOfARouteIsStillTriedAheadOfTheRange() {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.181:8760/"),
            endpoint(.lan, "https://mac.local:8760/"),
        ], policy: .privateOnly)

        let hosts = host.candidates.compactMap(\.link.baseURL.host)

        XCTAssertEqual(hosts.prefix(2), ["192.168.1.181", "mac.local"])
        XCTAssertTrue(hosts.dropFirst(2).allSatisfy { $0 == "192.168.1.181" })
    }

    /// Discovery's address is where the Mac is now, so it leads its route and it is the one that
    /// carries the range. The advertised LAN address the record remembers is still tried, once.
    func testTheDiscoveredAddressLeadsItsRouteAndCarriesTheRange() throws {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8760/"),
        ], policy: .privateOnly)
        let discovered = try XCTUnwrap(URL(string: "https://192.168.1.99:8760/"))

        let candidates = host.candidates(preferring: discovered)

        XCTAssertEqual(candidates.first?.link.baseURL.host, "192.168.1.99")
        XCTAssertTrue(
            candidates.filter(\.isPortWalk).allSatisfy {
                $0.link.baseURL.host == "192.168.1.99"
            },
            "one range, carried by the address the Mac was just found at"
        )
        XCTAssertEqual(
            candidates.first { $0.link.baseURL.host == "192.168.1.42" }?.wave,
            .address
        )
        XCTAssertEqual(
            candidates.first { $0.kind == RemoteHostEndpointKind.tailscale }?.wave,
            .route,
            "a discovered LAN address does not push another route out of the first wave"
        )
    }

    // MARK: - What a walk may spend

    /// A guessed port is worth less than a route's own address, because it is a guess. A Mac on
    /// this network refuses a port nothing is listening on immediately; a port that neither
    /// answers nor refuses is behind the same silence as the address itself.
    func testAGuessedPortIsGivenLessThanARoutesOwnAddress() {
        XCTAssertEqual(
            RemoteRouteWalkBudget.timeout(for: .route, isOnlyCandidateInRace: false),
            RemoteRouteWalkBudget.routeAttemptTimeout
        )
        XCTAssertEqual(
            RemoteRouteWalkBudget.timeout(for: .address, isOnlyCandidateInRace: false),
            RemoteRouteWalkBudget.routeAttemptTimeout
        )
        XCTAssertEqual(
            RemoteRouteWalkBudget.timeout(for: .port, isOnlyCandidateInRace: false),
            RemoteRouteWalkBudget.portAttemptTimeout
        )
        XCTAssertLessThan(
            RemoteRouteWalkBudget.portAttemptTimeout,
            RemoteRouteWalkBudget.routeAttemptTimeout
        )
    }

    /// A walk of one is not a walk. There is no other route to get on with, so cutting it short
    /// would only turn a slow success into a failure.
    func testASingleCandidateKeepsTheOrdinaryRequestTimeoutAndNoCeiling() {
        XCTAssertEqual(
            RemoteRouteWalkBudget.timeout(for: .route, isOnlyCandidateInRace: true),
            RemoteClient.defaultRequestTimeout
        )
        XCTAssertEqual(
            RemoteRouteWalkBudget.ceiling(forCandidateCount: 1),
            RemoteClient.defaultRequestTimeout
        )
        XCTAssertEqual(
            RemoteRouteWalkBudget.ceiling(forCandidateCount: 2),
            RemoteRouteWalkBudget.walkCeiling
        )
        XCTAssertLessThan(
            RemoteRouteWalkBudget.walkCeiling,
            15,
            "the ceiling ends the wait inside the span after which a person concludes it is broken"
        )
    }

    /// The conditional request a refresh sends first is a bet that the last route still works,
    /// and it is worth one route attempt: the race behind it tries every other way in at that
    /// pace. Given a whole request timeout, a phone that had left the Mac's Wi-Fi spent twenty
    /// seconds on the dead LAN origin before the race found Tailscale in one (2026-09-11).
    func testTheWarmProbeIsWorthOneRouteAttemptWhenTheRaceHasSomewhereElseToGo() {
        XCTAssertEqual(
            RemoteRouteWalkBudget.warmProbeTimeout(hasOtherRoutes: true),
            RemoteRouteWalkBudget.routeAttemptTimeout
        )
        XCTAssertEqual(
            RemoteRouteWalkBudget.warmProbeTimeout(hasOtherRoutes: false),
            RemoteClient.defaultRequestTimeout,
            "a Mac with one way in has nothing waiting behind the probe"
        )
        XCTAssertLessThan(
            RemoteRouteWalkBudget.warmProbeTimeout(hasOtherRoutes: true)
                + RemoteRouteWalkBudget.walkCeiling,
            RemoteClient.defaultRequestTimeout,
            "a lost probe and the whole race behind it end inside one old probe"
        )
    }

    /// The ceiling is an ownership boundary. Recovery may start as soon as it answers, so the old
    /// walk must already have been cancelled and cannot later compete with that new generation.
    @MainActor
    func testTheCeilingCancelsTheWalkBeforeRecoveryCanReplaceIt() async {
        let cancellation = CancellationFlag()

        do {
            _ = try await RemoteRouteWalkDeadline.run(
                ceiling: 0.05,
                walk: {
                    do {
                        try await Task.sleep(for: .seconds(30))
                        return "never"
                    } catch {
                        await cancellation.markCancelled()
                        throw error
                    }
                },
                exceeded: { URLError(.timedOut) }
            )
            XCTFail("the caller is answered at the ceiling")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }

        for _ in 0..<20 {
            if await cancellation.wasCancelled { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let wasCancelled = await cancellation.wasCancelled
        XCTAssertTrue(
            wasCancelled,
            "the timed-out generation cannot leave a request alive behind recovery"
        )
    }

    /// The ordinary case is unchanged: a walk that answers inside its ceiling is the answer.
    @MainActor
    func testAWalkInsideTheCeilingIsTheCallersAnswer() async throws {
        let value = try await RemoteRouteWalkDeadline.run(
            ceiling: 5,
            walk: { "lan" },
            exceeded: { URLError(.timedOut) }
        )

        XCTAssertEqual(value, "lan")
    }

    /// The failure the caller sees at the ceiling is the walk's ordinary named transport failure,
    /// so the offline screen keeps naming a cause and offering the step it already offered.
    @MainActor
    func testTheCeilingSurfacesTheOrdinaryNamedTransportFailure() async {
        do {
            _ = try await RemoteRouteWalkDeadline.run(
                ceiling: 0.05,
                walk: {
                    try await Task.sleep(for: .seconds(30))
                    return "never"
                },
                exceeded: {
                    RemoteConnectionAttempt(
                        underlying: URLError(.timedOut),
                        host: "192.168.1.181"
                    )
                }
            )
            XCTFail("the ceiling answers")
        } catch {
            let failure = RemoteConnectionFailure.transport(
                error,
                host: "192.168.1.181",
                trustVerdict: nil
            )
            XCTAssertEqual(failure.recovery, .reconnect)
            XCTAssertEqual(
                MobileDiagnostics.errorCode(RemoteConnectionAttempt.underlying(error)),
                "url.\(URLError.Code.timedOut.rawValue)"
            )
        }
    }

    /// Four lanes is the resource contract, whatever a host advertises. A lane walks its own
    /// candidates one at a time, so the number of sockets in flight is the number of lanes and
    /// not the number of candidates.
    func testTheWalkNeverPutsMoreAttemptsInFlightThanTheLaneBound() async throws {
        let host = Self.incidentHost()
        let lanes = PrivateNetworkRouteRacePlan.lanes(host.candidates)
        let peak = InFlightPeak()
        let attempts: [FirstSuccessfulTaskRace.Attempt<String>] = lanes.enumerated().map {
            index, lane in
            .init(id: "lane.\(index)", failurePriority: index) {
                for candidate in lane {
                    await peak.enter()
                    try await Task.sleep(for: .milliseconds(20))
                    await peak.leave()
                    if candidate.link.baseURL.host == Self.incidentTailnetName {
                        return candidate.link.baseURL.absoluteString
                    }
                }
                throw URLError(.timedOut)
            }
        }

        _ = try await FirstSuccessfulTaskRace.run(attempts)

        let observed = await peak.peak
        XCTAssertGreaterThan(observed, 1, "the lanes really did overlap")
        XCTAssertLessThanOrEqual(observed, PrivateNetworkRouteRacePlan.maximumConcurrentLanes)
        XCTAssertLessThanOrEqual(
            lanes.count,
            PrivateNetworkRouteRacePlan.maximumConcurrentLanes
        )
    }

    // MARK: - The 2026-08-21 incident, replayed

    /// The report's own candidate list, walked twice: in the order the journal shows and in the
    /// order this code now produces.
    ///
    /// The journal's traces name 23 candidates, `total: "23"`, at `timeoutMS: "4000"` each. The
    /// origin digests in it are unsalted SHA-256 of `scheme://host:port`, so the addresses behind
    /// them are recoverable: attempts 2 through 11 are `192.168.1.181` on 8760 through 8769 and
    /// attempts 12 through 21 are `davids-macbook-pro.local` on the same ten ports. Twenty LAN
    /// attempts for two addresses. The tailnet name answered at attempt 22 in 818 ms.
    ///
    /// This replays that on a clock that advances by what each attempt was given, so ninety
    /// seconds of a person's evening costs the suite nothing.
    @MainActor
    func testTheIncidentsWalkReachesTheTailnetFiveAttemptsInInsteadOfTwentyTwo() async {
        let host = Self.incidentHost()

        let before = await replay(
            Self.incidentCandidatesInJournalOrder(),
            timeout: { _ in RemoteRouteWalkBudget.routeAttemptTimeout }
        )
        let after = await replay(
            connectionCandidates(host),
            timeout: {
                RemoteRouteWalkBudget.timeout(for: $0.wave, isOnlyCandidateInRace: false)
            }
        )

        XCTAssertEqual(before.candidateCount, 23, "the report's own total")
        XCTAssertEqual(before.winningAttempt, 22, "the report's own attempt number")
        XCTAssertGreaterThan(
            before.elapsed,
            60,
            "twenty LAN attempts at four seconds each, ahead of the route that worked"
        )

        XCTAssertEqual(after.candidateCount, 14, "one sticky range instead of two")
        XCTAssertEqual(after.winningAttempt, 5)
        XCTAssertEqual(after.winner?.host, Self.incidentTailnetName)
        XCTAssertLessThan(after.elapsed, before.elapsed / 5)
    }

    /// What the phone actually does with that list, which is race it. Every route's own address
    /// starts at once, so the tailnet answers in its own 818 ms rather than behind anything.
    @MainActor
    func testTheIncidentsRacedWalkAnswersWellInsideTheCeiling() async throws {
        let host = Self.incidentHost()
        let lanes = PrivateNetworkRouteRacePlan.lanes(host.candidates)

        var firstSuccess: TimeInterval?
        for lane in lanes {
            let outcome = await replay(
                lane.map {
                    RemoteAppModel.ConnectionCandidate(
                        link: $0.link,
                        isHosted: false,
                        kind: $0.kind,
                        doorID: $0.doorID,
                        wave: $0.wave
                    )
                },
                timeout: {
                    RemoteRouteWalkBudget.timeout(
                        for: $0.wave,
                        isOnlyCandidateInRace: host.candidates.count == 1
                    )
                }
            )
            guard outcome.winner != nil else { continue }
            firstSuccess = min(firstSuccess ?? .greatestFiniteMagnitude, outcome.elapsed)
        }

        let reached = try XCTUnwrap(firstSuccess, "some lane reaches the Mac")
        XCTAssertLessThan(
            reached,
            RemoteRouteWalkBudget.walkCeiling,
            "a dead LAN with a live tailnet connects inside the walk's ceiling"
        )
        XCTAssertLessThan(reached, 2, "in the tailnet's own 818 ms, behind nothing")
    }

    // MARK: - What the walk says while it runs

    /// A first attempt normally answers in well under a second, and a route name flashed for two
    /// hundred milliseconds is a stutter rather than information.
    func testOpeningAChatSaysOpeningUntilSomethingHasFailed() {
        XCTAssertEqual(
            MobileSessionChrome.openingStatus(isAvailable: true, routeWalk: nil),
            "Opening chat…"
        )
        XCTAssertEqual(
            MobileSessionChrome.openingStatus(
                isAvailable: true,
                routeWalk: RemoteAppModel.RouteWalkStatus(
                    kind: RemoteHostEndpointKind.lan,
                    attempt: 1,
                    total: 14,
                    followsFailure: false
                )
            ),
            "Opening chat…"
        )
    }

    /// Once something has failed the walk is going to take a while, and the route it is on is the
    /// only honest thing to say. The words are the connection status's own.
    func testOnceARouteHasFailedTheScreenNamesTheOneItIsTrying() {
        XCTAssertEqual(
            MobileSessionChrome.openingStatus(
                isAvailable: true,
                routeWalk: RemoteAppModel.RouteWalkStatus(
                    kind: RemoteHostEndpointKind.tailscale,
                    attempt: 5,
                    total: 14,
                    followsFailure: true
                )
            ),
            MobileDashboardChrome.connectionStatus(
                phase: .connecting,
                connectionLabel: nil,
                progress: .tryingRoute(
                    kind: RemoteHostEndpointKind.tailscale,
                    previousKind: nil,
                    number: 5,
                    total: 14
                )
            )
        )
    }

    /// A dormant session is being woken on the Mac rather than reached over a route, so the route
    /// A chat reconnecting after a loss follows the opening rule: "Reconnecting…" until a route
    /// has failed, then the route it is on. "Reconnecting…" alone was the whole of what a chat
    /// said through a route loss, however long the walk behind it took (2026-09-11).
    func testAReconnectingChatNamesTheRouteOnceOneHasFailed() {
        XCTAssertEqual(
            MobileSessionChrome.diallingStatus(hasEverConnected: true, routeWalk: nil),
            "Reconnecting…"
        )
        XCTAssertEqual(
            MobileSessionChrome.diallingStatus(hasEverConnected: false, routeWalk: nil),
            "Opening chat…"
        )
        let walking = RemoteAppModel.RouteWalkStatus(
            kind: RemoteHostEndpointKind.tailscale,
            attempt: 2,
            total: 13,
            followsFailure: true
        )
        XCTAssertEqual(
            MobileSessionChrome.diallingStatus(hasEverConnected: true, routeWalk: walking),
            MobileSessionChrome.openingStatus(isAvailable: true, routeWalk: walking),
            "the reconnecting chat and the opening chat name a route the same way"
        )
        XCTAssertNotEqual(
            MobileSessionChrome.diallingStatus(hasEverConnected: true, routeWalk: walking),
            "Reconnecting…"
        )
    }

    /// walk has nothing to say about it.
    func testAResumingSessionKeepsItsOwnSentence() {
        XCTAssertEqual(
            MobileSessionChrome.openingStatus(
                isAvailable: false,
                routeWalk: RemoteAppModel.RouteWalkStatus(
                    kind: RemoteHostEndpointKind.lan,
                    attempt: 3,
                    total: 14,
                    followsFailure: true
                )
            ),
            "Resuming on your Mac…"
        )
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
        XCTAssertEqual(
            RemoteClient(link: vpnLink, endpointKind: .vpn).endpointKind,
            .vpn,
            "downstream socket diagnostics keep the advertised route instead of guessing again"
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
            .server(status: 404),
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

    /// A timeout is deliberately scoped to one attempt. It advances the walk without ruling the
    /// address out, so the rest of the sticky range is still tried — but only after every other
    /// route has had its own address tried, because a route nobody has knocked on yet is better
    /// evidence than a ninth guess at a port on an address that is not answering.
    @MainActor
    func testATimedOutPortStillWalksTheRestOfTheRangeAfterTheOtherRoutes() async {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8760/"),
        ], policy: .privateOnly)
        let candidates = connectionCandidates(host)
        var attempted: [URL] = []

        _ = try? await RemoteAppModel.walk(
            candidates,
            trace: "walk",
            phase: "request"
        ) { _, candidate -> URL in
            attempted.append(candidate.link.baseURL)
            throw URLError(.timedOut)
        }

        XCTAssertEqual(
            candidates.count,
            RemoteListenerPorts.fallbackRange.count + 1,
            "the LAN address and its ports, plus the tailnet name"
        )
        XCTAssertEqual(
            attempted.count,
            RemoteListenerPorts.fallbackRange.count + 1,
            "a request timeout is not enough evidence to discard the other ports"
        )
        XCTAssertEqual(
            attempted.prefix(2).compactMap(\.host),
            ["192.168.1.42", "mac.tail1234.ts.net"],
            "each route's own address leads; the port walk is not in front of another route"
        )
        XCTAssertEqual(attempted.dropFirst(2).compactMap(\.host).first, "192.168.1.42")
    }

    /// The same two doors, with the tailnet answering. It is reached second rather than eleventh,
    /// which is the whole of the 2026-08-21 fix stated on the smallest host that can show it.
    @MainActor
    func testAWorkingTailnetIsReachedBeforeADeadLansPortWalk() async {
        let host = pairedHost(endpoints: [
            endpoint(.lan, "https://192.168.1.42:8760/"),
            endpoint(.tailscale, "https://mac.tail1234.ts.net:8760/"),
        ], policy: .privateOnly)
        var attempted: [URL] = []

        let reached: URL? = try? await RemoteAppModel.walk(
            connectionCandidates(host),
            trace: "walk",
            phase: "request"
        ) { _, candidate -> URL in
            attempted.append(candidate.link.baseURL)
            guard candidate.kind == RemoteHostEndpointKind.tailscale else {
                throw URLError(.timedOut)
            }
            return candidate.link.baseURL
        }

        XCTAssertEqual(reached?.host, "mac.tail1234.ts.net")
        XCTAssertEqual(attempted.count, 2)
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
        var attempted: [RemoteHostEndpointKind] = []

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
    /// still naming the door it belongs to and which pass it belongs to.
    private func connectionCandidates(
        _ host: PairedRemoteHost
    ) -> [RemoteAppModel.ConnectionCandidate] {
        host.candidates.map {
            RemoteAppModel.ConnectionCandidate(
                link: $0.link,
                isHosted: false,
                kind: $0.kind,
                doorID: $0.doorID,
                wave: $0.wave
            )
        }
    }

    /// How many attempts of one walk overlapped at their peak.
    private actor InFlightPeak {
        private var current = 0
        private(set) var peak = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func leave() { current -= 1 }
    }

    /// The Mac the 2026-08-21 report was filed against, as its journal describes it.
    ///
    /// Four advertised addresses over three routes. The digests in the report recover the two LAN
    /// addresses exactly; the tailnet pair and the VPN address are reconstructed from the order
    /// the walk visited them in, which the shared kit fixes as plain URL order — a `100.x` tailnet
    /// address sorts ahead of `192.168.…`, and a `.ts.net` name sorts behind `.local`. That is
    /// what put the working route at attempt 22 out of 23.
    private static let incidentTailnetName = "davids-macbook-pro.tail9c21e.ts.net"

    private static func incidentHost() -> PairedRemoteHost {
        PairedRemoteHost(
            id: "mac",
            hostID: "mac",
            shareID: "my-devices",
            scope: "all",
            name: "Mac",
            link: RemoteConnectionLink(
                baseURL: URL(string: "https://192.168.1.181:8760/")!,
                token: bearer
            )!,
            lastConnectedAt: Date(),
            endpoints: [
                RemoteHostEndpointDTO(
                    kind: RemoteHostEndpointKind.tailscale,
                    baseURL: URL(string: "https://100.83.41.7:8760/")!,
                    isStable: true,
                    identity: RemoteHostEndpointIdentity.pinned
                ),
                RemoteHostEndpointDTO(
                    kind: RemoteHostEndpointKind.lan,
                    baseURL: URL(string: "https://192.168.1.181:8760/")!,
                    isStable: true,
                    identity: RemoteHostEndpointIdentity.pinned
                ),
                RemoteHostEndpointDTO(
                    kind: RemoteHostEndpointKind.lan,
                    baseURL: URL(string: "https://davids-macbook-pro.local:8760/")!,
                    isStable: true,
                    identity: RemoteHostEndpointIdentity.pinned
                ),
                RemoteHostEndpointDTO(
                    kind: RemoteHostEndpointKind.tailscale,
                    baseURL: URL(string: "https://\(incidentTailnetName):443/")!,
                    isStable: true
                ),
                RemoteHostEndpointDTO(
                    kind: RemoteHostEndpointKind.vpn,
                    baseURL: URL(string: "https://vpn-mac.internal:8760/")!,
                    isStable: true,
                    identity: RemoteHostEndpointIdentity.pinned
                ),
            ],
            connectionPolicy: .privateOnly
        )
    }

    /// The 23 attempts in the order the journal records them: one flat list, each LAN address
    /// carrying its own copy of the ten-port range.
    private static func incidentCandidatesInJournalOrder()
    -> [RemoteAppModel.ConnectionCandidate] {
        var urls = ["https://100.83.41.7:8760/"]
        for address in ["192.168.1.181", "davids-macbook-pro.local"] {
            for port in RemoteListenerPorts.candidates(preferred: RemoteListenerPorts.defaultPort) {
                urls.append("https://\(address):\(port)/")
            }
        }
        urls.append("https://\(incidentTailnetName):443/")
        urls.append("https://vpn-mac.internal:8760/")
        return urls.compactMap { string in
            guard let url = URL(string: string),
                  let link = RemoteConnectionLink(baseURL: url, token: bearer) else { return nil }
            let kind: RemoteHostEndpointKind
            switch url.host {
            case "100.83.41.7", incidentTailnetName: kind = RemoteHostEndpointKind.tailscale
            case "vpn-mac.internal": kind = RemoteHostEndpointKind.vpn
            default: kind = RemoteHostEndpointKind.lan
            }
            return RemoteAppModel.ConnectionCandidate(
                link: link,
                isHosted: false,
                kind: kind,
                doorID: "\(url.scheme ?? "")://\(url.host ?? "")",
                wave: .route
            )
        }
    }

    /// What one attempt of the incident's walk did, on the evidence in the journal.
    ///
    /// The tailnet name answered in 818 ms. The direct tailnet address failed TLS in 303 ms. Every
    /// LAN attempt, and the VPN address, returned nothing at all and therefore cost exactly the
    /// timeout each was given: that is what "every LAN SYN silently dropped" looks like from here.
    private static func incidentOutcome(
        for url: URL,
        timeout: TimeInterval
    ) -> (spent: TimeInterval, error: Error?) {
        switch url.host {
        case incidentTailnetName: return (0.818, nil)
        case "100.83.41.7": return (0.303, URLError(.secureConnectionFailed))
        default: return (timeout, URLError(.timedOut))
        }
    }

    private struct ReplayedWalk {
        let elapsed: TimeInterval
        let winner: URL?
        let winningAttempt: Int?
        let candidateCount: Int
    }

    /// Walks a candidate list through the production `walk`, on a clock that advances by what each
    /// attempt was given rather than by waiting for it.
    @MainActor
    private func replay(
        _ candidates: [RemoteAppModel.ConnectionCandidate],
        timeout: (RemoteAppModel.ConnectionCandidate) -> TimeInterval
    ) async -> ReplayedWalk {
        var elapsed: TimeInterval = 0
        var winningAttempt: Int?
        let winner: URL? = try? await RemoteAppModel.walk(
            candidates,
            trace: "replay",
            phase: "request"
        ) { index, candidate -> URL in
            let outcome = Self.incidentOutcome(
                for: candidate.link.baseURL,
                timeout: timeout(candidate)
            )
            elapsed += outcome.spent
            if let error = outcome.error { throw error }
            winningAttempt = index + 1
            return candidate.link.baseURL
        }
        return ReplayedWalk(
            elapsed: elapsed,
            winner: winner,
            winningAttempt: winningAttempt,
            candidateCount: candidates.count
        )
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

        var wireValue: RemoteHostEndpointKind {
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
