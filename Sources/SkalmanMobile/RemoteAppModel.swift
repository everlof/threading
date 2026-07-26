import Foundation
import SkalmanRemoteKit

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
    @Published var isPairing = false
    @Published var navigationPath: [String] = []

    private let store = RemoteHostStore()
    private let isDemo: Bool
    private var themeEventsTask: URLSessionWebSocketTask?
    private var themeEventsReceiveTask: Task<Void, Never>?
    private var themeEventsHostID: String?
    private var themeEventsGeneration = 0

    init() {
#if DEBUG
        if ProcessInfo.processInfo.environment["SKALMAN_MOBILE_DEMO"] != nil,
           let link = RemoteConnectionLink(string: "https://demo.invalid/#preview") {
            isDemo = true
            let host = PairedRemoteHost(
                id: "demo-mac",
                hostID: "demo-mac",
                shareID: "my-devices",
                scope: "all",
                name: "David’s MacBook Pro",
                link: link,
                lastConnectedAt: Date()
            )
            hosts = [host]
            activeHostID = host.id
            me = Self.demoResponse
            phase = .online
            return
        }
#endif
        isDemo = false
        let loaded = store.load()
        hosts = loaded
        activeHostID = loaded.first?.id
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
            name: identity?.name ?? link.baseURL.host ?? "Skalman Mac",
            link: link,
            lastConnectedAt: Date()
        )

        if let index = hosts.firstIndex(where: { $0.id == id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        store.save(hosts)
        activeHostID = id
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
        activeHostID = id
        // Never show one Mac's session identifiers while requests are already routed to another.
        me = nil
        phase = .connecting
    }

    func remove(_ host: PairedRemoteHost) {
        MobileDiagnostics.record(.hostRemoved, fields: [
            .peer: MobileDiagnostics.pseudonym(host.id, prefix: "peer")
        ])
        hosts.removeAll { $0.id == host.id }
        store.save(hosts)
        if activeHostID == host.id {
            disconnectThemeEvents()
            activeHostID = hosts.first?.id
            me = nil
            phase = activeHostID == nil ? .idle : .connecting
        }
    }

    func refresh() async {
        guard !isDemo else { return }
        guard let host = activeHost else {
            me = nil
            phase = .idle
            return
        }
        let hostID = host.id
        let client = RemoteClient(link: host.link)
        let wasOnline = phase == .online && me != nil
        let wasOffline: Bool
        if case .offline = phase {
            wasOffline = true
        } else {
            wasOffline = false
        }
        if !wasOnline { phase = .connecting }
        do {
            let response = try await client.fetchMe()
            guard activeHostID == hostID else { return }
            me = response
            phase = .online
            if !wasOnline {
                MobileDiagnostics.record(.hostRefreshSucceeded, fields: [
                    .peer: MobileDiagnostics.pseudonym(hostID, prefix: "peer"),
                    .protocolVersion: String(response.serverProtocol.version),
                    .minimumProtocolVersion: String(response.serverProtocol.minimumSupported),
                ])
            }
            ensureThemeEvents(for: host)
            if let index = hosts.firstIndex(where: { $0.id == hostID }) {
                let resolvedName = response.host?.name
                let nameChanged = resolvedName.map { $0 != hosts[index].name } ?? false
                // Polling is every three seconds. Persist only a real connection transition or
                // identity change, rather than rewriting the credential-bearing Keychain item
                // on every healthy poll.
                guard !wasOnline || nameChanged else { return }
                hosts[index].lastConnectedAt = Date()
                if let resolvedName { hosts[index].name = resolvedName }
                store.save(hosts)
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeHostID == hostID else { return }
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
        let hostID = host.id
        let client = RemoteClient(link: host.link)
        try await client.resume(sessionID: session.id)
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
#if DEBUG
        if isDemo { return }
#endif
        do {
            let response = try await RemoteClient(link: host.link).setAppTheme(themeID: themeID)
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
#if DEBUG
        if isDemo { return }
#endif
        do {
            let response = try await RemoteClient(link: host.link).setSessionTheme(
                sessionID: sessionID,
                themeID: themeID
            )
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
#if DEBUG
        if isDemo {
            return me?.sessions.first ?? Self.demoResponse.sessions[0]
        }
#endif
        let response = try await RemoteClient(link: host.link).createSession(request)
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
#if DEBUG
        if isDemo { return }
#endif
        let response = try await RemoteClient(link: host.link).renameSession(
            sessionID: session.id,
            title: title
        )
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func setPinned(_ pinned: Bool, for session: RemoteSessionSummaryDTO) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
#if DEBUG
        if isDemo { return }
#endif
        let response = try await RemoteClient(link: host.link).setSessionPinned(
            sessionID: session.id,
            isPinned: pinned
        )
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func setArchived(_ archived: Bool, for session: RemoteSessionSummaryDTO) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
#if DEBUG
        if isDemo { return }
#endif
        let response = try await RemoteClient(link: host.link).setSessionArchived(
            sessionID: session.id,
            isArchived: archived
        )
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func setSurface(_ surface: String, for session: RemoteSessionSummaryDTO) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
#if DEBUG
        if isDemo {
            me = me?.replacingSessionSurface(sessionID: session.id, surface: surface)
            return
        }
#endif
        let response = try await RemoteClient(link: host.link).setSessionSurface(
            sessionID: session.id,
            surface: surface
        )
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
        let response = try await RemoteClient(link: host.link).createShare(
            sessionID: session.id,
            capability: capability,
            canApprovePermissions: canApprovePermissions
        )
        guard activeHostID == hostID else { throw CancellationError() }
        me = response.me
        return response
    }

    func revokeShares(for session: RemoteSessionSummaryDTO) async throws {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        let response = try await RemoteClient(link: host.link).revokeShares(
            sessionID: session.id
        )
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
    }

    func openSessionFromNotification(hostID: String, sessionID: String) {
        let candidate = hosts.first {
            ($0.hostID ?? $0.id) == hostID && $0.isOwnerDevice
        } ?? hosts.first { ($0.hostID ?? $0.id) == hostID }
        guard let candidate else { return }

        selectHost(candidate.id)
        Task {
            await refresh()
            guard activeHostID == candidate.id,
                  me?.sessions.contains(where: { $0.id == sessionID }) == true else { return }
            if navigationPath.last != sessionID {
                navigationPath.append(sessionID)
            }
        }
    }

    // MARK: - Live app-theme events

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

#if DEBUG
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
            )
        )
    }
#endif
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
            newSessionCatalog: newSessionCatalog
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
            newSessionCatalog: newSessionCatalog
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
            newSessionCatalog: newSessionCatalog
        )
    }
}
