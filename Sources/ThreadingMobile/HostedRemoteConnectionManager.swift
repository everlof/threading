import Foundation
import ThreadingPeerTransport
import ThreadingRemoteKit

/// Keeps at most one iOS loopback proxy alive: the currently selected Mac. The actor also
/// coalesces concurrent refresh/mutation callers so a slow ICE negotiation cannot fan out into
/// duplicate sockets, candidate lists, or WebRTC peer connections.
actor HostedRemoteConnectionManager {
    private struct RouteKey: Equatable, Sendable {
        let serviceURL: URL
        let credential: PeerDeviceServiceCredential
    }

    private struct Active {
        let key: RouteKey
        let tunnel: PeerHostedDeviceTunnel
        let link: RemoteConnectionLink
    }

    private struct Pending {
        let id: UUID
        let key: RouteKey
        let task: Task<PeerHostedDeviceTunnel, Error>
    }

    private var active: Active?
    private var pending: Pending?

    func link(
        for host: PairedRemoteHost,
        trace: String? = nil
    ) async throws -> RemoteConnectionLink? {
        guard host.isOwnerDevice,
              let serviceURL = host.hostedServiceURL,
              let credential = host.hostedCredential,
              credential.hostID == host.hostID,
              credential.deviceID == RemoteDeviceIdentity.current,
              credential.expiresAt > Date().addingTimeInterval(60)
        else {
            return nil
        }
        let endpoint = try PeerControlPlaneServiceEndpoint(serviceURL)
        let key = RouteKey(serviceURL: endpoint.baseURL, credential: credential)
        if let active, active.key == key { return active.link }

        if let pending, pending.key == key {
            let tunnel = try await pending.task.value
            return try install(tunnel: tunnel, key: key, host: host, pendingID: pending.id)
        }

        pending?.task.cancel()
        let startedAt = MobileDiagnostics.monotonicNow()
        let peer = MobileDiagnostics.pseudonym(host.id, prefix: "peer")
        let task = Task {
            let rendezvousCredential = try credential.credential.withValue {
                try PeerRendezvousCredential($0)
            }
            return try await PeerHostedDeviceConnector.connect(
                endpoint: endpoint.rendezvousEndpoint,
                hostID: credential.hostID,
                deviceID: credential.deviceID,
                credential: rendezvousCredential,
                progress: { phase in
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
            )
        }
        let pending = Pending(id: UUID(), key: key, task: task)
        self.pending = pending
        do {
            let tunnel = try await task.value
            return try install(tunnel: tunnel, key: key, host: host, pendingID: pending.id)
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
        tunnel: PeerHostedDeviceTunnel,
        key: RouteKey,
        host: PairedRemoteHost,
        pendingID: UUID
    ) throws -> RemoteConnectionLink {
        if let active, active.key == key {
            tunnel.stop()
            if pending?.id == pendingID { pending = nil }
            return active.link
        }
        guard pending?.id == pendingID,
              let link = RemoteConnectionLink(baseURL: tunnel.origin, token: host.link.token)
        else {
            tunnel.stop()
            throw CancellationError()
        }
        active?.tunnel.stop()
        active = Active(key: key, tunnel: tunnel, link: link)
        pending = nil
        return link
    }
}
