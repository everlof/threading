import AppKit
import Foundation
import SkalmanRemoteKit

/// Bridges a live session to its remote subscribers: taps the PTY byte stream, keeps a ring for
/// late joiners, fans output out to every watcher, and routes remote input back in.
///
/// `@MainActor` because everything it touches — `AgentRuntime`, `TerminalSession`, `ProjectStore`
/// — is main-only. Connections live on the server queue and their `send*` methods hop there
/// themselves, so this class never blocks on the network.
///
/// Only the agent session's main surface is mirrored. Shell drawers and display-pane terminals
/// are not in `AgentRuntime` and stay local; native conversations use typed snapshots.
@MainActor
final class RemoteSessionMirrorRegistry {

    static let shared = RemoteSessionMirrorRegistry()
    private let appEvents = AppEventObservations()
    private var appearanceObservation: NSKeyValueObservation?

    private init() {
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
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.closeUnavailableSessions()
            self?.broadcastSessionsChanged()
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

    // MARK: - State

    private struct Mirror {
        var ring: RemoteRingBuffer
        let surface: String
        var subscribers: [ObjectIdentifier: RemoteConnection] = [:]
        /// Complete provider-neutral state and its live wire revision. The complete rows stay
        /// on the Mac; clients receive only a recent window plus requested older pages.
        var conversationSnapshot: RemoteConversationSnapshotDTO? = nil
        var conversationRevision = 0
        /// Devices that have already sent input, so the "first remote input" audit line is
        /// written once per device+session rather than per keystroke.
        var inputSeenDevices: Set<String> = []
        /// Interactive clients that currently have a terminal view on screen. The most recent
        /// request owns the shared PTY; retaining the others lets ownership fall back cleanly if
        /// the newest controller disconnects while another phone is still open.
        var viewportRequests: [ObjectIdentifier: ViewportRequest] = [:]
    }

    private struct ViewportRequest {
        let cols: Int
        let rows: Int
        let sequence: UInt64
    }

    private var mirrors: [SessionID: Mirror] = [:]
    private var sessionByConnection: [ObjectIdentifier: SessionID] = [:]
    private var themeEventSubscribers: [ObjectIdentifier: RemoteConnection] = [:]
    private var pendingConversationBroadcasts: [SessionID: DispatchWorkItem] = [:]
    private var viewportSequence: UInt64 = 0

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
                    .map { summary(for: $0, projectName: project.name) }
            }
            .sorted(by: summaryOrder)

        let scopeName: String
        switch authorization.scope {
        case .allSessions: scopeName = "all"
        case .session: scopeName = "session"
        }

        let ownsSessionLifecycle = canManageSessions(authorization)
        let archived = ownsSessionLifecycle
            ? ProjectStore.shared.archivedSessions()
                .map { summary(for: $0.session, projectName: $0.project.name) }
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
            host: RemoteHostIdentity.current,
            theme: RemoteThemeBridge.appTheme(),
            themeCatalog: canManageThemes(authorization)
                ? RemoteThemeBridge.catalog()
                : nil,
            archivedSessions: archived,
            newSessionCatalog: ownsSessionLifecycle ? newSessionCatalog() : nil
        )
    }

    private func summary(for session: AgentSession, projectName: String) -> RemoteSessionSummaryDTO {
        let available = AgentRuntime.shared.isRunning(sessionID: session.id)
        return RemoteSessionSummaryDTO(
            id: session.id.uuidString,
            title: session.displayTitle,
            agentKind: session.kind.rawValue,
            surface: session.usesNativeUI ? "conversation" : "terminal",
            state: String(describing: AgentRuntime.shared.activity(sessionID: session.id)),
            projectName: projectName,
            isAvailable: available,
            lastActiveAt: session.lastActiveAt.timeIntervalSince1970,
            isPinned: session.isPinned,
            isArchived: session.isArchived,
            isShared: RemoteAccessCoordinator.shared.hasSessionShares(session.id),
            terminalTheme: RemoteThemeBridge.terminalTheme(for: session.id),
            terminalThemeAssignmentID: ThemeAssignments
                .themeID(forSession: session.id)?
                .rawValue,
            inheritedTerminalThemeName: ThemeAssignments.inheritedName(forSession: session.id),
            inheritedTerminalTheme: RemoteThemeBridge.terminalTheme(
                ThemeAssignments.inheritedTheme(forSession: session.id)
            )
        )
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
                checkoutLabel: project.folderURL.lastPathComponent
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
                        defaultReasoningID: option.defaultReasoningLevel
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
                    let usage = AccountUsageService.shared.usage(for: account)
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
                        usageError: AccountUsageService.shared.errorMessage(for: account),
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
                supportsConversation: kind.supportsNativeUI
            )
        }

        return RemoteNewSessionCatalogDTO(projects: projects, agents: agents)
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
        if let controller = AgentRuntime.shared.controller(for: sessionID), controller.isRunning {
            return attachTerminal(
                connection,
                to: controller.session,
                sessionID: sessionID,
                capability: authorization.capability
            )
        }
        if let conversation = AgentRuntime.shared.conversation(for: sessionID),
           conversation.isRunning {
            return attachConversation(
                connection,
                to: conversation,
                sessionID: sessionID,
                authorization: authorization
            )
        }
        return false
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
            guard let authorization = connection.authorization,
                  predicate(authorization, connection.deviceID) else { continue }
            connection.sendText(message)
            count += 1
        }
        return count
    }

    private func attachTerminal(
        _ connection: RemoteConnection,
        to terminal: TerminalSession,
        sessionID: SessionID,
        capability: RemoteCapability
    ) -> Bool {
        beginCapturing(terminal, sessionID: sessionID)

        let key = ObjectIdentifier(connection)
        mirrors[sessionID]?.subscribers[key] = connection
        sessionByConnection[key] = sessionID

        let grid = terminal.characterGrid
        let hello = RemoteHelloDTO(
            surface: "terminal",
            capability: capability.rawValue,
            cols: grid.cols,
            rows: grid.rows,
            title: terminal.title,
            theme: RemoteThemeBridge.appTheme(),
            terminalTheme: RemoteThemeBridge.terminalTheme(for: sessionID)
        )
        connection.sendText(encode(hello))

        let snapshot = mirrors[sessionID]?.ring.snapshot() ?? Data()
        if !snapshot.isEmpty { connection.sendBinary(snapshot) }
        return true
    }

    private func attachConversation(
        _ connection: RemoteConnection,
        to conversation: ConversationViewController,
        sessionID: SessionID,
        authorization: RemoteAuthorization
    ) -> Bool {
        if mirrors[sessionID] == nil {
            mirrors[sessionID] = Mirror(
                // Conversation mirrors carry typed snapshots, not PTY history. The shared
                // mirror shape still owns a ring, kept at its smallest valid capacity.
                ring: RemoteRingBuffer(capacity: 1),
                surface: "conversation"
            )
        }

        let current = conversation.remoteSnapshot
        if mirrors[sessionID]?.conversationSnapshot != current {
            if mirrors[sessionID]?.subscribers.isEmpty == false {
                // Bring every already-attached viewer forward before the newcomer is inserted.
                // Mutating the shared baseline for only the newcomer would otherwise make a
                // pending broadcast look like a no-op and strand existing phones one revision
                // behind until some later event happened to expose the gap.
                broadcastConversation(sessionID)
            } else {
                var mirror = mirrors[sessionID]!
                mirror.conversationSnapshot = current
                mirror.conversationRevision &+= 1
                mirrors[sessionID] = mirror
            }
        }

        let key = ObjectIdentifier(connection)
        mirrors[sessionID]?.subscribers[key] = connection
        sessionByConnection[key] = sessionID
        connection.sendText(encode(RemoteHelloDTO(
            surface: "conversation",
            capability: authorization.capability.rawValue,
            cols: 0,
            rows: 0,
            title: ProjectStore.shared.session(withID: sessionID)?.displayTitle ?? "",
            theme: RemoteThemeBridge.appTheme(),
            terminalTheme: RemoteThemeBridge.terminalTheme(for: sessionID)
        )))
        let revision = mirrors[sessionID]?.conversationRevision ?? 0
        connection.sendText(encode(RemoteConversationWirePolicy.authorized(
            RemoteConversationWirePolicy.initial(current, revision: revision),
            for: authorization
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
        guard mirrors[sessionID]?.surface == "conversation",
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              let conversation = AgentRuntime.shared.conversation(for: sessionID) else {
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
        guard let authorization = connection.authorization,
              mirrors[sessionID]?.surface == "conversation",
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              let conversation = AgentRuntime.shared.conversation(for: sessionID) else {
            return
        }
        let current = conversation.remoteSnapshot
        if mirrors[sessionID]?.conversationSnapshot != current {
            broadcastConversation(sessionID)
        }
        let revision = mirrors[sessionID]?.conversationRevision ?? 0
        connection.sendText(encode(RemoteConversationWirePolicy.authorized(
            RemoteConversationWirePolicy.initial(current, revision: revision),
            for: authorization
        )))
    }

    func detach(_ connection: RemoteConnection) {
        let key = ObjectIdentifier(connection)
        themeEventSubscribers.removeValue(forKey: key)
        guard let sessionID = sessionByConnection.removeValue(forKey: key) else { return }
        broadcastPresence("idle", from: connection, sessionID: sessionID)
        releaseViewport(for: connection, sessionID: sessionID)
        mirrors[sessionID]?.subscribers.removeValue(forKey: key)
        if mirrors[sessionID]?.subscribers.isEmpty ?? true {
            // While Remote Access is enabled the ring keeps following a live terminal even with
            // no viewer. Otherwise reconnecting later would show only bytes produced after the
            // new socket attached — often an apparently blank TUI.
            let keepsTerminalCapture =
                mirrors[sessionID]?.surface == "terminal"
                && AppSettings.shared.remoteAccessEnabled
            if !keepsTerminalCapture {
                if mirrors[sessionID]?.surface == "terminal" {
                    removeTap(sessionID: sessionID)
                }
                mirrors[sessionID] = nil
            }
        }
    }

    /// Begins keeping the bounded terminal history as soon as a live surface exists, not only
    /// when the first phone connects. Existing screen contents seed the ring when access is
    /// enabled after a session has already been running.
    func beginCapturing(_ terminal: TerminalSession, sessionID: SessionID) {
        guard mirrors[sessionID] == nil else { return }
        var ring = RemoteRingBuffer(capacity: RemoteAccessDefaults.ringBufferBytes)
        // A synthesised repaint, not `getBufferAsData()`: that is plain text joined by bare line
        // feeds with blank cells as NUL, which a client renders as a staircase of run-together
        // words. See `RemoteScreenSeed`.
        ring.append(RemoteScreenSeed.repaint(of: terminal.terminalView.getTerminal()))
        mirrors[sessionID] = Mirror(ring: ring, surface: "terminal")
        installTap(on: terminal, sessionID: sessionID)
    }

    /// Called once the listener is ready, covering terminals that predate the setting change.
    func remoteAccessStarted() {
        for sessionID in AgentRuntime.shared.liveSessionIDs {
            guard RemoteSessionAccess.isVisible(
                ProjectStore.shared.session(withID: sessionID)
            ) else {
                continue
            }
            guard let controller = AgentRuntime.shared.controller(for: sessionID),
                  controller.isRunning else { continue }
            beginCapturing(controller.session, sessionID: sessionID)
        }
    }

    /// Releases idle capture as well as subscribers when the master switch is turned off.
    func remoteAccessStopped() {
        for sessionID in mirrors.keys where mirrors[sessionID]?.surface == "terminal" {
            AgentRuntime.shared.controller(for: sessionID)?.session.clearRemoteViewport()
            removeTap(sessionID: sessionID)
        }
        for work in pendingConversationBroadcasts.values { work.cancel() }
        pendingConversationBroadcasts.removeAll()
        mirrors.removeAll()
        sessionByConnection.removeAll()
        themeEventSubscribers.removeAll()
    }

    // MARK: - Input

    func sendInput(
        _ bytes: [UInt8],
        to sessionID: SessionID,
        device: String?,
        authorization: RemoteAuthorization
    ) {
        guard RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID)),
              let controller = AgentRuntime.shared.controller(for: sessionID),
              controller.isRunning else {
            return
        }
        let terminal = controller.session

        recordFirstInput(device: device, sessionID: sessionID)
        RemoteNotificationService.shared.recordInteraction(
            sessionID: sessionID,
            authorization: authorization
        )

        terminal.sendRemoteInput(bytes)
    }

    /// Records the visible grid of an interactive phone. This is a lease, not a preference:
    /// closing that view removes its request and restores the next controller or the Mac.
    func requestViewport(
        from connection: RemoteConnection,
        sessionID: SessionID,
        cols: Int,
        rows: Int
    ) {
        guard connection.authorization?.capability == .interact,
              (20...240).contains(cols),
              (4...160).contains(rows),
              mirrors[sessionID]?.surface == "terminal",
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              let controller = AgentRuntime.shared.controller(for: sessionID),
              controller.isRunning else {
            return
        }

        viewportSequence &+= 1
        mirrors[sessionID]?.viewportRequests[ObjectIdentifier(connection)] = ViewportRequest(
            cols: cols,
            rows: rows,
            sequence: viewportSequence
        )
        applyViewport(for: sessionID)
    }

    func releaseViewport(from connection: RemoteConnection, sessionID: SessionID) {
        releaseViewport(for: connection, sessionID: sessionID)
    }

    func submitPrompt(
        _ text: String,
        to sessionID: SessionID,
        device: String?,
        authorization: RemoteAuthorization
    ) {
        guard RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID)),
              let conversation = AgentRuntime.shared.conversation(for: sessionID),
              conversation.isRunning else {
            return
        }
        recordFirstInput(device: device, sessionID: sessionID)
        _ = conversation.sendRemotePrompt(text, authorization: authorization)
    }

    func updatePresence(
        _ state: String,
        from connection: RemoteConnection,
        sessionID: SessionID
    ) {
        guard state == "typing" || state == "idle",
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              connection.authorization?.capability == .interact else {
            return
        }
        broadcastPresence(state, from: connection, sessionID: sessionID)
    }

    /// Called after the native timeline changes. Provider-specific events are still folded only
    /// once on the Mac; the remote wire derives append/result deltas from that normalized state.
    /// Streaming providers can call this for every token, so updates are coalesced to one frame
    /// per display refresh.
    func sessionConversationChanged(_ sessionID: SessionID) {
        guard mirrors[sessionID]?.surface == "conversation",
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
        guard var mirror = mirrors[sessionID], mirror.surface == "conversation",
              let conversation = AgentRuntime.shared.conversation(for: sessionID) else { return }
        let current = conversation.remoteSnapshot
        let previous = mirror.conversationSnapshot
        guard previous != current else { return }

        let baseRevision = mirror.conversationRevision
        let revision = baseRevision &+ 1
        let delta = previous.flatMap {
            RemoteConversationWirePolicy.delta(
                from: $0,
                to: current,
                baseRevision: baseRevision,
                revision: revision
            )
        }
        mirror.conversationSnapshot = current
        mirror.conversationRevision = revision
        mirrors[sessionID] = mirror

        for connection in mirror.subscribers.values {
            guard let authorization = connection.authorization else { continue }
            if let delta {
                connection.sendText(encode(RemoteConversationWirePolicy.authorized(
                    delta,
                    for: authorization
                )))
            } else {
                connection.sendText(encode(RemoteConversationWirePolicy.authorized(
                    RemoteConversationWirePolicy.initial(current, revision: revision),
                    for: authorization
                )))
            }
        }
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

    /// Wakes every dashboard after a store mutation. The payload is only an invalidation:
    /// each connection re-fetches `/api/me`, where its own scope is applied.
    private func broadcastSessionsChanged() {
        let message = encode(RemoteSessionsChangedDTO())
        for connection in themeEventSubscribers.values {
            connection.sendText(message)
        }
    }

    func sessionSharingChanged() {
        broadcastSessionsChanged()
    }

    // MARK: - Session lifecycle

    /// Called by `AgentRuntime` when a session is discarded or the app is quitting: tells every
    /// watcher the mirror ended so the CLI is not left blocked and the client stops waiting.
    func sessionDiscarded(_ sessionID: SessionID) {
        pendingConversationBroadcasts.removeValue(forKey: sessionID)?.cancel()
        guard let mirror = mirrors[sessionID] else { return }
        AgentRuntime.shared.controller(for: sessionID)?.session.clearRemoteViewport()
        removeTap(sessionID: sessionID)
        let ended = encode(RemoteEndedDTO(reason: "sessionClosed"))
        for connection in mirror.subscribers.values {
            connection.sendText(ended)
            // `ended` is useful UI state, but it is not revocation. Closing the socket is what
            // prevents a client that ignores `ended` from typing into a later relaunch of the
            // same session id with its already-authenticated connection.
            connection.sendClose(code: RemoteWebSocket.CloseCode.goingAway, reason: "Session closed")
            sessionByConnection.removeValue(forKey: ObjectIdentifier(connection))
        }
        mirrors[sessionID] = nil
    }

    // MARK: - Private

    private func installTap(on terminal: TerminalSession, sessionID: SessionID) {
        terminal.onRawOutput = { data in
            // Fires on the main thread inside SwiftTerm's read hop; the async keeps the call
            // into this @MainActor class well-typed and preserves chunk order (main is FIFO).
            DispatchQueue.main.async {
                RemoteSessionMirrorRegistry.shared.broadcast(data, sessionID: sessionID)
            }
        }
    }

    private func removeTap(sessionID: SessionID) {
        AgentRuntime.shared.controller(for: sessionID)?.session.onRawOutput = nil
    }

    private func releaseViewport(for connection: RemoteConnection, sessionID: SessionID) {
        guard mirrors[sessionID]?.viewportRequests.removeValue(
            forKey: ObjectIdentifier(connection)
        ) != nil else { return }
        applyViewport(for: sessionID)
    }

    private func applyViewport(for sessionID: SessionID) {
        guard let terminal = AgentRuntime.shared.controller(for: sessionID)?.session else {
            return
        }
        let newest = mirrors[sessionID]?.viewportRequests.values.max {
            $0.sequence < $1.sequence
        }
        if let newest {
            terminal.setRemoteViewport(cols: newest.cols, rows: newest.rows)
        } else {
            terminal.clearRemoteViewport()
        }
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
        guard let authorization = connection.authorization,
              let mirror = mirrors[sessionID] else { return }
        let memberID = authorization.member?.id
            ?? "owner:\(connection.deviceID ?? "device")"
        let displayName = authorization.member?.displayName ?? "Owner"
        let message = encode(RemotePresenceDTO(
            memberID: memberID,
            displayName: displayName,
            state: state
        ))
        let source = ObjectIdentifier(connection)
        for (key, subscriber) in mirror.subscribers where key != source {
            subscriber.sendText(message)
        }
    }

    private func canManageThemes(_ authorization: RemoteAuthorization) -> Bool {
        authorization.canManageHost
    }

    private func canManageSessions(_ authorization: RemoteAuthorization) -> Bool {
        authorization.canManageHost
    }

    private func encode<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
