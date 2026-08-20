import AppKit
import CryptoKit
import Foundation
import ThreadingRemoteKit

/// Bridges a live session to its remote subscribers: taps the PTY byte stream, keeps a ring for
/// late joiners, fans output out to every watcher, and routes remote input back in.
///
/// `@MainActor` because its application capabilities and `ProjectStore` are main-only.
/// Connections live on the server queue and their `send*` methods hop there
/// themselves, so this class never blocks on the network.
///
/// Agent sessions and durable standalone project terminals are mirrored as distinct identities.
/// Shell drawers and display-pane terminals are not in either runtime query and stay local;
/// native conversations use typed snapshots.
@MainActor
final class RemoteSessionMirrorRegistry {

    static let shared = RemoteSessionMirrorRegistry()
    private let appEvents = AppEventObservations()
    private var appearanceObservation: NSKeyValueObservation?
    private var terminalApplication: (any RemoteTerminalApplicationCapability)?

    init(terminalApplication: (any RemoteTerminalApplicationCapability)? = nil) {
        self.terminalApplication = terminalApplication
        // A remote surface is a view of this app, so theme changes are live state rather than a
        // reconnect-only preference. Broadcast broadly and resolve per session: assignments can
        // change one terminal, while profile and app-theme changes can affect many.
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in
            self?.broadcastThemes()
        }
        appEvents.observe(ThemeAssignmentsDidChange.self) { [weak self] _ in
            self?.broadcastThemes()
        }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.broadcastThemes()
        }
        // Archiving is an authorization change, not only a sidebar filter. A live runtime may
        // intentionally survive it, so revoke any attached socket as soon as the store changes.
        appEvents.observe(ProjectsDidChange.self) { [weak self] change in
            self?.closeUnavailableSessions()
            self?.broadcastSessionsChanged(change)
        }
        // Activity is live row state, not a project mutation. Depending on a coincident title or
        // branch write left a completed chat's phone badge stale indefinitely.
        appEvents.observe(SessionActivityDidChange.self) { [weak self] event in
            self?.broadcastSessionRow(event.sessionID)
        }
        // The System theme can change without an AppTheme event when macOS itself crosses
        // light/dark mode. Its resolved AppKit colours and reported mode must move remotely too.
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) {
            [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.broadcastThemes()
            }
        }
    }

    /// Completes the live graph at the application composition root before the listener starts.
    /// Tests inject a fake at initialization; neither path permits route-time singleton lookup.
    func installTerminalApplication(
        _ terminalApplication: any RemoteTerminalApplicationCapability
    ) {
        precondition(self.terminalApplication == nil, "Remote terminal capability installs once")
        precondition(mirrors.isEmpty, "Remote terminal capability must be installed before use")
        self.terminalApplication = terminalApplication
    }

    // MARK: - State

    private struct Mirror {
        var ring: RemoteRingBuffer
        let surface: RemoteSessionSurface
        var subscribers: [ObjectIdentifier: RemoteConnection] = [:]
        /// Complete provider-neutral state and its live wire revision. The complete rows stay
        /// on the Mac; clients receive only a recent window plus requested older pages.
        var conversationSnapshot: RemoteConversationSnapshotDTO? = nil
        var conversationRowsRevision: RemoteConversationRowsRevision? = nil
        var conversationRevision = 0
        /// Devices that have already sent input, so the "first remote input" audit line is
        /// written once per device+session rather than per keystroke.
        var inputSeenDevices: Set<String> = []
        /// Interactive clients that currently have a terminal view on screen. They share one
        /// PTY, so the grid applied is the largest one all of them can display — see
        /// `applyViewport`.
        var viewportRequests: [ObjectIdentifier: ViewportRequest] = [:]
    }

    private struct ViewportRequest {
        let cols: Int
        let rows: Int
    }

    private struct ProjectTerminalMirror {
        var ring: RemoteRingBuffer
        var subscribers: [ObjectIdentifier: RemoteConnection] = [:]
        var inputSeenDevices: Set<String> = []
        var viewportRequests: [ObjectIdentifier: ViewportRequest] = [:]
    }

    private var mirrors: [SessionID: Mirror] = [:]
    private var terminalMirrors: [TerminalID: ProjectTerminalMirror] = [:]
    private var terminalByConnection: [ObjectIdentifier: TerminalID] = [:]
    /// Which subscribers are composing right now, per session. Presence is a relayed message
    /// between clients; this is the Mac keeping the part of it its own sharing pane shows.
    private var typingConnections: [SessionID: Set<ObjectIdentifier>] = [:]
    /// Random socket-scoped ids keep two tabs owned by the same member distinct. They are never
    /// credentials and disappear with the live connection.
    private var presenceIDs: [ObjectIdentifier: String] = [:]
    private var promptReplayCache = RemotePromptReplayCache()
    private var attentionRequestPolicy = RemoteAttentionRequestPolicy()
    private var inputControls: [SessionID: RemoteInputControlRecord] = [:]
    private var focusedControllerReleaseTasks: [SessionID: DispatchWorkItem] = [:]
    private var sessionByConnection: [ObjectIdentifier: SessionID] = [:]
    private var themeEventSubscribers: [ObjectIdentifier: RemoteConnection] = [:]
    private var pendingConversationBroadcasts: [SessionID: DispatchWorkItem] = [:]
    private var latestWorkspaceActivity: [SessionID: RemoteWorkspaceChangedDTO] = [:]

    // MARK: - REST

    /// The `/api/me` payload: the share, and the live sessions it reaches.
    func meResponse(for authorization: RemoteAuthorization) -> RemoteMeDTO {
        let sessions = ProjectStore.shared.projects
            .flatMap { project in
                project.sessions
                    .filter {
                        RemoteSessionAccess.isVisible($0)
                            && authorization.scope.covers($0.id)
                    }
                    .map {
                        summary(
                            for: $0,
                            projectName: project.name,
                            projectLimitRecovery: project.limitRecoveryPolicy,
                            authorization: authorization
                        )
                    }
            }
            .sorted(by: summaryOrder)

        let terminals = ProjectStore.shared.projects
            .flatMap(\.terminals)
            .filter { authorization.scope.covers($0.id) }
            .map { terminal in
                let project = ProjectStore.shared.displayProject(forTerminalID: terminal.id)
                    ?? ProjectStore.shared.homeProject(forTerminalID: terminal.id)
                return terminalSummary(for: terminal, projectName: project?.name ?? "")
            }
            .sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }

        let scopeName: String
        switch authorization.scope {
        case .allSessions: scopeName = "all"
        case .session: scopeName = "session"
        case .projectTerminal: scopeName = "terminal"
        }

        let ownsSessionLifecycle = canManageSessions(authorization)
        let archived = ownsSessionLifecycle
            ? ProjectStore.shared.archivedSessions()
                .map {
                    summary(
                        for: $0.session,
                        projectName: $0.project.name,
                        projectLimitRecovery: $0.project.limitRecoveryPolicy,
                        authorization: authorization
                    )
                }
                .sorted(by: summaryOrder)
            : nil

        return RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(
                label: authorization.shareID,
                scope: scopeName,
                capability: authorization.capability.rawValue,
                canApprovePermissions: authorization.canApprovePermissions,
                expiresAt: authorization.expiresAt?.timeIntervalSince1970,
                memberID: authorization.member?.id,
                displayName: authorization.member?.displayName
            ),
            sessions: sessions,
            terminals: terminals,
            host: RemoteAccessCoordinator.shared.hostIdentity(for: authorization),
            theme: RemoteThemeBridge.appTheme(),
            themeCatalog: canManageThemes(authorization)
                ? RemoteThemeBridge.catalog()
                : nil,
            archivedSessions: archived,
            newSessionCatalog: ownsSessionLifecycle ? newSessionCatalog() : nil,
            features: restFeatures(for: authorization)
        )
    }

    private func terminalSummary(
        for terminal: ProjectTerminal,
        projectName: String
    ) -> RemoteProjectTerminalSummaryDTO {
        let running = ProjectTerminalRuntime.shared.isRunning(terminalID: terminal.id)
        let busy = running && ProjectTerminalRuntime.shared.isBusy(terminalID: terminal.id)
        return RemoteProjectTerminalSummaryDTO(
            id: terminal.id.uuidString,
            title: ProjectTerminalTitle.displayTitle(for: terminal),
            projectName: projectName,
            state: running ? (busy ? "working" : "idle") : "dormant",
            isAvailable: running,
            createdAt: terminal.createdAt.timeIntervalSince1970,
            isShared: RemoteAccessCoordinator.shared.hasTerminalShares(terminal.id),
            terminalTheme: RemoteThemeBridge.terminalTheme(for: terminal.id),
            terminalThemeAssignmentID: ThemeAssignments.themeID(forTerminal: terminal.id)?.rawValue,
            inheritedTerminalThemeName: ThemeAssignments.inheritedName(forTerminal: terminal.id),
            inheritedTerminalTheme: RemoteThemeBridge.terminalTheme(
                ThemeAssignments.inheritedTheme(forTerminal: terminal.id)
            )
        )
    }

    private func restFeatures(for authorization: RemoteAuthorization) -> [String]? {
        var features: [String] = []
        if authorization.canReadHostUsage {
            features.append(RemoteRESTFeature.usageDashboard.rawValue)
        }
        if authorization.canManageHost,
           RemoteAccessCoordinator.shared.canIssueHostedDeviceCredentials {
            features.append(RemoteRESTFeature.hostedPeerTransport.rawValue)
        }
        return features.isEmpty ? nil : features
    }

    private func summary(
        for session: AgentSession,
        projectName: String,
        projectLimitRecovery: LimitRecoveryPolicy?,
        authorization: RemoteAuthorization
    ) -> RemoteSessionSummaryDTO {
        let available = AgentRuntime.shared.isRunning(sessionID: session.id)
        let ownsSessionLifecycle = canManageSessions(authorization)
        let resolvedLimitRecovery = LimitRecoveryResolution.resolve(
            session: session.limitRecoveryPolicy,
            project: projectLimitRecovery,
            app: LimitRecoverySettings.policy
        ).policy
        return RemoteSessionSummaryDTO(
            id: session.id.uuidString,
            title: session.displayTitle,
            agentKind: session.kind.rawValue,
            surface: session.usesNativeUI ? .conversation : .terminal,
            state: String(describing: AgentRuntime.shared.activity(
                sessionID: session.id,
                participantID: authorization.collaborationParticipantID
            )),
            projectName: projectName,
            isAvailable: available,
            lastActiveAt: session.lastActiveAt.timeIntervalSince1970,
            isPinned: session.isPinned,
            isArchived: session.isArchived,
            snoozedAt: session.snoozedAt?.timeIntervalSince1970,
            snoozedUntil: session.snoozedUntil?.timeIntervalSince1970,
            wokeReason: session.wake?.reason.rawValue,
            wokeAt: session.wake?.wokeAt.timeIntervalSince1970,
            isShared: RemoteAccessCoordinator.shared.hasSessionShares(session.id),
            terminalTheme: RemoteThemeBridge.terminalTheme(for: session.id),
            terminalThemeAssignmentID: ThemeAssignments
                .themeID(forSession: session.id)?
                .rawValue,
            inheritedTerminalThemeName: ThemeAssignments.inheritedName(forSession: session.id),
            inheritedTerminalTheme: RemoteThemeBridge.terminalTheme(
                ThemeAssignments.inheritedTheme(forSession: session.id)
            ),
            account: RemoteAccountBridge.identity(for: session),
            accountID: ownsSessionLifecycle && session.kind.supportsAccounts
                ? session.accountHandle.name
                : nil,
            limitRecovery: ownsSessionLifecycle
                ? remoteLimitRecovery(resolvedLimitRecovery)
                : nil
        )
    }

    private func remoteLimitRecovery(
        _ policy: LimitRecoveryPolicy
    ) -> RemoteLimitRecoveryPolicyDTO {
        switch policy {
        case .flagOnly:
            return .init(action: RemoteLimitRecoveryPolicyDTO.flagOnly)
        case .waitForReset:
            return .init(action: RemoteLimitRecoveryPolicyDTO.waitForReset)
        case .resumeOnBestAccount:
            return .init(action: RemoteLimitRecoveryPolicyDTO.resumeOnBestAccount)
        case .resumeVia(let accountID):
            return .init(
                action: RemoteLimitRecoveryPolicyDTO.resumeVia,
                accountID: accountID.handle.name
            )
        }
    }

    private func summaryOrder(
        _ lhs: RemoteSessionSummaryDTO,
        _ rhs: RemoteSessionSummaryDTO
    ) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return (lhs.lastActiveAt ?? 0) > (rhs.lastActiveAt ?? 0)
    }

    private func newSessionCatalog() -> RemoteNewSessionCatalogDTO {
        let projects = ProjectStore.shared.projects.map { project in
            RemoteProjectChoiceDTO(
                id: project.id.uuidString,
                name: project.name,
                branch: GitInfo.currentBranch(for: project.folderPath),
                checkoutLabel: project.folderURL.lastPathComponent,
                reportLaunch: reportLaunch(for: project)
            )
        }

        let agents = AgentKind.allCases.map { kind in
            let discoveredAccounts = AgentAccountDiscovery.accounts(for: kind)
            let accountNames = AccountName.names(for: discoveredAccounts)

            func models(for account: AgentAccount?) -> [RemoteModelChoiceDTO] {
                AgentModels.options(for: kind, account: account).map { option in
                    RemoteModelChoiceDTO(
                        id: option.identifier,
                        name: option.displayName,
                        reasoning: option.reasoningLevels.map {
                            RemoteReasoningChoiceDTO(id: $0.effort, name: $0.displayName)
                        },
                        defaultReasoningID: option.defaultReasoningLevel,
                        supportsFastMode: AgentModels.supportsFastMode(
                            kind: kind,
                            model: option.identifier,
                            account: account
                        )
                    )
                }
            }

            let accounts: [RemoteAccountChoiceDTO]
            if discoveredAccounts.isEmpty {
                accounts = [
                    RemoteAccountChoiceDTO(
                        id: AccountHandle.standardName,
                        name: AgentAccountDefaults.defaultDisplayName,
                        models: models(for: nil),
                        defaultModelID: AgentModels.defaultModel(for: kind, account: nil)
                    )
                ]
            } else {
                accounts = discoveredAccounts.map { account in
                    AccountUsageService.shared.refresh(account)
                    let reading = AccountUsageService.shared.reading(for: account)
                    let usage = reading.usage
                    // Read against the model this account would run, as the desktop's own
                    // account menu is: a plan metering that model separately can be nearly
                    // spent while the account's weekly window still looks comfortable.
                    let model = AgentModels.defaultModel(for: kind, account: account)
                    return RemoteAccountChoiceDTO(
                        id: account.handle.name,
                        name: accountNames[account.id] ?? account.displayName,
                        emoji: account.emoji,
                        usageSummary: usage?.compactSummary(metering: model),
                        usageFraction: usage?.bindingWindow(metering: model)?.fraction,
                        usageError: reading.error?.message,
                        models: models(for: account),
                        defaultModelID: AgentModels.defaultModel(for: kind, account: account)
                    )
                }
            }

            let defaultAccount = discoveredAccounts.first(where: \.isDefault)
                ?? discoveredAccounts.first
            return RemoteAgentChoiceDTO(
                id: kind.rawValue,
                name: kind.displayName,
                accounts: accounts,
                models: models(for: defaultAccount),
                defaultModelID: AgentModels.defaultModel(for: kind, account: defaultAccount),
                supportsConversation: kind.supportsNativeUI,
                permissionModes: kind.supportsPermissionModes
                    ? AgentPermissionMode.allCases.map { mode in
                        RemotePermissionModeChoiceDTO(
                            id: mode.rawValue,
                            name: mode.displayName(for: kind),
                            detail: [mode.menuDescription(for: kind), mode.caveat(for: kind)]
                                .compactMap { $0 }
                                .joined(separator: " ")
                        )
                    }
                    : []
            )
        }

        return RemoteNewSessionCatalogDTO(projects: projects, agents: agents)
    }

    /// What a report sent from a paired phone would come up as in one project.
    ///
    /// Two answers the Mac owns and the phone used to guess: the launch choices, inherited from
    /// the chat most recently used here, and the workspace, from the owner's Remote Access
    /// setting once this checkout and that agent have been checked against it.
    ///
    /// Every inherited value is measured against what this Mac would accept before it is
    /// published, because `handleCreateSession` refuses an account, model, level or speed that
    /// no longer exists — and a refusal here costs somebody their bug report. A login that has
    /// been signed out, or a model the account stopped offering, is therefore dropped rather
    /// than forwarded, which lands the chat on that agent's own defaults.
    private func reportLaunch(for project: Project) -> RemoteReportLaunchDTO {
        let inherited = InheritedLaunchConfiguration.resolve(
            sessions: project.sessions,
            defaultKind: AppSettings.shared.defaultAgentKind
        )
        let kind = inherited.kind

        // The standard handle needs no proof: the server resolves it to whichever login is
        // default at the time. A named one must still exist.
        let discoveredAccounts = AgentAccountDiscovery.accounts(for: kind)
        let account: AgentAccount? = inherited.accountHandle.isStandard
            ? discoveredAccounts.first(where: \.isDefault)
            : discoveredAccounts.first { $0.handle == inherited.accountHandle }
        let accountID: String? = {
            guard kind.supportsAccounts else { return nil }
            if inherited.accountHandle.isStandard { return AccountHandle.standardName }
            return account == nil ? nil : inherited.accountHandle.name
        }()

        let modelOptions = AgentModels.options(for: kind, account: account)
        let model = inherited.model.flatMap { identifier in
            modelOptions.contains { $0.identifier == identifier } ? identifier : nil
        }
        let reasoningEffort = model.flatMap { identifier in
            inherited.reasoningEffort.flatMap { effort in
                modelOptions.first { $0.identifier == identifier }?
                    .supports(reasoningEffort: effort) == true ? effort : nil
            }
        }
        let fastMode = inherited.fastMode.flatMap { requested in
            AgentModels.supportsFastMode(kind: kind, model: model, account: account)
                ? requested
                : nil
        }

        let workspace = AppSettings.shared.phoneReportWorkspace.resolvedPlan(
            canProvisionWorkspace: ManagedGitWorkspace.canProvision(from: project),
            supportsFinishHandshake: ManagedWorkspaceEligibility.supportsFinishHandshake(
                kind: kind,
                usesNativeUI: inherited.usesNativeUI
            )
        )

        return RemoteReportLaunchDTO(
            agentID: kind.rawValue,
            accountID: accountID,
            model: model,
            reasoningEffort: reasoningEffort,
            fastMode: fastMode,
            permissionMode: inherited.permissionMode?.rawValue,
            surface: inherited.usesNativeUI ? .conversation : .terminal,
            managedWorkspace: workspace.map {
                RemoteManagedWorkspacePlanDTO(
                    delivery: $0.delivery.rawValue,
                    publication: $0.publication?.rawValue
                )
            }
        )
    }

    // MARK: - Subscription

    /// Attaches a connection to a session's terminal mirror, sending it `hello` and the ring
    /// snapshot. Returns false if the session has no live terminal or conversation surface.
    func attach(
        _ connection: RemoteConnection,
        to sessionID: SessionID,
        authorization: RemoteAuthorization
    ) -> Bool {
        guard RemoteSessionAccess.isVisible(
            ProjectStore.shared.session(withID: sessionID)
        ) else {
            return false
        }
        var attached = attachTerminal(
            connection,
            sessionID: sessionID,
            capability: authorization.capability
        )
        if !attached,
           let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID),
                  conversation.isRunning {
            attached = attachConversation(
                connection,
                to: conversation,
                sessionID: sessionID,
                authorization: authorization
            )
        }
        guard attached else { return false }
        AgentRuntime.shared.acknowledgeAttention(
            sessionID: sessionID,
            participantID: authorization.collaborationParticipantID
        )
        // Attaching the live surface is a visit, regardless of which window or paired device
        // supplied it. All clients therefore acknowledge the same durable wake receipt.
        SessionSnoozeCenter.shared.acknowledge(sessionID)
        let key = ObjectIdentifier(connection)
        presenceIDs[key] = UUID().uuidString
        announcePresence(of: connection, sessionID: sessionID)
        broadcastCollaborationParticipants(sessionID)
        // Only the person whose last socket left resumes their grace period. A different
        // watcher arriving during those 30 seconds must not leave an offline controller holding
        // the session forever.
        if RemoteInputControlPolicy.isFocusedController(
            inputControlRecord(for: sessionID),
            participantID: authorization.collaborationParticipantID
        ) {
            focusedControllerReleaseTasks[sessionID]?.cancel()
            focusedControllerReleaseTasks[sessionID] = nil
        }
        broadcastInputControl(sessionID)
        if authorization.member != nil {
            RemoteAccessCoordinator.shared.noteMemberSeen(shareID: authorization.shareID)
        }
        followersChanged(sessionID)
        return true
    }

    /// Attaches a connection to a standalone project terminal. Shells deliberately do not join
    /// chat collaboration state: every interactive terminal capability may write, while a view
    /// capability can only receive the bounded output stream.
    func attach(
        _ connection: RemoteConnection,
        to terminalID: TerminalID,
        authorization: RemoteAuthorization
    ) -> Bool {
        guard authorization.scope.covers(terminalID),
              ProjectStore.shared.terminal(withID: terminalID) != nil,
              let snapshot = beginCapturing(terminalID: terminalID) else { return false }

        let key = ObjectIdentifier(connection)
        terminalMirrors[terminalID]?.subscribers[key] = connection
        terminalByConnection[key] = terminalID
        connection.sendText(encode(RemoteHelloDTO(
            surface: .terminal,
            capability: authorization.capability.rawValue,
            cols: snapshot.grid.cols,
            rows: snapshot.grid.rows,
            title: snapshot.title,
            theme: RemoteThemeBridge.appTheme(),
            terminalTheme: RemoteThemeBridge.terminalTheme(for: terminalID),
            // Standalone shells implement the baseline byte stream and viewport protocol only.
            // Chat collaboration, atomic line submission, attention and attachment features all
            // route through `SessionID` and must not be advertised on this target.
            features: []
        )))

        let ringSnapshot = terminalMirrors[terminalID]?.ring.snapshot() ?? Data()
        let budget = connection.authenticatedPeer?.terminalReplayBudget
        let replay = Self.terminalReplay(ring: ringSnapshot, budget: budget)
        switch replay {
        case .nothing: break
        case .whole(let ring): connection.sendBinary(ring)
        case .cut(let tail): connection.sendBinary(tail)
        }

        guard case .cut = replay, let budget else {
            connection.sendBinary(RemoteTerminalModeSeed.bytes(for: snapshot.modes))
            return true
        }
        EventLog.shared.record(.remote, "Remote replay bounded", [
            "terminal": terminalID.uuidString,
            "ring": String(ringSnapshot.count),
            "budget": String(budget),
        ])
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var modes = snapshot.modes
            if case .captured(let fresh) = self.terminalApplication?.currentSnapshot(
                for: terminalID
            ) {
                connection.sendBinary(fresh.screenSeed)
                modes = fresh.modes
            }
            connection.sendBinary(RemoteTerminalModeSeed.bytes(for: modes))
        }
        return true
    }

    /// Subscribes a dashboard to app-chrome changes without binding it to a particular session.
    /// The first frame is authoritative too, closing the race between `/api/me` and socket auth.
    func attachThemeEvents(_ connection: RemoteConnection) {
        themeEventSubscribers[ObjectIdentifier(connection)] = connection
        connection.sendText(encode(RemoteAppThemeUpdateDTO(
            theme: RemoteThemeBridge.appTheme()
        )))
    }

    /// Sends a bounded notification event only to event sockets whose capability satisfies the
    /// caller. This is a live complement to APNs, not an authorization shortcut: the socket was
    /// already authenticated and its resolved principal/scope is checked again here.
    @discardableResult
    func broadcastNotification(
        _ event: RemoteNotificationEventDTO,
        matching predicate: (RemoteAuthorization, String?) -> Bool
    ) -> Int {
        let message = encode(event)
        var count = 0
        for connection in themeEventSubscribers.values {
            guard let peer = connection.authenticatedPeer,
                  predicate(peer.authorization, peer.deviceID) else { continue }
            connection.sendText(message)
            count += 1
        }
        return count
    }

    /// The features this connection is told about, which is not always every feature there is.
    ///
    /// Composer uploads are the first one that has to be filtered. Handing bytes over is an
    /// owner-scope write into the Mac's own attachment custody, and a client that renders an
    /// attach button from an advertised feature it would then be refused for has been told a
    /// lie by the host. A view-only or guest connection simply never sees it, so its composer
    /// draws nothing to press.
    static func advertisedFeatures(for authorization: RemoteAuthorization?) -> [String] {
        RemoteWebSocketFeature.allCases.filter { feature in
            switch feature {
            case .composerAttachmentUploads:
                return authorization?.principal == .ownerDevice
                    && authorization?.scope == .allSessions
                    && authorization?.capability == .interact
            default:
                return true
            }
        }.map(\.rawValue)
    }

    /// CAN, which returns a client's escape-sequence parser to ground.
    private static let cancelPendingSequence: UInt8 = 0x18

    /// What a joining client's replay is made of: nothing, the ring whole, or a cut tail.
    ///
    /// A cut carries only the tail. What has to follow it — a freshly synthesized repaint — is
    /// the caller's business rather than this decision's, because the caller is the only thing
    /// that knows *when* it may be read; see `attachTerminal`.
    enum TerminalReplay: Equatable {
        /// The ring is empty, so there is no history to replay at all.
        case nothing
        /// The ring in full, byte for byte.
        case whole(Data)
        /// The ring's newest bytes within budget, behind CAN. A fresh repaint owes to follow.
        case cut(tail: Data)
    }

    /// How much of the ring a joining client is owed, given the budget it stated.
    ///
    /// Without a budget the client gets the ring whole, which is the only correct answer when it
    /// has not said what it can hold. With one, it gets the ring's newest `budget` bytes behind
    /// CAN, and a freshly synthesized repaint follows. Both halves of that are load-bearing:
    ///
    /// - CAN comes first for the reason the mode seed also begins with one. A byte window over a
    ///   raw PTY stream can end inside an escape sequence, and cutting the head off the ring
    ///   means it can now *begin* inside one too; without CAN the client's parser eats the first
    ///   bytes of real output as the tail of a sequence it never saw the start of.
    /// - The fresh repaint is what keeps the visible screen exact. The ring was seeded at capture
    ///   with a repaint of the screen as it stood then, and that seed sits at the head — the
    ///   part a budget cuts away. Replaying a tail alone reproduces only the output since some
    ///   arbitrary byte offset, so the screen has to be restated as it is now.
    ///
    /// The tail is not inert history. It is raw output, and every side effect it has on the
    /// client's emulator persists except where the two seeds that follow restate it — the
    /// repaint restates buffer, charset, attributes, contents and cursor; the mode seed restates
    /// the sticky modes. What the tail is *for* is scrollback; what makes the visible screen
    /// right is the repaint.
    static func terminalReplay(ring: Data, budget: Int?) -> TerminalReplay {
        guard !ring.isEmpty else { return .nothing }
        guard let budget, budget > 0, ring.count > budget else { return .whole(ring) }
        return .cut(tail: Data([Self.cancelPendingSequence]) + ring.suffix(budget))
    }

    private func attachTerminal(
        _ connection: RemoteConnection,
        sessionID: SessionID,
        capability: RemoteCapability
    ) -> Bool {
        guard let snapshot = beginCapturing(sessionID: sessionID) else { return false }

        let key = ObjectIdentifier(connection)
        mirrors[sessionID]?.subscribers[key] = connection
        sessionByConnection[key] = sessionID

        let hello = RemoteHelloDTO(
            surface: .terminal,
            capability: capability.rawValue,
            cols: snapshot.grid.cols,
            rows: snapshot.grid.rows,
            title: snapshot.title,
            theme: RemoteThemeBridge.appTheme(),
            terminalTheme: RemoteThemeBridge.terminalTheme(for: sessionID),
            features: Self.advertisedFeatures(for: connection.authorization)
        )
        connection.sendText(encode(hello))
        sendLatestWorkspaceActivity(to: connection, sessionID: sessionID)

        let ringSnapshot = mirrors[sessionID]?.ring.snapshot() ?? Data()
        let budget = connection.authenticatedPeer?.terminalReplayBudget
        let replay = Self.terminalReplay(ring: ringSnapshot, budget: budget)
        switch replay {
        case .nothing:
            break
        case .whole(let ring):
            connection.sendBinary(ring)
        case .cut(let tail):
            connection.sendBinary(tail)
        }

        guard case .cut = replay, let budget else {
            // After the ring rather than before it. The ring is replayed history: it can arm
            // mouse tracking the program has since dropped, and — far more often — it holds no
            // arming sequence at all, because a TUI sends that once at startup and 512 KB of
            // output rolled it away. The statement is what is true now, so it has to be the
            // last word.
            connection.sendBinary(RemoteTerminalModeSeed.bytes(for: snapshot.modes))
            return true
        }

        EventLog.shared.record(.remote, "Remote replay bounded", [
            "session": sessionID.uuidString,
            "ring": String(ringSnapshot.count),
            "budget": String(budget),
        ])
        // The ring lags the emulator by one main-queue hop: the capture sink hands its bytes to
        // `broadcast` through `DispatchQueue.main.async`, so output SwiftTerm has already applied
        // to the emulator can still be queued and unbroadcast at the moment a client attaches.
        // The tail therefore has to go now, ahead of those bytes, and the repaint has to go
        // after them. That asymmetry is exactly-once reasoning: a repaint is idempotent against
        // output the client has already applied, so restating a screen that already includes
        // those bytes is harmless — but the bytes themselves are incremental, and applying them
        // twice is not. A line-oriented TUI answers a second application with duplicated rows.
        // One continuation carries both seeds, so the modes remain the last word.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var modes = snapshot.modes
            if case .captured(let fresh) =
                self.terminalApplication?.currentSnapshot(for: sessionID) {
                connection.sendBinary(fresh.screenSeed)
                modes = fresh.modes
            }
            // Stated even when the terminal has gone in the meantime: a client that attached to
            // a live session must not be left wearing whatever modes the tail happened to arm.
            connection.sendBinary(RemoteTerminalModeSeed.bytes(for: modes))
        }
        return true
    }

    private func attachConversation(
        _ connection: RemoteConnection,
        to conversation: any RemoteConversationSurface,
        sessionID: SessionID,
        authorization: RemoteAuthorization
    ) -> Bool {
        if mirrors[sessionID] == nil {
            mirrors[sessionID] = Mirror(
                // Conversation mirrors carry typed snapshots, not PTY history. The shared
                // mirror shape still owns a ring, kept at its smallest valid capacity.
                ring: RemoteRingBuffer(capacity: 1),
                surface: .conversation
            )
        }

        let projection = conversation.remoteProjection
        let current = projection.snapshot
        let rowsChanged = mirrors[sessionID]?.conversationRowsRevision != projection.rowsRevision
        let metadataChanged = mirrors[sessionID]?.conversationSnapshot.map {
            !Self.sameConversationMetadata($0, current)
        } ?? true
        if rowsChanged || metadataChanged {
            if mirrors[sessionID]?.subscribers.isEmpty == false {
                // Bring every already-attached viewer forward before the newcomer is inserted.
                // Mutating the shared baseline for only the newcomer would otherwise make a
                // pending broadcast look like a no-op and strand existing phones one revision
                // behind until some later event happened to expose the gap.
                broadcastConversation(sessionID)
            } else if var mirror = mirrors[sessionID] {
                mirror.conversationSnapshot = current
                mirror.conversationRowsRevision = projection.rowsRevision
                mirror.conversationRevision &+= 1
                mirrors[sessionID] = mirror
            }
        }

        let key = ObjectIdentifier(connection)
        mirrors[sessionID]?.subscribers[key] = connection
        sessionByConnection[key] = sessionID
        connection.sendText(encode(RemoteHelloDTO(
            surface: .conversation,
            capability: authorization.capability.rawValue,
            cols: 0,
            rows: 0,
            title: ProjectStore.shared.session(withID: sessionID)?.displayTitle ?? "",
            theme: RemoteThemeBridge.appTheme(),
            terminalTheme: RemoteThemeBridge.terminalTheme(for: sessionID),
            features: Self.advertisedFeatures(for: authorization)
        )))
        sendLatestWorkspaceActivity(to: connection, sessionID: sessionID)
        let revision = mirrors[sessionID]?.conversationRevision ?? 0
        connection.sendText(encode(RemoteConversationWirePolicy.authorized(
            RemoteConversationWirePolicy.initial(current, revision: revision),
            for: authorization,
            canWrite: canWrite(sessionID: sessionID, authorization: authorization)
        )))
        return true
    }

    /// Sends an older prepend-only page to one authenticated subscriber.
    func requestConversationPage(
        from connection: RemoteConnection,
        sessionID: SessionID,
        beforeRowID: String?,
        limit: Int?
    ) {
        guard mirrors[sessionID]?.surface == .conversation,
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID) else {
            return
        }
        connection.sendText(encode(RemoteConversationWirePolicy.page(
            conversation.remoteSnapshot,
            beforeRowID: beforeRowID,
            requestedLimit: limit
        )))
    }

    /// Recovery for a client that missed or reordered a live delta.
    func resyncConversation(
        for connection: RemoteConnection,
        sessionID: SessionID
    ) {
        guard let peer = connection.authenticatedPeer,
              mirrors[sessionID]?.surface == .conversation,
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID) else {
            return
        }
        let projection = conversation.remoteProjection
        let current = projection.snapshot
        if mirrors[sessionID]?.conversationRowsRevision != projection.rowsRevision
            || mirrors[sessionID]?.conversationSnapshot.map({
                !Self.sameConversationMetadata($0, current)
            }) ?? true {
            broadcastConversation(sessionID)
        }
        let revision = mirrors[sessionID]?.conversationRevision ?? 0
        connection.sendText(encode(RemoteConversationWirePolicy.authorized(
            RemoteConversationWirePolicy.initial(current, revision: revision),
            for: peer.authorization,
            canWrite: canWrite(sessionID: sessionID, authorization: peer.authorization)
        )))
    }

    func detach(_ connection: RemoteConnection) {
        let key = ObjectIdentifier(connection)
        themeEventSubscribers.removeValue(forKey: key)
        if let terminalID = terminalByConnection.removeValue(forKey: key) {
            releaseViewport(for: connection, terminalID: terminalID)
            terminalMirrors[terminalID]?.subscribers.removeValue(forKey: key)
            if terminalMirrors[terminalID]?.subscribers.isEmpty == true,
               !AppSettings.shared.remoteAccessEnabled {
                removeTap(terminalID: terminalID)
                terminalMirrors[terminalID] = nil
            }
            return
        }
        guard let sessionID = sessionByConnection.removeValue(forKey: key) else { return }
        let departingParticipantID = connection.authenticatedPeer?.authorization
            .collaborationParticipantID
        broadcastPresence("left", from: connection, sessionID: sessionID)
        releaseViewport(for: connection, sessionID: sessionID)
        mirrors[sessionID]?.subscribers.removeValue(forKey: key)
        presenceIDs[key] = nil
        if mirrors[sessionID]?.subscribers.isEmpty ?? true {
            // While Remote Access is enabled the ring keeps following a live terminal even with
            // no viewer. Otherwise reconnecting later would show only bytes produced after the
            // new socket attached — often an apparently blank TUI.
            let keepsTerminalCapture =
                mirrors[sessionID]?.surface == .terminal
                && AppSettings.shared.remoteAccessEnabled
            if !keepsTerminalCapture {
                if mirrors[sessionID]?.surface == .terminal {
                    removeTap(sessionID: sessionID)
                }
                mirrors[sessionID] = nil
            }
        }
        typingConnections[sessionID]?.remove(key)
        if typingConnections[sessionID]?.isEmpty ?? false {
            typingConnections[sessionID] = nil
        }
        broadcastCollaborationParticipants(sessionID)
        if let departingParticipantID {
            scheduleFocusedControlReleaseIfNeeded(
                sessionID: sessionID,
                participantID: departingParticipantID
            )
        }
        broadcastInputControl(sessionID)
        followersChanged(sessionID)
    }

    /// Stable people currently viewing one live surface. Multiple sockets and owner devices
    /// collapse here; their socket-scoped presence ids remain separate everywhere else.
    func viewingParticipantIDs(for sessionID: SessionID) -> Set<String> {
        Set(mirrors[sessionID]?.subscribers.values.compactMap {
            $0.authenticatedPeer?.authorization.collaborationParticipantID
        } ?? [])
    }

    /// Begins keeping the bounded terminal history as soon as a live surface exists, not only
    /// when the first phone connects. Existing screen contents seed the ring when access is
    /// enabled after a session has already been running.
    @discardableResult
    func beginCapturing(sessionID: SessionID) -> RemoteTerminalState? {
        guard let terminalApplication else { return nil }
        if mirrors[sessionID] != nil {
            guard case .available(let state) = terminalApplication.state(for: sessionID) else {
                return nil
            }
            return state
        }

        let result = terminalApplication.beginCapture(for: sessionID) { [weak self] data in
            // Preserve the old capture handoff: the SwiftTerm output callback is synchronous
            // and must return before ring maintenance or subscriber fan-out begins.
            DispatchQueue.main.async { [weak self] in
                self?.broadcast(data, sessionID: sessionID)
            }
        }
        guard case .captured(let snapshot) = result else { return nil }
        var ring = RemoteRingBuffer(capacity: RemoteAccessDefaults.ringBufferBytes)
        // A synthesised repaint, not `getBufferAsData()`: that is plain text joined by bare line
        // feeds with blank cells as NUL, which a client renders as a staircase of run-together
        // words. See `RemoteScreenSeed`.
        ring.append(snapshot.screenSeed)
        mirrors[sessionID] = Mirror(ring: ring, surface: .terminal)
        return snapshot.state
    }

    @discardableResult
    func beginCapturing(terminalID: TerminalID) -> RemoteTerminalState? {
        guard let terminalApplication else { return nil }
        if terminalMirrors[terminalID] != nil {
            guard case .available(let state) = terminalApplication.state(for: terminalID) else {
                return nil
            }
            return state
        }
        let result = terminalApplication.beginCapture(for: terminalID) { [weak self] data in
            DispatchQueue.main.async { [weak self] in
                self?.broadcast(data, terminalID: terminalID)
            }
        }
        guard case .captured(let snapshot) = result else { return nil }
        var ring = RemoteRingBuffer(capacity: RemoteAccessDefaults.ringBufferBytes)
        ring.append(snapshot.screenSeed)
        terminalMirrors[terminalID] = ProjectTerminalMirror(ring: ring)
        return snapshot.state
    }

    func isTerminalAvailable(_ terminalID: TerminalID) -> Bool {
        guard let terminalApplication,
              case .available = terminalApplication.state(for: terminalID) else { return false }
        return true
    }

    /// Called once the listener is ready, covering terminals that predate the setting change.
    func remoteAccessStarted() {
        guard let terminalApplication else { return }
        for sessionID in terminalApplication.sessionIDs {
            guard RemoteSessionAccess.isVisible(
                ProjectStore.shared.session(withID: sessionID)
            ) else {
                continue
            }
            beginCapturing(sessionID: sessionID)
        }
        for terminalID in terminalApplication.terminalIDs
        where ProjectStore.shared.terminal(withID: terminalID) != nil {
            beginCapturing(terminalID: terminalID)
        }
    }

    /// Releases idle capture as well as subscribers when the master switch is turned off.
    func remoteAccessStopped() {
        for sessionID in mirrors.keys where mirrors[sessionID]?.surface == .terminal {
            _ = terminalApplication?.setViewport(nil, for: sessionID)
            removeTap(sessionID: sessionID)
        }
        for terminalID in terminalMirrors.keys {
            _ = terminalApplication?.setViewport(nil, for: terminalID)
            removeTap(terminalID: terminalID)
        }
        for work in pendingConversationBroadcasts.values { work.cancel() }
        pendingConversationBroadcasts.removeAll()
        mirrors.removeAll()
        terminalMirrors.removeAll()
        terminalByConnection.removeAll()
        typingConnections.removeAll()
        presenceIDs.removeAll()
        promptReplayCache.removeAll()
        attentionRequestPolicy.removeAll()
        for task in focusedControllerReleaseTasks.values { task.cancel() }
        focusedControllerReleaseTasks.removeAll()
        inputControls.removeAll()
        sessionByConnection.removeAll()
        themeEventSubscribers.removeAll()
    }

    // MARK: - Input

    @discardableResult
    func sendInput(
        _ bytes: [UInt8],
        to sessionID: SessionID,
        device: String?,
        authorization: RemoteAuthorization
    ) -> Bool {
        guard canWrite(sessionID: sessionID, authorization: authorization) else { return false }
        guard RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID)),
              let terminalApplication,
              case .available = terminalApplication.state(for: sessionID) else {
            return false
        }

        // Preserve the existing audit ordering: authorization and runtime admission happen
        // first, the accepted interaction is recorded, and only then do bytes reach the PTY.
        recordFirstInput(device: device, sessionID: sessionID)
        RemoteNotificationService.shared.recordInteraction(
            sessionID: sessionID,
            authorization: authorization
        )
        return terminalApplication.sendInput(bytes, to: sessionID) == .applied
    }

    @discardableResult
    func sendInput(
        _ bytes: [UInt8],
        to terminalID: TerminalID,
        device: String?,
        authorization: RemoteAuthorization
    ) -> Bool {
        guard authorization.capability == .interact,
              authorization.scope.covers(terminalID),
              ProjectStore.shared.terminal(withID: terminalID) != nil,
              let terminalApplication,
              case .available = terminalApplication.state(for: terminalID) else { return false }
        if let device,
           terminalMirrors[terminalID]?.inputSeenDevices.contains(device) == false {
            terminalMirrors[terminalID]?.inputSeenDevices.insert(device)
            EventLog.shared.record(.remote, "First remote terminal input", [
                "terminal": terminalID.uuidString,
                "device": device,
            ])
        }
        return terminalApplication.sendInput(bytes, to: terminalID) == .applied
    }

    /// Records the visible grid of an interactive phone. This is a lease, not a preference:
    /// closing that view removes its request and restores the next controller or the Mac.
    func requestViewport(
        from connection: RemoteConnection,
        sessionID: SessionID,
        cols: Int,
        rows: Int
    ) {
        guard let authorization = connection.authenticatedPeer?.authorization,
              canWrite(sessionID: sessionID, authorization: authorization),
              (20...240).contains(cols),
              (4...160).contains(rows),
              mirrors[sessionID]?.surface == .terminal,
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              let terminalApplication,
              case .available = terminalApplication.state(for: sessionID) else {
            return
        }

        mirrors[sessionID]?.viewportRequests[ObjectIdentifier(connection)] = ViewportRequest(
            cols: cols,
            rows: rows
        )
        applyViewport(for: sessionID)
    }

    func releaseViewport(from connection: RemoteConnection, sessionID: SessionID) {
        releaseViewport(for: connection, sessionID: sessionID)
    }

    func requestViewport(
        from connection: RemoteConnection,
        terminalID: TerminalID,
        cols: Int,
        rows: Int
    ) {
        guard connection.authenticatedPeer?.authorization.capability == .interact,
              RemoteViewportRefusal.columns.contains(cols),
              RemoteViewportRefusal.rows.contains(rows),
              terminalMirrors[terminalID]?.subscribers[ObjectIdentifier(connection)] != nil,
              let terminalApplication,
              case .available = terminalApplication.state(for: terminalID) else { return }
        terminalMirrors[terminalID]?.viewportRequests[ObjectIdentifier(connection)] = .init(
            cols: cols,
            rows: rows
        )
        applyViewport(for: terminalID)
    }

    func releaseViewport(from connection: RemoteConnection, terminalID: TerminalID) {
        releaseViewport(for: connection, terminalID: terminalID)
    }

    /// - Parameter attachmentPaths: staged uploads the server already claimed for this exact
    ///   session and device. They are paths into the host's own staging directory, never
    ///   anything a client named: the claim happened before this call and cannot be repeated.
    func submitPrompt(
        _ text: String,
        contextAttachments remoteContext: [RemoteConversationContextAttachmentDTO]? = nil,
        attachmentPaths: [String] = [],
        to sessionID: SessionID,
        device: String?,
        authorization: RemoteAuthorization,
        requestID: String?
    ) -> RemotePromptSubmissionStatus {
        let context = (remoteContext ?? []).compactMap(ConversationContextAttachment.init(remoteDTO:))
        let normalizedContext = ConversationContextPolicy.normalized(context)
        guard context.count == (remoteContext?.count ?? 0),
              normalizedContext == context else { return .rejected }

        let replayKey = requestID.map {
            RemotePromptReplayCache.Key(
                sessionID: sessionID.uuidString,
                principalID: [
                    authorization.principal == .ownerDevice ? "owner" : "guest",
                    authorization.member?.id ?? authorization.shareID,
                    device ?? "legacy",
                ].joined(separator: ":"),
                requestID: $0
            )
        }
        var fingerprintSource = Data(("conversation\0" + text + "\0").utf8)
        // Staged uploads are part of what makes this submission itself. Without them a retry
        // carrying different pictures would match the first attempt's fingerprint and replay
        // its status instead of being seen as the conflict it is.
        if !attachmentPaths.isEmpty {
            fingerprintSource.append(Data((attachmentPaths.joined(separator: "\0") + "\0").utf8))
        }
        if let remoteContext {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let encodedContext = try? encoder.encode(remoteContext) {
                fingerprintSource.append(encodedContext)
            }
        }
        let fingerprint = Data(SHA256.hash(data: fingerprintSource))
        if let replayKey {
            switch promptReplayCache.decision(for: replayKey, fingerprint: fingerprint) {
            case .new:
                break
            case .replay(let status):
                return status
            case .conflict:
                return .conflict
            }
        }

        let status: RemotePromptSubmissionStatus
        if !canWrite(sessionID: sessionID, authorization: authorization) {
            status = .rejected
        } else if !RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID)) {
            status = .unavailable
        } else if let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID),
                  conversation.isRunning {
            if !conversation.remoteSnapshot.canSend {
                status = .busy
            } else if let prompt = promptText(
                text,
                stagedAttachmentPaths: attachmentPaths,
                for: sessionID
            ), conversation.sendRemotePrompt(
                prompt,
                context: normalizedContext,
                authorization: authorization
            ) {
                recordFirstInput(device: device, sessionID: sessionID)
                status = .accepted
            } else {
                status = .rejected
            }
        } else {
            status = .unavailable
        }

        if let replayKey {
            promptReplayCache.store(status, for: replayKey, fingerprint: fingerprint)
        }
        return status
    }

    /// The prompt as the agent will see it: the words, then the pictures.
    ///
    /// Uploads take custody through the same door the Mac's own composer uses, so a file sent
    /// from a phone is filed as `origin: .user`, appears in the attachments pane beside what the
    /// agent makes of it, and is quoted into the text by the one spelling both composers share.
    /// Staging is a temporary directory nothing else owns; naming those paths directly would be
    /// the vanishing-attachments bug again, one device further away.
    ///
    /// Nil means the hand-over failed — no working directory, or custody refused every file. The
    /// caller turns that into a rejection rather than sending words that promise a picture the
    /// agent will not find.
    private func promptText(
        _ text: String,
        stagedAttachmentPaths: [String],
        for sessionID: SessionID
    ) -> String? {
        guard !stagedAttachmentPaths.isEmpty else { return text }

        // The staged files are on loan, not handed over: the server released or discarded them
        // by the status this call returns. Deleting them here would take them away from a
        // rejected submission the composer is about to retry.
        guard let folder = ProjectStore.shared.workingDirectory(forSessionID: sessionID) else {
            return nil
        }
        let handed = ComposerAttachmentHandover.handOver(
            paths: stagedAttachmentPaths,
            sessionID: sessionID,
            projectRoot: URL(fileURLWithPath: folder, isDirectory: true)
        )
        // `handOver` falls back to the caller's own paths when custody could not be taken, which
        // is right for a Mac drop naming a file the user still has. Here that fallback would name
        // staging, which the server is about to reclaim, so anything short of custody for every
        // file is a refusal instead.
        guard handed.count == stagedAttachmentPaths.count,
              handed != stagedAttachmentPaths else { return nil }
        return ComposerAttachmentHandover.appending(paths: handed, to: text)
    }

    /// Sends one locally composed terminal line as one PTY write. Every device keeps its own
    /// draft; only the completed line joins the shared byte stream, so two phones cannot splice
    /// individual keystrokes into one malformed Claude/Codex prompt.
    func submitTerminalLine(
        _ text: String,
        to sessionID: SessionID,
        device: String?,
        authorization: RemoteAuthorization,
        requestID: String?
    ) -> RemotePromptSubmissionStatus {
        let replayKey = requestID.map {
            RemotePromptReplayCache.Key(
                sessionID: sessionID.uuidString,
                principalID: [
                    authorization.principal == .ownerDevice ? "owner" : "guest",
                    authorization.member?.id ?? authorization.shareID,
                    device ?? "legacy",
                ].joined(separator: ":"),
                requestID: $0
            )
        }
        let fingerprint = Data(SHA256.hash(data: Data(("terminal\0" + text).utf8)))
        if let replayKey {
            switch promptReplayCache.decision(for: replayKey, fingerprint: fingerprint) {
            case .new:
                break
            case .replay(let status):
                return status
            case .conflict:
                return .conflict
            }
        }

        let status: RemotePromptSubmissionStatus
        if !canWrite(sessionID: sessionID, authorization: authorization) {
            status = .rejected
        } else if mirrors[sessionID]?.surface == .terminal,
           RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID)),
           terminalApplication?.sendInput(
               Array((text + "\r").utf8),
               to: sessionID
           ) == .applied {
            recordFirstInput(device: device, sessionID: sessionID)
            RemoteNotificationService.shared.recordInteraction(
                sessionID: sessionID,
                authorization: authorization
            )
            status = .accepted
        } else {
            status = .unavailable
        }

        if let replayKey {
            promptReplayCache.store(status, for: replayKey, fingerprint: fingerprint)
        }
        return status
    }

    // MARK: - Input control

    /// The Mac is a participant too. This is checked at the local submission boundary so a
    /// focused guest controls both remote clients and the host keyboard without making drafts
    /// read-only.
    func ownerCanWrite(to sessionID: SessionID) -> Bool {
        RemoteInputControlPolicy.canWrite(
            inputControlRecord(for: sessionID),
            participantID: RemoteCollaborationParticipantDTO.ownerID
        )
    }

    /// Owner-facing state for the Sharing pane. The local Mac is always online and can manage.
    func ownerInputControlState(for sessionID: SessionID) -> RemoteInputControlStateDTO {
        inputControlState(
            sessionID: sessionID,
            participantID: RemoteCollaborationParticipantDTO.ownerID,
            canManage: true
        )
    }

    @discardableResult
    func setInputControlFromOwner(
        _ action: RemoteInputControlAction,
        sessionID: SessionID,
        targetID: String? = nil
    ) -> RemoteInputControlResultStatus {
        applyInputControl(
            action,
            sessionID: sessionID,
            actorID: RemoteCollaborationParticipantDTO.ownerID,
            actorDisplayName: RemoteHostIdentity.current.name,
            actorCanManage: true,
            targetID: targetID
        )
    }

    func updateInputControl(
        from connection: RemoteConnection,
        sessionID: SessionID,
        action: RemoteInputControlAction,
        targetID: String?,
        requestID: String
    ) -> RemoteInputControlResultStatus {
        guard let peer = connection.authenticatedPeer,
              peer.authorization.capability == .interact,
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil else {
            return .forbidden
        }
        let actorID = peer.authorization.collaborationParticipantID
        if action == .request {
            let record = inputControlRecord(for: sessionID)
            guard record.mode == .focused,
                  let controllerID = record.controllerID,
                  controllerID != actorID else { return .rejected }
            switch requestAttention(
                from: connection,
                sessionID: sessionID,
                recipientID: controllerID,
                note: L10n.string("Would like input control"),
                requestID: requestID,
                broadcastsCollaborationEvent: false
            ) {
            case .delivered:
                break
            case .unavailable:
                return .unavailable
            case .rateLimited, .rejected:
                return .rejected
            }
        }
        return applyInputControl(
            action,
            sessionID: sessionID,
            actorID: actorID,
            actorDisplayName: peer.authorization.member?.displayName
                ?? peer.deviceName
                ?? RemoteHostIdentity.current.name,
            actorCanManage: peer.authorization.canManageHost,
            targetID: targetID
        )
    }

    private func applyInputControl(
        _ action: RemoteInputControlAction,
        sessionID: SessionID,
        actorID: String,
        actorDisplayName: String,
        actorCanManage: Bool,
        targetID: String?
    ) -> RemoteInputControlResultStatus {
        let current = inputControlRecord(for: sessionID)
        let participants = inputControlParticipants(for: sessionID)
        // Presence is not cosmetic at the handoff boundary. Selecting a participant who is
        // already away cannot produce a later detach event, so the disconnect grace timer would
        // never start and the session could remain focused on nobody indefinitely.
        let eligible = Self.eligibleInputControlParticipantIDs(participants)
        guard let result = RemoteInputControlPolicy.applying(
            action,
            to: current,
            actorID: actorID,
            actorCanManage: actorCanManage,
            targetID: targetID,
            eligibleParticipantIDs: eligible
        ) else { return .rejected }

        let resolvedTargetID = action == .reclaim
            ? RemoteCollaborationParticipantDTO.ownerID
            : (targetID ?? result.record.controllerID)
        let targetName = participants.first(where: { $0.id == resolvedTargetID })?.displayName

        if action == .request {
            let controllerID = current.controllerID
            let controllerName = participants.first(where: { $0.id == controllerID })?.displayName
            broadcastInputControlEvent(RemoteInputControlEventDTO(
                action: "requested",
                actorID: actorID,
                actorDisplayName: actorDisplayName,
                targetID: controllerID,
                targetDisplayName: controllerName
            ), sessionID: sessionID)
            NotificationCenter.default.post(SessionInputControlRequested(
                sessionID: sessionID,
                requesterName: actorDisplayName
            ))
            return result.status
        }

        inputControls[sessionID] = result.record
        focusedControllerReleaseTasks[sessionID]?.cancel()
        focusedControllerReleaseTasks[sessionID] = nil

        let eventAction: String
        switch action {
        case .collaborative, .focused: eventAction = "modeChanged"
        case .handoff: eventAction = "handedOff"
        case .reclaim: eventAction = "reclaimed"
        case .request: eventAction = "requested"
        }
        broadcastInputControlEvent(RemoteInputControlEventDTO(
            action: eventAction,
            actorID: actorID,
            actorDisplayName: actorDisplayName,
            targetID: resolvedTargetID,
            targetDisplayName: targetName
        ), sessionID: sessionID)
        inputControlChanged(sessionID)
        return result.status
    }

    nonisolated static func eligibleInputControlParticipantIDs(
        _ participants: [RemoteCollaborationParticipantDTO]
    ) -> Set<String> {
        Set(participants.lazy.filter(\.isOnline).map(\.id))
    }

    private func inputControlRecord(for sessionID: SessionID) -> RemoteInputControlRecord {
        if let record = inputControls[sessionID] { return record }
        let record = RemoteInputControlRecord.initial(
            default: AppSettings.shared.remoteInputControlDefault
        )
        inputControls[sessionID] = record
        return record
    }

    private func canWrite(
        sessionID: SessionID,
        authorization: RemoteAuthorization
    ) -> Bool {
        authorization.capability == .interact && RemoteInputControlPolicy.canWrite(
            inputControlRecord(for: sessionID),
            participantID: authorization.collaborationParticipantID
        )
    }

    private func inputControlState(
        sessionID: SessionID,
        participantID: String,
        canManage: Bool
    ) -> RemoteInputControlStateDTO {
        let record = inputControlRecord(for: sessionID)
        let participants = inputControlParticipants(for: sessionID)
        let controller = participants.first { $0.id == record.controllerID }
        return RemoteInputControlStateDTO(
            mode: record.mode,
            controllerID: record.controllerID,
            controllerDisplayName: controller?.displayName,
            currentParticipantID: participantID,
            canWrite: RemoteInputControlPolicy.canWrite(
                record,
                participantID: participantID
            ),
            canManage: canManage,
            canHandOff: record.mode == .focused
                && (record.controllerID == participantID || canManage),
            participants: participants,
            revision: record.revision
        )
    }

    private func inputControlParticipants(
        for sessionID: SessionID
    ) -> [RemoteCollaborationParticipantDTO] {
        let subscribers = mirrors[sessionID].map { Array($0.subscribers.values) } ?? []
        var participants = [RemoteCollaborationParticipantDTO(
            id: RemoteCollaborationParticipantDTO.ownerID,
            displayName: RemoteHostIdentity.current.name,
            role: "owner",
            isOnline: true
        )]
        var membersByID = Dictionary(uniqueKeysWithValues:
            RemoteAccessCoordinator.shared.access(for: sessionID)
                .members
                .filter { $0.capability == .interact }
                .map { member in
                    (member.id, RemoteCollaborationParticipantDTO(
                        id: member.id,
                        displayName: member.displayName,
                        role: "member",
                        isOnline: subscribers.contains {
                            $0.authenticatedPeer?.authorization.member?.id == member.id
                        }
                    ))
                }
        )
        // The authenticated socket is also an exact source of live membership. Keeping it in
        // the roster makes handoff resilient if the durable access read model is refreshing or
        // recovering while an already-authorized guest is connected.
        for subscriber in subscribers {
            guard let authorization = subscriber.authenticatedPeer?.authorization,
                  authorization.capability == .interact,
                  let member = authorization.member else { continue }
            membersByID[member.id] = RemoteCollaborationParticipantDTO(
                id: member.id,
                displayName: member.displayName,
                role: "member",
                isOnline: true
            )
        }
        participants.append(contentsOf: membersByID.values)
        return participants.sorted {
            if $0.role != $1.role { return $0.role == "owner" }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    private func broadcastInputControl(_ sessionID: SessionID) {
        guard let mirror = mirrors[sessionID] else { return }
        for connection in mirror.subscribers.values {
            guard let authorization = connection.authenticatedPeer?.authorization else { continue }
            connection.sendText(encode(inputControlState(
                sessionID: sessionID,
                participantID: authorization.collaborationParticipantID,
                canManage: authorization.canManageHost
            )))
        }
    }

    private func broadcastInputControlEvent(
        _ event: RemoteInputControlEventDTO,
        sessionID: SessionID
    ) {
        guard let mirror = mirrors[sessionID] else { return }
        let message = encode(event)
        for connection in mirror.subscribers.values { connection.sendText(message) }
    }

    private func inputControlChanged(_ sessionID: SessionID) {
        if var mirror = mirrors[sessionID], mirror.surface == .terminal {
            let subscribers = mirror.subscribers
            mirror.viewportRequests = mirror.viewportRequests.filter { key, _ in
                guard let authorization = subscribers[key]?.authenticatedPeer?.authorization
                else { return false }
                return canWrite(sessionID: sessionID, authorization: authorization)
            }
            mirrors[sessionID] = mirror
            applyViewport(for: sessionID)
        }
        broadcastInputControl(sessionID)
        // Provider state did not change, but each viewer's authorised `canSend` may have.
        if mirrors[sessionID]?.surface == .conversation,
           let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID),
           let mirror = mirrors[sessionID] {
            let revision = mirror.conversationRevision
            for connection in mirror.subscribers.values {
                guard let authorization = connection.authenticatedPeer?.authorization else { continue }
                connection.sendText(encode(RemoteConversationWirePolicy.authorized(
                    RemoteConversationWirePolicy.initial(
                        conversation.remoteSnapshot,
                        revision: revision
                    ),
                    for: authorization,
                    canWrite: canWrite(sessionID: sessionID, authorization: authorization)
                )))
            }
        }
        NotificationCenter.default.post(SessionInputControlDidChange(sessionID: sessionID))
        followersChanged(sessionID)
    }

    private func scheduleFocusedControlReleaseIfNeeded(
        sessionID: SessionID,
        participantID: String
    ) {
        let record = inputControlRecord(for: sessionID)
        guard participantID != RemoteCollaborationParticipantDTO.ownerID,
              record.mode == .focused,
              record.controllerID == participantID,
              !inputControlParticipants(for: sessionID).contains(where: {
                  $0.id == participantID && $0.isOnline
              }) else { return }

        focusedControllerReleaseTasks[sessionID]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let current = self.inputControlRecord(for: sessionID)
            guard current.mode == .focused,
                  current.controllerID == participantID,
                  !self.inputControlParticipants(for: sessionID).contains(where: {
                      $0.id == participantID && $0.isOnline
                  }) else { return }
            var released = current
            released.controllerID = RemoteCollaborationParticipantDTO.ownerID
            released.revision &+= 1
            self.inputControls[sessionID] = released
            self.broadcastInputControlEvent(RemoteInputControlEventDTO(
                action: "released",
                actorID: RemoteCollaborationParticipantDTO.ownerID,
                actorDisplayName: RemoteHostIdentity.current.name,
                targetID: RemoteCollaborationParticipantDTO.ownerID,
                targetDisplayName: RemoteHostIdentity.current.name
            ), sessionID: sessionID)
            self.inputControlChanged(sessionID)
        }
        focusedControllerReleaseTasks[sessionID] = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RemoteAccessDefaults.focusedControllerDisconnectGrace,
            execute: work
        )
    }

    func updatePresence(
        _ state: String,
        from connection: RemoteConnection,
        sessionID: SessionID
    ) {
        guard state == "typing" || state == "idle",
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              connection.authenticatedPeer?.authorization.capability == .interact else {
            return
        }
        broadcastPresence(state, from: connection, sessionID: sessionID)
    }

    /// Sends a human-only attention request. This method has no reference to either prompt
    /// submission or terminal input: its only side effects are a targeted notification and a
    /// small collaboration event on authenticated session sockets.
    func requestAttention(
        from connection: RemoteConnection,
        sessionID: SessionID,
        recipientID: String,
        note: String?,
        requestID: String,
        broadcastsCollaborationEvent: Bool = true
    ) -> RemoteAttentionRequestStatus {
        guard let peer = connection.authenticatedPeer,
              peer.authorization.capability == .interact,
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              let recipient = collaborationParticipants(
                for: sessionID,
                authorization: peer.authorization
              ).first(where: { $0.id == recipientID }) else {
            return .rejected
        }

        // A person can have several devices, but this is one request from that participant.
        // Otherwise moving from iPhone to browser would bypass the 30-second duplicate collapse.
        let principalID = peer.authorization.collaborationParticipantID
        let requestKey = RemoteAttentionRequestPolicy.RequestKey(
            sessionID: sessionID.uuidString,
            principalID: principalID,
            requestID: requestID
        )
        let rateKey = RemoteAttentionRequestPolicy.RateKey(
            sessionID: sessionID.uuidString,
            principalID: principalID,
            recipientID: recipientID
        )
        let fingerprint = Data(SHA256.hash(data: Data(
            (recipientID + "\0" + (note ?? "")).utf8
        )))
        switch attentionRequestPolicy.decision(
            requestKey: requestKey,
            rateKey: rateKey,
            fingerprint: fingerprint
        ) {
        case .replay(let status):
            return status
        case .conflict:
            return .rejected
        case .rateLimited:
            return .rateLimited
        case .proceed:
            break
        }

        let senderID = peer.authorization.member?.id
            ?? "owner:\(peer.deviceID ?? "device")"
        let senderDisplayName = peer.authorization.member?.displayName
            ?? peer.deviceName
            ?? "Owner"
        let event = RemoteAttentionEventDTO(
            requestID: requestID,
            senderID: senderID,
            senderDisplayName: senderDisplayName,
            recipientID: recipient.id,
            recipientDisplayName: recipient.displayName,
            note: note
        )

        let liveRecipients = mirrors[sessionID]?.subscribers.values.filter { candidate in
            guard let authorization = candidate.authenticatedPeer?.authorization else {
                return false
            }
            if recipientID == RemoteCollaborationParticipantDTO.ownerID {
                return authorization.principal == .ownerDevice
            }
            return authorization.member?.id == recipientID
        }.count ?? 0
        let optedInDevices = RemoteNotificationService.shared.attentionRequested(
            eventID: event.id,
            sessionID: sessionID,
            senderDisplayName: senderDisplayName,
            recipientID: recipientID,
            note: note
        )
        let status: RemoteAttentionRequestStatus = liveRecipients > 0 || optedInDevices > 0
            ? .delivered
            : .unavailable
        attentionRequestPolicy.store(
            status,
            requestKey: requestKey,
            rateKey: rateKey,
            fingerprint: fingerprint
        )
        guard status == .delivered else { return status }

        if broadcastsCollaborationEvent {
            let message = encode(event)
            for subscriber in mirrors[sessionID].map({ Array($0.subscribers.values) }) ?? [] {
                subscriber.sendText(message)
            }
        }
        EventLog.shared.record(.remote, "Collaboration attention requested", [
            "session": sessionID.uuidString,
            "recipient": recipient.role,
            "live": String(liveRecipients),
            "registered": String(optedInDevices),
        ])
        return status
    }

    /// Called after the native timeline changes. Provider-specific events are still folded only
    /// once on the Mac; the remote wire derives append/result deltas from that normalized state.
    /// Streaming providers can call this for every token, so updates are coalesced to one frame
    /// per display refresh.
    func sessionConversationChanged(_ sessionID: SessionID) {
        guard mirrors[sessionID]?.surface == .conversation,
              pendingConversationBroadcasts[sessionID] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingConversationBroadcasts[sessionID] = nil
            self.broadcastConversation(sessionID)
        }
        pendingConversationBroadcasts[sessionID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func broadcastConversation(_ sessionID: SessionID) {
        guard var mirror = mirrors[sessionID], mirror.surface == .conversation,
              let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID) else {
            return
        }
        let projection = conversation.remoteProjection
        let current = projection.snapshot
        let previous = mirror.conversationSnapshot
        let rowsUnchanged = mirror.conversationRowsRevision == projection.rowsRevision
        let metadataUnchanged = previous.map {
            Self.sameConversationMetadata($0, current)
        } ?? false
        guard !rowsUnchanged || !metadataUnchanged else { return }

        let baseRevision = mirror.conversationRevision
        let revision = baseRevision &+ 1
        let delta = previous.flatMap {
            rowsUnchanged
                ? RemoteConversationWirePolicy.deltaWithUnchangedRows(
                    from: $0,
                    to: current,
                    baseRevision: baseRevision,
                    revision: revision
                )
                : RemoteConversationWirePolicy.delta(
                    from: $0,
                    to: current,
                    baseRevision: baseRevision,
                    revision: revision
                )
        }
        mirror.conversationSnapshot = current
        mirror.conversationRowsRevision = projection.rowsRevision
        mirror.conversationRevision = revision
        mirrors[sessionID] = mirror

        for connection in mirror.subscribers.values {
            guard let authorization = connection.authenticatedPeer?.authorization else { continue }
            if let delta {
                connection.sendText(encode(RemoteConversationWirePolicy.authorized(
                    delta,
                    for: authorization,
                    canWrite: canWrite(sessionID: sessionID, authorization: authorization)
                )))
            } else {
                connection.sendText(encode(RemoteConversationWirePolicy.authorized(
                    RemoteConversationWirePolicy.initial(current, revision: revision),
                    for: authorization,
                    canWrite: canWrite(sessionID: sessionID, authorization: authorization)
                )))
            }
        }
    }

    /// Compares only state that can change without a timeline-row mutation. Row equality is
    /// answered by `RemoteConversationRowsRevision`, so a token does not walk the transcript.
    private static func sameConversationMetadata(
        _ lhs: RemoteConversationSnapshotDTO,
        _ rhs: RemoteConversationSnapshotDTO
    ) -> Bool {
        lhs.streamingText == rhs.streamingText
            && lhs.canSend == rhs.canSend
            && lhs.composerCapabilities == rhs.composerCapabilities
            && lhs.permission == rhs.permission
            && lhs.hasEarlier == rhs.hasEarlier
    }

    /// Keeps a remote renderer on the local terminal's authoritative grid. The remote never
    /// resizes the PTY; it follows the Mac, including split-view and window size changes.
    func sessionResized(_ sessionID: SessionID, cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let mirror = mirrors[sessionID] else { return }
        let message = encode(RemoteResizeDTO(cols: cols, rows: rows))
        for connection in mirror.subscribers.values {
            connection.sendText(message)
        }
    }

    /// OSC title changes are part of the live terminal state too. Sending a small dedicated
    /// message avoids replaying `hello`, which would register the browser's input handler twice.
    func sessionTitleChanged(_ sessionID: SessionID, title: String) {
        guard let mirror = mirrors[sessionID] else { return }
        let message = encode(RemoteTitleDTO(title: title))
        for connection in mirror.subscribers.values {
            connection.sendText(message)
        }
    }

    /// Pushes chrome and the per-session terminal palette to already-open clients.
    private func broadcastThemes() {
        let appMessage = encode(RemoteAppThemeUpdateDTO(theme: RemoteThemeBridge.appTheme()))
        for connection in themeEventSubscribers.values {
            connection.sendText(appMessage)
        }
        for (sessionID, mirror) in mirrors where !mirror.subscribers.isEmpty {
            let message = encode(RemoteThemeBridge.update(for: sessionID))
            for connection in mirror.subscribers.values {
                connection.sendText(message)
            }
        }
    }

    /// Keeps high-frequency row changes proportional to the changed session. Structural edits
    /// remain an invalidation because they can change ordering, projects, archives and creation
    /// choices together; every client then re-fetches its own scoped snapshot.
    private func broadcastSessionsChanged(_ change: ProjectsDidChange) {
        switch change.sidebarImpact {
        case .structure, .projectStructure:
            let message = encode(RemoteSessionsChangedDTO())
            for connection in themeEventSubscribers.values {
                connection.sendText(message)
            }
        case .terminalRow(let terminalID):
            let terminal = ProjectStore.shared.terminal(withID: terminalID)
            for connection in themeEventSubscribers.values {
                guard let authorization = connection.authenticatedPeer?.authorization,
                      authorization.scope.covers(terminalID) else { continue }
                let visible = terminal.map { candidate in
                    let project = ProjectStore.shared.displayProject(forTerminalID: terminalID)
                        ?? ProjectStore.shared.homeProject(forTerminalID: terminalID)
                    return terminalSummary(
                        for: candidate,
                        projectName: project?.name ?? ""
                    )
                }
                connection.sendText(encode(RemoteSessionsChangedDTO(
                    terminal: visible,
                    removedTerminalID: visible == nil ? terminalID.uuidString : nil
                )))
            }
        case .sessionRemoved:
            for connection in themeEventSubscribers.values {
                guard let authorization = connection.authenticatedPeer?.authorization,
                      let delta = Self.sessionRemovalDelta(
                          for: change,
                          authorization: authorization
                      ) else { continue }
                connection.sendText(encode(delta))
            }
        case .sessionOrder(let sessionID), .sessionRow(let sessionID):
            let session = ProjectStore.shared.session(withID: sessionID)
            let project = ProjectStore.shared.project(forSessionID: sessionID)
            for connection in themeEventSubscribers.values {
                guard let authorization = connection.authenticatedPeer?.authorization else {
                    continue
                }
                let visible = session.flatMap { candidate -> RemoteSessionSummaryDTO? in
                    guard RemoteSessionAccess.isVisible(candidate),
                          authorization.scope.covers(candidate.id),
                          let project else { return nil }
                    return summary(
                        for: candidate,
                        projectName: project.name,
                        projectLimitRecovery: project.limitRecoveryPolicy,
                        authorization: authorization
                    )
                }
                connection.sendText(encode(RemoteSessionsChangedDTO(
                    session: visible,
                    removedSessionID: visible == nil ? sessionID.uuidString : nil
                )))
            }
        }
    }

    /// Pushes one identity-specific catalogue row for an activity or read-receipt edge.
    private func broadcastSessionRow(_ sessionID: SessionID) {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              let project = ProjectStore.shared.project(forSessionID: sessionID) else { return }
        for connection in themeEventSubscribers.values {
            guard let authorization = connection.authenticatedPeer?.authorization,
                  RemoteSessionAccess.isVisible(session),
                  authorization.scope.covers(sessionID) else { continue }
            connection.sendText(encode(RemoteSessionsChangedDTO(session: summary(
                for: session,
                projectName: project.name,
                projectLimitRecovery: project.limitRecoveryPolicy,
                authorization: authorization
            ))))
        }
    }

    /// The permanent-delete catalogue delta is exact and scope-bound. Keeping the authorization
    /// decision beside the payload construction makes this small but security-sensitive branch
    /// independently testable without opening a real event socket.
    static func sessionRemovalDelta(
        for change: ProjectsDidChange,
        authorization: RemoteAuthorization
    ) -> RemoteSessionsChangedDTO? {
        guard case .sessionRemoved(_, let sessionID) = change.sidebarImpact,
              authorization.scope.covers(sessionID) else { return nil }
        return RemoteSessionsChangedDTO(
            session: nil,
            removedSessionID: sessionID.uuidString
        )
    }

    /// Invalidates the owner phone's read-only companion surfaces without steering its UI.
    ///
    /// Browser tools call this once they finish. Meaningful navigation carries an activity id
    /// that can become a subtle unread hint; in-page mutations send only an invalidation so a
    /// visible Follow view refreshes without pulsing on every click or scroll.
    func workspaceBrowserChanged(
        _ sessionID: SessionID,
        announcesActivity: Bool
    ) {
        guard RemoteSessionAccess.isVisible(
            ProjectStore.shared.session(withID: sessionID)
        ) else { return }

        let event = RemoteWorkspaceChangedDTO(
            kind: .browser,
            activityID: announcesActivity ? UUID().uuidString : nil
        )
        if announcesActivity {
            latestWorkspaceActivity[sessionID] = event
        }

        guard let mirror = mirrors[sessionID] else { return }
        let message = encode(event)
        for connection in mirror.subscribers.values {
            guard let peer = connection.authenticatedPeer,
                  canManageSessions(peer.authorization) else { continue }
            connection.sendText(message)
        }
    }

    func latestWorkspaceActivityID(for sessionID: SessionID) -> String? {
        latestWorkspaceActivity[sessionID]?.activityID
    }

    func sessionSharingChanged() {
        // Sharing can change both a session's summary and which sessions a scoped peer may see.
        // There is no single safe row delta, so make every client refresh its own authorised
        // catalogue through the structural invalidation path.
        broadcastSessionsChanged(ProjectsDidChange())
        for sessionID in mirrors.keys {
            if var record = inputControls[sessionID],
               record.mode == .focused,
               let controllerID = record.controllerID,
               !inputControlParticipants(for: sessionID).contains(where: {
                   $0.id == controllerID
               }) {
                record.controllerID = RemoteCollaborationParticipantDTO.ownerID
                record.revision &+= 1
                inputControls[sessionID] = record
                inputControlChanged(sessionID)
            }
            broadcastCollaborationParticipants(sessionID)
            broadcastInputControl(sessionID)
            followersChanged(sessionID)
        }
        NotificationCenter.default.post(SessionSharingDidChange())
    }

    // MARK: - Followers

    /// One live view of one chat. A person may hold two of these — a phone and a browser tab —
    /// which is exactly the case the sharing pane exists to make visible.
    struct Follower: Equatable, Identifiable {
        /// Stable for the life of the socket; a reconnect is a different follower.
        let id: ObjectIdentifier
        /// The member's own name for a guest; nil for one of the owner's paired devices, which
        /// carry an owner credential and have never been asked for a guest member name.
        let memberName: String?
        let memberID: String?
        /// What the device calls itself, when it said. Never an identity — see
        /// `RemoteInboundPolicy.normalizedDeviceName`.
        let deviceName: String?
        /// The short pseudonym the diagnostics log already uses, for a device that did not.
        let deviceLabel: String
        let isOwnerDevice: Bool
        let capability: RemoteCapability
        let canApprovePermissions: Bool
        /// Which of the chat's two faces they are looking at.
        let surface: RemoteSessionSurface
        /// The grid this follower is holding the shared PTY at, when it holds one.
        let viewport: (cols: Int, rows: Int)?
        let watchingSince: Date?
        let isTyping: Bool

        static func == (lhs: Follower, rhs: Follower) -> Bool {
            lhs.id == rhs.id
                && lhs.memberName == rhs.memberName
                && lhs.deviceName == rhs.deviceName
                && lhs.surface == rhs.surface
                && lhs.viewport?.cols == rhs.viewport?.cols
                && lhs.viewport?.rows == rhs.viewport?.rows
                && lhs.isTyping == rhs.isTyping
        }
    }

    /// Everyone with a live socket on this chat right now.
    ///
    /// Read from the mirror's own subscribers, so it is the truth the PTY answers to rather than
    /// a record of who was invited: a member who closed their phone is not here, and one of the
    /// owner's devices that never accepted anything is.
    func followers(of sessionID: SessionID) -> [Follower] {
        guard let mirror = mirrors[sessionID] else { return [] }
        let typing = typingConnections[sessionID] ?? []
        return mirror.subscribers.map { key, connection in
            let peer = connection.authenticatedPeer
            let authorization = peer?.authorization
            let request = mirror.viewportRequests[key]
            return Follower(
                id: key,
                memberName: authorization?.member?.displayName,
                memberID: authorization?.member?.id,
                deviceName: peer?.deviceName,
                deviceLabel: MacRemoteDiagnostics.pseudonym(
                    peer?.deviceID ?? "unknown",
                    prefix: "device"
                ),
                isOwnerDevice: authorization?.principal == .ownerDevice,
                capability: authorization?.capability ?? .view,
                canApprovePermissions: authorization?.canApprovePermissions ?? false,
                surface: mirror.surface,
                viewport: request.map { (cols: $0.cols, rows: $0.rows) },
                watchingSince: peer?.authenticatedAt,
                isTyping: typing.contains(key)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isOwnerDevice != rhs.isOwnerDevice { return !lhs.isOwnerDevice }
            return (lhs.watchingSince ?? .distantPast) < (rhs.watchingSince ?? .distantPast)
        }
    }

    /// Tells the corner card and the sharing pane that this chat's live audience moved.
    private func followersChanged(_ sessionID: SessionID) {
        NotificationCenter.default.post(SessionFollowersDidChange(sessionID: sessionID))
    }

    // MARK: - Session lifecycle

    /// Called by `AgentRuntime` when a session is discarded or the app is quitting: tells every
    /// watcher the mirror ended so the CLI is not left blocked and the client stops waiting.
    func sessionDiscarded(_ sessionID: SessionID) {
        pendingConversationBroadcasts.removeValue(forKey: sessionID)?.cancel()
        latestWorkspaceActivity.removeValue(forKey: sessionID)
        typingConnections.removeValue(forKey: sessionID)
        promptReplayCache.remove(sessionID: sessionID.uuidString)
        attentionRequestPolicy.remove(sessionID: sessionID.uuidString)
        defer { followersChanged(sessionID) }
        guard let mirror = mirrors[sessionID] else { return }
        _ = terminalApplication?.setViewport(nil, for: sessionID)
        removeTap(sessionID: sessionID)
        let ended = encode(RemoteEndedDTO(reason: "sessionClosed"))
        for connection in mirror.subscribers.values {
            connection.sendText(ended)
            // `ended` is useful UI state, but it is not revocation. Closing the socket is what
            // prevents a client that ignores `ended` from typing into a later relaunch of the
            // same session id with its already-authenticated connection.
            connection.sendClose(code: RemoteWebSocket.CloseCode.goingAway, reason: "Session closed")
            let key = ObjectIdentifier(connection)
            sessionByConnection.removeValue(forKey: key)
            presenceIDs[key] = nil
        }
        mirrors[sessionID] = nil
    }

    func terminalDiscarded(_ terminalID: TerminalID) {
        guard let mirror = terminalMirrors[terminalID] else { return }
        _ = terminalApplication?.setViewport(nil, for: terminalID)
        removeTap(terminalID: terminalID)
        let ended = encode(RemoteEndedDTO(reason: "terminalClosed"))
        for connection in mirror.subscribers.values {
            connection.sendText(ended)
            connection.sendClose(
                code: RemoteWebSocket.CloseCode.goingAway,
                reason: "Terminal closed"
            )
            terminalByConnection.removeValue(forKey: ObjectIdentifier(connection))
        }
        terminalMirrors[terminalID] = nil
    }

    // MARK: - Private

    private func removeTap(sessionID: SessionID) {
        _ = terminalApplication?.endCapture(for: sessionID)
    }

    private func removeTap(terminalID: TerminalID) {
        _ = terminalApplication?.endCapture(for: terminalID)
    }

    private func releaseViewport(for connection: RemoteConnection, sessionID: SessionID) {
        guard mirrors[sessionID]?.viewportRequests.removeValue(
            forKey: ObjectIdentifier(connection)
        ) != nil else { return }
        applyViewport(for: sessionID)
    }

    private func applyViewport(for sessionID: SessionID) {
        guard let terminalApplication,
              case .available(let state) = terminalApplication.state(for: sessionID) else {
            return
        }
        let requests = mirrors[sessionID]?.viewportRequests.map {
            (cols: $0.value.cols, rows: $0.value.rows)
        } ?? []
        guard let grid = Self.resolvedViewport(of: requests) else {
            guard state.remoteViewport != nil else { return }
            guard terminalApplication.setViewport(nil, for: sessionID) == .applied else { return }
            EventLog.shared.record(.remote, "Remote viewport released", [
                "session": sessionID.uuidString,
            ])
            return
        }
        let requestedGrid = RemoteTerminalGrid(cols: grid.cols, rows: grid.rows)
        guard state.remoteViewport != requestedGrid else {
            return
        }
        guard terminalApplication.setViewport(requestedGrid, for: sessionID) == .applied else {
            return
        }
        EventLog.shared.record(.remote, "Remote viewport applied", [
            "session": sessionID.uuidString,
            "grid": "\(grid.cols)×\(grid.rows)",
            "clients": String(requests.count),
        ])
        followersChanged(sessionID)
    }

    private func releaseViewport(for connection: RemoteConnection, terminalID: TerminalID) {
        guard terminalMirrors[terminalID]?.viewportRequests.removeValue(
            forKey: ObjectIdentifier(connection)
        ) != nil else { return }
        applyViewport(for: terminalID)
    }

    private func applyViewport(for terminalID: TerminalID) {
        guard let terminalApplication,
              case .available(let state) = terminalApplication.state(for: terminalID) else {
            return
        }
        let requests = terminalMirrors[terminalID]?.viewportRequests.map {
            (cols: $0.value.cols, rows: $0.value.rows)
        } ?? []
        let grid = Self.resolvedViewport(of: requests).map {
            RemoteTerminalGrid(cols: $0.cols, rows: $0.rows)
        }
        guard state.remoteViewport != grid else { return }
        _ = terminalApplication.setViewport(grid, for: terminalID)
        EventLog.shared.record(.remote, grid == nil
            ? "Remote terminal viewport released"
            : "Remote terminal viewport applied", [
                "terminal": terminalID.uuidString,
                "clients": String(requests.count),
            ])
    }

    /// Settles the one shared PTY between every interactive client watching it.
    ///
    /// The answer is the intersection — the widest and tallest grid that fits inside all of
    /// them — because it is the only one every viewer can see whole, and because it does not
    /// depend on who asked last. Honouring the most recent request instead let two clients
    /// fight: the Mac broadcast each new grid to everyone, and a client that could not show it
    /// answered by re-asking for its own, so the agent was reflowed and repainted several times
    /// a second for as long as both stayed open.
    static func resolvedViewport(
        of requests: [(cols: Int, rows: Int)]
    ) -> (cols: Int, rows: Int)? {
        guard let cols = requests.map(\.cols).min(),
              let rows = requests.map(\.rows).min() else { return nil }
        return (cols, rows)
    }

    private func closeUnavailableSessions() {
        for sessionID in Array(mirrors.keys) where !RemoteSessionAccess.isVisible(
            ProjectStore.shared.session(withID: sessionID)
        ) {
            sessionDiscarded(sessionID)
        }
    }

    private func broadcast(_ data: Data, sessionID: SessionID) {
        guard var mirror = mirrors[sessionID] else { return }
        mirror.ring.append(data)
        mirrors[sessionID] = mirror
        for connection in mirror.subscribers.values {
            connection.sendBinary(data)
        }
    }

    private func broadcast(_ data: Data, terminalID: TerminalID) {
        guard var mirror = terminalMirrors[terminalID] else { return }
        mirror.ring.append(data)
        terminalMirrors[terminalID] = mirror
        for connection in mirror.subscribers.values {
            connection.sendBinary(data)
        }
    }

    private func recordFirstInput(device: String?, sessionID: SessionID) {
        guard let device, mirrors[sessionID]?.inputSeenDevices.contains(device) == false else {
            return
        }
        mirrors[sessionID]?.inputSeenDevices.insert(device)
        EventLog.shared.record(.remote, "First remote input", [
            "session": sessionID.uuidString,
            "device": device,
        ])
    }

    private func broadcastPresence(
        _ state: String,
        from connection: RemoteConnection,
        sessionID: SessionID
    ) {
        guard connection.authenticatedPeer != nil,
              let mirror = mirrors[sessionID] else { return }

        // The Mac watches this as well as relaying it. A guest composing a reply is the one
        // piece of live state the sharing pane can show that a list of names cannot.
        let key = ObjectIdentifier(connection)
        let wasTyping = typingConnections[sessionID]?.contains(key) ?? false
        if state == "typing" {
            typingConnections[sessionID, default: []].insert(key)
        } else {
            typingConnections[sessionID]?.remove(key)
        }
        if wasTyping != (state == "typing") { followersChanged(sessionID) }

        let normalizedState = state == "idle" ? "viewing" : state
        let message = encode(presenceUpdate(
            for: connection,
            key: key,
            surface: mirror.surface,
            state: normalizedState
        ))
        let source = ObjectIdentifier(connection)
        for (key, subscriber) in mirror.subscribers where key != source {
            subscriber.sendText(message)
        }
    }

    /// Gives the new client a complete live roster, then tells every existing client that the
    /// newcomer is here. A typing update is only a delta; without this handshake a second phone
    /// could not distinguish “nobody else is here” from “somebody is here but not typing.”
    private func announcePresence(of connection: RemoteConnection, sessionID: SessionID) {
        let source = ObjectIdentifier(connection)
        guard let mirror = mirrors[sessionID], presenceIDs[source] != nil else { return }

        let newcomer = encode(presenceUpdate(
            for: connection,
            key: source,
            surface: mirror.surface,
            state: "viewing"
        ))
        let typing = typingConnections[sessionID] ?? []
        for (key, subscriber) in mirror.subscribers where key != source {
            connection.sendText(encode(presenceUpdate(
                for: subscriber,
                key: key,
                surface: mirror.surface,
                state: typing.contains(key) ? "typing" : "viewing"
            )))
            subscriber.sendText(newcomer)
        }
    }

    private func broadcastCollaborationParticipants(_ sessionID: SessionID) {
        guard let mirror = mirrors[sessionID] else { return }
        for connection in mirror.subscribers.values {
            guard let authorization = connection.authenticatedPeer?.authorization else { continue }
            connection.sendText(encode(RemoteCollaborationParticipantsDTO(
                participants: collaborationParticipants(
                    for: sessionID,
                    authorization: authorization
                )
            )))
        }
    }

    private func collaborationParticipants(
        for sessionID: SessionID,
        authorization: RemoteAuthorization
    ) -> [RemoteCollaborationParticipantDTO] {
        let subscribers = mirrors[sessionID].map { Array($0.subscribers.values) } ?? []
        var participants: [RemoteCollaborationParticipantDTO] = []

        if authorization.principal != .ownerDevice {
            participants.append(RemoteCollaborationParticipantDTO(
                id: RemoteCollaborationParticipantDTO.ownerID,
                displayName: RemoteHostIdentity.current.name,
                role: "owner",
                isOnline: subscribers.contains {
                    $0.authenticatedPeer?.authorization.principal == .ownerDevice
                }
            ))
        }

        let currentMemberID = authorization.member?.id
        for member in RemoteAccessCoordinator.shared.access(for: sessionID).members
            where member.capability == .interact && member.id != currentMemberID {
            participants.append(RemoteCollaborationParticipantDTO(
                id: member.id,
                displayName: member.displayName,
                role: "member",
                isOnline: subscribers.contains {
                    $0.authenticatedPeer?.authorization.member?.id == member.id
                }
            ))
        }
        return participants.sorted {
            if $0.role != $1.role { return $0.role == "owner" }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    private func presenceUpdate(
        for connection: RemoteConnection,
        key: ObjectIdentifier,
        surface: RemoteSessionSurface,
        state: String
    ) -> RemotePresenceDTO {
        let peer = connection.authenticatedPeer
        let authorization = peer?.authorization
        let deviceName = peer?.deviceName
        return RemotePresenceDTO(
            presenceID: presenceIDs[key],
            memberID: authorization?.member?.id
                ?? "owner:\(peer?.deviceID ?? "device")",
            displayName: authorization?.member?.displayName
                ?? deviceName
                ?? "Owner",
            deviceName: deviceName,
            surface: surface,
            state: state
        )
    }

    private func sendLatestWorkspaceActivity(
        to connection: RemoteConnection,
        sessionID: SessionID
    ) {
        guard let peer = connection.authenticatedPeer,
              canManageSessions(peer.authorization),
              let event = latestWorkspaceActivity[sessionID] else {
            return
        }
        connection.sendText(encode(event))
    }

    private func canManageThemes(_ authorization: RemoteAuthorization) -> Bool {
        authorization.canManageHost
    }

    private func canManageSessions(_ authorization: RemoteAuthorization) -> Bool {
        authorization.canManageHost
    }

    private func encode<Value: Encodable>(_ value: Value) -> String {
        do {
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        } catch {
            ThreadingLogger.remote.error(
                "Remote mirror encoding failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return #"{"type":"error","code":"encodingFailed"}"#
        }
    }
}
