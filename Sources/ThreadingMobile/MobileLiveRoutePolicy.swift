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
/// It used to be "hosted whenever a tunnel has been prepared". The mutation walk prepares one
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
