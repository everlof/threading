import Foundation
import ThreadingPeerTransport
import ThreadingRemoteKit

/// The manager owns a tunnel's lifetime independently of its network implementation.
protocol HostedRemoteTunnel: AnyObject, Sendable {
    var origin: URL { get }
    var isActive: Bool { get }
    func stop()
}

extension PeerHostedDeviceTunnel: HostedRemoteTunnel {}

/// The hosted way in as the app holds it: the loopback origin `URLSession` dials, and the tunnel
/// standing behind it.
///
/// `isActive` is the reason the tunnel travels with the link. The model's route readers are
/// synchronous and the manager is an actor, so the fact "this origin still leads somewhere" has
/// to be part of the value. A tunnel ends on its own when its transport closes or fails, and its
/// origin then refuses every dial: the 2026-09-06 report dialled one every second for as long as
/// its journal reached back, because the app held the origin and nothing held the tunnel.
struct HostedRemoteRoute: Sendable {
    let link: RemoteConnectionLink
    private let tunnel: any HostedRemoteTunnel
    private let trust: RemoteCertificatePinningDelegate.Registration

    fileprivate init(
        link: RemoteConnectionLink,
        tunnel: any HostedRemoteTunnel,
        trust: RemoteCertificatePinningDelegate.Registration
    ) {
        self.link = link
        self.tunnel = tunnel
        self.trust = trust
    }

    /// Whether the tunnel behind the origin is still standing. False once it has stopped, on
    /// request or by itself.
    var isActive: Bool { tunnel.isActive }
}

/// The model's copy of the hosted route the manager last handed out.
///
/// It answers one question, "is there a hosted link standing for this Mac right now", and that
/// is deliberately the only question it can be asked. Until 2026-09-06 the model held the raw
/// link, and three readers chose it by presence alone; a reader that can reach the stored route
/// can dial an ended tunnel again, so none can.
struct HostedRouteMirror {
    private var hostID: String?
    private var route: HostedRemoteRoute?

    mutating func adopt(_ route: HostedRemoteRoute, for hostID: String) {
        self.hostID = hostID
        self.route = route
    }

    mutating func clear(for hostID: String) {
        guard self.hostID == hostID else { return }
        clearAll()
    }

    mutating func clearAll() {
        hostID = nil
        route = nil
    }

    /// The loopback link, only while the tunnel behind it is standing.
    func standingLink(for hostID: String) -> RemoteConnectionLink? {
        guard self.hostID == hostID, let route, route.isActive else { return nil }
        return route.link
    }
}

/// Keeps at most one iOS loopback proxy alive: the currently selected Mac. The actor also
/// coalesces concurrent refresh/mutation callers so a slow ICE negotiation cannot fan out into
/// duplicate sockets, candidate lists, or WebRTC peer connections.
///
/// A tunnel that has ended is never handed out. It stops itself when its transport closes or
/// fails, and the next caller finds it inactive here, drops it, and negotiates again.
actor HostedRemoteConnectionManager {
    enum Failure: LocalizedError {
        case pairingRequired
        var errorDescription: String? {
            MobileL10n.string("Pair this Mac again by scanning its current code before using Threading Direct.")
        }
    }
    typealias Connector = @Sendable (
        PeerControlPlaneServiceEndpoint,
        PeerDeviceServiceCredential,
        @escaping @Sendable (PeerHostedDeviceConnectionPhase) -> Void
    ) async throws -> any HostedRemoteTunnel

    private struct RouteKey: Equatable, Sendable {
        let serviceURL: URL
        let credential: PeerDeviceServiceCredential
        let pins: RemoteHostPinSet
    }

    private struct Active {
        let key: RouteKey
        let tunnel: any HostedRemoteTunnel
        let route: HostedRemoteRoute
    }

    private struct Pending {
        let id: UUID
        let key: RouteKey
        let task: Task<HostedRemoteRoute, Error>
    }

    private var active: Active?
    private var pending: Pending?
    private let connect: Connector

    init(connect: @escaping Connector = { endpoint, credential, progress in
        try await HostedRemoteConnectionManager.connectTunnel(
            endpoint: endpoint, credential: credential, progress: progress
        )
    }) {
        self.connect = connect
    }

    func route(
        for host: PairedRemoteHost,
        trace: String? = nil
    ) async throws -> HostedRemoteRoute? {
        guard let serviceURL = host.hostedServiceURL,
              let credential = host.hostedCredential,
              credential.hostID == host.hostID,
              credential.deviceID == host.hostedDeviceID,
              credential.expiresAt > Date().addingTimeInterval(60)
        else {
            return nil
        }
        guard host.hasPairedIdentity, let pins = host.pinSet else { throw Failure.pairingRequired }
        let endpoint = try PeerControlPlaneServiceEndpoint(serviceURL)
        let key = RouteKey(serviceURL: endpoint.baseURL, credential: credential, pins: pins)
        if let active, active.key == key {
            if active.tunnel.isActive { return active.route }
            // The tunnel ended by itself: its transport closed or failed and it stopped its
            // proxy. It is not a route any more, so it is dropped here and negotiated again
            // rather than handed out for one more dial that cannot connect.
            self.active = nil
        }

        if let pending, pending.key == key {
            return try await pending.task.value
        }

        pending?.task.cancel()
        let startedAt = MobileDiagnostics.monotonicNow()
        let peer = MobileDiagnostics.pseudonym(host.id, prefix: "peer")
        let pendingID = UUID()
        let task = Task {
            let tunnel = try await connect(endpoint, credential) { phase in
                guard let trace else { return }
                MobileDiagnostics.recordConnectivity(.hostRouteProgress, fields: [
                    .trace: trace,
                    .peer: peer,
                    .transport: RemoteHostEndpointKind.hosted.rawValue,
                    .phase: "hosted.\(phase.rawValue)",
                    .result: "stage",
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                    .timeoutMS: MobileDiagnostics.milliseconds(
                        PeerTransportBounds.negotiationTimeout
                    ),
                ])
            }
            // The shared task installs once. Its waiters borrow the resulting route; none of
            // them may dispose of the same tunnel as if it were a duplicate connection.
            return try install(tunnel: tunnel, key: key, host: host, pendingID: pendingID)
        }
        let pending = Pending(id: pendingID, key: key, task: task)
        self.pending = pending
        do {
            return try await task.value
        } catch {
            if self.pending?.id == pending.id { self.pending = nil }
            throw error
        }
    }

    func invalidate(hostID: String? = nil) {
        if hostID == nil || active?.key.credential.hostID == hostID {
            active?.tunnel.stop()
            active = nil
        }
        if hostID == nil || pending?.key.credential.hostID == hostID {
            pending?.task.cancel()
            pending = nil
        }
    }

    private func install(
        tunnel: any HostedRemoteTunnel,
        key: RouteKey,
        host: PairedRemoteHost,
        pendingID: UUID
    ) throws -> HostedRemoteRoute {
        guard pending?.id == pendingID,
              tunnel.isActive,
              tunnel.origin.scheme == "https",
              let pins = host.pinSet,
              let link = RemoteConnectionLink(baseURL: tunnel.origin, token: host.link.token),
              let trust = RemoteClient.pinningDelegate.register(pins, forOrigin: tunnel.origin)
        else {
            tunnel.stop()
            throw CancellationError()
        }
        active?.tunnel.stop()
        let route = HostedRemoteRoute(link: link, tunnel: tunnel, trust: trust)
        active = Active(key: key, tunnel: tunnel, route: route)
        pending = nil
        return route
    }

    private static func connectTunnel(
        endpoint: PeerControlPlaneServiceEndpoint,
        credential: PeerDeviceServiceCredential,
        progress: @escaping @Sendable (PeerHostedDeviceConnectionPhase) -> Void
    ) async throws -> any HostedRemoteTunnel {
        let rendezvousCredential = try credential.credential.withValue {
            try PeerRendezvousCredential($0)
        }
        return try await PeerHostedDeviceConnector.connect(
            endpoint: endpoint.rendezvousEndpoint,
            hostID: credential.hostID,
            deviceID: credential.deviceID,
            credential: rendezvousCredential,
            service: .https,
            progress: progress
        )
    }
}
