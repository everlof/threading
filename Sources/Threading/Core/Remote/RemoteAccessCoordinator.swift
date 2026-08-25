import Foundation
import Security
import SystemConfiguration
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

/// Why an invitation could not be minted, in the words the person asking gets back.
///
/// Both cases are a fact about this Mac rather than about the network: an invitation points at a
/// private door, so there is either one bound or there is not, and the answer is known the moment
/// it is asked. Nothing waits for a transport to come up.
enum RemoteSharePreparationError: LocalizedError, Equatable {
    case remoteAccessUnavailable
    /// Remote Access is on, but no routable door is bound, so there is no origin a guest's phone
    /// could reach and nothing to pin when it got there.
    case noPrivateDoor

    var errorDescription: String? {
        switch self {
        case .remoteAccessUnavailable:
            return L10n.string("Remote Access is not ready.")
        case .noPrivateDoor:
            return L10n.string("Turn on a way in first.")
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

    /// What each door is doing, as the settings screen will render it.
    ///
    /// Separate from `status`, which answers "is the one server up". A door can be unreachable
    /// while the server is perfectly healthy, and reporting that as a server failure is how the
    /// tailnet privacy promise would get quietly broken.
    private(set) var listenerStatus: RemoteListenerStatus = .idle {
        didSet {
            guard listenerStatus != oldValue else { return }
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
    }

    /// What Tailscale Serve is doing. **Not the tailnet door**, which is a listener: this is the
    /// opt-in browser convenience, and no phone route depends on it.
    private(set) var tailscaleServeStatus: RemoteTransportState = .stopped {
        didSet {
            guard tailscaleServeStatus != oldValue else { return }
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
    }

    private let server: RemoteAccessServer
    private let identityStore: RemoteAccessIdentityStore
    private let mirrors: RemoteSessionMirrorRegistry
    /// The `tailscale` CLI: the facts behind the tailnet door, and the Serve sub-option.
    private let tailscale: any RemoteTailnetTransport
    private let hostedService: RemoteHostedServiceController
    private let appSettings: AppSettings
    /// What the `tailscale` door is made of in this build. One seam, so §8 of the transport plan
    /// swaps a Serve handler for a bound tailnet address without the settings page noticing.
    private let tailscaleDoor: RemoteTailscaleDoorImplementation
    private let authority = RemoteAuthorityStore()
    private let ownerDevices: RemoteOwnerDeviceRegistry
    private let guestShareStore: RemoteGuestSharePersisting
    /// Remote Access is useful with no visible window, so keep its process schedulable while its
    /// listener is starting or live. The concrete activity deliberately permits idle sleep.
    private let processActivity: any RemoteAccessProcessActivityManaging
    private(set) var guestSharePersistenceError: String?
    private var pairingBootstrapToken: String?
    private static let hostedPairingDeviceID = "hosted-pairing"
    private static let hostedPairingCredentialLifetimeSeconds = 5 * 60
    private var hostedPairingLink: HostedPairingLink?
    private var hostedPairingTask: Task<Void, Never>?
    private var pairingRedemptions: [String: PairingRedemption] = [:]
    private var sessionShares: [SessionID: [SessionShare]] = [:]
    private var terminalShares: [TerminalID: [SessionShare]] = [:]
    /// Invalidates a listener completion that was already enqueued on main when the user
    /// switched the feature off. Without it, a fast off-after-on could put the UI back into
    /// `listening` after `stop()` had already closed the listener and revoked its token.
    private var lifecycleGeneration = 0
    /// Transport callbacks have their own generation because starting or stopping the browser
    /// convenience keeps the listener and all current authorizations alive.
    private var transportGeneration = 0

    init(
        ownerDeviceStore: RemoteOwnerDevicePersisting,
        appSettings: AppSettings,
        guestShareStore: RemoteGuestSharePersisting? = nil,
        hostedService: RemoteHostedServiceController? = nil,
        serverServices: RemoteAccessServerServices? = nil,
        tailnetTransport: (any RemoteTailnetTransport)? = nil,
        identityStore: RemoteAccessIdentityStore? = nil,
        tailscaleDoor: RemoteTailscaleDoorImplementation = .current,
        processActivity: (any RemoteAccessProcessActivityManaging)? = nil
    ) {
        self.appSettings = appSettings
        self.tailscaleDoor = tailscaleDoor
        tailscale = tailnetTransport ?? Self.defaultTailnetTransport()
        let services = serverServices ?? Self.makeServerServices(appSettings: appSettings)
        mirrors = services.mirrors
        let identity = identityStore ?? RemoteAccessIdentityStore.shared
        self.identityStore = identity
        server = RemoteAccessServer(services: services, identityProvider: identity)
        ownerDevices = RemoteOwnerDeviceRegistry(store: ownerDeviceStore)
        self.guestShareStore = guestShareStore ?? Self.defaultGuestShareStore()
        self.hostedService = hostedService ?? RemoteHostedServiceController()
        self.processActivity = processActivity ?? RemoteAccessProcessActivity()
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
        // Doors come and go with the interfaces under them, so the status the settings page
        // renders is pushed rather than polled. The callback arrives on the server queue.
        server.onListenerStatusChange = { [weak self] status in
            Task { @MainActor in self?.applyListenerStatus(status) }
        }
        self.hostedService.onStateChange = { [weak self] in
            self?.refreshHostedPairingLink()
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
        // Readiness steps advance while `tailscaleServeStatus` sits on `.starting`, so without
        // this the settings page renders whichever step was current at the last state change and
        // freezes there until Serve connects or fails. It is also how the CLI facts behind the
        // tailnet door's status line reach the page: the probe publishes through the same seam.
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

    /// The transport the app ships with, unless a caller injected a substitute.
    ///
    /// A hosted test process gets `RefusedRemoteTransport` instead: the test bundle lives inside
    /// this app, so a test that reaches `shared` would otherwise run the developer's own
    /// `tailscale` and publish their Mac, leaving a child behind after the run. A test that wants
    /// to observe transport behaviour injects its own double rather than relying on this.
    static func defaultTailnetTransport() -> any RemoteTailnetTransport {
        isHostedTestProcess ? RefusedRemoteTransport() : TailscaleServeTransport()
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
            mobileDiagnosticsCaptures: .shared,
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

    /// Serve's readiness. The tailnet *door* reads `tailscaleHostFacts` and the listener.
    var tailscaleServeReadiness: TailscaleReadiness { tailscale.readiness }
    /// What `tailscale status` last said about this Mac.
    var tailscaleHostFacts: TailscaleHostFacts { tailscale.hostFacts }
    var hostedServiceState: RemoteHostedServiceState { hostedService.state }

    /// Whether any way in an owner device could take is switched on.
    ///
    /// With none of them on, Remote Access binds loopback and nothing else, which is a state the
    /// page has to be able to say out loud rather than a spinner waiting for something that is
    /// never going to start.
    var hasEnabledWayIn: Bool {
        !appSettings.remoteAccessDoors.isEmpty || appSettings.remoteAccessTailscaleEnabled
    }

    var isThisNetworkDoorEnabled: Bool { appSettings.remoteAccessDoors.contains(.lan) }

    var isTailscaleDoorEnabled: Bool { appSettings.remoteAccessTailscaleEnabled }

    /// The browser convenience under it, which starts and stops on its own.
    var isTailscaleServeEnabled: Bool { appSettings.remoteAccessTailscaleServeEnabled }

    /// The `tailscale` door, with its addresses in the order the pairing code picks between them.
    var tailscaleDoorState: RemoteAccessDoorState {
        let state = listenerStatus.state(of: .tailscale)
        guard case .bound(let bindings) = state else { return state }
        return .bound(Self.orderedBindings(
            bindings,
            primaryInterfaceName: Self.primaryInterfaceName()
        ))
    }

    /// Reads `tailscale status` once, when there is a reason to.
    ///
    /// Bounded and rare on purpose: the CLI answers a question the interface list cannot, and
    /// nothing here is on a timer. The door itself needs no probe at all — it is bound or it is
    /// not — so this only sharpens the sentence beside it and supplies the MagicDNS name.
    func refreshTailscaleHostFacts() {
        guard appSettings.remoteAccessTailscaleEnabled else { return }
        tailscale.refreshHostFacts()
    }

    /// The `lan` door, with its addresses in the order the pairing code picks between them.
    var thisNetworkDoorState: RemoteAccessDoorState {
        let state = listenerStatus.state(of: .lan)
        guard case .bound(let bindings) = state else { return state }
        return .bound(Self.orderedBindings(
            bindings,
            primaryInterfaceName: Self.primaryInterfaceName()
        ))
    }

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
    /// list so a one-chat invitation never reveals the owner's other addresses; a guest reaches
    /// the one door its link names and learns nothing further about this Mac.
    ///
    /// Every route in here is a door of this Mac's own, and every one of them is stable, which is
    /// what "pair once, reconnect tomorrow" rests on. A phone paired to an address this Mac no
    /// longer holds learns the live ones from this list the next time it connects over any of
    /// them.
    ///
    /// The policy is therefore always `privateOnly`. `RemoteHostConnectionPolicy` stays on the
    /// wire because an old phone decodes it and maps anything it does not know to `privateOnly`
    /// as well; `relayOnly` and `preferPrivate` are never sent again.
    func hostIdentity(for authorization: RemoteAuthorization) -> RemoteHostDTO {
        let identity = RemoteHostIdentity.current
        guard authorization.canManageHost else { return identity }

        // **Serve's origin is deliberately not in here.** It is a `*.ts.net` name with a publicly
        // trusted certificate, so a phone told to pin it would break at the next renewal and a
        // phone told to stock-trust it would be the one endpoint no fingerprint covers. The
        // tailnet door advertises this Mac's own tailnet address, and its MagicDNS name on the
        // same sticky port, both pinned — one code path with the pin, which is the point of §8.
        let endpoints: [RemoteHostEndpointDTO] = Self.doorEndpoints(
            listenerStatus,
            advertisedHostname: appSettings.remoteAccessAdvertisedHostname,
            tailnetHostname: tailscale.hostFacts.magicDNSName
        )
        return Self.ownerHost(
            identity,
            endpoints: endpoints,
            policy: .privateOnly,
            identity: identityStore.snapshot
        )
    }

    /// The owner's view of this Mac: who it is, how to reach it, and what to trust when you do.
    ///
    /// The fingerprints ride along **only when something pinned is on offer**. A fingerprint
    /// beside a list of endpoints none of which present it is a value with nothing to check
    /// against, and a phone that stored it would refuse the Serve endpoint it is actually using.
    nonisolated static func ownerHost(
        _ host: RemoteHostDTO,
        endpoints: [RemoteHostEndpointDTO],
        policy: RemoteHostConnectionPolicy,
        identity: RemoteAccessIdentitySnapshot
    ) -> RemoteHostDTO {
        let pinned = endpoints.contains(where: \.expectsPinnedIdentity) ? identity : .unloaded
        return RemoteHostDTO(
            id: host.id,
            name: host.name,
            platform: host.platform,
            endpoints: endpoints,
            connectionPolicy: policy,
            pinnedFingerprint: pinned.fingerprint?.hex,
            nextPinnedFingerprint: pinned.nextFingerprint?.hex
        )
    }

    /// What this Mac's certificate is, for a settings screen and for the pairing card.
    var identitySnapshot: RemoteAccessIdentitySnapshot { identityStore.snapshot }

    /// Throws this Mac's identity away and mints a new one, then rebuilds the listeners so they
    /// present it.
    ///
    /// Every paired device that did not receive a rotation announcement has to scan a new code
    /// afterwards, which is why this is only ever a person's explicit choice.
    @discardableResult
    func resetIdentity() async -> Result<RemoteHostFingerprint, RemoteIdentityFailure> {
        let store = identityStore
        // Off the main actor deliberately: this reads and writes files, derives a key and
        // imports a container.
        let outcome = await Task.detached { store.reset() }.value
        server.reloadIdentity()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        return outcome.map(\.fingerprint)
    }

    /// Mints the successor identity and announces it, without presenting it yet.
    ///
    /// A phone connected over the pinned channel is talking to the holder of the current private
    /// key, so the announcement is authenticated by the identity it replaces. That is what makes
    /// the switch free of re-pairing, and it is why the announcement is only ever read from a
    /// pinned connection.
    @discardableResult
    func prepareIdentityRotation() async -> Result<RemoteHostFingerprint, RemoteIdentityFailure> {
        let store = identityStore
        let outcome = await Task.detached { store.prepareRotation() }.value
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        return outcome
    }

    /// Switches the listeners to the prepared successor. The port does not move and loopback is
    /// untouched, so nothing that talks to `127.0.0.1` notices.
    @discardableResult
    func activateIdentityRotation() async -> Result<RemoteHostFingerprint, RemoteIdentityFailure> {
        let store = identityStore
        let outcome = await Task.detached { store.activateRotation() }.value
        if case .success = outcome { server.reloadIdentity() }
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        return outcome.map(\.fingerprint)
    }

    /// The routes a routable door is currently answering on.
    ///
    /// Every entry is stable: the port is sticky and the addresses come from interfaces the Mac
    /// holds, so a phone that learns one can use it again tomorrow. Every entry is also `https`
    /// and carries `identity: pinned`, because a routable listener presents this Mac's own
    /// certificate. **That flag cannot be inferred from `kind`**: a Serve endpoint is advertised
    /// as `tailscale` too and holds a publicly trusted certificate, so a phone told to pin it
    /// would break the next time Let's Encrypt renewed.
    ///
    /// Loopback is never advertised. It reaches this Mac only, so an entry for it would be a
    /// route no other device can take.
    nonisolated static func doorEndpoints(
        _ status: RemoteListenerStatus,
        advertisedHostname: String,
        localHostname: String? = bonjourLocalHostname(),
        tailnetHostname: String? = nil
    ) -> [RemoteHostEndpointDTO] {
        var endpoints: [RemoteHostEndpointDTO] = []
        var seen: Set<URL> = []

        func append(_ url: URL?, door: RemoteAccessDoor) {
            guard let url, seen.insert(url).inserted else { return }
            endpoints.append(RemoteHostEndpointDTO(
                kind: door.endpointKind,
                baseURL: url,
                isStable: true,
                identity: door.requiresTLS ? RemoteHostEndpointIdentity.pinned : nil
            ))
        }

        for door in RemoteAccessDoor.selectable {
            let bindings = status.state(of: door).bindings
            for binding in bindings {
                append(binding.origin, door: door)
            }
            guard let port = bindings.first?.port else { continue }
            // A name is the same door reached the way a person's DNS reaches it, so each rides
            // with the door whose addresses it resolves to and appears only while that door is
            // up. The tailnet's MagicDNS name is on the *sticky* port, not Serve's: it resolves
            // to the same `100.x` address the listener is bound to, with the same certificate.
            if door == .tailscale, let tailnetHostname, !tailnetHostname.isEmpty {
                append(Self.origin(host: tailnetHostname, port: port, door: door), door: door)
            }
            guard door == .lan else { continue }
            if let localHostname, localHostname.hasSuffix(RemoteAccessDefaults.localHostnameSuffix) {
                append(Self.origin(host: localHostname, port: port, door: door), door: door)
            }
            if !advertisedHostname.isEmpty {
                append(Self.origin(host: advertisedHostname, port: port, door: door), door: door)
            }
        }
        return endpoints
    }

    /// This Mac's Bonjour name with the `.local` suffix, from the system configuration store.
    ///
    /// Not `ProcessInfo.hostName`: that answers with whatever reverse DNS says, which on some
    /// networks is not a `.local` name at all, and it can block on the lookup, while this is
    /// called on the main actor for every owner `/api/me`. The store answers from memory.
    nonisolated static func bonjourLocalHostname() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else {
            return nil
        }
        return name + RemoteAccessDefaults.localHostnameSuffix
    }

    private nonisolated static func origin(
        host: String,
        port: UInt16,
        door: RemoteAccessDoor
    ) -> URL? {
        var components = URLComponents()
        components.scheme = door.requiresTLS
            ? RemoteAccessDefaults.tlsScheme
            : RemoteAccessDefaults.cleartextScheme
        components.host = host
        components.port = Int(port)
        components.path = "/"
        guard let url = components.url, url.host?.isEmpty == false else { return nil }
        return url
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
    ///
    /// The same credential as the QR code, written the way a person pasting a link expects to
    /// see it. Both carry the fingerprint when the destination is a pinned door, because a link
    /// that pairs without one produces a phone that trusts whatever answers at that address.
    var remoteURL: URL? {
        guard ownerDevices.persistenceError == nil else { return nil }
        return pairingLink?.shareURL
    }

    private var pairingLink: RemoteConnectionLink? {
        guard let destination = pairingDestination, let pairingBootstrapToken else { return nil }
        return RemoteConnectionLink(
            baseURL: destination.origin,
            token: pairingBootstrapToken,
            pinnedFingerprintCode: destination.pinnedFingerprintCode
        )
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
        return pairingLink?.scannablePayload
    }

    /// Where a scanning phone is sent, and what it should pin when it arrives.
    ///
    /// A bound LAN door wins: it is the address this Mac actually holds, it survives a restart,
    /// and it is the network the phone in the room is almost certainly already on. When no LAN
    /// door is bound, the tailnet door is the answer, and it carries the fingerprint too — the
    /// listener there presents the same certificate as every other routable door. Nothing falls
    /// back to Serve, which hands the phone a certificate that is not ours to pin: that is
    /// exactly the second trust story §8 exists to remove.
    private var pairingDestination: (origin: URL, pinnedFingerprintCode: String?)? {
        Self.pairingDestination(
            lanBindings: listenerStatus.state(of: .lan).bindings,
            tailnetBindings: listenerStatus.state(of: .tailscale).bindings,
            primaryInterfaceName: Self.primaryInterfaceName(),
            pinnedFingerprint: identityStore.snapshot.fingerprint
        )
    }

    nonisolated static func pairingDestination(
        lanBindings: [RemoteListenerBinding],
        tailnetBindings: [RemoteListenerBinding],
        primaryInterfaceName: String?,
        pinnedFingerprint: RemoteHostFingerprint?
    ) -> (origin: URL, pinnedFingerprintCode: String?)? {
        guard let pinnedFingerprint else { return nil }
        for bindings in [lanBindings, tailnetBindings] {
            guard let binding = preferredPairingBinding(
                bindings,
                primaryInterfaceName: primaryInterfaceName
            ), let origin = binding.origin else { continue }
            return (origin, pinnedFingerprint.pairingCode)
        }
        return nil
    }

    /// The one LAN address a pairing code names, out of however many this Mac is answering on.
    ///
    /// A QR code holds one origin, so this picks: the address on the interface carrying the
    /// default route first, then IPv4 over IPv6 within that interface, then the sorted first.
    /// The default route is the right guess because it is the network the Mac itself reaches the
    /// world through, which is almost always the one the phone in the room is on. The phone
    /// learns every other address from `/api/me` immediately afterwards, so this choice costs
    /// nothing after the first connection.
    nonisolated static func preferredPairingBinding(
        _ bindings: [RemoteListenerBinding],
        primaryInterfaceName: String?
    ) -> RemoteListenerBinding? {
        bindings.min { lhs, rhs in
            func rank(_ binding: RemoteListenerBinding) -> (Int, Int) {
                (
                    binding.address.interfaceName == primaryInterfaceName ? 0 : 1,
                    binding.address.isIPv6 ? 1 : 0
                )
            }
            let left = rank(lhs)
            let right = rank(rhs)
            if left != right { return left < right }
            return lhs.address < rhs.address
        }
    }

    /// The LAN addresses in the order the pairing code picks between them.
    ///
    /// The settings page prints the first one as the door's status and the rest as its second
    /// line, so the address a person reads first is the address on the code they are about to
    /// photograph.
    nonisolated static func orderedBindings(
        _ bindings: [RemoteListenerBinding],
        primaryInterfaceName: String?
    ) -> [RemoteListenerBinding] {
        guard let preferred = preferredPairingBinding(
            bindings,
            primaryInterfaceName: primaryInterfaceName
        ) else { return [] }
        return [preferred] + bindings.filter { $0 != preferred }.sorted { $0.address < $1.address }
    }

    /// The interface carrying the default IPv4 route, from the system configuration store.
    ///
    /// The store answers from memory, which is what makes this safe to ask on the main actor;
    /// enumerating routes or resolving names would not be.
    nonisolated static func primaryInterfaceName() -> String? {
        guard let global = SCDynamicStoreCopyValue(
            nil,
            RemoteAccessDefaults.globalIPv4StateKey as CFString
        ) as? [String: Any] else { return nil }
        return global[kSCDynamicStorePropNetPrimaryInterface as String] as? String
    }

    /// Where a one-chat guest link points, and what the guest's phone should pin when it
    /// arrives there.
    ///
    /// The same destination the owner's pairing code names: the LAN door when one is bound, the
    /// tailnet door otherwise. A guest is somebody on your Wi-Fi or on your tailnet running the
    /// Threading app, so the origin is a private door of this Mac and the link carries the
    /// certificate's pairing code exactly as the owner code does. There is no public origin left
    /// to offer: the Quick Tunnel that used to supply one is gone, and browser guests come back
    /// over ICE/TURN rather than through a third party that terminates TLS.
    ///
    /// Nil means no routable door is bound, which is the whole of the refusal below. It is a fact
    /// this Mac already knows, so minting answers immediately rather than waiting on anything.
    private var invitationDestination: (origin: URL, pinnedFingerprintCode: String?)? {
        pairingDestination
    }

    /// Mints a short-lived, single-use invitation for exactly one chat.
    ///
    /// This is deliberately separate from `remoteURL`, which is the owner's pairing door.
    /// Accepting it exchanges the invitation bearer for a device-bound membership bearer that
    /// remains valid until sharing is stopped. Copying the invite can therefore never leak the
    /// dashboard or another session.
    ///
    /// Synchronous, because every input is already known: a door is bound or it is not. It used
    /// to queue the request behind a relay process starting up, which is what the pending-share
    /// machinery and its timeout existed for.
    func createSessionShare(
        for sessionID: SessionID,
        capability: RemoteCapability,
        canApprovePermissions requestedPermissionApproval: Bool = false
    ) -> Result<RemoteCreatedShare, RemoteSharePreparationError> {
        let isListening: Bool
        if case .listening = status { isListening = true } else { isListening = false }
        if let refusal = Self.shareRefusal(
            isSessionShareable: RemoteSessionAccess.isVisible(
                ProjectStore.shared.session(withID: sessionID)
            ),
            isListening: isListening,
            hasPrivateDoor: invitationDestination != nil
        ) {
            return .failure(refusal)
        }
        guard let created = createSessionShareNow(
            for: sessionID,
            capability: capability,
            canApprovePermissions: requestedPermissionApproval
        ) else {
            return .failure(.remoteAccessUnavailable)
        }
        return .success(created)
    }

    /// Mints an exact-terminal invitation. `interact` grants PTY control; unlike chat shares it
    /// can never grant permission approval because no agent permission surface belongs here.
    func createTerminalShare(
        for terminalID: TerminalID,
        capability: RemoteCapability
    ) -> Result<RemoteCreatedShare, RemoteSharePreparationError> {
        let isListening: Bool
        if case .listening = status { isListening = true } else { isListening = false }
        if let refusal = Self.shareRefusal(
            isSessionShareable: ProjectStore.shared.terminal(withID: terminalID) != nil,
            isListening: isListening,
            hasPrivateDoor: invitationDestination != nil
        ) {
            return .failure(refusal)
        }
        guard let invitationToken = Self.randomToken(),
              let url = invitationURL(token: invitationToken) else {
            return .failure(.remoteAccessUnavailable)
        }
        let id = UUID().uuidString.lowercased()
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(RemoteAccessDefaults.defaultShareExpiry)
        let share = SessionShare(
            id: id,
            invitationToken: invitationToken,
            capability: capability,
            canApprovePermissions: false,
            createdAt: createdAt,
            expiresAt: expiresAt,
            members: [:]
        )
        var candidate = terminalShares
        candidate[terminalID, default: []].append(share)
        guard persistTerminalGuestShares(candidate) else {
            return .failure(.remoteAccessUnavailable)
        }
        terminalShares = candidate
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RemoteAccessDefaults.defaultShareExpiry
        ) { [weak self] in
            self?.expireInvitation(token: invitationToken, terminalID: terminalID)
        }
        sharingChanged()
        ThreadingLogger.remote.info(
            "Remote terminal invitation created terminal=\(terminalID.rawValue, privacy: .public) capability=\(capability.rawValue, privacy: .public)"
        )
        return .success(RemoteCreatedShare(
            url: url,
            expiresAt: expiresAt,
            canApprovePermissions: false
        ))
    }

    /// Why an invitation cannot be minted, or nil when one can.
    ///
    /// Separated from the minting so the order of the two refusals is a value rather than a run
    /// of guards: "Remote Access is not ready" and "turn on a way in" send a person to two
    /// different switches, and answering the wrong one is worse than answering neither.
    nonisolated static func shareRefusal(
        isSessionShareable: Bool,
        isListening: Bool,
        hasPrivateDoor: Bool
    ) -> RemoteSharePreparationError? {
        guard isSessionShareable, isListening else { return .remoteAccessUnavailable }
        guard hasPrivateDoor else { return .noPrivateDoor }
        return nil
    }

    private func createSessionShareNow(
        for sessionID: SessionID,
        capability: RemoteCapability,
        canApprovePermissions requestedPermissionApproval: Bool
    ) -> RemoteCreatedShare? {
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
        for terminalID in Array(terminalShares.keys) {
            guard var shares = terminalShares[terminalID],
                  let index = shares.firstIndex(where: {
                      $0.invitationToken == token && $0.expiresAt > Date()
                  }),
                  let accessToken = Self.randomToken() else { continue }
            var share = shares[index]
            let memberID = UUID().uuidString.lowercased()
            let member = RemoteMember(
                id: memberID,
                displayName: normalizedName,
                deviceID: normalizedDeviceID
            )
            let authorization = RemoteAuthorization(
                shareID: memberID,
                capability: share.capability,
                scope: .projectTerminal(terminalID),
                principal: .guest,
                member: member,
                canApprovePermissions: false
            )
            share.invitationToken = nil
            share.members[memberID] = MemberRecord(
                token: accessToken,
                authorization: authorization,
                joinedAt: Date()
            )
            shares[index] = share
            var candidate = terminalShares
            candidate[terminalID] = shares
            guard persistTerminalGuestShares(candidate) else { return nil }
            terminalShares = candidate
            authority.set(authorization, forToken: accessToken)
            sharingChanged()
            ThreadingLogger.remote.notice(
                "Remote terminal invitation redeemed terminal=\(terminalID.rawValue, privacy: .public) capability=\(share.capability.rawValue, privacy: .public)"
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

    func hasTerminalShares(_ terminalID: TerminalID) -> Bool {
        !(terminalShares[terminalID]?.isEmpty ?? true)
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
        for (terminalID, shares) in terminalShares {
            for (shareIndex, share) in shares.enumerated() where share.members[shareID] != nil {
                var candidate = terminalShares
                candidate[terminalID]?[shareIndex].members[shareID]?.lastSeenAt = Date()
                if persistTerminalGuestShares(candidate) { terminalShares = candidate }
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
            + terminalShares.values.reduce(0) { $0 + $1.count }
        do {
            try guestShareStore.deleteAll()
        } catch {
            ThreadingLogger.remote.error(
                "Remote guest share persistence failed stage=delete error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw error
        }
        sessionShares.removeAll()
        terminalShares.removeAll()
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

    func revokeTerminalShares(_ terminalID: TerminalID) {
        let removed = terminalShares[terminalID] ?? []
        var candidate = terminalShares
        candidate[terminalID] = nil
        guard persistTerminalGuestShares(candidate) else { return }
        terminalShares = candidate
        for share in removed {
            for member in share.members.values { revoke(member) }
        }
        sharingChanged()
        ThreadingLogger.remote.notice(
            "Remote terminal sharing revoked terminal=\(terminalID.rawValue, privacy: .public) shares=\(removed.count, privacy: .public)"
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
    }

    private func restoreGuestShares() {
        do {
            let now = Date()
            var restored: [SessionID: [SessionShare]] = [:]
            var restoredTerminals: [TerminalID: [SessionShare]] = [:]
            for record in try guestShareStore.load() {
                let scope: RemoteScope
                if record.targetKind == .projectTerminal {
                    guard let terminalID = TerminalID(uuidString: record.sessionID) else { continue }
                    scope = .projectTerminal(terminalID)
                } else {
                    guard let sessionID = SessionID(uuidString: record.sessionID) else { continue }
                    scope = .session(sessionID)
                }
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
                        scope: scope,
                        principal: .guest,
                        member: member,
                        canApprovePermissions: record.targetKind == .projectTerminal
                            ? false : record.canApprovePermissions
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
                let share = SessionShare(
                    id: record.id,
                    invitationToken: invitation,
                    capability: record.capability,
                    canApprovePermissions: record.targetKind == .projectTerminal
                        ? false : record.canApprovePermissions,
                    createdAt: record.createdAt,
                    expiresAt: record.expiresAt,
                    members: members
                )
                switch scope {
                case .session(let sessionID):
                    restored[sessionID, default: []].append(share)
                    if let invitation {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + max(0, record.expiresAt.timeIntervalSince(now))
                        ) { [weak self] in
                            self?.expireInvitation(token: invitation, sessionID: sessionID)
                        }
                    }
                case .projectTerminal(let terminalID):
                    restoredTerminals[terminalID, default: []].append(share)
                    if let invitation {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + max(0, record.expiresAt.timeIntervalSince(now))
                        ) { [weak self] in
                            self?.expireInvitation(token: invitation, terminalID: terminalID)
                        }
                    }
                case .allSessions:
                    break
                }
            }
            sessionShares = restored
            terminalShares = restoredTerminals
            ThreadingLogger.remote.info(
                "Remote guest shares restored sessions=\(restored.count, privacy: .public) terminals=\(restoredTerminals.count, privacy: .public)"
            )
        } catch {
            guestSharePersistenceError = error.localizedDescription
            sessionShares = [:]
            terminalShares = [:]
            ThreadingLogger.remote.error(
                "Remote guest share persistence failed stage=load error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    private func persistGuestShares(
        _ candidate: [SessionID: [SessionShare]]
    ) -> Bool {
        persistGuestShares(sessions: candidate, terminals: terminalShares)
    }

    private func persistTerminalGuestShares(
        _ candidate: [TerminalID: [SessionShare]]
    ) -> Bool {
        persistGuestShares(sessions: sessionShares, terminals: candidate)
    }

    private func persistGuestShares(
        sessions: [SessionID: [SessionShare]],
        terminals: [TerminalID: [SessionShare]]
    ) -> Bool {
        guard guestSharePersistenceError == nil else { return false }
        let sessionRecords = sessions.flatMap { sessionID, shares in
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
        let terminalRecords = terminals.flatMap { terminalID, shares in
            shares.map { share in
                RemoteGuestShareRecord(
                    id: share.id,
                    targetKind: .projectTerminal,
                    sessionID: terminalID.uuidString,
                    invitationToken: share.invitationToken,
                    capability: share.capability,
                    canApprovePermissions: false,
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
        let records = sessionRecords + terminalRecords
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

    /// The invitation, written the way the owner's pairing link is written.
    ///
    /// `RemoteConnectionLink` owns the fragment, including the `.<fingerprint>` half, so a guest
    /// scanning or opening this pins the door it names before its first request. That is the same
    /// out-of-band step the owner code performs, and it is what makes a private door usable by
    /// somebody who has never spoken to this Mac.
    private func invitationURL(token: String) -> URL? {
        guard let destination = invitationDestination else { return nil }
        return Self.invitationURL(
            token: token,
            origin: destination.origin,
            pinnedFingerprintCode: destination.pinnedFingerprintCode
        )
    }

    nonisolated static func invitationURL(
        token: String,
        origin: URL,
        pinnedFingerprintCode: String?
    ) -> URL? {
        RemoteConnectionLink(
            baseURL: origin,
            token: token,
            pinnedFingerprintCode: pinnedFingerprintCode
        )?.shareURL
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
    }

    private func expireInvitation(token: String, terminalID: TerminalID) {
        guard var shares = terminalShares[terminalID],
              let index = shares.firstIndex(where: { $0.invitationToken == token }) else {
            return
        }
        let share = shares.remove(at: index)
        var candidate = terminalShares
        candidate[terminalID] = shares.isEmpty ? nil : shares
        guard persistTerminalGuestShares(candidate) else { return }
        terminalShares = candidate
        for member in share.members.values { revoke(member) }
        sharingChanged()
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

    /// Selects the `tailscale` door, and rebuilds the listeners for it.
    ///
    /// The door is a bind now, so this is the same operation `setDoors` performs for the network
    /// way in: one listener per tailnet address, presenting this Mac's own certificate. The CLI
    /// is asked for its facts as well, because the door being down has three different causes and
    /// only `tailscale status` can tell them apart.
    func setTailscaleDoorEnabled(_ enabled: Bool) {
        guard appSettings.remoteAccessTailscaleEnabled != enabled else { return }
        appSettings.remoteAccessTailscaleEnabled = enabled
        guard case .listening(let port) = status else {
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            return
        }
        switch tailscaleDoor {
        case .serveTransport:
            if enabled {
                startTailscale(port: port, generation: transportGeneration)
            } else {
                tailscale.stop()
                tailscaleServeStatus = .stopped
            }
        case .listenerDoor:
            server.updateDoors(listenerConfiguration().doors)
            if enabled { tailscale.refreshHostFacts() }
        }
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    /// The browser convenience on the tailnet: `tailscale serve` publishing the loopback listener
    /// at this Mac's `*.ts.net` name, so a browser there meets no certificate interstitial.
    ///
    /// Independent of the door in both directions. The phone does not use it — it pins the
    /// listener on the tailnet address instead — so turning it off takes no route away, and
    /// turning it on adds none.
    func setTailscaleServeEnabled(_ enabled: Bool) {
        guard appSettings.remoteAccessTailscaleServeEnabled != enabled else { return }
        appSettings.remoteAccessTailscaleServeEnabled = enabled
        guard case .listening(let port) = status else {
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
            return
        }
        if enabled {
            startTailscale(port: port, generation: transportGeneration)
        } else {
            tailscale.stop()
            tailscaleServeStatus = .stopped
        }
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
        stopTransports()
        server.stop()
        listenerStatus = .idle
        mirrors.remoteAccessStopped()
        RemoteNotificationService.shared.reset()
        authority.removeAll()
        pairingBootstrapToken = nil
        pairingRedemptions.removeAll()
        status = .disabled
        processActivity.end()
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

        processActivity.begin()

        // The photographed value is a bootstrap, never the durable capability. It is consumed
        // and rotated when a device exchanges it for its own 256-bit bearer.
        guard let token = Self.pairingToken() else {
            ThreadingLogger.remote.error(
                "Remote credential generation failed stage=listener_start"
            )
            status = .failed(reason: L10n.string("A secure remote access token could not be created."))
            processActivity.end()
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
        for shares in terminalShares.values {
            for share in shares {
                for member in share.members.values {
                    authority.set(member.authorization, forToken: member.token)
                }
            }
        }

        server.start(configuration: listenerConfiguration()) { [weak self] outcome in
            guard let self else { return }
            guard self.lifecycleGeneration == generation,
                  appSettings.remoteAccessEnabled else {
                return
            }
            switch outcome {
            case .listening(let port):
                self.status = .listening(port: port)
                self.applyListenerStatus(self.server.listenerStatus)
                self.mirrors.remoteAccessStarted()
                self.startTransports(port: port)
                ThreadingLogger.remote.info(
                    "Remote access listener ready port=\(port, privacy: .public)"
                )
                // The port is the whole point of the journal line: it is the sticky value a
                // paired phone remembers. Routable addresses stay out of `EventLog`; the
                // share-safe journal carries a hash of them instead.
                EventLog.shared.record(.remote, "Remote access started", ["port": String(port)])
                MacRemoteDiagnostics.record(.hostListenerStarted, fields: [
                    .transport: RemoteAccessDoor.loopback.rawValue,
                ])
            case .failed(let failure):
                self.stopTransports()
                self.authority.removeAll()
                self.pairingBootstrapToken = nil
                self.pairingRedemptions.removeAll()
                self.listenerStatus = .idle
                self.status = .failed(reason: failure.statement)
                self.processActivity.end()
                EventLog.shared.record(
                    .remote,
                    "Remote access failed to start",
                    ["reason": failure.rawValue]
                )
                MacRemoteDiagnostics.record(
                    .hostListenerFailed,
                    level: .error,
                    fields: [.reason: failure.rawValue]
                )
            }
        }
    }

    /// What the listener is asked to bind: the sticky port, and the routable doors the user
    /// selected. Loopback is not in the set because it is not a choice.
    ///
    /// The `tailscale` door is in the set because it is a bind: one listener per tailnet address,
    /// with the same identity and the same port as every other routable door. The seam is still
    /// consulted so a build pinned to the old Serve handler keeps the listener out of it.
    private func listenerConfiguration() -> RemoteListenerConfiguration {
        var doors = appSettings.remoteAccessDoors
        if tailscaleDoor == .listenerDoor, appSettings.remoteAccessTailscaleEnabled {
            doors.insert(.tailscale)
        }
        return RemoteListenerConfiguration(
            preferredPort: appSettings.remoteAccessListenerPort,
            doors: doors,
            isDiscoveryEnabled: appSettings.remoteAccessDiscoveryEnabled
        )
    }

    // MARK: - Discovery

    /// Whether this Mac announces its LAN door with Bonjour.
    var isDiscoveryEnabled: Bool { appSettings.remoteAccessDiscoveryEnabled }

    /// Starts or stops the announcement. No listener is disturbed either way, so a phone already
    /// connected over the LAN door stays connected.
    func setDiscoveryEnabled(_ enabled: Bool) {
        guard appSettings.remoteAccessDiscoveryEnabled != enabled else { return }
        appSettings.remoteAccessDiscoveryEnabled = enabled
        server.updateDiscovery(isEnabled: enabled)
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    /// What this Mac is broadcasting over Bonjour right now, if anything.
    ///
    /// The registration rather than a Bool: the instance name and the TXT record are what a
    /// person is entitled to see before deciding whether they want the broadcast at all.
    var advertisedService: RemoteServiceRegistration? { server.advertisedService }

    /// Whether a connection to the advertised service can wake this Mac, and the two facts
    /// behind it. `.unknown` until `refreshWakeOnDemandFacts()` has read them.
    private(set) var wakeOnDemand: RemoteWakeOnDemandFacts = .unknown {
        didSet {
            guard wakeOnDemand != oldValue else { return }
            NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        }
    }

    /// Reads "Wake for network access" and browses briefly for a Sleep Proxy.
    ///
    /// Both are network-and-process work, so this is asynchronous and bounded; the answer is
    /// allowed to stay unknown. Call it when the Remote Access page appears and after a network
    /// change, never on a timer: a proxy is a property of the network this Mac is on.
    func refreshWakeOnDemandFacts() async {
        wakeOnDemand = await RemoteWakeOnDemandProbe.read()
    }

    /// Selects the routable doors and rebuilds only their listeners. Loopback and the doors that
    /// did not change keep the listeners they already have.
    func setDoors(_ doors: Set<RemoteAccessDoor>) {
        let selected = doors.intersection(RemoteAccessDoor.selectable)
        guard appSettings.remoteAccessDoors != selected else { return }
        appSettings.remoteAccessDoors = selected
        server.updateDoors(listenerConfiguration().doors)
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    private func applyListenerStatus(_ status: RemoteListenerStatus) {
        guard case .listening = self.status else { return }
        listenerStatus = status
    }

    // MARK: - Transports

    /// Starts what the selected ways in are made of.
    ///
    /// Every way in an owner device can take is a listener now — the network door and the tailnet
    /// door alike — and `start` already handed the listener its door set, so nothing here starts a
    /// route. What is left is the browser convenience, which follows its own switch and no
    /// phone's, and the CLI facts the tailnet door's status line reads.
    ///
    private func startTransports(port: UInt16) {
        transportGeneration += 1
        let generation = transportGeneration
        tailscale.stop()
        hostedService.start(targetPort: port)
        tailscaleServeStatus = .stopped

        if shouldRunTailscaleServe {
            startTailscale(port: port, generation: generation)
        } else if appSettings.remoteAccessTailscaleEnabled {
            tailscale.refreshHostFacts()
        }
    }

    /// Serve runs for the sub-option, and for the old seam's door. Nothing else asks for it.
    private var shouldRunTailscaleServe: Bool {
        if appSettings.remoteAccessTailscaleServeEnabled { return true }
        return tailscaleDoor == .serveTransport && appSettings.remoteAccessTailscaleEnabled
    }

    private func startTailscale(port: UInt16, generation: Int) {
        tailscaleServeStatus = .starting
        tailscale.start(port: port) { [weak self] state in
            self?.serveTransportChanged(state, generation: generation)
        }
    }

    private func stopTransports() {
        transportGeneration += 1
        hostedPairingTask?.cancel()
        hostedPairingTask = nil
        hostedService.revokeDevice(deviceID: Self.hostedPairingDeviceID)
        hostedPairingLink = nil
        tailscale.stop()
        hostedService.stop()
        tailscaleServeStatus = .stopped
    }

    /// Produces the first-install QR route without requiring Tailscale or a bound door. The
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

    /// What Tailscale Serve is doing, journalled.
    ///
    /// Serve is the only transport left with states of its own: every way in an owner device can
    /// take is a listener, and the listener reports through `RemoteListenerStatus`. The two
    /// diagnostic events keep their names so a report can be grouped against older bundles; what
    /// they carry now is the browser convenience and nothing else.
    private func serveTransportChanged(
        _ state: RemoteTransportState,
        generation: Int
    ) {
        guard transportGeneration == generation,
              appSettings.remoteAccessEnabled,
              case .listening = status else { return }
        tailscaleServeStatus = state

        switch state {
        case .connected(let origin):
            // The published origin, hashed. Without it a report says a transport connected and
            // cannot say to what, which is exactly the question a browser failing against a dead
            // address needs answered.
            let digest = MacRemoteDiagnostics.originDigest(origin)
            MacRemoteDiagnostics.record(.relayConnected, fields: [
                .transport: Self.serveTransportName,
                .origin: digest,
            ])
            EventLog.shared.record(.remote, "Remote transport connected", [
                "transport": Self.serveTransportName,
                "origin": digest,
            ])
        case .unavailable(let reason):
            var fields: [RemoteDiagnosticField: String] = [
                .transport: Self.serveTransportName,
                .reason: Self.diagnosticReason(reason),
            ]
            if case .actionRequired(let issue, _) = tailscale.readiness {
                fields[.code] = issue.rawValue
            }
            MacRemoteDiagnostics.record(
                .relayFailed,
                level: .warning,
                fields: fields
            )
            EventLog.shared.record(.remote, "Remote transport unavailable", [
                "transport": Self.serveTransportName,
                "reason": Self.diagnosticReason(reason),
            ])
        case .stopped, .starting:
            break
        }
    }

    /// The token a diagnostic report groups Serve's own events by. Unchanged from when the
    /// tailnet had two implementations, so a bundle from either build reads the same.
    private static let serveTransportName = RemoteAccessDoor.tailscale.rawValue

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
    /// 8 bits a character where base32's uppercase alphabet encodes at 5.5. A symbol with fewer,
    /// larger modules is one a camera finds faster, which is the whole job here.
    ///
    /// 128 bits, not 256. It is an unguessable online-only bootstrap, held in memory, rotated
    /// immediately after a successful exchange, and revoked when Remote Access stops.
    ///
    /// The origin it rides on is now a private door, `HTTPS://192.168.1.42:8760/`, and the
    /// fragment carries the 26-character fingerprint beside the token. Both halves are base32
    /// upper case in the same alphanumeric segment, so the fingerprint costs characters and no
    /// mode switch. `PairingCodeImageTests` holds the measured module count.
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
