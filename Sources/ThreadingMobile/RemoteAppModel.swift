import Foundation
import ThreadingPeerTransport
import ThreadingRemoteKit

struct RemoteNotificationOpenRequest: Equatable, Identifiable {
    let eventID: String
    let sessionID: String
    let destination: RemoteNotificationDestinationDTO

    var id: String { eventID }
}

@MainActor
final class RemoteAppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case online
        case offline(String)
    }

    @Published private(set) var hosts: [PairedRemoteHost]
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
        }
    }
    @Published private(set) var activeHostID: String?
    @Published private(set) var storageIssue: String? = nil
    @Published private(set) var notificationOpenRequest: RemoteNotificationOpenRequest?
    @Published var isPairing = false
    @Published var navigationPath: [String] = [] {
        didSet {
            guard let activeHostID else { return }
            if let sessionID = navigationPath.last {
                continuity.setLastRoute(hostID: activeHostID, sessionID: sessionID)
            } else {
                continuity.clearLastRoute()
            }
        }
    }

    private let store = RemoteHostStore()
    private let hostedConnections = HostedRemoteConnectionManager()
    private let continuity: MobileSessionContinuityStore
    /// True while the app is showing the canned Mac — entered from the welcome screen's Try
    /// the Demo, or by the DEBUG screenshot environment. Every mutation path short-circuits on
    /// it, so demo state changes locally and nothing ever reaches a network (`DemoExperience`).
    @Published private(set) var isDemo = false
    private var themeEventsTask: URLSessionWebSocketTask?
    private var themeEventsReceiveTask: Task<Void, Never>?
    private var themeEventsHostID: String?
    private var themeEventsGeneration = 0
    private var themeEventsRecoveryTask: Task<Void, Never>?
    private var themeEventsRecoveryAttempt = 0
    private var sessionsChangedRefreshTask: Task<Void, Never>?
    private var sessionsChangedRefreshGeneration = 0
    private var pendingSessionDeltas: [String: RemoteSessionsChangedDTO] = [:]
    private var sessionDeltaApplicationTask: Task<Void, Never>?
    private var sessionDeltaApplicationGeneration = 0
    private var catalogueRevision = 0
    private var catalogueRefreshInFlightGeneration: Int?
    private var refreshGeneration = 0
    private var activeHostedLink: RemoteConnectionLink?
    private var activeHostedHostID: String?
    /// Provisioning is a low-frequency control-plane operation. A service outage must not turn
    /// event-socket recovery into a credential-issuance retry loop.
    private var hostedProvisioningRetryAfter: [String: Date] = [:]
    private static let hostedCredentialRenewalLeadTime: TimeInterval = 24 * 60 * 60
    private static let hostedProvisioningRetryDelay: TimeInterval = 5 * 60
    private static let sessionsChangedCoalescingDelay = Duration.milliseconds(350)
    private static let sessionDeltaCoalescingDelay = Duration.milliseconds(50)
    private static let maximumThemeEventsRecoveryDelay: TimeInterval = 60

    init(continuity: MobileSessionContinuityStore = MobileSessionContinuityStore()) {
        self.continuity = continuity
#if DEBUG
        if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] != nil,
           let link = RemoteConnectionLink(
            string: "https://david-mac.tailnet-demo.ts.net:8443/#preview"
           ) {
            isDemo = true
            let host = PairedRemoteHost(
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
                        kind: "relay",
                        baseURL: URL(string: "https://threading-demo.example.com/")!,
                        isStable: true
                    ),
                ],
                connectionPolicy: .preferPrivate,
                activeEndpointKind: "tailscale"
            )
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
            me = Self.demoResponse
            phase = .online
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

    func pair(_ invitationLink: RemoteConnectionLink, displayName: String) async throws {
        phase = .connecting
        MobileDiagnostics.record(.hostPairingStarted)
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
            var fields: [RemoteDiagnosticField: String] = [
                .code: MobileDiagnostics.errorCode(error),
            ]
            if let verdict { fields[.detail] = RemoteHostTrust.token(for: verdict) }
            MobileDiagnostics.record(.hostPairingFailed, level: .error, fields: fields)
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
            do {
                let issued = try await RemoteClient(link: link).issueHostedDeviceCredential()
                (hostedServiceURL, hostedCredential) = try Self.validateHostedCredential(
                    issued,
                    expectedHostID: hostID
                )
            } catch {
                // Pairing and the existing relay/Tailscale routes remain valid. The Mac will
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
            phase = .offline(error.localizedDescription)
            throw error
        }
        invalidateRefreshes()
        activeHostID = id
        continuity.setActiveHostID(id)
        self.me = me
        phase = .online
        isPairing = false
        ensureThemeEvents(for: host)
        MobileDiagnostics.record(.hostPairingSucceeded, fields: [
            .peer: MobileDiagnostics.pseudonym(id, prefix: "peer"),
            .capability: me.share.capability,
        ])
    }

    func pair(_ hostedLink: HostedPairingLink, displayName: String) async throws {
        guard !hostedLink.isExpired else { throw PeerControlPlaneError.invalidCredential }
        phase = .connecting
        MobileDiagnostics.record(.hostPairingStarted, fields: [.transport: "hosted"])
        let endpoint = try PeerControlPlaneServiceEndpoint(hostedLink.serviceURL)
        let credential = try PeerRendezvousCredential(hostedLink.rendezvousCredential)
        let tunnel: PeerHostedDeviceTunnel
        do {
            tunnel = try await PeerHostedDeviceConnector.connect(
                endpoint: endpoint.rendezvousEndpoint,
                hostID: hostedLink.hostID,
                deviceID: hostedLink.deviceID,
                credential: credential
            )
        } catch {
            MobileDiagnostics.record(
                .hostPairingFailed,
                level: .error,
                fields: [.code: MobileDiagnostics.errorCode(error), .transport: "hosted"]
            )
            throw error
        }
        defer { tunnel.stop() }
        guard let loopbackLink = RemoteConnectionLink(
            baseURL: tunnel.origin,
            token: hostedLink.bootstrapToken
        ) else {
            throw RemoteClientError.invalidResponse
        }
        try await pair(loopbackLink, displayName: displayName)
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
        discardPendingSessionDeltas()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let host = activeHost else {
            discardHostedConnection()
            me = nil
            phase = .idle
            return
        }
        let hostID = host.id
        catalogueRefreshInFlightGeneration = generation
        defer {
            if catalogueRefreshInFlightGeneration == generation {
                catalogueRefreshInFlightGeneration = nil
                startSessionDeltaApplicationIfNeeded(for: hostID)
            }
        }
        let wasOnline = phase == .online && me != nil
        let wasOffline: Bool
        if case .offline = phase {
            wasOffline = true
        } else {
            wasOffline = false
        }
        if !wasOnline { phase = .connecting }
        do {
            let connection = try await fetchMe(from: host)
            let response = connection.response
            let successfulLink = connection.link
            guard activeHostID == hostID, refreshGeneration == generation else { return }
            me = response
            phase = .online
            restoreRouteIfPossible(hostID: hostID, response: response)
            if !wasOnline {
                MobileDiagnostics.record(.hostRefreshSucceeded, fields: [
                    .peer: MobileDiagnostics.pseudonym(hostID, prefix: "peer"),
                    .transport: connection.isHosted
                        ? "hosted"
                        : PairedRemoteHost.endpointKind(for: successfulLink.baseURL),
                    .protocolVersion: String(response.serverProtocol.version),
                    .minimumProtocolVersion: String(response.serverProtocol.minimumSupported),
                ])
            }
            if let index = hosts.firstIndex(where: { $0.id == hostID }) {
                let old = hosts[index]
                var updated = old
                updated.merge(
                    identity: response.host,
                    successfulLink: successfulLink,
                    isHosted: connection.isHosted
                )
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
            await reconcileHostedCredential(
                hostID: hostID,
                response: response,
                successfulLink: successfulLink,
                generation: generation
            )
        } catch is CancellationError {
            return
        } catch {
            guard activeHostID == hostID, refreshGeneration == generation else { return }
            let failure = connectionFailure(for: host, error: error)
            phase = .offline(failure.message)
            scheduleThemeEventsRecovery(for: hostID)
            if !wasOffline {
                var fields: [RemoteDiagnosticField: String] = [
                    .peer: MobileDiagnostics.pseudonym(hostID, prefix: "peer"),
                    .code: MobileDiagnostics.errorCode(RemoteConnectionAttempt.underlying(error)),
                    .reason: failure.cause.rawValue,
                ]
                // A token, never a fingerprint: a report says whether the identity check passed,
                // refused or never ran, which is the difference between "the Mac is off" and
                // "something else is answering at the Mac's address".
                if let verdict = RemoteHostTrust.verdictToken(for: host) {
                    fields[.detail] = verdict
                }
                MobileDiagnostics.record(.hostRefreshFailed, level: .error, fields: fields)
            }
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

    /// Changes the one app appearance shared by the Mac and paired clients. The local preview
    /// is applied before the relay round trip, then replaced by the Mac's resolved response.
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
            if navigationPath.last != event.sessionID {
                navigationPath.append(event.sessionID)
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
        navigationPath = [route.sessionID]
    }

    // MARK: - Live app-theme events

    private struct ConnectionCandidate {
        let link: RemoteConnectionLink
        let isHosted: Bool
        /// Which advertised door this attempt belongs to, so the rest of a port walk can be
        /// abandoned once that door has answered. Nil for the hosted route, which is one
        /// rendezvous rather than an address with ports on it.
        let doorID: String?
    }

    private struct SuccessfulConnection {
        let response: RemoteMeDTO
        let link: RemoteConnectionLink
        let isHosted: Bool
    }

    private func fetchMe(from host: PairedRemoteHost) async throws -> SuccessfulConnection {
        let prepared = await connectionCandidates(for: host)
        var lastError: Error = prepared.error ?? RemoteClientError.invalidResponse
        // A door that has answered is done, whatever it answered. The remaining attempts on it
        // are the sticky port range, and knocking on nine more ports after the Mac has refused a
        // bearer, named a protocol version, or presented the wrong certificate finds nothing.
        var answeredDoors: Set<String> = []
        for (index, candidate) in prepared.candidates.enumerated() {
            if let doorID = candidate.doorID, answeredDoors.contains(doorID) { continue }
            do {
                let timeout: TimeInterval? = prepared.candidates.count > 1
                    && index < prepared.candidates.count - 1
                    ? 4 : nil
                let response = try await RemoteClient(link: candidate.link).fetchMe(timeout: timeout)
                return SuccessfulConnection(
                    response: response,
                    link: candidate.link,
                    isHosted: candidate.isHosted
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = RemoteConnectionAttempt(
                    underlying: error,
                    host: candidate.link.baseURL.host
                )
                if let doorID = candidate.doorID,
                   Self.doorHasAnswered(error, host: candidate.link.baseURL.host) {
                    answeredDoors.insert(doorID)
                }
                if candidate.isHosted { await hostedConnectionFailed(hostID: host.id) }
            }
        }
        throw lastError
    }

    /// Whether a failure means something was there, rather than nothing being there.
    ///
    /// An HTTP status and a refused certificate both came from a server; a refused or timed-out
    /// connection did not. Only the second is a reason to try the next port of the range.
    private static func doorHasAnswered(_ error: Error, host: String?) -> Bool {
        if error is RemoteClientError { return true }
        guard let host else { return false }
        return RemoteClient.pinningDelegate.verdict(forHost: host) == .rejectedFingerprintMismatch
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
        let prepared = await connectionCandidates(for: host)
        var lastError: Error = prepared.error ?? RemoteClientError.invalidResponse
        var answeredDoors: Set<String> = []
        for (index, candidate) in prepared.candidates.enumerated() {
            if let doorID = candidate.doorID, answeredDoors.contains(doorID) { continue }
            do {
                let timeout: TimeInterval? = prepared.candidates.count > 1
                    && index < prepared.candidates.count - 1
                    ? 8 : nil
                let response = try await operation(
                    RemoteClient(link: candidate.link, requestTimeout: timeout),
                    requestID
                )
                guard activeHostID == hostID else { throw CancellationError() }
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
                throw CancellationError()
            } catch let error as RemoteClientError {
                // HTTP answers are authoritative. Failover is for transport loss, not for
                // bypassing an authorization or compatibility decision made by the Mac. A
                // gateway failure can belong to the route in front of it, and the same request
                // id keeps trying the next route safe even if the Mac did receive it.
                if case .server(let status) = error, [502, 503, 504].contains(status) {
                    lastError = error
                    if let doorID = candidate.doorID { answeredDoors.insert(doorID) }
                    if candidate.isHosted { await hostedConnectionFailed(hostID: host.id) }
                    continue
                }
                if candidate.isHosted { await hostedConnectionFailed(hostID: host.id) }
                throw error
            } catch {
                lastError = error
                if let doorID = candidate.doorID,
                   Self.doorHasAnswered(error, host: candidate.link.baseURL.host) {
                    answeredDoors.insert(doorID)
                }
                if candidate.isHosted { await hostedConnectionFailed(hostID: host.id) }
            }
        }
        throw lastError
    }

    private func connectionCandidates(
        for host: PairedRemoteHost
    ) async -> (candidates: [ConnectionCandidate], error: Error?) {
        var candidates: [ConnectionCandidate] = []
        var preparationError: Error?
        do {
            if let hostedLink = try await hostedConnections.link(for: host) {
                candidates.append(
                    ConnectionCandidate(link: hostedLink, isHosted: true, doorID: nil)
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
        for candidate in host.candidates
        where !candidates.contains(where: { $0.link == candidate.link }) {
            candidates.append(ConnectionCandidate(
                link: candidate.link,
                isHosted: false,
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
        generation: Int
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
        do {
            let issued = try await RemoteClient(link: successfulLink).issueHostedDeviceCredential()
            let (serviceURL, credential) = try Self.validateHostedCredential(
                issued,
                expectedHostID: hosts[index].hostID ?? hostID
            )
            guard activeHostID == hostID, refreshGeneration == generation,
                  let currentIndex = hosts.firstIndex(where: { $0.id == hostID }) else { return }
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
        } catch is CancellationError {
            return
        } catch {
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
        refreshGeneration &+= 1
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
        guard let task = try? client.eventsWebSocketTask() else {
            scheduleThemeEventsRecovery(for: host.id)
            return
        }
        themeEventsRecoveryTask?.cancel()
        themeEventsRecoveryTask = nil
        themeEventsGeneration &+= 1
        let generation = themeEventsGeneration
        themeEventsHostID = host.id
        themeEventsTask = task
        task.resume()

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
                themeEventsRecoveryAttempt = 0
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
                    if me != nil, update.session != nil || update.removedSessionID != nil {
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
                default:
                    continue
                }
            }
        } catch is CancellationError {
            return
        } catch {}
        if themeEventsGeneration == generation, themeEventsTask === task {
            themeEventsTask = nil
            themeEventsReceiveTask = nil
            themeEventsHostID = nil
            scheduleThemeEventsRecovery(for: hostID)
        }
    }

    private func disconnectThemeEvents() {
        clearThemeEventSocket()
        themeEventsRecoveryTask?.cancel()
        themeEventsRecoveryTask = nil
        themeEventsRecoveryAttempt = 0
        sessionsChangedRefreshGeneration &+= 1
        sessionsChangedRefreshTask?.cancel()
        sessionsChangedRefreshTask = nil
        discardPendingSessionDeltas()
    }

    private func clearThemeEventSocket() {
        themeEventsGeneration &+= 1
        themeEventsReceiveTask?.cancel()
        themeEventsReceiveTask = nil
        themeEventsTask?.cancel(with: .goingAway, reason: nil)
        themeEventsTask = nil
        themeEventsHostID = nil
    }

    private func scheduleThemeEventsRecovery(for hostID: String) {
        guard !isDemo, activeHostID == hostID, themeEventsTask == nil,
              themeEventsRecoveryTask == nil else { return }
        let exponent = min(themeEventsRecoveryAttempt, 6)
        let delay = min(
            pow(2, Double(exponent)),
            Self.maximumThemeEventsRecoveryDelay
        )
        themeEventsRecoveryAttempt &+= 1
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
              let key = update.removedSessionID ?? update.session?.id else { return }
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
                guard let key = update.removedSessionID ?? update.session?.id,
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
                    inheritedTerminalTheme: demoTerminalTheme
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
                                name: "Auto",
                                detail: "Decides for itself when to ask."
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
        return RemoteMeDTO(
            serverProtocol: serverProtocol,
            share: share,
            sessions: updatedSessions,
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
                    terminalTheme: terminalTheme,
                    terminalThemeAssignmentID: assignmentID,
                    inheritedTerminalThemeName: session.inheritedTerminalThemeName,
                    inheritedTerminalTheme: session.inheritedTerminalTheme
                )
            },
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
                terminalTheme: session.terminalTheme,
                terminalThemeAssignmentID: session.terminalThemeAssignmentID,
                inheritedTerminalThemeName: session.inheritedTerminalThemeName,
                inheritedTerminalTheme: session.inheritedTerminalTheme,
                // Everything this rebuild forgets is a fact the row visibly loses until the next
                // refresh. Switching surface must not blank the chat's account chip.
                account: session.account
            )
        }

        return RemoteMeDTO(
            serverProtocol: serverProtocol,
            share: share,
            sessions: sessions.map(replace),
            host: host,
            theme: theme,
            themeCatalog: themeCatalog,
            archivedSessions: archivedSessions?.map(replace),
            newSessionCatalog: newSessionCatalog,
            features: features
        )
    }
}
