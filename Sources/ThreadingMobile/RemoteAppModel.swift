import Foundation
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
    @Published private(set) var me: RemoteMeDTO?
    @Published private(set) var phase: Phase = .idle
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
    private let continuity: MobileSessionContinuityStore
    /// True while the app is showing the canned Mac — entered from the welcome screen's Try
    /// the Demo, or by the DEBUG screenshot environment. Every mutation path short-circuits on
    /// it, so demo state changes locally and nothing ever reaches a network (`DemoExperience`).
    @Published private(set) var isDemo = false
    private var themeEventsTask: URLSessionWebSocketTask?
    private var themeEventsReceiveTask: Task<Void, Never>?
    private var themeEventsHostID: String?
    private var themeEventsGeneration = 0
    private var refreshGeneration = 0

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
        invalidateRefreshes()
        let host = DemoExperience.pairedHost
        hosts = [host]
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
        activeHost.map { RemoteClient(link: $0.link) }
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
        let acceptance: RemoteAcceptInvitationResponseDTO
        do {
            acceptance = try await RemoteClient(link: invitationLink)
                .acceptInvitation(displayName: displayName)
        } catch {
            MobileDiagnostics.record(
                .hostPairingFailed,
                level: .error,
                fields: [.code: MobileDiagnostics.errorCode(error)]
            )
            throw error
        }
        guard let link = RemoteConnectionLink(
            baseURL: invitationLink.baseURL,
            token: acceptance.accessToken
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
            activeEndpointKind: PairedRemoteHost.endpointKind(for: link.baseURL)
        )

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

    func selectHost(_ id: String) {
        guard hosts.contains(where: { $0.id == id }), activeHostID != id else { return }
        disconnectThemeEvents()
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
        guard persistHosts() else {
            hosts = previousHosts
            return
        }
        invalidateRefreshes()
        if activeHostID == host.id {
            disconnectThemeEvents()
            activeHostID = hosts.first?.id
            continuity.setActiveHostID(activeHostID)
            me = nil
            phase = activeHostID == nil ? .idle : .connecting
        }
    }

    func refresh() async {
        guard !isDemo else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let host = activeHost else {
            me = nil
            phase = .idle
            return
        }
        let hostID = host.id
        let wasOnline = phase == .online && me != nil
        let wasOffline: Bool
        if case .offline = phase {
            wasOffline = true
        } else {
            wasOffline = false
        }
        if !wasOnline { phase = .connecting }
        do {
            let (response, successfulLink) = try await fetchMe(from: host)
            guard activeHostID == hostID, refreshGeneration == generation else { return }
            me = response
            phase = .online
            restoreRouteIfPossible(hostID: hostID, response: response)
            if !wasOnline {
                MobileDiagnostics.record(.hostRefreshSucceeded, fields: [
                    .peer: MobileDiagnostics.pseudonym(hostID, prefix: "peer"),
                    .transport: PairedRemoteHost.endpointKind(for: successfulLink.baseURL),
                    .protocolVersion: String(response.serverProtocol.version),
                    .minimumProtocolVersion: String(response.serverProtocol.minimumSupported),
                ])
            }
            if let index = hosts.firstIndex(where: { $0.id == hostID }) {
                let old = hosts[index]
                var updated = old
                updated.merge(identity: response.host, successfulLink: successfulLink)
                let metadataChanged = old.name != updated.name
                    || old.link != updated.link
                    || old.endpoints != updated.endpoints
                    || old.connectionPolicy != updated.connectionPolicy
                    || old.activeEndpointKind != updated.activeEndpointKind
                // Polling is every three seconds. Persist only a real connection transition or
                // identity change, rather than rewriting the credential-bearing Keychain item
                // on every healthy poll.
                if !wasOnline || metadataChanged {
                    hosts[index] = updated
                    _ = persistHosts()
                }
                ensureThemeEvents(for: updated)
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeHostID == hostID, refreshGeneration == generation else { return }
            phase = .offline(error.localizedDescription)
            if !wasOffline {
                MobileDiagnostics.record(
                    .hostRefreshFailed,
                    level: .error,
                    fields: [
                        .peer: MobileDiagnostics.pseudonym(hostID, prefix: "peer"),
                        .code: MobileDiagnostics.errorCode(error),
                    ]
                )
            }
        }
    }

    func poll() async {
        guard !isDemo else { return }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
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
        surface: String,
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
            surface: surface,
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

    func setSurface(_ surface: String, for session: RemoteSessionSummaryDTO) async throws {
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

    private func fetchMe(
        from host: PairedRemoteHost
    ) async throws -> (RemoteMeDTO, RemoteConnectionLink) {
        let candidates = host.candidateLinks
        var lastError: Error = RemoteClientError.invalidResponse
        for (index, link) in candidates.enumerated() {
            do {
                let timeout: TimeInterval? = candidates.count > 1 && index < candidates.count - 1
                    ? 4 : nil
                let response = try await RemoteClient(link: link).fetchMe(timeout: timeout)
                return (response, link)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
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
        var lastError: Error = RemoteClientError.invalidResponse
        let candidates = host.candidateLinks
        for (index, link) in candidates.enumerated() {
            do {
                let timeout: TimeInterval? = candidates.count > 1 && index < candidates.count - 1
                    ? 8 : nil
                let response = try await operation(
                    RemoteClient(link: link, requestTimeout: timeout),
                    requestID
                )
                guard activeHostID == hostID else { throw CancellationError() }
                invalidateRefreshes()
                if let index = hosts.firstIndex(where: { $0.id == hostID }),
                   hosts[index].link != link {
                    hosts[index].merge(identity: nil, successfulLink: link)
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
                    continue
                }
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
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

    private func ensureThemeEvents(for host: PairedRemoteHost) {
        guard !isDemo else { return }
        if themeEventsHostID == host.id, themeEventsTask != nil { return }
        disconnectThemeEvents()

        let client = RemoteClient(link: host.link)
        guard let task = try? client.eventsWebSocketTask() else { return }
        themeEventsGeneration &+= 1
        let generation = themeEventsGeneration
        themeEventsHostID = host.id
        themeEventsTask = task
        task.resume()

        let auth = RemoteClientMessage(
            type: "auth",
            token: host.link.token,
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
                switch envelope.type {
                case "appTheme":
                    if let update = try? JSONDecoder().decode(
                        RemoteAppThemeUpdateDTO.self,
                        from: data
                    ) {
                        me = me?.replacing(theme: update.theme)
                    }
                case "sessionsChanged":
                    // The event is intentionally scope-free. Refreshing here makes a surface
                    // switch, rename, pin or archive made on the Mac visible immediately.
                    await refresh()
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
        } catch {
            // The three-second REST refresh remains the reconnect and offline fallback.
        }
        if themeEventsGeneration == generation, themeEventsTask === task {
            themeEventsTask = nil
            themeEventsReceiveTask = nil
            themeEventsHostID = nil
        }
    }

    private func disconnectThemeEvents() {
        themeEventsGeneration &+= 1
        themeEventsReceiveTask?.cancel()
        themeEventsReceiveTask = nil
        themeEventsTask?.cancel(with: .goingAway, reason: nil)
        themeEventsTask = nil
        themeEventsHostID = nil
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

    static let demoTerminalTheme = RemoteTerminalThemeDTO(
        id: "app-cyberpunk-terminal",
        name: "Cyberpunk",
        foreground: "#E6FFF4",
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
                    surface: "conversation",
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
                    surface: "terminal",
                    state: "idle",
                    projectName: "AnotherTerminal",
                    isAvailable: true,
                    lastActiveAt: now - 380,
                    terminalTheme: demoTerminalTheme,
                    terminalThemeAssignmentID: demoTerminalTheme.id,
                    inheritedTerminalThemeName: demoTerminalTheme.name,
                    inheritedTerminalTheme: demoTerminalTheme
                ),
                .init(
                    id: "164182ac-7908-4c2d-89a2-fe8f040c4b50",
                    title: "Theme polish",
                    agentKind: "codex",
                    surface: "conversation",
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
                    surface: "conversation",
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
                    surface: "terminal",
                    state: "dormant",
                    projectName: "Strom",
                    isAvailable: false,
                    lastActiveAt: now - 604_800,
                    terminalTheme: demoTerminalTheme
                ),
            ],
            host: RemoteHostDTO(id: "demo-mac", name: "David’s MacBook Pro"),
            theme: demoTheme,
            themeCatalog: .init(
                appThemes: [demoTheme],
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
                                        defaultReasoningID: "high"
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
                                        defaultReasoningID: "high"
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
                                defaultReasoningID: "high"
                            )
                        ],
                        defaultModelID: "gpt-5.6-sol",
                        supportsConversation: true
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

    func replacingSessionSurface(sessionID: String, surface: String) -> RemoteMeDTO {
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
                inheritedTerminalTheme: session.inheritedTerminalTheme
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
