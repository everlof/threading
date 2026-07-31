import Foundation
import Security
import ThreadingRemoteKit

/// A thread-safe token → authorization map. The server queue reads it on every auth check, and
/// the coordinator (main) mints and revokes into it, so it guards its own state with a lock
/// rather than borrowing the coordinator's main-actor isolation.
///
/// Owner pairing and exact-session guest links are all launch-scoped today. A future persisted
/// device/share store can replace this in-memory authority without changing server routing.
final class RemoteAuthorityStore: RemoteAuthorizing, @unchecked Sendable {
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

struct RemoteInvitationRedemption: Sendable {
    let accessToken: String
    let authorization: RemoteAuthorization
}

@MainActor
protocol RemoteInvitationRedeeming: AnyObject, Sendable {
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
        let joinedAt: Date
        /// Last time this member authenticated a socket. Not "still watching" — that is a live
        /// connection, which the mirror registry knows and this store deliberately does not.
        var lastSeenAt: Date?
    }

    private struct SessionShare {
        let id: String
        var invitationToken: String?
        let capability: RemoteCapability
        let canApprovePermissions: Bool
        let createdAt: Date
        let expiresAt: Date
        var members: [String: MemberRecord]
    }

    struct CreatedShare {
        let url: URL
        let expiresAt: Date
        let canApprovePermissions: Bool
    }

    // MARK: - Access read model

    /// Everything that can reach one chat from outside this Mac, as the sharing pane shows it.
    ///
    /// Deliberately two lists rather than one: an unused link and a person are different things
    /// to look at and different things to revoke. A link that has been accepted is no longer a
    /// link — it became the membership below it — which is why `links` only ever holds the
    /// invitations still waiting to be used.
    struct SessionAccess: Equatable {
        var members: [Member] = []
        var links: [Link] = []

        var isEmpty: Bool { members.isEmpty && links.isEmpty }

        struct Member: Equatable, Identifiable {
            let id: String
            let displayName: String
            let deviceID: String
            let capability: RemoteCapability
            let canApprovePermissions: Bool
            let joinedAt: Date
            let lastSeenAt: Date?
        }

        struct Link: Equatable, Identifiable {
            let id: String
            let capability: RemoteCapability
            let canApprovePermissions: Bool
            let createdAt: Date
            let expiresAt: Date
            /// The invitation URL, so the pane can offer to copy it again. Held only while the
            /// link is unused; accepting one clears it here as well as on the wire.
            let url: URL?
        }
    }

    /// The local browser door for this launch. The bearer stays in the fragment, which browsers
    /// do not send in the HTTP request or a referrer. It is intentionally not persisted: turning
    /// access off, or quitting Threading, invalidates every copied link.
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

    /// The same door as `remoteURL`, written the way a QR code wants to read it.
    ///
    /// Separate from `remoteURL` because the two have different readers: a person pasting a
    /// link should see the ordinary lower-case URL, and a scanner should get the form that
    /// encodes in half the symbol. `RemoteConnectionLink` owns the difference, and normalises
    /// the case back on the way in, so both are the same credential.
    var pairingCodePayload: String? {
        guard case .connected(let origin) = relayStatus,
              let ownerToken,
              let link = RemoteConnectionLink(baseURL: origin, token: ownerToken)
        else {
            return nil
        }
        return link.scannablePayload
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
        guard case .connected = relayStatus,
              RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID))
        else {
            return nil
        }

        let invitationToken = Self.randomToken()
        let id = UUID().uuidString.lowercased()
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(RemoteAccessDefaults.defaultShareExpiry)
        let canApprovePermissions =
            requestedPermissionApproval && capability == .interact
        let share = SessionShare(
            id: id,
            invitationToken: invitationToken,
            capability: capability,
            canApprovePermissions: canApprovePermissions,
            createdAt: createdAt,
            expiresAt: expiresAt,
            members: [:]
        )
        sessionShares[sessionID, default: []].append(share)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RemoteAccessDefaults.defaultShareExpiry
        ) { [weak self] in
            self?.expireInvitation(token: invitationToken, sessionID: sessionID)
        }

        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        guard let url = invitationURL(token: invitationToken) else {
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
                authorization: authorization,
                joinedAt: Date()
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

    /// Who can reach this chat: the people who accepted an invitation, and the invitations still
    /// waiting to be used. The owner's own paired devices are deliberately absent — they hold the
    /// pairing token rather than a share, reach every chat, and are shown by the sharing pane
    /// from the live connection instead, where they can be told apart from a guest.
    func access(for sessionID: SessionID) -> SessionAccess {
        let shares = sessionShares[sessionID] ?? []
        var access = SessionAccess()

        for share in shares {
            for record in share.members.values {
                guard let member = record.authorization.member else { continue }
                access.members.append(SessionAccess.Member(
                    id: member.id,
                    displayName: member.displayName,
                    deviceID: member.deviceID,
                    capability: record.authorization.capability,
                    canApprovePermissions: record.authorization.canApprovePermissions,
                    joinedAt: record.joinedAt,
                    lastSeenAt: record.lastSeenAt
                ))
            }
            guard let invitationToken = share.invitationToken,
                  share.expiresAt > Date() else { continue }
            access.links.append(SessionAccess.Link(
                id: share.id,
                capability: share.capability,
                canApprovePermissions: share.canApprovePermissions,
                createdAt: share.createdAt,
                expiresAt: share.expiresAt,
                url: invitationURL(token: invitationToken)
            ))
        }

        access.members.sort { $0.joinedAt < $1.joinedAt }
        access.links.sort { $0.createdAt < $1.createdAt }
        return access
    }

    /// Records that a member's bearer authenticated a socket, for the pane's "last seen".
    ///
    /// Keyed by `shareID`, which for a membership *is* the member id — the authorization a
    /// connection carries has no other back-reference to the share it came from.
    func noteMemberSeen(shareID: String) {
        for (sessionID, shares) in sessionShares {
            for (shareIndex, share) in shares.enumerated() where share.members[shareID] != nil {
                sessionShares[sessionID]?[shareIndex].members[shareID]?.lastSeenAt = Date()
                return
            }
        }
    }

    /// Ends one person's access to one chat, closing whatever they have open.
    ///
    /// The share they came through stays only if it still has other members: an invitation is
    /// single-use, so a share whose one member is gone has nothing left to grant.
    @discardableResult
    func revokeMember(_ memberID: String, in sessionID: SessionID) -> Bool {
        guard var shares = sessionShares[sessionID] else { return false }
        for (index, share) in shares.enumerated() {
            guard let record = share.members[memberID] else { continue }
            revoke(record)
            shares[index].members[memberID] = nil
            if shares[index].members.isEmpty, shares[index].invitationToken == nil {
                shares.remove(at: index)
            }
            sessionShares[sessionID] = shares.isEmpty ? nil : shares
            sharingChanged()
            return true
        }
        return false
    }

    /// Withdraws a link that has not been used. Anyone who already accepted it keeps their
    /// access — they are a member now, and revoking a person is its own act.
    @discardableResult
    func revokeLink(_ shareID: String, in sessionID: SessionID) -> Bool {
        guard var shares = sessionShares[sessionID],
              let index = shares.firstIndex(where: { $0.id == shareID }),
              shares[index].invitationToken != nil else {
            return false
        }
        shares[index].invitationToken = nil
        if shares[index].members.isEmpty {
            shares.remove(at: index)
        }
        sessionShares[sessionID] = shares.isEmpty ? nil : shares
        sharingChanged()
        return true
    }

    func revokeSessionShares(_ sessionID: SessionID) {
        for share in sessionShares.removeValue(forKey: sessionID) ?? [] {
            for member in share.members.values { revoke(member) }
        }
        sharingChanged()
    }

    private func revoke(_ member: MemberRecord) {
        authority.set(nil, forToken: member.token)
        RemoteNotificationService.shared.revoke(shareID: member.authorization.shareID)
        server.revokeConnections(shareID: member.authorization.shareID)
    }

    private func sharingChanged() {
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        RemoteSessionMirrorRegistry.shared.sessionSharingChanged()
    }

    private func invitationURL(token: String) -> URL? {
        guard case .connected(let origin) = relayStatus else { return nil }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.fragment = token
        return components?.url
    }

    private func expireInvitation(token: String, sessionID: SessionID) {
        guard var shares = sessionShares[sessionID],
              let index = shares.firstIndex(where: {
            $0.invitationToken == token
        })
        else { return }
        // A consumed invitation has already been cleared and its membership intentionally
        // survives the invitation timer.
        let share = shares.remove(at: index)
        sessionShares[sessionID] = shares.isEmpty ? nil : shares
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
        let token = Self.pairingToken()
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
                ThreadingLogger.remote.info(
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
        Data(entropy(bytes: 32)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The owner bearer, which is the one token that has to survive being *photographed*.
    ///
    /// Base32 rather than base64url, and 16 bytes rather than 32, because this token is the
    /// tail of a QR payload: base64url is mixed case, so it forces a byte-mode segment worth
    /// 8 bits a character where base32's uppercase alphabet encodes at 5.5. Against a median
    /// `trycloudflare.com` host that is 41 modules before and 37 after — and a symbol with
    /// fewer, larger modules is one a camera finds faster, which is the whole job here.
    ///
    /// 128 bits, not 256. It is still an unguessable online-only bearer against a secret
    /// relay hostname, held in memory and revoked when Remote Access stops. Shortening it
    /// further would reach 33 modules, and that is where this stops: the trade turns from
    /// "spend entropy nobody can use" into "spend entropy", and a code that is 10% chunkier is
    /// not worth arguing about the second one.
    ///
    /// **Revisit this when the relay moves off `trycloudflare.com`.** The 52-character host is
    /// what makes the token pay for the last version; against a short custom domain a 256-bit
    /// base32 token still measures 33 modules. See `docs/REMOTE_ACCESS.md` for the table.
    ///
    /// `randomToken` stays as it was for invitations and device bearers. Those travel by
    /// copied link and never by camera, so they have nothing to buy with the change.
    static func pairingToken() -> String {
        base32(entropy(bytes: 16))
    }

    private static func entropy(bytes count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "Could not generate a remote access token")
        return bytes
    }

    /// RFC 4648 base32, upper case, unpadded — every character inside QR's alphanumeric set.
    private static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output = ""
        var accumulator = 0
        var bits = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(accumulator >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            output.append(alphabet[(accumulator << (5 - bits)) & 0x1F])
        }
        return output
    }
}
