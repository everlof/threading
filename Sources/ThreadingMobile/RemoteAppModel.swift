import Foundation
import ThreadingPeerTransport
import ThreadingRemoteKit

struct RemoteNotificationOpenRequest: Equatable, Identifiable {
    let eventID: String
    let sessionID: String
    let destination: RemoteNotificationDestinationDTO

    var id: String { eventID }
}

/// The phone's two durable navigation subjects.
///
/// Projects are navigation context only; continuity persists the open chat, never a project
/// name pretending to be a session identifier. Keeping the cases typed also lets a chat opened
/// from a project return to that project's list without encoding UI routes into opaque strings.
enum MobileNavigationRoute: Hashable {
    case project(String)
    case session(String)
    case terminal(String)

    var sessionID: String? {
        guard case .session(let id) = self else { return nil }
        return id
    }
}

/// When a recoverable route miss becomes a settled, actionable dashboard failure.
///
/// One miss is ordinary network movement and the automatic retry already owns it. Three
/// consecutive bounded route races are enough to say that the Mac is unavailable *for now*
/// without flashing the full recovery surface between every backoff attempt.
enum MobileConnectionRecoveryPolicy {
    static let settledFailureAttempt = 3

    /// A single socket reset is often transient and should first retry the authenticated route.
    /// If that retry also fails, the route itself is suspect and the session joins host recovery.
    static func sessionReconnectNeedsHostRecovery(attempt: Int) -> Bool {
        attempt > 0
    }
}

/// Owns the one catalogue/route recovery allowed for a Mac at a time.
///
/// A terminal socket and the dashboard event socket can discover the same transport loss within
/// milliseconds. Before this gate, both called `RemoteAppModel.refresh()`, and every call advanced
/// the model's generation. A later caller could therefore invalidate an earlier route race after
/// it had already found the Mac. The callers then repeated the same LAN/Tailscale work until one
/// happened to survive long enough to deliver a WebSocket hello.
///
/// The task is deliberately unstructured. Cancelling one screen's waiter must not cancel recovery
/// for every other socket. Only ``invalidate()`` — an app/host lifecycle decision owned by the
/// model — cancels the shared work. The monotonically increasing identifier prevents an old
/// flight's completion from clearing a replacement installed after invalidation.
@MainActor
final class MobileHostRefreshSingleFlight {
    typealias Operation = @MainActor @Sendable () async -> Void

    private struct Flight {
        let id: Int
        let hostID: String
        let task: Task<Void, Never>
    }

    private var nextID = 0
    private var flight: Flight?

    func hasFlight(for hostID: String) -> Bool {
        flight?.hostID == hostID
    }

    func run(hostID: String, operation: @escaping Operation) async {
        if let flight, flight.hostID == hostID {
            await flight.task.value
            return
        }

        // A host transition normally calls `invalidate()` before changing identity. Keep this
        // defensive branch so a missed call can never join recovery for the wrong Mac.
        flight?.task.cancel()
        flight = nil

        nextID &+= 1
        let id = nextID
        let task = Task { @MainActor in
            await operation()
        }
        flight = Flight(id: id, hostID: hostID, task: task)

        await task.value
        if flight?.id == id {
            flight = nil
        }
    }

    func invalidate() {
        flight?.task.cancel()
        flight = nil
    }
}

@MainActor
final class RemoteAppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case online
        case offline(RemoteConnectionFailure)

        /// The named failure survives all the way to the dashboard. Keeping only its sentence
        /// made the root screen unable to choose a recovery action, and it fell back to an
        /// indeterminate loading card after the request had already failed.
        var failure: RemoteConnectionFailure? {
            guard case .offline(let failure) = self else { return nil }
            return failure
        }
    }

    /// The real work behind the dashboard's initial connection, kept separate from `Phase` so a
    /// healthy background catalogue refresh does not replace "Connected" with transient network
    /// detail. It retains semantic route kinds so localization can choose standalone or sentence
    /// grammar later; addresses and ports remain diagnostics-only.
    enum ConnectionProgress: Equatable {
        case preparingRoutes
        case tryingRoute(
            kind: String,
            previousKind: String?,
            number: Int,
            total: Int
        )
        case loadingSessions(routeKind: String)
        /// One complete bounded route race ended, but automatic recovery is already scheduled.
        /// This is not yet the settled recovery surface: the dashboard keeps the same compact
        /// progress anatomy and says exactly why it is waiting.
        case waitingToRetry(attempt: Int)
    }

    @Published private(set) var hosts: [PairedRemoteHost] {
        didSet {
            guard hosts != oldValue else { return }
            discoveryHostsChanged()
        }
    }
    @Published private(set) var me: RemoteMeDTO? {
        didSet { catalogueRevision &+= 1 }
    }
    /// Every transition is recorded, not only the current one. A support report that says only
    /// "offline" cannot tell a phone that never reached this Mac from one that reached it and
    /// lost it.
    @Published private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            MobileConnectionStateLog.record(MobileDiagnostics.connectionState(phase))
            if case .connecting = phase {
                // The route loop owns the more specific state below.
            } else {
                connectionProgress = nil
            }
        }
    }
    @Published private(set) var connectionProgress: ConnectionProgress?
    @Published private(set) var activeHostID: String?
    @Published private(set) var storageIssue: String? = nil
    @Published private(set) var notificationOpenRequest: RemoteNotificationOpenRequest?
    @Published var isPairing = false
    /// An invitation the operating system delivered, held until the pairing screen takes it.
    ///
    /// A tapped `threading://` link can arrive before that screen exists — including on a cold
    /// launch, where the URL comes with the scene's connection options — so the payload waits
    /// here rather than being handed to a view that is not on screen yet.
    @Published private(set) var pendingInvitation: String?
    @Published var navigationPath: [MobileNavigationRoute] = [] {
        didSet {
            guard !isEphemeralTerminalWireFixture else { return }
            guard let activeHostID else { return }
            if let sessionID = navigationPath.last?.sessionID {
                continuity.setLastRoute(hostID: activeHostID, sessionID: sessionID)
            } else {
                continuity.clearLastRoute()
            }
        }
    }

    private let store = RemoteHostStore()
    private let hostedConnections = HostedRemoteConnectionManager()
    /// Browses for paired Macs on this network while the app is in front of somebody.
    private let discovery = RemoteHostDiscovery()
    /// Where each paired Mac was last found on this network. In memory only: it is a fact about
    /// the network this phone is on right now, not something to write into a Keychain record.
    private var discoveredAddresses = RemoteDiscoveredAddresses()
    private let continuity: MobileSessionContinuityStore
    /// True while the app is showing the canned Mac — entered from the welcome screen's Try
    /// the Demo, or by the DEBUG screenshot environment. Every mutation path short-circuits on
    /// it, so demo state changes locally and nothing ever reaches a network (`DemoExperience`).
    @Published private(set) var isDemo = false
    /// The DEBUG simulator lab talks to a real loopback server but owns no durable pairing.
    /// Keeping the distinction separate from `isDemo` is load-bearing: demo skips the network,
    /// while this mode must traverse it and merely suppress local persistence and discovery.
    private(set) var isEphemeralTerminalWireFixture = false
    private var themeEventsTask: URLSessionWebSocketTask?
    private var themeEventsReceiveTask: Task<Void, Never>?
    private var themeEventsHelloDeadlineTask: Task<Void, Never>?
    private var themeEventsHostID: String?
    private var themeEventsGeneration = 0
    private var themeEventsRecoveryTask: Task<Void, Never>?
    /// Consecutive automatic recovery waits since the last successful catalogue/event socket.
    /// The dashboard uses the count to keep a transient miss in compact progress chrome and
    /// disclose the full recovery surface only after repeated bounded attempts.
    @Published private(set) var connectionRecoveryAttempt = 0
    private var themeEventsDidReceiveHello = false
    private var themeEventsStartedAt: UInt64?
    private var themeEventsDiagnosticFields: [RemoteDiagnosticField: String] = [:]
    private var sessionsChangedRefreshTask: Task<Void, Never>?
    private var sessionsChangedRefreshGeneration = 0
    private var pendingSessionDeltas: [String: RemoteSessionsChangedDTO] = [:]
    private var sessionDeltaApplicationTask: Task<Void, Never>?
    private var sessionDeltaApplicationGeneration = 0
    private var catalogueRevision = 0
    private var catalogueRefreshInFlightGeneration: Int?
    private var refreshGeneration = 0
    private let hostRefreshSingleFlight = MobileHostRefreshSingleFlight()
    private var activeHostedLink: RemoteConnectionLink?
    private var activeHostedHostID: String?
    /// Provisioning is a low-frequency control-plane operation. A service outage must not turn
    /// event-socket recovery into a credential-issuance retry loop.
    private var hostedProvisioningRetryAfter: [String: Date] = [:]
    private static let hostedCredentialRenewalLeadTime: TimeInterval = 24 * 60 * 60
    private static let hostedProvisioningRetryDelay: TimeInterval = 5 * 60
    private static let sessionsChangedCoalescingDelay = Duration.milliseconds(350)
    private static let sessionDeltaCoalescingDelay = Duration.milliseconds(50)
    private static let themeEventsHelloDeadline = Duration.seconds(15)
    private static let maximumThemeEventsRecoveryDelay: TimeInterval = 60
#if DEBUG
    var mobileDebugAuthenticatedEventsTask: URLSessionWebSocketTask? {
        themeEventsDidReceiveHello ? themeEventsTask : nil
    }
#endif

    init(continuity: MobileSessionContinuityStore = MobileSessionContinuityStore()) {
        self.continuity = continuity
#if DEBUG
        if let wire = MobileTerminalWireFixtureConfiguration.current {
            isEphemeralTerminalWireFixture = true
            let host = PairedRemoteHost(
                id: "terminal-wire-lab",
                hostID: "terminal-wire-lab",
                shareID: "terminal-wire-lab",
                scope: "all",
                name: "Terminal Replay",
                link: wire.link,
                lastConnectedAt: Date(),
                // Nil intentionally means "this exact paired door". Adopting the integration
                // host's advertised production routes would move a later refresh off loopback.
                endpoints: nil,
                connectionPolicy: nil,
                activeEndpointKind: RemoteHostEndpointKind.lan
            )
            hosts = [host]
            activeHostID = host.id
            phase = .connecting
            return
        }
        if let demoMode = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"],
           let link = RemoteConnectionLink(
            string: "https://david-mac.tailnet-demo.ts.net:8443/#preview"
           ) {
            isDemo = true
            var host = PairedRemoteHost(
                id: "demo-mac",
                hostID: "demo-mac",
                shareID: "my-devices",
                scope: "all",
                name: "David’s MacBook Pro",
                link: link,
                lastConnectedAt: Date(),
                endpoints: [
                    RemoteHostEndpointDTO(
                        kind: "tailscale",
                        baseURL: link.baseURL,
                        isStable: true
                    ),
                    RemoteHostEndpointDTO(
                        kind: "lan",
                        baseURL: URL(string: "https://192.168.1.42:8760/")!,
                        isStable: true
                    ),
                ],
                connectionPolicy: .privateOnly,
                activeEndpointKind: "tailscale"
            )
            if demoMode == "sessions-offline" {
                // A public, deterministic certificate fingerprint gives the recovery fixture the
                // same 26-character comparison code a real paired record carries. No credential
                // or machine state enters UI evidence.
                host.pinnedFingerprint = RemoteHostFingerprint(
                    certificateDER: Data("offline recovery evidence".utf8)
                ).hex
            }
            let studioLink = RemoteConnectionLink(
                string: "https://studio-mac.tailnet-demo.ts.net:8443/#preview"
            )!
            let studio = PairedRemoteHost(
                id: "demo-studio",
                hostID: "demo-studio",
                shareID: "my-devices",
                scope: "all",
                name: "Studio Mac",
                link: studioLink,
                lastConnectedAt: Date().addingTimeInterval(-600),
                endpoints: [RemoteHostEndpointDTO(
                    kind: "tailscale",
                    baseURL: studioLink.baseURL,
                    isStable: true
                )],
                connectionPolicy: .privateOnly,
                activeEndpointKind: "tailscale"
            )
            hosts = [host, studio]
            activeHostID = host.id
            continuity.setActiveHostID(host.id)
            if demoMode == "sessions-offline" {
                me = nil
                phase = .offline(.transport(URLError(.timedOut), host: link.baseURL.host))
                // This fixture is the settled recovery state, after automatic retries have had
                // their chance. `isDemo` prevents another attempt from being scheduled.
                connectionRecoveryAttempt = MobileConnectionRecoveryPolicy.settledFailureAttempt
            } else if demoMode == "sessions-connecting" {
                me = nil
                phase = .connecting
                connectionProgress = .tryingRoute(
                    kind: RemoteHostEndpointKind.lan,
                    previousKind: RemoteHostEndpointKind.hosted,
                    number: 2,
                    total: 3
                )
            } else {
                me = Self.demoResponse
                phase = .online
            }
            return
        }
#endif
        let loaded: [PairedRemoteHost]
        switch store.load() {
        case .success(let hosts):
            loaded = hosts
        case .failure(let error):
            loaded = []
            storageIssue = error.localizedDescription
        }
        hosts = loaded
        // Before anything is fetched: the first request after a relaunch is the one that needs
        // the pin, so the record's own fingerprints are in force ahead of it.
        RemoteHostTrust.register(loaded)
        let restoredHostID = continuity.activeHostID.flatMap { candidate in
            loaded.contains(where: { $0.id == candidate }) ? candidate : nil
        }
        activeHostID = restoredHostID ?? loaded.first?.id
        continuity.setActiveHostID(activeHostID)
#if DEBUG
        MobileDebugIncidentRecorder.shared.attach(self)
#endif
    }

    // MARK: - The demo

    /// Enters the canned Mac: fixture sessions through the real pipeline, no network anywhere
    /// (`DemoExperience`). Reachable from the welcome screen, and built for two audiences —
    /// App Review, which runs this app with no Mac to pair, and anyone who installed the phone
    /// app first. Deliberately not persisted: the demo owns no credential, so it never becomes
    /// a keychain host record, and a relaunch starts clean.
    func startDemo() {
        guard !isDemo else { return }
        isDemo = true
        isPairing = false
        navigationPath = []
        // The same hygiene as `selectHost`: a half-open theme-events socket for the real Mac
        // would exit its receive loop on the first frame (the activeHostID guard) while
        // leaving `themeEventsTask` non-nil, and `ensureThemeEvents` would then refuse to
        // reconnect it after the demo ends — live theme and session events silently dead.
        disconnectThemeEvents()
        discardHostedConnection()
        invalidateRefreshes()
        let host = DemoExperience.pairedHost
        hosts = [host]
        hostedProvisioningRetryAfter.removeAll(keepingCapacity: false)
        activeHostID = host.id
        continuity.setActiveHostID(host.id)
        me = Self.demoResponse
        phase = .online
    }

    /// Leaves the demo and restores whatever was actually paired — for a first-run user,
    /// nothing, which lands back on the welcome screen.
    func endDemo() {
        guard isDemo else { return }
        isDemo = false
        navigationPath = []
        discardHostedConnection()
        me = nil
        let loaded: [PairedRemoteHost]
        switch store.load() {
        case .success(let hosts):
            loaded = hosts
        case .failure(let error):
            loaded = []
            storageIssue = error.localizedDescription
        }
        hosts = loaded
        RemoteHostTrust.register(loaded)
        hostedProvisioningRetryAfter.removeAll(keepingCapacity: false)
        activeHostID = loaded.first?.id
        continuity.setActiveHostID(activeHostID)
        phase = .idle
        if let host = activeHost {
            ensureThemeEvents(for: host)
            Task { await refresh() }
        }
    }

    var activeHost: PairedRemoteHost? {
        guard let activeHostID else { return nil }
        return hosts.first { $0.id == activeHostID }
    }

    var client: RemoteClient? {
        activeHost.map { host in
            RemoteClient(link: activeHostedHostID == host.id ? activeHostedLink ?? host.link : host.link)
        }
    }

    var canManageThemes: Bool {
        me?.share.scope == "all"
            && me?.share.capability == RemoteCapability.interact.rawValue
            && me?.themeCatalog != nil
    }

    var canManageSessions: Bool {
        me?.share.scope == "all"
            && me?.share.capability == RemoteCapability.interact.rawValue
            && me?.newSessionCatalog != nil
    }

    var canReadUsage: Bool {
        me?.features?.contains(RemoteRESTFeature.usageDashboard.rawValue) == true
    }

    /// Routes a URL the operating system handed this app.
    ///
    /// Answers whether the URL was Threading's, so a scene that was given several can stop at
    /// the first one that meant something and leave the rest alone. It opens the pairing screen
    /// rather than accepting silently: accepting an invitation creates a durable membership on
    /// somebody else's Mac, which is not something a tap should do without showing its work.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard MobileInvitationRoute(url: url) != nil else { return false }
        pendingInvitation = url.absoluteString
        isPairing = true
        return true
    }

    /// Hands over a waiting invitation exactly once.
    func takePendingInvitation() -> String? {
        defer { pendingInvitation = nil }
        return pendingInvitation
    }

    func pair(_ invitationLink: RemoteConnectionLink, displayName: String) async throws {
        try await acceptPairing(
            invitationLink,
            displayName: displayName,
            trace: MobileDiagnostics.connectivityTrace(),
            transport: PairedRemoteHost.endpointKind(for: invitationLink.baseURL)
        )
    }

    private func acceptPairing(
        _ invitationLink: RemoteConnectionLink,
        displayName: String,
        trace: String,
        transport: String,
        recordsStart: Bool = true
    ) async throws {
        phase = .connecting
        let startedAt = MobileDiagnostics.monotonicNow()
        let pairingFields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .transport: transport,
            .origin: MobileDiagnostics.originDigest(invitationLink.baseURL),
            .phase: "pairing.accept",
            .timeoutMS: MobileDiagnostics.milliseconds(RemoteClient.defaultRequestTimeout),
        ]
        if recordsStart {
            MobileDiagnostics.recordConnectivity(
                .hostPairingStarted,
                fields: pairingFields.merging([.result: "started"]) { _, new in new }
            )
        }
        // The scanned code is the out-of-band half of the trust story, so it is in force before
        // the very first request rather than after the Mac has answered one.
        RemoteHostTrust.register(link: invitationLink)
        let acceptance: RemoteAcceptInvitationResponseDTO
        do {
            acceptance = try await RemoteClient(link: invitationLink)
                .acceptInvitation(displayName: displayName)
        } catch {
            let verdict = invitationLink.baseURL.host.flatMap {
                RemoteClient.pinningDelegate.verdict(forHost: $0)
            }
            var fields = pairingFields.merging([
                .result: "failed",
                .code: MobileDiagnostics.errorCode(error),
                .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
            ]) { _, new in new }
            if let verdict { fields[.detail] = RemoteHostTrust.token(for: verdict) }
            MobileDiagnostics.recordConnectivity(
                .hostPairingFailed,
                level: .error,
                fields: fields
            )
            // A refused pin arrives as a cancelled request, which reads as "cancelled" and
            // explains nothing. The pairing screen gets the sentence that names it instead.
            let failure = RemoteConnectionFailure.transport(
                error,
                host: invitationLink.baseURL.host,
                trustVerdict: verdict
            )
            if failure.cause == .pinnedIdentityMismatch || failure.cause == .upgradeRequired {
                throw failure
            }
            throw error
        }
        guard let link = RemoteConnectionLink(
            baseURL: invitationLink.baseURL,
            token: acceptance.accessToken,
            // The durable credential keeps the scanned fingerprint. Without it the pin would be
            // in force for this launch only and a relaunch would fall back to stock evaluation,
            // which refuses the Mac's own certificate.
            pinnedFingerprintCode: invitationLink.pinnedFingerprintCode
        ) else {
            MobileDiagnostics.recordConnectivity(
                .hostPairingFailed,
                level: .error,
                fields: pairingFields.merging([
                    .result: "failed",
                    .code: MobileDiagnostics.errorCode(RemoteClientError.invalidResponse),
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
            )
            throw RemoteClientError.invalidResponse
        }
        let me = acceptance.me
        let identity = me.host
        let hostID = identity?.id ?? link.baseURL.host ?? UUID().uuidString
        // One Mac can be present once as My Devices and again through individual guest shares.
        // A guest token must never replace the owner's all-session capability in Keychain.
        let id = me.share.scope == "all"
            ? hostID
            : "\(hostID):share:\(me.share.label)"
        var hostedServiceURL = hosts.first(where: { $0.id == id })?.hostedServiceURL
        var hostedCredential = hosts.first(where: { $0.id == id })?.hostedCredential
        if me.share.scope == "all",
           me.features?.contains(RemoteRESTFeature.hostedPeerTransport.rawValue) == true {
            let provisioningStartedAt = MobileDiagnostics.monotonicNow()
            let provisioningFields = pairingFields.merging([
                .peer: MobileDiagnostics.pseudonym(id, prefix: "peer"),
                .phase: "pairing.provisionHosted",
                .timeoutMS: MobileDiagnostics.milliseconds(RemoteClient.defaultRequestTimeout),
            ]) { _, new in new }
            MobileDiagnostics.recordConnectivity(
                .hostRouteStarted,
                fields: provisioningFields.merging([.result: "started"]) { _, new in new }
            )
            do {
                let issued = try await RemoteClient(link: link).issueHostedDeviceCredential()
                (hostedServiceURL, hostedCredential) = try Self.validateHostedCredential(
                    issued,
                    expectedHostID: hostID
                )
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    fields: provisioningFields.merging([
                        .result: "succeeded",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(
                            since: provisioningStartedAt
                        ),
                    ]) { _, new in new }
                )
            } catch {
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    level: .warning,
                    fields: provisioningFields.merging([
                        .result: "failed",
                        .code: MobileDiagnostics.errorCode(error),
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(
                            since: provisioningStartedAt
                        ),
                    ]) { _, new in new }
                )
                // Pairing and the private routes this Mac advertised remain valid. The Mac will
                // advertise the feature again so a later refresh can retry provisioning.
                hostedProvisioningRetryAfter[id] = Date().addingTimeInterval(
                    Self.hostedProvisioningRetryDelay
                )
            }
        }
        let host = PairedRemoteHost(
            id: id,
            hostID: hostID,
            shareID: me.share.label,
            scope: me.share.scope,
            name: identity?.name ?? link.baseURL.host ?? "Threading Mac",
            link: link,
            lastConnectedAt: Date(),
            endpoints: identity?.endpoints,
            connectionPolicy: identity?.connectionPolicy,
            activeEndpointKind: PairedRemoteHost.endpointKind(for: link.baseURL),
            hostedServiceURL: hostedServiceURL,
            hostedCredential: hostedCredential,
            // Owner responses only: a guest capability is not the Mac's owner and never teaches
            // this phone which certificate to trust.
            pinnedFingerprint: me.share.scope == "all" ? identity?.pinnedFingerprint : nil,
            nextPinnedFingerprint: me.share.scope == "all" ? identity?.nextPinnedFingerprint : nil
        )
        RemoteHostTrust.register([host])

        let previousHosts = hosts
        if let index = hosts.firstIndex(where: { $0.id == id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        do {
            try store.save(hosts)
            storageIssue = nil
        } catch {
            hosts = previousHosts
            storageIssue = error.localizedDescription
            phase = .offline(.transport(error.localizedDescription))
            MobileDiagnostics.recordConnectivity(
                .hostPairingFailed,
                level: .error,
                fields: pairingFields.merging([
                    .result: "failed",
                    .code: MobileDiagnostics.errorCode(error),
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
            )
            throw error
        }
        invalidateRefreshes()
        activeHostID = id
        continuity.setActiveHostID(id)
        self.me = me
        phase = .online
        isPairing = false
        ensureThemeEvents(for: host)
        MobileDiagnostics.recordConnectivity(.hostPairingSucceeded, fields: pairingFields.merging([
            .result: "succeeded",
            .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
            .peer: MobileDiagnostics.pseudonym(id, prefix: "peer"),
            .capability: me.share.capability,
        ]) { _, new in new })
    }

    func pair(_ hostedLink: HostedPairingLink, displayName: String) async throws {
        guard !hostedLink.isExpired else { throw PeerControlPlaneError.invalidCredential }
        phase = .connecting
        let endpoint = try PeerControlPlaneServiceEndpoint(hostedLink.serviceURL)
        let credential = try PeerRendezvousCredential(hostedLink.rendezvousCredential)
        let trace = MobileDiagnostics.connectivityTrace()
        let startedAt = MobileDiagnostics.monotonicNow()
        let pairingFields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .transport: RemoteHostEndpointKind.hosted,
            .phase: "pairing.prepare",
            .timeoutMS: MobileDiagnostics.milliseconds(PeerTransportBounds.negotiationTimeout),
        ]
        MobileDiagnostics.recordConnectivity(
            .hostPairingStarted,
            fields: pairingFields.merging([.result: "started"]) { _, new in new }
        )
        MobileDiagnostics.recordConnectivity(
            .hostRouteStarted,
            fields: pairingFields.merging([.result: "started"]) { _, new in new }
        )
        let tunnel: PeerHostedDeviceTunnel
        do {
            tunnel = try await PeerHostedDeviceConnector.connect(
                endpoint: endpoint.rendezvousEndpoint,
                hostID: hostedLink.hostID,
                deviceID: hostedLink.deviceID,
                credential: credential,
                progress: { phase in
                    MobileDiagnostics.recordConnectivity(.hostRouteProgress, fields: [
                        .trace: trace,
                        .transport: RemoteHostEndpointKind.hosted,
                        .phase: "pairing.hosted.\(phase.rawValue)",
                        .result: "stage",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                        .timeoutMS: MobileDiagnostics.milliseconds(
                            PeerTransportBounds.negotiationTimeout
                        ),
                    ])
                }
            )
        } catch {
            let terminalFields = pairingFields.merging([
                .result: error is CancellationError ? "cancelled" : "failed",
                .code: error is CancellationError
                    ? "swift.cancelled"
                    : MobileDiagnostics.errorCode(error),
                .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
            ]) { _, new in new }
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                level: error is CancellationError ? .info : .warning,
                fields: terminalFields
            )
            MobileDiagnostics.recordConnectivity(
                .hostPairingFailed,
                level: .error,
                fields: terminalFields
            )
            throw error
        }
        MobileDiagnostics.recordConnectivity(
            .hostRouteEnded,
            fields: pairingFields.merging([
                .result: "succeeded",
                .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
            ]) { _, new in new }
        )
        defer { tunnel.stop() }
        guard let loopbackLink = RemoteConnectionLink(
            baseURL: tunnel.origin,
            token: hostedLink.bootstrapToken
        ) else {
            MobileDiagnostics.recordConnectivity(
                .hostPairingFailed,
                level: .error,
                fields: pairingFields.merging([
                    .result: "failed",
                    .code: MobileDiagnostics.errorCode(RemoteClientError.invalidResponse),
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
            )
            throw RemoteClientError.invalidResponse
        }
        try await acceptPairing(
            loopbackLink,
            displayName: displayName,
            trace: trace,
            transport: RemoteHostEndpointKind.hosted,
            recordsStart: false
        )
        // `pair` stores the durable hosted credential through this temporary tunnel. Move the
        // live app socket onto that durable route before the temporary pairing tunnel closes.
        disconnectThemeEvents()
        await refresh()
    }

    func selectHost(_ id: String) {
        guard hosts.contains(where: { $0.id == id }), activeHostID != id else { return }
        disconnectThemeEvents()
        discardHostedConnection()
        invalidateRefreshes()
        activeHostID = id
        continuity.setActiveHostID(id)
        navigationPath.removeAll()
        // Never show one Mac's session identifiers while requests are already routed to another.
        me = nil
        phase = .connecting
    }

    func remove(_ host: PairedRemoteHost) {
        MobileDiagnostics.record(.hostRemoved, fields: [
            .peer: MobileDiagnostics.pseudonym(host.id, prefix: "peer")
        ])
        let previousHosts = hosts
        hosts.removeAll { $0.id == host.id }
        hostedProvisioningRetryAfter[host.id] = nil
        guard persistHosts() else {
            hosts = previousHosts
            return
        }
        RemoteHostTrust.forget(host, remaining: hosts)
        invalidateRefreshes()
        if activeHostID == host.id {
            disconnectThemeEvents()
            discardHostedConnection()
            activeHostID = hosts.first?.id
            continuity.setActiveHostID(activeHostID)
            me = nil
            phase = activeHostID == nil ? .idle : .connecting
        }
    }

    func refresh() async {
        guard !isDemo else { return }
        guard let host = activeHost else {
            discardPendingSessionDeltas()
            invalidateRefreshes()
            discardHostedConnection()
            me = nil
            phase = .idle
            return
        }
        let hostID = host.id
        await hostRefreshSingleFlight.run(hostID: hostID) { [weak self] in
            guard let self, self.activeHostID == hostID else { return }
            await self.performRefresh(from: host)
        }
    }

    /// Returns a route for a live-session reconnect without turning one broken session socket
    /// into a full catalogue race. If dashboard recovery already owns that race, the session
    /// joins it; if the model has no authoritative catalogue, it starts it. Otherwise the last
    /// authenticated route is exactly the route that should get the first inexpensive retry.
    func clientForSessionReconnect(hostID: String, attempt: Int) async -> RemoteClient? {
        guard activeHostID == hostID else { return nil }
        if hostRefreshSingleFlight.hasFlight(for: hostID)
            || phase != .online
            || me == nil
            || MobileConnectionRecoveryPolicy.sessionReconnectNeedsHostRecovery(attempt: attempt) {
            await refresh()
        }
        guard activeHostID == hostID else { return nil }
        return client
    }

    private func performRefresh(from host: PairedRemoteHost) async {
        discardPendingSessionDeltas()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let hostID = host.id
        let refreshTrace = MobileDiagnostics.connectivityTrace()
        let refreshStartedAt = MobileDiagnostics.monotonicNow()
        let refreshBaseFields: [RemoteDiagnosticField: String] = [
            .trace: refreshTrace,
            .peer: MobileDiagnostics.pseudonym(hostID, prefix: "peer"),
            .phase: "refresh",
        ]
        MobileDiagnostics.recordConnectivity(
            .hostRefreshStarted,
            fields: refreshBaseFields.merging([.result: "started"]) { current, _ in current }
        )
        catalogueRefreshInFlightGeneration = generation
        defer {
            if catalogueRefreshInFlightGeneration == generation {
                catalogueRefreshInFlightGeneration = nil
                startSessionDeltaApplicationIfNeeded(for: hostID)
            }
        }
        let wasOnline = phase == .online && me != nil
        if !wasOnline {
            phase = .connecting
            connectionProgress = .preparingRoutes
        }
        do {
            let connection = try await fetchMe(
                from: host,
                reportsProgress: !wasOnline,
                trace: refreshTrace
            )
            let response = connection.response
            let successfulLink = connection.link
            guard activeHostID == hostID, refreshGeneration == generation else {
                MobileDiagnostics.recordConnectivity(
                    .hostRefreshFailed,
                    level: .warning,
                    fields: refreshBaseFields.merging([
                        .result: "discarded",
                        .code: "refresh.generationChanged",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(
                            since: refreshStartedAt
                        ),
                    ]) { current, _ in current }
                )
                return
            }
            me = response
            if connectionRecoveryAttempt != 0 {
                connectionRecoveryAttempt = 0
            }
            phase = .online
            restoreRouteIfPossible(hostID: hostID, response: response)
            MobileDiagnostics.recordConnectivity(
                .hostRefreshSucceeded,
                fields: refreshBaseFields.merging([
                    .result: "succeeded",
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: refreshStartedAt),
                    .transport: connection.kind,
                    .origin: MobileDiagnostics.originDigest(successfulLink.baseURL),
                    .protocolVersion: String(response.serverProtocol.version),
                    .minimumProtocolVersion: String(response.serverProtocol.minimumSupported),
                ]) { current, _ in current }
            )
            if isEphemeralTerminalWireFixture {
                // Keep the loopback door exact and in memory. The real server still supplies
                // the catalogue and event stream; its advertised Mac routes and identity are
                // production state that do not belong in this synthetic pairing.
                ensureThemeEvents(for: host)
            } else if let index = hosts.firstIndex(where: { $0.id == hostID }) {
                let old = hosts[index]
                var updated = old
                // A pin is refined or followed only on the word of a channel that proved the
                // pinned key; over anything else the response may still be adopted where the
                // record allows it, and a foreign identity is refused and said so.
                let overPinnedChannel = !connection.isHosted
                    && successfulLink.baseURL.host.map {
                        RemoteHostTrust.liveVerdict($0.lowercased()) == .accepted
                    } == true
                let pinOutcome = updated.merge(
                    identity: response.host,
                    successfulLink: successfulLink,
                    isHosted: connection.isHosted,
                    overPinnedChannel: overPinnedChannel
                )
                if pinOutcome == .refused {
                    MobileDiagnostics.logDegraded(.hostTrust, code: .pinChangeRefused)
                }
                let metadataChanged = old.name != updated.name
                    || old.link != updated.link
                    || old.endpoints != updated.endpoints
                    || old.connectionPolicy != updated.connectionPolicy
                    || old.activeEndpointKind != updated.activeEndpointKind
                    || old.pinnedFingerprint != updated.pinnedFingerprint
                    || old.nextPinnedFingerprint != updated.nextPinnedFingerprint
                // Persist only a real connection transition or identity change, rather than
                // rewriting the credential-bearing Keychain item after every event-driven
                // catalogue refresh.
                if !wasOnline || metadataChanged {
                    hosts[index] = updated
                    _ = persistHosts()
                }
                // A pin the Mac just announced covers every address it flagged, including the
                // ones this phone has not used yet. That is what lets a phone paired on the
                // couch use the tailnet address from the train with no further ceremony.
                RemoteHostTrust.register([updated])
                ensureThemeEvents(for: updated)
            }
            if !isEphemeralTerminalWireFixture {
                await reconcileHostedCredential(
                    hostID: hostID,
                    response: response,
                    successfulLink: successfulLink,
                    generation: generation,
                    trace: refreshTrace
                )
            }
        } catch is CancellationError {
            MobileDiagnostics.recordConnectivity(
                .hostRefreshFailed,
                level: .warning,
                fields: refreshBaseFields.merging([
                    .result: "cancelled",
                    .code: "swift.cancelled",
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: refreshStartedAt),
                ]) { current, _ in current }
            )
            return
        } catch {
            guard activeHostID == hostID, refreshGeneration == generation else {
                MobileDiagnostics.recordConnectivity(
                    .hostRefreshFailed,
                    level: .warning,
                    fields: refreshBaseFields.merging([
                        .result: "discarded",
                        .code: "refresh.generationChanged",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(
                            since: refreshStartedAt
                        ),
                    ]) { current, _ in current }
                )
                return
            }
            forgetDiscovered(hostID: hostID)
            let failure = connectionFailure(for: host, error: error)
            phase = .offline(failure)
            scheduleThemeEventsRecovery(for: hostID)
            var fields = refreshBaseFields.merging([
                .result: "failed",
                .durationMS: MobileDiagnostics.elapsedMilliseconds(since: refreshStartedAt),
                .code: MobileDiagnostics.errorCode(RemoteConnectionAttempt.underlying(error)),
                .reason: failure.cause.rawValue,
            ]) { current, _ in current }
            // A token, never a fingerprint: a report says whether the identity check passed,
            // refused or never ran, which is the difference between "the Mac is off" and
            // "something else is answering at the Mac's address".
            if let verdict = RemoteHostTrust.verdictToken(for: host) {
                fields[.detail] = verdict
            }
            MobileDiagnostics.recordConnectivity(.hostRefreshFailed, level: .error, fields: fields)
        }
    }

    /// Names a failed refresh, in the same vocabulary a failed session socket uses.
    ///
    /// A pin refusal is read first and from the delegate, because the error it produces is a
    /// cancelled request with nothing in it. After that the classification is the address's:
    /// the same no-route code means "grant Local Network access" on a private address and
    /// "that machine is not answering" on a public one, which is why the attempt carries the
    /// host it was aimed at rather than the one the record happens to remember.
    private func connectionFailure(
        for host: PairedRemoteHost,
        error: Error
    ) -> RemoteConnectionFailure {
        if RemoteHostTrust.rejectedIdentity(for: host) {
            return .pinnedIdentityMismatch()
        }
        let attempt = error as? RemoteConnectionAttempt
        return RemoteConnectionFailure.transport(
            attempt?.underlying ?? error,
            host: attempt?.host ?? host.link.baseURL.host,
            trustVerdict: nil
        )
    }

    /// Establishes the dashboard's authoritative snapshot. Healthy updates arrive on the event
    /// socket; only a failed socket starts bounded exponential recovery.
    func activateDashboard() async {
        guard !isDemo else { return }
        await refresh()
    }

    func suspendHostedConnections() {
        invalidateRefreshes()
        disconnectThemeEvents()
        discardHostedConnection()
    }

    func makeSessionReady(_ session: RemoteSessionSummaryDTO) async throws {
        guard !session.isAvailable, let host = activeHost else { return }
        // A demo session has no Mac to resume it; the canned connection opens regardless.
        if isDemo { return }
        let hostID = host.id
        let link = try await performMutation(for: hostID) { client, requestID in
            try await client.resume(sessionID: session.id, requestID: requestID)
            return client.link
        }
        let client = RemoteClient(link: link)
        guard activeHostID == hostID else { throw CancellationError() }

        for _ in 0..<30 {
            try Task.checkCancellation()
            let response = try await client.fetchMe()
            guard activeHostID == hostID else { throw CancellationError() }
            me = response
            if response.sessions.first(where: { $0.id == session.id })?.isAvailable == true {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RemoteClientError.server(408)
    }

    func makeTerminalReady(_ terminal: RemoteProjectTerminalSummaryDTO) async throws {
        guard !terminal.isAvailable, let host = activeHost else { return }
        guard me?.share.capability == RemoteCapability.interact.rawValue else {
            throw RemoteClientError.unauthorized
        }
        if isDemo { return }
        let hostID = host.id
        let link = try await performMutation(for: hostID) { client, requestID in
            try await client.resumeTerminal(terminalID: terminal.id, requestID: requestID)
            return client.link
        }
        let client = RemoteClient(link: link)
        guard activeHostID == hostID else { throw CancellationError() }
        for _ in 0..<30 {
            try Task.checkCancellation()
            let response = try await client.fetchMe()
            guard activeHostID == hostID else { throw CancellationError() }
            me = response
            if response.terminals?.first(where: { $0.id == terminal.id })?.isAvailable == true {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RemoteClientError.server(408)
    }

    /// Changes the one app appearance shared by the Mac and paired clients. The local preview
    /// is applied before the round trip, then replaced by the Mac's resolved response.
    func selectAppTheme(_ themeID: String) async throws {
        guard canManageThemes, let host = activeHost, let current = me,
              let preview = current.themeCatalog?.appThemes.first(where: { $0.id == themeID })
        else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        let previous = current
        me = current.replacing(theme: preview)
        if isDemo { return }
        do {
            let response = try await performMutation(for: hostID) { client, requestID in
                try await client.setAppTheme(themeID: themeID, requestID: requestID)
            }
            guard activeHostID == hostID else { throw CancellationError() }
            me = response
        } catch {
            if activeHostID == hostID, me?.theme?.id == preview.id {
                me = previous
            }
            throw error
        }
    }

    /// Sets only this session's terminal palette. Passing nil restores project/default
    /// inheritance, matching the Mac's Theme menu.
    func selectTerminalTheme(sessionID: String, themeID: String?) async throws {
        guard canManageThemes, let host = activeHost, let current = me else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        let previous = current
        let session = current.sessions.first(where: { $0.id == sessionID })
        let preview = themeID.flatMap { selectedID in
            current.themeCatalog?.terminalThemes.first(where: { $0.id == selectedID })
        } ?? (themeID == nil ? session?.inheritedTerminalTheme : nil)
        if let preview {
            me = current.replacingSessionTheme(
                sessionID: sessionID,
                terminalTheme: preview,
                assignmentID: themeID
            )
        }
        if isDemo { return }
        do {
            let response = try await performMutation(for: hostID) { client, requestID in
                try await client.setSessionTheme(
                    sessionID: sessionID,
                    themeID: themeID,
                    requestID: requestID
                )
            }
            guard activeHostID == hostID else { throw CancellationError() }
            me = response
        } catch {
            if activeHostID == hostID {
                me = previous
            }
            throw error
        }
    }

    func createSession(
        projectID: String,
        agentKind: String,
        accountHandle: String?,
        model: String?,
        reasoningEffort: String?,
        fastMode: Bool?,
        permissionMode: String?,
        surface: RemoteSessionSurface,
        managedWorkspace: RemoteManagedWorkspacePlanDTO? = nil,
        prompt: String
    ) async throws -> RemoteSessionSummaryDTO {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        let request = RemoteCreateSessionRequestDTO(
            projectID: projectID,
            agentKind: agentKind,
            accountHandle: accountHandle,
            model: model,
            reasoningEffort: reasoningEffort,
            fastMode: fastMode,
            permissionMode: permissionMode,
            surface: surface,
            managedWorkspace: managedWorkspace,
            prompt: prompt
        )
        if isDemo {
            return me?.sessions.first ?? Self.demoResponse.sessions[0]
        }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.createSession(request, requestID: requestID)
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response.me
        guard let session = response.me.sessions.first(where: { $0.id == response.sessionID }) else {
            throw RemoteClientError.invalidResponse
        }
        return session
    }

    func renameSession(_ session: RemoteSessionSummaryDTO, to title: String) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        if isDemo { return }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.renameSession(
                sessionID: session.id,
                title: title,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func setPinned(_ pinned: Bool, for session: RemoteSessionSummaryDTO) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        if isDemo { return }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.setSessionPinned(
                sessionID: session.id,
                isPinned: pinned,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func setArchived(_ archived: Bool, for session: RemoteSessionSummaryDTO) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        if isDemo { return }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.setSessionArchived(
                sessionID: session.id,
                isArchived: archived,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func setSnoozed(until deadline: Date?, for session: RemoteSessionSummaryDTO) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        if isDemo { return }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.setSessionSnoozed(
                sessionID: session.id,
                until: deadline,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func setSurface(
        _ surface: RemoteSessionSurface,
        for session: RemoteSessionSummaryDTO
    ) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        if isDemo {
            me = me?.replacingSessionSurface(sessionID: session.id, surface: surface)
            return
        }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.setSessionSurface(
                sessionID: session.id,
                surface: surface,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func moveSessionAccount(
        _ accountID: String,
        for session: RemoteSessionSummaryDTO
    ) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        if isDemo { return }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.moveSessionAccount(
                sessionID: session.id,
                accountID: accountID,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func setLimitRecovery(
        _ policy: RemoteLimitRecoveryPolicyDTO,
        for session: RemoteSessionSummaryDTO
    ) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        if isDemo { return }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.setSessionLimitRecovery(
                sessionID: session.id,
                policy: policy,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func createShare(
        for session: RemoteSessionSummaryDTO,
        capability: String,
        canApprovePermissions: Bool
    ) async throws -> RemoteCreateShareResponseDTO {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.createShare(
                sessionID: session.id,
                capability: capability,
                canApprovePermissions: canApprovePermissions,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response.me
        return response
    }

    func revokeShares(for session: RemoteSessionSummaryDTO) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.revokeShares(sessionID: session.id, requestID: requestID)
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func createTerminalShare(
        for terminal: RemoteProjectTerminalSummaryDTO,
        capability: String
    ) async throws -> RemoteCreateShareResponseDTO {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.createTerminalShare(
                terminalID: terminal.id,
                capability: capability,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response.me
        return response
    }

    func revokeTerminalShares(for terminal: RemoteProjectTerminalSummaryDTO) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.revokeTerminalShares(
                terminalID: terminal.id,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func openSessionFromNotification(_ event: RemoteNotificationEventDTO) {
        let candidate = hosts.first {
            ($0.hostID ?? $0.id) == event.hostID && $0.isOwnerDevice
        } ?? hosts.first { ($0.hostID ?? $0.id) == event.hostID }
        guard let candidate else { return }

        selectHost(candidate.id)
        Task {
            await refresh()
            guard activeHostID == candidate.id,
                  me?.sessions.contains(where: { $0.id == event.sessionID }) == true else {
                return
            }
            if navigationPath.last != .session(event.sessionID) {
                navigationPath.append(.session(event.sessionID))
            }
            notificationOpenRequest = RemoteNotificationOpenRequest(
                eventID: event.id,
                sessionID: event.sessionID,
                destination: event.destination
            )
        }
    }

    func consumeNotificationOpenRequest(eventID: String) {
        guard notificationOpenRequest?.eventID == eventID else { return }
        notificationOpenRequest = nil
    }

    private func restoreRouteIfPossible(hostID: String, response: RemoteMeDTO) {
        guard navigationPath.isEmpty,
              let route = continuity.lastRoute,
              route.hostID == hostID,
              response.sessions.contains(where: { $0.id == route.sessionID }) else { return }
        navigationPath = [.session(route.sessionID)]
    }

    // MARK: - Same-network discovery

    /// Starts browsing for paired Macs. Called when the app comes to the front.
    ///
    /// The browse exists to answer one question: has a Mac this phone is already paired with
    /// moved to a different address on this network? It never acquires a Mac, so it does nothing
    /// at all until something has been paired, which is also what keeps iOS from asking for Local
    /// Network access before the app has a reason to want it.
    func startDiscovery() {
        guard !isDemo, !isEphemeralTerminalWireFixture else { return }
        discovery.onResolved = { [weak self] resolution in
            self?.applyDiscovered(resolution)
        }
        discovery.start(hosts: hosts)
    }

    /// Stops browsing. Called when the app goes to the background, because a browse is a
    /// multicast listener and leaving one running asks questions nobody is waiting to answer.
    func stopDiscovery() {
        discovery.stop()
    }

    /// Records where a paired Mac was found, and puts that record's existing pins into force for
    /// the address so the next request over it is checked rather than refused.
    ///
    /// Nothing durable is written. The address is the phone's own working knowledge of this
    /// network; the pairing, its endpoints and its pins are untouched.
    private func applyDiscovered(_ resolution: RemoteHostDiscovery.Resolution) {
        guard let host = hosts.first(where: { $0.id == resolution.hostRecordID }) else { return }
        guard discoveredAddresses.record(resolution.baseURL, forHostRecordID: host.id) else {
            return
        }
        RemoteHostTrust.register(discoveredHost: host, at: resolution.baseURL)
        MobileDiagnostics.recordConnectivity(.hostDiscoveryMatched, fields: [
            .peer: MobileDiagnostics.pseudonym(host.id, prefix: "peer"),
            .transport: RemoteHostEndpointKind.lan,
            .phase: "resolve",
            .result: "matched",
            .origin: MobileDiagnostics.originDigest(resolution.baseURL),
        ])
    }

    /// Forgets where a Mac was after a connection to it failed.
    ///
    /// The remembered address is this phone's working knowledge of a network, and a failed
    /// connection is the evidence that it is out of date. Dropping it puts the advertised list
    /// back in front, and clearing the browse tracking means the Mac's next announcement is
    /// resolved again rather than recognised as something already known.
    private func forgetDiscovered(hostID: String) {
        guard discoveredAddresses[hostID] != nil else { return }
        discoveredAddresses.forget(hostRecordID: hostID)
        discovery.forgetTracking()
    }

    /// Keeps the browse and the remembered addresses aligned with what is actually paired.
    private func discoveryHostsChanged() {
        discoveredAddresses.retain(hostRecordIDs: Set(hosts.map(\.id)))
        // Only ever *re-states* the match list. Starting a browse here would start one while the
        // app is in the background, which is the scene's decision and not this one's.
        guard discovery.isBrowsing else { return }
        discovery.start(hosts: hosts)
    }

    // MARK: - Live app-theme events

    struct ConnectionCandidate: Sendable {
        let link: RemoteConnectionLink
        let isHosted: Bool
        /// The product name of the way in this attempt belongs to. Port-walk attempts keep the
        /// same kind, so presentation advances only when the route actually changes.
        let kind: String
        /// Which advertised door this attempt belongs to, so the rest of a port walk can be
        /// abandoned once that door has answered. Nil for the hosted route, which is one
        /// rendezvous rather than an address with ports on it.
        let doorID: String?
        /// Original position in the complete candidate list. Lanes retain it so concurrent
        /// diagnostics still reconstruct the host's full route plan rather than four local lists.
        let diagnosticAttempt: Int?
        let diagnosticTotal: Int?

        init(
            link: RemoteConnectionLink,
            isHosted: Bool,
            kind: String,
            doorID: String?,
            diagnosticAttempt: Int? = nil,
            diagnosticTotal: Int? = nil
        ) {
            self.link = link
            self.isHosted = isHosted
            self.kind = kind
            self.doorID = doorID
            self.diagnosticAttempt = diagnosticAttempt
            self.diagnosticTotal = diagnosticTotal
        }
    }

    private struct SuccessfulConnection: Sendable {
        let response: RemoteMeDTO
        let link: RemoteConnectionLink
        let isHosted: Bool
        let kind: String
    }

    private func fetchMe(
        from host: PairedRemoteHost,
        reportsProgress: Bool,
        trace: String
    ) async throws -> SuccessfulConnection {
        let expectedRouteCount = max(host.connectionOptionLabels.count, 1)
        let remoteCandidates = host.candidates(preferring: discoveredAddresses[host.id])
        let diagnosticPositions = Dictionary(uniqueKeysWithValues: remoteCandidates.enumerated().map {
            ($0.element.link, $0.offset + 1)
        })
        let localCandidateLanes = PrivateNetworkRouteRacePlan.lanes(remoteCandidates).map { lane in
            lane.map {
                ConnectionCandidate(
                    link: $0.link,
                    isHosted: false,
                    kind: $0.kind,
                    doorID: $0.doorID,
                    diagnosticAttempt: diagnosticPositions[$0.link],
                    diagnosticTotal: remoteCandidates.count
                )
            }
        }
        let localCandidates = localCandidateLanes.flatMap { $0 }
        let hasHostedRoute = host.isOwnerDevice
            && host.hostedServiceURL != nil
            && host.hostedCredential != nil

        if reportsProgress, let firstKind = localCandidates.first?.kind
            ?? (hasHostedRoute ? RemoteHostEndpointKind.hosted : nil) {
            connectionProgress = .tryingRoute(
                kind: firstKind,
                previousKind: nil,
                number: 1,
                total: expectedRouteCount
            )
        }

        var attempts: [FirstSuccessfulTaskRace.Attempt<SuccessfulConnection>] = []
        for (index, lane) in localCandidateLanes.enumerated() {
            attempts.append(.init(
                id: "private.\(index)",
                failurePriority: index
            ) { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.fetchMeSequentially(candidates: lane, trace: trace)
            })
        }
        if hasHostedRoute {
            attempts.append(.init(id: "hosted", failurePriority: 1) { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.fetchMeHosted(
                    from: host,
                    trace: trace,
                    racesPrivateRoute: !localCandidates.isEmpty
                )
            })
        }

        do {
            let winner = try await withTaskCancellationHandler {
                try await FirstSuccessfulTaskRace.run(
                    attempts,
                    winnerSelected: { @MainActor [weak self] winnerID in
                        guard winnerID != "hosted" else { return }
                        // The hosted manager coalesces its negotiation in an unstructured task.
                        // Stop that owner before the structured race waits for its losing child.
                        await self?.hostedConnectionFailed(hostID: host.id)
                    }
                )
            } onCancel: { [weak self] in
                // Structured child cancellation does not propagate into the manager's shared,
                // unstructured negotiation. Explicitly close it so switching Macs or starting a
                // newer refresh never waits for an irrelevant hosted timeout.
                Task { @MainActor in
                    await self?.hostedConnectionFailed(hostID: host.id)
                }
            }
            if reportsProgress {
                connectionProgress = .loadingSessions(routeKind: winner.value.kind)
            }
            return winner.value
        } catch FirstSuccessfulTaskRace.RaceError.noAttempts {
            throw RemoteClientError.invalidResponse
        }
    }

    /// Walks one bounded race lane in its established order. A sticky LAN port range stays in one
    /// lane and stops as soon as its door has answered or proved unreachable.
    private func fetchMeSequentially(
        candidates: [ConnectionCandidate],
        trace: String
    ) async throws -> SuccessfulConnection {
        try await Self.walk(candidates, trace: trace, phase: "request") { index, candidate in
            let timeout = candidates.count > 1 && index < candidates.count - 1
                ? 4
                : RemoteClient.defaultRequestTimeout
            return try await self.fetchMe(
                candidate: candidate,
                trace: trace,
                attempt: candidate.diagnosticAttempt ?? index + 1,
                total: candidate.diagnosticTotal ?? candidates.count,
                timeout: timeout
            )
        }
    }

    /// The walk itself: candidates in order, first success wins, and a door is abandoned as soon
    /// as it has answered or proved unreachable.
    ///
    /// The attempt is a closure so the walk can be driven by scripted outcomes. DNS, routing,
    /// timeout and response failures otherwise depend on network state that a test fixture cannot
    /// reproduce deterministically.
    ///
    /// A door that has answered is done, whatever it answered, and so is a door the network or
    /// resolver definitively cannot reach. The remaining attempts on either are the sticky port
    /// range: another port cannot change an authenticated response, pin mismatch, DNS failure or
    /// explicit no-route error. A generic request timeout does not close the door because it
    /// carries no connection-phase evidence about the address or its other ports.
    static func walk<Value>(
        _ candidates: [ConnectionCandidate],
        trace: String,
        phase: String,
        peer: String? = nil,
        attempt: (Int, ConnectionCandidate) async throws -> Value
    ) async throws -> Value {
        var lastError: Error = RemoteClientError.invalidResponse
        var closedDoors: Set<String> = []
        for (index, candidate) in candidates.enumerated() {
            if let doorID = candidate.doorID, closedDoors.contains(doorID) { continue }
            do {
                return try await attempt(index, candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = RemoteConnectionAttempt(
                    underlying: error,
                    host: candidate.link.baseURL.host
                )
                closeDoor(
                    for: error,
                    candidates: candidates,
                    index: index,
                    closedDoors: &closedDoors,
                    trace: trace,
                    phase: phase,
                    peer: peer
                )
            }
        }
        throw lastError
    }

    /// Ends the rest of one door's port walk when its failure ruled the address out, and says so
    /// once rather than once per port.
    ///
    /// The record exists because the skip is otherwise invisible: a support report would show
    /// attempt 2 failing and attempt 12 starting with nothing between them to say why. One
    /// bounded record per door names the reason, the failure behind it and how many attempts it
    /// stood in for — never one per skipped port, which would put the cardinality back.
    static func closeDoor(
        for error: Error,
        candidates: [ConnectionCandidate],
        index: Int,
        closedDoors: inout Set<String>,
        trace: String,
        phase: String,
        peer: String? = nil
    ) {
        let candidate = candidates[index]
        guard let doorID = candidate.doorID else { return }
        let host = candidate.link.baseURL.host
        guard let ending = RemoteDoorWalk.ending(
            for: error,
            trustVerdict: host.flatMap { RemoteClient.pinningDelegate.verdict(forHost: $0) }
        ) else { return }
        closedDoors.insert(doorID)
        let skippedCandidates = candidates[(index + 1)...].filter { $0.doorID == doorID }
        let skipped = skippedCandidates.count
        guard skipped > 0 else { return }
        var fields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .transport: candidate.kind,
            .origin: MobileDiagnostics.originDigest(candidate.link.baseURL),
            .phase: phase,
            .kind: "candidate",
            .result: "skipped",
            .reason: ending.rawValue,
            .code: MobileDiagnostics.errorCode(RemoteConnectionAttempt.underlying(error)),
            .attempt: String(skippedCandidates.first?.diagnosticAttempt ?? index + 2),
            .total: String(candidate.diagnosticTotal ?? candidates.count),
            .detail: String(skipped),
        ]
        if let peer { fields[.peer] = peer }
        MobileDiagnostics.recordConnectivity(.hostRouteEnded, fields: fields)
    }

    private func fetchMeHosted(
        from host: PairedRemoteHost,
        trace: String,
        racesPrivateRoute: Bool
    ) async throws -> SuccessfulConnection {
        let preparedAt = MobileDiagnostics.monotonicNow()
        let baseFields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .peer: MobileDiagnostics.pseudonym(host.id, prefix: "peer"),
            .transport: RemoteHostEndpointKind.hosted,
            .phase: "prepare",
            .timeoutMS: MobileDiagnostics.milliseconds(PeerTransportBounds.negotiationTimeout),
        ]
        MobileDiagnostics.recordConnectivity(
            .hostRouteStarted,
            fields: baseFields.merging([.result: "started"]) { current, _ in current }
        )
        let link: RemoteConnectionLink
        do {
            guard let prepared = try await hostedConnections.link(for: host, trace: trace) else {
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    level: .warning,
                    fields: baseFields.merging([
                        .result: "unavailable",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: preparedAt),
                        .code: "hosted.unavailable",
                    ]) { current, _ in current }
                )
                throw RemoteClientError.invalidResponse
            }
            link = prepared
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            if !(error is RemoteClientError) {
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    level: cancelled ? .info : .warning,
                    fields: baseFields.merging([
                        .result: cancelled ? "cancelled" : "failed",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: preparedAt),
                        .code: cancelled ? "swift.cancelled" : MobileDiagnostics.errorCode(error),
                    ]) { current, _ in current }
                )
            }
            await hostedConnectionFailed(hostID: host.id)
            if cancelled { throw CancellationError() }
            throw error
        }
        if activeHostID == host.id {
            activeHostedHostID = host.id
            activeHostedLink = link
        }
        MobileDiagnostics.recordConnectivity(
            .hostRouteEnded,
            fields: baseFields.merging([
                .result: "succeeded",
                .durationMS: MobileDiagnostics.elapsedMilliseconds(since: preparedAt),
            ]) { current, _ in current }
        )
        let timeout = racesPrivateRoute ? 4 : RemoteClient.defaultRequestTimeout
        do {
            return try await fetchMe(
                candidate: ConnectionCandidate(
                    link: link,
                    isHosted: true,
                    kind: RemoteHostEndpointKind.hosted,
                    doorID: nil
                ),
                trace: trace,
                attempt: 1,
                total: 1,
                timeout: timeout
            )
        } catch {
            await hostedConnectionFailed(hostID: host.id)
            throw error
        }
    }

    private func fetchMe(
        candidate: ConnectionCandidate,
        trace: String,
        attempt: Int,
        total: Int,
        timeout: TimeInterval
    ) async throws -> SuccessfulConnection {
        let startedAt = MobileDiagnostics.monotonicNow()
        let baseFields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .transport: candidate.kind,
            .origin: MobileDiagnostics.originDigest(candidate.link.baseURL),
            .phase: "request",
            .kind: candidate.doorID == nil ? "hosted" : "candidate",
            .attempt: String(attempt),
            .total: String(total),
            .timeoutMS: MobileDiagnostics.milliseconds(timeout),
        ]
        MobileDiagnostics.recordConnectivity(
            .hostRouteStarted,
            fields: baseFields.merging([.result: "started"]) { current, _ in current }
        )
        do {
            let response = try await RemoteClient(link: candidate.link).fetchMe(timeout: timeout)
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                fields: baseFields.merging([
                    .result: "succeeded",
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { current, _ in current }
            )
            return SuccessfulConnection(
                response: response,
                link: candidate.link,
                isHosted: candidate.isHosted,
                kind: candidate.kind
            )
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            var fields = baseFields.merging([
                .result: cancelled ? "cancelled" : "failed",
                .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                .code: cancelled ? "swift.cancelled" : MobileDiagnostics.errorCode(error),
            ]) { current, _ in current }
            if let remote = error as? RemoteClientError,
               case .server(let status) = remote {
                fields[.status] = String(status)
            }
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                level: cancelled ? .info : .warning,
                fields: fields
            )
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    /// Tries every policy-approved endpoint with one request id. A timeout after the Mac has
    /// committed the operation therefore cannot create a second session or apply an action
    /// twice when the client continues over another route.
    private func performMutation<Response>(
        for hostID: String,
        operation: (RemoteClient, String) async throws -> Response
    ) async throws -> Response {
        guard let host = hosts.first(where: { $0.id == hostID }) else {
            throw CancellationError()
        }
        let requestID = UUID().uuidString.lowercased()
        let peer = MobileDiagnostics.pseudonym(host.id, prefix: "peer")
        let preparedAt = MobileDiagnostics.monotonicNow()
        let preparationFields: [RemoteDiagnosticField: String] = [
            .trace: requestID,
            .peer: peer,
            .phase: "mutation.prepare",
            .result: "started",
        ]
        MobileDiagnostics.recordConnectivity(.hostRouteStarted, fields: preparationFields)
        let prepared = await connectionCandidates(for: host, trace: requestID)
        var preparedFields = preparationFields
        preparedFields[.result] = prepared.candidates.isEmpty ? "failed" : "succeeded"
        preparedFields[.durationMS] = MobileDiagnostics.elapsedMilliseconds(since: preparedAt)
        if let error = prepared.error {
            preparedFields[.code] = MobileDiagnostics.errorCode(error)
        }
        MobileDiagnostics.recordConnectivity(
            .hostRouteEnded,
            level: prepared.candidates.isEmpty ? .warning : .info,
            fields: preparedFields
        )
        var lastError: Error = prepared.error ?? RemoteClientError.invalidResponse
        var closedDoors: Set<String> = []
        for (index, candidate) in prepared.candidates.enumerated() {
            if let doorID = candidate.doorID, closedDoors.contains(doorID) { continue }
            let timeout = prepared.candidates.count > 1
                && index < prepared.candidates.count - 1
                ? 8
                : RemoteClient.defaultRequestTimeout
            let startedAt = MobileDiagnostics.monotonicNow()
            let routeFields: [RemoteDiagnosticField: String] = [
                .trace: requestID,
                .peer: peer,
                .transport: candidate.kind,
                .origin: MobileDiagnostics.originDigest(candidate.link.baseURL),
                .phase: "mutation.request",
                .result: "started",
                .attempt: String(index + 1),
                .total: String(prepared.candidates.count),
                .timeoutMS: MobileDiagnostics.milliseconds(timeout),
            ]
            MobileDiagnostics.recordConnectivity(.hostRouteStarted, fields: routeFields)
            do {
                let response = try await operation(
                    RemoteClient(link: candidate.link, requestTimeout: timeout),
                    requestID
                )
                guard activeHostID == hostID else { throw CancellationError() }
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    fields: routeFields.merging([
                        .result: "succeeded",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                    ]) { _, new in new }
                )
                invalidateRefreshes()
                if let index = hosts.firstIndex(where: { $0.id == hostID }),
                   (candidate.isHosted
                        ? hosts[index].activeEndpointKind != "hosted"
                        : hosts[index].link != candidate.link) {
                    hosts[index].merge(
                        identity: nil,
                        successfulLink: candidate.link,
                        isHosted: candidate.isHosted
                    )
                    _ = persistHosts()
                    disconnectThemeEvents()
                }
                return response
            } catch is CancellationError {
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    fields: routeFields.merging([
                        .result: "cancelled",
                        .code: "swift.cancelled",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                    ]) { _, new in new }
                )
                throw CancellationError()
            } catch let error as RemoteClientError {
                var failedFields = routeFields.merging([
                    .result: "failed",
                    .code: MobileDiagnostics.errorCode(error),
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
                if case .server(let status) = error {
                    failedFields[.status] = String(status)
                }
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    level: .warning,
                    fields: failedFields
                )
                // HTTP answers are authoritative. Failover is for transport loss, not for
                // bypassing an authorization or compatibility decision made by the Mac. A
                // gateway failure can belong to the route in front of it, and the same request
                // id keeps trying the next route safe even if the Mac did receive it.
                if case .server(let status) = error, [502, 503, 504].contains(status) {
                    lastError = error
                    Self.closeDoor(
                        for: error,
                        candidates: prepared.candidates,
                        index: index,
                        closedDoors: &closedDoors,
                        trace: requestID,
                        phase: "mutation.request",
                        peer: peer
                    )
                    if candidate.isHosted { await hostedConnectionFailed(hostID: host.id) }
                    continue
                }
                if candidate.isHosted { await hostedConnectionFailed(hostID: host.id) }
                throw error
            } catch {
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    level: .warning,
                    fields: routeFields.merging([
                        .result: "failed",
                        .code: MobileDiagnostics.errorCode(error),
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                    ]) { _, new in new }
                )
                lastError = error
                Self.closeDoor(
                    for: error,
                    candidates: prepared.candidates,
                    index: index,
                    closedDoors: &closedDoors,
                    trace: requestID,
                    phase: "mutation.request",
                    peer: peer
                )
                if candidate.isHosted { await hostedConnectionFailed(hostID: host.id) }
            }
        }
        throw lastError
    }

    private func connectionCandidates(
        for host: PairedRemoteHost,
        routeWillBegin: ((String) -> Void)? = nil,
        trace: String? = nil
    ) async -> (candidates: [ConnectionCandidate], error: Error?) {
        var candidates: [ConnectionCandidate] = []
        var preparationError: Error?
        do {
            if host.hostedServiceURL != nil, host.hostedCredential != nil {
                routeWillBegin?(RemoteHostEndpointKind.hosted)
            }
            if let hostedLink = try await hostedConnections.link(for: host, trace: trace) {
                candidates.append(
                    ConnectionCandidate(
                        link: hostedLink,
                        isHosted: true,
                        kind: RemoteHostEndpointKind.hosted,
                        doorID: nil
                    )
                )
                if activeHostID == host.id {
                    activeHostedHostID = host.id
                    activeHostedLink = hostedLink
                }
            }
        } catch is CancellationError {
            preparationError = CancellationError()
        } catch {
            preparationError = error
            await hostedConnectionFailed(hostID: host.id)
        }
        for candidate in host.candidates(preferring: discoveredAddresses[host.id])
        where !candidates.contains(where: { $0.link == candidate.link }) {
            candidates.append(ConnectionCandidate(
                link: candidate.link,
                isHosted: false,
                kind: candidate.kind,
                doorID: candidate.doorID
            ))
        }
        return (candidates, preparationError)
    }

    private func hostedConnectionFailed(hostID: String) async {
        await hostedConnections.invalidate(hostID: hostID)
        if activeHostedHostID == hostID {
            activeHostedHostID = nil
            activeHostedLink = nil
        }
    }

    private func reconcileHostedCredential(
        hostID: String,
        response: RemoteMeDTO,
        successfulLink: RemoteConnectionLink,
        generation: Int,
        trace: String
    ) async {
        guard activeHostID == hostID, refreshGeneration == generation,
              let index = hosts.firstIndex(where: { $0.id == hostID }),
              hosts[index].isOwnerDevice else { return }

        let advertised = response.features?.contains(
            RemoteRESTFeature.hostedPeerTransport.rawValue
        ) == true
        if !advertised {
            hostedProvisioningRetryAfter[hostID] = nil
            guard hosts[index].hostedCredential != nil || hosts[index].hostedServiceURL != nil else {
                return
            }
            hosts[index].hostedCredential = nil
            hosts[index].hostedServiceURL = nil
            _ = persistHosts()
            await hostedConnectionFailed(hostID: hostID)
            return
        }

        let credentialSecondsRemaining = hosts[index].hostedCredential?.expiresAt
            .timeIntervalSinceNow ?? 0
        let needsCredential = credentialSecondsRemaining
            <= Self.hostedCredentialRenewalLeadTime
        guard needsCredential,
              hostedProvisioningRetryAfter[hostID, default: .distantPast] <= Date() else { return }
        let startedAt = MobileDiagnostics.monotonicNow()
        let fields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .peer: MobileDiagnostics.pseudonym(hostID, prefix: "peer"),
            .transport: PairedRemoteHost.endpointKind(for: successfulLink.baseURL),
            .origin: MobileDiagnostics.originDigest(successfulLink.baseURL),
            .phase: "refresh.provisionHosted",
            .timeoutMS: MobileDiagnostics.milliseconds(RemoteClient.defaultRequestTimeout),
        ]
        MobileDiagnostics.recordConnectivity(
            .hostRouteStarted,
            fields: fields.merging([.result: "started"]) { _, new in new }
        )
        do {
            let issued = try await RemoteClient(link: successfulLink).issueHostedDeviceCredential()
            let (serviceURL, credential) = try Self.validateHostedCredential(
                issued,
                expectedHostID: hosts[index].hostID ?? hostID
            )
            guard activeHostID == hostID, refreshGeneration == generation,
                  let currentIndex = hosts.firstIndex(where: { $0.id == hostID }) else {
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    level: .warning,
                    fields: fields.merging([
                        .result: "discarded",
                        .code: "refresh.generationChanged",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                    ]) { _, new in new }
                )
                return
            }
            let changed = hosts[currentIndex].hostedServiceURL != serviceURL
                || hosts[currentIndex].hostedCredential != credential
            hosts[currentIndex].hostedServiceURL = serviceURL
            hosts[currentIndex].hostedCredential = credential
            hostedProvisioningRetryAfter[hostID] = nil
            if changed {
                _ = persistHosts()
                disconnectThemeEvents()
                await hostedConnectionFailed(hostID: hostID)
            }
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                fields: fields.merging([
                    .result: "succeeded",
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
            )
        } catch is CancellationError {
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                fields: fields.merging([
                    .result: "cancelled",
                    .code: "swift.cancelled",
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
            )
            return
        } catch {
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                level: .warning,
                fields: fields.merging([
                    .result: "failed",
                    .code: MobileDiagnostics.errorCode(error),
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
            )
            hostedProvisioningRetryAfter[hostID] = Date().addingTimeInterval(
                Self.hostedProvisioningRetryDelay
            )
        }
    }

    @discardableResult
    private func persistHosts() -> Bool {
        do {
            try store.save(hosts)
            storageIssue = nil
            return true
        } catch {
            storageIssue = error.localizedDescription
            return false
        }
    }

    private func invalidateRefreshes() {
        hostRefreshSingleFlight.invalidate()
        refreshGeneration &+= 1
        connectionProgress = nil
    }

    private func discardHostedConnection() {
        activeHostedHostID = nil
        activeHostedLink = nil
        Task { await hostedConnections.invalidate() }
    }

    private static func validateHostedCredential(
        _ response: RemoteHostedDeviceCredentialDTO,
        expectedHostID: String
    ) throws -> (URL, PeerDeviceServiceCredential) {
        guard response.hostID == expectedHostID,
              response.deviceID == RemoteDeviceIdentity.current,
              response.expiresAt.isFinite,
              let rawURL = URL(string: response.serviceURL) else {
            throw RemoteClientError.invalidResponse
        }
        let endpoint = try PeerControlPlaneServiceEndpoint(rawURL)
        let expiresAt = Date(timeIntervalSince1970: response.expiresAt / 1_000)
        guard expiresAt > Date().addingTimeInterval(60),
              expiresAt < Date().addingTimeInterval(370 * 24 * 60 * 60) else {
            throw RemoteClientError.invalidResponse
        }
        let credential = try PeerDeviceServiceCredential(
            hostID: response.hostID,
            deviceID: response.deviceID,
            credential: PeerControlPlaneBearer(response.credential),
            expiresAt: expiresAt
        )
        return (endpoint.baseURL, credential)
    }

    private func ensureThemeEvents(for host: PairedRemoteHost) {
        guard !isDemo else { return }
        if themeEventsHostID == host.id, themeEventsTask != nil { return }
        clearThemeEventSocket()

        let link = activeHostedHostID == host.id ? activeHostedLink ?? host.link : host.link
        let client = RemoteClient(link: link)
        let trace = MobileDiagnostics.connectivityTrace()
        themeEventsStartedAt = MobileDiagnostics.monotonicNow()
        themeEventsDiagnosticFields = [
            .trace: trace,
            .peer: MobileDiagnostics.pseudonym(host.id, prefix: "peer"),
            .transport: PairedRemoteHost.endpointKind(for: link.baseURL),
            .origin: MobileDiagnostics.originDigest(link.baseURL),
            .surface: "events",
        ]
        let task: URLSessionWebSocketTask
        do {
            task = try client.eventsWebSocketTask()
        } catch {
            MobileDiagnostics.recordConnectivity(
                .socketFailed,
                level: .error,
                fields: themeEventFields(phase: "events.hello").merging([
                    .result: "failed",
                    .code: MobileDiagnostics.errorCode(error),
                    .timeoutMS: MobileDiagnostics.milliseconds(
                        Self.themeEventsHelloDeadline
                    ),
                ]) { _, new in new }
            )
            scheduleThemeEventsRecovery(for: host.id)
            return
        }
        themeEventsRecoveryTask?.cancel()
        themeEventsRecoveryTask = nil
        themeEventsGeneration &+= 1
        let generation = themeEventsGeneration
        themeEventsHostID = host.id
        themeEventsTask = task
        themeEventsDidReceiveHello = false
        MobileDiagnostics.recordConnectivity(
            .socketConnecting,
            fields: themeEventFields(phase: "events.hello").merging([
                .result: "started",
                .attempt: String(connectionRecoveryAttempt + 1),
                .timeoutMS: MobileDiagnostics.milliseconds(Self.themeEventsHelloDeadline),
                .protocolVersion: String(RemoteProtocol.current),
                .minimumProtocolVersion: String(RemoteProtocol.minimumSupported),
            ]) { _, new in new }
        )
        task.resume()
        armThemeEventsHelloDeadline(hostID: host.id, generation: generation)

        let auth = RemoteClientMessage(
            type: "auth",
            token: link.token,
            device: RemoteDeviceIdentity.current,
            protocolVersion: RemoteProtocol.current,
            protocolMinimum: RemoteProtocol.minimumSupported
        )
        if let data = try? JSONEncoder().encode(auth) {
            task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
        }
        themeEventsReceiveTask = Task { [weak self, task] in
            await self?.receiveThemeEvents(
                task: task,
                hostID: host.id,
                generation: generation
            )
        }
    }

    private func receiveThemeEvents(
        task: URLSessionWebSocketTask,
        hostID: String,
        generation: Int
    ) async {
        do {
            while !Task.isCancelled,
                  themeEventsGeneration == generation,
                  themeEventsTask === task {
                let message = try await task.receive()
                guard activeHostID == hostID else { return }
                guard case .string(let text) = message else { continue }
                let data = Data(text.utf8)
                struct Envelope: Decodable { let type: String }
                guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                    continue
                }
                // The server sends an authoritative appTheme frame immediately after auth. Any
                // well-formed event proves this socket is authenticated and clears backoff.
                if !themeEventsDidReceiveHello {
                    themeEventsDidReceiveHello = true
                    cancelThemeEventsHelloDeadline()
                    MobileDiagnostics.recordConnectivity(
                        .socketConnected,
                        fields: themeEventFields(phase: "events.hello").merging([
                            .result: "succeeded",
                            .attempt: String(connectionRecoveryAttempt + 1),
                        ]) { _, new in new }
                    )
#if DEBUG
                    sendMobileDebugHello(on: task)
#endif
                }
                if connectionRecoveryAttempt != 0 {
                    connectionRecoveryAttempt = 0
                }
                switch envelope.type {
                case "appTheme":
                    if let update = try? JSONDecoder().decode(
                        RemoteAppThemeUpdateDTO.self,
                        from: data
                    ) {
                        me = me?.replacing(theme: update.theme)
                    }
                case "sessionsChanged":
                    guard let update = try? JSONDecoder().decode(
                        RemoteSessionsChangedDTO.self,
                        from: data
                    ) else { continue }
                    if me != nil,
                       update.session != nil || update.removedSessionID != nil
                        || update.terminal != nil || update.removedTerminalID != nil {
                        scheduleSessionDelta(update, for: hostID)
                    } else {
                        discardPendingSessionDeltas()
                        // Structural changes still need an authoritative scoped snapshot. A
                        // bounded coalescing window prevents a mutation burst from fanning out
                        // into one full catalogue request per event.
                        scheduleSessionsChangedRefresh(for: hostID)
                    }
                case "notification":
                    if let event = try? JSONDecoder().decode(
                        RemoteNotificationEventDTO.self,
                        from: data
                    ) {
                        RemoteNotificationBridge.received(event, connectionID: hostID)
                    }
#if DEBUG
                case "mobileDebugCaptureRequest":
                    if let request = try? JSONDecoder().decode(
                        RemoteMobileDebugCaptureRequestDTO.self,
                        from: data
                    ) {
                        await performMobileDebugCapture(request, hostID: hostID)
                    }
#endif
                default:
                    continue
                }
            }
            if !Task.isCancelled,
               themeEventsGeneration == generation,
               themeEventsTask === task {
                cancelThemeEventsHelloDeadline()
                MobileDiagnostics.recordConnectivity(
                    .socketEnded,
                    fields: themeEventFields(
                        phase: themeEventsDidReceiveHello ? "events.session" : "events.hello"
                    ).merging([
                        .result: "ended",
                        .reason: "remoteClose",
                    ]) { _, new in new }
                )
            }
        } catch is CancellationError {
            return
        } catch {
            if themeEventsGeneration == generation, themeEventsTask === task {
                cancelThemeEventsHelloDeadline()
                MobileDiagnostics.recordConnectivity(
                    .socketFailed,
                    level: .error,
                    fields: themeEventFields(
                        phase: themeEventsDidReceiveHello ? "events.session" : "events.hello"
                    ).merging([
                        .result: "failed",
                        .code: MobileDiagnostics.errorCode(error),
                    ]) { _, new in new }
                )
            }
        }
        if themeEventsGeneration == generation, themeEventsTask === task {
            themeEventsTask = nil
            themeEventsReceiveTask = nil
            themeEventsHostID = nil
            scheduleThemeEventsRecovery(for: hostID)
        }
    }

    private func disconnectThemeEvents() {
        clearThemeEventSocket(reason: "owner")
        themeEventsRecoveryTask?.cancel()
        themeEventsRecoveryTask = nil
        if connectionRecoveryAttempt != 0 {
            connectionRecoveryAttempt = 0
        }
        sessionsChangedRefreshGeneration &+= 1
        sessionsChangedRefreshTask?.cancel()
        sessionsChangedRefreshTask = nil
        discardPendingSessionDeltas()
    }

    private func clearThemeEventSocket(reason: String = "replaced") {
        let hadTask = themeEventsTask != nil
        if hadTask, !themeEventsDiagnosticFields.isEmpty {
            MobileDiagnostics.recordConnectivity(
                .socketEnded,
                fields: themeEventFields(
                    phase: themeEventsDidReceiveHello ? "events.session" : "events.hello"
                ).merging([
                    .result: "ended",
                    .reason: reason,
                ]) { _, new in new }
            )
        }
        themeEventsGeneration &+= 1
        cancelThemeEventsHelloDeadline()
        themeEventsReceiveTask?.cancel()
        themeEventsReceiveTask = nil
        themeEventsTask?.cancel(with: .goingAway, reason: nil)
        themeEventsTask = nil
        themeEventsHostID = nil
        themeEventsDidReceiveHello = false
        themeEventsStartedAt = nil
        themeEventsDiagnosticFields = [:]
    }

    private func scheduleThemeEventsRecovery(for hostID: String) {
        guard !isDemo, activeHostID == hostID, themeEventsTask == nil,
              themeEventsRecoveryTask == nil else { return }
        let exponent = min(connectionRecoveryAttempt, 6)
        let delay = min(
            pow(2, Double(exponent)),
            Self.maximumThemeEventsRecoveryDelay
        )
        connectionRecoveryAttempt &+= 1
        if case .offline = phase {
            connectionProgress = .waitingToRetry(attempt: connectionRecoveryAttempt)
        }
        if !themeEventsDiagnosticFields.isEmpty {
            MobileDiagnostics.recordConnectivity(
                .socketReconnectScheduled,
                fields: themeEventFields(phase: "events.backoff").merging([
                    .result: "scheduled",
                    .attempt: String(connectionRecoveryAttempt + 1),
                    .delayMS: MobileDiagnostics.milliseconds(delay),
                ]) { _, new in new }
            )
        }
        themeEventsRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.recoverThemeEvents(for: hostID)
        }
    }

    private func recoverThemeEvents(for hostID: String) async {
        themeEventsRecoveryTask = nil
        guard !isDemo, activeHostID == hostID, themeEventsTask == nil else { return }
        await refresh()
        if activeHostID == hostID, themeEventsTask == nil {
            scheduleThemeEventsRecovery(for: hostID)
        }
    }

    private func armThemeEventsHelloDeadline(hostID: String, generation: Int) {
        cancelThemeEventsHelloDeadline()
        themeEventsHelloDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.themeEventsHelloDeadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.themeEventsHelloDeadlineExpired(hostID: hostID, generation: generation)
        }
    }

    private func cancelThemeEventsHelloDeadline() {
        themeEventsHelloDeadlineTask?.cancel()
        themeEventsHelloDeadlineTask = nil
    }

    private func themeEventsHelloDeadlineExpired(hostID: String, generation: Int) {
        guard themeEventsGeneration == generation, themeEventsTask != nil,
              !themeEventsDidReceiveHello else { return }
        themeEventsHelloDeadlineTask = nil
        MobileDiagnostics.recordConnectivity(
            .socketFailed,
            level: .error,
            fields: themeEventFields(phase: "events.hello").merging([
                .result: "failed",
                .reason: RemoteConnectionFailure.Cause.helloTimeout.rawValue,
                .code: "connection.helloTimeout",
                .timeoutMS: MobileDiagnostics.milliseconds(Self.themeEventsHelloDeadline),
            ]) { _, new in new }
        )
        themeEventsGeneration &+= 1
        themeEventsReceiveTask?.cancel()
        themeEventsReceiveTask = nil
        themeEventsTask?.cancel(with: .goingAway, reason: nil)
        themeEventsTask = nil
        themeEventsHostID = nil
        scheduleThemeEventsRecovery(for: hostID)
    }

    private func themeEventFields(phase: String) -> [RemoteDiagnosticField: String] {
        var fields = themeEventsDiagnosticFields
        fields[.phase] = phase
        if let themeEventsStartedAt {
            fields[.durationMS] = MobileDiagnostics.elapsedMilliseconds(
                since: themeEventsStartedAt
            )
        }
        return fields
    }

    private func scheduleSessionsChangedRefresh(for hostID: String) {
        guard activeHostID == hostID, sessionsChangedRefreshTask == nil else { return }
        sessionsChangedRefreshGeneration &+= 1
        let generation = sessionsChangedRefreshGeneration
        sessionsChangedRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.sessionsChangedCoalescingDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.refreshSessionsChanged(
                for: hostID,
                generation: generation
            )
        }
    }

    private func scheduleSessionDelta(
        _ update: RemoteSessionsChangedDTO,
        for hostID: String
    ) {
        guard activeHostID == hostID,
              let key = catalogueDeltaKey(update) else { return }
        pendingSessionDeltas[key] = update
        startSessionDeltaApplicationIfNeeded(for: hostID)
    }

    private func startSessionDeltaApplicationIfNeeded(for hostID: String) {
        guard catalogueRefreshInFlightGeneration == nil,
              sessionDeltaApplicationTask == nil,
              !pendingSessionDeltas.isEmpty else { return }
        sessionDeltaApplicationGeneration &+= 1
        let generation = sessionDeltaApplicationGeneration
        sessionDeltaApplicationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.sessionDeltaCoalescingDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.applyPendingSessionDeltas(
                for: hostID,
                generation: generation
            )
        }
    }

    private func applyPendingSessionDeltas(for hostID: String, generation: Int) async {
        guard activeHostID == hostID,
              sessionDeltaApplicationGeneration == generation else { return }
        let updates = Array(pendingSessionDeltas.values)
        pendingSessionDeltas.removeAll(keepingCapacity: true)
        guard let current = me else {
            sessionDeltaApplicationTask = nil
            scheduleSessionsChangedRefresh(for: hostID)
            return
        }
        let revision = catalogueRevision
        // A delta burst can still touch a large local catalogue. Perform the merge and sort off
        // the main actor, then publish one value for SwiftUI's identity-based visible-row diff.
        let updated = await Task.detached(priority: .userInitiated) {
            current.applying(updates)
        }.value
        guard activeHostID == hostID,
              sessionDeltaApplicationGeneration == generation else { return }
        guard catalogueRevision == revision else {
            // A mutation response, theme update or authoritative refresh won the race. Keep a
            // newer queued delta for the same session; otherwise replay this one against the
            // newly published snapshot instead of overwriting it with stale companion fields.
            for update in updates {
                guard let key = catalogueDeltaKey(update),
                      pendingSessionDeltas[key] == nil else { continue }
                pendingSessionDeltas[key] = update
            }
            sessionDeltaApplicationTask = nil
            startSessionDeltaApplicationIfNeeded(for: hostID)
            return
        }
        me = updated
        sessionDeltaApplicationTask = nil
        startSessionDeltaApplicationIfNeeded(for: hostID)
    }

    private func catalogueDeltaKey(_ update: RemoteSessionsChangedDTO) -> String? {
        if let id = update.removedTerminalID ?? update.terminal?.id {
            return "terminal:\(id)"
        }
        if let id = update.removedSessionID ?? update.session?.id {
            return "session:\(id)"
        }
        return nil
    }

    private func discardPendingSessionDeltas() {
        sessionDeltaApplicationGeneration &+= 1
        sessionDeltaApplicationTask?.cancel()
        sessionDeltaApplicationTask = nil
        pendingSessionDeltas.removeAll(keepingCapacity: true)
    }

    private func refreshSessionsChanged(for hostID: String, generation: Int) async {
        guard activeHostID == hostID,
              sessionsChangedRefreshGeneration == generation else { return }
        await refresh()
        if sessionsChangedRefreshGeneration == generation {
            sessionsChangedRefreshTask = nil
        }
    }

    static let demoTheme = RemoteThemeDTO(
        id: "cyberpunk",
        name: "Cyberpunk",
        mode: "dark",
        colors: [
            "ground": "#07070B",
            "surface": "#0D0D14",
            "panel": "#14142A",
            "elevated": "#1B1B36",
            "control_resting": "#00FF881A",
            "control_hover": "#00FF8833",
            "border": "#2E2E5A",
            "divider": "#1F1F3A",
            "label": "#E6FFF4",
            "secondary_label": "#E6FFF4B2",
            "tertiary_label": "#E6FFF473",
            "accent": "#00FF88",
            "accent_muted": "#00FF882E",
            "selection": "#00FF884D",
            "status_positive": "#00FF88",
            "status_warning": "#FFB000",
            "status_negative": "#FF3366",
            "diff_added": "#00FF88",
            "diff_removed": "#FF3366",
        ],
        material: .init(
            panelRadius: 3,
            controlRadius: 2,
            borderWidth: 1,
            glow: .init(color: "#00FF88", radius: 10, opacity: 0.28)
        )
    )

    static let demoLightTheme = RemoteThemeDTO(
        id: "paper",
        name: "Paper",
        mode: "light",
        colors: [
            "ground": "#F6F1E8",
            "surface": "#EEE7DA",
            "panel": "#FFFDF8",
            "elevated": "#FFFFFF",
            "control_resting": "#315B7A14",
            "control_hover": "#315B7A24",
            "border": "#614C3829",
            "divider": "#614C381F",
            "label": "#241E19",
            "secondary_label": "#685C51",
            "tertiary_label": "#948579",
            "accent": "#1B668A",
            "accent_muted": "#1B668A24",
            "selection": "#1B668A30",
            "status_positive": "#317A4B",
            "status_warning": "#A86716",
            "status_negative": "#A13D3D",
            "diff_added": "#317A4B",
            "diff_removed": "#A13D3D",
        ],
        material: .init(
            panelRadius: 22,
            controlRadius: 11,
            borderWidth: 1
        )
    )

    /// Deterministic projection of the System-theme seam that matters to floating chrome.
    /// `panel` is intentionally only a label wash, while the Mac-resolved floating role is an
    /// opaque control surface. This is an evidence sentinel, not a snapshot of OS-owned pixels.
    static let demoSystemRemoteTheme = RemoteThemeDTO(
        id: "system-remote",
        name: "System remote",
        mode: "dark",
        colors: [
            "ground": "#1E1E1E",
            "surface": "#1E1E1E",
            "panel": "#FFFFFF0D",
            "elevated": "#2C2C2E",
            "floating_surface": "#2C2C2E",
            "control_resting": "#FFFFFF12",
            "control_hover": "#FFFFFF20",
            "border": "#FFFFFF1A",
            "divider": "#FFFFFF0D",
            "label": "#FFFFFF",
            "secondary_label": "#FFFFFFB2",
            "tertiary_label": "#FFFFFF73",
            "accent": "#0A84FF",
            "accent_muted": "#0A84FF2E",
            "selection": "#0A84FF4D",
            "status_positive": "#30D158",
            "status_warning": "#FFD60A",
            "status_negative": "#FF453A",
            "diff_added": "#30D158",
            "diff_removed": "#FF453A",
        ],
        material: .init(
            panelRadius: 14,
            controlRadius: 8,
            borderWidth: 1
        )
    )

    static let demoThreadingTheme = RemoteThemeDTO(
        id: "threading",
        name: "Threading",
        mode: "dark",
        colors: [
            "ground": "#040A12",
            "surface": "#071626",
            "panel": "#0A1C2F",
            "elevated": "#102A43",
            "control_resting": "#0E253A",
            "control_hover": "#173B55",
            "border": "#2B4B65",
            "divider": "#183A52",
            "label": "#F7EFE6",
            "secondary_label": "#B9AEA2",
            "tertiary_label": "#827A72",
            "accent": "#FF9A3D",
            "accent_muted": "#FF9A3D21",
            "selection": "#17405C",
            "status_positive": "#74C49A",
            "status_warning": "#E6A35D",
            "status_negative": "#E06E65",
            "diff_added": "#74C49A",
            "diff_removed": "#E06E65",
        ],
        material: .init(
            panelRadius: 10,
            controlRadius: 7,
            borderWidth: 1
        )
    )

    private static func demoCatalogTheme(
        id: String,
        name: String,
        mode: String,
        ground: String,
        surface: String,
        panel: String,
        label: String,
        accent: String,
        radius: Double = 10,
        borderWidth: Double = 1
    ) -> RemoteThemeDTO {
        RemoteThemeDTO(
            id: id,
            name: name,
            mode: mode,
            colors: [
                "ground": ground,
                "surface": surface,
                "panel": panel,
                "elevated": panel,
                "control_resting": label + "12",
                "control_hover": accent + "24",
                "border": label + "2E",
                "divider": label + "1F",
                "label": label,
                "secondary_label": label + "B2",
                "tertiary_label": label + "73",
                "accent": accent,
                "accent_muted": accent + "24",
                "selection": accent + "30",
                "status_positive": mode == "light" ? "#197149" : "#74C49A",
                "status_warning": mode == "light" ? "#9A6700" : "#E6A35D",
                "status_negative": mode == "light" ? "#B42318" : "#E06E65",
                "diff_added": mode == "light" ? "#197149" : "#74C49A",
                "diff_removed": mode == "light" ? "#B42318" : "#E06E65",
            ],
            material: .init(
                panelRadius: radius,
                controlRadius: max(0, radius / 2),
                borderWidth: borderWidth
            )
        )
    }

    static let demoCatalogThemes: [RemoteThemeDTO] = [
        demoTheme,
        demoThreadingTheme,
        demoLightTheme,
        demoCatalogTheme(
            id: "editorial", name: "Editorial", mode: "light",
            ground: "#F2EEE7", surface: "#E8E1D7", panel: "#FBF8F2",
            label: "#2A2520", accent: "#A85632", radius: 5
        ),
        demoCatalogTheme(
            id: "swiss-minimalist", name: "Swiss Minimalist", mode: "light",
            ground: "#FFFFFF", surface: "#F2F2F2", panel: "#FFFFFF",
            label: "#111111", accent: "#FF3000", radius: 0, borderWidth: 2
        ),
        demoCatalogTheme(
            id: "bauhaus", name: "Bauhaus", mode: "light",
            ground: "#F0F0F0", surface: "#FFFFFF", panel: "#FFFFFF",
            label: "#121212", accent: "#D02020", radius: 0, borderWidth: 4
        ),
        demoCatalogTheme(
            id: "art-deco", name: "Art Deco", mode: "dark",
            ground: "#0A0A0F", surface: "#050505", panel: "#141414",
            label: "#F2F0E4", accent: "#D4AF37", radius: 4
        ),
        demoCatalogTheme(
            id: "neo-brutalism", name: "Neo Brutalism", mode: "light",
            ground: "#FFFDF5", surface: "#C4B5FD", panel: "#FFFFFF",
            label: "#000000", accent: "#FF6B6B", radius: 0, borderWidth: 4
        ),
        demoCatalogTheme(
            id: "claymorphism", name: "Claymorphism", mode: "light",
            ground: "#E9E7F7", surface: "#DCD8F0", panel: "#F5F2FF",
            label: "#332B55", accent: "#7C4DFF", radius: 24
        ),
        demoCatalogTheme(
            id: "vaporwave", name: "Vaporwave", mode: "dark",
            ground: "#120A26", surface: "#1B0E35", panel: "#261346",
            label: "#F7E8FF", accent: "#FF4FCB", radius: 12
        ),
    ]

    static let demoTerminalTheme = RemoteTerminalThemeDTO(
        id: "app-cyberpunk-terminal",
        name: "Cyberpunk",
        foreground: "#E6FFF4",
        boldForeground: "#FCEE0A",
        background: "#07070B",
        cursor: "#00FF88",
        selection: "#103D2C",
        ansi: [
            "#14142A", "#FF3366", "#00FF88", "#FFB000",
            "#2E8BFF", "#FF00FF", "#00D4FF", "#B9C6C0",
            "#2E2E5A", "#FF6B93", "#7CFFC4", "#FFD166",
            "#7AB4FF", "#FF7AFF", "#7CE9FF", "#E6FFF4",
        ]
    )

    static let demoThreadingTerminalTheme = RemoteTerminalThemeDTO(
        id: "app-threading-terminal",
        name: "Threading",
        foreground: "#D9D1C8",
        boldForeground: "#FFFFFF",
        background: "#040A12",
        cursor: "#D9D1C8",
        selection: "#173A50",
        ansi: [
            "#071626", "#E06E65", "#74C49A", "#E6A35D",
            "#6EA8D8", "#C486B9", "#7DC9D2", "#D9D1C8",
            "#4F697E", "#F08A81", "#91D6AD", "#F2BC78",
            "#8DBEE3", "#D9A0CC", "#9CDAE0", "#F7EFE6",
        ]
    )

    private static var demoResponse: RemoteMeDTO {
        let now = Date().timeIntervalSince1970
        return RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(
                label: "preview",
                scope: "all",
                capability: "interact",
                canApprovePermissions: true,
                expiresAt: nil
            ),
            sessions: [
                .init(
                    id: "5de80220-2172-4fbe-8ed7-a707572fc922",
                    title: "Review the new remote access feature",
                    agentKind: "codex",
                    surface: .conversation,
                    state: "working",
                    projectName: "AnotherTerminal",
                    isAvailable: true,
                    lastActiveAt: now,
                    isPinned: true,
                    terminalTheme: demoTerminalTheme,
                    inheritedTerminalThemeName: demoTerminalTheme.name,
                    inheritedTerminalTheme: demoTerminalTheme,
                    accountID: "default",
                    limitRecovery: .init(
                        action: RemoteLimitRecoveryPolicyDTO.resumeOnBestAccount
                    )
                ),
                .init(
                    id: "ff9f4a47-4c3b-466b-bcc5-a864b0657423",
                    title: "Finish remote access review",
                    agentKind: "claude",
                    surface: .terminal,
                    state: "idle",
                    projectName: "AnotherTerminal",
                    isAvailable: true,
                    lastActiveAt: now - 380,
                    terminalTheme: demoTerminalTheme,
                    terminalThemeAssignmentID: demoTerminalTheme.id,
                    inheritedTerminalThemeName: demoTerminalTheme.name,
                    inheritedTerminalTheme: demoTerminalTheme,
                    // Both chip forms are represented on purpose: a login with a chosen emoji and
                    // one falling back to its initial on a hashed disc are drawn differently, and
                    // the evidence capture is where that difference is reviewed.
                    account: .init(
                        name: "Vera Lundborg",
                        glyph: "V",
                        isEmoji: false,
                        hue: 0.72
                    )
                ),
                .init(
                    id: "164182ac-7908-4c2d-89a2-fe8f040c4b50",
                    title: "Theme polish",
                    agentKind: "codex",
                    surface: .conversation,
                    state: "dormant",
                    projectName: "AnotherTerminal",
                    isAvailable: false,
                    lastActiveAt: now - 86_400,
                    terminalTheme: demoTerminalTheme
                ),
                .init(
                    id: "f13fc835-763c-4d9f-a54e-099bdd5927d1",
                    title: "Roadmap implementation",
                    agentKind: "claude",
                    surface: .conversation,
                    state: "needsAttention",
                    projectName: "Strom",
                    isAvailable: true,
                    lastActiveAt: now - 220,
                    terminalTheme: demoTerminalTheme
                ),
                .init(
                    id: "359b4bcd-f8ed-43a6-a42e-48f44536be96",
                    title: "Release to TestFlight",
                    agentKind: "codex",
                    surface: .terminal,
                    state: "dormant",
                    projectName: "Strom",
                    isAvailable: false,
                    lastActiveAt: now - 604_800,
                    terminalTheme: demoTerminalTheme,
                    account: .init(
                        name: "Sandbox",
                        glyph: "🧪",
                        isEmoji: true,
                        hue: nil
                    )
                ),
            ],
            terminals: [
                .init(
                    id: "a98a5b1a-cdc3-43ea-9fd3-40bc03f3b1f8",
                    title: "Development server",
                    projectName: "AnotherTerminal",
                    state: "working",
                    isAvailable: true,
                    createdAt: now - 90,
                    terminalTheme: demoTerminalTheme,
                    inheritedTerminalThemeName: demoTerminalTheme.name,
                    inheritedTerminalTheme: demoTerminalTheme
                ),
                .init(
                    id: "60f1a622-d187-4875-b1ca-3705ae53394c",
                    title: "Terminal",
                    projectName: "Strom",
                    state: "dormant",
                    isAvailable: false,
                    createdAt: now - 7_200,
                    terminalTheme: demoTerminalTheme
                ),
            ],
            host: RemoteHostDTO(id: "demo-mac", name: "David’s MacBook Pro"),
            theme: demoTheme,
            themeCatalog: .init(
                // More than one authored theme is part of the picker contract. Keeping the
                // deterministic demo catalog representative prevents the evidence state from
                // silently regressing into a single checked row.
                appThemes: demoCatalogThemes,
                terminalThemes: [demoTerminalTheme]
            ),
            archivedSessions: [],
            newSessionCatalog: .init(
                projects: [
                    .init(
                        id: "project-another-terminal",
                        name: "AnotherTerminal",
                        branch: "main",
                        checkoutLabel: "AnotherTerminal"
                    ),
                    .init(
                        id: "project-strom",
                        name: "Strom",
                        branch: "release",
                        checkoutLabel: "Strom"
                    ),
                ],
                agents: [
                    .init(
                        id: "codex",
                        name: "Codex",
                        accounts: [
                            .init(
                                id: "default",
                                name: "David",
                                emoji: "🧑‍💻",
                                usageSummary: "5h 18% · 7d 63%",
                                usageFraction: 0.63,
                                models: [
                                    .init(
                                        id: "gpt-5.6-sol",
                                        name: "GPT-5.6 Sol",
                                        reasoning: [
                                            .init(id: "medium", name: "Medium"),
                                            .init(id: "high", name: "High"),
                                            .init(id: "xhigh", name: "Extra High"),
                                        ],
                                        defaultReasoningID: "high",
                                        supportsFastMode: true
                                    )
                                ],
                                defaultModelID: "gpt-5.6-sol"
                            ),
                            .init(
                                id: "codex-work",
                                name: "Work",
                                usageSummary: "5h 44% · 7d 28%",
                                usageFraction: 0.44,
                                models: [
                                    .init(
                                        id: "gpt-5.6-sol",
                                        name: "GPT-5.6 Sol",
                                        reasoning: [
                                            .init(id: "medium", name: "Medium"),
                                            .init(id: "high", name: "High"),
                                            .init(id: "xhigh", name: "Extra High"),
                                        ],
                                        defaultReasoningID: "high",
                                        supportsFastMode: true
                                    )
                                ],
                                defaultModelID: "gpt-5.6-sol"
                            ),
                        ],
                        models: [
                            .init(
                                id: "gpt-5.6-sol",
                                name: "GPT-5.6 Sol",
                                reasoning: [
                                    .init(id: "medium", name: "Medium"),
                                    .init(id: "high", name: "High"),
                                    .init(id: "xhigh", name: "Extra High"),
                                ],
                                defaultReasoningID: "high",
                                supportsFastMode: true
                            )
                        ],
                        defaultModelID: "gpt-5.6-sol",
                        supportsConversation: true,
                        permissionModes: [
                            .init(
                                id: "manual",
                                name: "Manual",
                                detail: "Asks before making any change."
                            ),
                            .init(
                                id: "acceptEdits",
                                name: "Accept Edits",
                                detail: "Edits files without asking. Commands still ask."
                            ),
                            .init(
                                id: "auto",
                                name: "Auto (Approve for me)",
                                detail: "A reviewer agent handles requests that cross the sandbox."
                            ),
                        ]
                    ),
                    .init(
                        id: "claude",
                        name: "Claude Code",
                        accounts: [
                            .init(
                                id: "default",
                                name: "David",
                                usageSummary: "5h 31% · 7d 56%",
                                usageFraction: 0.56,
                                models: [],
                                defaultModelID: nil
                            )
                        ],
                        models: [],
                        defaultModelID: nil,
                        supportsConversation: true
                    ),
                ]
            ),
            features: [RemoteRESTFeature.usageDashboard.rawValue]
        )
    }
}

private extension RemoteMeDTO {
    func applying(_ updates: [RemoteSessionsChangedDTO]) -> RemoteMeDTO {
        var updatedSessions = sessions
        let changedIDs = Set(updates.compactMap { $0.removedSessionID ?? $0.session?.id })
        updatedSessions.removeAll { changedIDs.contains($0.id) }
        for session in updates.compactMap(\.session) {
            if !session.isArchived {
                updatedSessions.append(session)
            }
        }
        updatedSessions.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.lastActiveAt ?? 0) > ($1.lastActiveAt ?? 0)
        }
        var updatedTerminals = terminals
        if updatedTerminals != nil {
            let changedTerminalIDs = Set(updates.compactMap {
                $0.removedTerminalID ?? $0.terminal?.id
            })
            updatedTerminals?.removeAll { changedTerminalIDs.contains($0.id) }
            updatedTerminals?.append(contentsOf: updates.compactMap(\.terminal))
            updatedTerminals?.sort { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
        }
        return RemoteMeDTO(
            serverProtocol: serverProtocol,
            share: share,
            sessions: updatedSessions,
            terminals: updatedTerminals,
            host: host,
            theme: theme,
            themeCatalog: themeCatalog,
            archivedSessions: archivedSessions,
            newSessionCatalog: newSessionCatalog,
            features: features
        )
    }

    func replacing(theme: RemoteThemeDTO) -> RemoteMeDTO {
        RemoteMeDTO(
            serverProtocol: serverProtocol,
            share: share,
            sessions: sessions,
            terminals: terminals,
            host: host,
            theme: theme,
            themeCatalog: themeCatalog,
            archivedSessions: archivedSessions,
            newSessionCatalog: newSessionCatalog,
            features: features
        )
    }

    func replacingSessionTheme(
        sessionID: String,
        terminalTheme: RemoteTerminalThemeDTO,
        assignmentID: String?
    ) -> RemoteMeDTO {
        RemoteMeDTO(
            serverProtocol: serverProtocol,
            share: share,
            sessions: sessions.map { session in
                guard session.id == sessionID else { return session }
                return RemoteSessionSummaryDTO(
                    id: session.id,
                    title: session.title,
                    agentKind: session.agentKind,
                    surface: session.surface,
                    state: session.state,
                    projectName: session.projectName,
                    isAvailable: session.isAvailable,
                    lastActiveAt: session.lastActiveAt,
                    isPinned: session.isPinned,
                    isArchived: session.isArchived,
                    snoozedAt: session.snoozedAt,
                    snoozedUntil: session.snoozedUntil,
                    wokeReason: session.wokeReason,
                    wokeAt: session.wokeAt,
                    isShared: session.isShared,
                    terminalTheme: terminalTheme,
                    terminalThemeAssignmentID: assignmentID,
                    inheritedTerminalThemeName: session.inheritedTerminalThemeName,
                    inheritedTerminalTheme: session.inheritedTerminalTheme,
                    account: session.account,
                    accountID: session.accountID,
                    limitRecovery: session.limitRecovery
                )
            },
            terminals: terminals,
            host: host,
            theme: theme,
            themeCatalog: themeCatalog,
            archivedSessions: archivedSessions,
            newSessionCatalog: newSessionCatalog,
            features: features
        )
    }

    func replacingSessionSurface(
        sessionID: String,
        surface: RemoteSessionSurface
    ) -> RemoteMeDTO {
        func replace(_ session: RemoteSessionSummaryDTO) -> RemoteSessionSummaryDTO {
            guard session.id == sessionID else { return session }
            return RemoteSessionSummaryDTO(
                id: session.id,
                title: session.title,
                agentKind: session.agentKind,
                surface: surface,
                state: session.state,
                projectName: session.projectName,
                isAvailable: session.isAvailable,
                lastActiveAt: session.lastActiveAt,
                isPinned: session.isPinned,
                isArchived: session.isArchived,
                snoozedAt: session.snoozedAt,
                snoozedUntil: session.snoozedUntil,
                wokeReason: session.wokeReason,
                wokeAt: session.wokeAt,
                isShared: session.isShared,
                terminalTheme: session.terminalTheme,
                terminalThemeAssignmentID: session.terminalThemeAssignmentID,
                inheritedTerminalThemeName: session.inheritedTerminalThemeName,
                inheritedTerminalTheme: session.inheritedTerminalTheme,
                // Everything this rebuild forgets is a fact the row visibly loses until the next
                // refresh. Switching surface must not blank the chat's account chip.
                account: session.account,
                accountID: session.accountID,
                limitRecovery: session.limitRecovery
            )
        }

        return RemoteMeDTO(
            serverProtocol: serverProtocol,
            share: share,
            sessions: sessions.map(replace),
            terminals: terminals,
            host: host,
            theme: theme,
            themeCatalog: themeCatalog,
            archivedSessions: archivedSessions?.map(replace),
            newSessionCatalog: newSessionCatalog,
            features: features
        )
    }
}
