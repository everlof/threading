import Foundation
import ThreadingRemoteKit

/// The way in a new socket or request is given: its link, the kind of route, and whether it is
/// the hosted loopback.
struct MobileLiveRoute: Equatable, Sendable {
    let link: RemoteConnectionLink
    let kind: RemoteHostEndpointKind
    let isHosted: Bool
}

/// Decides which route carries the sockets: the dashboard's event socket, a session's socket,
/// and the client a mutation or a reconnect starts from.
///
/// The rule is the one the conditional refresh already follows: **the route that answered
/// last**. A hosted tunnel is that route only when hosted is what answered, and only while the
/// tunnel is standing.
///
/// It used to be "hosted whenever a tunnel has been prepared". The mutation walk prepared one
/// for every mutation and a read race prepares one beside the private routes, so a prepared
/// tunnel was usually there, and nothing that adopted it as the socket route asked whether it
/// was the route that had answered, or whether it still stood. The 2026-09-06 iOS report is what
/// that costs: every second, for as long as the journal reached back, the event socket dialled
/// the hosted loopback origin and failed in 20 ms (`url.-1004`, nothing listening), the socket's
/// recovery ran one conditional refresh over Tailscale that answered `304`, and the socket
/// dialled the loopback again. The catalogue was fine, so the dashboard showed every row; the
/// session sockets took the same route, so no chat would open; only a force quit, which forgets
/// the tunnel, ended it.
///
/// Pure and unit-tested. `hostedLink` is nil unless the tunnel behind it is standing.
enum MobileLiveRoutePolicy {
    static func route(
        for host: PairedRemoteHost,
        lastConnection: MobileConnectionRecord?,
        hostedLink: RemoteConnectionLink?
    ) -> MobileLiveRoute {
        if let hostedLink,
           let last = lastConnection, last.hostID == host.id, last.isHosted
        {
            return MobileLiveRoute(link: hostedLink, kind: .hosted, isHosted: true)
        }
        // The paired link is the private route that answered last; `merge` moves it on every
        // direct answer. Its kind is read from the address when the record's active kind names
        // the hosted route, which is what it says after a hosted answer whose tunnel has since
        // ended.
        let kind: RemoteHostEndpointKind
        if let active = host.activeEndpointKind, active != .hosted {
            kind = active
        } else {
            kind = PairedRemoteHost.endpointKind(for: host.link.baseURL)
        }
        return MobileLiveRoute(link: host.link, kind: kind, isHosted: false)
    }
}

/// The order a sequential walk tries a Mac's ways in, and which attempt may replay a lost
/// response.
///
/// A mutation and a notification registration walk the routes one at a time under one request
/// id, so the walk itself is the retry: whatever one address did not deliver, the next one asks
/// for again. Three rules follow, each from the 2026-09-06 report.
///
/// **The route that answered last leads.** `RemoteHostEndpointSelection` ranks a stable address
/// above the one in use, so the registration walk after the relaunch tried a Tailscale address
/// that refused, then two LAN addresses at sixteen seconds each, before the Tailscale address
/// that had answered the catalogue thirty-three seconds earlier: attempt 4 of 14, fifty seconds
/// in.
///
/// **The hosted tunnel is prepared when the walk reaches it, not before.** Every mutation used to
/// negotiate a rendezvous and an ICE session first and try the tunnel first, so the first
/// mutation after a direct read moved the whole app onto the tunnel, and dropped the event socket
/// to do it. Hosted leads only when hosted answered last; otherwise it follows the warm route and
/// precedes the Mac's other addresses, as it always has.
///
/// **A lost response is replayed once, on the last attempt.** `RemoteClient` replays a request
/// whose answer was lost, because the Mac may already have applied it. Inside a walk the next
/// address replays it anyway, so a replay on a dead address only doubled its timeout: the sixteen
/// seconds above, against an eight-second budget.
///
/// Pure and unit-tested.
enum MobileRouteWalkPlan {
    enum Step: Equatable, Sendable {
        case hosted
        /// An index into the direct candidates the plan returned.
        case direct(Int)
    }

    struct Plan<Candidate> {
        /// The direct candidates, with the route that answered last in front when it is among
        /// them and the rest in their given order.
        let direct: [Candidate]
        let steps: [Step]
    }

    static func plan<Candidate>(
        direct candidates: [Candidate],
        hasHostedRoute: Bool,
        hostID: String,
        lastConnection: MobileConnectionRecord?,
        origin: (Candidate) -> URL
    ) -> Plan<Candidate> {
        let hosted: [Step] = hasHostedRoute ? [.hosted] : []
        guard let last = lastConnection, last.hostID == hostID else {
            return Plan(direct: candidates, steps: hosted + candidates.indices.map(Step.direct))
        }
        if last.isHosted {
            return Plan(direct: candidates, steps: hosted + candidates.indices.map(Step.direct))
        }
        guard let warm = candidates.firstIndex(where: { origin($0) == last.baseURL }) else {
            return Plan(direct: candidates, steps: hosted + candidates.indices.map(Step.direct))
        }
        var direct = candidates
        direct.insert(direct.remove(at: warm), at: 0)
        let rest = direct.indices.dropFirst().map(Step.direct)
        return Plan(direct: direct, steps: [.direct(0)] + hosted + rest)
    }

    /// Whether the attempt at `index` of `count` may replay a lost response on its own address.
    static func replaysLostResponse(at index: Int, of count: Int) -> Bool {
        index == count - 1
    }
}
