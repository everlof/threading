import Foundation
import Security
import ThreadingRemoteKit

/// A thread-safe token → authorization map. The server queue reads it on every auth check, and
/// the coordinator (main) mints and revokes into it, so it guards its own state with a lock
/// rather than borrowing the coordinator's main-actor isolation.
///
/// Durable owner devices and launch-scoped guest links are loaded into the same runtime map.
/// Stopping remote access empties this map immediately; starting it rehydrates only the owner
/// records whose per-device credentials survived in Keychain.
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
        displayName: String,
        persistsOwnerDevice: Bool
    ) -> RemoteInvitationRedemption?
}

/// The one facade the app and UI talk to for remote access: a master switch that owns the
/// server and its selected HTTPS transports, and publishes statuses other views can render.
@MainActor
final class RemoteAccessCoordinator: RemoteInvitationRedeeming {

    static let shared = RemoteAccessCoordinator(ownerDeviceStore: defaultOwnerDeviceStore())

    /// Posted whenever `status` changes, so a Settings page can redraw.
    static let statusDidChange = Notification.Name("RemoteAccessStatusDidChange")

    enum Status: Equatable {
        case disabled
        case starting
        case listening(port: UInt16)
        case failed(reason: String)
    }

    private(set) var status: Status = .disabled {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
    }

    private(set) var relayStatus: RemoteTransportState = .stopped {
        didSet {
            guard relayStatus != oldValue else { return }
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
    }

    private(set) var tailscaleStatus: RemoteTransportState = .stopped {
        didSet {
            guard tailscaleStatus != oldValue else { return }
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
    }

    private let server = RemoteAccessServer()
    private let tunnel = RemoteTunnel()
    private let tailscale = TailscaleRemoteTransport()
    private let authority = RemoteAuthorityStore()
    private let ownerDevices: RemoteOwnerDeviceRegistry
    private var pairingBootstrapToken: String?
    private var pairingRedemptions: [String: PairingRedemption] = [:]
    private var sessionShares: [SessionID: [SessionShare]] = [:]
    /// Invalidates a listener completion that was already enqueued on main when the user
    /// switched the feature off. Without it, a fast off-after-on could put the UI back into
    /// `listening` after `stop()` had already closed the listener and revoked its token.
    private var lifecycleGeneration = 0
    /// Transport callbacks have their own generation because changing Relay/Tailscale mode keeps
    /// the listener and all current authorizations alive.
    private var transportGeneration = 0

    private init(ownerDeviceStore: RemoteOwnerDevicePersisting) {
        ownerDevices = RemoteOwnerDeviceRegistry(store: ownerDeviceStore)
        server.authorizer = authority
        server.invitationRedeemer = self
    }

    private static func defaultOwnerDeviceStore() -> RemoteOwnerDevicePersisting {
        if NSClassFromString("XCTestCase") != nil {
            return InMemoryRemoteOwnerDeviceStore()
        }
        return RemoteOwnerDeviceKeychainStore()
    }

    private struct PairingRedemption {
        let deviceID: String
        let redemption: RemoteInvitationRedemption
        let expiresAt: Date
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

    struct PairedOwnerDevice: Equatable, Identifiable {
        let id: String
        let displayName: String
        let pairedAt: Date
        let lastSeenAt: Date?
    }

    var pairedOwnerDevices: [PairedOwnerDevice] {
        ownerDevices.devices
            .map {
                PairedOwnerDevice(
                    id: $0.id,
                    displayName: $0.displayName,
                    pairedAt: $0.pairedAt,
                    lastSeenAt: $0.lastSeenAt
                )
            }
            .sorted { $0.pairedAt < $1.pairedAt }
    }

    var ownerDevicePersistenceError: String? { ownerDevices.persistenceError }

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

    /// The local browser pairing door for this launch. The bootstrap bearer stays in the
    /// fragment and is exchanged for a device-bound credential before any session is returned.
    var localURL: URL? {
        guard case .listening(let port) = status, let pairingBootstrapToken else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = RemoteAccessDefaults.host
        components.port = Int(port)
        components.path = "/"
        components.fragment = pairingBootstrapToken
        return components.url
    }

    /// The HTTPS door intended for another device. Nil while the selected pairing transport is
    /// still starting or unavailable; the local browser link remains usable independently.
    var remoteURL: URL? {
        guard ownerDevices.persistenceError == nil,
              let origin = pairingOrigin,
              let pairingBootstrapToken else { return nil }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.fragment = pairingBootstrapToken
        return components?.url
    }

    /// The same door as `remoteURL`, written the way a QR code wants to read it.
    ///
    /// Separate from `remoteURL` because the two have different readers: a person pasting a
    /// link should see the ordinary lower-case URL, and a scanner should get the form that
    /// encodes in half the symbol. `RemoteConnectionLink` owns the difference, and normalises
    /// the case back on the way in, so both are the same credential.
    var pairingCodePayload: String? {
        guard ownerDevices.persistenceError == nil,
              let origin = pairingOrigin,
              let pairingBootstrapToken,
              let link = RemoteConnectionLink(baseURL: origin, token: pairingBootstrapToken)
        else {
            return nil
        }
        return link.scannablePayload
    }

    private var pairingOrigin: URL? {
        switch AppSettings.shared.remoteAccessConnectionMode {
        case .relay:
            if case .connected(let origin) = relayStatus { return origin }
        case .tailscale, .tailscaleAndRelay:
            if case .connected(let origin) = tailscaleStatus { return origin }
        }
        return nil
    }

    private var invitationOrigin: URL? {
        switch AppSettings.shared.remoteAccessConnectionMode {
        case .relay, .tailscaleAndRelay:
            if case .connected(let origin) = relayStatus { return origin }
        case .tailscale:
            if case .connected(let origin) = tailscaleStatus { return origin }
        }
        return nil
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
        guard invitationOrigin != nil,
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
    /// Owner bootstraps are exchanged for a unique device bearer; one-chat invitations follow
    /// the existing guest-membership path. A short retry cache makes a lost pairing response
    /// idempotent without leaving the photographed bootstrap valid for the rest of the launch.
    func redeemInvitation(
        token: String,
        deviceID: String,
        displayName: String,
        persistsOwnerDevice: Bool
    ) -> RemoteInvitationRedemption? {
        guard let normalizedDeviceID = RemoteInboundPolicy.normalizedDeviceID(deviceID),
              let normalizedName = RemoteInboundPolicy.normalizedMemberName(displayName)
        else {
            return nil
        }

        let now = Date()
        pairingRedemptions = pairingRedemptions.filter { $0.value.expiresAt > now }
        if let cached = pairingRedemptions[token], cached.deviceID == normalizedDeviceID {
            return cached.redemption
        }
        if token == pairingBootstrapToken {
            let accessToken = Self.randomToken()
            if persistsOwnerDevice {
                let previousToken = ownerDevices.devices.first(where: {
                    $0.deviceID == normalizedDeviceID
                })?.token
                return pairNewOwnerDevice(
                    bootstrap: token,
                    deviceID: normalizedDeviceID,
                    displayName: normalizedName,
                    accessToken: accessToken,
                    previousToken: previousToken,
                    now: now
                )
            } else {
                let authorization = RemoteAuthorization(
                    shareID: "owner-browser-\(UUID().uuidString.lowercased())",
                    capability: .interact,
                    scope: .allSessions,
                    principal: .ownerDevice,
                    boundDeviceID: normalizedDeviceID
                )
                authority.set(authorization, forToken: accessToken)
                return finishPairing(
                    bootstrap: token,
                    deviceID: normalizedDeviceID,
                    accessToken: accessToken,
                    authorization: authorization,
                    now: now
                )
            }
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

    private func pairNewOwnerDevice(
        bootstrap: String,
        deviceID: String,
        displayName: String,
        accessToken: String,
        previousToken: String?,
        now: Date
    ) -> RemoteInvitationRedemption? {
        guard let record = ownerDevices.pair(
            deviceID: deviceID,
            displayName: displayName,
            token: accessToken,
            now: now
        ) else {
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            return nil
        }
        if let previousToken { authority.set(nil, forToken: previousToken) }
        authority.set(record.authorization, forToken: accessToken)
        server.revokeConnections(shareID: record.id)
        return finishPairing(
            bootstrap: bootstrap,
            deviceID: deviceID,
            accessToken: accessToken,
            authorization: record.authorization,
            now: now
        )
    }

    private func finishPairing(
        bootstrap: String,
        deviceID: String,
        accessToken: String,
        authorization: RemoteAuthorization,
        now: Date
    ) -> RemoteInvitationRedemption {
        let redemption = RemoteInvitationRedemption(
            accessToken: accessToken,
            authorization: authorization
        )
        pairingRedemptions[bootstrap] = PairingRedemption(
            deviceID: deviceID,
            redemption: redemption,
            expiresAt: now.addingTimeInterval(RemoteAccessDefaults.pairingRetrySeconds)
        )
        pairingBootstrapToken = Self.pairingToken()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        return redemption
    }

    func hasSessionShares(_ sessionID: SessionID) -> Bool {
        !(sessionShares[sessionID]?.isEmpty ?? true)
    }

    /// Who can reach this chat: the people who accepted an invitation, and the invitations still
    /// waiting to be used. The owner's own paired devices are deliberately absent — they hold the
    /// owner credential rather than a share, reach every chat, and are shown by the sharing pane
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
        if ownerDevices.devices.contains(where: { $0.id == shareID }) {
            ownerDevices.noteSeen(id: shareID)
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            return
        }
        for (sessionID, shares) in sessionShares {
            for (shareIndex, share) in shares.enumerated() where share.members[shareID] != nil {
                sessionShares[sessionID]?[shareIndex].members[shareID]?.lastSeenAt = Date()
                return
            }
        }
    }

    @discardableResult
    func revokeOwnerDevice(_ deviceID: String) -> Bool {
        guard let record = ownerDevices.revoke(id: deviceID) else {
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            return false
        }
        authority.set(nil, forToken: record.token)
        RemoteNotificationService.shared.revoke(shareID: record.id)
        server.revokeConnections(shareID: record.id)
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        RemoteSessionMirrorRegistry.shared.sessionSharingChanged()
        return true
    }

    /// Full app reset is the one operation authorized to erase the Keychain record itself,
    /// including a corrupt record that ordinary fail-closed revocation refuses to overwrite.
    func deleteOwnerDevicesForAppReset() throws {
        stop()
        try ownerDevices.deleteAllForAppReset()
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
        guard let origin = invitationOrigin else { return nil }
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

    func setConnectionMode(_ mode: RemoteAccessConnectionMode) {
        guard AppSettings.shared.remoteAccessConnectionMode != mode else { return }
        AppSettings.shared.remoteAccessConnectionMode = mode
        guard case .listening(let port) = status else {
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            return
        }
        startTransports(port: port)
    }

    func retryTransports() {
        guard case .listening(let port) = status else { return }
        startTransports(port: port)
    }

    /// Stops every network door and clears runtime capabilities. Durable owner-device records
    /// remain in Keychain and are rehydrated on the next start; guest shares stay deliberately
    /// launch-scoped and are revoked here.
    func stop() {
        lifecycleGeneration += 1
        stopTransports()
        server.stop()
        RemoteSessionMirrorRegistry.shared.remoteAccessStopped()
        RemoteNotificationService.shared.reset()
        authority.removeAll()
        pairingBootstrapToken = nil
        pairingRedemptions.removeAll()
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

        // The photographed value is a bootstrap, never the durable capability. It is consumed
        // and rotated when a device exchanges it for its own 256-bit bearer.
        let token = Self.pairingToken()
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        pairingBootstrapToken = token
        pairingRedemptions.removeAll()
        status = .starting
        stopTransports()
        authority.removeAll()
        for record in ownerDevices.devices {
            authority.set(record.authorization, forToken: record.token)
        }

        server.start { [weak self] port in
            guard let self else { return }
            guard self.lifecycleGeneration == generation,
                  AppSettings.shared.remoteAccessEnabled else {
                return
            }
            if let port {
                self.status = .listening(port: port)
                RemoteSessionMirrorRegistry.shared.remoteAccessStarted()
                self.startTransports(port: port)
                ThreadingLogger.remote.info(
                    "Remote access local URL: http://127.0.0.1:\(port)/#\(token, privacy: .private)"
                )
                EventLog.shared.record(.remote, "Remote access started", ["port": String(port)])
                MacRemoteDiagnostics.record(.hostListenerStarted, fields: [
                    .transport: "loopback",
                ])
            } else {
                self.stopTransports()
                self.authority.removeAll()
                self.pairingBootstrapToken = nil
                self.pairingRedemptions.removeAll()
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

    // MARK: - Transports

    private func startTransports(port: UInt16) {
        transportGeneration += 1
        let generation = transportGeneration
        tunnel.stop()
        tailscale.stop()
        relayStatus = .stopped
        tailscaleStatus = .stopped

        let mode = AppSettings.shared.remoteAccessConnectionMode
        if mode.usesRelay {
            relayStatus = .starting
            tunnel.start(port: port) { [weak self] state in
                self?.transportChanged(
                    .relay,
                    state: state,
                    generation: generation
                )
            }
        }
        if mode.usesTailscale {
            tailscaleStatus = .starting
            tailscale.start(port: port) { [weak self] state in
                self?.transportChanged(
                    .tailscale,
                    state: state,
                    generation: generation
                )
            }
        }
    }

    private func stopTransports() {
        transportGeneration += 1
        tunnel.stop()
        tailscale.stop()
        relayStatus = .stopped
        tailscaleStatus = .stopped
    }

    private func transportChanged(
        _ kind: RemoteTransportKind,
        state: RemoteTransportState,
        generation: Int
    ) {
        guard transportGeneration == generation,
              AppSettings.shared.remoteAccessEnabled,
              case .listening = status else { return }
        switch kind {
        case .relay: relayStatus = state
        case .tailscale: tailscaleStatus = state
        }

        switch state {
        case .connected:
            MacRemoteDiagnostics.record(.relayConnected, fields: [
                .transport: kind.rawValue,
            ])
            EventLog.shared.record(.remote, "Remote transport connected", [
                "transport": kind.rawValue,
            ])
        case .unavailable(let reason):
            MacRemoteDiagnostics.record(
                .relayFailed,
                level: .warning,
                fields: [
                    .transport: kind.rawValue,
                    .reason: Self.diagnosticReason(reason),
                ]
            )
            EventLog.shared.record(.remote, "Remote transport unavailable", [
                "transport": kind.rawValue,
                "reason": Self.diagnosticReason(reason),
            ])
        case .stopped, .starting:
            break
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

    /// The one-time owner bootstrap, which is the one token that has to survive being
    /// *photographed*.
    ///
    /// Base32 rather than base64url, and 16 bytes rather than 32, because this token is the
    /// tail of a QR payload: base64url is mixed case, so it forces a byte-mode segment worth
    /// 8 bits a character where base32's uppercase alphabet encodes at 5.5. Against a median
    /// `trycloudflare.com` host that is 41 modules before and 37 after — and a symbol with
    /// fewer, larger modules is one a camera finds faster, which is the whole job here.
    ///
    /// 128 bits, not 256. It is an unguessable online-only bootstrap, held in memory, rotated
    /// immediately after a successful exchange, and revoked when Remote Access stops.
    /// Shortening it further would reach 33 modules, and that is where this stops: the trade
    /// turns from "spend entropy nobody can use" into "spend entropy", and a code that is 10%
    /// chunkier is not worth arguing about the second one.
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
