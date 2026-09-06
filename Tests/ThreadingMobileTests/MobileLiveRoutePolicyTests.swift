import Foundation
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
        static let hostedLink = RemoteConnectionLink(baseURL: loopbackURL, token: token)!

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
}
