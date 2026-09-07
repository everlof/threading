import AppKit
import CryptoKit
import Foundation
import ThreadingPTYHostKit
import ThreadingRemoteKit

private enum RemoteTerminalHydrationDefaults {
    /// PTY programs do not expose a resize-repaint acknowledgement. Once the first output after
    /// SIGWINCH arrives, a short host-local quiet window closes that burst. Network pacing is
    /// deliberately outside this decision: the ready frame is queued behind the bytes.
    static let outputQuietDelay: Duration = .milliseconds(200)
    /// A foreground program may choose not to repaint after SIGWINCH. Do not leave that terminal
    /// hidden indefinitely when the host can already synthesize its authoritative screen.
    static let firstOutputMaximumDelay: Duration = .seconds(1)
    /// Continuous output still gets one bounded final seed and a visible terminal.
    static let maximumDelay: Duration = .seconds(3)
}

private enum RemoteSessionStartupDefaults {
    /// A provider can spend several seconds loading history before its surface becomes live. The
    /// wait is host-owned and bounded; no client catalogue size participates in this deadline.
    static let maximumWait: Duration = .seconds(60)
}

private enum RemoteAttachDiagnostics {
    static let sessionKind = "session"
    static let terminalKind = "terminal"
    static let nanosecondsPerMillisecond: UInt64 = 1_000_000
}

private enum RemoteCatalogueCacheDefaults {
    /// A structural invalidation is already coalesced for 350 ms on iOS. One second lets every
    /// authenticated owner request share the same host projection without turning the catalogue
    /// into durable state or hiding a later mutation for an unbounded interval.
    static let lifetime: Duration = .seconds(1)
}

/// The account-specific model projection shared by the remote catalogue and its regression tests.
/// `defaultReasoningID` means what this login will inherit for that model, not merely the model
/// cache's generic fallback. Older phones already consume this field, so fixing the projection
/// repairs their opening choice without requiring a wire-version branch.
@MainActor
enum RemoteNewSessionModelCatalog {
    static func choices(
        for kind: AgentKind,
        account: AgentAccount?
    ) -> [RemoteModelChoiceDTO] {
        AgentModels.visibleOptions(for: kind, account: account).map { option in
            RemoteModelChoiceDTO(
                id: option.identifier,
                name: option.displayName,
                reasoning: option.reasoningLevels.map {
                    RemoteReasoningChoiceDTO(id: $0.effort, name: $0.displayName)
                },
                defaultReasoningID: AgentModels.effectiveEffort(
                    selected: nil,
                    kind: kind,
                    model: option.identifier,
                    account: account
                ),
                supportsFastMode: AgentModels.supportsFastMode(
                    kind: kind,
                    model: option.identifier,
                    account: account
                )
            )
        }
    }
}

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

    private let terminalHydrationOutputQuietDelay: Duration
    private let terminalHydrationFirstOutputMaximumDelay: Duration
    private let terminalHydrationMaximumDelay: Duration
    private let sessionStartupMaximumWait: Duration
    /// Read at every release rather than cached, so a `defaults write` takes effect without a
    /// relaunch and a test can hand this registry milliseconds — or zero, which is the
    /// release-immediately behaviour the grace replaced.
    private let viewportLeaseGrace: @MainActor () -> Duration
    private let catalogueCacheLifetime: Duration
    private let catalogueCacheNow: @MainActor () -> ContinuousClock.Instant
    private let allSessionsCatalogueDidBuild: @MainActor () -> Void
    /// The Mac terminal selected in the local pane. It does not displace a phone that is still
    /// actively rendering, but it makes a departed phone's reconnect hold ineligible.
    private var locallyVisibleSessionID: SessionID?
    /// Sessions whose submitted line has been typed and whose Return has not followed yet.
    /// Keyed per PTY, because the window it guards is the PTY's, not any one client's.
    private var owedTerminalReturns: [SessionID: Task<Void, Never>] = [:]

    init(
        terminalApplication: (any RemoteTerminalApplicationCapability)? = nil,
        terminalHydrationOutputQuietDelay: Duration =
            RemoteTerminalHydrationDefaults.outputQuietDelay,
        terminalHydrationFirstOutputMaximumDelay: Duration =
            RemoteTerminalHydrationDefaults.firstOutputMaximumDelay,
        terminalHydrationMaximumDelay: Duration = RemoteTerminalHydrationDefaults.maximumDelay,
        sessionStartupMaximumWait: Duration = RemoteSessionStartupDefaults.maximumWait,
        viewportLeaseGrace: @escaping @MainActor () -> Duration = {
            .seconds(AppSettings.shared.remoteViewportLeaseGraceSeconds)
        },
        catalogueCacheLifetime: Duration = RemoteCatalogueCacheDefaults.lifetime,
        catalogueCacheNow: @escaping @MainActor () -> ContinuousClock.Instant = {
            ContinuousClock.now
        },
        allSessionsCatalogueDidBuild: @escaping @MainActor () -> Void = {}
    ) {
        self.terminalApplication = terminalApplication
        self.terminalHydrationOutputQuietDelay = terminalHydrationOutputQuietDelay
        self.terminalHydrationFirstOutputMaximumDelay =
            terminalHydrationFirstOutputMaximumDelay
        self.terminalHydrationMaximumDelay = terminalHydrationMaximumDelay
        self.sessionStartupMaximumWait = sessionStartupMaximumWait
        self.viewportLeaseGrace = viewportLeaseGrace
        self.catalogueCacheLifetime = catalogueCacheLifetime
        self.catalogueCacheNow = catalogueCacheNow
        self.allSessionsCatalogueDidBuild = allSessionsCatalogueDidBuild
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
        // Account presentation and availability already live in `/api/me`; model visibility now
        // does too. Treat a preference edit as a catalogue invalidation so a connected phone
        // refetches immediately instead of keeping a model the Mac just withdrew until reconnect.
        appEvents.observe(AccountPreferencesDidChange.self) { [weak self] _ in
            self?.broadcastSessionsChanged(ProjectsDidChange())
        }
        appEvents.observe(AgentModelsDidChange.self) { [weak self] _ in
            self?.broadcastSessionsChanged(ProjectsDidChange())
        }
        // Receipt commits have their own narrow edge. The broad presentation event remains for
        // local UI, but the remote catalogue no longer guesses whether it meant runtime or read.
        appEvents.observe(SessionAttentionDidChange.self) { [weak self] event in
            self?.broadcastSessionRow(event.sessionID)
        }
        // Runtime is live row state too. Receipt changes do not use this edge, so every typed
        // runtime transition — including a continuation-kind-only change — publishes exactly once.
        appEvents.observe(SessionRuntimeDidChange.self) { [weak self] event in
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

    private struct MeCatalogue {
        let sessions: [RemoteSessionSummaryDTO]
        let terminals: [RemoteProjectTerminalSummaryDTO]
        let host: RemoteHostDTO
        let theme: RemoteThemeDTO
        let themeCatalog: RemoteThemeCatalogDTO?
        let archivedSessions: [RemoteSessionSummaryDTO]?
        let newSessionCatalog: RemoteNewSessionCatalogDTO?
        let features: [String]?
    }

    private struct CachedMeCatalogue {
        let value: MeCatalogue
        let expiresAt: ContinuousClock.Instant
    }

    /// Owner devices all receive the same expensive catalogue projection. The boolean separates
    /// the ordinary interactive owner from any deliberately read-only owner authorization a test
    /// or future caller constructs. Exact-session guests use indexed lookup and never enter this
    /// all-session cache.
    private var allSessionsCatalogueCache: [Bool: CachedMeCatalogue] = [:]

    /// The catalogue edition, advanced by every invalidation and minted fresh per process so a
    /// phone that remembers one from before a relaunch is answered in full rather than `304`.
    private let catalogueEpoch = RemoteCatalogueRevisionDTO.newEpoch()
    private var catalogueRevisionNumber: UInt64 = 1

    /// Encoded `/api/me` bodies for the current edition; see `RemoteMeResponseCache`.
    private var meResponseCache = RemoteMeResponseCache()

    private struct Mirror {
        var ring: RemoteRingBuffer
        let surface: RemoteSessionSurface
        var subscribers: [ObjectIdentifier: RemoteConnection] = [:]
        /// Complete provider-neutral state and its live wire revision. The complete rows stay
        /// on the Mac; clients receive only a recent window plus requested older pages.
        var conversationSnapshot: RemoteConversationSnapshotDTO? = nil
        var conversationRowsRevision: RemoteConversationRowsRevision? = nil
        var conversationRevision = 0
        var runPlan: RunProgress? = nil
        var runPlanRevision = 0
        /// Devices that have already sent input, so the "first remote input" audit line is
        /// written once per device+session rather than per keystroke.
        var inputSeenDevices: Set<String> = []
        /// Interactive clients that currently have a terminal view on screen, plus the ones
        /// that have just left and may come straight back. They share one PTY, so the grid
        /// applied is the largest one all of them can display — see `applyViewport`.
        var viewportLeases = ViewportLeases()
    }

    private struct ViewportRequest {
        let cols: Int
        let rows: Int
    }

    /// A lease whose client has gone, still counted by `resolvedViewport` until its grace
    /// expires. See `releaseViewport(for:target:)` for why it exists.
    private struct HeldViewportLease {
        let cols: Int
        let rows: Int
        /// The releasing peer's authorization, kept so a later permission change can *narrow*
        /// this lease away. It is read for exactly one question — may this device still
        /// write? — and a `false` drops the lease. It never admits input, keeps a subscriber,
        /// answers a permission prompt, or grants anything at all: a grace is a grid, not an
        /// access.
        let authorization: RemoteAuthorization
        let expiry: Task<Void, Never>
    }

    /// Every grid one shared PTY is currently answering to.
    ///
    /// `active` is keyed by connection because that is the identity of a socket; `held` is keyed
    /// by **device**, because a phone that comes back is a new `RemoteConnection` object and
    /// would otherwise fail to match its own pending release — which is precisely the case the
    /// grace exists for.
    private struct ViewportLeases {
        var active: [ObjectIdentifier: ViewportRequest] = [:]
        var held: [String: HeldViewportLease] = [:]

        /// What `resolvedViewport` intersects. A held lease counts exactly like a live one,
        /// which is what makes a return inside the window cost zero resizes.
        var grids: [(cols: Int, rows: Int)] {
            active.values.map { (cols: $0.cols, rows: $0.rows) }
                + held.values.map { (cols: $0.cols, rows: $0.rows) }
        }

        func cancelExpiries() {
            for lease in held.values {
                lease.expiry.cancel()
            }
        }

        mutating func dropHeld() {
            cancelExpiries()
            held.removeAll()
        }
    }

    /// One shared PTY a viewport lease can be held against.
    ///
    /// Agent sessions and standalone project terminals answer the same lease rules, so the grace
    /// period is written once against this rather than twice against two mirror types.
    private enum ViewportLeaseTarget: Hashable {
        case session(SessionID)
        case terminal(TerminalID)
    }

    /// Why one live viewport stopped owning the shared PTY grid.
    ///
    /// A transport loss may be a momentary background/foreground round trip, so it keeps the
    /// reconnect grace. An explicit release or parked chat is the renderer saying it has left;
    /// keeping that grid would make the Mac remain at phone size after the phone is gone.
    private enum ViewportLeaseRelease {
        case reconnectGrace
        case immediate
    }

    private struct ProjectTerminalMirror {
        var ring: RemoteRingBuffer
        var subscribers: [ObjectIdentifier: RemoteConnection] = [:]
        var inputSeenDevices: Set<String> = []
        var viewportLeases = ViewportLeases()
    }

    enum InitialSessionAttach {
        case attached
        case waitingForStartup
        case unavailable
    }

    private struct StartupWaiter {
        let connection: RemoteConnection
        let authorization: RemoteAuthorization
        let authorizationIsCurrent: () -> Bool
        let didAttach: () -> Void
    }

    private struct StartingSession {
        var waiters: [ObjectIdentifier: StartupWaiter] = [:]
        var expiry: Task<Void, Never>?
    }

    /// One socket's initial replay plus first phone-owned resize. The external terminal program
    /// has no repaint-finished API, so the Mac observes its first post-SIGWINCH output burst,
    /// takes one final authoritative screen seed, and then puts an ordered ready frame on this
    /// socket. Holding this state on the host is what keeps Wi-Fi packet gaps out of presentation.
    private final class TerminalHydrationTransaction {
        let requestID: String
        let sessionID: SessionID
        let connection: RemoteConnection
        var quietTask: Task<Void, Never>?
        var firstOutputTask: Task<Void, Never>?
        var maximumTask: Task<Void, Never>?

        init(requestID: String, sessionID: SessionID, connection: RemoteConnection) {
            self.requestID = requestID
            self.sessionID = sessionID
            self.connection = connection
        }

        func cancel() {
            quietTask?.cancel()
            firstOutputTask?.cancel()
            maximumTask?.cancel()
        }
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
    /// Sessions whose create/resume transaction owns producing a live surface. Authenticated
    /// sockets wait here and receive the ordinary hello from `attach` once that surface exists.
    private var startingSessions: [SessionID: StartingSession] = [:]
    private var startupSessionByConnection: [ObjectIdentifier: SessionID] = [:]
    private var themeEventSubscribers: [ObjectIdentifier: RemoteConnection] = [:]
    private var catalogueStreamIDs: [ObjectIdentifier: String] = [:]
    private var catalogueStreamSequences: [ObjectIdentifier: UInt64] = [:]
    private var pendingConversationBroadcasts: [SessionID: DispatchWorkItem] = [:]
    private var latestWorkspaceActivity: [SessionID: RemoteWorkspaceChangedDTO] = [:]
    private var terminalHydrations: [ObjectIdentifier: TerminalHydrationTransaction] = [:]

    // MARK: - REST

    /// Which edition of the catalogue `/api/me` describes right now.
    var catalogueRevision: RemoteCatalogueRevisionDTO {
        RemoteCatalogueRevisionDTO(epoch: catalogueEpoch, revision: catalogueRevisionNumber)
    }

    /// The main-actor half of answering `/api/me`: the projection, plus the encoded body if one
    /// was already produced for this authorization at this edition.
    ///
    /// The payload is built here because everything it reads is main-actor state. Nothing here
    /// encodes: a caller that finds `encoded` nil hands `payload` to a worker and stores the
    /// result with `storeMeResponse`, so the next device asking for the same edition pays
    /// neither the projection nor the encoder.
    func meResponseSnapshot(for authorization: RemoteAuthorization) -> RemoteMeResponseSnapshot {
        let revision = catalogueRevision
        let key = RemoteMeResponseKey(authorization)
        if let encoded = meResponseCache.response(for: key, revision: revision) {
            return RemoteMeResponseSnapshot(payload: nil, encoded: encoded, revision: revision)
        }
        return RemoteMeResponseSnapshot(
            payload: meResponse(for: authorization),
            encoded: nil,
            revision: revision
        )
    }

    /// Remembers a body a worker encoded. Dropped if the catalogue moved while it was encoding.
    func storeMeResponse(
        _ encoded: RemoteMeEncodedResponse,
        for authorization: RemoteAuthorization
    ) {
        meResponseCache.store(
            encoded,
            for: RemoteMeResponseKey(authorization),
            revision: catalogueRevision
        )
    }

    /// The `/api/me` payload: the share, and the live sessions it reaches.
    func meResponse(for authorization: RemoteAuthorization) -> RemoteMeDTO {
        let catalogue = meCatalogue(for: authorization)

        let scopeName: RemoteShareScope
        switch authorization.scope {
        case .allSessions: scopeName = .all
        case .session: scopeName = .session
        case .projectTerminal: scopeName = .terminal
        }

        return RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(
                label: authorization.shareID,
                scope: scopeName,
                capability: RemoteAdvertisedCapability(authorization.capability),
                canApprovePermissions: authorization.canApprovePermissions,
                expiresAt: authorization.expiresAt?.timeIntervalSince1970,
                memberID: authorization.member?.id,
                displayName: authorization.member?.displayName
            ),
            sessions: catalogue.sessions,
            terminals: catalogue.terminals,
            host: catalogue.host,
            theme: catalogue.theme,
            themeCatalog: catalogue.themeCatalog,
            archivedSessions: catalogue.archivedSessions,
            newSessionCatalog: catalogue.newSessionCatalog,
            features: catalogue.features,
            revision: catalogueRevision
        )
    }

    private func meCatalogue(for authorization: RemoteAuthorization) -> MeCatalogue {
        switch authorization.scope {
        case .allSessions:
            return allSessionsCatalogue(for: authorization)
        case let .session(sessionID):
            guard let session = ProjectStore.shared.session(withID: sessionID),
                  let project = ProjectStore.shared.project(forSessionID: sessionID),
                  RemoteSessionAccess.isVisible(session)
            else {
                return makeMeCatalogue(
                    sessions: [],
                    terminals: [],
                    archivedSessions: nil,
                    newSessionCatalog: nil,
                    authorization: authorization
                )
            }
            return makeMeCatalogue(
                sessions: [summary(
                    for: session,
                    projectID: project.id,
                    projectName: project.name,
                    projectLimitRecovery: project.limitRecoveryPolicy,
                    authorization: authorization
                )],
                terminals: [],
                archivedSessions: nil,
                newSessionCatalog: nil,
                authorization: authorization
            )
        case let .projectTerminal(terminalID):
            guard let terminal = ProjectStore.shared.terminal(withID: terminalID) else {
                return makeMeCatalogue(
                    sessions: [],
                    terminals: [],
                    archivedSessions: nil,
                    newSessionCatalog: nil,
                    authorization: authorization
                )
            }
            let project = ProjectStore.shared.homeProject(forTerminalID: terminalID)
            return makeMeCatalogue(
                sessions: [],
                terminals: [terminalSummary(
                    for: terminal,
                    projectID: project?.id,
                    projectName: project?.name ?? ""
                )],
                archivedSessions: nil,
                newSessionCatalog: nil,
                authorization: authorization
            )
        }
    }

    private func allSessionsCatalogue(
        for authorization: RemoteAuthorization
    ) -> MeCatalogue {
        let managesSessions = canManageSessions(authorization)
        let now = catalogueCacheNow()
        if authorization.principal == .ownerDevice,
           let cached = allSessionsCatalogueCache[managesSessions],
           cached.expiresAt > now
        {
            return cached.value
        }

        allSessionsCatalogueDidBuild()
        let value = buildAllSessionsCatalogue(
            authorization: authorization,
            managesSessions: managesSessions
        )
        if authorization.principal == .ownerDevice {
            allSessionsCatalogueCache[managesSessions] = CachedMeCatalogue(
                value: value,
                // Start freshness after projection. A 5,000-row cold build can itself exceed
                // the cache lifetime; expiring from its start would make every queued owner
                // rebuild it again, recreating the fan-out this cache bounds.
                expiresAt: catalogueCacheNow() + catalogueCacheLifetime
            )
        }
        return value
    }

    private func buildAllSessionsCatalogue(
        authorization: RemoteAuthorization,
        managesSessions: Bool
    ) -> MeCatalogue {
        let sessions = ProjectStore.shared.projects
            .flatMap { project in
                project.sessions
                    .filter { RemoteSessionAccess.isVisible($0) }
                    .map {
                        summary(
                            for: $0,
                            projectID: project.id,
                            projectName: project.name,
                            projectLimitRecovery: project.limitRecoveryPolicy,
                            authorization: authorization
                        )
                    }
            }
            .sorted(by: summaryOrder)
        let terminals = ProjectStore.shared.projects
            .flatMap { project in
                project.terminals.map {
                    terminalSummary(
                        for: $0,
                        projectID: project.id,
                        projectName: project.name
                    )
                }
            }
            .sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
        let archived = managesSessions
            ? ProjectStore.shared.archivedSessions()
            .map {
                summary(
                    for: $0.session,
                    projectID: $0.project.id,
                    projectName: $0.project.name,
                    projectLimitRecovery: $0.project.limitRecoveryPolicy,
                    authorization: authorization
                )
            }
            .sorted(by: summaryOrder)
            : nil
        return makeMeCatalogue(
            sessions: sessions,
            terminals: terminals,
            archivedSessions: archived,
            newSessionCatalog: managesSessions ? newSessionCatalog() : nil,
            authorization: authorization
        )
    }

    private func makeMeCatalogue(
        sessions: [RemoteSessionSummaryDTO],
        terminals: [RemoteProjectTerminalSummaryDTO],
        archivedSessions: [RemoteSessionSummaryDTO]?,
        newSessionCatalog: RemoteNewSessionCatalogDTO?,
        authorization: RemoteAuthorization
    ) -> MeCatalogue {
        MeCatalogue(
            sessions: sessions,
            terminals: terminals,
            host: RemoteAccessCoordinator.shared.hostIdentity(for: authorization),
            theme: RemoteThemeBridge.appTheme(),
            themeCatalog: canManageThemes(authorization) ? RemoteThemeBridge.catalog() : nil,
            archivedSessions: archivedSessions,
            newSessionCatalog: newSessionCatalog,
            features: restFeatures(for: authorization)
        )
    }

    private func invalidateMeCatalogue() {
        allSessionsCatalogueCache.removeAll(keepingCapacity: true)
        catalogueRevisionNumber &+= 1
        meResponseCache.removeAll()
    }

    /// One already-authorised catalogue row for an O(changed) mutation response.
    func sessionSummary(
        for sessionID: SessionID,
        authorization: RemoteAuthorization
    ) -> RemoteSessionSummaryDTO? {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              let project = ProjectStore.shared.project(forSessionID: sessionID),
              RemoteSessionAccess.isVisible(session),
              authorization.scope.covers(sessionID) else { return nil }
        return summary(
            for: session,
            projectID: project.id,
            projectName: project.name,
            projectLimitRecovery: project.limitRecoveryPolicy,
            authorization: authorization
        )
    }

    private func terminalSummary(
        for terminal: ProjectTerminal,
        projectID: ProjectID?,
        projectName: String
    ) -> RemoteProjectTerminalSummaryDTO {
        let running = ProjectTerminalRuntime.shared.isRunning(terminalID: terminal.id)
        let busy = running && ProjectTerminalRuntime.shared.isBusy(terminalID: terminal.id)
        return RemoteProjectTerminalSummaryDTO(
            id: terminal.id.uuidString,
            title: ProjectTerminalTitle.displayTitle(for: terminal),
            projectName: projectName,
            projectID: projectID?.uuidString,
            state: running ? (busy ? .working : .idle) : .dormant,
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
        if authorization.canUseUniversalSearch {
            features.append(RemoteRESTFeature.universalSearch.rawValue)
        }
        if authorization.canReadHostUsage {
            features.append(RemoteRESTFeature.usageDashboard.rawValue)
        }
        if authorization.canManageHost,
           RemoteAccessCoordinator.shared.canIssueHostedDeviceCredentials
        {
            features.append(RemoteRESTFeature.hostedPeerTransport.rawValue)
        }
        // The thumbnail route is gated exactly like the attachment route it shrinks, so it is
        // advertised to whoever may read attachments at all.
        features.append(RemoteRESTFeature.attachmentThumbnails.rawValue)
        features.append(RemoteRESTFeature.attachmentVideoStreaming.rawValue)
        features.append(RemoteRESTFeature.sessionStartupHandshake.rawValue)
        if authorization.canManageHost {
            features.append(RemoteRESTFeature.reportSessionOpening.rawValue)
            features.append(RemoteRESTFeature.sessionDraftAttachmentUploads.rawValue)
            features.append(RemoteRESTFeature.sessionContinuation.rawValue)
        }
        return features.isEmpty ? nil : features
    }

    private func summary(
        for session: AgentSession,
        projectID: ProjectID,
        projectName: String,
        projectLimitRecovery: LimitRecoveryPolicy?,
        authorization: RemoteAuthorization
    ) -> RemoteSessionSummaryDTO {
        let available = AgentRuntime.shared.isRunning(sessionID: session.id)
        let runtime = AgentRuntime.shared.runtimeSnapshot(sessionID: session.id)
        let participantID = authorization.collaborationParticipantID
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
            state: RemoteSessionActivity(AgentRuntime.shared.activity(
                sessionID: session.id,
                participantID: participantID
            )),
            attention: RemoteSessionAttentionDTO(AgentRuntime.shared.attention(
                sessionID: session.id,
                participantID: participantID
            )),
            continuation: RemoteSessionContinuation(runtime.continuation),
            projectName: projectName,
            projectID: projectID.uuidString,
            isAvailable: available,
            lastActiveAt: session.lastActiveAt.timeIntervalSince1970,
            isPinned: session.isPinned,
            isArchived: session.isArchived,
            archivedAt: session.archivedAt?.timeIntervalSince1970,
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
                : nil,
            model: session.model
        )
    }

    private func remoteLimitRecovery(
        _ policy: LimitRecoveryPolicy
    ) -> RemoteLimitRecoveryPolicyDTO {
        switch policy {
        case .flagOnly:
            return .flagOnly
        case .waitForReset:
            return .waitForReset
        case .resumeOnBestAccount:
            return .resumeOnBestAccount
        case let .resumeVia(accountID):
            return .resumeVia(accountID: accountID.handle.name)
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

        var publishedImageIDs: Set<String> = []
        var remainingImageBytes = 2 * 1024 * 1024
        let agents = AgentKind.allCases.map { kind in
            let discoveredAccounts = AgentAccountDiscovery.accounts(for: kind)
            let accountNames = AccountName.names(for: AgentAccountDiscovery.allAccounts(for: kind))

            let accounts: [RemoteAccountChoiceDTO]
            if discoveredAccounts.isEmpty {
                accounts = [
                    RemoteAccountChoiceDTO(
                        id: AccountHandle.standardName,
                        name: AgentAccountDefaults.defaultDisplayName,
                        models: RemoteNewSessionModelCatalog.choices(for: kind, account: nil),
                        defaultModelID: AgentModels.defaultModel(for: kind, account: nil)
                    ),
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
                    let modelChoices = RemoteNewSessionModelCatalog.choices(
                        for: kind,
                        account: account
                    )
                    var images: [String: Data] = [:]
                    for (id, data) in RemoteAccountBridge.images(for: account) {
                        guard !publishedImageIDs.contains(id), data.count <= remainingImageBytes else { continue }
                        publishedImageIDs.insert(id)
                        remainingImageBytes -= data.count
                        images[id] = data
                    }
                    return RemoteAccountChoiceDTO(
                        id: account.handle.name,
                        name: accountNames[account.id] ?? account.displayName,
                        email: RemoteAccountBridge.email(for: account),
                        emoji: account.emoji,
                        presentation: RemoteAccountBridge.identity(for: account, surface: .chooser),
                        appearances: RemoteAccountBridge.appearances(for: account),
                        images: images,
                        usageSummary: usage?.compactSummary(metering: model),
                        usageFraction: usage?.bindingWindow(metering: model)?.fraction,
                        usageError: reading.error?.message,
                        // Every window, scoped ones with the models they meter, so the phone
                        // can ring a chat's *own* model rather than the account's default.
                        usageWindows: usage.map {
                            RemoteAccountBridge.usageWindows(
                                for: $0,
                                modelChoices: modelChoices.map(\.id)
                            )
                        },
                        models: modelChoices,
                        defaultModelID: model
                    )
                }
            }

            let defaultAccount = discoveredAccounts.first(where: \.isDefault)
                ?? discoveredAccounts.first
            return RemoteAgentChoiceDTO(
                id: kind.rawValue,
                name: kind.displayName,
                accounts: accounts,
                models: RemoteNewSessionModelCatalog.choices(
                    for: kind,
                    account: defaultAccount
                ),
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

        return RemoteNewSessionCatalogDTO(
            projects: projects,
            agents: agents,
            supportsManagerRole: true
        )
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
                    delivery: RemoteManagedWorkspaceDelivery(rawValue: $0.delivery.rawValue),
                    publication: $0.publication.map {
                        RemoteManagedWorkspacePublication(rawValue: $0.rawValue)
                    }
                )
            }
        )
    }

    // MARK: - Subscription

    /// Marks the interval between a durable row being accepted and its live surface existing.
    /// The marker belongs to the host transaction, so a client cannot make an arbitrary dormant
    /// session wait indefinitely merely by opening its socket.
    func noteSessionStarting(_ sessionID: SessionID) {
        guard startingSessions[sessionID] == nil else { return }
        var starting = StartingSession()
        let maximumWait = sessionStartupMaximumWait
        starting.expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: maximumWait)
            guard !Task.isCancelled else { return }
            self?.expireSessionStartup(sessionID)
        }
        startingSessions[sessionID] = starting
    }

    /// Attaches now, waits only when a host-owned startup transaction names this session, or
    /// refuses it. Waiting sends an immediate progress frame and later completes through the
    /// exact same `attach` path as every ordinary session socket.
    func attachOrWaitForStartup(
        _ connection: RemoteConnection,
        to sessionID: SessionID,
        authorization: RemoteAuthorization,
        authorizationIsCurrent: @escaping () -> Bool,
        didAttach: @escaping () -> Void
    ) -> InitialSessionAttach {
        if attach(connection, to: sessionID, authorization: authorization) {
            didAttach()
            // The surface may have become attachable before its normal readiness callback ran.
            // Complete any older waiters through the same attach path and retire an otherwise
            // empty startup marker instead of keeping it alive until the timeout.
            attachStartupWaiters(sessionID)
            if let starting = startingSessions[sessionID], starting.waiters.isEmpty {
                starting.expiry?.cancel()
                startingSessions[sessionID] = nil
            }
            return .attached
        }
        guard var starting = startingSessions[sessionID],
              RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID))
        else {
            return .unavailable
        }
        let key = ObjectIdentifier(connection)
        starting.waiters[key] = StartupWaiter(
            connection: connection,
            authorization: authorization,
            authorizationIsCurrent: authorizationIsCurrent,
            didAttach: didAttach
        )
        startingSessions[sessionID] = starting
        startupSessionByConnection[key] = sessionID
        connection.sendText(encode(RemoteSessionStartingDTO()))
        return .waitingForStartup
    }

    private func attachStartupWaiters(_ sessionID: SessionID) {
        guard var starting = startingSessions[sessionID], !starting.waiters.isEmpty else {
            return
        }
        var remaining: [ObjectIdentifier: StartupWaiter] = [:]
        var attachedAny = false
        for (key, waiter) in starting.waiters {
            startupSessionByConnection[key] = nil
            guard waiter.authorizationIsCurrent() else {
                waiter.connection.sendClose(code: 4003, reason: "Share revoked")
                continue
            }
            if attach(
                waiter.connection,
                to: sessionID,
                authorization: waiter.authorization
            ) {
                attachedAny = true
                waiter.didAttach()
            } else {
                remaining[key] = waiter
                startupSessionByConnection[key] = sessionID
            }
        }
        starting.waiters = remaining
        if remaining.isEmpty {
            starting.expiry?.cancel()
            startingSessions[sessionID] = nil
        } else {
            startingSessions[sessionID] = starting
        }
        if attachedAny { broadcastSessionRow(sessionID) }
    }

    private func expireSessionStartup(_ sessionID: SessionID) {
        guard let starting = startingSessions.removeValue(forKey: sessionID) else { return }
        for (key, waiter) in starting.waiters {
            startupSessionByConnection[key] = nil
            // Startup exhaustion is terminal for this route, not a healthy-socket action
            // refusal. `ended` prevents the client from reconnecting to a marker the host has
            // deliberately retired and replacing the concrete failure with transport noise.
            waiter.connection.sendText(encode(RemoteEndedDTO(reason: "sessionStartupTimedOut")))
            waiter.connection.sendClose(code: 4004, reason: "Session startup timed out")
        }
    }

    private func cancelSessionStartup(_ sessionID: SessionID, reason: String) {
        guard let starting = startingSessions.removeValue(forKey: sessionID) else { return }
        starting.expiry?.cancel()
        for (key, waiter) in starting.waiters {
            startupSessionByConnection[key] = nil
            waiter.connection.sendText(encode(RemoteEndedDTO(reason: "sessionClosed")))
            waiter.connection.sendClose(code: 4004, reason: reason)
        }
    }

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
        let attachStartedAt = DispatchTime.now()
        defer {
            recordAttachEnded(
                kind: RemoteAttachDiagnostics.sessionKind,
                id: sessionID.uuidString,
                connection: connection,
                startedAt: attachStartedAt
            )
        }
        var attached = attachTerminal(
            connection,
            sessionID: sessionID,
            capability: authorization.capability
        )
        if !attached,
           let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID),
           conversation.isRunning
        {
            attached = attachConversation(
                connection,
                to: conversation,
                sessionID: sessionID,
                authorization: authorization
            )
        }
        guard attached else { return false }
        let acknowledgement = AgentRuntime.shared.acknowledgeAttention(
            sessionID: sessionID,
            participantID: authorization.collaborationParticipantID
        )
        if let session = sessionSummary(for: sessionID, authorization: authorization) {
            connection.sendText(encode(RemoteSessionVisitedDTO(
                session: session,
                revision: catalogueRevision,
                receiptCommitted: acknowledgement.persistence == .committed
            )))
        }
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
        let attachStartedAt = DispatchTime.now()
        defer {
            recordAttachEnded(
                kind: RemoteAttachDiagnostics.terminalKind,
                id: terminalID.uuidString,
                connection: connection,
                startedAt: attachStartedAt
            )
        }

        let key = ObjectIdentifier(connection)
        terminalMirrors[terminalID]?.subscribers[key] = connection
        terminalByConnection[key] = terminalID
        connection.sendText(encode(RemoteHelloDTO(
            surface: .terminal,
            capability: RemoteAdvertisedCapability(authorization.capability),
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
        case let .whole(ring): connection.sendBinary(ring)
        case let .cut(tail): connection.sendBinary(tail)
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
            if case let .captured(fresh) = self.terminalApplication?.currentSnapshot(
                for: terminalID
            ) {
                connection.sendBinary(fresh.screenSeed)
                modes = fresh.modes
            }
            connection.sendBinary(RemoteTerminalModeSeed.bytes(for: modes))
        }
        return true
    }

    /// What the host spent attaching one socket: from admission to the hello and the bounded
    /// replay being handed to the connection. The phone measured 1.9 s and 2.5 s to enter a
    /// terminal on 5 Sep 2026 and could only say the wait was "around admission and replay";
    /// the host recorded no duration of its own. This is the number that says whether that
    /// time was spent here — a ring snapshot and a capture on the main actor — or on the wire.
    private func recordAttachEnded(
        kind: String,
        id: String,
        connection: RemoteConnection,
        startedAt: DispatchTime
    ) {
        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds
        var fields: [RemoteDiagnosticField: String] = [
            .kind: kind,
            .session: MacRemoteDiagnostics.pseudonym(id, prefix: "session"),
            .durationMS: String(elapsed / RemoteAttachDiagnostics.nanosecondsPerMillisecond),
            .transport: "websocket",
        ]
        if let device = connection.authenticatedPeer?.deviceID {
            fields[.peer] = MacRemoteDiagnostics.pseudonym(device, prefix: "device")
        }
        MacRemoteDiagnostics.record(.terminalAttachEnded, fields: fields)
    }

    /// Subscribes a dashboard to app-chrome changes without binding it to a particular session.
    /// The first frame is authoritative too, closing the race between `/api/me` and socket auth.
    func attachThemeEvents(_ connection: RemoteConnection) {
        let key = ObjectIdentifier(connection)
        themeEventSubscribers[key] = connection
        let streamID = UUID().uuidString
        catalogueStreamIDs[key] = streamID
        catalogueStreamSequences[key] = 0
        if let peer = connection.authenticatedPeer {
            RemoteNotificationService.shared.foregroundDeviceAttached(
                shareID: peer.authorization.shareID,
                participantID: peer.authorization.member.map { .member($0.id) } ?? .owner,
                deviceID: peer.deviceID ?? "socket-\(key.hashValue)"
            )
        }
        // Registration and the edition capture are one main-actor transaction. The client can
        // now prove that its REST snapshot meets this stream or refresh before trusting it.
        connection.sendText(encode(RemoteCatalogueStreamHelloDTO(
            streamID: streamID,
            revision: catalogueRevision
        )))
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

    /// Retractions are a separate typed frame so an older client safely ignores them and a new
    /// client never has to infer recall from alert copy or stringly-typed event comparisons.
    @discardableResult
    func broadcastNotificationRetraction(
        _ retraction: RemoteNotificationRetractionDTO,
        matching predicate: (RemoteAuthorization, String?) -> Bool
    ) -> Int {
        let message = encode(retraction)
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
            case .composerAttachmentUploads, .terminalAttachmentInsertion:
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
            capability: RemoteAdvertisedCapability(capability),
            cols: snapshot.grid.cols,
            rows: snapshot.grid.rows,
            title: snapshot.title,
            theme: RemoteThemeBridge.appTheme(),
            terminalTheme: RemoteThemeBridge.terminalTheme(for: sessionID),
            features: Self.advertisedFeatures(for: connection.authorization)
        )
        connection.sendText(encode(hello))
        sendCurrentRunPlan(to: connection, sessionID: sessionID)
        sendLatestWorkspaceActivity(to: connection, sessionID: sessionID)

        let ringSnapshot = mirrors[sessionID]?.ring.snapshot() ?? Data()
        let budget = connection.authenticatedPeer?.terminalReplayBudget
        let replay = Self.terminalReplay(ring: ringSnapshot, budget: budget)
        switch replay {
        case .nothing:
            break
        case let .whole(ring):
            connection.sendBinary(ring)
        case let .cut(tail):
            connection.sendBinary(tail)
        }

        guard case .cut = replay, let budget else {
            // After the ring rather than before it. The ring is replayed history: it can arm
            // mouse tracking the program has since dropped, and — far more often — it holds no
            // arming sequence at all, because a TUI sends that once at startup and 512 KB of
            // output rolled it away. The statement is what is true now, so it has to be the
            // last word.
            connection.sendBinary(RemoteTerminalModeSeed.bytes(for: snapshot.modes))
            if capability == .view {
                connection.sendText(encode(RemoteTerminalReadyDTO()))
            }
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
            if case let .captured(fresh) =
                self.terminalApplication?.currentSnapshot(for: sessionID)
            {
                connection.sendBinary(fresh.screenSeed)
                modes = fresh.modes
            }
            // Stated even when the terminal has gone in the meantime: a client that attached to
            // a live session must not be left wearing whatever modes the tail happened to arm.
            connection.sendBinary(RemoteTerminalModeSeed.bytes(for: modes))
            if capability == .view {
                connection.sendText(self.encode(RemoteTerminalReadyDTO()))
            }
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
            capability: RemoteAdvertisedCapability(authorization.capability),
            cols: 0,
            rows: 0,
            title: ProjectStore.shared.session(withID: sessionID)?.displayTitle ?? "",
            theme: RemoteThemeBridge.appTheme(),
            terminalTheme: RemoteThemeBridge.terminalTheme(for: sessionID),
            features: Self.advertisedFeatures(for: authorization)
        )))
        sendCurrentRunPlan(to: connection, sessionID: sessionID)
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
              let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID)
        else {
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
              let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID)
        else {
            return
        }
        let projection = conversation.remoteProjection
        let current = projection.snapshot
        if mirrors[sessionID]?.conversationRowsRevision != projection.rowsRevision
            || mirrors[sessionID]?.conversationSnapshot.map({
                !Self.sameConversationMetadata($0, current)
            }) ?? true
        {
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
        detach(connection, viewportRelease: .reconnectGrace)
    }

    private func detach(
        _ connection: RemoteConnection,
        viewportRelease: ViewportLeaseRelease
    ) {
        let key = ObjectIdentifier(connection)
        if let startupSessionID = startupSessionByConnection.removeValue(forKey: key),
           var starting = startingSessions[startupSessionID]
        {
            starting.waiters[key] = nil
            startingSessions[startupSessionID] = starting
        }
        cancelTerminalHydration(for: key)
        catalogueStreamIDs.removeValue(forKey: key)
        catalogueStreamSequences.removeValue(forKey: key)
        if themeEventSubscribers.removeValue(forKey: key) != nil,
           let peer = connection.authenticatedPeer {
            RemoteNotificationService.shared.foregroundDeviceDetached(
                shareID: peer.authorization.shareID,
                participantID: peer.authorization.member.map { .member($0.id) } ?? .owner,
                deviceID: peer.deviceID ?? "socket-\(key.hashValue)"
            )
        }
        if let terminalID = terminalByConnection.removeValue(forKey: key) {
            releaseViewport(
                for: connection,
                target: .terminal(terminalID),
                release: viewportRelease
            )
            terminalMirrors[terminalID]?.subscribers.removeValue(forKey: key)
            if terminalMirrors[terminalID]?.subscribers.isEmpty == true,
               !AppSettings.shared.remoteAccessEnabled
            {
                // A mirror that is going cannot hold a grid: nothing would be left to expire it,
                // and this terminal would stay at phone width with no lease to explain it.
                terminalMirrors[terminalID]?.viewportLeases.dropHeld()
                applyViewport(for: terminalID)
                removeTap(terminalID: terminalID)
                terminalMirrors[terminalID] = nil
            }
            return
        }
        guard let sessionID = sessionByConnection.removeValue(forKey: key) else { return }
        let departingParticipantID = connection.authenticatedPeer?.authorization
            .collaborationParticipantID
        broadcastPresence(.left, from: connection, sessionID: sessionID)
        releaseViewport(
            for: connection,
            target: .session(sessionID),
            release: viewportRelease
        )
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
                    // A mirror that is going cannot hold a grid: nothing would be left to expire
                    // it, and the Mac would stay at phone width with no lease to explain it.
                    mirrors[sessionID]?.viewportLeases.dropHeld()
                    applyViewport(for: sessionID)
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

    /// Leaves a session mirror while keeping the authenticated WebSocket itself alive.
    ///
    /// Parking deliberately reuses the complete detach path: a phone that is no longer showing
    /// the session must stop receiving PTY bytes, disappear from presence, release its viewport
    /// and give up input control exactly as if its socket had closed. The only retained resource
    /// is the transport owned by `RemoteConnection`.
    @discardableResult
    func park(_ connection: RemoteConnection, sessionID: SessionID) -> Bool {
        let key = ObjectIdentifier(connection)
        guard sessionByConnection[key] == sessionID else { return false }
        detach(connection, viewportRelease: .immediate)
        connection.sendText(encode(RemoteSessionParkedDTO()))
        return true
    }

    func isAttached(_ connection: RemoteConnection, to sessionID: SessionID) -> Bool {
        sessionByConnection[ObjectIdentifier(connection)] == sessionID
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
            guard case let .available(state) = terminalApplication.state(for: sessionID) else {
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
        guard case let .captured(snapshot) = result else { return nil }
        var ring = RemoteRingBuffer(capacity: RemoteAccessDefaults.ringBufferBytes)
        // A synthesised repaint, not `getBufferAsData()`: that is plain text joined by bare line
        // feeds with blank cells as NUL, which a client renders as a staircase of run-together
        // words. See `RemoteScreenSeed`.
        ring.append(snapshot.screenSeed)
        mirrors[sessionID] = Mirror(ring: ring, surface: .terminal)
        attachStartupWaiters(sessionID)
        return snapshot.state
    }

    @discardableResult
    func beginCapturing(terminalID: TerminalID) -> RemoteTerminalState? {
        guard let terminalApplication else { return nil }
        if terminalMirrors[terminalID] != nil {
            guard case let .available(state) = terminalApplication.state(for: terminalID) else {
                return nil
            }
            return state
        }
        let result = terminalApplication.beginCapture(for: terminalID) { [weak self] data in
            DispatchQueue.main.async { [weak self] in
                self?.broadcast(data, terminalID: terminalID)
            }
        }
        guard case let .captured(snapshot) = result else { return nil }
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
            where ProjectStore.shared.terminal(withID: terminalID) != nil
        {
            beginCapturing(terminalID: terminalID)
        }
    }

    /// Releases idle capture as well as subscribers when the master switch is turned off.
    func remoteAccessStopped() {
        invalidateMeCatalogue()
        for transaction in terminalHydrations.values {
            transaction.cancel()
        }
        terminalHydrations.removeAll()
        // Turning the master switch off is an authorization change, so every held grid ends now
        // rather than at its own expiry. The mirrors are cleared below and each surface is put
        // back to its Mac frame; this cancels the timers that would otherwise outlive them.
        for mirror in mirrors.values {
            mirror.viewportLeases.cancelExpiries()
        }
        for mirror in terminalMirrors.values {
            mirror.viewportLeases.cancelExpiries()
        }
        for sessionID in mirrors.keys where mirrors[sessionID]?.surface == .terminal {
            _ = terminalApplication?.setViewport(nil, for: sessionID)
            removeTap(sessionID: sessionID)
        }
        for terminalID in terminalMirrors.keys {
            _ = terminalApplication?.setViewport(nil, for: terminalID)
            removeTap(terminalID: terminalID)
        }
        for work in pendingConversationBroadcasts.values {
            work.cancel()
        }
        pendingConversationBroadcasts.removeAll()
        // Not cancelled: the line was typed and the sender told it was accepted, and the PTY
        // outlives remote access. A dropped Return would leave that message in the composer.
        for sessionID in Array(owedTerminalReturns.keys) {
            pressOwedReturn(in: sessionID)
        }
        for starting in startingSessions.values {
            starting.expiry?.cancel()
        }
        startingSessions.removeAll()
        startupSessionByConnection.removeAll()
        mirrors.removeAll()
        terminalMirrors.removeAll()
        terminalByConnection.removeAll()
        typingConnections.removeAll()
        presenceIDs.removeAll()
        promptReplayCache.removeAll()
        attentionRequestPolicy.removeAll()
        for task in focusedControllerReleaseTasks.values {
            task.cancel()
        }
        focusedControllerReleaseTasks.removeAll()
        inputControls.removeAll()
        sessionByConnection.removeAll()
        for (key, connection) in themeEventSubscribers {
            guard let peer = connection.authenticatedPeer else { continue }
            RemoteNotificationService.shared.foregroundDeviceDetached(
                shareID: peer.authorization.shareID,
                participantID: peer.authorization.member.map { .member($0.id) } ?? .owner,
                deviceID: peer.deviceID ?? "socket-\(key.hashValue)"
            )
        }
        themeEventSubscribers.removeAll()
        catalogueStreamIDs.removeAll()
        catalogueStreamSequences.removeAll()
    }

    // MARK: - Input

    /// Every byte this registry writes into a session's PTY goes through here, so a Return
    /// still owed by an earlier submitted line is pressed before anything can land on top of
    /// that line — two messages merged into one prompt is the failure this ordering prevents.
    @discardableResult
    private func writeTerminalInput(_ bytes: [UInt8], to sessionID: SessionID) -> Bool {
        pressOwedReturn(in: sessionID)
        return terminalApplication?.sendInput(bytes, to: sessionID) == .applied
    }

    /// Inserts one semantic paste using the mode the program running on the PTY actually set.
    ///
    /// Attachment paths cannot go through `writeTerminalInput`: Claude Code and Codex both
    /// distinguish pasted image paths from the identical characters typed at the cursor. The
    /// cheap terminal state already carries DECSET 2004, so no screen snapshot or UI adapter is
    /// needed to preserve that distinction for a remote attachment.
    @discardableResult
    private func pasteTerminalText(_ text: String, to sessionID: SessionID) -> Bool {
        pressOwedReturn(in: sessionID)
        guard !text.isEmpty,
              let terminalApplication,
              case .available(let state) = terminalApplication.state(for: sessionID)
        else { return false }
        let paste = RemoteTerminalPaste.delimited(
            text,
            bracketedPaste: state.modes.bracketedPaste
        )
        return terminalApplication.sendInput(Array(paste.utf8), to: sessionID) == .applied
    }

    /// Submits the line just typed into `sessionID`, in a write of its own a beat later.
    ///
    /// The text and its Return cannot share a write. Input arriving in one chunk is what a
    /// TUI's paste heuristic *is*, so a Return bundled with the text is read as pasted content:
    /// Claude Code inserts it as a line break and the message sits unsent in its composer,
    /// which is exactly what a phone's composer produced. `SessionCoordinator` measured the
    /// same thing for the rename request, and `SessionMessageDelivery` types the Mac's own
    /// cross-session sends this way for the same reason.
    private func pressReturnAfterTypedLine(in sessionID: SessionID) {
        pressOwedReturn(in: sessionID)
        owedTerminalReturns[sessionID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TerminalDefaults.submitSequenceDelay))
            guard !Task.isCancelled, let self else { return }
            self.owedTerminalReturns[sessionID] = nil
            self.writeSubmitSequence(to: sessionID)
        }
    }

    /// Presses a Return a typed line is still waiting for, now rather than on its beat.
    private func pressOwedReturn(in sessionID: SessionID) {
        guard let owed = owedTerminalReturns.removeValue(forKey: sessionID) else { return }
        owed.cancel()
        writeSubmitSequence(to: sessionID)
    }

    private func writeSubmitSequence(to sessionID: SessionID) {
        _ = terminalApplication?.sendInput(
            Array(TerminalDefaults.submitSequence.utf8),
            to: sessionID
        )
    }

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
              case .available = terminalApplication.state(for: sessionID)
        else {
            return false
        }

        // Preserve the existing audit ordering: authorization and runtime admission happen
        // first, the accepted interaction is recorded, and only then do bytes reach the PTY.
        recordFirstInput(device: device, sessionID: sessionID)
        RemoteNotificationService.shared.recordInteraction(
            sessionID: sessionID,
            authorization: authorization
        )
        return writeTerminalInput(bytes, to: sessionID)
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
           terminalMirrors[terminalID]?.inputSeenDevices.contains(device) == false
        {
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
        rows: Int,
        hydrationRequestID: String? = nil
    ) {
        guard let authorization = connection.authenticatedPeer?.authorization,
              canWrite(sessionID: sessionID, authorization: authorization),
              (20 ... 240).contains(cols),
              (4 ... 160).contains(rows),
              mirrors[sessionID]?.surface == .terminal,
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              let terminalApplication,
              case let .available(state) = terminalApplication.state(for: sessionID)
        else {
            return
        }

        // Before the live request is recorded, so this device's own held grid stops counting at
        // the same moment its replacement starts: a phone asking for the grid it left with
        // resolves to the same intersection and costs no resize at all.
        claimHeldViewport(for: connection, target: .session(sessionID))
        mirrors[sessionID]?.viewportLeases.active[ObjectIdentifier(connection)] = ViewportRequest(
            cols: cols,
            rows: rows
        )
        let requestedGrid = Self.resolvedViewport(
            of: mirrors[sessionID]?.viewportLeases.grids ?? []
        ).map { RemoteTerminalGrid(cols: $0.cols, rows: $0.rows) }
        let expectsResizeOutput = state.remoteViewport != requestedGrid
        applyViewport(for: sessionID)
        if let hydrationRequestID {
            beginTerminalHydration(
                connection: connection,
                sessionID: sessionID,
                requestID: hydrationRequestID,
                expectsResizeOutput: expectsResizeOutput
            )
        }
    }

    func releaseViewport(from connection: RemoteConnection, sessionID: SessionID) {
        releaseViewport(
            for: connection,
            target: .session(sessionID),
            release: .immediate
        )
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
        claimHeldViewport(for: connection, target: .terminal(terminalID))
        terminalMirrors[terminalID]?.viewportLeases.active[ObjectIdentifier(connection)] = .init(
            cols: cols,
            rows: rows
        )
        applyViewport(for: terminalID)
    }

    func releaseViewport(from connection: RemoteConnection, terminalID: TerminalID) {
        releaseViewport(
            for: connection,
            target: .terminal(terminalID),
            release: .immediate
        )
    }

    /// Reconciles the viewport grace with the local renderer's ownership transition.
    ///
    /// The reconnect window exists for a phone whose transport disappeared while nobody local
    /// is looking at the chat. Selecting that chat on the Mac is an explicit demand for the
    /// desktop grid, so any departed devices stop constraining it immediately. Active phone
    /// leases remain: they still represent renderers on screen and continue to use the shared
    /// intersection rule.
    func localSessionVisibilityChanged(_ sessionID: SessionID?) {
        locallyVisibleSessionID = sessionID
        guard let sessionID,
              var leases = mirrors[sessionID]?.viewportLeases,
              !leases.held.isEmpty else { return }
        leases.dropHeld()
        mirrors[sessionID]?.viewportLeases = leases
        applyViewport(for: sessionID)
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
            case let .replay(status):
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
                  conversation.isRunning
        {
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

        guard let handed = handedOverAttachmentPaths(
            stagedAttachmentPaths,
            for: sessionID
        ) else { return nil }
        return ComposerAttachmentHandover.appending(paths: handed, to: text)
    }

    /// Exchanges temporary upload paths for the session-owned copies an agent may safely open.
    private func handedOverAttachmentPaths(
        _ stagedAttachmentPaths: [String],
        for sessionID: SessionID
    ) -> [String]? {
        guard !stagedAttachmentPaths.isEmpty else { return [] }

        // The staged files are on loan, not handed over: the server released or discarded them
        // by the status this call returns. Deleting them here would take them away from a
        // rejected submission the composer is about to retry.
        guard let folder = ProjectStore.shared.workingDirectory(forSessionID: sessionID) else {
            return nil
        }
        guard let handed = ComposerAttachmentHandover.handOverStaged(
            paths: stagedAttachmentPaths,
            sessionID: sessionID,
            projectRoot: URL(fileURLWithPath: folder, isDirectory: true)
        ) else { return nil }
        return handed
    }

    /// Sends one locally composed terminal line. Every device keeps its own draft; only the
    /// completed line joins the shared byte stream, so two phones cannot splice individual
    /// keystrokes into one malformed Claude/Codex prompt.
    ///
    /// The line is one write and its Return is another, a beat later — see
    /// `pressReturnAfterTypedLine`. Bundled into a single write, as this did, the Return is
    /// part of what a TUI reads as pasted content, and the message a phone sent was left
    /// sitting in Claude Code's composer with a stray line break instead of being submitted.
    /// `.accepted` is answered on the text landing, which is the write that can fail.
    func submitTerminalLine(
        _ text: String,
        stagedAttachmentPaths: [String] = [],
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
        let fingerprint = Data(SHA256.hash(data: Data(
            ("terminal\0" + text + "\0" + stagedAttachmentPaths.joined(separator: "\0")).utf8
        )))
        if let replayKey {
            switch promptReplayCache.decision(for: replayKey, fingerprint: fingerprint) {
            case .new:
                break
            case let .replay(status):
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
                  let line = promptText(
                      text,
                      stagedAttachmentPaths: stagedAttachmentPaths,
                      for: sessionID
                  ),
                  writeTerminalInput(Array(line.utf8), to: sessionID)
        {
            pressReturnAfterTypedLine(in: sessionID)
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

    /// Takes custody of phone uploads and pastes their workspace paths into the PTY.
    /// Direct mode belongs to the terminal application, so adding Return here would unexpectedly
    /// submit whatever the person was editing before the upload finished.
    func insertTerminalAttachments(
        stagedPaths: [String],
        into sessionID: SessionID,
        device: String?,
        authorization: RemoteAuthorization,
        requestID: String
    ) -> RemotePromptSubmissionStatus {
        let replayKey = RemotePromptReplayCache.Key(
            sessionID: sessionID.uuidString,
            principalID: [
                authorization.principal == .ownerDevice ? "owner" : "guest",
                authorization.member?.id ?? authorization.shareID,
                device ?? "legacy",
            ].joined(separator: ":"),
            requestID: requestID
        )
        let fingerprint = Data(SHA256.hash(data: Data(
            ("terminal-attachments\0" + stagedPaths.joined(separator: "\0")).utf8
        )))
        switch promptReplayCache.decision(for: replayKey, fingerprint: fingerprint) {
        case let .replay(status):
            return status
        case .conflict:
            return .conflict
        case .new:
            break
        }

        let status: RemotePromptSubmissionStatus
        if !canWrite(sessionID: sessionID, authorization: authorization) {
            status = .rejected
        } else if mirrors[sessionID]?.surface == .terminal,
                  RemoteSessionAccess.isVisible(ProjectStore.shared.session(withID: sessionID)),
                  let handed = handedOverAttachmentPaths(stagedPaths, for: sessionID),
                  !handed.isEmpty,
                  pasteTerminalText(
                      RemoteTerminalPaste.filePathText(for: handed),
                      to: sessionID
                  )
        {
            recordFirstInput(device: device, sessionID: sessionID)
            RemoteNotificationService.shared.recordInteraction(
                sessionID: sessionID,
                authorization: authorization
            )
            status = .accepted
        } else {
            status = .unavailable
        }

        promptReplayCache.store(status, for: replayKey, fingerprint: fingerprint)
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
              mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil
        else {
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
                action: .requested,
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

        let eventAction: RemoteInputControlEventAction
        switch action {
        case .collaborative, .focused: eventAction = .modeChanged
        case .handoff: eventAction = .handedOff
        case .reclaim: eventAction = .reclaimed
        case .request: eventAction = .requested
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
            role: .owner,
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
                        role: .member,
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
                role: .member,
                isOnline: true
            )
        }
        participants.append(contentsOf: membersByID.values)
        return participants.sorted {
            if $0.role != $1.role { return $0.role == .owner }
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
        for connection in mirror.subscribers.values {
            connection.sendText(message)
        }
    }

    private func inputControlChanged(_ sessionID: SessionID) {
        if var mirror = mirrors[sessionID], mirror.surface == .terminal {
            let subscribers = mirror.subscribers
            mirror.viewportLeases.active = mirror.viewportLeases.active.filter { key, _ in
                guard let authorization = subscribers[key]?.authenticatedPeer?.authorization
                else { return false }
                return canWrite(sessionID: sessionID, authorization: authorization)
            }
            // A held grid is re-checked against the authorization its device released with, and
            // that snapshot can only ever *narrow* the lease: a device that would no longer be
            // allowed to write loses the grid it was holding now, not at expiry. The timer is
            // not a place where an access outlives its check.
            //
            // In Focused mode this means the 30-second `focusedControllerDisconnectGrace` ends a
            // departed controller's viewport lease too, well before a longer viewport grace
            // would have. That is correct: the moment control returns to the Mac owner, the
            // phone that left is no longer a client whose grid the PTY answers to.
            for (deviceID, lease) in mirror.viewportLeases.held
                where !canWrite(sessionID: sessionID, authorization: lease.authorization)
            {
                lease.expiry.cancel()
                mirror.viewportLeases.held.removeValue(forKey: deviceID)
            }
            mirrors[sessionID] = mirror
            applyViewport(for: sessionID)
        }
        broadcastInputControl(sessionID)
        // Provider state did not change, but each viewer's authorised `canSend` may have.
        if mirrors[sessionID]?.surface == .conversation,
           let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID),
           let mirror = mirrors[sessionID]
        {
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
                action: .released,
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
        _ state: RemotePresenceUpdate,
        from connection: RemoteConnection,
        sessionID: SessionID
    ) {
        guard mirrors[sessionID]?.subscribers[ObjectIdentifier(connection)] != nil,
              connection.authenticatedPeer?.authorization.capability == .interact
        else {
            return
        }
        broadcastPresence(
            state == .typing ? .typing : .viewing,
            from: connection,
            sessionID: sessionID
        )
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
              ).first(where: { $0.id == recipientID })
        else {
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
        case let .replay(status):
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
            "recipient": recipient.role.rawValue,
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
        attachStartupWaiters(sessionID)
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
              let conversation = AgentRuntime.shared.remoteConversationSurface(for: sessionID)
        else {
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

    /// Publishes the current provider-owned checklist independently of terminal bytes or native
    /// transcript rows, so both surfaces have the same remote chrome.
    func sessionRunProgressChanged(_ sessionID: SessionID) {
        guard var mirror = mirrors[sessionID] else { return }
        let progress = AgentRuntime.shared.runProgress(for: sessionID)
        guard mirror.runPlan != progress else { return }
        mirror.runPlan = progress
        mirror.runPlanRevision &+= 1
        mirrors[sessionID] = mirror
        let message = encode(Self.runPlanUpdate(
            progress,
            revision: mirror.runPlanRevision
        ))
        for connection in mirror.subscribers.values {
            connection.sendText(message)
        }
    }

    /// Serves one bounded checklist page for the exact revision the client is displaying.
    func requestRunPlanPage(
        from connection: RemoteConnection,
        sessionID: SessionID,
        revision: Int,
        offset: Int,
        limit: Int?
    ) {
        guard let mirror = mirrors[sessionID],
              mirror.subscribers[ObjectIdentifier(connection)] != nil,
              mirror.runPlanRevision == revision,
              let progress = mirror.runPlan
        else {
            connection.sendText(encode(Self.runPlanUpdate(
                mirrors[sessionID]?.runPlan,
                revision: mirrors[sessionID]?.runPlanRevision ?? 0
            )))
            return
        }
        let start = min(max(0, offset), progress.steps.count)
        let count = min(
            max(1, limit ?? RemoteAccessDefaults.maximumRemoteRunPlanPageSteps),
            RemoteAccessDefaults.maximumRemoteRunPlanPageSteps
        )
        let end = min(progress.steps.count, start + count)
        connection.sendText(encode(RemoteRunPlanPageDTO(
            revision: revision,
            offset: start,
            total: progress.steps.count,
            steps: Self.remoteSteps(Array(progress.steps[start ..< end]), baseOffset: start)
        )))
    }

    private func sendCurrentRunPlan(to connection: RemoteConnection, sessionID: SessionID) {
        guard var mirror = mirrors[sessionID] else { return }
        let current = AgentRuntime.shared.runProgress(for: sessionID)
        if mirror.runPlan != current {
            mirror.runPlan = current
            mirror.runPlanRevision &+= 1
            mirrors[sessionID] = mirror
        }
        connection.sendText(encode(Self.runPlanUpdate(
            current,
            revision: mirror.runPlanRevision
        )))
    }

    private static func runPlanUpdate(
        _ progress: RunProgress?,
        revision: Int
    ) -> RemoteRunPlanUpdateDTO {
        let summary = progress.map { progress in
            RemoteRunPlanSummaryDTO(
                activeTitle: progress.currentStep.map {
                    boundedRunPlanTitle($0.title)
                },
                current: progress.currentPosition,
                completed: progress.completed,
                active: progress.active,
                total: progress.total
            )
        }
        return RemoteRunPlanUpdateDTO(revision: revision, plan: summary)
    }

    private static func remoteSteps(
        _ steps: [RunProgress.Step],
        baseOffset: Int
    ) -> [RemoteRunPlanStepDTO] {
        steps.enumerated().map { index, step in
            let status: RemoteRunPlanStepStatus = switch step.status {
            case .pending: .pending
            case .inProgress: .inProgress
            case .completed: .completed
            }
            return RemoteRunPlanStepDTO(
                // Provider ids are useful metadata but are not guaranteed unique. The wire id
                // is positional within one immutable revision so paged SwiftUI lists stay sound.
                id: "step-\(baseOffset + index)",
                providerID: step.id,
                title: boundedRunPlanTitle(step.title),
                status: status
            )
        }
    }

    private static func boundedRunPlanTitle(_ title: String) -> String {
        let limit = RemoteAccessDefaults.maximumRemoteRunPlanTitleBytes
        guard title.utf8.count > limit else { return title }
        var end = title.startIndex
        var bytes = 0
        while end < title.endIndex {
            let next = title.index(after: end)
            let width = title[end ..< next].utf8.count
            guard bytes + width <= limit - 3 else { break }
            bytes += width
            end = next
        }
        return String(title[..<end]) + "…"
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
        invalidateMeCatalogue()
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

    /// Sends one scoped catalogue frame with continuity local to this authenticated connection.
    /// A hidden row consumes no sequence number, so the counter carries delivery proof without
    /// leaking activity from outside the connection's authorization.
    private func sendCatalogueUpdate(
        _ update: RemoteSessionsChangedDTO,
        to connection: RemoteConnection
    ) {
        let key = ObjectIdentifier(connection)
        guard themeEventSubscribers[key] === connection,
              var streamID = catalogueStreamIDs[key],
              var sequence = catalogueStreamSequences[key] else { return }
        if sequence == UInt64.max {
            streamID = UUID().uuidString
            sequence = 0
            catalogueStreamIDs[key] = streamID
            connection.sendText(encode(RemoteCatalogueStreamHelloDTO(
                streamID: streamID,
                revision: catalogueRevision
            )))
        }
        sequence += 1
        catalogueStreamSequences[key] = sequence
        connection.sendText(encode(update.framed(streamID: streamID, sequence: sequence)))
    }

    /// Keeps high-frequency row changes proportional to the changed session. Structural edits
    /// remain an invalidation because they can change ordering, projects, archives and creation
    /// choices together; every client then re-fetches its own scoped snapshot.
    private func broadcastSessionsChanged(_ change: ProjectsDidChange) {
        invalidateMeCatalogue()
        // Read once after the invalidation: every delta this change produces names the edition
        // the change created, which is what a client adopts when it applies the delta.
        let revision = catalogueRevision
        switch change.sidebarImpact {
        case .structure, .projectRemoved, .projectStructure, .projectRow:
            for connection in themeEventSubscribers.values {
                sendCatalogueUpdate(RemoteSessionsChangedDTO(revision: revision), to: connection)
            }
        case let .terminalAdded(_, terminalID), let .terminalRow(terminalID):
            let terminal = ProjectStore.shared.terminal(withID: terminalID)
            for connection in themeEventSubscribers.values {
                guard let authorization = connection.authenticatedPeer?.authorization,
                      authorization.scope.covers(terminalID) else { continue }
                let visible = terminal.map { candidate in
                    let project = ProjectStore.shared.homeProject(forTerminalID: terminalID)
                    return terminalSummary(
                        for: candidate,
                        projectID: project?.id,
                        projectName: project?.name ?? ""
                    )
                }
                sendCatalogueUpdate(RemoteSessionsChangedDTO(
                    terminal: visible,
                    removedTerminalID: visible == nil ? terminalID.uuidString : nil,
                    revision: revision
                ), to: connection)
            }
        case .sessionRemoved:
            for connection in themeEventSubscribers.values {
                guard let authorization = connection.authenticatedPeer?.authorization,
                      let delta = Self.sessionRemovalDelta(
                          for: change,
                          authorization: authorization,
                          revision: revision
                      ) else { continue }
                sendCatalogueUpdate(delta, to: connection)
            }
        case let .sessionAdded(_, sessionID), let .sessionStructure(_, sessionID),
             let .sessionTitle(sessionID, _),
             let .sessionRow(sessionID):
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
                        projectID: project.id,
                        projectName: project.name,
                        projectLimitRecovery: project.limitRecoveryPolicy,
                        authorization: authorization
                    )
                }
                guard let delta = Self.sessionMutationDelta(
                    sessionID: sessionID,
                    visibleSummary: visible,
                    authorization: authorization,
                    revision: revision
                ) else { continue }
                sendCatalogueUpdate(delta, to: connection)
            }
        }
    }

    /// Pushes one identity-specific catalogue row for an activity or read-receipt edge.
    private func broadcastSessionRow(_ sessionID: SessionID) {
        invalidateMeCatalogue()
        let revision = catalogueRevision
        guard let session = ProjectStore.shared.session(withID: sessionID),
              let project = ProjectStore.shared.project(forSessionID: sessionID) else { return }
        for connection in themeEventSubscribers.values {
            guard let authorization = connection.authenticatedPeer?.authorization,
                  RemoteSessionAccess.isVisible(session),
                  authorization.scope.covers(sessionID) else { continue }
            sendCatalogueUpdate(RemoteSessionsChangedDTO(
                session: summary(
                    for: session,
                    projectID: project.id,
                    projectName: project.name,
                    projectLimitRecovery: project.limitRecoveryPolicy,
                    authorization: authorization
                ),
                revision: revision
            ), to: connection)
        }
    }

    /// The permanent-delete catalogue delta is exact and scope-bound. Keeping the authorization
    /// decision beside the payload construction makes this small but security-sensitive branch
    /// independently testable without opening a real event socket.
    static func sessionRemovalDelta(
        for change: ProjectsDidChange,
        authorization: RemoteAuthorization,
        revision: RemoteCatalogueRevisionDTO? = nil
    ) -> RemoteSessionsChangedDTO? {
        guard case let .sessionRemoved(_, sessionID) = change.sidebarImpact,
              authorization.scope.covers(sessionID) else { return nil }
        return RemoteSessionsChangedDTO(
            session: nil,
            removedSessionID: sessionID.uuidString,
            revision: revision
        )
    }

    /// An add, reorder, visibility change, or row update must not reveal that an out-of-scope
    /// identity changed. In-scope disappearance still names the row so a client can remove it.
    static func sessionMutationDelta(
        sessionID: SessionID,
        visibleSummary: RemoteSessionSummaryDTO?,
        authorization: RemoteAuthorization,
        revision: RemoteCatalogueRevisionDTO? = nil
    ) -> RemoteSessionsChangedDTO? {
        guard authorization.scope.covers(sessionID) else { return nil }
        return RemoteSessionsChangedDTO(
            session: visibleSummary,
            removedSessionID: visibleSummary == nil ? sessionID.uuidString : nil,
            revision: revision
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
               })
            {
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
            // `active` only: a held grid belongs to a device that has gone, and an audience
            // list that showed it would be reporting a follower who is not watching anything.
            let request = mirror.viewportLeases.active[key]
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
        cancelSessionStartup(sessionID, reason: "Session closed")
        pendingConversationBroadcasts.removeValue(forKey: sessionID)?.cancel()
        latestWorkspaceActivity.removeValue(forKey: sessionID)
        typingConnections.removeValue(forKey: sessionID)
        promptReplayCache.remove(sessionID: sessionID.uuidString)
        attentionRequestPolicy.remove(sessionID: sessionID.uuidString)
        defer { followersChanged(sessionID) }
        // Archival and discard are authorization changes, so a held grid ends here rather than
        // at its own expiry. The mirror is about to go with it; this cancels the timers.
        mirrors[sessionID]?.viewportLeases.dropHeld()
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
            cancelTerminalHydration(for: key)
            sessionByConnection.removeValue(forKey: key)
            presenceIDs[key] = nil
        }
        mirrors[sessionID] = nil
    }

    func terminalDiscarded(_ terminalID: TerminalID) {
        terminalMirrors[terminalID]?.viewportLeases.dropHeld()
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

    private func beginTerminalHydration(
        connection: RemoteConnection,
        sessionID: SessionID,
        requestID: String,
        expectsResizeOutput: Bool
    ) {
        let key = ObjectIdentifier(connection)
        terminalHydrations.removeValue(forKey: key)?.cancel()
        let transaction = TerminalHydrationTransaction(
            requestID: requestID,
            sessionID: sessionID,
            connection: connection
        )
        terminalHydrations[key] = transaction

        guard expectsResizeOutput else {
            completeTerminalHydration(for: key, requestID: requestID)
            return
        }

        let firstOutputDelay = terminalHydrationFirstOutputMaximumDelay
        transaction.firstOutputTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: firstOutputDelay)
            guard !Task.isCancelled else { return }
            self?.completeTerminalHydration(for: key, requestID: requestID)
        }
        let maximumDelay = terminalHydrationMaximumDelay
        transaction.maximumTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: maximumDelay)
            guard !Task.isCancelled else { return }
            self?.completeTerminalHydration(for: key, requestID: requestID)
        }
    }

    private func noteTerminalHydrationOutput(
        for key: ObjectIdentifier,
        sessionID: SessionID
    ) {
        guard let transaction = terminalHydrations[key],
              transaction.sessionID == sessionID else { return }
        transaction.firstOutputTask?.cancel()
        transaction.firstOutputTask = nil
        transaction.quietTask?.cancel()
        let requestID = transaction.requestID
        let quietDelay = terminalHydrationOutputQuietDelay
        transaction.quietTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: quietDelay)
            guard !Task.isCancelled else { return }
            self?.completeTerminalHydration(for: key, requestID: requestID)
        }
    }

    /// Sends a final screen seed and then the text boundary on the same connection queue. Wire
    /// ordering makes the ready frame proof that every earlier binary frame is available to the
    /// client parser; packet timing on Wi-Fi no longer participates in reveal timing.
    private func completeTerminalHydration(for key: ObjectIdentifier, requestID: String) {
        guard let transaction = terminalHydrations[key],
              transaction.requestID == requestID else { return }
        terminalHydrations[key] = nil
        transaction.cancel()

        if case let .captured(snapshot) = terminalApplication?.currentSnapshot(
            for: transaction.sessionID
        ) {
            transaction.connection.sendBinary(snapshot.screenSeed)
            transaction.connection.sendBinary(RemoteTerminalModeSeed.bytes(for: snapshot.modes))
        }
        transaction.connection.sendText(encode(RemoteTerminalReadyDTO(requestID: requestID)))
    }

    private func cancelTerminalHydration(for key: ObjectIdentifier) {
        terminalHydrations.removeValue(forKey: key)?.cancel()
    }

    // MARK: - Viewport leases

    /// Ends one connection's lease. Only an unannounced transport loss holds its grid for a
    /// grace period when the device can be recognised on its return; an explicit release or
    /// parked chat restores the remaining controller or Mac grid immediately.
    ///
    /// A lease change is a real `SIGWINCH` and a full TUI repaint, and the joining client waits
    /// for that repaint. Backgrounding the iOS app can drop the socket without an explicit
    /// release, so a glance at a notification and a return used to reflow a working agent twice
    /// — the most frequent cost this mirror imposes on the program it is watching.
    ///
    /// **The grace holds a grid, and only a grid.** The socket is already unsubscribed, the peer
    /// is permitted nothing, and `followers(of:)` reads subscribers rather than leases, so a
    /// held lease is invisible as an audience and useless as an access. Discard, archival, the
    /// master switch and a loss of write permission all end it immediately rather than at
    /// expiry; nothing here is a place where an authorization outlives its check.
    ///
    /// An explicit release also removes a held lease for the same device. Socket teardown and a
    /// final `viewportRelease` frame cross queues, so teardown can otherwise turn the active
    /// request into a held one just before the already-sent explicit release is handled.
    private func releaseViewport(
        for connection: RemoteConnection,
        target: ViewportLeaseTarget,
        release: ViewportLeaseRelease
    ) {
        guard var leases = viewportLeases(for: target) else { return }
        let request = leases.active.removeValue(forKey: ObjectIdentifier(connection))
        var removedHeldLease = false
        if release == .immediate,
           let deviceID = connection.authenticatedPeer?.deviceID,
           let held = leases.held.removeValue(forKey: deviceID)
        {
            held.expiry.cancel()
            removedHeldLease = true
        }
        guard request != nil || removedHeldLease else { return }
        defer {
            setViewportLeases(leases, for: target)
            applyViewport(for: target)
        }
        guard release == .reconnectGrace, let request else { return }
        if case let .session(sessionID) = target,
           locallyVisibleSessionID == sessionID
        {
            // The local renderer is already looking at this chat. There is no unattended
            // interval for a reconnect grace to protect, so its desktop grid wins now.
            return
        }
        let grace = viewportLeaseGrace()
        guard grace > .zero,
              let peer = connection.authenticatedPeer,
              let deviceID = peer.deviceID else { return }
        leases.held[deviceID]?.expiry.cancel()
        leases.held[deviceID] = HeldViewportLease(
            cols: request.cols,
            rows: request.rows,
            authorization: peer.authorization,
            expiry: Task { @MainActor [weak self] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled else { return }
                self?.expireHeldViewport(deviceID: deviceID, target: target)
            }
        )
        EventLog.shared.record(.remote, "Remote viewport lease held", leaseFields(
            target: target,
            deviceID: deviceID,
            extra: [
                "grid": "\(request.cols)×\(request.rows)",
                "grace": String(describing: grace),
            ]
        ))
    }

    /// The window closed with nobody back. The grid stops counting and the Mac's own frame
    /// decides again, exactly as an immediate release always did.
    private func expireHeldViewport(deviceID: String, target: ViewportLeaseTarget) {
        guard var leases = viewportLeases(for: target),
              leases.held.removeValue(forKey: deviceID) != nil else { return }
        setViewportLeases(leases, for: target)
        EventLog.shared.record(.remote, "Remote viewport lease expired", leaseFields(
            target: target,
            deviceID: deviceID
        ))
        applyViewport(for: target)
    }

    /// A returning device takes its own pending lease back before its live request replaces it,
    /// so the intersection never sees the grid twice and never sees it missing.
    private func claimHeldViewport(for connection: RemoteConnection, target: ViewportLeaseTarget) {
        guard let deviceID = connection.authenticatedPeer?.deviceID,
              var leases = viewportLeases(for: target),
              let lease = leases.held.removeValue(forKey: deviceID) else { return }
        lease.expiry.cancel()
        setViewportLeases(leases, for: target)
    }

    private func viewportLeases(for target: ViewportLeaseTarget) -> ViewportLeases? {
        switch target {
        case let .session(sessionID): return mirrors[sessionID]?.viewportLeases
        case let .terminal(terminalID): return terminalMirrors[terminalID]?.viewportLeases
        }
    }

    private func setViewportLeases(_ leases: ViewportLeases, for target: ViewportLeaseTarget) {
        switch target {
        case let .session(sessionID): mirrors[sessionID]?.viewportLeases = leases
        case let .terminal(terminalID): terminalMirrors[terminalID]?.viewportLeases = leases
        }
    }

    private func applyViewport(for target: ViewportLeaseTarget) {
        switch target {
        case let .session(sessionID): applyViewport(for: sessionID)
        case let .terminal(terminalID): applyViewport(for: terminalID)
        }
    }

    /// The device is pseudonymised for the same reason the sharing pane pseudonymises it: a
    /// journal line has to be safe to hand to somebody, and correlating two lines only needs
    /// the two to match.
    private func leaseFields(
        target: ViewportLeaseTarget,
        deviceID: String,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var fields = extra
        switch target {
        case let .session(sessionID): fields["session"] = sessionID.uuidString
        case let .terminal(terminalID): fields["terminal"] = terminalID.uuidString
        }
        fields["device"] = MacRemoteDiagnostics.pseudonym(deviceID, prefix: "device")
        return fields
    }

    private func applyViewport(for sessionID: SessionID) {
        guard let terminalApplication,
              case let .available(state) = terminalApplication.state(for: sessionID)
        else {
            return
        }
        let leases = mirrors[sessionID]?.viewportLeases ?? ViewportLeases()
        guard let grid = Self.resolvedViewport(of: leases.grids) else {
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
            "clients": String(leases.active.count),
            "held": String(leases.held.count),
        ])
        followersChanged(sessionID)
    }

    private func applyViewport(for terminalID: TerminalID) {
        guard let terminalApplication,
              case let .available(state) = terminalApplication.state(for: terminalID)
        else {
            return
        }
        let leases = terminalMirrors[terminalID]?.viewportLeases ?? ViewportLeases()
        let grid = Self.resolvedViewport(of: leases.grids).map {
            RemoteTerminalGrid(cols: $0.cols, rows: $0.rows)
        }
        guard state.remoteViewport != grid else { return }
        _ = terminalApplication.setViewport(grid, for: terminalID)
        EventLog.shared.record(.remote, grid == nil
            ? "Remote terminal viewport released"
            : "Remote terminal viewport applied", [
                "terminal": terminalID.uuidString,
                "clients": String(leases.active.count),
                "held": String(leases.held.count),
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
        for sessionID in Array(startingSessions.keys) where !RemoteSessionAccess.isVisible(
            ProjectStore.shared.session(withID: sessionID)
        ) {
            cancelSessionStartup(sessionID, reason: "Session not available")
        }
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
        for (key, connection) in mirror.subscribers {
            connection.sendBinary(data)
            noteTerminalHydrationOutput(for: key, sessionID: sessionID)
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
        _ state: RemotePresenceState,
        from connection: RemoteConnection,
        sessionID: SessionID
    ) {
        guard connection.authenticatedPeer != nil,
              let mirror = mirrors[sessionID] else { return }

        // The Mac watches this as well as relaying it. A guest composing a reply is the one
        // piece of live state the sharing pane can show that a list of names cannot.
        let key = ObjectIdentifier(connection)
        let wasTyping = typingConnections[sessionID]?.contains(key) ?? false
        if state == .typing {
            typingConnections[sessionID, default: []].insert(key)
        } else {
            typingConnections[sessionID]?.remove(key)
        }
        if wasTyping != (state == .typing) { followersChanged(sessionID) }

        let message = encode(presenceUpdate(
            for: connection,
            key: key,
            surface: mirror.surface,
            state: state
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
            state: .viewing
        ))
        let typing = typingConnections[sessionID] ?? []
        for (key, subscriber) in mirror.subscribers where key != source {
            connection.sendText(encode(presenceUpdate(
                for: subscriber,
                key: key,
                surface: mirror.surface,
                state: typing.contains(key) ? .typing : .viewing
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
                role: .owner,
                isOnline: subscribers.contains {
                    $0.authenticatedPeer?.authorization.principal == .ownerDevice
                }
            ))
        }

        let currentMemberID = authorization.member?.id
        for member in RemoteAccessCoordinator.shared.access(for: sessionID).members
            where member.capability == .interact && member.id != currentMemberID
        {
            participants.append(RemoteCollaborationParticipantDTO(
                id: member.id,
                displayName: member.displayName,
                role: .member,
                isOnline: subscribers.contains {
                    $0.authenticatedPeer?.authorization.member?.id == member.id
                }
            ))
        }
        return participants.sorted {
            if $0.role != $1.role { return $0.role == .owner }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    private func presenceUpdate(
        for connection: RemoteConnection,
        key: ObjectIdentifier,
        surface: RemoteSessionSurface,
        state: RemotePresenceState
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
              let event = latestWorkspaceActivity[sessionID]
        else {
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
            return try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        } catch {
            ThreadingLogger.remote.error(
                "Remote mirror encoding failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return #"{"type":"error","code":"encodingFailed"}"#
        }
    }
}

private extension RemoteSessionActivity {
    /// The remote vocabulary is intentionally mapped case by case. Reflection made a source
    /// rename into an undeclared wire-protocol change and let the phone compare misspellable
    /// strings; this switch makes adding an activity fail compilation until the wire answer is
    /// chosen deliberately.
    init(_ activity: SessionActivity) {
        switch activity {
        case .dormant: self = .dormant
        case .idle: self = .idle
        case .working: self = .working
        case .readyWithBackgroundWork: self = .idle
        case .awaitingUser: self = .awaitingUser
        case .needsAttention: self = .needsAttention
        case .limitReached: self = .limitReached
        }
    }
}

private extension RemoteSessionAttentionDTO {
    init(_ projection: SessionAttentionProjection) {
        switch projection {
        case let .read(completionGeneration, seenGeneration):
            self.init(
                knowledge: .read,
                completionGeneration: completionGeneration,
                seenGeneration: seenGeneration
            )
        case let .unread(completionGeneration, seenGeneration):
            self.init(
                knowledge: .unread,
                completionGeneration: completionGeneration,
                seenGeneration: seenGeneration
            )
        case .unknown:
            self.init(knowledge: .unavailable)
        }
    }
}

private extension RemoteSessionContinuation {
    init?(_ continuation: SessionContinuationState) {
        switch continuation {
        case .none: return nil
        case .delegated: self = .delegated
        case .standing: self = .standing
        }
    }
}
