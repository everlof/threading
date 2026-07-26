import Foundation
import Security
import SkalmanRemoteKit

/// A thread-safe token → authorization map. The server queue reads it on every auth check, and
/// the coordinator (main) mints and revokes into it, so it guards its own state with a lock
/// rather than borrowing the coordinator's main-actor isolation.
///
/// Owner pairing and exact-session guest links are all launch-scoped today. A future persisted
/// device/share store can replace this in-memory authority without changing server routing.
final class RemoteAuthorityStore: RemoteAuthorizing {
    private let lock = NSLock()
    private var byToken: [String: RemoteAuthorization] = [:]

    func authorization(forToken token: String) -> RemoteAuthorization? {
        lock.lock(); defer { lock.unlock() }
        guard let authorization = byToken[token] else { return nil }
        if authorization.isExpired {
            byToken[token] = nil
            return nil
        }
        return authorization
    }

    func set(_ authorization: RemoteAuthorization?, forToken token: String) {
        lock.lock(); defer { lock.unlock() }
        byToken[token] = authorization
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        byToken.removeAll()
    }
}

struct RemoteInvitationRedemption {
    let accessToken: String
    let authorization: RemoteAuthorization
}

@MainActor
protocol RemoteInvitationRedeeming: AnyObject {
    func redeemInvitation(
        token: String,
        deviceID: String,
        displayName: String
    ) -> RemoteInvitationRedemption?
}

/// The one facade the app and UI talk to for remote access: a master switch that owns the
/// server and HTTPS relay, and publishes statuses other views can render.
@MainActor
final class RemoteAccessCoordinator: RemoteInvitationRedeeming {

    static let shared = RemoteAccessCoordinator()

    /// Posted whenever `status` changes, so a Settings page can redraw.
    static let statusDidChange = Notification.Name("RemoteAccessStatusDidChange")

    enum Status: Equatable {
        case disabled
        case starting
        case listening(port: UInt16)
        case failed(reason: String)
    }

    enum RelayStatus: Equatable {
        case inactive
        case starting
        case connected(URL)
        case unavailable(String)
    }

    private(set) var status: Status = .disabled {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
    }

    private(set) var relayStatus: RelayStatus = .inactive {
        didSet {
            guard relayStatus != oldValue else { return }
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
    }

    private let server = RemoteAccessServer()
    private let tunnel = RemoteTunnel()
    private let authority = RemoteAuthorityStore()
    private var ownerToken: String?
    private var sessionShares: [SessionID: [SessionShare]] = [:]
    /// Invalidates a listener completion that was already enqueued on main when the user
    /// switched the feature off. Without it, a fast off-after-on could put the UI back into
    /// `listening` after `stop()` had already closed the listener and revoked its token.
    private var lifecycleGeneration = 0

    private init() {
        server.authorizer = authority
        server.invitationRedeemer = self
    }

    private struct MemberRecord {
        let token: String
        let authorization: RemoteAuthorization
    }

    private struct SessionShare {
        let id: String
        var invitationToken: String?
        let capability: RemoteCapability
        let canApprovePermissions: Bool
        let expiresAt: Date
        var members: [String: MemberRecord]
    }

    struct CreatedShare {
        let url: URL
        let expiresAt: Date
        let canApprovePermissions: Bool
    }

    /// The local browser door for this launch. The bearer stays in the fragment, which browsers
    /// do not send in the HTTP request or a referrer. It is intentionally not persisted: turning
    /// access off, or quitting Skalman, invalidates every copied link.
    var localURL: URL? {
        guard case .listening(let port) = status, let ownerToken else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = RemoteAccessDefaults.host
        components.port = Int(port)
        components.path = "/"
        components.fragment = ownerToken
        return components.url
    }

    /// The HTTPS door intended for another device. Nil while the relay is still starting or
    /// unavailable; the local browser link remains usable independently.
    var remoteURL: URL? {
        guard case .connected(let origin) = relayStatus, let ownerToken else { return nil }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.fragment = ownerToken
        return components?.url
    }

    /// Mints a short-lived, single-use invitation for exactly one chat.
    ///
    /// This is deliberately separate from `remoteURL`, which is the owner's pairing door.
    /// Accepting it exchanges the invitation bearer for a device-bound membership bearer that
    /// remains valid until sharing is stopped. Copying the invite can therefore never leak the
    /// dashboard or another session.
    func shareURL(
        for sessionID: SessionID,
        capability: RemoteCapability = .view,
        canApprovePermissions: Bool = false
    ) -> URL? {
        createSessionShare(
            for: sessionID,
            capability: capability,
            canApprovePermissions: canApprovePermissions
        )?.url
    }

    func createSessionShare(
        for sessionID: SessionID,
        capability: RemoteCapability,
        canApprovePermissions requestedPermissionApproval: Bool = false
    ) -> CreatedShare? {
        guard case .connected(let origin) = relayStatus,
              RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID))
        else {
            return nil
        }

        let invitationToken = Self.randomToken()
        let id = UUID().uuidString.lowercased()
        let expiresAt = Date().addingTimeInterval(RemoteAccessDefaults.defaultShareExpiry)
        let canApprovePermissions =
            requestedPermissionApproval && capability == .interact
        let share = SessionShare(
            id: id,
            invitationToken: invitationToken,
            capability: capability,
            canApprovePermissions: canApprovePermissions,
            expiresAt: expiresAt,
            members: [:]
        )
        sessionShares[sessionID, default: []].append(share)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RemoteAccessDefaults.defaultShareExpiry
        ) { [weak self] in
            self?.expireInvitation(token: invitationToken, sessionID: sessionID)
        }

        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.fragment = invitationToken
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        guard let url = components?.url else {
            sessionShares[sessionID]?.removeAll { $0.id == id }
            return nil
        }
        RemoteSessionMirrorRegistry.shared.sessionSharingChanged()
        return CreatedShare(
            url: url,
            expiresAt: expiresAt,
            canApprovePermissions: canApprovePermissions
        )
    }

    /// Consumes one invitation and returns a durable, device-bound chat membership.
    ///
    /// "Durable" means until the owner stops sharing, Remote Access is disabled, or this Mac
    /// process exits. The 24-hour timer applies only while the invitation remains unused.
    func redeemInvitation(
        token: String,
        deviceID: String,
        displayName: String
    ) -> RemoteInvitationRedemption? {
        guard let normalizedDeviceID = RemoteInboundPolicy.normalizedDeviceID(deviceID),
              let normalizedName = RemoteInboundPolicy.normalizedMemberName(displayName)
        else {
            return nil
        }

        for sessionID in Array(sessionShares.keys) {
            guard var shares = sessionShares[sessionID],
                  let index = shares.firstIndex(where: {
                      $0.invitationToken == token && $0.expiresAt > Date()
                  }) else {
                continue
            }

            var share = shares[index]
            let memberID = UUID().uuidString.lowercased()
            let accessToken = Self.randomToken()
            let member = RemoteMember(
                id: memberID,
                displayName: normalizedName,
                deviceID: normalizedDeviceID
            )
            let authorization = RemoteAuthorization(
                shareID: memberID,
                capability: share.capability,
                scope: .session(sessionID),
                principal: .guest,
                member: member,
                canApprovePermissions: share.canApprovePermissions
            )
            share.invitationToken = nil
            share.members[memberID] = MemberRecord(
                token: accessToken,
                authorization: authorization
            )
            shares[index] = share
            sessionShares[sessionID] = shares
            authority.set(authorization, forToken: accessToken)
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            RemoteSessionMirrorRegistry.shared.sessionSharingChanged()
            return RemoteInvitationRedemption(
                accessToken: accessToken,
                authorization: authorization
            )
        }
        return nil
    }

    func hasSessionShares(_ sessionID: SessionID) -> Bool {
        !(sessionShares[sessionID]?.isEmpty ?? true)
    }

    func revokeSessionShares(_ sessionID: SessionID) {
        for share in sessionShares.removeValue(forKey: sessionID) ?? [] {
            for member in share.members.values {
                authority.set(nil, forToken: member.token)
                RemoteNotificationService.shared.revoke(
                    shareID: member.authorization.shareID
                )
                server.revokeConnections(shareID: member.authorization.shareID)
            }
        }
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        RemoteSessionMirrorRegistry.shared.sessionSharingChanged()
    }

    private func expireInvitation(token: String, sessionID: SessionID) {
        guard let index = sessionShares[sessionID]?.firstIndex(where: {
            $0.invitationToken == token
        })
        else { return }
        // A consumed invitation has already been cleared and its membership intentionally
        // survives the invitation timer.
        let share = sessionShares[sessionID]!.remove(at: index)
        if sessionShares[sessionID]?.isEmpty == true { sessionShares[sessionID] = nil }
        for member in share.members.values {
            authority.set(nil, forToken: member.token)
            RemoteNotificationService.shared.revoke(
                shareID: member.authorization.shareID
            )
            server.revokeConnections(shareID: member.authorization.shareID)
        }
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        RemoteSessionMirrorRegistry.shared.sessionSharingChanged()
    }

    // MARK: - Master switch

    /// Called at launch. Starts the server only if the user has turned remote access on.
    func startIfEnabled() {
        guard AppSettings.shared.remoteAccessEnabled else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        AppSettings.shared.remoteAccessEnabled = enabled
        if enabled { start() } else { stop() }
    }

    /// Stops the tunnel, then the server, then forgets every token. On app quit this must
    /// run before the listeners so a child tunnel process cannot outlive the app.
    func stop() {
        lifecycleGeneration += 1
        tunnel.stop()
        relayStatus = .inactive
        server.stop()
        RemoteSessionMirrorRegistry.shared.remoteAccessStopped()
        RemoteNotificationService.shared.reset()
        authority.removeAll()
        ownerToken = nil
        sessionShares.removeAll()
        status = .disabled
    }

    // MARK: - Start

    private func start() {
        switch status {
        case .disabled:
            break
        case .failed:
            // A failed NWListener remains a listener object until it is cancelled. Clear it so
            // switching the setting on again is a real retry rather than an immediate replay of
            // the old nil port.
            server.stop()
            authority.removeAll()
        case .starting, .listening:
            return
        }

        // An in-memory owner-device token, not persisted. Settings exposes its loopback URL for
        // local testing and its relay form only in the deliberately privileged pairing sheet.
        let token = Self.randomToken()
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        ownerToken = token
        status = .starting
        relayStatus = .inactive
        authority.set(
            RemoteAuthorization(
                shareID: "my-devices",
                capability: .interact,
                scope: .allSessions,
                principal: .ownerDevice
            ),
            forToken: token
        )

        server.start { [weak self] port in
            guard let self else { return }
            guard self.lifecycleGeneration == generation,
                  AppSettings.shared.remoteAccessEnabled else {
                return
            }
            if let port {
                self.status = .listening(port: port)
                RemoteSessionMirrorRegistry.shared.remoteAccessStarted()
                self.relayStatus = .starting
                self.tunnel.start(port: port) { [weak self] state in
                    guard let self,
                          self.lifecycleGeneration == generation,
                          AppSettings.shared.remoteAccessEnabled else {
                        return
                    }
                    switch state {
                    case .stopped:
                        self.relayStatus = .inactive
                    case .starting:
                        self.relayStatus = .starting
                    case .connected(let url):
                        self.relayStatus = .connected(url)
                        MacRemoteDiagnostics.record(.relayConnected, fields: [
                            .transport: "https",
                        ])
                        EventLog.shared.record(.remote, "Remote relay connected", [
                            "host": url.host ?? "unknown"
                        ])
                    case .unavailable(let reason):
                        self.relayStatus = .unavailable(reason)
                        MacRemoteDiagnostics.record(
                            .relayFailed,
                            level: .warning,
                            fields: [.reason: Self.diagnosticReason(reason)]
                        )
                        EventLog.shared.record(.remote, "Remote relay unavailable", [
                            "reason": reason
                        ])
                    }
                }
                SkalmanLogger.remote.info(
                    "Remote access local URL: http://127.0.0.1:\(port)/#\(token, privacy: .private)"
                )
                EventLog.shared.record(.remote, "Remote access started", ["port": String(port)])
                MacRemoteDiagnostics.record(.hostListenerStarted, fields: [
                    .transport: "loopback",
                ])
            } else {
                self.tunnel.stop()
                self.relayStatus = .inactive
                self.authority.removeAll()
                self.ownerToken = nil
                self.sessionShares.removeAll()
                self.status = .failed(reason: "listener")
                EventLog.shared.record(.remote, "Remote access failed to start")
                MacRemoteDiagnostics.record(
                    .hostListenerFailed,
                    level: .error,
                    fields: [.reason: "listener"]
                )
            }
        }
    }

    private static func diagnosticReason(_ reason: String) -> String {
        let lowered = reason.lowercased()
        if lowered.contains("timeout") { return "timeout" }
        if lowered.contains("network") { return "network" }
        if lowered.contains("exited") { return "process-exited" }
        return "unavailable"
    }

    // MARK: - Tokens

    /// 32 bytes of entropy, base64url, no padding — the `ExtensionHostService.randomToken`
    /// primitive. A share link's whole security rests on this being unguessable.
    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Could not generate a remote access token")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
