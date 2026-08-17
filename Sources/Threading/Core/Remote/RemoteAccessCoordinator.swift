import Foundation
import Security
import ThreadingPeerTransport
import ThreadingRemoteKit

/// A thread-safe token → authorization map. The server queue reads it on every auth check, and
/// the coordinator (main) mints and revokes into it, so it guards its own state with a lock
/// rather than borrowing the coordinator's main-actor isolation.
///
/// Durable owner devices and accepted guest memberships are loaded into the same runtime map.
/// Stopping remote access empties this map immediately; starting it rehydrates every credential
/// whose source record survived in Keychain.
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

    func isCurrent(_ authorization: RemoteAuthorization) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !authorization.isExpired else { return false }
        // A single share can have several accepted members. Validate the exact authorization
        // against the active token map rather than letting one member replace another in a
        // share-ID index.
        return byToken.values.contains(authorization)
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

struct RemoteCreatedShare {
    let url: URL
    let expiresAt: Date
    let canApprovePermissions: Bool
}

enum RemoteSharePreparationError: LocalizedError {
    case remoteAccessUnavailable
    case relayUnavailable(String)
    case tooManyRequests

    var errorDescription: String? {
        switch self {
        case .remoteAccessUnavailable:
            return L10n.string("Remote Access is not ready.")
        case .relayUnavailable(let reason):
            return reason
        case .tooManyRequests:
            return L10n.string("Too many share links are being prepared. Try again shortly.")
        }
    }
}

/// The one facade the app and UI talk to for remote access: a master switch that owns the
/// server and its selected HTTPS transports, and publishes statuses other views can render.
@MainActor
final class RemoteAccessCoordinator: RemoteInvitationRedeeming, RemoteHostCommanding {

    static let shared = RemoteAccessCoordinator(
        ownerDeviceStore: defaultOwnerDeviceStore(),
        appSettings: AppSettings.shared
    )

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

    private let server: RemoteAccessServer
    private let mirrors: RemoteSessionMirrorRegistry
    private let tunnel: any RemoteRelayTransport
    private let tailscale: any RemoteTailnetTransport
    private let hostedService: RemoteHostedServiceController
    private let appSettings: AppSettings
    private let authority = RemoteAuthorityStore()
    private let ownerDevices: RemoteOwnerDeviceRegistry
    private let guestShareStore: RemoteGuestSharePersisting
    private(set) var guestSharePersistenceError: String?
    private var pairingBootstrapToken: String?
    private static let hostedPairingDeviceID = "hosted-pairing"
    private static let hostedPairingCredentialLifetimeSeconds = 5 * 60
    private var hostedPairingLink: HostedPairingLink?
    private var hostedPairingTask: Task<Void, Never>?
    private var pairingRedemptions: [String: PairingRedemption] = [:]
    private var sessionShares: [SessionID: [SessionShare]] = [:]
    private var pendingPublicShares: [UUID: PendingPublicShare] = [:]
    /// Invalidates a listener completion that was already enqueued on main when the user
    /// switched the feature off. Without it, a fast off-after-on could put the UI back into
    /// `listening` after `stop()` had already closed the listener and revoked its token.
    private var lifecycleGeneration = 0
    /// Transport callbacks have their own generation because changing Relay/Tailscale mode keeps
    /// the listener and all current authorizations alive.
    private var transportGeneration = 0

    init(
        ownerDeviceStore: RemoteOwnerDevicePersisting,
        appSettings: AppSettings,
        guestShareStore: RemoteGuestSharePersisting? = nil,
        hostedService: RemoteHostedServiceController? = nil,
        serverServices: RemoteAccessServerServices? = nil,
        relayTransport: (any RemoteRelayTransport)? = nil,
        tailnetTransport: (any RemoteTailnetTransport)? = nil
    ) {
        self.appSettings = appSettings
        tunnel = relayTransport ?? Self.defaultRelayTransport()
        tailscale = tailnetTransport ?? Self.defaultTailnetTransport()
        let services = serverServices ?? Self.makeServerServices(appSettings: appSettings)
        mirrors = services.mirrors
        server = RemoteAccessServer(services: services)
        ownerDevices = RemoteOwnerDeviceRegistry(store: ownerDeviceStore)
        self.guestShareStore = guestShareStore ?? Self.defaultGuestShareStore()
        self.hostedService = hostedService ?? RemoteHostedServiceController()
        let hostedPushService = self.hostedService
        services.notifications.configureHostedPushSender(
            isAvailable: { [weak hostedPushService] in
                hostedPushService?.canSendHostedPush == true
            },
            send: { [weak hostedPushService] event, token, environment, playsSound in
                guard let hostedPushService else {
                    return RemoteAPNSDeliveryResult(
                        statusCode: nil,
                        reason: "Hosted push service is unavailable.",
                        apnsID: nil
                    )
                }
                return await hostedPushService.sendHostedPush(
                    event: event,
                    deviceToken: token,
                    environment: environment,
                    playsSound: playsSound
                )
            }
        )
        server.authorizer = authority
        server.invitationRedeemer = self
        server.hostCommands = self
        self.hostedService.onStateChange = { [weak self] in
            self?.refreshHostedPairingLink()
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
        // Readiness steps advance while `tailscaleStatus` sits on `.starting`, so without this
        // the settings page's readiness card renders whichever step was current at the last
        // state change and freezes there until the transport connects or fails.
        tailscale.onReadinessChange = {
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
        restoreGuestShares()
    }

    /// Completes the terminal application graph before the listener can admit a request.
    /// The mirror is the same instance already injected into the server services.
    func installTerminalApplication(
        _ terminalApplication: any RemoteTerminalApplicationCapability
    ) {
        mirrors.installTerminalApplication(terminalApplication)
    }

    /// The transports the app ships with, unless a caller injected substitutes.
    ///
    /// A hosted test process gets `RefusedRemoteTransport` instead: the test bundle lives inside
    /// this app, so a test that reaches `shared` would otherwise spawn the developer's own
    /// `cloudflared` and `tailscale` and publish their Mac, leaving children behind after the run.
    /// A test that wants to observe transport behaviour injects its own double rather than
    /// relying on this.
    static func defaultRelayTransport() -> any RemoteRelayTransport {
        isHostedTestProcess ? RefusedRemoteTransport() : RemoteTunnel()
    }

    static func defaultTailnetTransport() -> any RemoteTailnetTransport {
        isHostedTestProcess ? RefusedRemoteTransport() : TailscaleRemoteTransport()
    }

    private static var isHostedTestProcess: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// The remote transport's live composition root. No route may recover one of these process
    /// services on demand; tests replace the narrow interfaces while keeping the real socket.
    static func makeServerServices(appSettings: AppSettings) -> RemoteAccessServerServices {
        let sessionStore = ProjectStore.shared
        let runtime = AgentRuntime.shared
        let eventLog = EventLog.shared
        let transcriptUsage = TranscriptUsageService.shared
        let usageHistory = UsageHistoryStore.shared

        return RemoteAccessServerServices(
            sessionQueries: sessionStore,
            sessionMutations: sessionStore,
            runtimeStatus: runtime,
            settings: LiveRemoteSettingsMutator(appSettings: appSettings),
            eventLog: eventLog,
            mirrors: .shared,
            notifications: .shared,
            archiveSync: .shared,
            snoozeCenter: .shared,
            attachments: .shared,
            extensions: .shared,
            usageDashboard: { offset, count in
                let now = Date()
                transcriptUsage.refresh()
                let report = transcriptUsage.report
                let isBuilding = transcriptUsage.isBuilding
                let snapshot = await usageHistory.loadSnapshot(
                    since: now.addingTimeInterval(-90 * 86_400),
                    now: now
                )
                let preparation = Task.detached(priority: .utility) {
                    let overview = report.flatMap {
                        UsageDashboardProjector.overview(report: $0, now: now)
                    }
                    let index = UsageDashboardProjector.limitIndex(from: snapshot, now: now)
                    return RemoteUsageBridge.dashboard(
                        overview: overview,
                        limitIndex: index,
                        isBuilding: isBuilding,
                        limitOffset: offset,
                        limitCount: count
                    )
                }
                return await preparation.value
            },
            usageLimit: { seriesID, days in
                let now = Date()
                let snapshot = await usageHistory.loadSnapshot(
                    since: now.addingTimeInterval(-90 * 86_400),
                    now: now
                )
                let preparation = Task.detached(priority: .utility) {
                    guard let series = UsageDashboardProjector.limitSeries(
                        from: snapshot,
                        seriesID: seriesID,
                        now: now
                    ) else { return nil as RemoteUsageLimitDTO? }
                    return RemoteUsageBridge.limit(series: series, days: days, preparedAt: now)
                }
                return await preparation.value
            }
        )
    }

    private static func defaultOwnerDeviceStore() -> RemoteOwnerDevicePersisting {
        if NSClassFromString("XCTestCase") != nil {
            return InMemoryRemoteOwnerDeviceStore()
        }
        return RemoteOwnerDeviceKeychainStore()
    }

    private static func defaultGuestShareStore() -> RemoteGuestSharePersisting {
        if NSClassFromString("XCTestCase") != nil {
            return InMemoryRemoteGuestShareStore()
        }
        return RemoteGuestShareKeychainStore()
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

    private struct PendingPublicShare {
        let sessionID: SessionID
        let capability: RemoteCapability
        let canApprovePermissions: Bool
        let completion: @MainActor (
            Result<RemoteCreatedShare, RemoteSharePreparationError>
        ) -> Void
    }

    var tailscaleReadiness: TailscaleReadiness { tailscale.readiness }
    var hostedServiceState: RemoteHostedServiceState { hostedService.state }

    /// Installed by the application composition root before the listener is allowed to start.
    var sessionCommands: (any RemoteSessionCommands)? {
        get { server.sessionCommands }
        set { server.sessionCommands = newValue }
    }

    func signInHostedService(
        identityToken: String,
        authorizationCode: String,
        rawNonce: String
    ) async throws {
        try await hostedService.signInWithApple(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            rawNonce: rawNonce
        )
    }

    func signOutHostedService() async throws {
        try await hostedService.signOut()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    func deleteHostedServiceAccount() async throws {
        try await hostedService.deleteAccount()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    var canIssueHostedDeviceCredentials: Bool {
        hostedService.canIssueDeviceCredentials
    }

    func issueHostedDeviceCredential(deviceID: String) async throws
        -> RemoteHostedDeviceCredentialDTO {
        guard let serviceURL = hostedService.serviceURL else {
            throw PeerControlPlaneError.invalidEndpoint
        }
        let issued = try await hostedService.issueDeviceCredential(deviceID: deviceID)
        return issued.credential.withValue { credential in
            RemoteHostedDeviceCredentialDTO(
                serviceURL: serviceURL.absoluteString,
                hostID: issued.hostID,
                deviceID: issued.deviceID,
                credential: credential,
                expiresAt: issued.expiresAt.timeIntervalSince1970 * 1_000
            )
        }
    }

    /// The stable host plus the routes an owner is allowed to consider. Guest payloads omit the
    /// list so a public one-chat invitation never reveals the owner's private tailnet hostname.
    func hostIdentity(for authorization: RemoteAuthorization) -> RemoteHostDTO {
        let identity = RemoteHostIdentity.current
        guard authorization.canManageHost else { return identity }

        let mode = appSettings.remoteAccessConnectionMode
        var endpoints: [RemoteHostEndpointDTO] = []
        if mode.usesTailscale, case .connected(let origin) = tailscaleStatus {
            endpoints.append(RemoteHostEndpointDTO(
                kind: RemoteTransportKind.tailscale.rawValue,
                baseURL: origin,
                isStable: true
            ))
        }
        let allowsRelay = mode == .relay
            || (mode == .tailscaleAndRelay
                && appSettings.remoteAccessAllowsOwnerRelayFallback)
        if allowsRelay, case .connected(let origin) = relayStatus {
            endpoints.append(RemoteHostEndpointDTO(
                kind: RemoteTransportKind.relay.rawValue,
                baseURL: origin,
                isStable: !Self.isQuickRelay(origin)
            ))
        }

        let policy: RemoteHostConnectionPolicy
        switch mode {
        case .relay:
            policy = .relayOnly
        case .tailscale:
            policy = .privateOnly
        case .tailscaleAndRelay:
            policy = appSettings.remoteAccessAllowsOwnerRelayFallback
                ? .preferPrivate
                : .privateOnly
        }
        return RemoteHostDTO(
            id: identity.id,
            name: identity.name,
            platform: identity.platform,
            endpoints: endpoints,
            connectionPolicy: policy
        )
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
              let pairingBootstrapToken
        else {
            return nil
        }
        if let hostedPairingLink,
           hostedPairingLink.bootstrapToken == pairingBootstrapToken,
           !hostedPairingLink.isExpired {
            return hostedPairingLink.scannablePayload
        }
        guard let origin = pairingOrigin,
              let link = RemoteConnectionLink(baseURL: origin, token: pairingBootstrapToken)
        else { return nil }
        return link.scannablePayload
    }

    private var pairingOrigin: URL? {
        switch appSettings.remoteAccessConnectionMode {
        case .relay:
            if case .connected(let origin) = relayStatus { return origin }
        case .tailscale, .tailscaleAndRelay:
            if case .connected(let origin) = tailscaleStatus { return origin }
        }
        return nil
    }

    private var invitationOrigin: URL? {
        switch appSettings.remoteAccessConnectionMode {
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
    func createSessionShare(
        for sessionID: SessionID,
        capability: RemoteCapability,
        canApprovePermissions requestedPermissionApproval: Bool = false,
        completion: @escaping @MainActor (
            Result<RemoteCreatedShare, RemoteSharePreparationError>
        ) -> Void
    ) {
        guard RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID)),
              case .listening = status else {
            completion(.failure(.remoteAccessUnavailable))
            return
        }

        if invitationOrigin != nil {
            guard let created = createSessionShareNow(
                for: sessionID,
                capability: capability,
                canApprovePermissions: requestedPermissionApproval
            ) else {
                completion(.failure(.remoteAccessUnavailable))
                return
            }
            completion(.success(created))
            return
        }

        guard pendingPublicShares.count < RemoteAccessDefaults.maximumPendingSharePreparations
        else {
            completion(.failure(.tooManyRequests))
            return
        }

        let requestID = UUID()
        pendingPublicShares[requestID] = PendingPublicShare(
            sessionID: sessionID,
            capability: capability,
            canApprovePermissions: requestedPermissionApproval,
            completion: completion
        )
        startInvitationTransportIfNeeded()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RemoteAccessDefaults.sharePreparationTimeout
        ) { [weak self] in
            guard let self, let pending = self.pendingPublicShares.removeValue(
                forKey: requestID
            ) else { return }
            self.reconcileRelayIfNeeded()
            pending.completion(.failure(.relayUnavailable(
                L10n.string("The sharing connection timed out. Try again.")
            )))
        }
    }

    private func createSessionShareNow(
        for sessionID: SessionID,
        capability: RemoteCapability,
        canApprovePermissions requestedPermissionApproval: Bool
    ) -> RemoteCreatedShare? {
        guard invitationOrigin != nil else { return nil }

        guard let invitationToken = Self.randomToken() else {
            ThreadingLogger.remote.error(
                "Remote credential generation failed stage=guest_invitation"
            )
            return nil
        }
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
        guard let url = invitationURL(token: invitationToken) else { return nil }
        var candidate = sessionShares
        candidate[sessionID, default: []].append(share)
        guard persistGuestShares(candidate) else { return nil }
        sessionShares = candidate
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RemoteAccessDefaults.defaultShareExpiry
        ) { [weak self] in
            self?.expireInvitation(token: invitationToken, sessionID: sessionID)
        }

        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        mirrors.sessionSharingChanged()
        ThreadingLogger.remote.info(
            "Remote guest invitation created session=\(sessionID.rawValue, privacy: .public) capability=\(capability.rawValue, privacy: .public) permission_approval=\(canApprovePermissions, privacy: .public)"
        )
        return RemoteCreatedShare(
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
            guard let accessToken = Self.randomToken() else {
                ThreadingLogger.remote.error(
                    "Remote credential generation failed stage=owner_access"
                )
                return nil
            }
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
                ThreadingLogger.remote.notice(
                    "Remote owner browser paired persistent=false"
                )
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
            guard let accessToken = Self.randomToken() else {
                ThreadingLogger.remote.error(
                    "Remote credential generation failed stage=guest_access"
                )
                return nil
            }
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
            var candidate = sessionShares
            candidate[sessionID] = shares
            guard persistGuestShares(candidate) else { return nil }
            sessionShares = candidate
            authority.set(authorization, forToken: accessToken)
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            mirrors.sessionSharingChanged()
            ThreadingLogger.remote.notice(
                "Remote guest invitation redeemed session=\(sessionID.rawValue, privacy: .public) capability=\(share.capability.rawValue, privacy: .public) permission_approval=\(share.canApprovePermissions, privacy: .public)"
            )
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
        ThreadingLogger.remote.notice(
            "Remote owner device paired rotated=\(previousToken != nil, privacy: .public)"
        )
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
        // The consumed bootstrap must never remain valid because rotation failed. Nil leaves
        // existing device bearers working while refusing another pairing until a restart can
        // obtain fresh entropy.
        pairingBootstrapToken = Self.pairingToken()
        if pairingBootstrapToken == nil {
            ThreadingLogger.remote.error(
                "Remote credential generation failed stage=pairing_rotation"
            )
        }
        retireHostedPairingLink(after: RemoteAccessDefaults.pairingRetrySeconds)
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
                var candidate = sessionShares
                candidate[sessionID]?[shareIndex].members[shareID]?.lastSeenAt = Date()
                if persistGuestShares(candidate) { sessionShares = candidate }
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
        hostedService.revokeDevice(deviceID: record.deviceID)
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        mirrors.sessionSharingChanged()
        ThreadingLogger.remote.notice("Remote owner device revoked")
        return true
    }

    /// Full app reset is the one operation authorized to erase the Keychain record itself,
    /// including a corrupt record that ordinary fail-closed revocation refuses to overwrite.
    func deleteOwnerDevicesForAppReset() throws {
        stop()
        try ownerDevices.deleteAllForAppReset()
        let removedShareCount = sessionShares.values.reduce(0) { $0 + $1.count }
        do {
            try guestShareStore.deleteAll()
        } catch {
            ThreadingLogger.remote.error(
                "Remote guest share persistence failed stage=delete error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw error
        }
        sessionShares.removeAll()
        guestSharePersistenceError = nil
        ThreadingLogger.remote.notice(
            "Remote guest shares deleted for app reset count=\(removedShareCount, privacy: .public)"
        )
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
            shares[index].members[memberID] = nil
            if shares[index].members.isEmpty, shares[index].invitationToken == nil {
                shares.remove(at: index)
            }
            var candidate = sessionShares
            candidate[sessionID] = shares.isEmpty ? nil : shares
            guard persistGuestShares(candidate) else { return false }
            sessionShares = candidate
            revoke(record)
            sharingChanged()
            ThreadingLogger.remote.notice(
                "Remote guest member revoked session=\(sessionID.rawValue, privacy: .public)"
            )
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
        var candidate = sessionShares
        candidate[sessionID] = shares.isEmpty ? nil : shares
        guard persistGuestShares(candidate) else { return false }
        sessionShares = candidate
        sharingChanged()
        ThreadingLogger.remote.notice(
            "Remote guest invitation revoked session=\(sessionID.rawValue, privacy: .public)"
        )
        return true
    }

    func revokeSessionShares(_ sessionID: SessionID) {
        let removed = sessionShares[sessionID] ?? []
        var candidate = sessionShares
        candidate[sessionID] = nil
        guard persistGuestShares(candidate) else { return }
        sessionShares = candidate
        for share in removed {
            for member in share.members.values { revoke(member) }
        }
        sharingChanged()
        ThreadingLogger.remote.notice(
            "Remote session sharing revoked session=\(sessionID.rawValue, privacy: .public) shares=\(removed.count, privacy: .public)"
        )
    }

    private func revoke(_ member: MemberRecord) {
        authority.set(nil, forToken: member.token)
        RemoteNotificationService.shared.revoke(shareID: member.authorization.shareID)
        server.revokeConnections(shareID: member.authorization.shareID)
    }

    private func sharingChanged() {
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        mirrors.sessionSharingChanged()
        reconcileRelayIfNeeded()
    }

    private func restoreGuestShares() {
        do {
            let now = Date()
            var restored: [SessionID: [SessionShare]] = [:]
            for record in try guestShareStore.load() {
                guard let sessionID = SessionID(uuidString: record.sessionID) else { continue }
                let members = record.members.reduce(into: [String: MemberRecord]()) {
                    result, stored in
                    let member = RemoteMember(
                        id: stored.id,
                        displayName: stored.displayName,
                        deviceID: stored.deviceID
                    )
                    let authorization = RemoteAuthorization(
                        shareID: stored.id,
                        capability: record.capability,
                        scope: .session(sessionID),
                        principal: .guest,
                        member: member,
                        canApprovePermissions: record.canApprovePermissions
                    )
                    result[stored.id] = MemberRecord(
                        token: stored.token,
                        authorization: authorization,
                        joinedAt: stored.joinedAt,
                        lastSeenAt: stored.lastSeenAt
                    )
                }
                let invitation = record.expiresAt > now ? record.invitationToken : nil
                guard invitation != nil || !members.isEmpty else { continue }
                restored[sessionID, default: []].append(SessionShare(
                    id: record.id,
                    invitationToken: invitation,
                    capability: record.capability,
                    canApprovePermissions: record.canApprovePermissions,
                    createdAt: record.createdAt,
                    expiresAt: record.expiresAt,
                    members: members
                ))
                if let invitation {
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + max(0, record.expiresAt.timeIntervalSince(now))
                    ) { [weak self] in
                        self?.expireInvitation(token: invitation, sessionID: sessionID)
                    }
                }
            }
            sessionShares = restored
            ThreadingLogger.remote.info(
                "Remote guest shares restored sessions=\(restored.count, privacy: .public) shares=\(restored.values.reduce(0) { $0 + $1.count }, privacy: .public)"
            )
        } catch {
            guestSharePersistenceError = error.localizedDescription
            sessionShares = [:]
            ThreadingLogger.remote.error(
                "Remote guest share persistence failed stage=load error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    private func persistGuestShares(
        _ candidate: [SessionID: [SessionShare]]
    ) -> Bool {
        guard guestSharePersistenceError == nil else { return false }
        let records = candidate.flatMap { sessionID, shares in
            shares.map { share in
                RemoteGuestShareRecord(
                    id: share.id,
                    sessionID: sessionID.uuidString,
                    invitationToken: share.invitationToken,
                    capability: share.capability,
                    canApprovePermissions: share.canApprovePermissions,
                    createdAt: share.createdAt,
                    expiresAt: share.expiresAt,
                    members: share.members.values.map { member in
                        RemoteGuestShareRecord.Member(
                            id: member.authorization.shareID,
                            token: member.token,
                            displayName: member.authorization.member?.displayName ?? "Guest",
                            deviceID: member.authorization.member?.deviceID ?? "unknown",
                            joinedAt: member.joinedAt,
                            lastSeenAt: member.lastSeenAt
                        )
                    }
                )
            }
        }
        do {
            try guestShareStore.save(records)
            return true
        } catch {
            guestSharePersistenceError = error.localizedDescription
            ThreadingLogger.remote.error(
                "Remote guest share persistence failed stage=save records=\(records.count, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            return false
        }
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
        var candidate = sessionShares
        candidate[sessionID] = shares.isEmpty ? nil : shares
        guard persistGuestShares(candidate) else { return }
        sessionShares = candidate
        for member in share.members.values {
            authority.set(nil, forToken: member.token)
            RemoteNotificationService.shared.revoke(
                shareID: member.authorization.shareID
            )
            server.revokeConnections(shareID: member.authorization.shareID)
        }
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        mirrors.sessionSharingChanged()
        reconcileRelayIfNeeded()
    }

    // MARK: - Master switch

    /// Called at launch. Starts the server only if the user has turned remote access on.
    func startIfEnabled() {
        guard appSettings.remoteAccessEnabled else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        appSettings.remoteAccessEnabled = enabled
        if enabled { start() } else { stop() }
    }

    func setConnectionMode(_ mode: RemoteAccessConnectionMode) {
        guard appSettings.remoteAccessConnectionMode != mode else { return }
        failPendingShares(.remoteAccessUnavailable)
        appSettings.remoteAccessConnectionMode = mode
        guard case .listening(let port) = status else {
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            return
        }
        startTransports(port: port)
    }

    func setAllowsOwnerRelayFallback(_ enabled: Bool) {
        guard appSettings.remoteAccessAllowsOwnerRelayFallback != enabled else { return }
        appSettings.remoteAccessAllowsOwnerRelayFallback = enabled
        reconcileRelayIfNeeded()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    func setKeepsRelayReady(_ enabled: Bool) {
        guard appSettings.remoteAccessKeepsRelayReady != enabled else { return }
        appSettings.remoteAccessKeepsRelayReady = enabled
        reconcileRelayIfNeeded()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    func retryTransports() {
        guard case .listening(let port) = status else { return }
        startTransports(port: port)
    }

    /// Stops every network door and clears runtime capabilities. Durable owner-device and
    /// accepted one-chat records remain in Keychain and are rehydrated on the next start.
    func stop() {
        lifecycleGeneration += 1
        failPendingShares(.remoteAccessUnavailable)
        stopTransports()
        server.stop()
        mirrors.remoteAccessStopped()
        RemoteNotificationService.shared.reset()
        authority.removeAll()
        pairingBootstrapToken = nil
        pairingRedemptions.removeAll()
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
        guard let token = Self.pairingToken() else {
            ThreadingLogger.remote.error(
                "Remote credential generation failed stage=listener_start"
            )
            status = .failed(reason: L10n.string("A secure remote access token could not be created."))
            return
        }
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
        for shares in sessionShares.values {
            for share in shares {
                for member in share.members.values {
                    authority.set(member.authorization, forToken: member.token)
                }
            }
        }

        server.start { [weak self] port in
            guard let self else { return }
            guard self.lifecycleGeneration == generation,
                  appSettings.remoteAccessEnabled else {
                return
            }
            if let port {
                self.status = .listening(port: port)
                self.mirrors.remoteAccessStarted()
                self.startTransports(port: port)
                ThreadingLogger.remote.info(
                    "Remote access listener ready port=\(port, privacy: .public)"
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
        hostedService.start(targetPort: port)
        relayStatus = .stopped
        tailscaleStatus = .stopped

        let mode = appSettings.remoteAccessConnectionMode
        if mode.usesTailscale {
            startTailscale(port: port, generation: generation)
        }
        if shouldRunRelay {
            startRelay(port: port, generation: generation)
        }
    }

    private var shouldRunRelay: Bool {
        Self.relayRequired(
            mode: appSettings.remoteAccessConnectionMode,
            allowsOwnerFallback: appSettings.remoteAccessAllowsOwnerRelayFallback,
            keepsRelayReady: appSettings.remoteAccessKeepsRelayReady,
            hasActiveShares: !sessionShares.isEmpty,
            hasPendingShares: !pendingPublicShares.isEmpty
        )
    }

    nonisolated static func relayRequired(
        mode: RemoteAccessConnectionMode,
        allowsOwnerFallback: Bool,
        keepsRelayReady: Bool,
        hasActiveShares: Bool,
        hasPendingShares: Bool
    ) -> Bool {
        switch mode {
        case .relay:
            return true
        case .tailscale:
            return false
        case .tailscaleAndRelay:
            return allowsOwnerFallback || keepsRelayReady || hasActiveShares || hasPendingShares
        }
    }

    private func startRelay(port: UInt16, generation: Int) {
        relayStatus = .starting
        tunnel.start(port: port) { [weak self] state in
            self?.transportChanged(.relay, state: state, generation: generation)
        }
    }

    private func startTailscale(port: UInt16, generation: Int) {
        tailscaleStatus = .starting
        tailscale.start(port: port) { [weak self] state in
            self?.transportChanged(.tailscale, state: state, generation: generation)
        }
    }

    private func reconcileRelayIfNeeded() {
        guard case .listening(let port) = status else { return }
        if shouldRunRelay {
            switch relayStatus {
            case .connected, .starting:
                return
            case .stopped, .unavailable:
                startRelay(port: port, generation: transportGeneration)
            }
        } else if relayStatus != .stopped {
            tunnel.stop()
            relayStatus = .stopped
        }
    }

    private func startInvitationTransportIfNeeded() {
        guard case .listening(let port) = status else {
            failPendingShares(.remoteAccessUnavailable)
            return
        }
        switch appSettings.remoteAccessConnectionMode {
        case .relay, .tailscaleAndRelay:
            switch relayStatus {
            case .connected:
                drainPendingSharesIfPossible()
            case .starting:
                break
            case .stopped, .unavailable:
                startRelay(port: port, generation: transportGeneration)
            }
        case .tailscale:
            switch tailscaleStatus {
            case .connected:
                drainPendingSharesIfPossible()
            case .starting:
                break
            case .stopped, .unavailable:
                startTailscale(port: port, generation: transportGeneration)
            }
        }
    }

    private func drainPendingSharesIfPossible() {
        guard invitationOrigin != nil, !pendingPublicShares.isEmpty else { return }
        let pending = Array(pendingPublicShares.values)
        pendingPublicShares.removeAll()
        for request in pending {
            guard let created = createSessionShareNow(
                for: request.sessionID,
                capability: request.capability,
                canApprovePermissions: request.canApprovePermissions
            ) else {
                request.completion(.failure(.remoteAccessUnavailable))
                continue
            }
            request.completion(.success(created))
        }
    }

    private func failPendingShares(_ error: RemoteSharePreparationError) {
        let pending = Array(pendingPublicShares.values)
        pendingPublicShares.removeAll()
        for request in pending { request.completion(.failure(error)) }
    }

    private func stopTransports() {
        transportGeneration += 1
        hostedPairingTask?.cancel()
        hostedPairingTask = nil
        hostedService.revokeDevice(deviceID: Self.hostedPairingDeviceID)
        hostedPairingLink = nil
        tunnel.stop()
        tailscale.stop()
        hostedService.stop()
        relayStatus = .stopped
        tailscaleStatus = .stopped
    }

    /// Produces the first-install QR route without requiring cloudflared or Tailscale. The
    /// rendezvous bearer only reaches this Mac's loopback listener; the existing one-time owner
    /// bootstrap still has to be redeemed before any remote API is authorized.
    private func refreshHostedPairingLink() {
        guard hostedService.state == .ready else {
            hostedPairingTask?.cancel()
            hostedPairingTask = nil
            hostedPairingLink = nil
            return
        }
        guard hostedPairingTask == nil,
              hostedService.canIssueDeviceCredentials,
              case .listening = status,
              let bootstrap = pairingBootstrapToken else {
            return
        }
        if let current = hostedPairingLink,
           current.bootstrapToken == bootstrap,
           !current.isExpired {
            return
        }

        let generation = transportGeneration
        hostedPairingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let issued = try await hostedService.issueDeviceCredential(
                    deviceID: Self.hostedPairingDeviceID,
                    lifetimeSeconds: Self.hostedPairingCredentialLifetimeSeconds
                )
                guard !Task.isCancelled,
                      generation == transportGeneration,
                      pairingBootstrapToken == bootstrap,
                      let serviceURL = hostedService.serviceURL else {
                    return
                }
                let link = issued.credential.withValue { credential in
                    HostedPairingLink(
                        serviceURL: serviceURL,
                        hostID: issued.hostID,
                        deviceID: issued.deviceID,
                        rendezvousCredential: credential,
                        bootstrapToken: bootstrap,
                        expiresAt: issued.expiresAt
                    )
                }
                guard let link else { return }
                hostedPairingLink = link
                hostedPairingTask = nil
                NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            } catch is CancellationError {
                hostedPairingTask = nil
            } catch {
                hostedPairingTask = nil
                ThreadingLogger.remote.error("Hosted pairing credential issue failed code=service")
            }
        }
    }

    /// The pairing HTTP response and durable hosted-credential response need a moment to leave
    /// the loopback bridge before its temporary transport credential is revoked.
    func completeHostedPairingBootstrap() {
        retireHostedPairingLink(after: 2)
    }

    private func retireHostedPairingLink(after delay: TimeInterval) {
        guard hostedPairingLink != nil || hostedPairingTask != nil else { return }
        hostedPairingLink = nil
        hostedPairingTask?.cancel()
        hostedPairingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            await hostedService.revokeDeviceImmediately(deviceID: Self.hostedPairingDeviceID)
            hostedPairingTask = nil
            refreshHostedPairingLink()
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    private func transportChanged(
        _ kind: RemoteTransportKind,
        state: RemoteTransportState,
        generation: Int
    ) {
        guard transportGeneration == generation,
              appSettings.remoteAccessEnabled,
              case .listening = status else { return }
        switch kind {
        case .relay: relayStatus = state
        case .tailscale: tailscaleStatus = state
        }

        switch state {
        case .connected(let origin):
            // The advertised origin, hashed. Without it a report says a transport connected and
            // cannot say to what, which is exactly the question a phone failing against a dead
            // address needs answered.
            let digest = MacRemoteDiagnostics.originDigest(origin)
            MacRemoteDiagnostics.record(.relayConnected, fields: [
                .transport: kind.rawValue,
                .origin: digest,
            ])
            EventLog.shared.record(.remote, "Remote transport connected", [
                "transport": kind.rawValue,
                "origin": digest,
            ])
            drainPendingSharesIfPossible()
        case .unavailable(let reason):
            var fields: [RemoteDiagnosticField: String] = [
                .transport: kind.rawValue,
                .reason: Self.diagnosticReason(reason),
            ]
            if kind == .tailscale,
               case .actionRequired(let issue, _) = tailscale.readiness {
                fields[.code] = issue.rawValue
            }
            // The relay's own code, rather than a guess made from its localised sentence. Until
            // it existed a relay that launched and never published an address recorded nothing
            // at all, because that case had no timeout and so never reached this branch.
            if kind == .relay, let failure = tunnel.lastFailure {
                fields[.reason] = failure.diagnosticReason
                fields[.code] = failure.rawValue
            }
            MacRemoteDiagnostics.record(
                .relayFailed,
                level: .warning,
                fields: fields
            )
            EventLog.shared.record(.remote, "Remote transport unavailable", [
                "transport": kind.rawValue,
                "reason": Self.diagnosticReason(reason),
            ])
            let mode = appSettings.remoteAccessConnectionMode
            let isInvitationTransport = kind == .relay
                ? mode != .tailscale
                : mode == .tailscale
            if isInvitationTransport {
                failPendingShares(.relayUnavailable(reason))
            }
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

    private static func isQuickRelay(_ origin: URL) -> Bool {
        origin.host?.lowercased().hasSuffix(".trycloudflare.com") == true
    }

    // MARK: - Tokens

    /// 32 bytes of entropy, base64url, no padding — the `ExtensionHostService.randomToken`
    /// primitive. A share link's whole security rests on this being unguessable.
    typealias EntropySource = (_ byteCount: Int) -> [UInt8]?

    static func randomToken(using source: EntropySource = secureEntropy) -> String? {
        guard let bytes = source(32), bytes.count == 32 else { return nil }
        return Data(bytes).base64EncodedString()
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
    static func pairingToken(using source: EntropySource = secureEntropy) -> String? {
        guard let bytes = source(16), bytes.count == 16 else { return nil }
        return base32(bytes)
    }

    /// Security.framework owns this operation; it does not touch coordinator state and is safe
    /// to pass through the nonisolated entropy seam without erasing a main-actor function type.
    nonisolated private static func secureEntropy(bytes count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            ThreadingLogger.remote.fault(
                "Could not generate remote access entropy: \(status, privacy: .public)"
            )
            return nil
        }
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
