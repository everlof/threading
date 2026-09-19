import Foundation
import Network
import ThreadingGlanceKit
import ThreadingPeerTransport
import ThreadingRemoteKit
import UIKit

struct RemoteNotificationOpenRequest: Equatable, Identifiable {
    let eventID: String
    let sessionID: String
    let destination: RemoteNotificationDestinationDTO

    var id: String { eventID }
}

/// Which UIKit lifecycle delivered a notification response.
///
/// A response attached to a connecting scene is that scene's initial route, so it replaces
/// saved continuity. A response delivered to an existing scene is ordinary forward navigation
/// and keeps the screen beneath it as Back's destination. The same response can arrive through
/// both paths; the model coalesces them and the connecting-scene meaning wins.
enum RemoteNotificationOpenOrigin: Equatable {
    case notificationCenter
    case connectingScene

    func merged(with other: Self) -> Self {
        if self == .connectingScene || other == .connectingScene {
            return .connectingScene
        }
        return .notificationCenter
    }
}

/// A chat being written before the Mac has a session for it.
///
/// Identified by the phone, because the Mac mints the session's id only when Start is tapped,
/// and the screen has to be on the navigation stack before then. Once started, the route keeps
/// this identity and the model resolves it to the session it became (`RemoteAppModel.sessionID`),
/// so the screen that drafted the chat is the screen that shows it — no dismissal, no second
/// push, and Back still returns to the list the draft was opened from.
struct MobileSessionDraft: Hashable {
    let id: UUID
    /// The project page's "+" seeds the checkout; the dashboard's leaves it to the catalogue.
    let projectName: String?

    init(id: UUID = UUID(), projectName: String? = nil) {
        self.id = id
        self.projectName = projectName
    }
}

/// How a detail route reaches the live surface behind its catalogue row.
enum MobileSessionOpeningStrategy: Equatable {
    /// An existing dormant row must first ask the Mac to resume it.
    case resumeIfNeeded
    /// Create already owns the launch; opening another resume transaction would race it.
    case awaitCreatedSession
}

struct MobileCreatedSession: Equatable {
    let session: RemoteSessionSummaryDTO
    let openingStrategy: MobileSessionOpeningStrategy
}

struct MobileStartedDraft: Equatable {
    let sessionID: String
    let openingStrategy: MobileSessionOpeningStrategy
}

/// The phone's durable navigation subjects.
///
/// Projects are navigation context only; continuity persists the open chat, never a project
/// name pretending to be a session identifier. Keeping the cases typed also lets a chat opened
/// from a project return to that project's list without encoding UI routes into opaque strings.
enum MobileWorkspaceSearchDestination: Hashable {
    case attachment(String)
    case browserTab(String)

    var remoteDestination: RemoteNotificationDestinationDTO {
        switch self {
        case let .attachment(id): return .attachment(id: id)
        case let .browserTab(id): return .browserTab(id: id)
        }
    }
}

enum MobileNavigationRoute: Hashable {
    case project(String)
    /// Search carries the stable checkout identity so duplicate display names stay distinct.
    case searchProject(id: String, name: String)
    case session(String)
    /// Opens the session and then its native Workspace drawer at the exact search result.
    case sessionWorkspace(String, MobileWorkspaceSearchDestination)
    case terminal(String)
    /// A chat being drafted, and — once Start has been answered — the chat it started.
    case draft(MobileSessionDraft)

    /// The session this route names by itself. A draft names one only through the model,
    /// which is where the started session's id is known; ask `RemoteAppModel.sessionID(for:)`.
    var sessionID: String? {
        switch self {
        case let .session(id), let .sessionWorkspace(id, _): return id
        case .project, .searchProject, .terminal, .draft: return nil
        }
    }
}

/// When a recoverable route miss becomes a settled, actionable dashboard failure.
///
/// One miss is ordinary network movement and the automatic retry already owns it. Three
/// consecutive bounded route races are enough to say that the Mac is unavailable *for now*
/// without flashing the full recovery surface between every backoff attempt.
/// What a live-session socket knows about the loss it is recovering from, handed to the model
/// so the model can decide whether the last authenticated route deserves another try.
struct MobileSessionReconnectRequest: Equatable {
    /// Retries already made against this loss. A hello resets it, so a socket that connects and
    /// dies twenty seconds later is back at zero each time.
    let attempt: Int
    /// The Mac's close frame arrived after the loss began. Bytes crossed the route on the way
    /// down, so whatever broke was not the route. A socket that ended without one may well have
    /// ended because its address stopped existing: a phone that walked off Wi-Fi still holds the
    /// LAN origin, and every retry against it waits out the whole hello deadline.
    let peerSentClose: Bool
}

/// Where the model would send a new socket right now.
///
/// Derived from published state, so a SwiftUI `onChange` sees it move the moment a refresh adopts
/// another route and can hand the new route to a session socket still dialling the old one.
struct MobileRouteIdentity: Equatable {
    let origin: URL
    let endpointKind: RemoteHostEndpointKind
}

enum MobileConnectionRecoveryPolicy {
    static let settledFailureAttempt = 3

    /// Whether a session socket's retry goes through host recovery or straight back to the last
    /// authenticated route.
    ///
    /// The cheap retry exists for a socket the Mac closed on purpose: the address answered, the
    /// route is fine, and one catalogue race per refused socket would be waste. A loss with no
    /// close frame is evidence about the route itself, and so is the dashboard event socket
    /// already recovering from the same loss. The 2026-09-02 report had both sockets die within a
    /// millisecond of Wi-Fi going away; the session's retry looked for a dashboard flight 72 ms
    /// before that flight began, kept the LAN origin, and dialled it until the person backed out.
    static func sessionReconnectNeedsHostRecovery(
        _ request: MobileSessionReconnectRequest,
        dashboardRecoveryPending: Bool
    ) -> Bool {
        if dashboardRecoveryPending { return true }
        if request.attempt > 0 { return true }
        return !request.peerSentClose
    }

    /// Whether opening a chat or terminal goes through host recovery before its socket dials.
    ///
    /// Without a catalogue or online phase there is nothing to open against. With both, the
    /// answer is whether the dashboard is recovering from a lost event socket: the phase stays
    /// online through that loss, so the model's client still names the origin that just died.
    /// The 2026-09-11 report opened a chat ten seconds into such a recovery; the open took that
    /// client, dialled the dead LAN origin, and the person backed out of a chat that "felt
    /// stuck" while the recovery found Tailscale beside it. Joining the recovery costs the open
    /// nothing it would not have paid on the hello deadline, and it dials the right route once.
    static func openNeedsHostRecovery(
        isOnline: Bool,
        hasCatalogue: Bool,
        dashboardRecoveryPending: Bool
    ) -> Bool {
        if !isOnline || !hasCatalogue { return true }
        return dashboardRecoveryPending
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

    /// Waits for the flight in progress for `hostID`, if there is one, and starts nothing. For
    /// work that wants the route a refresh is about to find rather than a refresh of its own.
    func join(hostID: String) async {
        guard let flight, flight.hostID == hostID else { return }
        await flight.task.value
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

/// Continuity proof between an authenticated catalogue snapshot and its scoped event stream.
///
/// WebSocket delivery is ordered, but reconnects, decode failures and process restarts create
/// holes outside that guarantee. Once a current host supplies a stream id, only its next sequence
/// may mutate the snapshot. Any ambiguity latches `requiresRefresh` until an authoritative REST
/// edition catches up with every revision observed on the stream.
struct MobileCatalogueStreamFence: Equatable {
    private(set) var streamID: String?
    private(set) var sequence: UInt64?
    private(set) var requiredRevision: RemoteCatalogueRevisionDTO?
    private(set) var requiresRefresh = false

    var hasCurrentStream: Bool { streamID != nil }

    mutating func begin(
        _ hello: RemoteCatalogueStreamHelloDTO,
        currentRevision: RemoteCatalogueRevisionDTO?
    ) {
        streamID = hello.streamID
        sequence = 0
        requiredRevision = hello.revision
        requiresRefresh = true
        reconcile(currentRevision: currentRevision)
    }

    mutating func accepts(_ update: RemoteSessionsChangedDTO) -> Bool {
        guard let streamID else {
            // Compatibility lane for a host predating stream fences. A framed update without a
            // hello is never legacy; it is a lost fence and must recover from REST.
            guard update.streamID == nil, update.sequence == nil else {
                invalidate(revision: update.revision)
                return false
            }
            return true
        }
        guard update.streamID == streamID,
              let candidate = update.sequence,
              let revision = update.revision,
              let previous = sequence,
              previous < UInt64.max,
              candidate == previous + 1 else {
            invalidate(revision: update.revision)
            // Keep following a same-stream tail so one full refresh can cover the whole gap.
            if update.streamID == streamID, let candidate = update.sequence {
                sequence = candidate
            }
            return false
        }
        sequence = candidate
        noteRequired(revision)
        return !requiresRefresh
    }

    mutating func invalidate(revision: RemoteCatalogueRevisionDTO?) {
        requiresRefresh = true
        noteRequired(revision)
    }

    mutating func reconcile(currentRevision: RemoteCatalogueRevisionDTO?) {
        guard streamID != nil, let requiredRevision else { return }
        guard let currentRevision,
              currentRevision.epoch == requiredRevision.epoch,
              currentRevision.revision >= requiredRevision.revision else {
            requiresRefresh = true
            return
        }
        requiresRefresh = false
    }

    mutating func reset() {
        self = MobileCatalogueStreamFence()
    }

    private mutating func noteRequired(_ revision: RemoteCatalogueRevisionDTO?) {
        guard let revision else { return }
        guard let requiredRevision, requiredRevision.epoch == revision.epoch else {
            self.requiredRevision = revision
            return
        }
        if revision.revision > requiredRevision.revision {
            self.requiredRevision = revision
        }
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
            guard case let .offline(failure) = self else { return nil }
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
            kind: RemoteHostEndpointKind,
            previousKind: RemoteHostEndpointKind?,
            number: Int,
            total: Int
        )
        case loadingSessions(routeKind: RemoteHostEndpointKind)
        /// One complete bounded route race ended, but automatic recovery is already scheduled.
        /// This is not yet the settled recovery surface: the dashboard keeps the same compact
        /// progress anatomy and says exactly why it is waiting.
        case waitingToRetry(attempt: Int)
    }

    /// Which route a walk is on right now, for a surface that would otherwise show only a spinner.
    ///
    /// Separate from `ConnectionProgress`, which belongs to the dashboard's initial connection.
    /// This one exists for every walk, including the one behind opening a chat: the 2026-08-21
    /// incident's phone showed "Opening chat…" and nothing else for ninety seconds, so the person
    /// watching it had no way to tell a stuck app from an app working through a dead LAN.
    ///
    /// `followsFailure` is why this is a value rather than a route name. A first attempt normally
    /// answers in well under a second, and naming the route that fast reads as a stutter; naming
    /// it *after* something failed is the answer to "what is it doing now".
    struct RouteWalkStatus: Equatable, Sendable {
        let kind: RemoteHostEndpointKind
        let attempt: Int
        let total: Int
        let followsFailure: Bool
    }

    @Published private(set) var hosts: [PairedRemoteHost] {
        didSet {
            guard hosts != oldValue else { return }
            discoveryHostsChanged()
        }
    }

    @Published private(set) var me: RemoteMeDTO? {
        didSet {
            MobileAccountImages.shared.receive(me?.newSessionCatalog)
            catalogueRevision &+= 1
            reconcileCatalogueStreamFence()
            rememberCurrentTheme()
            rememberCurrentDashboard()
        }
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
    @Published private(set) var routeWalkStatus: RouteWalkStatus?
    @Published private(set) var activeHostID: String?
    @Published private(set) var storageIssue: String? = nil
    @Published private(set) var widgetHostID: String?
    @Published private(set) var widgetIssue: MobileUsageGlanceIssue?
    @Published var widgetUsageRoute: UsageGlanceRoute?
    @Published private(set) var widgetUsageFocus: MobileUsageAccountFocus?
    @Published private(set) var widgetUsageFocusReady = false
    var usageGlance: MobileUsageGlancePublisher?
    @Published private(set) var notificationOpenRequest: RemoteNotificationOpenRequest?
    @Published var isPairing = false
    /// An invitation the operating system delivered, held until the pairing screen takes it.
    ///
    /// A tapped `threading://` link can arrive before that screen exists — including on a cold
    /// launch, where the URL comes with the scene's connection options — so the payload waits
    /// here rather than being handed to a view that is not on screen yet.
    @Published private(set) var pendingInvitation: String?
    @Published var navigationPath: [MobileNavigationRoute] = [] {
        didSet { recordLastRoute() }
    }

    /// Sessions whose archive/restore transaction is still being committed by the Mac.
    ///
    /// The phone removes these from whichever catalogue they currently occupy at the press
    /// edge. This presentation-only state is shared by the dashboard and an open detail route,
    /// so Archive never waits for provider cleanup before it feels complete.
    @Published private(set) var archiveMutationSessionIDs = Set<String>()
    /// A failed mutation that began in a detail screen already dismissed at the press edge.
    /// The dashboard owns the themed alert because it is the surface now visible.
    @Published private(set) var archiveMutationError: String?
    /// The session each draft on the stack became, by the draft's id. A draft route resolves
    /// through this for everything that asks which chat is open — continuity, the push
    /// dedup, a notification for the chat that was just started — so a chat that began as a
    /// draft is the same navigation subject as one opened from its row.
    @Published private(set) var startedDrafts: [UUID: MobileStartedDraft] = [:]

    private let store: RemoteHostStore
    private let protectedDataAvailable: () -> Bool
    @Published private(set) var needsHostStorageRecovery = false
    private var hostStorageRecoveryTask: Task<Bool, Never>?
    private enum DeferredHostOpen {
        case widget(URL)
        case notification(RemoteNotificationEventDTO, RemoteNotificationOpenOrigin)
    }
    private var deferredHostOpen: DeferredHostOpen?

    private let hostedConnections = HostedRemoteConnectionManager()
    /// Browses for paired Macs on this network while the app is in front of somebody.
    private let discovery = RemoteHostDiscovery()
    /// Where each paired Mac was last found on this network. In memory only: it is a fact about
    /// the network this phone is on right now, not something to write into a Keychain record.
    private var discoveredAddresses = RemoteDiscoveredAddresses()
    private let continuity: MobileSessionContinuityStore
    /// Optional device-local launch memory is isolated from continuity so corrupt preferences
    /// can never endanger an unsent draft or a saved reading position.
    private let newSessionDefaults: MobileNewSessionDefaultsStore
    /// A bounded per-Mac launch cache. The live `/api/me` response remains authoritative.
    private let themeCache: MobileThemeCacheStore
    /// A bounded per-pairing list cache. Pairing identity is required because `/api/me` is
    /// capability-filtered and two shares on one Mac may expose different sessions.
    private let dashboardCache: MobileDashboardCacheStore
    @Published private var cachedDashboardCatalogues: [String: MobileDashboardCatalogue]
    /// Prevents the asynchronous launch read from republishing a pairing purged while that read
    /// was in flight. A later authenticated catalogue clears its own tombstone after persistence.
    private var discardedDashboardCacheIdentities: Set<String> = []
    private var dashboardCacheWriteTask: Task<Void, Never>?
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
    /// The host whose dashboard recovery is scheduled but has not run yet. Set beside
    /// `themeEventsRecoveryTask`, cleared when that recovery runs or the socket's owner ends it.
    private var themeEventsRecoveryHostID: String?
    /// Decides each path-change probe of the event socket exactly once: by its pong, its error,
    /// or its deadline, whichever comes first.
    private var themeEventsPathProbe = MobileEventSocketPathProbe()
    private var networkPathMonitor: NWPathMonitor?
    private let networkPathQueue = DispatchQueue(
        label: "threading.mobile.model.network-path",
        qos: .utility
    )
    private var networkPathSettleTask: Task<Void, Never>?
    private var lastObservedNetworkPath: MobileNetworkPathSummary?
    /// How long a changed path must stay changed before the sockets are asked about it.
    static let networkPathSettleDelay: Duration = .milliseconds(500)
    /// Advances once per settled material path change. A session screen watches it and asks
    /// its socket whether it is still there; see `RemoteSessionConnection.networkPathChanged()`.
    @Published private(set) var networkPathGeneration = 0
    /// Consecutive automatic recovery waits since the event socket last delivered a frame.
    /// The dashboard uses the count to keep a transient miss in compact progress chrome and
    /// disclose the full recovery surface only after repeated bounded attempts.
    ///
    /// A catalogue answer does not reset it. One did from 2026-08-22, when this counter absorbed
    /// the socket's own, until the 2026-09-06 report showed what that allows: a `304` every
    /// second beside a socket failing every second, at attempt 2 for as long as the journal
    /// reached. A frame on the socket is the reset; `MobileSocketRecoveryBackoff` is the ladder
    /// the count climbs meanwhile, and `check_architecture_boundaries.sh` counts the resets.
    @Published private(set) var connectionRecoveryAttempt = 0
    /// The route this phone last reached a Mac over, for the connection panel. Kept across a
    /// drop so the panel can still say what was in use; the panel reads it only for the Mac it
    /// names.
    @Published private(set) var lastConnection: MobileConnectionRecord?
    private var themeEventsDidReceiveHello = false
    private var catalogueStreamFence = MobileCatalogueStreamFence()
    private var themeEventsStartedAt: UInt64?
    private var themeEventsDiagnosticFields: [RemoteDiagnosticField: String] = [:]
    private var sessionsChangedRefreshTask: Task<Void, Never>?
    private var sessionsChangedRefreshGeneration = 0
    private var pendingSessionDeltas: [String: RemoteSessionsChangedDTO] = [:]
    private var sessionDeltaApplicationTask: Task<Void, Never>?
    private var sessionDeltaApplicationGeneration = 0
    private struct NotificationOpenIdentity: Hashable {
        let hostID: String
        let eventID: String
    }
    private struct PendingNotificationOpen {
        let identity: NotificationOpenIdentity
        let event: RemoteNotificationEventDTO
        let candidateID: String
        var origin: RemoteNotificationOpenOrigin
        let generation: Int
    }
    private var pendingNotificationOpen: PendingNotificationOpen?
    private var notificationOpenTask: Task<Void, Never>?
    private var notificationOpenGeneration = 0
    private var recentNotificationOpenIdentities: [NotificationOpenIdentity] = []
    private var recentNotificationOpenIdentitySet = Set<NotificationOpenIdentity>()
    private static let maximumRecentNotificationOpenCount = 128
    private var catalogueRevision = 0
    private var liveDashboardProjection: (revision: Int, catalogue: MobileDashboardCatalogue)?
    private var catalogueRefreshInFlightGeneration: Int?
    private var refreshGeneration = 0
    /// How many attempts of the walk in progress have failed. One counter rather than one per
    /// walk: a refresh and a mutation can overlap, and what the spinner needs to know is whether
    /// *something* has already failed, not which walk it belonged to.
    private var routeWalkFailures = 0
    private var routeWalksInFlight = 0
    private let hostRefreshSingleFlight = MobileHostRefreshSingleFlight()
    /// Addresses that have refused this phone's identity check repeatedly, rested for a while.
    private let routeHealth = MobileRouteHealthLedger()
    /// The hosted way in as the manager last handed it out, kept so the synchronous route readers
    /// can ask whether a tunnel is standing. Holding it does not make it the route in use:
    /// ``MobileLiveRoutePolicy`` gives the sockets the route that answered last.
    private var hostedRoute = HostedRouteMirror()
    /// Provisioning is a low-frequency control-plane operation. A service outage must not turn
    /// event-socket recovery into a credential-issuance retry loop.
    private var hostedProvisioningRetryAfter: [String: Date] = [:]
    private static let hostedCredentialRenewalLeadTime: TimeInterval = 24 * 60 * 60
    private static let hostedProvisioningRetryDelay: TimeInterval = 5 * 60
    private static let sessionsChangedCoalescingDelay = Duration.milliseconds(350)
    private static let sessionDeltaCoalescingDelay = Duration.milliseconds(50)
    private static let themeEventsHelloDeadline = Duration.seconds(15)
    var mobileDiagnosticsAuthenticatedEventsTask: URLSessionWebSocketTask? {
        themeEventsDidReceiveHello ? themeEventsTask : nil
    }

    init(
        continuity: MobileSessionContinuityStore = MobileSessionContinuityStore(),
        newSessionDefaults: MobileNewSessionDefaultsStore = MobileNewSessionDefaultsStore(),
        themeCache: MobileThemeCacheStore = MobileThemeCacheStore(),
        dashboardCache: MobileDashboardCacheStore = MobileDashboardCacheStore(),
        hostStore: RemoteHostStore = RemoteHostStore(),
        protectedDataAvailable: @escaping () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
    ) {
        self.store = hostStore
        self.protectedDataAvailable = protectedDataAvailable
        self.continuity = continuity
        self.newSessionDefaults = newSessionDefaults
        self.themeCache = themeCache
        self.dashboardCache = dashboardCache
        cachedDashboardCatalogues = [:]
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
            if let demoMode = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey],
               let link = RemoteConnectionLink(
                   string: MobileDemoFixture.isMarketing(demoMode)
                       ? "https://\(DemoExperience.sentinelHost)/#marketing"
                       : "https://david-mac.tailnet-demo.ts.net:8443/#preview"
               )
            {
                isDemo = true
                let isMarketing = MobileDemoFixture.isMarketing(demoMode)
                // This scene photographs a row containing the connection time. Its clock is part of
                // the fixture, not ambient machine state: otherwise every minute creates a visual
                // regression and accepting it merely blesses the time at which the test happened.
                let demoNow = demoMode == "connection-status"
                    ? Date(timeIntervalSince1970: 1_800_000_000)
                    : Date()
                var host = PairedRemoteHost(
                    id: "demo-mac",
                    hostID: "demo-mac",
                    shareID: "my-devices",
                    scope: "all",
                    name: "David’s MacBook Pro",
                    link: link,
                    lastConnectedAt: demoNow,
                    endpoints: isMarketing
                        ? [RemoteHostEndpointDTO(
                            kind: .hosted,
                            baseURL: link.baseURL,
                            isStable: true
                        )]
                        : [
                            RemoteHostEndpointDTO(
                                kind: .tailscale,
                                baseURL: link.baseURL,
                                isStable: true
                            ),
                            RemoteHostEndpointDTO(
                                kind: .lan,
                                baseURL: URL(string: "https://192.168.1.42:8760/")!,
                                isStable: true
                            ),
                        ],
                    connectionPolicy: isMarketing ? nil : .privateOnly,
                    activeEndpointKind: isMarketing ? .hosted : .tailscale
                )
                if demoMode == "sessions-offline" || demoMode == "connection-status" {
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
                    lastConnectedAt: demoNow.addingTimeInterval(-600),
                    endpoints: [RemoteHostEndpointDTO(
                        kind: .tailscale,
                        baseURL: studioLink.baseURL,
                        isStable: true
                    )],
                    connectionPolicy: .privateOnly,
                    activeEndpointKind: .tailscale
                )
                hosts = isMarketing ? [host] : [host, studio]
                activeHostID = host.id
                continuity.setActiveHostID(host.id)
                if demoMode == "sessions-offline" {
                    cachedDashboardCatalogues[host.id] = MobileDashboardCacheSnapshot.make(
                        from: Self.demoResponse,
                        capturedAt: demoNow.addingTimeInterval(-7 * 60)
                    ).flatMap { MobileDashboardCatalogue.current(live: nil, cached: $0) }
                    me = nil
                    phase = .offline(.transport(URLError(.timedOut), host: link.baseURL.host))
                    // This fixture is the settled recovery state, after automatic retries have had
                    // their chance. `isDemo` prevents another attempt from being scheduled.
                    connectionRecoveryAttempt = MobileConnectionRecoveryPolicy.settledFailureAttempt
                } else if demoMode == "sessions-connecting" {
                    cachedDashboardCatalogues[host.id] = MobileDashboardCacheSnapshot.make(
                        from: Self.demoResponse,
                        capturedAt: demoNow.addingTimeInterval(-7 * 60)
                    ).flatMap { MobileDashboardCatalogue.current(live: nil, cached: $0) }
                    me = nil
                    phase = .connecting
                    connectionProgress = .tryingRoute(
                        kind: RemoteHostEndpointKind.lan,
                        previousKind: RemoteHostEndpointKind.hosted,
                        number: 2,
                        total: 3
                    )
                } else {
                    me = Self.demoResponse(for: demoMode)
                    phase = .online
                    lastConnection = .demo(
                        hostID: host.id,
                        baseURL: link.baseURL,
                        kind: isMarketing ? .hosted : .tailscale,
                        now: demoNow
                    )
                }
                return
            }
        #endif
        // Background notification launches must not read an unlocked-only Keychain item.
        // The first foreground/unlock restores off-main before any host refresh or pairing.
        needsHostStorageRecovery = true
        hosts = []
        MobileDiagnosticsIncidentRecorder.shared.attach(self)

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
        needsHostStorageRecovery = false
        deferredHostOpen = nil
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
        lastConnection = .demo(
            hostID: host.id,
            baseURL: host.link.baseURL,
            kind: host.activeEndpointKind ?? PairedRemoteHost.endpointKind(for: host.link.baseURL),
            now: Date()
        )
    }

    /// Leaves the demo and restores whatever was actually paired — for a first-run user,
    /// nothing, which lands back on the welcome screen.
    func endDemo() {
        guard isDemo else { return }
        isDemo = false
        navigationPath = []
        discardHostedConnection()
        me = nil
        hosts = []
        activeHostID = nil
        needsHostStorageRecovery = true
        storageIssue = nil
        store.suspendWrites()
        hostedProvisioningRetryAfter.removeAll(keepingCapacity: false)
        phase = .idle
        Task { await refresh(reason: .hostChanged) }
    }

    /// Unlock and foreground refresh share one read. A failed read is never an empty pairing
    /// set: keep continuity, widgets and the Keychain recovery copy until validation succeeds.
    @discardableResult
    func restorePairedHostsIfNeeded() async -> Bool {
        guard !isDemo, !isEphemeralTerminalWireFixture, needsHostStorageRecovery else { return true }
        if let task = hostStorageRecoveryTask { return await task.value }
        guard protectedDataAvailable() else {
            storageIssue = "Unlock your iPhone to restore your saved Macs."
            return false
        }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let result = await store.reload()
            guard protectedDataAvailable() else {
                store.suspendWrites()
                return false
            }
            guard !isDemo else { return false }
            switch result {
            case let .failure(error):
                storageIssue = error.localizedDescription
                return false
            case let .success(loaded):
                RemoteHostTrust.register(loaded)
                hosts = loaded
                let remembered = continuity.activeHostID
                activeHostID = loaded.first(where: { $0.id == remembered })?.id ?? loaded.first?.id
                continuity.setActiveHostID(activeHostID)
                storageIssue = nil
                needsHostStorageRecovery = false
                if let publisher = usageGlance { installUsageGlancePublisher(publisher) }
                let deferred = deferredHostOpen
                deferredHostOpen = nil
                switch deferred {
                case let .widget(url): _ = open(url)
                case let .notification(event, origin): _ = openSessionFromNotification(event, origin: origin)
                case nil: break
                }
                let catalogues = await dashboardCache.loadCatalogues()
                for (identity, catalogue) in catalogues
                    where hosts.contains(where: { $0.id == identity })
                        && !discardedDashboardCacheIdentities.contains(identity) {
                    cachedDashboardCatalogues[identity] = catalogue
                }
                await dashboardCache.removeExpired()
                return true
            }
        }
        hostStorageRecoveryTask = task
        let restored = await task.value
        hostStorageRecoveryTask = nil
        return restored
    }

    var activeHost: PairedRemoteHost? {
        guard let activeHostID else { return nil }
        return hosts.first { $0.id == activeHostID }
    }

    /// Live rows when available, otherwise the last bounded list for this exact membership.
    var dashboardCatalogue: MobileDashboardCatalogue? {
        if let me {
            if let prepared = liveDashboardProjection, prepared.revision == catalogueRevision {
                return prepared.catalogue
            }
            let prepared = MobileDashboardCatalogue.current(live: me, cached: nil)
            liveDashboardProjection = prepared.map { (catalogueRevision, $0) }
            return prepared
        }
        liveDashboardProjection = nil
        guard let activeHostID,
              let cached = cachedDashboardCatalogues[activeHostID],
              cached.isUsable() else { return nil }
        return cached
    }

    /// Publishes an authoritative refresh only when it changes the value SwiftUI observes.
    ///
    /// `@Published` sends before `didSet`, so an equality guard inside the observer would be too
    /// late: an identical recovery response would still invalidate every dashboard consumer.
    /// Keep the guard at the assignment boundary instead.
    @discardableResult
    func adoptRefreshedCatalogueIfChanged(_ response: RemoteMeDTO) -> Bool {
        guard me != response else { return false }
        me = response
        return true
    }

    func dashboardSession(id: String) -> RemoteSessionSummaryDTO? {
        dashboardCatalogue?.session(id: id)
    }

    /// Applies the session socket's canonical post-visit row immediately. This is the receipt
    /// transaction's acknowledgement path; the dashboard event remains necessary for other
    /// devices, but losing it cannot strand the device that performed the visit.
    func acceptSessionVisit(
        _ visit: RemoteSessionVisitedDTO,
        from hostID: String
    ) {
        guard activeHostID == hostID, visit.receiptCommitted, let current = me else { return }
        let updated = current.applyingCanonicalVisit(visit)
        guard updated != current else { return }
        me = updated
        if updated.revision == nil {
            scheduleSessionsChangedRefresh(for: hostID, reason: .revisionGap)
        }
    }

    func dashboardTerminal(id: String) -> RemoteProjectTerminalSummaryDTO? {
        dashboardCatalogue?.terminal(id: id)
    }

    /// The palette to draw now. On a cold launch the paired-host record is available before the
    /// first authenticated catalogue, so its last resolved theme bridges that bounded interval.
    var appTheme: RemoteThemeDTO? {
        MobileThemeResolution.current(
            live: me?.theme,
            cached: activeThemeCacheIdentities.lazy.compactMap {
                self.themeCache.theme(for: $0)
            }.first
        )
    }

    private var activeThemeCacheIdentities: [String] {
        guard let host = activeHost else { return [] }
        if let hostID = host.hostID, !hostID.isEmpty {
            if hostID == host.id { return ["host:\(hostID)"] }
            return ["host:\(hostID)", "pairing:\(host.id)"]
        }
        return ["pairing:\(host.id)"]
    }

    private func rememberCurrentTheme() {
        guard !isDemo, !isEphemeralTerminalWireFixture, let theme = me?.theme else { return }
        for identity in activeThemeCacheIdentities {
            themeCache.remember(theme, for: identity)
        }
    }

    /// Coalesce hot event-stream updates without starving the cache. Snapshot projection and
    /// JSON work happen away from the main actor; only the successful replacement is published.
    private func rememberCurrentDashboard() {
        guard !isDemo, !isEphemeralTerminalWireFixture, me != nil, activeHostID != nil else {
            return
        }
        guard dashboardCacheWriteTask == nil else { return }
        dashboardCacheWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.flushCurrentDashboardCache()
        }
    }

    private func flushCurrentDashboardCache() async {
        let revision = catalogueRevision
        defer {
            dashboardCacheWriteTask = nil
            if revision != catalogueRevision {
                rememberCurrentDashboard()
            }
        }
        guard !Task.isCancelled,
              !isDemo,
              !isEphemeralTerminalWireFixture,
              let response = me,
              let identity = activeHostID else { return }
        let prepared: (MobileDashboardCacheSnapshot, MobileDashboardCatalogue)? = await Task.detached(
            priority: .utility
        ) { () -> (MobileDashboardCacheSnapshot, MobileDashboardCatalogue)? in
            guard let snapshot = MobileDashboardCacheSnapshot.make(from: response),
                  let catalogue = MobileDashboardCatalogue.current(
                      live: nil,
                      cached: snapshot
                  ) else { return nil }
            return (snapshot, catalogue)
        }.value
        guard !Task.isCancelled,
              activeHostID == identity,
              let prepared else { return }
        if await dashboardCache.remember(prepared.0, for: identity) {
            discardedDashboardCacheIdentities.remove(identity)
            cachedDashboardCatalogues[identity] = prepared.1
        }
    }

    private func discardDashboardSnapshot(for identity: String) {
        if activeHostID == identity {
            dashboardCacheWriteTask?.cancel()
            dashboardCacheWriteTask = nil
        }
        discardedDashboardCacheIdentities.insert(identity)
        cachedDashboardCatalogues[identity] = nil
        Task { await dashboardCache.remove(identity: identity) }
    }

    var client: RemoteClient? {
        activeHost.map { host in
            let route = liveRoute(for: host)
            return RemoteClient(link: route.link, endpointKind: route.kind)
        }
    }

    /// The route a new socket or request is given now. See ``MobileLiveRoutePolicy``.
    private func liveRoute(for host: PairedRemoteHost) -> MobileLiveRoute {
        MobileLiveRoutePolicy.route(
            for: host,
            lastConnection: lastConnection,
            hostedLink: liveHostedLink(for: host)
        )
    }

    /// The hosted loopback link, and only while the tunnel behind it is standing. A tunnel that
    /// has ended keeps its origin in memory until the next negotiation replaces it; that origin
    /// refuses every dial and is no route at all.
    private func liveHostedLink(for host: PairedRemoteHost) -> RemoteConnectionLink? {
        hostedRoute.standingLink(for: host.id)
    }

    var canManageThemes: Bool {
        me?.share.scope == .all
            && me?.share.capability == .interact
            && me?.themeCatalog != nil
    }

    var canManageSessions: Bool {
        me?.share.scope == .all
            && me?.share.capability == .interact
            && me?.newSessionCatalog != nil
    }

    var canReadUsage: Bool {
        me?.features?.contains(RemoteRESTFeature.usageDashboard.rawValue) == true
    }

    func installUsageGlancePublisher(_ publisher: MobileUsageGlancePublisher) {
        usageGlance = publisher
        widgetHostID = publisher.pairingID
        publisher.reportIssue = { [weak self, weak publisher] issue in
            self?.widgetIssue = issue
            self?.widgetHostID = publisher?.pairingID
        }
        if !needsHostStorageRecovery, storageIssue == nil,
           let pinned = publisher.pairingID, !hosts.contains(where: { $0.id == pinned }) {
            publisher.choose(nil)
            widgetHostID = nil
        }
    }

    func setWidgetsEnabled(_ enabled: Bool) {
        usageGlance?.choose(enabled ? activeHostID : nil)
        widgetHostID = usageGlance?.pairingID
        if enabled { refreshUsageGlance(features: me?.features) }
    }

    private func refreshUsageGlance(features: [String]?) {
        guard !isDemo, !isEphemeralTerminalWireFixture,
              let host = activeHost, host.id == usageGlance?.pairingID,
              let client else { return }
        guard features?.contains(RemoteRESTFeature.usageCapacity.rawValue) == true else {
            widgetIssue = .hostUpdateNeeded
            return
        }
        usageGlance?.refresh(pairingID: host.id, hostName: host.name, client: client)
    }

    /// Whether the Mac answers the continuation route at all. An older one does not, and the
    /// phone then offers no such control rather than asking and reporting the 404 as a failure.
    var canContinueChatsElsewhere: Bool {
        canManageSessions
            && me?.features?.contains(RemoteRESTFeature.sessionContinuation.rawValue) == true
    }

    var canUseUniversalSearch: Bool {
        me?.features?.contains(RemoteRESTFeature.universalSearch.rawValue) == true
    }

    /// Routes a URL the operating system handed this app.
    ///
    /// Answers whether the URL was Threading's, so a scene that was given several can stop at
    /// the first one that meant something and leave the rest alone. It opens the pairing screen
    /// rather than accepting silently: accepting an invitation creates a durable membership on
    /// somebody else's Mac, which is not something a tap should do without showing its work.
    @discardableResult
    func open(_ url: URL) -> Bool {
        if let route = UsageGlanceRoute(url: url) {
            if needsHostStorageRecovery {
                deferredHostOpen = .widget(url)
                Task { await restorePairedHostsIfNeeded() }
                return true
            }
            guard hosts.contains(where: { $0.id == route.pairingID }) else { return true }
            selectHost(route.pairingID)
            navigationPath.removeAll()
            widgetUsageRoute = route
            widgetUsageFocus = nil
            widgetUsageFocusReady = false
            Task { [weak self] in
                let snapshot = try? await UsageGlanceStore.shared.read()
                guard let self, widgetUsageRoute == route else { return }
                if snapshot?.pairingID == route.pairingID,
                   let account = snapshot?.account(id: route.accountID) {
                    widgetUsageFocus = MobileUsageAccountFocus(runtimeName: account.runtimeName,
                        accountName: account.accountName,
                        accountID: "\(account.runtimeID):\(account.accountID)")
                }
                widgetUsageFocusReady = true
                await refresh(reason: .userCheck)
            }
            return true
        }
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
        transport: RemoteHostEndpointKind,
        recordsStart: Bool = true
    ) async throws {
        guard await restorePairedHostsIfNeeded() else { throw RemoteHostStore.StoreError.unreadable }
        phase = .connecting
        let startedAt = MobileDiagnostics.monotonicNow()
        let pairingFields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .transport: transport.rawValue,
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
        let id = me.share.scope == .all
            ? hostID
            : "\(hostID):share:\(me.share.label)"
        var hostedServiceURL = hosts.first(where: { $0.id == id })?.hostedServiceURL
        var hostedCredential = hosts.first(where: { $0.id == id })?.hostedCredential
        if me.features?.contains(RemoteRESTFeature.hostedPeerTransport.rawValue) == true
        {
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
                    expectedHostID: hostID,
                    expectedDeviceID: me.share.scope == .all ? RemoteDeviceIdentity.current
                        : RemoteInvitationWebLink.guestDeviceID(shareID: me.share.label)
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
                // A hosted-only acceptance cannot persist a loopback URL after this tunnel
                // stops. Retry the same invitation while the Mac retains its device-bound receipt.
                if transport == .hosted { throw error }
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
            scope: me.share.scope.rawValue,
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
            pinnedFingerprint: me.share.scope == .all ? identity?.pinnedFingerprint : nil,
            nextPinnedFingerprint: me.share.scope == .all ? identity?.nextPinnedFingerprint : nil
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
            .capability: me.share.capability.rawValue,
        ]) { _, new in new })
    }

    func pair(_ hostedLink: HostedPairingLink, displayName: String) async throws {
        guard await restorePairedHostsIfNeeded() else { throw RemoteHostStore.StoreError.unreadable }
        guard !hostedLink.isExpired else { throw PeerControlPlaneError.invalidCredential }
        phase = .connecting
        let endpoint = try PeerControlPlaneServiceEndpoint(hostedLink.serviceURL)
        let credential = try PeerRendezvousCredential(hostedLink.rendezvousCredential)
        let trace = MobileDiagnostics.connectivityTrace()
        let startedAt = MobileDiagnostics.monotonicNow()
        let pairingFields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .transport: RemoteHostEndpointKind.hosted.rawValue,
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
                        .transport: RemoteHostEndpointKind.hosted.rawValue,
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
        await refresh(reason: .hostChanged)
    }

    func selectHost(_ id: String) {
        guard hosts.contains(where: { $0.id == id }), activeHostID != id else { return }
        usageGlance?.suspend()
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
            .peer: MobileDiagnostics.pseudonym(host.id, prefix: "peer"),
        ])
        let previousHosts = hosts
        hosts.removeAll { $0.id == host.id }
        hostedProvisioningRetryAfter[host.id] = nil
        guard persistHosts() else {
            hosts = previousHosts
            return
        }
        discardDashboardSnapshot(for: host.id)
        if usageGlance?.pairingID == host.id {
            usageGlance?.choose(nil)
            widgetHostID = nil
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

    /// Brings the catalogue up to date, at the cost `MobileRefreshPolicy` decides for the reason.
    ///
    /// `.userCheck` is the default because a caller that does not say why is a person pressing
    /// a button, and that always earns the full race. Every other caller names its reason so the
    /// journal can attribute the refresh and the policy can decline or cheapen it.
    func refresh(reason: MobileRefreshReason = .userCheck) async {
        guard !isDemo else { return }
        guard await restorePairedHostsIfNeeded() else { return }
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
            await self.performRefresh(from: host, reason: reason)
        }
    }

    /// The catalogue edition in hand, which a conditional refresh names to the Mac. Nil until a
    /// host that knows editions has answered, and nil again after a local rebuild could not say
    /// which edition it corresponds to.
    var catalogueEdition: RemoteCatalogueRevisionDTO? {
        me?.revision
    }

    /// Whether the dashboard's event socket is authenticated and delivering for this host, which
    /// is what makes the catalogue in hand authoritative without asking.
    func isEventSocketHealthy(for hostID: String) -> Bool {
        themeEventsTask != nil && themeEventsDidReceiveHello && themeEventsHostID == hostID
            && !catalogueStreamFence.requiresRefresh
    }

    /// Resolves a cached navigation id against an authoritative catalogue before any resume or
    /// socket is attempted. The detail screen can appear immediately, but it waits here while
    /// the dashboard's single-flight reconnect does the network work.
    func liveSessionForOpening(id: String) async throws -> RemoteSessionSummaryDTO {
        if openNeedsHostRecovery {
            await refresh(reason: .openTarget)
        }
        guard let response = me else {
            if let failure = phase.failure { throw failure }
            throw RemoteClientError.invalidResponse
        }
        guard let session = response.sessions.first(where: { $0.id == id })
            ?? response.archivedSessions?.first(where: { $0.id == id }) else {
            throw MobileDashboardItemError.sessionUnavailable
        }
        return session
    }

    func liveTerminalForOpening(id: String) async throws -> RemoteProjectTerminalSummaryDTO {
        if openNeedsHostRecovery {
            await refresh(reason: .openTarget)
        }
        guard let response = me else {
            if let failure = phase.failure { throw failure }
            throw RemoteClientError.invalidResponse
        }
        guard let terminal = response.terminals?.first(where: { $0.id == id }) else {
            throw MobileDashboardItemError.terminalUnavailable
        }
        return terminal
    }

    /// Whether opening a chat or terminal has to go through host recovery before it takes the
    /// model's client. A pending dashboard recovery means the route that client names is the one
    /// that just failed; the open joins that recovery (or starts it early) rather than dialling
    /// the old origin and waiting out a hello deadline on it.
    private var openNeedsHostRecovery: Bool {
        MobileConnectionRecoveryPolicy.openNeedsHostRecovery(
            isOnline: phase == .online,
            hasCatalogue: me != nil,
            dashboardRecoveryPending: activeHostID.map(isDashboardRecoveryPending(for:)) ?? false
        )
    }

    /// Returns a route for a live-session reconnect without turning one refused session socket
    /// into a full catalogue race. If dashboard recovery owns or has scheduled that race, the
    /// session joins it; if the model has no authoritative catalogue, or the loss says the route
    /// itself is suspect, it starts one. Only a socket the Mac closed on purpose gets the last
    /// authenticated route back for an inexpensive first retry.
    func clientForSessionReconnect(
        hostID: String,
        request: MobileSessionReconnectRequest
    ) async -> RemoteClient? {
        guard activeHostID == hostID else { return nil }
        if phase != .online
            || me == nil
            || MobileConnectionRecoveryPolicy.sessionReconnectNeedsHostRecovery(
                request,
                dashboardRecoveryPending: isDashboardRecoveryPending(for: hostID)
            )
        {
            await refresh(reason: .socketRecovery)
        }
        guard activeHostID == hostID else { return nil }
        return client
    }

    /// True from the moment the dashboard event socket schedules its recovery until that
    /// recovery has run, not only while the route race itself is in flight.
    ///
    /// Both sockets lose the same transport within milliseconds and both sleep the same second
    /// before retrying, so whichever wakes first finds no flight. Counting the scheduled recovery
    /// closes that window: the session starts the race and the dashboard joins it, or the other
    /// way round, and neither dials the old origin on its own.
    func isDashboardRecoveryPending(for hostID: String) -> Bool {
        hostRefreshSingleFlight.hasFlight(for: hostID) || themeEventsRecoveryHostID == hostID
    }

    /// The routes a notification registration walks for `host`, in the order a mutation would
    /// take them. Joined to any catalogue refresh in flight for that Mac first: a registration
    /// started beside a launch used to walk the persisted order while the race beside it was
    /// finding the Mac, and reached the route the race had found at attempt 4 of 14.
    func registrationRoutes(for host: PairedRemoteHost) async -> [RemoteHostConnectionCandidate] {
        await hostRefreshSingleFlight.join(hostID: host.id)
        let admitted = routeHealth.admitting(
            host.candidates(preferring: discoveredAddresses[host.id]),
            origin: { $0.link.baseURL }
        )
        return MobileRouteWalkPlan.plan(
            direct: admitted,
            hasHostedRoute: false,
            hostID: host.id,
            lastConnection: lastConnection,
            origin: { $0.link.baseURL }
        ).direct
    }

    /// The origin and kind of address a new socket would be given now. See ``MobileRouteIdentity``.
    var routeIdentity: MobileRouteIdentity? {
        client.map { MobileRouteIdentity(origin: $0.link.baseURL, endpointKind: $0.endpointKind) }
    }

    private func performRefresh(from host: PairedRemoteHost, reason: MobileRefreshReason) async {
        let hostID = host.id
        let warm = warmCandidate(for: host)
        let edition = catalogueEdition
        let decision = MobileRefreshPolicy.decide(
            reason: reason,
            hasCatalogue: phase == .online && me != nil,
            eventSocketHealthy: isEventSocketHealthy(for: hostID),
            canRefreshConditionally: warm != nil && edition != nil
        )
        guard decision != .skip else { return }

        // One walk for the whole refresh, probe included, so a chat title that names the route
        // being tried says so from the probe's failure onward rather than from the race's second
        // attempt. `fetchMe` opens its own nested walk; the count keeps the status one story.
        beginRouteWalk()
        defer { endRouteWalk() }
        discardPendingSessionDeltas()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let refreshTrace = MobileDiagnostics.connectivityTrace()
        let refreshStartedAt = MobileDiagnostics.monotonicNow()
        let refreshBaseFields: [RemoteDiagnosticField: String] = [
            .trace: refreshTrace,
            .peer: MobileDiagnostics.pseudonym(hostID, prefix: "peer"),
            .phase: "refresh",
        ]
        MobileDiagnostics.recordConnectivity(
            .hostRefreshStarted,
            fields: refreshBaseFields.merging([
                .result: "started",
                .reason: reason.rawValue,
                .detail: decision.rawValue,
            ]) { current, _ in current }
        )
        catalogueRefreshInFlightGeneration = generation
        defer {
            if catalogueRefreshInFlightGeneration == generation {
                catalogueRefreshInFlightGeneration = nil
                startSessionDeltaApplicationIfNeeded(for: hostID)
            }
        }
        let wasOnline = phase == .online && me != nil
        // What the walk would try, asked here only for its size: a host with one way in has no
        // ceiling and no short warm probe, because there is no other route to get on with.
        // Bounded by the advertised endpoint list and the one sticky range, so this is a few
        // dozen URL constructions.
        let plannedCandidateCount = host.candidates(
            preferring: discoveredAddresses[host.id]
        ).count
        let plannedRouteCount = plannedCandidateCount + (hasHostedRoute(host) ? 1 : 0)

        // The cheap path first: one request on the route that answered last, naming the edition
        // in hand. A `304` settles the refresh; a full body is adopted like any race winner; a
        // transport failure on that one route says nothing about the others and falls through
        // to the race below — which is why the probe is given one route attempt, not a whole
        // request timeout, whenever that race has somewhere else to go.
        if decision == .conditional, let warm, let edition {
            switch await refreshConditionally(
                from: host,
                candidate: warm,
                edition: edition,
                timeout: RemoteRouteWalkBudget.warmProbeTimeout(
                    hasOtherRoutes: plannedRouteCount > 1
                ),
                generation: generation,
                wasOnline: wasOnline,
                trace: refreshTrace,
                baseFields: refreshBaseFields,
                startedAt: refreshStartedAt
            ) {
            case .settled:
                return
            case .fallBackToFullRace:
                break
            }
        }

        if !wasOnline {
            phase = .connecting
            connectionProgress = .preparingRoutes
        }
        do {
            // The ceiling owns the whole race. Once it answers, every request from that generation
            // is cancelled before recovery may start a fresh one; two refreshes never compete to
            // become the host's authoritative route.
            let connection = try await RemoteRouteWalkDeadline.run(
                ceiling: RemoteRouteWalkBudget.ceiling(
                    forCandidateCount: plannedCandidateCount
                ),
                walk: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchMe(
                        from: host,
                        reportsProgress: !wasOnline,
                        trace: refreshTrace
                    )
                },
                exceeded: {
                    RemoteConnectionAttempt(
                        underlying: URLError(.timedOut),
                        host: host.link.baseURL.host
                    )
                }
            )
            await applyRefreshSuccess(
                connection,
                host: host,
                hostID: hostID,
                generation: generation,
                wasOnline: wasOnline,
                trace: refreshTrace,
                baseFields: refreshBaseFields,
                startedAt: refreshStartedAt
            )
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
            if MobileDashboardCachePolicy.discardsSnapshot(after: error) {
                if usageGlance?.pairingID == hostID {
                    usageGlance?.choose(nil)
                    widgetHostID = nil
                }
                // A revoked or expired membership invalidates both the list and its live-looking
                // predecessor. Ordinary transport failures keep the last-good presentation.
                me = nil
                if activeHostID == hostID {
                    dashboardCacheWriteTask?.cancel()
                    dashboardCacheWriteTask = nil
                }
                discardedDashboardCacheIdentities.insert(hostID)
                cachedDashboardCatalogues[hostID] = nil
                _ = await dashboardCache.remove(identity: hostID)
                cachedDashboardCatalogues[hostID] = nil
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

    /// Adopts the successful race through the one path that persists pins and starts its socket.
    private func applyRefreshSuccess(
        _ connection: SuccessfulConnection,
        host: PairedRemoteHost,
        hostID: String,
        generation: Int,
        wasOnline: Bool,
        trace refreshTrace: String,
        baseFields refreshBaseFields: [RemoteDiagnosticField: String],
        startedAt refreshStartedAt: UInt64
    ) async {
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
        adoptRefreshedCatalogueIfChanged(response)
        phase = .online
        lastConnection = MobileConnectionRecord(
            hostID: hostID,
            kind: connection.kind,
            baseURL: successfulLink.baseURL,
            isHosted: connection.isHosted,
            connectedAt: Date(),
            metrics: connection.metrics,
            serverProtocol: response.serverProtocol
        )
        restoreRouteIfPossible(hostID: hostID, response: response)
        MobileDiagnostics.recordConnectivity(
            .hostRefreshSucceeded,
            fields: refreshBaseFields.merging([
                .result: "succeeded",
                .status: MobileDiagnostics.fullCatalogueStatus,
                .durationMS: MobileDiagnostics.elapsedMilliseconds(since: refreshStartedAt),
                .transport: connection.kind.rawValue,
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
            refreshUsageGlance(features: response.features)
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
        await refresh(reason: .dashboardAppeared)
    }

    func suspendHostedConnections() {
        usageGlance?.suspend()
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
        // Current hosts hold this session's authenticated socket until the resumed surface can
        // send its ordinary hello. Readiness is therefore session-scoped and the catalogue never
        // enters the wait. Keep the old bounded polling only for an installed older Mac.
        if me?.features?.contains(RemoteRESTFeature.sessionStartupHandshake.rawValue) == true {
            return
        }
        let client = RemoteClient(link: link)
        guard activeHostID == hostID else { throw CancellationError() }

        for _ in 0 ..< 30 {
            try Task.checkCancellation()
            let response = try await client.fetchMe()
            guard activeHostID == hostID else { throw CancellationError() }
            me = response
            if response.sessions.first(where: { $0.id == session.id })?.isAvailable == true {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RemoteClientError.server(status: 408)
    }

    func makeTerminalReady(_ terminal: RemoteProjectTerminalSummaryDTO) async throws {
        guard !terminal.isAvailable, let host = activeHost else { return }
        guard me?.share.capability == .interact else {
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
        for _ in 0 ..< 30 {
            try Task.checkCancellation()
            let response = try await client.fetchMe()
            guard activeHostID == hostID else { throw CancellationError() }
            me = response
            if response.terminals?.first(where: { $0.id == terminal.id })?.isAvailable == true {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RemoteClientError.server(status: 408)
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
        role: RemoteSessionRole? = nil,
        reportOpening: RemoteReportSessionOpeningDTO? = nil,
        openingAttachmentScopeID: String? = nil,
        openingAttachmentUploadIDs: [String] = [],
        prompt: String
    ) async throws -> MobileCreatedSession {
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
            role: role,
            reportOpening: reportOpening,
            openingAttachmentScopeID: openingAttachmentScopeID,
            openingAttachmentUploadIDs: openingAttachmentUploadIDs.isEmpty
                ? nil
                : openingAttachmentUploadIDs,
            compactResponse: true,
            prompt: prompt
        )
        if isDemo {
            // The demo Mac starts nothing, so the draft becomes an existing canned chat — one
            // on the surface that was asked for, or the demo would answer a terminal draft
            // with a conversation and open a screen the choices never named.
            let sessions = me?.sessions ?? Self.demoResponse.sessions
            return MobileCreatedSession(
                session: sessions.first { $0.surface == surface }
                    ?? sessions.first
                    ?? Self.demoResponse.sessions[0],
                openingStrategy: .awaitCreatedSession
            )
        }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.createSession(request, requestID: requestID)
        }
        guard activeHostID == hostID else { throw CancellationError() }
        if let session = response.session, session.id == response.sessionID {
            guard let current = me else { throw RemoteClientError.invalidResponse }
            me = current.applying([RemoteSessionsChangedDTO(session: session)])
            return MobileCreatedSession(
                session: session,
                // Create owns this launch whether the host answered before or after its surface
                // became ready. Never begin a second resume transaction for the row it returned.
                openingStrategy: .awaitCreatedSession
            )
        }
        // An older Mac ignored `compactResponse` and returned the original snapshot. Preserve
        // that protocol path and its readiness behaviour until the host advertises the handshake.
        guard let responseMe = response.me,
              let session = responseMe.sessions.first(where: { $0.id == response.sessionID })
        else { throw RemoteClientError.invalidResponse }
        me = responseMe
        return MobileCreatedSession(session: session, openingStrategy: .resumeIfNeeded)
    }

    func newSessionChoiceIdentity(
        agentID: String,
        accountID: String
    ) -> MobileNewSessionChoiceIdentity? {
        guard let activeHost,
              let stableHostID = activeHost.hostID ?? activeHostID,
              !stableHostID.isEmpty,
              !agentID.isEmpty,
              !accountID.isEmpty else { return nil }
        return MobileNewSessionChoiceIdentity(
            // Prefer the identity the Mac signs over the phone-local pairing record. A route
            // change or re-pair must not turn the same Mac into a different defaults scope.
            hostID: stableHostID,
            agentID: agentID,
            accountID: accountID
        )
    }

    func rememberedNewSessionChoice(
        for identity: MobileNewSessionChoiceIdentity
    ) -> MobileNewSessionRunChoice? {
        newSessionDefaults.choice(for: identity)
    }

    /// The caller reaches this only after `createSession` succeeds, so failed and abandoned
    /// drafts never become the next draft's remembered answer.
    func rememberNewSessionChoice(
        _ choice: MobileNewSessionRunChoice,
        for identity: MobileNewSessionChoiceIdentity
    ) {
        guard !isDemo else { return }
        newSessionDefaults.remember(choice, for: identity)
    }

    var canManageProjectVisibility: Bool {
        canManageSessions && me?.features?.contains(RemoteRESTFeature.projectVisibility.rawValue) == true
    }

    func setProjectHidden(_ hidden: Bool, projectID: String) async throws {
        guard canManageProjectVisibility, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        if isDemo { return }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.setProjectHidden(projectID: projectID, isHidden: hidden, requestID: requestID)
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response
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
        guard archiveMutationSessionIDs.insert(session.id).inserted else { return }
        defer { archiveMutationSessionIDs.remove(session.id) }
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

    func reportArchiveMutationFailure(_ error: Error) {
        archiveMutationError = error.localizedDescription
    }

    func clearArchiveMutationFailure() {
        archiveMutationError = nil
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

    /// Where this chat could continue on another agent.
    ///
    /// Read-only and asked once, when the screen offering the choice opens: the Mac resolves it
    /// from a transcript on disk, which is not something a session row can carry for every chat
    /// in every snapshot. An empty list means the control is not offered.
    func continuationOptions(
        for session: RemoteSessionSummaryDTO
    ) async throws -> RemoteSessionContinuationOptionsDTO {
        guard canManageSessions else { throw RemoteClientError.unauthorized }
        if isDemo { return demoContinuationOptions(for: session) }
        guard canContinueChatsElsewhere else {
            return RemoteSessionContinuationOptionsDTO(destinations: [])
        }
        guard let client else { throw RemoteClientError.unauthorized }
        return try await client.sessionContinuationOptions(sessionID: session.id)
    }

    /// Continues this chat on another agent, returning the new chat's identity.
    ///
    /// The source chat is left resumable; the Mac freezes its transcript and creates a sibling
    /// whose first turn reads that snapshot. The caller navigates to what comes back.
    func continueSession(
        _ destination: RemoteContinuationDestinationDTO,
        from session: RemoteSessionSummaryDTO
    ) async throws -> String {
        guard canManageSessions, let host = activeHost else {
            throw RemoteClientError.unauthorized
        }
        let hostID = host.id
        // The demo Mac creates nothing. Answer with the canned chat that already runs the agent
        // that was chosen, so the screen after the choice is one this agent could really be in.
        if isDemo {
            let sessions = me?.sessions ?? Self.demoResponse.sessions
            guard let landing = sessions.first(where: { $0.agentKind == destination.agentID })
                ?? sessions.first(where: { $0.id != session.id })
            else { throw RemoteClientError.invalidResponse }
            return landing.id
        }
        let response = try await performMutation(for: hostID) { client, requestID in
            try await client.continueSession(
                sessionID: session.id,
                agentID: destination.agentID,
                accountID: destination.accountID,
                requestID: requestID
            )
        }
        guard activeHostID == hostID else { throw CancellationError() }
        me = response.me
        return response.sessionID
    }

    /// The demo's own answer, derived from its catalogue rather than a second fixture: every
    /// agent that is not the one this chat already runs.
    private func demoContinuationOptions(
        for session: RemoteSessionSummaryDTO
    ) -> RemoteSessionContinuationOptionsDTO {
        let agents = me?.newSessionCatalog?.agents
            ?? Self.demoResponse.newSessionCatalog?.agents
            ?? []
        return RemoteSessionContinuationOptionsDTO(
            destinations: agents
                .filter { $0.id != session.agentKind }
                .flatMap { agent -> [RemoteContinuationDestinationDTO] in
                    guard let accounts = agent.accounts, !accounts.isEmpty else {
                        return [.init(agentID: agent.id, agentName: agent.name)]
                    }
                    return accounts.map { account in
                        .init(
                            agentID: agent.id,
                            agentName: agent.name,
                            accountID: account.id,
                            accountName: account.name,
                            emoji: account.emoji
                        )
                    }
                }
        )
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
        capability: RemoteCapability,
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
        capability: RemoteCapability
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

    /// Begins one navigation transaction for a notification response.
    ///
    /// UIKit may describe one tap both on `UIScene.ConnectionOptions` and through the user-
    /// notification-center delegate. The event identity is admitted synchronously, before any
    /// refresh can restore continuity, so both callbacks converge on one task and one route.
    @discardableResult
    func openSessionFromNotification(
        _ event: RemoteNotificationEventDTO,
        origin: RemoteNotificationOpenOrigin
    ) -> Bool {
        if needsHostStorageRecovery {
            if case let .notification(previous, previousOrigin) = deferredHostOpen,
               previous.id == event.id, previous.hostID == event.hostID {
                deferredHostOpen = .notification(event, previousOrigin.merged(with: origin))
                return false
            }
            deferredHostOpen = .notification(event, origin)
            Task { await restorePairedHostsIfNeeded() }
            return true
        }
        let candidate = hosts.first {
            ($0.hostID ?? $0.id) == event.hostID && $0.isOwnerDevice
        } ?? hosts.first { ($0.hostID ?? $0.id) == event.hostID }
        guard let candidate else { return false }

        let identity = NotificationOpenIdentity(hostID: event.hostID, eventID: event.id)
        if var pending = pendingNotificationOpen, pending.identity == identity {
            pending.origin = pending.origin.merged(with: origin)
            pendingNotificationOpen = pending
            return false
        }
        guard !recentNotificationOpenIdentitySet.contains(identity) else { return false }
        rememberNotificationOpen(identity)

        notificationOpenGeneration &+= 1
        let generation = notificationOpenGeneration
        notificationOpenTask?.cancel()
        notificationOpenRequest = nil
        pendingNotificationOpen = PendingNotificationOpen(
            identity: identity,
            event: event,
            candidateID: candidate.id,
            origin: origin,
            generation: generation
        )

        selectHost(candidate.id)
        notificationOpenTask = Task { @MainActor [weak self] in
            await self?.performNotificationOpen(generation: generation)
        }
        return true
    }

    private func performNotificationOpen(generation: Int) async {
        await refresh(reason: .notificationOpen)
        guard !Task.isCancelled,
              let pending = pendingNotificationOpen,
              pending.generation == generation,
              activeHostID == pending.candidateID else {
            finishNotificationOpen(generation: generation)
            return
        }
        guard let response = me,
              response.sessions.contains(where: { $0.id == pending.event.sessionID }) else {
            finishNotificationOpen(generation: generation)
            if let response = me, activeHostID == pending.candidateID {
                restoreRouteIfPossible(hostID: pending.candidateID, response: response)
            }
            return
        }

        if openSessionID != pending.event.sessionID {
            switch pending.origin {
            case .notificationCenter:
                navigationPath.append(.session(pending.event.sessionID))
            case .connectingScene:
                navigationPath = [.session(pending.event.sessionID)]
            }
        }
        notificationOpenRequest = RemoteNotificationOpenRequest(
            eventID: pending.event.id,
            sessionID: pending.event.sessionID,
            destination: pending.event.destination
        )
        finishNotificationOpen(generation: generation)
    }

    private func finishNotificationOpen(generation: Int) {
        guard pendingNotificationOpen?.generation == generation else { return }
        pendingNotificationOpen = nil
        notificationOpenTask = nil
    }

    private func rememberNotificationOpen(_ identity: NotificationOpenIdentity) {
        recentNotificationOpenIdentities.append(identity)
        recentNotificationOpenIdentitySet.insert(identity)
        let overflow = recentNotificationOpenIdentities.count
            - Self.maximumRecentNotificationOpenCount
        guard overflow > 0 else { return }
        for expired in recentNotificationOpenIdentities.prefix(overflow) {
            recentNotificationOpenIdentitySet.remove(expired)
        }
        recentNotificationOpenIdentities.removeFirst(overflow)
    }

    func consumeNotificationOpenRequest(eventID: String) {
        guard notificationOpenRequest?.eventID == eventID else { return }
        notificationOpenRequest = nil
    }

    /// The session a route shows, whether it was opened by id or drafted into being.
    func sessionID(for route: MobileNavigationRoute?) -> String? {
        switch route {
        case let .session(id), let .sessionWorkspace(id, _): return id
        case let .draft(draft): return startedDrafts[draft.id]?.sessionID
        case .project, .searchProject, .terminal, .none: return nil
        }
    }

    /// The session the screen on top is showing, if it is showing one.
    var openSessionID: String? {
        sessionID(for: navigationPath.last)
    }

    /// Start was answered: the draft's screen now shows this session. The path itself does not
    /// change — that is the point — so the route record is refreshed here, where the top route
    /// began naming a session without moving.
    func noteDraftStarted(_ draft: MobileSessionDraft, creation: MobileCreatedSession) {
        startedDrafts[draft.id] = MobileStartedDraft(
            sessionID: creation.session.id,
            openingStrategy: creation.openingStrategy
        )
        recordLastRoute()
    }

    private func recordLastRoute() {
        guard !isEphemeralTerminalWireFixture else { return }
        guard let activeHostID else { return }
        if let sessionID = openSessionID {
            continuity.setLastRoute(hostID: activeHostID, sessionID: sessionID)
        } else {
            continuity.clearLastRoute()
        }
    }

    func restoreRouteIfPossible(hostID: String, response: RemoteMeDTO) {
        guard pendingNotificationOpen == nil,
              widgetUsageRoute == nil,
              navigationPath.isEmpty,
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

    // MARK: - The network path

    /// Starts watching the network path, for as long as the app is in the foreground.
    ///
    /// A socket the phone still calls connected can be dead on the wire for as long as iOS takes
    /// to notice, and before this the phone reacted to a path change nowhere outside the
    /// connection panel: a person who walked from Wi-Fi to cellular with a chat open sat on a
    /// connected-looking socket until something aborted it (2026-09-11). The path is the one
    /// piece of evidence the phone has before that, so a material change asks every socket
    /// whether it is still there, at once.
    func startNetworkPathWatch() {
        guard !isDemo, !isEphemeralTerminalWireFixture, networkPathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = MobileNetworkPathSummary(path)
            Task { @MainActor [weak self] in
                self?.networkPathObserved(summary)
            }
        }
        networkPathMonitor = monitor
        monitor.start(queue: networkPathQueue)
    }

    /// Stops watching. The background has its own recovery on return, and a path that changes
    /// while the app is suspended is answered by the activation probe.
    func stopNetworkPathWatch() {
        networkPathMonitor?.cancel()
        networkPathMonitor = nil
        networkPathSettleTask?.cancel()
        networkPathSettleTask = nil
        lastObservedNetworkPath = nil
    }

    /// One observation from the monitor. Immaterial changes are dropped; material ones settle for
    /// a moment, because a handoff reports several paths in quick succession and the sockets
    /// should be asked about the one that stays.
    func networkPathObserved(_ summary: MobileNetworkPathSummary) {
        let previous = lastObservedNetworkPath
        lastObservedNetworkPath = summary
        guard MobileNetworkPathChangePolicy.isMaterial(from: previous, to: summary) else { return }
        networkPathSettleTask?.cancel()
        networkPathSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.networkPathSettleDelay)
            guard !Task.isCancelled else { return }
            self?.networkPathSettled()
        }
    }

    /// The path has changed and stayed changed. Session sockets learn through the generation;
    /// the dashboard's own socket is asked here: a ping when it is delivering, and recovery now
    /// — not after whatever backoff was counting toward the old network — when it is not.
    private func networkPathSettled() {
        networkPathSettleTask = nil
        networkPathGeneration &+= 1
        guard let host = activeHost, !isDemo else { return }
        let hostID = host.id
        if let task = themeEventsTask, themeEventsDidReceiveHello, themeEventsHostID == hostID {
            let generation = themeEventsGeneration
            let probe = networkPathGeneration
            task.sendPing { [weak self] error in
                Task { @MainActor in
                    guard let self, self.themeEventsGeneration == generation,
                          self.themeEventsTask === task,
                          self.themeEventsPathProbe.pingReturned(
                              probe: probe,
                              failed: error != nil
                          ) == .recover else { return }
                    self.recoverThemeEventsAfterPathChange(for: hostID)
                }
            }
            Task { [weak self, deadline = RemoteMobileConnectionDefaults.resumeLivenessDeadline] in
                try? await Task.sleep(for: deadline)
                guard let self, self.themeEventsGeneration == generation,
                      self.themeEventsTask === task, self.networkPathGeneration == probe,
                      self.themeEventsPathProbe.deadlinePassed(probe: probe) == .recover
                else { return }
                self.recoverThemeEventsAfterPathChange(for: hostID)
            }
            return
        }
        guard hostRefreshSingleFlight.hasFlight(for: hostID) == false else { return }
        themeEventsRecoveryTask?.cancel()
        themeEventsRecoveryTask = nil
        themeEventsRecoveryHostID = nil
        Task { [weak self] in
            await self?.refresh(reason: .networkPathChanged)
        }
    }

    /// The event socket did not answer the ping the path change sent. It is torn down as a
    /// loss and recovered at once.
    private func recoverThemeEventsAfterPathChange(for hostID: String) {
        guard themeEventsHostID == hostID, themeEventsTask != nil else { return }
        MobileDiagnostics.recordConnectivity(
            .socketFailed,
            level: .error,
            fields: themeEventFields(phase: "events.session").merging([
                .result: "failed",
                .code: "liveness.pathChanged",
                .reason: MobileRefreshReason.networkPathChanged.rawValue,
            ]) { _, new in new }
        )
        clearThemeEventSocket()
        themeEventsRecoveryTask?.cancel()
        themeEventsRecoveryTask = nil
        themeEventsRecoveryHostID = nil
        Task { [weak self] in
            await self?.refresh(reason: .networkPathChanged)
        }
    }

    /// Where a paired Mac was last found on this network, if the browse has seen it.
    func discoveredAddress(forHostID id: String) -> URL? {
        discoveredAddresses[id]
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
            .transport: RemoteHostEndpointKind.lan.rawValue,
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
        let kind: RemoteHostEndpointKind
        /// Which advertised door this attempt belongs to, so the rest of a port walk can be
        /// abandoned once that door has answered. Nil for the hosted route, which is one
        /// rendezvous rather than an address with ports on it.
        let doorID: String?
        /// Which pass of the walk this attempt belongs to, which decides both what it is given
        /// and what a support report can say about why a walk was long. Nil for the hosted route,
        /// which is a rendezvous rather than one of the Mac's own addresses.
        let wave: RemoteRouteWave?
        /// Original position in the complete candidate list. Lanes retain it so concurrent
        /// diagnostics still reconstruct the host's full route plan rather than four local lists.
        let diagnosticAttempt: Int?
        let diagnosticTotal: Int?

        init(
            link: RemoteConnectionLink,
            isHosted: Bool,
            kind: RemoteHostEndpointKind,
            doorID: String?,
            wave: RemoteRouteWave? = nil,
            diagnosticAttempt: Int? = nil,
            diagnosticTotal: Int? = nil
        ) {
            self.link = link
            self.isHosted = isHosted
            self.kind = kind
            self.doorID = doorID
            self.wave = wave
            self.diagnosticAttempt = diagnosticAttempt
            self.diagnosticTotal = diagnosticTotal
        }
    }

    private struct SuccessfulConnection: Sendable {
        let response: RemoteMeDTO
        let link: RemoteConnectionLink
        let isHosted: Bool
        let kind: RemoteHostEndpointKind
        /// URL loading evidence for the request that answered, when the task reported any.
        let metrics: RemoteRequestMetrics?
    }

    /// How a conditional refresh ended.
    private enum ConditionalRefreshOutcome {
        /// Answered — with the same edition or a new catalogue — or discarded as stale. Either
        /// way the refresh is over.
        case settled
        /// The known route did not answer. Nothing is known about the others yet.
        case fallBackToFullRace
    }

    /// What the one known route said to a request that named the edition in hand.
    private enum ConditionalAnswer {
        case catalogue(SuccessfulConnection)
        case unchanged(link: RemoteConnectionLink, kind: RemoteHostEndpointKind, isHosted: Bool, metrics: RemoteRequestMetrics?)
    }

    /// The route that answered last, as one candidate — the whole of a conditional refresh's
    /// route plan. Nil until something has answered, and nil for a hosted route whose tunnel is
    /// no longer standing, since dialling a rendezvous is the race's job.
    private func warmCandidate(for host: PairedRemoteHost) -> ConnectionCandidate? {
        guard let last = lastConnection, last.hostID == host.id else { return nil }
        if last.isHosted {
            guard let link = liveHostedLink(for: host) else { return nil }
            return ConnectionCandidate(
                link: link,
                isHosted: true,
                kind: RemoteHostEndpointKind.hosted,
                doorID: nil
            )
        }
        return ConnectionCandidate(
            link: host.link,
            isHosted: false,
            kind: host.activeEndpointKind ?? PairedRemoteHost.endpointKind(for: host.link.baseURL),
            doorID: host.link.baseURL.absoluteString
        )
    }

    private func refreshConditionally(
        from host: PairedRemoteHost,
        candidate: ConnectionCandidate,
        edition: RemoteCatalogueRevisionDTO,
        timeout: TimeInterval,
        generation: Int,
        wasOnline: Bool,
        trace refreshTrace: String,
        baseFields refreshBaseFields: [RemoteDiagnosticField: String],
        startedAt refreshStartedAt: UInt64
    ) async -> ConditionalRefreshOutcome {
        let hostID = host.id
        let answer: ConditionalAnswer
        do {
            answer = try await fetchMeConditionally(
                candidate: candidate,
                edition: edition,
                timeout: timeout,
                trace: refreshTrace
            )
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
            return .settled
        } catch {
            return activeHostID == hostID && refreshGeneration == generation
                ? .fallBackToFullRace
                : .settled
        }
        switch answer {
        case let .catalogue(connection):
            await applyRefreshSuccess(
                connection,
                host: host,
                hostID: hostID,
                generation: generation,
                wasOnline: wasOnline,
                trace: refreshTrace,
                baseFields: refreshBaseFields,
                startedAt: refreshStartedAt
            )
        case let .unchanged(link, kind, isHosted, metrics):
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
                return .settled
            }
            phase = .online
            lastConnection = MobileConnectionRecord(
                hostID: hostID,
                kind: kind,
                baseURL: link.baseURL,
                isHosted: isHosted,
                connectedAt: Date(),
                metrics: metrics,
                serverProtocol: me?.serverProtocol
            )
            MobileDiagnostics.recordConnectivity(
                .hostRefreshSucceeded,
                fields: refreshBaseFields.merging([
                    .result: "succeeded",
                    .status: String(RemoteClientDefaults.notModifiedStatus),
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: refreshStartedAt),
                    .transport: kind.rawValue,
                    .origin: MobileDiagnostics.originDigest(link.baseURL),
                ]) { current, _ in current }
            )
            // The catalogue stands; what a resume or a recovery still owes is the socket.
            ensureThemeEvents(for: host)
        }
        return .settled
    }

    /// One request on one route, naming the edition in hand, with the same journal shape as an
    /// attempt in the race so a report reads both alike. `wave` says which it was, and
    /// `timeoutMS` says what it was given — `RemoteRouteWalkBudget.warmProbeTimeout`.
    private func fetchMeConditionally(
        candidate: ConnectionCandidate,
        edition: RemoteCatalogueRevisionDTO,
        timeout: TimeInterval,
        trace: String
    ) async throws -> ConditionalAnswer {
        let startedAt = MobileDiagnostics.monotonicNow()
        let baseFields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .transport: candidate.kind.rawValue,
            .origin: MobileDiagnostics.originDigest(candidate.link.baseURL),
            .phase: "request",
            .kind: candidate.isHosted ? "hosted" : "candidate",
            .wave: MobileDiagnostics.warmRouteWave,
            .attempt: "1",
            .total: "1",
            .timeoutMS: MobileDiagnostics.milliseconds(timeout),
        ]
        noteRouteAttempt(candidate)
        MobileDiagnostics.recordConnectivity(
            .hostRouteStarted,
            fields: baseFields.merging([.result: "started"]) { current, _ in current }
        )
        let metrics = RemoteRequestMetricsCollector()
        let client = RemoteClient(link: candidate.link, endpointKind: candidate.kind)
        do {
            // `timeout` is a deadline, not the request's idle timer. URLSession's
            // `timeoutInterval` restarts on every byte and stops while the app is suspended; a
            // probe given 4000 ms failed after 2,263,174 ms (2026-09-17), and every refresh and
            // chat open joined to it waited that long. The deadline cancels the request and falls
            // through to the race, whose own ceiling bounds the rest.
            let fetched = try await RemoteRouteWalkDeadline.run(
                ceiling: timeout,
                walk: {
                    try await client.fetchCatalogue(
                        timeout: timeout,
                        metrics: metrics,
                        ifNoneMatch: edition.entityTag
                    )
                },
                exceeded: { URLError(.timedOut) }
            )
            let status: String
            let answer: ConditionalAnswer
            switch fetched {
            case let .catalogue(response):
                status = MobileDiagnostics.fullCatalogueStatus
                answer = .catalogue(SuccessfulConnection(
                    response: response,
                    link: candidate.link,
                    isHosted: candidate.isHosted,
                    kind: candidate.kind,
                    metrics: metrics.snapshot
                ))
            case .notModified:
                status = String(RemoteClientDefaults.notModifiedStatus)
                answer = .unchanged(
                    link: candidate.link,
                    kind: candidate.kind,
                    isHosted: candidate.isHosted,
                    metrics: metrics.snapshot
                )
            }
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                fields: baseFields.merging(metrics.fields) { current, _ in current }.merging([
                    .result: "succeeded",
                    .status: status,
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { current, _ in current }
            )
            return answer
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                level: cancelled ? .info : .warning,
                fields: baseFields.merging(metrics.fields) { current, _ in current }.merging([
                    .result: cancelled ? "cancelled" : "failed",
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                    .code: cancelled ? "swift.cancelled" : MobileDiagnostics.errorCode(error),
                ]) { current, _ in current }
            )
            if cancelled { throw CancellationError() }
            noteRouteFailure()
            throw error
        }
    }

    /// Whether the race may also dial the hosted rendezvous for `host`.
    private func hasHostedRoute(_ host: PairedRemoteHost) -> Bool {
        host.hostedServiceURL != nil && host.hostedCredential != nil
    }

    private func fetchMe(
        from host: PairedRemoteHost,
        reportsProgress: Bool,
        trace: String
    ) async throws -> SuccessfulConnection {
        beginRouteWalk()
        defer { endRouteWalk() }
        let expectedRouteCount = max(host.connectionOptionLabels.count, 1)
        let remoteCandidates = routeHealth.admitting(
            host.candidates(preferring: discoveredAddresses[host.id]),
            origin: { $0.link.baseURL },
            skipped: { candidate in
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    fields: [
                        .trace: trace,
                        .transport: candidate.kind.rawValue,
                        .origin: MobileDiagnostics.originDigest(candidate.link.baseURL),
                        .phase: "request",
                        .kind: "candidate",
                        .wave: candidate.wave.rawValue,
                        .result: "skipped",
                        .reason: MobileDiagnostics.routeCooldownReason,
                    ]
                )
            }
        )
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
                    wave: $0.wave,
                    diagnosticAttempt: diagnosticPositions[$0.link],
                    diagnosticTotal: remoteCandidates.count
                )
            }
        }
        let localCandidates = localCandidateLanes.flatMap { $0 }
        let hasHostedRoute = self.hasHostedRoute(host)
        let isOnlyCandidateInRace = localCandidates.count + (hasHostedRoute ? 1 : 0) == 1

        if reportsProgress, let firstKind = localCandidates.first?.kind
            ?? (hasHostedRoute ? RemoteHostEndpointKind.hosted : nil)
        {
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
                return try await self.fetchMeSequentially(
                    candidates: lane,
                    isOnlyCandidateInRace: isOnlyCandidateInRace,
                    trace: trace
                )
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

    // MARK: - What a walk is doing

    /// Opens a walk, so the words on screen belong to this one rather than to the last one.
    private func beginRouteWalk() {
        routeWalksInFlight += 1
        guard routeWalksInFlight == 1 else { return }
        routeWalkFailures = 0
        routeWalkStatus = nil
    }

    /// Closes a walk. The status goes with it: a spinner that is gone has nothing to say.
    private func endRouteWalk() {
        routeWalksInFlight = max(0, routeWalksInFlight - 1)
        guard routeWalksInFlight == 0 else { return }
        routeWalkFailures = 0
        routeWalkStatus = nil
    }

    /// Records which route is being tried right now.
    ///
    /// Lanes race, so several attempts are in flight and the most recently started one is the one
    /// named. That is deliberate: the question a person is asking is "is it still doing
    /// something", and the newest attempt is the truest answer to it.
    private func noteRouteAttempt(_ candidate: ConnectionCandidate) {
        routeWalkStatus = RouteWalkStatus(
            kind: candidate.kind,
            attempt: candidate.diagnosticAttempt ?? 1,
            total: candidate.diagnosticTotal ?? 1,
            followsFailure: routeWalkFailures > 0
        )
    }

    private func noteRouteFailure() {
        routeWalkFailures += 1
        guard let status = routeWalkStatus, !status.followsFailure else { return }
        routeWalkStatus = RouteWalkStatus(
            kind: status.kind,
            attempt: status.attempt,
            total: status.total,
            followsFailure: true
        )
    }

    /// Walks one bounded race lane in its established order. A sticky LAN port range stays in one
    /// lane and stops as soon as its door has answered or proved unreachable.
    private func fetchMeSequentially(
        candidates: [ConnectionCandidate],
        isOnlyCandidateInRace: Bool,
        trace: String
    ) async throws -> SuccessfulConnection {
        try await Self.walk(candidates, trace: trace, phase: "request") { index, candidate in
            let timeout = RemoteRouteWalkBudget.timeout(
                for: candidate.wave,
                isOnlyCandidateInRace: isOnlyCandidateInRace
            )
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
            .transport: candidate.kind.rawValue,
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
            .transport: RemoteHostEndpointKind.hosted.rawValue,
            .phase: "prepare",
            .timeoutMS: MobileDiagnostics.milliseconds(PeerTransportBounds.negotiationTimeout),
        ]
        MobileDiagnostics.recordConnectivity(
            .hostRouteStarted,
            fields: baseFields.merging([.result: "started"]) { current, _ in current }
        )
        let route: HostedRemoteRoute
        do {
            guard let prepared = try await hostedConnections.route(for: host, trace: trace) else {
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
            route = prepared
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
            hostedRoute.adopt(route, for: host.id)
        }
        MobileDiagnostics.recordConnectivity(
            .hostRouteEnded,
            fields: baseFields.merging([
                .result: "succeeded",
                .durationMS: MobileDiagnostics.elapsedMilliseconds(since: preparedAt),
            ]) { current, _ in current }
        )
        let timeout = racesPrivateRoute
            ? RemoteRouteWalkBudget.routeAttemptTimeout
            : RemoteClient.defaultRequestTimeout
        do {
            return try await fetchMe(
                candidate: ConnectionCandidate(
                    link: route.link,
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
        var baseFields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .transport: candidate.kind.rawValue,
            .origin: MobileDiagnostics.originDigest(candidate.link.baseURL),
            .phase: "request",
            .kind: candidate.doorID == nil ? "hosted" : "candidate",
            .attempt: String(attempt),
            .total: String(total),
            .timeoutMS: MobileDiagnostics.milliseconds(timeout),
        ]
        if let wave = candidate.wave { baseFields[.wave] = wave.rawValue }
        noteRouteAttempt(candidate)
        MobileDiagnostics.recordConnectivity(
            .hostRouteStarted,
            fields: baseFields.merging([.result: "started"]) { current, _ in current }
        )
        let metrics = RemoteRequestMetricsCollector()
        do {
            let response = try await RemoteClient(
                link: candidate.link,
                endpointKind: candidate.kind
            ).fetchMe(
                timeout: timeout,
                metrics: metrics
            )
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                fields: baseFields.merging(metrics.fields) { current, _ in current }.merging([
                    .result: "succeeded",
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { current, _ in current }
            )
            routeHealth.noteSuccess(origin: candidate.link.baseURL)
            return SuccessfulConnection(
                response: response,
                link: candidate.link,
                isHosted: candidate.isHosted,
                kind: candidate.kind,
                metrics: metrics.snapshot
            )
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            if !cancelled { noteRouteFailure() }
            let code = cancelled ? "swift.cancelled" : MobileDiagnostics.errorCode(error)
            var fields = baseFields.merging([
                .result: cancelled ? "cancelled" : "failed",
                .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                .code: code,
            ]) { current, _ in current }
            fields.merge(metrics.fields) { current, _ in current }
            if let remote = error as? RemoteClientError,
               case let .server(status, _, _) = remote
            {
                fields[.status] = String(status)
            }
            if !cancelled {
                // Which of two opposite fixes: a pin the phone never registered for this
                // address, or a handshake the address itself ended. The audit could not tell.
                if let detail = MobileDiagnostics.transportDetail(
                    for: error,
                    host: candidate.link.baseURL.host
                ) {
                    fields[.detail] = detail
                }
                if !candidate.isHosted {
                    routeHealth.noteFailure(origin: candidate.link.baseURL, code: code)
                }
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
    ///
    /// The order is `MobileRouteWalkPlan`'s: the route that answered last, then the hosted
    /// tunnel — prepared here, when the walk reaches it, rather than before the first request —
    /// then the Mac's other addresses in wave order. Only the last attempt replays a lost
    /// response on its own address; every earlier one is replayed by the address after it.
    private func performMutation<Response>(
        for hostID: String,
        operation: (RemoteClient, String) async throws -> Response
    ) async throws -> Response {
        guard let host = hosts.first(where: { $0.id == hostID }) else {
            throw CancellationError()
        }
        beginRouteWalk()
        defer { endRouteWalk() }
        let requestID = UUID().uuidString.lowercased()
        let peer = MobileDiagnostics.pseudonym(host.id, prefix: "peer")
        let plan = MobileRouteWalkPlan.plan(
            direct: routeHealth.admitting(
                host.candidates(preferring: discoveredAddresses[host.id]),
                origin: { $0.link.baseURL }
            ),
            hasHostedRoute: host.hostedServiceURL != nil
                && host.hostedCredential != nil,
            hostID: hostID,
            lastConnection: lastConnection,
            origin: { $0.link.baseURL }
        )
        let total = plan.steps.count
        let direct = plan.direct.map { planned in
            ConnectionCandidate(
                link: planned.link,
                isHosted: false,
                kind: planned.kind,
                doorID: planned.doorID,
                wave: planned.wave
            )
        }
        var lastError: Error = RemoteClientError.invalidResponse
        var closedDoors: Set<String> = []
        for (index, step) in plan.steps.enumerated() {
            let candidate: ConnectionCandidate
            switch step {
            case .hosted:
                guard let prepared = await prepareHostedRouteForWalk(
                    for: host,
                    trace: requestID,
                    peer: peer,
                    lastError: &lastError
                ) else { continue }
                candidate = ConnectionCandidate(
                    link: prepared.link,
                    isHosted: true,
                    kind: RemoteHostEndpointKind.hosted,
                    doorID: nil,
                    diagnosticAttempt: index + 1,
                    diagnosticTotal: total
                )
            case let .direct(position):
                let planned = direct[position]
                if let doorID = planned.doorID, closedDoors.contains(doorID) { continue }
                candidate = ConnectionCandidate(
                    link: planned.link,
                    isHosted: false,
                    kind: planned.kind,
                    doorID: planned.doorID,
                    wave: planned.wave,
                    diagnosticAttempt: index + 1,
                    diagnosticTotal: total
                )
            }
            let timeout = RemoteRouteWalkBudget.mutationTimeout(
                for: candidate.wave,
                isOnlyCandidateInWalk: total == 1
            )
            let startedAt = MobileDiagnostics.monotonicNow()
            var routeFields: [RemoteDiagnosticField: String] = [
                .trace: requestID,
                .peer: peer,
                .transport: candidate.kind.rawValue,
                .origin: MobileDiagnostics.originDigest(candidate.link.baseURL),
                .phase: "mutation.request",
                .result: "started",
                .attempt: String(index + 1),
                .total: String(total),
                .timeoutMS: MobileDiagnostics.milliseconds(timeout),
            ]
            if let wave = candidate.wave { routeFields[.wave] = wave.rawValue }
            noteRouteAttempt(candidate)
            MobileDiagnostics.recordConnectivity(.hostRouteStarted, fields: routeFields)
            do {
                let response = try await operation(
                    RemoteClient(
                        link: candidate.link,
                        requestTimeout: timeout,
                        endpointKind: candidate.kind,
                        replaysLostResponse: MobileRouteWalkPlan.replaysLostResponse(
                            at: index,
                            of: total
                        )
                    ),
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
                // A mutation that had to fail over is now the route in use; the panel says so
                // without waiting for the next catalogue refresh.
                if let current = lastConnection, current.hostID == hostID,
                   current.baseURL != candidate.link.baseURL || current.isHosted != candidate.isHosted
                {
                    lastConnection = MobileConnectionRecord(
                        hostID: hostID,
                        kind: candidate.kind,
                        baseURL: candidate.link.baseURL,
                        isHosted: candidate.isHosted,
                        connectedAt: Date(),
                        metrics: nil,
                        serverProtocol: current.serverProtocol
                    )
                }
                if let index = hosts.firstIndex(where: { $0.id == hostID }),
                   candidate.isHosted
                   ? hosts[index].activeEndpointKind != .hosted
                   : hosts[index].link != candidate.link
                {
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
                noteRouteFailure()
                var failedFields = routeFields.merging([
                    .result: "failed",
                    .code: MobileDiagnostics.errorCode(error),
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
                if case let .server(status, _, _) = error {
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
                if error.allowsMutationRouteFailover {
                    lastError = error
                    if case let .direct(position) = step {
                        Self.closeDoor(
                            for: error,
                            candidates: direct,
                            index: position,
                            closedDoors: &closedDoors,
                            trace: requestID,
                            phase: "mutation.request",
                            peer: peer
                        )
                    }
                    if candidate.isHosted { await hostedConnectionFailed(hostID: host.id) }
                    continue
                }
                if candidate.isHosted { await hostedConnectionFailed(hostID: host.id) }
                throw error
            } catch {
                noteRouteFailure()
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
                if case let .direct(position) = step {
                    Self.closeDoor(
                        for: error,
                        candidates: direct,
                        index: position,
                        closedDoors: &closedDoors,
                        trace: requestID,
                        phase: "mutation.request",
                        peer: peer
                    )
                }
                if candidate.isHosted { await hostedConnectionFailed(hostID: host.id) }
            }
        }
        throw lastError
    }

    /// Prepares the hosted tunnel for a mutation walk that has reached it: the manager's standing
    /// tunnel when there is one, a rendezvous and an ICE session otherwise. Nil when there is no
    /// route to prepare or the preparation did not finish; what went wrong is recorded and left
    /// in `lastError` for the walk to throw if nothing else answers.
    private func prepareHostedRouteForWalk(
        for host: PairedRemoteHost,
        trace: String,
        peer: String,
        lastError: inout Error
    ) async -> HostedRemoteRoute? {
        let startedAt = MobileDiagnostics.monotonicNow()
        let fields: [RemoteDiagnosticField: String] = [
            .trace: trace,
            .peer: peer,
            .transport: RemoteHostEndpointKind.hosted.rawValue,
            .phase: "mutation.prepare",
            .timeoutMS: MobileDiagnostics.milliseconds(PeerTransportBounds.negotiationTimeout),
        ]
        MobileDiagnostics.recordConnectivity(
            .hostRouteStarted,
            fields: fields.merging([.result: "started"]) { _, new in new }
        )
        do {
            guard let prepared = try await hostedConnections.route(for: host, trace: trace) else {
                MobileDiagnostics.recordConnectivity(
                    .hostRouteEnded,
                    level: .warning,
                    fields: fields.merging([
                        .result: "unavailable",
                        .code: "hosted.unavailable",
                        .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                    ]) { _, new in new }
                )
                return nil
            }
            if activeHostID == host.id {
                hostedRoute.adopt(prepared, for: host.id)
            }
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                fields: fields.merging([
                    .result: "succeeded",
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
            )
            return prepared
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            MobileDiagnostics.recordConnectivity(
                .hostRouteEnded,
                level: cancelled ? .info : .warning,
                fields: fields.merging([
                    .result: cancelled ? "cancelled" : "failed",
                    .code: cancelled ? "swift.cancelled" : MobileDiagnostics.errorCode(error),
                    .durationMS: MobileDiagnostics.elapsedMilliseconds(since: startedAt),
                ]) { _, new in new }
            )
            if !cancelled { await hostedConnectionFailed(hostID: host.id) }
            lastError = cancelled ? CancellationError() : error
            return nil
        }
    }

    private func hostedConnectionFailed(hostID: String) async {
        await hostedConnections.invalidate(hostID: hostID)
        hostedRoute.clear(for: hostID)
    }

    private func reconcileHostedCredential(
        hostID: String,
        response: RemoteMeDTO,
        successfulLink: RemoteConnectionLink,
        generation: Int,
        trace: String
    ) async {
        guard activeHostID == hostID, refreshGeneration == generation,
              let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }

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
            .transport: PairedRemoteHost.endpointKind(for: successfulLink.baseURL).rawValue,
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
                expectedHostID: hosts[index].hostID ?? hostID,
                expectedDeviceID: hosts[index].hostedDeviceID
            )
            guard activeHostID == hostID, refreshGeneration == generation,
                  let currentIndex = hosts.firstIndex(where: { $0.id == hostID })
            else {
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
        hostedRoute.clearAll()
        Task { await hostedConnections.invalidate() }
    }

    private static func validateHostedCredential(
        _ response: RemoteHostedDeviceCredentialDTO,
        expectedHostID: String,
        expectedDeviceID: String?
    ) throws -> (URL, PeerDeviceServiceCredential) {
        guard response.hostID == expectedHostID,
              response.deviceID == expectedDeviceID,
              response.expiresAt.isFinite,
              let rawURL = URL(string: response.serviceURL)
        else {
            throw RemoteClientError.invalidResponse
        }
        let endpoint = try PeerControlPlaneServiceEndpoint(rawURL)
        let expiresAt = Date(timeIntervalSince1970: response.expiresAt / 1000)
        guard expiresAt > Date().addingTimeInterval(60),
              expiresAt < Date().addingTimeInterval(370 * 24 * 60 * 60)
        else {
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

        let route = liveRoute(for: host)
        let link = route.link
        let client = RemoteClient(link: link, endpointKind: route.kind)
        let trace = MobileDiagnostics.connectivityTrace()
        themeEventsStartedAt = MobileDiagnostics.monotonicNow()
        themeEventsDiagnosticFields = [
            .trace: trace,
            .peer: MobileDiagnostics.pseudonym(host.id, prefix: "peer"),
            .transport: client.endpointKind.rawValue,
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
                  themeEventsTask === task
            {
                let message = try await task.receive()
                guard activeHostID == hostID else { return }
                guard case let .string(text) = message else { continue }
                let data = Data(text.utf8)
                struct Envelope: Decodable {
                    let type: String
                    let streamID: String?
                    let sequence: UInt64?
                    let revision: RemoteCatalogueRevisionDTO?
                    let session: RemoteSessionSummaryDTO?
                    let removedSessionID: String?
                    let terminal: RemoteProjectTerminalSummaryDTO?
                    let removedTerminalID: String?
                }
                guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                    // An undecodable frame could have been the only catalogue mutation before
                    // the socket went quiet. Reconnect for a fresh stream fence instead of
                    // blessing the snapshot merely because no later sequence exposes the hole.
                    throw RemoteClientError.invalidResponse
                }
                // The server sends an authoritative frame immediately after auth. Any
                // well-formed event proves authentication; catalogue health additionally needs
                // the stream fence below to agree with the REST snapshot.
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
                    sendMobileDiagnosticsHello(on: task)
                }
                // The one place the socket's attempt counter goes back to zero. A catalogue
                // answer is not a socket: in the 2026-09-06 report a `304` over Tailscale reset
                // the counter every second while the socket beside it failed on a dead hosted
                // origin every second, so the backoff never grew past its first step. Only a
                // frame on the socket says the socket is back.
                if connectionRecoveryAttempt != 0 {
                    connectionRecoveryAttempt = 0
                }
                switch envelope.type {
                case "catalogueHello":
                    refreshUsageGlance(features: me?.features)
                    guard let streamID = envelope.streamID, !streamID.isEmpty,
                          let revision = envelope.revision else {
                        throw RemoteClientError.invalidResponse
                    }
                    let hello = RemoteCatalogueStreamHelloDTO(
                        streamID: streamID,
                        revision: revision
                    )
                    discardPendingSessionDeltas()
                    catalogueStreamFence.begin(hello, currentRevision: me?.revision)
                    if catalogueStreamFence.requiresRefresh {
                        scheduleSessionsChangedRefresh(for: hostID, reason: .revisionGap)
                    }
                case "appTheme":
                    if let update = try? JSONDecoder().decode(
                        RemoteAppThemeUpdateDTO.self,
                        from: data
                    ) {
                        me = me?.replacing(theme: update.theme)
                    }
                case "usageCapacityChanged":
                    refreshUsageGlance(features: me?.features)
                case "sessionsChanged":
                    let update = RemoteSessionsChangedDTO(
                        session: envelope.session,
                        removedSessionID: envelope.removedSessionID,
                        terminal: envelope.terminal,
                        removedTerminalID: envelope.removedTerminalID,
                        revision: envelope.revision,
                        streamID: envelope.streamID,
                        sequence: envelope.sequence
                    )
                    guard acceptCatalogueUpdate(update, for: hostID) else { continue }
                    if me != nil,
                       update.session != nil || update.removedSessionID != nil
                       || update.terminal != nil || update.removedTerminalID != nil
                    {
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
                    ), RemoteNotificationPayloadValidation.accepts(event) {
                        RemoteNotificationBridge.received(event, connectionID: hostID)
                    }
                case "notificationRetraction":
                    if let data = text.data(using: .utf8),
                       let retraction = try? JSONDecoder().decode(
                           RemoteNotificationRetractionDTO.self,
                           from: data
                       ), RemoteNotificationPayloadValidation.accepts(retraction) {
                        RemoteNotificationBridge.received(retraction, connectionID: hostID)
                    }
                case "mobileDiagnosticsCaptureRequest":
                    if let request = try? JSONDecoder().decode(
                        RemoteMobileDiagnosticsCaptureRequestDTO.self,
                        from: data
                    ) {
                        await performMobileDiagnosticsCapture(request, hostID: hostID)
                    }
                default:
                    continue
                }
            }
            if !Task.isCancelled,
               themeEventsGeneration == generation,
               themeEventsTask === task
            {
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
        themeEventsRecoveryHostID = nil
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
        catalogueStreamFence.reset()
        themeEventsStartedAt = nil
        themeEventsDiagnosticFields = [:]
    }

    private func scheduleThemeEventsRecovery(for hostID: String) {
        guard !isDemo, activeHostID == hostID, themeEventsTask == nil,
              themeEventsRecoveryTask == nil else { return }
        let delay = MobileSocketRecoveryBackoff.delay(forAttempt: connectionRecoveryAttempt)
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
        themeEventsRecoveryHostID = hostID
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
        themeEventsRecoveryHostID = nil
        guard !isDemo, activeHostID == hostID, themeEventsTask == nil else { return }
        await refresh(reason: .socketRecovery)
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

    private func scheduleSessionsChangedRefresh(
        for hostID: String,
        reason: MobileRefreshReason = .structuralChange
    ) {
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
                generation: generation,
                reason: reason
            )
        }
    }

    /// Accepts only the next scoped event in the stream the host fenced. WebSockets preserve
    /// order, but lifecycle replacement and decoding failures can still leave the client with a
    /// hole; a hole makes the cached catalogue stale rather than "probably current".
    private func acceptCatalogueUpdate(
        _ update: RemoteSessionsChangedDTO,
        for hostID: String
    ) -> Bool {
        guard catalogueStreamFence.accepts(update) else {
            discardPendingSessionDeltas()
            scheduleSessionsChangedRefresh(for: hostID, reason: .revisionGap)
            return false
        }
        return true
    }

    private func reconcileCatalogueStreamFence() {
        catalogueStreamFence.reconcile(currentRevision: me?.revision)
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
        // Deltas from a Mac process the edition in hand does not know are a restart this phone
        // slept through. The rows still apply; what they cannot vouch for is everything else.
        let editionWasKnown = current.revision != nil
        let editionLost = editionWasKnown && updated.revision == nil
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
        if editionLost {
            scheduleSessionsChangedRefresh(for: hostID, reason: .revisionGap)
        }
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

    private func refreshSessionsChanged(
        for hostID: String,
        generation: Int,
        reason: MobileRefreshReason
    ) async {
        guard activeHostID == hostID,
              sessionsChangedRefreshGeneration == generation else { return }
        await refresh(reason: reason)
        if sessionsChangedRefreshGeneration == generation {
            sessionsChangedRefreshTask = nil
            if catalogueStreamFence.requiresRefresh {
                scheduleSessionsChangedRefresh(for: hostID, reason: .revisionGap)
            }
        }
    }

    static let demoTheme = RemoteThemeDTO(
        id: "cyberpunk",
        name: "Cyberpunk",
        mode: .dark,
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
        mode: .light,
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
        mode: .dark,
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
        mode: .dark,
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
        mode: RemoteThemeMode,
        ground: String,
        surface: String,
        panel: String,
        label: String,
        accent: String,
        radius: Double = 10,
        borderWidth: Double = 1,
        glow: RemoteThemeDTO.Material.Glow? = nil
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
                "status_positive": mode == .light ? "#197149" : "#74C49A",
                "status_warning": mode == .light ? "#9A6700" : "#E6A35D",
                "status_negative": mode == .light ? "#B42318" : "#E06E65",
                "diff_added": mode == .light ? "#197149" : "#74C49A",
                "diff_removed": mode == .light ? "#B42318" : "#E06E65",
            ],
            material: .init(
                panelRadius: radius,
                controlRadius: max(0, radius / 2),
                borderWidth: borderWidth,
                glow: glow
            )
        )
    }

    static let demoCatalogThemes: [RemoteThemeDTO] = [
        demoTheme,
        demoThreadingTheme,
        demoLightTheme,
        demoCatalogTheme(
            id: "editorial", name: "Editorial", mode: .light,
            ground: "#F2EEE7", surface: "#E8E1D7", panel: "#FBF8F2",
            label: "#2A2520", accent: "#A85632", radius: 5
        ),
        demoCatalogTheme(
            id: "swiss-minimalist", name: "Swiss Minimalist", mode: .light,
            ground: "#FFFFFF", surface: "#F2F2F2", panel: "#FFFFFF",
            label: "#111111", accent: "#FF3000", radius: 0, borderWidth: 2
        ),
        demoCatalogTheme(
            id: "bauhaus", name: "Bauhaus", mode: .light,
            ground: "#F0F0F0", surface: "#FFFFFF", panel: "#FFFFFF",
            label: "#121212", accent: "#D02020", radius: 0, borderWidth: 4
        ),
        demoCatalogTheme(
            id: "art-deco", name: "Art Deco", mode: .dark,
            ground: "#0A0A0F", surface: "#050505", panel: "#141414",
            label: "#F2F0E4", accent: "#D4AF37", radius: 4
        ),
        demoCatalogTheme(
            id: "neo-brutalism", name: "Neo Brutalism", mode: .light,
            ground: "#FFFDF5", surface: "#C4B5FD", panel: "#FFFFFF",
            label: "#000000", accent: "#FF6B6B", radius: 0, borderWidth: 4,
            glow: .init(color: "#000000", radius: 0, opacity: 1, offsetX: 12, offsetY: -12)
        ),
        demoCatalogTheme(
            id: "claymorphism", name: "Claymorphism", mode: .light,
            ground: "#E9E7F7", surface: "#DCD8F0", panel: "#F5F2FF",
            label: "#332B55", accent: "#7C4DFF", radius: 24
        ),
        demoCatalogTheme(
            id: "vaporwave", name: "Vaporwave", mode: .dark,
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

    /// The app theme a marketing capture asked for through `THREADING_MOBILE_THEME`, else the
    /// demo's own.
    ///
    /// One resolution for the hello's theme, the coordinated terminal palette and the fixture's
    /// `me.theme`. The dashboard's frame was painted in the requested theme while the response
    /// still carried the demo's Cyberpunk record, so the Settings capture named an appearance
    /// the rest of the set was not drawn in.
    static var demoRequestedMarketingTheme: RemoteThemeDTO {
#if DEBUG
        switch ProcessInfo.processInfo.environment["THREADING_MOBILE_THEME"] {
        case "light": return demoLightTheme
        case "threading": return demoThreadingTheme
        case "system-remote": return demoSystemRemoteTheme
        case let requested?:
            return demoCatalogThemes.first(where: { $0.id == requested }) ?? demoTheme
        case nil: return demoTheme
        }
#else
        return demoTheme
#endif
    }

    /// A coordinated terminal palette for a marketing capture's selected app theme.
    ///
    /// Real sessions keep app and terminal themes independently assignable. The marketing flow is
    /// different: one `--theme` input promises a coherent visual variant of the whole frame. Its
    /// terminal therefore resolves from the same semantic colours as the surrounding chrome,
    /// including a genuinely light terminal for light app themes.
    static func demoMarketingTerminalTheme(
        matching appTheme: RemoteThemeDTO
    ) -> RemoteTerminalThemeDTO {
        let colours = appTheme.colors
        let isLight = appTheme.mode == .light
        let ground = colours["ground"] ?? (isLight ? "#FFFFFF" : "#16181D")
        // A terminal cell has no alpha: `TerminalViewRepresentable` hands SwiftTerm opaque RGB, so
        // a role that is the label at some opacity (`tertiary_label`, `selection`) has to be
        // composited over the ground here or it arrives as the label itself. That is how Art
        // Deco drew Claude's prompt bar in cream and Editorial in near-black: both are `\e[100m`,
        // ANSI bright black, mapped to the tertiary tint with its alpha thrown away.
        func role(_ key: String, fallback: String) -> String {
            DemoHexColour.composite(colours[key] ?? fallback, over: ground)
        }
        let foreground = role("label", fallback: isLight ? "#111111" : "#F3F4F6")
        let secondary = role("secondary_label", fallback: isLight ? "#555555" : "#A7ABB4")
        let tertiary = role("tertiary_label", fallback: isLight ? "#777777" : "#747983")
        let accent = role("accent", fallback: isLight ? "#155DB1" : "#64A8FF")
        let positive = role("status_positive", fallback: isLight ? "#197149" : "#74C49A")
        let warning = role("status_warning", fallback: isLight ? "#9A6700" : "#E6A35D")
        let negative = role("status_negative", fallback: isLight ? "#B42318" : "#E06E65")
        let selection = DemoHexColour.composite(
            colours["selection"] ?? colours["accent_muted"] ?? accent,
            over: ground
        )
        let blue = isLight ? "#2457A7" : "#6EA8D8"
        let magenta = isLight ? "#8F3F97" : "#C486B9"
        let cyan = isLight ? "#137C8B" : "#7DC9D2"
        // The four greys follow terminal convention for the mode rather than the label roles: a
        // TUI recorded against a light terminal writes its text in black and bright black and
        // expects white and bright white to sit near the paper, and a dark one the reverse. The
        // recording replayed for a light theme was made against a light terminal
        // (`MobileMarketingTerminalFixture.TerminalMode`), so the two halves agree.
        let black = isLight ? foreground : role("surface", fallback: "#1B1E24")
        let brightBlack = isLight
            ? DemoHexColour.blend(ground, foreground, fraction: 0.5)
            : tertiary
        let white = isLight
            ? DemoHexColour.blend(ground, foreground, fraction: 0.2)
            : secondary
        let brightWhite = isLight ? ground : foreground

        return RemoteTerminalThemeDTO(
            id: "marketing-\(appTheme.id)-terminal",
            name: "\(appTheme.name) Marketing",
            foreground: foreground,
            boldForeground: foreground,
            background: ground,
            cursor: accent,
            selection: selection,
            ansi: [
                black, negative, positive, warning, blue, magenta, cyan, white,
                brightBlack, negative, positive, warning, accent, magenta, cyan, brightWhite,
            ]
        )
    }

    /// The Claude demo login's windows, held apart from the catalogue literal: three windows and
    /// a model list inside that one expression put the type checker past its budget.
    private static let demoClaudeModels: [RemoteModelChoiceDTO] = [
        RemoteModelChoiceDTO(id: "claude-fable-5", name: "Fable 5"),
    ]

    /// Each window says when it comes back, as a real host's does: the chat menu's usage row
    /// spends its words on the nearest reset now that its gauge draws the percentages, and a
    /// demo whose windows never reset could only ever show that row's fallback.
    private static let demoClaudeUsageWindows: [RemoteAccountUsageWindowDTO] = {
        let now = Date().timeIntervalSince1970
        return [
            RemoteAccountUsageWindowDTO(
                id: "5h",
                name: "5h",
                fraction: 0.31,
                resetsAt: now + 3 * 60 * 60,
                windowDuration: 5 * 60 * 60
            ),
            RemoteAccountUsageWindowDTO(
                id: "7d",
                name: "7d",
                fraction: 0.56,
                resetsAt: now + 4 * 24 * 60 * 60,
                windowDuration: 7 * 24 * 60 * 60
            ),
            RemoteAccountUsageWindowDTO(
                id: "Fable",
                name: "7d Fable",
                fraction: 0.82,
                resetsAt: now + 4 * 24 * 60 * 60,
                windowDuration: 7 * 24 * 60 * 60,
                metersModelIDs: ["claude-fable-5"]
            ),
        ]
    }()

    /// The marketing menu keeps two exact provider windows on one line. Their reset timestamps
    /// are deliberately absent: the screenshot must replay identically next month, and the full
    /// usage dashboard remains the place for time-relative history.
    private static let marketingClaudeUsageWindows: [RemoteAccountUsageWindowDTO] = [
        RemoteAccountUsageWindowDTO(
            id: "5h",
            name: "5h",
            fraction: 0.31,
            windowDuration: 5 * 60 * 60
        ),
        RemoteAccountUsageWindowDTO(
            id: "7d",
            name: "7d",
            fraction: 0.56,
            windowDuration: 7 * 24 * 60 * 60
        ),
    ]

    /// The demo's terminal chat, held apart from the catalogue literal for the reason its
    /// windows are: one more argument inside that expression puts the type checker over budget.
    private static func demoTerminalSession(now: Double) -> RemoteSessionSummaryDTO {
        RemoteSessionSummaryDTO(
            id: "ff9f4a47-4c3b-466b-bcc5-a864b0657423",
            title: "Finish remote access review",
            agentKind: "claude",
            surface: .terminal,
            state: .idle,
            continuation: .delegated,
            projectName: "AnotherTerminal",
            isAvailable: true,
            lastActiveAt: now - 380,
            terminalTheme: demoTerminalTheme,
            terminalThemeAssignmentID: demoTerminalTheme.id,
            inheritedTerminalThemeName: demoTerminalTheme.name,
            inheritedTerminalTheme: demoTerminalTheme,
            // Both chip forms are represented on purpose: a login with a chosen emoji and one
            // falling back to its initial on a hashed disc are drawn differently, and the
            // evidence capture is where that difference is reviewed.
            account: .init(
                name: "Vera Keller",
                glyph: "V",
                isEmoji: false,
                hue: 0.72
            ),
            // Routed to a login, as every chat on a host with account routing is. Its disc is
            // ringed by that login's windows and its menu leads with them — and this one runs on
            // the alternate login whose chip the row above wears, so the two agree.
            accountID: "keller"
        )
    }

#if DEBUG
    static func marketingTerminalSession(
        provider: MobileMarketingTerminalFixture.Provider,
        now: Double
    ) -> RemoteSessionSummaryDTO {
        switch provider {
        case .claude:
            return RemoteSessionSummaryDTO(
                id: "marketing-claude-session",
                title: "Polish launch screenshots",
                agentKind: "claude",
                surface: .terminal,
                state: .needsAttention,
                projectName: "Threading",
                isAvailable: true,
                lastActiveAt: now - 90,
                terminalTheme: demoTerminalTheme,
                inheritedTerminalThemeName: demoTerminalTheme.name,
                inheritedTerminalTheme: demoTerminalTheme,
                account: .init(name: "Vera Keller", glyph: "V", isEmoji: false, hue: 0.72),
                accountID: "keller",
                model: "claude-fable-5"
            )
        case .codex:
            return RemoteSessionSummaryDTO(
                id: "marketing-codex-session",
                title: "Build App Store capture flow",
                agentKind: "codex",
                surface: .terminal,
                state: .working,
                projectName: "Threading",
                isAvailable: true,
                lastActiveAt: now,
                isPinned: true,
                terminalTheme: demoTerminalTheme,
                inheritedTerminalThemeName: demoTerminalTheme.name,
                inheritedTerminalTheme: demoTerminalTheme,
                // The standard Codex login is still the routed account, but like the real host
                // projection it carries no visual chip: the Codex mark already identifies it.
                accountID: "default",
                model: "gpt-5.6-sol"
            )
        }
    }

    private static func demoResponse(for mode: String) -> RemoteMeDTO {
        if mode == MobileDemoFixture.sessionsScrollStress.rawValue {
            let requestedRows = ProcessInfo.processInfo.environment[
                "THREADING_MOBILE_DASHBOARD_STRESS_ROWS"
            ].flatMap(Int.init) ?? 1_000
            return dashboardStressResponse(rowCount: max(1, requestedRows))
        }
        let response = MobileDemoFixture.isMarketing(mode)
            ? marketingResponse(forMode: mode)
            : demoResponse
        guard ["sessions", "project-sessions"].contains(mode) else { return response }
        var features = response.features ?? []
        if !features.contains(RemoteRESTFeature.universalSearch.rawValue) {
            features.append(RemoteRESTFeature.universalSearch.rawValue)
        }
        // These DEBUG fixtures exercise the dashboard's complete bottom chrome. Search has its
        // own functional fixture; here the advertised capability keeps a missing pill from
        // escaping visual review again.
        return RemoteMeDTO(
            serverProtocol: response.serverProtocol,
            share: response.share,
            sessions: response.sessions + [
                .init(id: "preview-older-attention", title: "Review before release",
                      agentKind: "claude", surface: .conversation, state: .needsAttention,
                      projectName: "AnotherTerminal", isAvailable: true, lastActiveAt: 10),
                .init(id: "preview-older-working", title: "Long-running checks",
                      agentKind: "codex", surface: .conversation, state: .working,
                      projectName: "AnotherTerminal", isAvailable: true, lastActiveAt: 9),
                .init(id: "preview-older-idle", title: "Documentation cleanup",
                      agentKind: "codex", surface: .conversation, state: .dormant,
                      projectName: "AnotherTerminal", lastActiveAt: 8),
            ],
            terminals: response.terminals,
            host: response.host,
            theme: response.theme,
            themeCatalog: response.themeCatalog,
            archivedSessions: response.archivedSessions,
            newSessionCatalog: response.newSessionCatalog,
            features: features
        )
    }

    /// The shipping dashboard's deterministic scaling fixture.
    ///
    /// One project is deliberate: it exercises the largest plate the collection can own while
    /// every session remains an independent diffable item and a real reusable dashboard row.
    private static func dashboardStressResponse(rowCount: Int) -> RemoteMeDTO {
        let response = demoResponse
        let now = Date().timeIntervalSince1970
        let sessions = (0..<rowCount).map { index in
            RemoteSessionSummaryDTO(
                id: "dashboard-scroll-\(index)",
                title: "Dashboard scrolling session \(index)",
                agentKind: index.isMultiple(of: 2) ? "codex" : "claude",
                surface: index.isMultiple(of: 3) ? .terminal : .conversation,
                state: index.isMultiple(of: 11) ? .working : .idle,
                projectName: "Dashboard Stress",
                isAvailable: true,
                lastActiveAt: now - Double(index * 60),
                isPinned: index.isMultiple(of: 17)
            )
        }
        return RemoteMeDTO(
            serverProtocol: response.serverProtocol,
            share: response.share,
            sessions: sessions,
            terminals: [],
            host: response.host,
            theme: response.theme,
            themeCatalog: response.themeCatalog,
            archivedSessions: [],
            newSessionCatalog: response.newSessionCatalog,
            features: response.features
        )
    }

    private static func marketingResponse(forMode mode: String) -> RemoteMeDTO {
        let response = marketingResponse
        guard mode == MobileDemoFixture.marketingClaudeUsageMenu.rawValue else {
            return response
        }
        // With the software keyboard visible, one more nested menu pushes Archive below the
        // first system-menu viewport. This host deliberately does not advertise theme management,
        // leaving the complete capability-appropriate menu visible in one marketing frame.
        return RemoteMeDTO(
            serverProtocol: response.serverProtocol,
            share: response.share,
            sessions: response.sessions,
            terminals: response.terminals,
            host: response.host,
            theme: response.theme,
            themeCatalog: nil,
            archivedSessions: response.archivedSessions,
            newSessionCatalog: response.newSessionCatalog,
            features: response.features
        )
    }

    static var marketingResponse: RemoteMeDTO {
        let base = demoResponse
        let now = Date().timeIntervalSince1970
        let sessions = [
            marketingTerminalSession(provider: .codex, now: now),
            marketingTerminalSession(provider: .claude, now: now),
            RemoteSessionSummaryDTO(
                id: "marketing-remote-access-session",
                title: "Verify away-from-home access",
                agentKind: "codex",
                surface: .conversation,
                state: .idle,
                projectName: "Threading",
                isAvailable: true,
                lastActiveAt: now - 12 * 60,
                terminalTheme: demoTerminalTheme,
                account: .init(name: "Work", glyph: "W", isEmoji: false, hue: 0.14),
                accountID: "codex-work",
                model: "gpt-5.6-terra"
            ),
            RemoteSessionSummaryDTO(
                id: "marketing-linux-session",
                title: "Plan Linux account support",
                agentKind: "claude",
                surface: .conversation,
                state: .dormant,
                projectName: "Threading",
                isAvailable: false,
                lastActiveAt: now - 22 * 60 * 60,
                terminalTheme: demoTerminalTheme,
                account: .init(name: "David", glyph: "D", isEmoji: false, hue: 0.58),
                accountID: "default"
            ),
        ]
        let catalog = base.newSessionCatalog.map {
            RemoteNewSessionCatalogDTO(
                projects: [
                    .init(
                        id: "project-threading",
                        name: "Threading",
                        branch: "main",
                        checkoutLabel: "Threading"
                    ),
                ],
                agents: marketingAgents($0.agents),
                supportsManagerRole: $0.supportsManagerRole
            )
        }
        return RemoteMeDTO(
            serverProtocol: base.serverProtocol,
            share: base.share,
            sessions: sessions,
            terminals: [],
            host: RemoteHostDTO(id: "demo-mac", name: "David’s MacBook Pro"),
            theme: demoRequestedMarketingTheme,
            themeCatalog: base.themeCatalog,
            archivedSessions: [],
            newSessionCatalog: catalog,
            features: base.features
        )
    }

    private static func marketingAgents(
        _ agents: [RemoteAgentChoiceDTO]
    ) -> [RemoteAgentChoiceDTO] {
        agents.map { agent in
            guard agent.id == "claude" else { return agent }
            let accounts = agent.accounts?.map { account in
                guard account.id == "keller" else { return account }
                return RemoteAccountChoiceDTO(
                    id: account.id,
                    name: account.name,
                    email: account.email,
                    emoji: account.emoji,
                    presentation: account.presentation,
                    imagePNG: account.imagePNG,
                    appearances: account.appearances,
                    images: account.images,
                    usageSummary: "5h 31% · 7d 56%",
                    usageFraction: 0.56,
                    usageError: account.usageError,
                    usageWindows: marketingClaudeUsageWindows,
                    models: account.models,
                    defaultModelID: account.defaultModelID
                )
            }
            return RemoteAgentChoiceDTO(
                id: agent.id,
                name: agent.name,
                accounts: accounts,
                models: agent.models,
                defaultModelID: agent.defaultModelID,
                supportsConversation: agent.supportsConversation,
                permissionModes: agent.permissionModes
            )
        }
    }
#endif

    private static var demoResponse: RemoteMeDTO {
        let now = Date().timeIntervalSince1970
        return RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(
                label: "preview",
                scope: .all,
                capability: .interact,
                canApprovePermissions: true,
                expiresAt: nil
            ),
            sessions: [
                .init(
                    id: "5de80220-2172-4fbe-8ed7-a707572fc922",
                    title: "Review the new remote access feature",
                    agentKind: "codex",
                    surface: .conversation,
                    state: .working,
                    projectName: "AnotherTerminal",
                    isAvailable: true,
                    lastActiveAt: now,
                    isPinned: true,
                    terminalTheme: demoTerminalTheme,
                    inheritedTerminalThemeName: demoTerminalTheme.name,
                    inheritedTerminalTheme: demoTerminalTheme,
                    accountID: "default",
                    limitRecovery: .resumeOnBestAccount
                ),
                demoTerminalSession(now: now),
                .init(
                    id: "164182ac-7908-4c2d-89a2-fe8f040c4b50",
                    title: "Theme polish",
                    agentKind: "codex",
                    surface: .conversation,
                    state: .dormant,
                    projectName: "AnotherTerminal",
                    isAvailable: false,
                    lastActiveAt: now - 86400,
                    terminalTheme: demoTerminalTheme
                ),
                .init(
                    id: "f13fc835-763c-4d9f-a54e-099bdd5927d1",
                    title: "Roadmap implementation",
                    agentKind: "claude",
                    surface: .conversation,
                    state: .needsAttention,
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
                    state: .dormant,
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
                    state: .working,
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
                    state: .dormant,
                    isAvailable: false,
                    createdAt: now - 7200,
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
                        checkoutLabel: "AnotherTerminal",
                        isHidden: ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"]
                            == "session-dashboard-show-project-custom-dark"
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
                                            .init(id: "max", name: "Max"),
                                            .init(id: "ultra", name: "Ultra"),
                                        ],
                                        defaultReasoningID: "high",
                                        supportsFastMode: true
                                    ),
                                    .init(
                                        id: "gpt-5.6-terra",
                                        name: "GPT-5.6 Terra",
                                        reasoning: [
                                            .init(id: "low", name: "Light"),
                                            .init(id: "medium", name: "Medium"),
                                            .init(id: "high", name: "High"),
                                            .init(id: "xhigh", name: "Extra High"),
                                            .init(id: "max", name: "Max"),
                                            .init(id: "ultra", name: "Ultra"),
                                        ],
                                        defaultReasoningID: "high",
                                        supportsFastMode: true
                                    ),
                                    .init(
                                        id: "gpt-5.6-luna",
                                        name: "GPT-5.6 Luna",
                                        reasoning: [
                                            .init(id: "low", name: "Light"),
                                            .init(id: "medium", name: "Medium"),
                                            .init(id: "high", name: "High"),
                                            .init(id: "xhigh", name: "Extra High"),
                                            .init(id: "max", name: "Max"),
                                        ],
                                        defaultReasoningID: "medium",
                                        supportsFastMode: false
                                    ),
                                ],
                                defaultModelID: "gpt-5.6-sol"
                            ),
                            .init(
                                id: "codex-work",
                                name: "Work",
                                presentation: .init(name: "Work", glyph: "DV", isEmoji: false, hue: nil,
                                    backgroundHex: "#F4C95D", foregroundHex: "#000000",
                                    badgeHidden: false, displayLabel: "Work"),
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
                                    ),
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
                            ),
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
                                email: "david.everlof@example.com",
                                usageSummary: "5h 31% · 7d 56% · 7d Fable 82%",
                                usageFraction: 0.82,
                                usageWindows: demoClaudeUsageWindows,
                                models: demoClaudeModels,
                                defaultModelID: demoClaudeModels[0].id
                            ),
                            // A second login on the same runtime, which is what a chip on a row
                            // — and now on the chat's own disc — exists to tell apart.
                            .init(
                                id: "keller",
                                name: "Vera Keller",
                                email: "vera.keller@example.com",
                                usageSummary: "5h 12% · 7d 44%",
                                usageFraction: 0.44,
                                usageWindows: demoClaudeUsageWindows,
                                models: demoClaudeModels,
                                defaultModelID: demoClaudeModels[0].id
                            ),
                        ],
                        models: [],
                        defaultModelID: nil,
                        supportsConversation: true
                    ),
                ],
                supportsManagerRole: true
            ),
            features: [
                RemoteRESTFeature.projectVisibility.rawValue,
                RemoteRESTFeature.usageDashboard.rawValue,
                RemoteRESTFeature.sessionContinuation.rawValue,
            ]
        )
    }
}

extension RemoteMeDTO {
    /// Applies a proof-bearing response from the live session socket.
    ///
    /// Unlike an event-stream delta, an equal-edition visit is canonical and may repair a local
    /// row that somehow diverged while retaining the right edition. An older visit stays stale,
    /// and a host-process change invalidates the whole snapshot before any payload is trusted.
    func applyingCanonicalVisit(_ visit: RemoteSessionVisitedDTO) -> RemoteMeDTO {
        guard visit.receiptCommitted else { return self }
        if let current = revision {
            guard visit.revision.epoch == current.epoch else {
                return replacingCatalogueRevision(nil)
            }
            guard visit.revision.revision >= current.revision else { return self }
            if visit.revision.revision == current.revision {
                return applying([RemoteSessionsChangedDTO(session: visit.session)])
            }
        }
        return applying([RemoteSessionsChangedDTO(
            session: visit.session,
            revision: visit.revision
        )])
    }

    func applying(_ updates: [RemoteSessionsChangedDTO]) -> RemoteMeDTO {
        // A frame from another host process cannot safely be merged into this process's
        // snapshot. Drop the payload and only discard the edition so the caller is forced
        // through an unconditional refresh.
        if let current = revision,
           updates.compactMap(\.revision).contains(where: { $0.epoch != current.epoch }) {
            return replacingCatalogueRevision(nil)
        }
        let candidates = updates.filter { update in
            guard let current = revision, let candidate = update.revision else { return true }
            return candidate.revision > current.revision
        }
        let applicable: [RemoteSessionsChangedDTO]
        if candidates.allSatisfy({ $0.revision != nil }) {
            applicable = candidates.enumerated().sorted { lhs, rhs in
                let left = lhs.element.revision?.revision ?? 0
                let right = rhs.element.revision?.revision ?? 0
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
        } else {
            // A legacy host has no editions. Preserve WebSocket delivery order rather than
            // combining version and input-order comparisons into a non-transitive sort.
            applicable = candidates
        }

        var updatedSessions = sessions
        for update in applicable {
            guard let id = update.removedSessionID ?? update.session?.id else { continue }
            updatedSessions.removeAll { $0.id == id }
            if let session = update.session, !session.isArchived { updatedSessions.append(session) }
        }
        updatedSessions.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.lastActiveAt ?? 0) > ($1.lastActiveAt ?? 0)
        }
        var updatedTerminals = terminals
        if updatedTerminals != nil {
            for update in applicable {
                guard let id = update.removedTerminalID ?? update.terminal?.id else { continue }
                updatedTerminals?.removeAll { $0.id == id }
                if let terminal = update.terminal { updatedTerminals?.append(terminal) }
            }
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
            features: features,
            revision: revision.map { current in
                Self.editionAfterApplying(applicable, to: current)
            } ?? nil
        )
    }

    private func replacingCatalogueRevision(
        _ catalogueRevision: RemoteCatalogueRevisionDTO?
    ) -> RemoteMeDTO {
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
            features: features,
            revision: catalogueRevision
        )
    }

    /// The edition the catalogue is at once these deltas are applied, or nil when the deltas
    /// come from a Mac process the current edition does not know — a restart — so the next
    /// refresh is a full one rather than a conditional request the host would answer `304`.
    ///
    /// A delta with no revision is an older Mac's, and the catalogue keeps the edition it had:
    /// such a host never answers `304`, so an edition that is not advanced costs nothing.
    static func editionAfterApplying(
        _ updates: [RemoteSessionsChangedDTO],
        to current: RemoteCatalogueRevisionDTO
    ) -> RemoteCatalogueRevisionDTO? {
        var latest = current
        for revision in updates.compactMap(\.revision) {
            guard revision.epoch == current.epoch else { return nil }
            if revision.revision > latest.revision { latest = revision }
        }
        return latest
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
            features: features,
            revision: revision
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
                    attention: session.attention,
                    continuation: session.continuation,
                    projectName: session.projectName,
                    projectID: session.projectID,
                    isAvailable: session.isAvailable,
                    lastActiveAt: session.lastActiveAt,
                    isPinned: session.isPinned,
                    isArchived: session.isArchived,
                    archivedAt: session.archivedAt,
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
                    limitRecovery: session.limitRecovery,
                    model: session.model
                )
            },
            terminals: terminals,
            host: host,
            theme: theme,
            themeCatalog: themeCatalog,
            archivedSessions: archivedSessions,
            newSessionCatalog: newSessionCatalog,
            features: features,
            revision: revision
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
                attention: session.attention,
                continuation: session.continuation,
                projectName: session.projectName,
                projectID: session.projectID,
                isAvailable: session.isAvailable,
                lastActiveAt: session.lastActiveAt,
                isPinned: session.isPinned,
                isArchived: session.isArchived,
                archivedAt: session.archivedAt,
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
                limitRecovery: session.limitRecovery,
                model: session.model
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
            features: features,
            revision: revision
        )
    }
}

/// Six-digit hex arithmetic for the derived marketing palette.
///
/// Theme colours arrive as `#RRGGBB` or `#RRGGBBAA`; every result is opaque `#RRGGBB`, because
/// that is all a terminal cell can hold. Unparseable input passes through unchanged.
enum DemoHexColour {
    static func composite(_ hex: String, over ground: String) -> String {
        guard let top = channels(hex), let base = channels(ground) else { return hex }
        let alpha = top.alpha
        return format(
            red: top.red * alpha + base.red * (1 - alpha),
            green: top.green * alpha + base.green * (1 - alpha),
            blue: top.blue * alpha + base.blue * (1 - alpha)
        )
    }

    static func blend(_ from: String, _ to: String, fraction: Double) -> String {
        guard let start = channels(from), let end = channels(to) else { return from }
        return format(
            red: start.red + (end.red - start.red) * fraction,
            green: start.green + (end.green - start.green) * fraction,
            blue: start.blue + (end.blue - start.blue) * fraction
        )
    }

    private static func channels(
        _ hex: String
    ) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        var digits = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6 || digits.count == 8,
              let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        return (
            Double((value >> (16 + shift)) & 0xFF) / 255,
            Double((value >> (8 + shift)) & 0xFF) / 255,
            Double((value >> shift) & 0xFF) / 255,
            hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }

    private static func format(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
