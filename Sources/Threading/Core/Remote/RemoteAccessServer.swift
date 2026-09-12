import CryptoKit
import Foundation
import Network
import os
import ThreadingExtensionKit
import ThreadingRemoteKit

typealias RemoteClientDiagnosticsReceiver = @Sendable (
    _ records: [RemoteDiagnosticRecord],
    _ source: RemoteDiagnosticSource,
    _ deviceID: String
) -> Bool

typealias RemoteUsageDashboardLoader = @MainActor @Sendable (
    _ offset: Int,
    _ count: Int
) async -> RemoteUsageDashboardDTO
typealias RemoteUsageLimitLoader = @MainActor @Sendable (
    _ seriesID: String,
    _ days: Int
) async -> RemoteUsageLimitDTO?
typealias RemoteUsageResetOfferLoader = @MainActor @Sendable (
    _ seriesID: String
) async throws -> RemoteBankedUsageResetOfferDTO?
typealias RemoteUsageResetConsumer = @MainActor @Sendable (
    _ request: RemoteBankedUsageResetRequestDTO,
    _ idempotencyKey: String
) async throws -> RemoteBankedUsageResetResponseDTO
typealias RemoteUniversalSearchLoader = @MainActor @Sendable (
    _ request: RemoteSearchRequestDTO,
    _ deviceID: String
) async throws -> RemoteSearchResponseDTO
typealias RemoteUniversalSearchResolver = @MainActor @Sendable (
    _ token: String,
    _ deviceID: String
) async throws -> RemoteSearchResolutionDTO

/// One JSON value destined for a typed app-setting descriptor. The wire remains deliberately
/// type-erased only until descriptor admission; unsupported JSON shapes fail before mutation.
private struct RemoteAppSettingMutationRequest: Decodable {
    private enum CodingKeys: String, CodingKey { case value }

    let value: AppSettingStoredValue

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let container = try keyed.superDecoder(forKey: .value).singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self.value = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self.value = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self.value = .string(value)
        } else if let value = try? container.decode([String].self) {
            self.value = .stringArray(value)
        } else if let value = try? container.decode([String: String].self) {
            self.value = .stringDictionary(value)
        } else {
            throw DecodingError.typeMismatch(
                AppSettingStoredValue.self,
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Unsupported app-setting value shape"
                )
            )
        }
    }
}

/// Cross-executor dependencies have their own synchronization because tests and the main-actor
/// coordinator configure them while the server reads them from its network queue.
private final class RemoteAccessServerDependencies: @unchecked Sendable {
    private let lock = NSLock()
    private weak var authorizerStorage: (any RemoteAuthorizing)?
    private weak var invitationRedeemerStorage: (any RemoteInvitationRedeeming)?
    private weak var sessionCommandsStorage: (any RemoteSessionCommands)?
    private weak var hostCommandsStorage: (any RemoteHostCommanding)?
    private var diagnosticsReceiverStorage: RemoteClientDiagnosticsReceiver = {
        records, source, deviceID in
        MacRemoteDiagnostics.receive(records, source: source, deviceID: deviceID)
    }

    private var usageDashboardLoaderStorage: RemoteUsageDashboardLoader?
    private var usageLimitLoaderStorage: RemoteUsageLimitLoader?
    private var usageResetOfferLoaderStorage: RemoteUsageResetOfferLoader?
    private var usageResetConsumerStorage: RemoteUsageResetConsumer?
    private var universalSearchLoaderStorage: RemoteUniversalSearchLoader?
    private var universalSearchResolverStorage: RemoteUniversalSearchResolver?

    var authorizer: (any RemoteAuthorizing)? {
        get { lock.withLock { authorizerStorage } }
        set { lock.withLock { authorizerStorage = newValue } }
    }

    var invitationRedeemer: (any RemoteInvitationRedeeming)? {
        get { lock.withLock { invitationRedeemerStorage } }
        set { lock.withLock { invitationRedeemerStorage = newValue } }
    }

    var sessionCommands: (any RemoteSessionCommands)? {
        get { lock.withLock { sessionCommandsStorage } }
        set { lock.withLock { sessionCommandsStorage = newValue } }
    }

    var hostCommands: (any RemoteHostCommanding)? {
        get { lock.withLock { hostCommandsStorage } }
        set { lock.withLock { hostCommandsStorage = newValue } }
    }

    var diagnosticsReceiver: RemoteClientDiagnosticsReceiver {
        get { lock.withLock { diagnosticsReceiverStorage } }
        set { lock.withLock { diagnosticsReceiverStorage = newValue } }
    }

    var usageDashboardLoader: RemoteUsageDashboardLoader? {
        get { lock.withLock { usageDashboardLoaderStorage } }
        set { lock.withLock { usageDashboardLoaderStorage = newValue } }
    }

    var usageLimitLoader: RemoteUsageLimitLoader? {
        get { lock.withLock { usageLimitLoaderStorage } }
        set { lock.withLock { usageLimitLoaderStorage = newValue } }
    }

    var usageResetOfferLoader: RemoteUsageResetOfferLoader? {
        get { lock.withLock { usageResetOfferLoaderStorage } }
        set { lock.withLock { usageResetOfferLoaderStorage = newValue } }
    }

    var usageResetConsumer: RemoteUsageResetConsumer? {
        get { lock.withLock { usageResetConsumerStorage } }
        set { lock.withLock { usageResetConsumerStorage = newValue } }
    }

    var universalSearchLoader: RemoteUniversalSearchLoader? {
        get { lock.withLock { universalSearchLoaderStorage } }
        set { lock.withLock { universalSearchLoaderStorage = newValue } }
    }

    var universalSearchResolver: RemoteUniversalSearchResolver? {
        get { lock.withLock { universalSearchResolverStorage } }
        set { lock.withLock { universalSearchResolverStorage = newValue } }
    }
}

/// The second HTTP/WebSocket server — the one a tunnel forwards to. It is deliberately separate
/// from `MCPServer` and `ExtensionHostService`: those broker tool permissions and host
/// extensions, and nothing reachable through a public tunnel may touch them.
///
/// One server, one identity, one authorization path. Which addresses it answers on is
/// `RemoteListenerSet`'s question, not this type's: it owns the sticky port and one `NWListener`
/// per door. What remains here is a latched ready-or-failed completion and a `queue.sync` stop
/// that has cancelled everything by the time it returns.
///
/// Mutable connection and rate-limit state belongs to `queue`, which is also the listener set's
/// queue. The dependency values have separate locks. This queue ownership is why passing the
/// server's identity into Network.framework callbacks is safe.
final class RemoteAccessServer: @unchecked Sendable {
    // MARK: - Properties

    /// Resolves owner-device and exact-session guest bearer tokens. Read from the server queue,
    /// so the coordinator's authority store must be thread-safe.
    var authorizer: (any RemoteAuthorizing)? {
        get { dependencies.authorizer }
        set { dependencies.authorizer = newValue }
    }

    var invitationRedeemer: (any RemoteInvitationRedeeming)? {
        get { dependencies.invitationRedeemer }
        set { dependencies.invitationRedeemer = newValue }
    }

    var sessionCommands: (any RemoteSessionCommands)? {
        get { dependencies.sessionCommands }
        set { dependencies.sessionCommands = newValue }
    }

    var hostCommands: (any RemoteHostCommanding)? {
        get { dependencies.hostCommands }
        set { dependencies.hostCommands = newValue }
    }

    /// Injectable so integration tests never append to the developer's real support journal.
    var receiveClientDiagnostics: RemoteClientDiagnosticsReceiver {
        get { dependencies.diagnosticsReceiver }
        set { dependencies.diagnosticsReceiver = newValue }
    }

    /// Deterministic integration-test seams. Production leaves these nil and reads the app's
    /// immutable projections through the background preparation paths below.
    var usageDashboardLoader: RemoteUsageDashboardLoader? {
        get { dependencies.usageDashboardLoader }
        set { dependencies.usageDashboardLoader = newValue }
    }

    var usageLimitLoader: RemoteUsageLimitLoader? {
        get { dependencies.usageLimitLoader }
        set { dependencies.usageLimitLoader = newValue }
    }

    var usageResetOfferLoader: RemoteUsageResetOfferLoader? {
        get { dependencies.usageResetOfferLoader }
        set { dependencies.usageResetOfferLoader = newValue }
    }

    var usageResetConsumer: RemoteUsageResetConsumer? {
        get { dependencies.usageResetConsumer }
        set { dependencies.usageResetConsumer = newValue }
    }

    var universalSearchLoader: RemoteUniversalSearchLoader? {
        get { dependencies.universalSearchLoader }
        set { dependencies.universalSearchLoader = newValue }
    }

    var universalSearchResolver: RemoteUniversalSearchResolver? {
        get { dependencies.universalSearchResolver }
        set { dependencies.universalSearchResolver = newValue }
    }

    var port: UInt16? {
        listeners.status.port
    }

    /// What every door is doing, for the coordinator to publish and a later settings screen to
    /// render. Readable from any executor.
    var listenerStatus: RemoteListenerStatus { listeners.status }

    /// What each live listener was asked to bind, whatever state it reached.
    var requestedBindings: [RemoteListenerBinding] { listeners.requestedBindings }

    /// The object identity of each live listener, so a door change can be proven to have left
    /// the other doors alone.
    var listenerIdentities: [RemoteNetworkAddress: ObjectIdentifier] { listeners.listenerIdentities }

    /// Called on the server queue whenever a door changes state.
    var onListenerStatusChange: (@Sendable (RemoteListenerStatus) -> Void)? {
        get { listeners.onStatusChange }
        set { listeners.onStatusChange = newValue }
    }

    /// Where a door transition is journalled. Injectable for the same reason
    /// `receiveClientDiagnostics` is: a hosted test would otherwise append to the developer's
    /// own support journal.
    var recordListenerDiagnostic:
        @Sendable (RemoteDiagnosticEvent, RemoteDiagnosticLevel, [RemoteDiagnosticField: String]) -> Void
    {
        get { listeners.journal }
        set { listeners.journal = newValue }
    }

    private var connectionsByID: [ObjectIdentifier: RemoteConnection] = [:]
    private var authLimiter = RemoteAuthRateLimiter()
    private var mutationReplayCache: [MutationReplayKey: MutationReplayEntry] = [:]
    /// Files a composer handed over but has not yet named in a prompt. Queue-confined, like the
    /// replay cache above it, and swept on the same request that sweeps that.
    private var attachmentUploads = RemoteAttachmentUploadStore()

    private struct MutationReplayKey: Hashable {
        let requestID: String
        let bearerDigest: Data
        let deviceID: String
    }

    private struct MutationReplayEntry {
        let fingerprint: Data
        let createdAt: Date
        var response: HTTPResponse?
        var waiters: [@Sendable (RemoteRouteDecision) -> Void]
    }

    private let dependencies = RemoteAccessServerDependencies()
    private let services: RemoteAccessServerServices
    private let queue = DispatchQueue(label: RemoteAccessDefaults.queueLabel, qos: .userInitiated)
    private let router = RemoteRouter()
    private let listeners: RemoteListenerSet

    /// The identity provider has no default on purpose: this server is composed by its root,
    /// and naming the shared store here would put a global lookup inside the one file the
    /// architecture lint keeps free of them.
    init(
        services: RemoteAccessServerServices,
        addressSource: @escaping RemoteNetworkAddressSource = RemoteNetworkInterfaces.current,
        identityProvider: any RemoteAccessIdentityProviding,
        advertiser: any RemoteServiceAdvertising = RemoteServiceAdvertisers.standard(),
        hostIDSource: @escaping @Sendable () -> String = { RemoteHostIdentity.current.id }
    ) {
        self.services = services
        listeners = RemoteListenerSet(
            queue: queue,
            addressSource: addressSource,
            identityProvider: identityProvider,
            advertiser: advertiser,
            hostIDSource: hostIDSource
        )
        listeners.onConnection = { [weak self] connection in self?.accept(connection) }
    }

    // MARK: - Lifecycle

    /// Binds loopback and every enabled door, and reports the port actually taken.
    ///
    /// The configuration is the caller's, not a constant here: the port is a user setting with a
    /// deterministic fallback range, and which routable doors get a listener is a decision the
    /// coordinator reads from settings. The completion latches, so a listener that flaps between
    /// states after the first answer does not call it twice.
    func start(
        configuration: RemoteListenerConfiguration,
        completion: @escaping @MainActor @Sendable (RemoteListenerStartOutcome) -> Void
    ) {
        listeners.start(configuration: configuration) { outcome in
            Task { @MainActor in completion(outcome) }
        }
    }

    /// Applies a changed door selection without disturbing the doors that did not change, and
    /// without touching loopback.
    func updateDoors(_ doors: Set<RemoteAccessDoor>) {
        listeners.update(doors: doors)
    }

    /// Re-reads the interface list and rebuilds only the listeners whose address changed.
    func refreshListenerAddresses() {
        listeners.refreshAddresses()
    }

    /// Starts or stops advertising the LAN door over Bonjour. No listener is disturbed either
    /// way: the door is whether this Mac answers, and this is whether it says so out loud.
    func updateDiscovery(isEnabled: Bool) {
        listeners.update(isDiscoveryEnabled: isEnabled)
    }

    /// What this Mac is broadcasting over Bonjour right now, if anything.
    var advertisedService: RemoteServiceRegistration? { listeners.advertisedService }

    /// Rebuilds the routable listeners so they present the identity store's current certificate.
    /// The port does not move, and loopback is not disturbed.
    func reloadIdentity() {
        listeners.reloadIdentity()
    }

    func stop() {
        queue.sync {
            // `cancel()` synchronously reports `didClose`, which removes its entry. Snapshot
            // and clear first so shutdown never mutates a Dictionary while iterating its live
            // values view.
            let connections = Array(connectionsByID.values)
            connectionsByID.removeAll()
            for connection in connections {
                connection.cancel()
            }
            authLimiter = RemoteAuthRateLimiter()
            mutationReplayCache.removeAll()
            attachmentUploads.discardAll()
        }
        listeners.stop()
    }

    /// Revocation applies to already-open sockets as well as future authentication. Without
    /// this, "Stop Sharing" would revoke the copied URL but leave a collaborator's current tab
    /// interactive until it happened to disconnect.
    func revokeConnections(shareID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connectionsByID.values
                where connection.authorization?.shareID == shareID
            {
                connection.sendClose(code: 4003, reason: "Share revoked")
            }
        }
    }

    // MARK: - Accepting

    private func accept(_ nwConnection: NWConnection) {
        guard connectionsByID.count < RemoteAccessDefaults.maximumConnections else {
            nwConnection.cancel()
            return
        }
        let connection = RemoteConnection(connection: nwConnection, queue: queue, delegate: self)
        connectionsByID[ObjectIdentifier(connection)] = connection
        connection.start()
    }
}

// MARK: - RemoteConnection.Delegate

extension RemoteAccessServer: RemoteConnection.Delegate {
    func route(
        _ request: HTTPRequest,
        from connection: RemoteConnection,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard request.method == "POST",
              let rawRequestID = request.header(RemoteRouter.requestIDHeader)
        else {
            routeUncached(request, from: connection, respond: respond)
            return
        }
        guard let requestID = RemoteInboundPolicy.normalizedMutationRequestID(rawRequestID) else {
            respond(.respond(RemoteRouter.error(
                400,
                "Invalid request id",
                code: .invalidRequestID
            )))
            return
        }
        guard let bearer = RemoteRouter.bearerToken(from: request),
              RemoteInboundPolicy.acceptsBearerToken(bearer),
              let deviceID = RemoteInboundPolicy.normalizedDeviceID(
                  request.header(RemoteRouter.deviceHeader)
              )
        else {
            // Authentication owns the response for missing or malformed credentials. Such a
            // request cannot have performed a mutation, so it does not belong in replay state.
            routeUncached(request, from: connection, respond: respond)
            return
        }

        let now = Date()
        mutationReplayCache = mutationReplayCache.filter {
            now.timeIntervalSince($0.value.createdAt) < RemoteAccessDefaults.mutationReplayLifetime
        }
        attachmentUploads.reap(now: now)
        let key = MutationReplayKey(
            requestID: requestID,
            bearerDigest: Data(SHA256.hash(data: Data(bearer.utf8))),
            deviceID: deviceID
        )
        let fingerprint = Self.mutationFingerprint(for: request)
        if var existing = mutationReplayCache[key] {
            guard existing.fingerprint == fingerprint else {
                respond(.respond(RemoteRouter.error(
                    409,
                    "Request id was reused",
                    code: .requestIDReused
                )))
                return
            }
            if let response = existing.response {
                respond(.respond(response))
                return
            }
            guard existing.waiters.count < RemoteAccessDefaults.maximumMutationReplayWaiters else {
                respond(.respond(RemoteRouter.error(429, "Too Many Requests")))
                return
            }
            existing.waiters.append(respond)
            mutationReplayCache[key] = existing
            return
        }

        if mutationReplayCache.count >= RemoteAccessDefaults.maximumMutationReplayEntries,
           let oldestCompleted = mutationReplayCache
           .filter({ $0.value.response != nil })
           .min(by: { $0.value.createdAt < $1.value.createdAt })?.key
        {
            mutationReplayCache.removeValue(forKey: oldestCompleted)
        }
        guard mutationReplayCache.count < RemoteAccessDefaults.maximumMutationReplayEntries else {
            respond(.respond(RemoteRouter.error(
                503,
                "Replay cache busy",
                code: .replayCacheBusy
            )))
            return
        }
        mutationReplayCache[key] = MutationReplayEntry(
            fingerprint: fingerprint,
            createdAt: now,
            response: nil,
            waiters: []
        )
        routeUncached(request, from: connection) { [weak self] decision in
            guard let self else { return }
            self.queue.async {
                guard case var .respond(response) = decision else {
                    self.mutationReplayCache.removeValue(forKey: key)
                    respond(decision)
                    return
                }
                response.extraHeaders["X-Threading-Request-ID"] = requestID
                var completed = self.mutationReplayCache[key]
                completed?.response = response
                let waiters = completed?.waiters ?? []
                completed?.waiters.removeAll(keepingCapacity: false)
                if let completed { self.mutationReplayCache[key] = completed }
                respond(.respond(response))
                waiters.forEach { $0(.respond(response)) }
            }
        }
    }

    private func routeUncached(
        _ request: HTTPRequest,
        from _: RemoteConnection,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        let path = RemoteRouter.normalizedPath(request.path)

        // Static client: GET only, no auth, no data.
        if request.method == "GET", let response = router.staticResponse(forPath: path) {
            respond(.respond(response))
            return
        }

        // WebSocket upgrade: auth is deferred to the first frame.
        if request.method == "GET", path == RemoteRouter.themeEventsPath {
            respond(.upgrade(sessionID: RemoteRouter.themeEventsRouteID))
            return
        }
        if request.method == "GET", let sessionID = RemoteRouter.webSocketSessionID(forPath: path) {
            respond(.upgrade(sessionID: sessionID))
            return
        }
        if request.method == "GET",
           let terminalID = RemoteRouter.webSocketTerminalID(forPath: path)
        {
            respond(.upgradeTerminal(terminalID: terminalID))
            return
        }

        // The one REST call: the share and its sessions.
        if request.method == "GET", path == RemoteRouter.apiSessionsPath {
            handleMe(request, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.searchPath {
            handleUniversalSearch(request, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.searchResolvePath {
            handleUniversalSearchResolution(request, respond: respond)
            return
        }

        if request.method == "GET", path == RemoteRouter.usageCapacityPath {
            handleUsageCapacity(request, respond: respond)
            return
        }

        if request.method == "GET", path == RemoteRouter.usagePath {
            handleUsage(request, respond: respond)
            return
        }

        if request.method == "GET", path == RemoteRouter.usageLimitPath {
            handleUsageLimit(request, respond: respond)
            return
        }

        if request.method == "GET", path == RemoteRouter.usageResetPath {
            handleUsageResetOffer(request, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.usageResetPath {
            handleUsageReset(request, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.createSessionPath {
            handleCreateSession(request, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.notificationRegistrationPath {
            handleNotificationRegistration(request, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.diagnosticUploadPath {
            handleDiagnosticUpload(request, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.mobileDiagnosticsCaptureUploadPath {
            handleMobileDiagnosticsCaptureUpload(request, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.invitationAcceptancePath {
            handleAcceptInvitation(request, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.hostedDeviceCredentialPath {
            handleHostedDeviceCredential(request, respond: respond)
            return
        }

        // An interact-capable paired device may resume a dormant conversation before opening
        // its socket. This is a narrow lifecycle door: it cannot create, delete, or change the
        // operational configuration of sessions, and the dedicated server exposes no MCP route.
        if request.method == "POST",
           let sessionID = RemoteRouter.resumeSessionID(forPath: path)
        {
            handleResume(request, sessionID: sessionID, respond: respond)
            return
        }
        if request.method == "POST",
           let terminalID = RemoteRouter.resumeTerminalID(forPath: path)
        {
            handleResumeTerminal(request, terminalID: terminalID, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.appThemePath {
            handleAppTheme(request, respond: respond)
            return
        }

        if request.method == "POST",
           let identity = RemoteRouter.appSettingIdentity(forPath: path)
        {
            handleAppSetting(
                request,
                identity: identity,
                respond: respond
            )
            return
        }

        // The one route a paired client may write a file through. Owner scope and interact
        // capability are both required, and the staged bytes are refused unless the host would
        // preview the assembled file — see `RemoteAttachmentUploadStore`.
        if request.method == "POST",
           let sessionID = RemoteRouter.attachmentUploadSessionID(forPath: path)
        {
            handleAttachmentUpload(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.themeSessionID(forPath: path)
        {
            handleSessionTheme(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.renameSessionID(forPath: path)
        {
            handleRenameSession(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.pinnedSessionID(forPath: path)
        {
            handlePinnedSession(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.archivedSessionID(forPath: path)
        {
            handleArchivedSession(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.snoozedSessionID(forPath: path)
        {
            handleSnoozedSession(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.surfaceSessionID(forPath: path)
        {
            handleSessionSurface(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.accountSessionID(forPath: path)
        {
            handleSessionAccount(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.continuationSessionID(forPath: path)
        {
            handleSessionContinuationOptions(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.continuationSessionID(forPath: path)
        {
            handleSessionContinuation(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.limitRecoverySessionID(forPath: path)
        {
            handleSessionLimitRecovery(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.shareSessionID(forPath: path)
        {
            handleCreateShare(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.unshareSessionID(forPath: path)
        {
            handleRevokeShares(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let terminalID = RemoteRouter.shareTerminalID(forPath: path)
        {
            handleCreateTerminalShare(request, terminalID: terminalID, respond: respond)
            return
        }

        if request.method == "POST",
           let terminalID = RemoteRouter.unshareTerminalID(forPath: path)
        {
            handleRevokeTerminalShares(request, terminalID: terminalID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.extensionPanelSessionID(forPath: path)
        {
            handleExtensionPanelAction(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let route = RemoteRouter.gitReviewRoute(forPath: path)
        {
            handleGitReview(
                request,
                sessionID: route.sessionID,
                mode: route.mode,
                respond: respond
            )
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.repositoryFilesSessionID(forPath: path)
        {
            handleRepositoryFiles(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.repositoryFileSessionID(forPath: path)
        {
            handleRepositoryFile(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.attachmentsSessionID(forPath: path)
        {
            handleAttachments(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.workspaceSessionID(forPath: path)
        {
            handleWorkspace(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.browserPreviewSessionID(forPath: path)
        {
            handleBrowserPreview(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.extensionPanelSessionID(forPath: path)
        {
            handleExtensionPanel(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.extensionPanelResourceSessionID(forPath: path)
        {
            handleExtensionPanelResource(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.attachmentThumbnailSessionID(forPath: path)
        {
            handleAttachmentThumbnail(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.attachmentSessionID(forPath: path)
        {
            handleAttachment(request, sessionID: sessionID, respond: respond)
            return
        }

        respond(.respond(RemoteRouter.error(404, "Not Found")))
    }

    private static func mutationFingerprint(for request: HTTPRequest) -> Data {
        var input = Data(request.method.utf8)
        input.append(0)
        input.append(contentsOf: RemoteRouter.normalizedPath(request.path).utf8)
        input.append(0)
        for header in [
            RemoteRouter.clientHeader,
            RemoteRouter.protocolHeader,
            RemoteRouter.protocolMinimumHeader,
        ] {
            input.append(contentsOf: (request.header(header) ?? "").utf8)
            input.append(0)
        }
        input.append(mutationFingerprintBody(for: request))
        return Data(SHA256.hash(data: input))
    }

    /// JSON object order and whitespace are serialization details, not mutation identity. Native
    /// clients rebuild a request when they fail over to another address, so hashing raw bytes can
    /// reject the same operation precisely when its first response was lost. Invalid or non-JSON
    /// bodies retain byte-for-byte identity and continue through their route's normal validation.
    private static func mutationFingerprintBody(for request: HTTPRequest) -> Data {
        guard request.header("content-type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "application/json",
            let object = try? JSONSerialization.jsonObject(with: request.body),
            JSONSerialization.isValidJSONObject(object),
            let canonical = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        else {
            return request.body
        }
        return canonical
    }

    func handleMessage(_ message: RemoteWebSocket.Message, from connection: RemoteConnection) {
        guard case let .text(data) = message,
              let parsed = try? JSONDecoder().decode(RemoteClientMessage.self, from: data)
        else {
            return
        }

        switch parsed.type {
        case "auth":
            authenticate(connection, message: parsed)
        case "input":
            handleInput(connection, data: parsed.data, requestID: parsed.requestID)
        case "submit":
            handleSubmit(
                connection,
                text: parsed.text,
                contextAttachments: parsed.contextAttachments,
                attachmentUploadIDs: parsed.attachmentUploadIDs,
                requestID: parsed.requestID
            )
        case "terminalSubmit":
            handleTerminalSubmit(
                connection,
                text: parsed.text,
                attachmentUploadIDs: parsed.attachmentUploadIDs,
                requestID: parsed.requestID
            )
        case "terminalAttachmentInsert":
            handleTerminalAttachmentInsert(
                connection,
                attachmentUploadIDs: parsed.attachmentUploadIDs,
                requestID: parsed.requestID
            )
        case "attentionRequest":
            handleAttentionRequest(
                connection,
                recipientID: parsed.recipientID,
                note: parsed.text,
                requestID: parsed.requestID
            )
        case "inputControl":
            handleInputControl(
                connection,
                action: parsed.state,
                targetID: parsed.recipientID,
                requestID: parsed.requestID
            )
        case "questionAnswer":
            handleQuestionAnswer(connection, id: parsed.id, answers: parsed.answers, decision: parsed.decision)
        case "permission":
            handlePermission(
                connection,
                id: parsed.id,
                decision: parsed.decision
            )
        case "presence":
            handlePresence(connection, state: parsed.state)
        case "sessionPark":
            handleSessionPark(connection)
        case "sessionResume":
            handleSessionResume(connection)
        case "viewport":
            handleViewport(
                connection,
                cols: parsed.cols,
                rows: parsed.rows,
                requestID: parsed.requestID
            )
        case "viewportRelease":
            handleViewportRelease(connection)
        case "conversationPage":
            handleConversationPage(
                connection,
                beforeRowID: parsed.beforeRowID,
                limit: parsed.limit
            )
        case "conversationResync":
            handleConversationResync(connection)
        case "runPlanPage":
            handleRunPlanPage(
                connection,
                revision: parsed.revision,
                offset: parsed.offset,
                limit: parsed.limit
            )
        case "mobileDiagnosticsHello":
            handleMobileDiagnosticsSignal(
                connection,
                routeKind: parsed.state,
                screenshotPolicy: .latestIncident,
                automatic: true
            )
        case "mobileDiagnosticsIncident":
            handleMobileDiagnosticsSignal(
                connection,
                routeKind: parsed.state,
                screenshotPolicy: .latestIncident,
                automatic: false
            )
        case "mobileDiagnosticsDisabled":
            handleMobileDiagnosticsDisabled(connection, routeKind: parsed.state)
        default:
            break
        }
    }

    func didClose(_ connection: RemoteConnection) {
        // The admission limit is concurrent, not lifetime. Keeping closed connections here
        // permanently made the 33rd browser visit fail even when every earlier tab was gone.
        connectionsByID.removeValue(forKey: ObjectIdentifier(connection))
        DispatchQueue.main.async {
            self.services.mirrors.detach(connection)
        }
        services.mobileDiagnosticsCaptures.unregister(connection)
    }

    // MARK: - REST

    private func handleMe(_ request: HTTPRequest, respond: @escaping @Sendable (RemoteRouteDecision) -> Void) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        respondWithCatalogue(for: authorization, request: request, respond: respond)
    }

    /// Answers with this authorization's catalogue, doing on the main queue only what has to be
    /// there.
    ///
    /// The projection reads main-actor state and stays on it, behind the registry's one-second
    /// shared owner cache. Everything after that — comparing the client's validator, encoding
    /// the JSON, compressing it — is either one comparison or work a `userInitiated` worker
    /// does on an immutable value. The encoded body is handed back to the registry so the next
    /// device asking for the same catalogue edition is served bytes that already exist. Measured
    /// during a session-relaunch storm at 2.65 s of `serverWaitMS` per phone refresh when all of
    /// this ran inline on main; see `docs/architecture/performance.md`.
    private func respondWithCatalogue(
        for authorization: RemoteAuthorization,
        request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        let acceptsGzip = RemoteRouter.acceptsGzip(request)
        let requestedRevision = RemoteRouter.requestedCatalogueRevision(request)
        DispatchQueue.main.async {
            let snapshot = self.services.mirrors.meResponseSnapshot(for: authorization)
            if snapshot.revision.matches(ifNoneMatch: requestedRevision) {
                respond(.respond(RemoteRouter.notModified(snapshot.revision)))
                return
            }
            if let encoded = snapshot.encoded {
                respond(.respond(RemoteRouter.encodedJSON(encoded, acceptsGzip: acceptsGzip)))
                return
            }
            guard let payload = snapshot.payload else {
                respond(.respond(RemoteRouter.error(500, "Internal Server Error")))
                return
            }
            let revision = snapshot.revision
            DispatchQueue.global(qos: .userInitiated).async {
                let encoded: RemoteMeEncodedResponse
                do {
                    encoded = try RemoteMeEncodedResponse.encode(payload, revision: revision)
                } catch {
                    ThreadingLogger.remote.error(
                        "Remote catalogue encoding failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                    respond(.respond(RemoteRouter.error(500, "Internal Server Error")))
                    return
                }
                respond(.respond(RemoteRouter.encodedJSON(encoded, acceptsGzip: acceptsGzip)))
                DispatchQueue.main.async {
                    self.services.mirrors.storeMeResponse(encoded, for: authorization)
                }
            }
        }
    }

    private func handleUniversalSearch(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canUseUniversalSearch else {
            respond(.respond(RemoteRouter.error(404, "Not Found")))
            return
        }
        guard let deviceID = RemoteInboundPolicy.normalizedDeviceID(
            request.header(RemoteRouter.deviceHeader)
        ), let loader = universalSearchLoader,
        let query = try? JSONDecoder().decode(RemoteSearchRequestDTO.self, from: request.body),
        query.query.utf8.count <= RemoteSearchWireLimits.maximumQueryUTF8Bytes else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        Task { @MainActor in
            do {
                let payload = try await loader(query, deviceID)
                guard self.authorizer?.isCurrent(authorization) == true else {
                    respond(.respond(RemoteRouter.error(401, "Unauthorized")))
                    return
                }
                respond(.respond(RemoteRouter.json(
                    payload,
                    maximumBytes: RemoteAccessDefaults.maximumSearchResponseBytes
                )))
            } catch is CancellationError {
                respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
            } catch let error as RemoteUniversalSearchError {
                switch error {
                case .invalidRequest:
                    respond(.respond(RemoteRouter.error(400, "Bad Request")))
                case .resultNoLongerAvailable:
                    respond(.respond(RemoteRouter.error(404, "Not Found")))
                case .unavailable:
                    respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
                }
            } catch {
                respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
            }
        }
    }

    private func handleUniversalSearchResolution(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canUseUniversalSearch else {
            respond(.respond(RemoteRouter.error(404, "Not Found")))
            return
        }
        guard let deviceID = RemoteInboundPolicy.normalizedDeviceID(
            request.header(RemoteRouter.deviceHeader)
        ), let resolver = universalSearchResolver,
        let resolution = try? JSONDecoder().decode(
            RemoteSearchResolveRequestDTO.self,
            from: request.body
        ), RemoteInboundPolicy.acceptsSearchToken(resolution.token) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        Task { @MainActor in
            do {
                let payload = try await resolver(resolution.token, deviceID)
                guard self.authorizer?.isCurrent(authorization) == true else {
                    respond(.respond(RemoteRouter.error(401, "Unauthorized")))
                    return
                }
                respond(.respond(RemoteRouter.json(
                    payload,
                    maximumBytes: RemoteAccessDefaults.maximumSearchResponseBytes
                )))
            } catch let error as RemoteUniversalSearchError {
                switch error {
                case .invalidRequest:
                    respond(.respond(RemoteRouter.error(400, "Bad Request")))
                case .resultNoLongerAvailable, .unavailable:
                    respond(.respond(RemoteRouter.error(404, "Not Found")))
                }
            } catch {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
            }
        }
    }

    private func handleUsageCapacity(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canReadHostUsage else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        let loader = services.usageCapacity
        Task {
            do {
                let payload = try await loader()
                // Encoding happens on this transport task, after bounded main-actor projection.
                let response = RemoteRouter.json(payload, maximumBytes: RemoteUsageCapacityLimits.bytes)
                guard authorizer?.isCurrent(authorization) == true else {
                    respond(.respond(RemoteRouter.error(401, "Unauthorized")))
                    return
                }
                respond(.respond(response))
            } catch {
                respond(.respond(RemoteRouter.error(503, "Capacity Unavailable")))
            }
        }
    }

    private func handleUsage(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canReadHostUsage else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }

        let rawCursor = RemoteRouter.queryValue(named: "cursor", in: request.path)
        let rawCount = RemoteRouter.queryValue(named: "limit", in: request.path)
        let offset: Int
        if let rawCursor {
            guard let parsed = Int(rawCursor) else {
                respond(.respond(RemoteRouter.error(400, "Bad Request")))
                return
            }
            offset = max(0, parsed)
        } else {
            offset = 0
        }
        let count: Int
        if let rawCount {
            guard let parsed = Int(rawCount) else {
                respond(.respond(RemoteRouter.error(400, "Bad Request")))
                return
            }
            count = parsed
        } else {
            count = RemoteUsageBridge.defaultLimitPageSize
        }

        let loader = usageDashboardLoader ?? services.usageDashboard
        Task { @MainActor in
            let payload = await loader(offset, count)
            respond(.respond(RemoteRouter.json(
                payload,
                maximumBytes: RemoteUsageBridge.maximumOverviewResponseBytes
            )))
        }
    }

    private func handleUsageLimit(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canReadHostUsage else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let seriesID = RemoteRouter.queryValue(named: "series", in: request.path),
              !seriesID.isEmpty,
              seriesID.utf8.count <= 512,
              let days = RemoteRouter.queryValue(named: "days", in: request.path).flatMap(Int.init),
              UsageDashboardProjectionDefaults.overviewRanges.contains(days)
        else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        let loader = usageLimitLoader ?? services.usageLimit
        Task { @MainActor in
            guard let payload = await loader(seriesID, days) else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            respond(.respond(RemoteRouter.json(
                payload,
                maximumBytes: RemoteUsageBridge.maximumLimitResponseBytes
            )))
        }
    }

    private func handleUsageResetOffer(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canManageHost else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let seriesID = RemoteRouter.queryValue(named: "series", in: request.path),
              !seriesID.isEmpty,
              seriesID.utf8.count <= 512 else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }
        let loader = usageResetOfferLoader ?? services.usageResetOffer
        Task { @MainActor in
            do {
                guard let payload = try await loader(seriesID) else {
                    respond(.respond(RemoteRouter.error(404, "Not Found")))
                    return
                }
                guard self.authorizer?.isCurrent(authorization) == true else {
                    respond(.respond(RemoteRouter.error(401, "Unauthorized")))
                    return
                }
                respond(.respond(RemoteRouter.json(payload)))
            } catch {
                respond(.respond(Self.usageResetErrorResponse(error)))
            }
        }
    }

    private func handleUsageReset(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canManageHost else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard request.body.count <= RemoteAccessDefaults.maximumUsageResetRequestBytes,
              let payload = try? JSONDecoder().decode(
                  RemoteBankedUsageResetRequestDTO.self,
                  from: request.body
              ), !payload.seriesID.isEmpty,
              payload.seriesID.utf8.count <= 512,
              payload.availableCount > 0,
              payload.offerFingerprint.utf8.count == 64,
              let requestID = request.header(RemoteRouter.requestIDHeader).flatMap(
                  RemoteInboundPolicy.normalizedMutationRequestID
              ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }
        let consumer = usageResetConsumer ?? services.usageResetConsumer
        Task { @MainActor in
            do {
                let response = try await consumer(payload, requestID)
                guard self.authorizer?.isCurrent(authorization) == true else {
                    respond(.respond(RemoteRouter.error(401, "Unauthorized")))
                    return
                }
                respond(.respond(RemoteRouter.json(response)))
            } catch {
                respond(.respond(Self.usageResetErrorResponse(error)))
            }
        }
    }

    private static func usageResetErrorResponse(_ error: Error) -> HTTPResponse {
        switch error as? BankedUsageResetError {
        case .noCredit, .offerChanged, .busy:
            return RemoteRouter.error(409, "Usage reset changed")
        case .unsupportedAccount:
            return RemoteRouter.error(404, "Not Found")
        case .accountIdentityUnavailable, .accountMismatch, .updateCodex,
             .transport, .malformedResponse:
            return RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)
        case nil:
            return RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)
        }
    }

    private func handleResume(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.capability == .interact else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let sessionID = SessionID(uuidString: rawSessionID),
              authorization.scope.covers(sessionID)
        else {
            respond(.respond(RemoteRouter.error(404, "Not Found")))
            return
        }

        DispatchQueue.main.async {
            guard RemoteSessionAccess.isVisible(
                self.services.sessionQueries.session(withID: sessionID)
            ) else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }

            if !self.services.runtimeStatus.isRunning(sessionID: sessionID) {
                guard let sessionCommands = self.sessionCommands,
                      sessionCommands.resumeRemoteSession(sessionID)
                else {
                    respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
                    return
                }
            }
            let isReady = self.services.runtimeStatus.isRunning(sessionID: sessionID)
            if !isReady { self.services.mirrors.noteSessionStarting(sessionID) }
            respond(.respond(RemoteRouter.json(
                ["state": isReady ? "ready" : "starting"],
                status: 202,
                reason: "Accepted"
            )))
        }
    }

    private func handleResumeTerminal(
        _ request: HTTPRequest,
        terminalID rawTerminalID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.capability == .interact else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let terminalID = TerminalID(uuidString: rawTerminalID),
              authorization.scope.covers(terminalID)
        else {
            respond(.respond(RemoteRouter.error(404, "Not Found")))
            return
        }
        DispatchQueue.main.async {
            guard self.services.sessionQueries.terminal(withID: terminalID) != nil else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            if !self.services.mirrors.isTerminalAvailable(terminalID) {
                guard let sessionCommands = self.sessionCommands,
                      sessionCommands.resumeRemoteTerminal(terminalID)
                else {
                    respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
                    return
                }
            }
            respond(.respond(RemoteRouter.json(
                ["state": self.services.mirrors.isTerminalAvailable(terminalID)
                    ? "ready" : "starting"],
                status: 202,
                reason: "Accepted"
            )))
        }
    }

    /// What the journal says for a launch choice the request left to the account.
    private enum RemoteLaunchJournalValue {
        static let inherited = "inherit"
    }

    private func handleCreateSession(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard canManageSessions(authorization) else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let creation = try? JSONDecoder().decode(
            RemoteCreateSessionRequestDTO.self,
            from: request.body
        ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        let legacyPrompt = creation.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt: String
        if let reportOpening = creation.reportOpening {
            guard legacyPrompt.isEmpty else {
                respond(.respond(RemoteRouter.error(
                    400,
                    "Bad Request",
                    code: .invalidReportOpening
                )))
                return
            }
            prompt = reportOpening.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            prompt = legacyPrompt
        }
        guard RemoteInboundPolicy.acceptsPrompt(prompt), !prompt.isEmpty,
              RemoteInboundPolicy.acceptsLaunchIdentifier(creation.projectID),
              RemoteInboundPolicy.acceptsLaunchIdentifier(creation.agentKind),
              creation.accountHandle.map(RemoteInboundPolicy.acceptsAccountIdentifier) ?? true,
              creation.model.map(RemoteInboundPolicy.acceptsLaunchIdentifier) ?? true,
              creation.reasoningEffort.map(RemoteInboundPolicy.acceptsLaunchIdentifier) ?? true,
              creation.permissionMode.map(RemoteInboundPolicy.acceptsLaunchIdentifier) ?? true,
              creation.surface.isKnown
        else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        let openingAttachmentIDs = creation.openingAttachmentUploadIDs ?? []
        guard creation.reportOpening == nil
            || (creation.openingAttachmentScopeID == nil && openingAttachmentIDs.isEmpty)
        else {
            // Reports and ordinary new-session drafts are distinct atomic openings. Combining
            // them would evade each surface's attachment bound and give a malicious client nine
            // paths where every composer is capped at eight.
            respond(.respond(RemoteRouter.error(
                400,
                "Invalid Opening Attachments",
                code: .invalidOpeningAttachments
            )))
            return
        }

        // The bytes are validated and lent on the server queue before a session can exist. The
        // application receives a temporary path, takes its own durable copy before launch, and
        // this claim is discarded whichever way that transaction ends. An older Mac ignores the
        // report envelope and refuses its deliberately empty legacy prompt, so version skew can
        // never turn this into a text-only report.
        let reportScreenshot: RemoteClaimedReportScreenshot?
        if let screenshot = creation.reportOpening?.screenshot {
            guard let deviceID = RemoteInboundPolicy.normalizedDeviceID(
                request.header(RemoteRouter.deviceHeader)
            ), let jpegData = RemoteReportScreenshotPolicy.jpegData(from: screenshot) else {
                respond(.respond(RemoteRouter.error(
                    400,
                    "Bad Request",
                    code: .invalidReportOpening
                )))
                return
            }
            guard let claimed = attachmentUploads.stageAndClaimReportScreenshot(
                jpegData,
                deviceID: deviceID
            ) else {
                respond(.respond(RemoteRouter.error(
                    503,
                    "Mac Not Ready",
                    code: .persistenceUnavailable
                )))
                return
            }
            reportScreenshot = claimed
        } else {
            reportScreenshot = nil
        }

        // A new-session composer has no host-minted session id yet, so it uploads against the
        // phone's draft UUID. Creation is the one operation allowed to exchange that temporary
        // scope for attachment custody. Claim every id before crossing to the main actor: two
        // create requests racing with the same draft must not both see the files as available,
        // and an invalid set must refuse the whole opening rather than launch with text alone.
        let openingAttachmentPaths: [String]
        if openingAttachmentIDs.isEmpty {
            guard creation.openingAttachmentScopeID == nil else {
                if let uploadID = reportScreenshot?.uploadID {
                    attachmentUploads.discardClaimed(ids: [uploadID])
                }
                respond(.respond(RemoteRouter.error(
                    400,
                    "Invalid Opening Attachments",
                    code: .invalidOpeningAttachments
                )))
                return
            }
            openingAttachmentPaths = []
        } else {
            let totalOpeningAttachmentCount = openingAttachmentIDs.count
                + (reportScreenshot == nil ? 0 : 1)
            guard totalOpeningAttachmentCount
                <= RemoteAttachmentUploadDefaults.maximumStagedUploadsPerSession,
                openingAttachmentIDs.allSatisfy(RemoteInboundPolicy.acceptsAttachmentID),
                let rawScopeID = creation.openingAttachmentScopeID,
                let scopeID = SessionID(uuidString: rawScopeID),
                let deviceID = RemoteInboundPolicy.normalizedDeviceID(
                    request.header(RemoteRouter.deviceHeader)
                ), let claimed = attachmentUploads.claim(
                    ids: openingAttachmentIDs,
                    sessionID: scopeID.uuidString,
                    deviceID: deviceID
                )
            else {
                if let uploadID = reportScreenshot?.uploadID {
                    attachmentUploads.discardClaimed(ids: [uploadID])
                }
                respond(.respond(RemoteRouter.error(
                    400,
                    "Invalid Opening Attachments",
                    code: .invalidOpeningAttachments
                )))
                return
            }
            openingAttachmentPaths = claimed.map(\.path)
        }

        DispatchQueue.main.async {
            var acceptedOpeningAttachments = false
            defer {
                if let uploadID = reportScreenshot?.uploadID {
                    self.queue.async {
                        self.attachmentUploads.discardClaimed(ids: [uploadID])
                    }
                }
                self.resolveClaim(
                    openingAttachmentIDs,
                    accepted: acceptedOpeningAttachments
                )
            }
            guard self.authorizer?.isCurrent(authorization) == true else {
                respond(.respond(RemoteRouter.error(403, "Forbidden")))
                return
            }
            // A refused choice answers the phone and used to leave nothing here, so a report
            // saying "my chat would not start" could not be matched to what this Mac declined.
            // The choices are what the refusal is about; the prompt stays out of the journal.
            let refuse: (Int, String, RemoteRESTErrorCode) -> Void = { status, reason, code in
                self.services.eventLog.recordRemoteEvent("Remote session refused", [
                    .share: authorization.shareID,
                    .reason: code.rawValue,
                    .agent: creation.agentKind,
                    .model: creation.model ?? RemoteLaunchJournalValue.inherited,
                ])
                respond(.respond(RemoteRouter.error(status, reason, code: code)))
            }
            guard let projectID = ProjectID(uuidString: creation.projectID),
                  self.services.sessionQueries.project(withID: projectID) != nil,
                  let kind = AgentKind(rawValue: creation.agentKind)
            else {
                refuse(422, "Unknown Launch Choice", .unknownLaunchChoice)
                return
            }

            let accountHandle = AccountHandle(storedName: creation.accountHandle)
            let discoveredAccounts = AgentAccountDiscovery.accounts(for: kind)
            let account: AgentAccount?
            if accountHandle.isStandard {
                account = discoveredAccounts.first(where: \.isDefault)
            } else {
                guard let selected = discoveredAccounts.first(where: {
                    $0.handle == accountHandle
                }) else {
                    refuse(422, "Unknown Account", .unknownAccount)
                    return
                }
                account = selected
            }
            let modelOptions = AgentModels.options(for: kind, account: account)
            if let model = creation.model,
               !modelOptions.contains(where: { $0.identifier == model })
            {
                refuse(422, "Unknown Model", .unknownModel)
                return
            }
            if let effort = creation.reasoningEffort {
                guard AgentModels.supports(
                    reasoningEffort: effort,
                    kind: kind,
                    model: creation.model,
                    account: account,
                    options: modelOptions
                ) else {
                    refuse(422, "Unknown Reasoning Effort", .unknownReasoningEffort)
                    return
                }
            }
            let permissionMode = creation.permissionMode.flatMap(AgentPermissionMode.init(rawValue:))
            guard creation.permissionMode == nil
                || (permissionMode != nil && kind.supportsPermissionModes)
            else {
                refuse(422, "Unknown Permission Mode", .unknownPermissionMode)
                return
            }
            if creation.fastMode != nil {
                guard AgentModels.supportsFastMode(
                    kind: kind,
                    model: creation.model,
                    account: account
                ) else {
                    refuse(422, "Unsupported Speed", .unsupportedSpeed)
                    return
                }
            }
            let usesNativeUI = creation.surface == .conversation
            guard !usesNativeUI || kind.supportsNativeUI else {
                refuse(422, "Unsupported Surface", .unsupportedSurface)
                return
            }
            // Absent is a chat, the only thing older phones could ask for. The lossless wire
            // vocabulary carries a future word this far so validation can refuse it rather
            // than treating a semantically valid request as malformed JSON. It is never
            // guessed as chat: a phone that asked for a manager and got a chat would not find
            // out until the agent failed to reach its siblings.
            guard let role = creation.role.map({ SessionRole(rawValue: $0.rawValue) }) ?? .chat else {
                refuse(422, "Unknown Role", .unknownRole)
                return
            }

            // An isolated workspace is checked the same way the composer's checkbox is gated,
            // rather than being discovered as a failed provision after the session record
            // exists: the checkout has to be able to host a worktree, and the agent has to be
            // able to hand it back. Publication is refused outright — opening a change request
            // is a decision made while looking at the repository, not one a phone may post.
            let managedWorkspacePlan: ManagedWorkspacePlan?
            if let requested = creation.managedWorkspace {
                guard requested.delivery.isKnown,
                      let delivery = ManagedWorkspaceDelivery(rawValue: requested.delivery.rawValue),
                      requested.publication == nil,
                      let project = self.services.sessionQueries.project(withID: projectID),
                      ManagedGitWorkspace.canProvision(from: project),
                      ManagedWorkspaceEligibility.supportsFinishHandshake(
                          kind: kind,
                          usesNativeUI: usesNativeUI
                      )
                else {
                    refuse(422, "Unsupported Workspace", .unsupportedWorkspace)
                    return
                }
                managedWorkspacePlan = ManagedWorkspacePlan(delivery: delivery)
            } else {
                managedWorkspacePlan = nil
            }

            let launch = RemoteSessionLaunch(
                projectID: projectID,
                kind: kind,
                accountHandle: accountHandle,
                model: creation.model,
                reasoningEffort: creation.reasoningEffort,
                fastMode: creation.fastMode,
                permissionMode: permissionMode,
                usesNativeUI: usesNativeUI,
                managedWorkspacePlan: managedWorkspacePlan,
                role: role,
                openingAttachmentPaths: (reportScreenshot.map { [$0.url.path] } ?? [])
                    + openingAttachmentPaths,
                prompt: prompt
            )
            guard let sessionID = self.sessionCommands?.startRemoteSession(launch) else {
                respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
                return
            }
            acceptedOpeningAttachments = true

            self.services.mirrors.noteSessionStarting(sessionID)
            let response: RemoteCreateSessionResponseDTO
            if creation.compactResponse == true {
                guard let session = self.services.mirrors.sessionSummary(
                    for: sessionID,
                    authorization: authorization
                ) else {
                    respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
                    return
                }
                response = RemoteCreateSessionResponseDTO(
                    sessionID: sessionID.uuidString,
                    session: session,
                    startup: .starting
                )
            } else {
                // Compatibility for installed clients whose response decoder still requires the
                // complete catalogue. Current clients explicitly ask for the compact row above.
                response = RemoteCreateSessionResponseDTO(
                    sessionID: sessionID.uuidString,
                    me: self.services.mirrors.meResponse(for: authorization)
                )
            }
            respond(.respond(RemoteRouter.json(response, status: 201, reason: "Created")))
        }
    }

    private func handleNotificationRegistration(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard let deviceID = RemoteInboundPolicy.normalizedDeviceID(
            request.header(RemoteRouter.deviceHeader)
        ), let registration = try? JSONDecoder().decode(
            RemoteNotificationRegistrationDTO.self,
            from: request.body
        ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            let registrationResult = self.services.notifications.register(
                registration,
                deviceID: deviceID,
                authorization: authorization
            )
            switch registrationResult {
            case .invalid:
                respond(.respond(RemoteRouter.error(
                    422,
                    "Invalid Device Token",
                    code: .invalidDeviceToken
                )))
            case .persistenceUnavailable:
                respond(.respond(RemoteRouter.error(
                    503,
                    "Persistence Unavailable",
                    code: .persistenceUnavailable
                )))
            case let .registered(result):
                self.services.eventLog.recordRemoteEvent("Remote notifications registered", [
                    .share: authorization.shareID,
                    .device: deviceID,
                    .delivery: result.delivery.rawValue,
                ])
                MacRemoteDiagnostics.record(.notificationRegistrationReceived, fields: [
                    .peer: MacRemoteDiagnostics.pseudonym(deviceID, prefix: "device"),
                    .transport: result.delivery.rawValue,
                    .capability: authorization.capability.rawValue,
                    .enabledKindCount: String(registration.enabledKinds.count),
                ])
                respond(.respond(RemoteRouter.json(result)))
            }
        }
    }

    /// Accepts only the content-free diagnostic vocabulary, and only from an interactive owner
    /// device that explicitly enabled sharing. Raw client logs have no route into the Mac.
    private func handleDiagnosticUpload(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canManageHost else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard request.body.count <= RemoteDiagnosticUploadPolicy.maximumUploadBytes,
              let deviceID = RemoteInboundPolicy.normalizedDeviceID(
                  request.header(RemoteRouter.deviceHeader)
              ),
              let upload = try? JSONDecoder().decode(
                  RemoteDiagnosticUploadRequestDTO.self,
                  from: request.body
              ),
              let expectedSource = Self.diagnosticSource(
                  forClientHeader: request.header(RemoteRouter.clientHeader)
              ),
              upload.source == expectedSource,
              RemoteDiagnosticUploadPolicy.accepts(upload),
              receiveClientDiagnostics(upload.records, upload.source, deviceID)
        else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        let peer = MacRemoteDiagnostics.pseudonym(deviceID, prefix: "device")
        services.eventLog.recordRemoteEvent("Remote diagnostics received", [
            .source: upload.source.rawValue,
            .records: String(upload.records.count),
            .peer: peer,
        ])
        respond(.respond(RemoteRouter.json(
            RemoteDiagnosticUploadResponseDTO(acceptedRecords: upload.records.count)
        )))
    }

    private func handleMobileDiagnosticsCaptureUpload(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canManageHost,
              request.header(RemoteRouter.clientHeader)?.lowercased() == RemoteClientKind.iOS.rawValue,
              request.body.count <= MobileDiagnosticsCaptureStore.maximumEncodedCaptureBytes,
              let deviceID = RemoteInboundPolicy.normalizedDeviceID(
                  request.header(RemoteRouter.deviceHeader)
              ),
              let upload = try? JSONDecoder().decode(
                  RemoteMobileDiagnosticsCaptureUploadRequestDTO.self,
                  from: request.body
              ),
              upload.capture.requestID == request.header(RemoteRouter.requestIDHeader)
        else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }

        do {
            let stored = try services.mobileDiagnosticsCaptures.accept(
                upload.capture,
                from: deviceID,
                deviceName: nil
            )
            services.eventLog.recordRemoteEvent("iOS local diagnostics cached", [
                .device: MacRemoteDiagnostics.pseudonym(deviceID, prefix: "device"),
                .records: String(upload.capture.diagnostics.count),
                .screenshot: upload.capture.screenshotJPEGBase64 == nil ? "none" : "included",
            ])
            respond(.respond(RemoteRouter.json(
                RemoteMobileDiagnosticsCaptureUploadResponseDTO(
                    captureID: stored.capture.captureID,
                    storedAt: stored.storedAt
                )
            )))
        } catch MobileDiagnosticsCaptureStore.StoreError.disabled {
            respond(.respond(RemoteRouter.error(
                403,
                "Local Diagnostics Disabled",
                code: .localDiagnosticsDisabled
            )))
        } catch MobileDiagnosticsCaptureStore.StoreError.unsolicited {
            respond(.respond(RemoteRouter.error(
                409,
                "Capture Not Requested",
                code: .captureNotRequested
            )))
        } catch {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
        }
    }

    private func handleMobileDiagnosticsSignal(
        _ connection: RemoteConnection,
        routeKind: String?,
        screenshotPolicy: RemoteMobileDiagnosticsCaptureRequestDTO.ScreenshotPolicy,
        automatic: Bool
    ) {
        guard let (deviceID, deviceName) = mobileDiagnosticsPeer(
            connection,
            routeKind: routeKind
        ) else { return }
        services.mobileDiagnosticsCaptures.register(
            connection,
            deviceID: deviceID,
            deviceName: deviceName
        )
        _ = services.mobileDiagnosticsCaptures.requestCapture(
            deviceID: deviceID,
            screenshotPolicy: screenshotPolicy,
            automatic: automatic
        )
    }

    private func handleMobileDiagnosticsDisabled(
        _ connection: RemoteConnection,
        routeKind: String?
    ) {
        guard mobileDiagnosticsPeer(connection, routeKind: routeKind) != nil else { return }
        services.mobileDiagnosticsCaptures.unregister(connection)
    }

    private func mobileDiagnosticsPeer(
        _ connection: RemoteConnection,
        routeKind rawRouteKind: String?
    ) -> (deviceID: String, deviceName: String?)? {
        guard let rawRouteKind,
              RemoteHostEndpointKind(rawValue: rawRouteKind) == .lan,
              connection.routedSessionID == RemoteRouter.themeEventsRouteID,
              let peer = connection.authenticatedPeer,
              peer.authorization.canManageHost,
              authorizer?.isCurrent(peer.authorization) == true,
              let deviceID = peer.deviceID
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return nil
        }
        return (deviceID, peer.deviceName)
    }

    private static func diagnosticSource(
        forClientHeader header: String?
    ) -> RemoteDiagnosticSource? {
        switch header?.lowercased() {
        case RemoteClientKind.iOS.rawValue: return .iOSClient
        case RemoteClientKind.web.rawValue: return .browserClient
        default: return nil
        }
    }

    /// Exchanges a short-lived, single-use invitation for a device-bound membership bearer.
    /// Calling the same endpoint with an already accepted or owner bearer is idempotent, which
    /// lets clients use one connection flow for pairing and invitations.
    private func handleAcceptInvitation(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let token = RemoteRouter.bearerToken(from: request),
              RemoteInboundPolicy.acceptsBearerToken(token),
              let deviceID = RemoteInboundPolicy.normalizedDeviceID(
                  request.header(RemoteRouter.deviceHeader)
              ),
              let acceptance = try? JSONDecoder().decode(
                  RemoteAcceptInvitationRequestDTO.self,
                  from: request.body
              ),
              let displayName = RemoteInboundPolicy.normalizedMemberName(
                  acceptance.displayName
              )
        else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        let version = request.header(RemoteRouter.protocolHeader).flatMap { Int($0) }
        let minimum = request.header(RemoteRouter.protocolMinimumHeader).flatMap { Int($0) }
        if let update = protocolUpdateNeeded(version: version, minimum: minimum) {
            respond(.respond(RemoteRouter.json(
                upgradeRequired(update),
                status: 426,
                reason: "Upgrade Required"
            )))
            return
        }

        if let existing = authorizer?.authorization(forToken: token),
           existing.isBound(to: deviceID)
        {
            DispatchQueue.main.async {
                respond(.respond(RemoteRouter.json(
                    RemoteAcceptInvitationResponseDTO(
                        accessToken: token,
                        me: self.services.mirrors.meResponse(for: existing)
                    )
                )))
            }
            return
        }

        guard !authLimiter.shouldReject(device: deviceID) else {
            respond(.respond(RemoteRouter.error(429, "Too Many Requests")))
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let redemption = self.invitationRedeemer?.redeemInvitation(
                      token: token,
                      deviceID: deviceID,
                      displayName: displayName,
                      // Browser owner access remains tab-scoped by design. Native clients keep
                      // their exchanged bearer in Keychain and therefore receive a Mac-side
                      // durable record as well.
                      persistsOwnerDevice:
                      request.header(RemoteRouter.clientHeader)?.lowercased()
                          == RemoteClientKind.iOS.rawValue
                  )
            else {
                self?.queue.async { [weak self] in
                    self?.recordFailedAuth(reason: "invalid invitation", device: deviceID)
                    respond(.respond(RemoteRouter.error(
                        401,
                        "Invalid Invitation",
                        code: .invalidInvitation
                    )))
                }
                return
            }
            respond(.respond(RemoteRouter.json(
                RemoteAcceptInvitationResponseDTO(
                    accessToken: redemption.accessToken,
                    me: self.services.mirrors.meResponse(
                        for: redemption.authorization
                    )
                ),
                status: 201,
                reason: "Created"
            )))
        }
    }

    private func handleHostedDeviceCredential(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canManageHost || authorization.member != nil else {
            respond(.respond(RemoteRouter.error(
                403,
                "Owner access required",
                code: .ownerAccessRequired
            )))
            return
        }
        guard let deviceID = RemoteInboundPolicy.normalizedDeviceID(
            request.header(RemoteRouter.deviceHeader)
        ) else {
            respond(.respond(RemoteRouter.error(400, "Invalid device", code: .invalidDevice)))
            return
        }
        Task { @MainActor in
            do {
                guard let hostCommands = self.hostCommands else {
                    respond(.respond(RemoteRouter.error(
                        503,
                        "Hosted service unavailable",
                        code: .hostedServiceUnavailable
                    )))
                    return
                }
                let credential = try await hostCommands.issueHostedDeviceCredential(
                    accessToken: RemoteRouter.bearerToken(from: request) ?? "",
                    deviceID: deviceID
                )
                respond(.respond(RemoteRouter.json(
                    credential,
                    status: 201,
                    reason: "Created",
                    maximumBytes: 16 * 1024
                )))
                if authorization.canManageHost { hostCommands.completeHostedPairingBootstrap() }
            } catch {
                ThreadingLogger.remote.error(
                    "Hosted device credential issue failed code=service"
                )
                respond(.respond(RemoteRouter.error(
                    503,
                    "Hosted service unavailable",
                    code: .hostedServiceUnavailable
                )))
            }
        }
    }

    private func handleAppTheme(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard canManageThemes(authorization) else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let choice = try? JSONDecoder().decode(
            RemoteSetAppThemeRequestDTO.self,
            from: request.body
        ), RemoteInboundPolicy.acceptsThemeID(choice.themeID) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            let appliedThemeID: AppThemeID
            switch self.services.settings.applyAppTheme(id: AppThemeID(choice.themeID)) {
            case let .applied(themeID):
                appliedThemeID = themeID
            case .unknownTheme:
                respond(.respond(RemoteRouter.error(422, "Unknown Theme", code: .unknownTheme)))
                return
            }
            self.services.eventLog.recordRemoteEvent("App theme changed remotely", [
                .theme: appliedThemeID.rawValue,
                .device: request.header(RemoteRouter.deviceHeader) ?? "unknown",
            ])
            self.respondWithCatalogue(for: authorization, request: request, respond: respond)
        }
    }

    private func handleAppSetting(
        _ request: HTTPRequest,
        identity: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canManageHost else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let mutation = try? JSONDecoder().decode(
            RemoteAppSettingMutationRequest.self,
            from: request.body
        ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            switch self.services.settings.applyAppSetting(
                identity: identity,
                value: mutation.value
            ) {
            case .applied:
                self.services.eventLog.recordRemoteEvent("App setting changed remotely", [
                    .setting: identity,
                    .device: request.header(RemoteRouter.deviceHeader) ?? "unknown",
                ])
                self.respondWithCatalogue(for: authorization, request: request, respond: respond)
            case .unknownSetting:
                respond(.respond(RemoteRouter.error(404, "Unknown Setting", code: .unknownSetting)))
            case .notMutable:
                respond(.respond(RemoteRouter.error(
                    403,
                    "Setting Not Mutable",
                    code: .settingNotMutable
                )))
            case .invalidValue:
                respond(.respond(RemoteRouter.error(
                    422,
                    "Invalid Setting Value",
                    code: .invalidSettingValue
                )))
            }
        }
    }

    private func handleSessionTheme(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard canManageThemes(authorization) else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let sessionID = SessionID(uuidString: rawSessionID),
              authorization.scope.covers(sessionID)
        else {
            respond(.respond(RemoteRouter.error(404, "Not Found")))
            return
        }
        guard let choice = try? JSONDecoder().decode(
            RemoteSetTerminalThemeRequestDTO.self,
            from: request.body
        ), choice.themeID.map(RemoteInboundPolicy.acceptsThemeID) ?? true else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard RemoteSessionAccess.isVisible(
                self.services.sessionQueries.session(withID: sessionID)
            ) else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            let themeID = choice.themeID.map { TerminalThemeID($0) }
            let result = self.services.settings.setSessionTheme(
                id: themeID,
                for: sessionID
            )
            switch result {
            case .applied, .unchanged:
                break
            case .targetNotFound:
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            case .persistenceRefused:
                respond(.respond(self.persistenceRefusalResponse()))
                return
            case .unsupportedValue:
                respond(.respond(RemoteRouter.error(
                    422,
                    "Unsupported Value",
                    code: .unsupportedValue
                )))
                return
            }
            self.services.eventLog.recordRemoteEvent("Session theme changed remotely", [
                .session: sessionID.uuidString,
                .theme: themeID?.rawValue ?? "inherit",
                .device: request.header(RemoteRouter.deviceHeader) ?? "unknown",
            ])
            self.respondWithCatalogue(for: authorization, request: request, respond: respond)
        }
    }

    private func handleRenameSession(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let choice = try? JSONDecoder().decode(
            RemoteRenameSessionRequestDTO.self,
            from: request.body
        ), RemoteInboundPolicy.acceptsSessionTitle(choice.title) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard let sessionID = SessionID(uuidString: rawSessionID),
                  self.services.sessionQueries.session(withID: sessionID) != nil
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            let result = self.services.sessionMutations.renameSession(
                id: sessionID,
                to: choice.title
            )
            switch result {
            case .applied, .unchanged:
                break
            case .targetNotFound:
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            case .persistenceRefused:
                respond(.respond(self.persistenceRefusalResponse()))
                return
            case .unsupportedValue:
                respond(.respond(RemoteRouter.error(
                    422,
                    "Unsupported Value",
                    code: .unsupportedValue
                )))
                return
            }
            self.services.eventLog.recordRemoteEvent("Session renamed remotely", [
                .session: sessionID.uuidString,
                .device: request.header(RemoteRouter.deviceHeader) ?? "unknown",
            ])
            self.respondWithCatalogue(for: authorization, request: request, respond: respond)
        }
    }

    private func handlePinnedSession(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let choice = try? JSONDecoder().decode(
            RemoteSetSessionPinnedRequestDTO.self,
            from: request.body
        ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard let sessionID = SessionID(uuidString: rawSessionID),
                  self.services.sessionQueries.session(withID: sessionID) != nil
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            let result = self.services.sessionMutations.setPinned(
                choice.isPinned,
                for: sessionID
            )
            switch result {
            case .applied, .unchanged:
                break
            case .targetNotFound:
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            case .persistenceRefused:
                respond(.respond(self.persistenceRefusalResponse()))
                return
            case .unsupportedValue:
                respond(.respond(RemoteRouter.error(
                    422,
                    "Unsupported Value",
                    code: .unsupportedValue
                )))
                return
            }
            self.sessionCommands?.refreshAfterRemoteSessionMutation(
                sessionID: sessionID,
                archived: false
            )
            self.respondWithCatalogue(for: authorization, request: request, respond: respond)
        }
    }

    private func handleArchivedSession(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let choice = try? JSONDecoder().decode(
            RemoteSetSessionArchivedRequestDTO.self,
            from: request.body
        ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard let sessionID = SessionID(uuidString: rawSessionID),
                  self.services.sessionQueries.session(withID: sessionID) != nil
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            self.services.archiveSync.setArchived(
                choice.isArchived,
                for: sessionID
            ) { result in
                switch result {
                case .success:
                    self.services.eventLog.recordRemoteEvent(choice.isArchived
                        ? "Session archived remotely"
                        : "Session restored remotely", [
                            .session: sessionID.uuidString,
                            .device: request.header(RemoteRouter.deviceHeader) ?? "unknown",
                        ])
                    self.respondWithCatalogue(for: authorization, request: request, respond: respond)
                case let .failure(failure):
                    if case .persistenceUnavailable = failure {
                        respond(.respond(self.persistenceRefusalResponse()))
                        return
                    }
                    let status: Int
                    if case .alreadyChanging = failure {
                        status = 409
                    } else if case .sessionNotFound = failure {
                        status = 404
                    } else {
                        status = 500
                    }
                    let code: RemoteRESTErrorCode
                    switch failure {
                    case .alreadyChanging:
                        code = .archiveAlreadyChanging
                    case .sessionNotFound:
                        code = .notFound
                    case .accountUnavailable:
                        code = .archiveAccountUnavailable
                    case .persistenceUnavailable:
                        code = .persistenceUnavailable
                    case .commandCouldNotLaunch:
                        code = .archiveCommandUnavailable
                    case .commandRejected:
                        code = .archiveCommandRejected
                    }
                    respond(.respond(RemoteRouter.error(
                        status,
                        failure.localizedDescription,
                        code: code
                    )))
                }
            }
        }
    }

    private func handleSnoozedSession(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let choice = try? JSONDecoder().decode(
            RemoteSetSessionSnoozeRequestDTO.self,
            from: request.body
        ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard let sessionID = SessionID(uuidString: rawSessionID),
                  let session = self.services.sessionQueries.session(withID: sessionID),
                  !session.isArchived
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            if let rawDeadline = choice.snoozedUntil {
                let deadline = Date(timeIntervalSince1970: rawDeadline)
                guard deadline > Date(), deadline < Date().addingTimeInterval(366 * 86400) else {
                    respond(.respond(RemoteRouter.error(
                        422,
                        "Invalid snooze deadline",
                        code: .invalidSnoozeDeadline
                    )))
                    return
                }
                self.services.snoozeCenter.snooze(sessionID, until: deadline)
            } else {
                self.services.snoozeCenter.unsnooze(sessionID)
            }
            self.respondWithCatalogue(for: authorization, request: request, respond: respond)
        }
    }

    private func handleSessionSurface(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let choice = try? JSONDecoder().decode(
            RemoteSetSessionSurfaceRequestDTO.self,
            from: request.body
        ), choice.surface.isKnown else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard let sessionID = SessionID(uuidString: rawSessionID),
                  let session = self.services.sessionQueries.session(withID: sessionID)
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            let usesNativeUI = choice.surface == .conversation
            guard !usesNativeUI || session.kind.supportsNativeUI else {
                respond(.respond(RemoteRouter.error(
                    422,
                    "Unsupported Surface",
                    code: .unsupportedSurface
                )))
                return
            }

            let result = self.services.sessionMutations.setUsesNativeUI(
                usesNativeUI,
                for: sessionID
            )
            switch result {
            case .applied:
                // A live process belongs to the standing surface until its replacement is
                // durable. A database refusal must leave that process and surface untouched.
                self.services.runtimeStatus.discard(
                    sessionID: sessionID,
                    preservingViewport: true
                )
                self.sessionCommands?.refreshAfterRemoteSurfaceMutation(sessionID: sessionID)
            case .unchanged:
                break
            case .targetNotFound:
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            case .unsupportedValue:
                respond(.respond(RemoteRouter.error(
                    422,
                    "Unsupported Surface",
                    code: .unsupportedSurface
                )))
                return
            case .persistenceRefused:
                respond(.respond(self.persistenceRefusalResponse()))
                return
            }
            self.services.eventLog.recordRemoteEvent("Session UI changed remotely", [
                .session: sessionID.uuidString,
                .surface: choice.surface.rawValue,
                .device: request.header(RemoteRouter.deviceHeader) ?? "unknown",
            ])
            self.respondWithCatalogue(for: authorization, request: request, respond: respond)
        }
    }

    private func handleSessionAccount(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let choice = try? JSONDecoder().decode(
            RemoteMoveSessionAccountRequestDTO.self,
            from: request.body
        ), RemoteInboundPolicy.acceptsAccountIdentifier(choice.accountID) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard let sessionID = SessionID(uuidString: rawSessionID),
                  let session = self.services.sessionQueries.session(withID: sessionID)
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            guard session.kind.supportsAccounts else {
                respond(.respond(RemoteRouter.error(
                    422,
                    "Unsupported Runtime",
                    code: .unsupportedRuntime
                )))
                return
            }
            guard let commands = self.sessionCommands else {
                respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
                return
            }

            switch commands.moveRemoteSession(
                sessionID,
                to: AccountHandle(storedName: choice.accountID)
            ) {
            case .success:
                self.services.eventLog.recordRemoteEvent("Session account changed remotely", [
                    .session: sessionID.uuidString,
                    .account: choice.accountID,
                    .device: request.header(RemoteRouter.deviceHeader) ?? "unknown",
                ])
                self.respondWithCatalogue(for: authorization, request: request, respond: respond)
            case .failure(.sessionNotFound):
                respond(.respond(RemoteRouter.error(404, "Not Found")))
            case .failure(.accountNotFound), .failure(.unsupportedRuntime):
                respond(.respond(RemoteRouter.error(
                    422,
                    "Unsupported Account",
                    code: .unsupportedAccount
                )))
            case .failure(.appUnavailable):
                respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
            case let .failure(.moveRefused(refusal)):
                respond(.respond(RemoteRouter.error(
                    409,
                    "Account move refused",
                    code: .accountMoveRefused,
                    detail: refusal.rawValue
                )))
            }
        }
    }

    /// Where this conversation could continue, asked once by the screen that offers the choice.
    ///
    /// An empty list is a complete answer: a source with nothing recorded yet, a runtime that
    /// cannot be a source, and a Mac with no other provider configured all reach it, and in each
    /// the client hides the control rather than offering something that would be refused.
    private func handleSessionContinuationOptions(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) != nil else { return }

        DispatchQueue.main.async {
            guard let sessionID = SessionID(uuidString: rawSessionID),
                  let session = self.services.sessionQueries.session(withID: sessionID),
                  let project = self.services.sessionQueries.project(forSessionID: sessionID)
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            respond(.respond(RemoteRouter.json(
                RemoteContinuationBridge.options(for: session, in: project)
            )))
        }
    }

    /// Continues this conversation on another provider.
    ///
    /// Deliberately a different route from the account move above, because it is a different
    /// operation: the source session and its transcript stay resumable, and the destination is a
    /// new conversation whose first turn reads a frozen snapshot of this one. The phone owns the
    /// confirmation; the Mac owns the capture, the snapshot and the new record.
    private func handleSessionContinuation(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let choice = try? JSONDecoder().decode(
            RemoteContinueSessionRequestDTO.self,
            from: request.body
        ), RemoteInboundPolicy.acceptsLaunchIdentifier(choice.agentID),
            choice.accountID.map(RemoteInboundPolicy.acceptsAccountIdentifier) ?? true else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        let device = request.header(RemoteRouter.deviceHeader) ?? "unknown"
        DispatchQueue.main.async {
            guard let sessionID = SessionID(uuidString: rawSessionID),
                  self.services.sessionQueries.session(withID: sessionID) != nil
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            guard let kind = AgentKind(rawValue: choice.agentID) else {
                respond(.respond(RemoteRouter.error(
                    422,
                    "Unsupported Runtime",
                    code: .unsupportedRuntime
                )))
                return
            }
            // Whether this runtime and login were actually offered is the command's answer, not
            // the transport's: the same resolution admits the Mac's own menu, and a second copy
            // here would be a rule that can drift from the one that runs. The transport checks
            // only what it can see — a token that names no runtime at all.
            let target = RemoteContinuationTarget(
                kind: kind,
                accountHandle: choice.accountID.map { AccountHandle(storedName: $0) }
            )
            guard let commands = self.sessionCommands else {
                respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
                return
            }

            commands.continueRemoteSession(sessionID, with: target) { result in
                switch result {
                case let .success(createdID):
                    self.services.eventLog.recordRemoteEvent("Session continued remotely", [
                        .session: sessionID.uuidString,
                        .agent: choice.agentID,
                        .account: choice.accountID ?? "default",
                        .device: device,
                    ])
                    respond(.respond(RemoteRouter.json(RemoteContinueSessionResponseDTO(
                        sessionID: createdID.uuidString,
                        me: self.services.mirrors.meResponse(for: authorization)
                    ))))
                case .failure(.sessionNotFound):
                    respond(.respond(RemoteRouter.error(404, "Not Found")))
                case .failure(.destinationNotFound):
                    respond(.respond(RemoteRouter.error(
                        422,
                        "Unsupported Account",
                        code: .unsupportedAccount
                    )))
                case .failure(.appUnavailable):
                    respond(.respond(RemoteRouter.error(
                        503,
                        "Mac Not Ready",
                        code: .hostNotReady
                    )))
                case let .failure(.continuationRefused(refusal)):
                    respond(.respond(RemoteRouter.error(
                        409,
                        "Continuation refused",
                        code: .continuationRefused,
                        detail: refusal?.rawValue
                    )))
                }
            }
        }
    }

    private func handleSessionLimitRecovery(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let choice = try? JSONDecoder().decode(
            RemoteSetSessionLimitRecoveryRequestDTO.self,
            from: request.body
        ), choice.policy.isKnown else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard let sessionID = SessionID(uuidString: rawSessionID),
                  let session = self.services.sessionQueries.session(withID: sessionID)
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            guard let policy = self.limitRecoveryPolicy(
                choice.policy,
                for: session
            ) else {
                respond(.respond(RemoteRouter.error(
                    422,
                    "Unsupported Recovery",
                    code: .unsupportedRecovery
                )))
                return
            }
            let inherited = LimitRecoveryResolution.inherited(
                beyond: .session,
                project: self.services.sessionQueries.project(forSessionID: sessionID)?
                    .limitRecoveryPolicy,
                app: LimitRecoverySettings.policy
            )
            let result = self.services.sessionMutations.setLimitRecoveryPolicy(
                policy == inherited ? nil : policy,
                forSessionID: sessionID
            )
            switch result {
            case .applied, .unchanged:
                self.services.eventLog.recordRemoteEvent(
                    "Session limit recovery changed remotely",
                    [
                        .session: sessionID.uuidString,
                        .policy: choice.policy.action,
                        .device: request.header(RemoteRouter.deviceHeader) ?? "unknown",
                    ]
                )
                self.respondWithCatalogue(for: authorization, request: request, respond: respond)
            case .targetNotFound:
                respond(.respond(RemoteRouter.error(404, "Not Found")))
            case .unsupportedValue:
                respond(.respond(RemoteRouter.error(
                    422,
                    "Unsupported Recovery",
                    code: .unsupportedRecovery
                )))
            case .persistenceRefused:
                respond(.respond(self.persistenceRefusalResponse()))
            }
        }
    }

    /// HTTP status is only the broad transport class. Preserve the ProjectStore cause as the
    /// stable REST code so a client can distinguish a full disk from an arbitrary failed write.
    @MainActor
    private func persistenceRefusalResponse() -> HTTPResponse {
        if services.sessionMutations.persistenceBlockReason == .storageExhausted {
            return RemoteRouter.error(
                503,
                "Storage Exhausted",
                code: .storageExhausted
            )
        }
        return RemoteRouter.error(
            503,
            "Persistence Unavailable",
            code: .persistenceUnavailable
        )
    }

    @MainActor
    private func limitRecoveryPolicy(
        _ remote: RemoteLimitRecoveryPolicyDTO,
        for session: AgentSession
    ) -> LimitRecoveryPolicy? {
        switch remote {
        case .flagOnly:
            return .flagOnly
        case .waitForReset:
            return .waitForReset
        case .resumeOnBestAccount:
            return session.kind.supportsAccounts ? .resumeOnBestAccount : nil
        case let .resumeVia(rawAccountID):
            guard RemoteInboundPolicy.acceptsAccountIdentifier(rawAccountID) else { return nil }
            let handle = AccountHandle(storedName: rawAccountID)
            guard SessionMigration.destinations(for: session).contains(where: {
                $0.handle == handle
            }) else { return nil }
            return .resumeVia(AccountID(provider: session.kind, handle: handle))
        case .unknown:
            return nil
        }
    }

    private func handleCreateShare(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ), let sessionID = SessionID(uuidString: rawSessionID) else { return }
        guard let choice = try? JSONDecoder().decode(
            RemoteCreateShareRequestDTO.self,
            from: request.body
        ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }
        let capability = choice.capability

        Task { @MainActor in
            guard let hostCommands = self.hostCommands else {
                respond(.respond(RemoteRouter.error(
                    503,
                    "Sharing Not Available",
                    code: .sharingNotAvailable
                )))
                return
            }
            switch await hostCommands.prepareSessionShare(
                for: sessionID,
                capability: capability,
                canApprovePermissions: choice.canApprovePermissions
            ) {
            case let .success(created):
                respond(.respond(RemoteRouter.json(RemoteCreateShareResponseDTO(
                    url: created.url.absoluteString,
                    capability: RemoteAdvertisedCapability(capability),
                    canApprovePermissions: created.canApprovePermissions,
                    expiresAt: created.expiresAt.timeIntervalSince1970,
                    me: self.services.mirrors.meResponse(for: authorization)
                ))))
            case .failure:
                // An invitation points at a door of this Mac's own, so the only way to fail is
                // to have none bound. That is a state the owner fixes on the Mac, which is why
                // it is reported rather than retried here.
                respond(.respond(RemoteRouter.error(
                    503,
                    "Sharing Not Available",
                    code: .sharingNotAvailable
                )))
            }
        }
    }

    private func handleRevokeShares(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ), let sessionID = SessionID(uuidString: rawSessionID) else { return }
        guard (try? JSONDecoder().decode(
            RemoteRevokeSharesRequestDTO.self,
            from: request.body
        )) != nil else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard let hostCommands = self.hostCommands else {
                respond(.respond(RemoteRouter.error(503, "Mac Not Ready", code: .hostNotReady)))
                return
            }
            hostCommands.revokeSessionShares(sessionID)
            self.respondWithCatalogue(for: authorization, request: request, respond: respond)
        }
    }

    private func handleCreateTerminalShare(
        _ request: HTTPRequest,
        terminalID rawTerminalID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canManageHost else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let terminalID = TerminalID(uuidString: rawTerminalID) else {
            respond(.respond(RemoteRouter.error(404, "Not Found")))
            return
        }
        guard let choice = try? JSONDecoder().decode(
            RemoteCreateShareRequestDTO.self,
            from: request.body
        ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }
        let capability = choice.capability
        DispatchQueue.main.async {
            guard self.services.sessionQueries.terminal(withID: terminalID) != nil,
                  let hostCommands = self.hostCommands
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            switch hostCommands.createTerminalShare(for: terminalID, capability: capability) {
            case let .success(created):
                respond(.respond(RemoteRouter.json(RemoteCreateShareResponseDTO(
                    url: created.url.absoluteString,
                    capability: RemoteAdvertisedCapability(capability),
                    canApprovePermissions: false,
                    expiresAt: created.expiresAt.timeIntervalSince1970,
                    me: self.services.mirrors.meResponse(for: authorization)
                ))))
            case .failure:
                respond(.respond(RemoteRouter.error(
                    503,
                    "Sharing Not Available",
                    code: .sharingNotAvailable
                )))
            }
        }
    }

    private func handleRevokeTerminalShares(
        _ request: HTTPRequest,
        terminalID rawTerminalID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.canManageHost else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let terminalID = TerminalID(uuidString: rawTerminalID) else {
            respond(.respond(RemoteRouter.error(404, "Not Found")))
            return
        }
        guard (try? JSONDecoder().decode(
            RemoteRevokeSharesRequestDTO.self,
            from: request.body
        )) != nil else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }
        DispatchQueue.main.async {
            guard self.services.sessionQueries.terminal(withID: terminalID) != nil,
                  let hostCommands = self.hostCommands
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            hostCommands.revokeTerminalShares(terminalID)
            self.respondWithCatalogue(for: authorization, request: request, respond: respond)
        }
    }

    private func handleGitReview(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        mode: RemoteGitReviewMode,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let sessionID = authorizeOwnerSessionRead(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }

        DispatchQueue.main.async {
            guard RemoteSessionAccess.isVisible(
                self.services.sessionQueries.session(withID: sessionID)
            ) else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            RemoteGitReviewBridge.review(sessionID: sessionID, mode: mode) { snapshot in
                respond(.respond(RemoteRouter.json(snapshot)))
            }
        }
    }

    private func handleRepositoryFiles(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let sessionID = authorizeOwnerSessionRead(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }

        DispatchQueue.main.async {
            RemoteGitReviewBridge.repositoryFiles(sessionID: sessionID) { result in
                switch result {
                case let .success(files):
                    respond(.respond(RemoteRouter.json(files)))
                case .failure:
                    respond(.respond(RemoteRouter.error(404, "Not Found")))
                }
            }
        }
    }

    private func handleRepositoryFile(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let sessionID = authorizeOwnerSessionRead(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let path = RemoteRouter.queryValue(named: "path", in: request.path),
              RemoteInboundPolicy.acceptsRepositoryPath(path)
        else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            RemoteGitReviewBridge.repositoryFile(
                sessionID: sessionID,
                path: path
            ) { result in
                switch result {
                case let .success(file):
                    respond(.respond(RemoteRouter.json(file)))
                case .failure:
                    respond(.respond(RemoteRouter.error(404, "Not Found")))
                }
            }
        }
    }

    /// Takes one chunk of a file a composing client wants to send with its next prompt.
    ///
    /// Every refusal answers 400 with no detail. The alternative — saying which bound was hit —
    /// would let something that has not proved it owns any staged state enumerate the host's:
    /// whether an id exists, whose device it belongs to, how far a transfer got.
    ///
    /// The bytes are staged, not attached. Nothing reaches the session, the attachments pane or
    /// the agent until a prompt names this upload's id, which is what keeps an interrupted
    /// attach from leaving a half-sent picture in somebody's conversation.
    private func handleAttachmentUpload(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }
        guard authorization.principal == .ownerDevice,
              authorization.scope == .allSessions,
              authorization.capability == .interact
        else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return
        }
        guard let sessionID = SessionID(uuidString: rawSessionID),
              authorization.scope.covers(sessionID)
        else {
            respond(.respond(RemoteRouter.error(404, "Not Found")))
            return
        }
        guard let deviceID = RemoteInboundPolicy.normalizedDeviceID(
            request.header(RemoteRouter.deviceHeader)
        ), let upload = try? JSONDecoder().decode(
            RemoteAttachmentUploadRequestDTO.self,
            from: request.body
        ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        guard let result = attachmentUploads.accept(
            upload,
            sessionID: sessionID.uuidString,
            deviceID: deviceID
        ) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        respond(.respond(RemoteRouter.json(result)))
    }

    private func handleAttachments(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let sessionID = authorizeOwnerSessionRead(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }

        DispatchQueue.main.async {
            guard RemoteSessionAccess.isVisible(
                self.services.sessionQueries.session(withID: sessionID)
            ) else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }

            let attachments = self.services.attachments.attachments(for: sessionID).compactMap {
                attachment -> RemoteAttachmentDTO? in
                guard let values = try? attachment.url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                ), let size = values.fileSize,
                size >= 0,
                attachment.kind == .video || size <= RemoteAccessDefaults.maximumAttachmentBytes else {
                    return nil
                }
                return RemoteAttachmentDTO(
                    path: attachment.relativePath,
                    name: attachment.name,
                    kind: RemoteAttachmentKind(rawValue: attachment.kind.rawValue),
                    byteCount: Int64(size),
                    modifiedAt: values.contentModificationDate,
                    referencedAt: attachment.referencedAt,
                    origin: RemoteAttachmentOrigin(rawValue: attachment.origin.rawValue),
                    id: attachment.id
                )
            }
            respond(.respond(RemoteRouter.json(RemoteAttachmentsDTO(
                attachments: attachments
            ))))
        }
    }

    private func handleWorkspace(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let sessionID = authorizeOwnerSessionRead(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }

        DispatchQueue.main.async {
            guard let workspace = RemoteWorkspaceBridge.workspace(
                for: sessionID,
                latestActivityID: self.services.mirrors
                    .latestWorkspaceActivityID(for: sessionID)
            ) else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            respond(.respond(RemoteRouter.json(workspace)))
        }
    }

    private func handleBrowserPreview(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let sessionID = authorizeOwnerSessionRead(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let rawTabID = RemoteRouter.queryValue(named: "tab", in: request.path),
              let tabID = UUID(uuidString: rawTabID)
        else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        Task { @MainActor in
            guard let data = await RemoteWorkspaceBridge.browserPreview(
                for: sessionID,
                tabID: tabID
            ) else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            respond(.respond(RemoteRouter.data(data, contentType: "image/png")))
        }
    }

    private func handleAttachment(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let sessionID = authorizeOwnerSessionRead(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let attachmentID = RemoteRouter.queryValue(named: "id", in: request.path),
              RemoteInboundPolicy.acceptsAttachmentID(attachmentID)
        else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard RemoteSessionAccess.isVisible(
                self.services.sessionQueries.session(withID: sessionID)
            ), let attachment = self.services.attachments.attachment(
                for: sessionID,
                id: attachmentID
            ), let values = try? attachment.url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize,
            size >= 0 else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }

            let url = attachment.url
            let contentType = Self.attachmentContentType(for: url)
            if attachment.kind == .video, let rawRange = request.header("Range") {
                guard let range = RemoteAttachmentByteRange.resolve(
                    rawRange,
                    fileSize: Int64(size)
                ) else {
                    respond(.respond(RemoteRouter.rangeNotSatisfiable(totalBytes: Int64(size))))
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let data = RemoteAttachmentByteRange.read(url, range: range) else {
                        respond(.respond(RemoteRouter.error(404, "Not Found")))
                        return
                    }
                    respond(.respond(RemoteRouter.byteRange(
                        data,
                        contentType: contentType,
                        range: range,
                        totalBytes: Int64(size)
                    )))
                }
                return
            }
            guard size <= RemoteAccessDefaults.maximumAttachmentBytes else {
                // A new phone always asks for ranges. Keeping the old whole-file answer bounded
                // prevents an older client from turning a newly listed recording into one giant
                // allocation if it reaches this route without the advertised feature.
                respond(.respond(RemoteRouter.rangeNotSatisfiable(totalBytes: Int64(size))))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? BoundedFileReader.read(
                    url,
                    maximumBytes: RemoteAccessDefaults.maximumAttachmentBytes
                ) else {
                    respond(.respond(RemoteRouter.error(404, "Not Found")))
                    return
                }
                respond(.respond(RemoteRouter.data(data, contentType: contentType)))
            }
        }
    }

    /// A small raster of one attachment for the phone's gallery ledger.
    ///
    /// Gated like the attachment route it shrinks — the same owner read, the same id policy, the
    /// same visibility and size checks — and bounded on its own account: the decode runs under
    /// `BoundedImageDecodePolicy.thumbnail`, so a decompression bomb is refused before it is
    /// rasterised, and the answer is never wider than `RemoteAttachmentThumbnail` allows whatever
    /// the request said. An image is thumbnailed by ImageIO; a PDF by its first page; every
    /// other kind is a 404, which the phone draws as the kind's glyph.
    private func handleAttachmentThumbnail(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let sessionID = authorizeOwnerSessionRead(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let attachmentID = RemoteRouter.queryValue(named: "id", in: request.path),
              RemoteInboundPolicy.acceptsAttachmentID(attachmentID)
        else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard RemoteSessionAccess.isVisible(
                self.services.sessionQueries.session(withID: sessionID)
            ), let attachment = self.services.attachments.attachment(
                for: sessionID,
                id: attachmentID
            ), let values = try? attachment.url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize,
            size >= 0,
            attachment.kind == .video || size <= RemoteAccessDefaults.maximumAttachmentBytes else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }

            let url = attachment.url
            let kind = attachment.kind
            Task.detached(priority: .userInitiated) {
                guard let data = await RemoteAttachmentThumbnailRenderer.jpeg(at: url, kind: kind) else {
                    respond(.respond(RemoteRouter.error(404, "Not Found")))
                    return
                }
                // A thumbnail is bounded to a few tens of kilobytes by its pixel ceiling, far
                // under the ordinary send high-water mark, so the connection stays open for the
                // next cell's request instead of being cut after every picture — the churn a
                // phone reported as its network connection lost, twenty-seven times in a day.
                respond(.respond(RemoteRouter.data(
                    data,
                    contentType: "image/jpeg",
                    closesConnection: false
                )))
            }
        }
    }

    /// Serves the extension SDK's semantic panel value to the paired owner. The phone receives
    /// neither an AppKit archive nor a presentation-only projection: it hosts this same tree with
    /// native SwiftUI controls.
    private func handleExtensionPanel(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let sessionID = authorizeOwnerSessionRead(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let reference = extensionPanelReference(in: request) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard RemoteSessionAccess.isVisible(
                self.services.sessionQueries.session(withID: sessionID)
            ), let item = self.services.extensions.registeredPanel(
                extensionIdentifier: reference.extensionIdentifier,
                panelID: reference.panelID
            ) else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            respond(.respond(RemoteRouter.json(RemoteExtensionPanelDTO(
                extensionIdentifier: item.extensionIdentifier,
                extensionName: item.extensionName,
                processGeneration: item.processGeneration,
                panel: item.panel
            ))))
        }
    }

    /// Relays one native control event to the same running extension generation that owns the
    /// Mac panel. Mutation replay above this handler makes a lost HTTP response safe to retry.
    private func handleExtensionPanelAction(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard authorizeSessionManagement(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) != nil else { return }
        guard let sessionID = SessionID(uuidString: rawSessionID),
              let reference = extensionPanelReference(in: request),
              let action = try? JSONDecoder().decode(
                  RemoteExtensionPanelActionRequestDTO.self,
                  from: request.body
              ), RemoteInboundPolicy.acceptsExtensionIdentifier(action.actionID)
        else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard RemoteSessionAccess.isVisible(
                self.services.sessionQueries.session(withID: sessionID)
            ), let item = self.services.extensions.registeredPanel(
                extensionIdentifier: reference.extensionIdentifier,
                panelID: reference.panelID
            ) else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            guard action.processGeneration == item.processGeneration else {
                respond(.respond(RemoteRouter.json(RemoteExtensionPanelActionResponseDTO(
                    processGeneration: item.processGeneration,
                    panel: item.panel
                ))))
                return
            }

            let projectID = self.services.sessionQueries.project(forSessionID: sessionID)?
                .id.uuidString.lowercased()
            _ = self.services.extensions.invokePanelAction(
                extensionIdentifier: reference.extensionIdentifier,
                panelID: reference.panelID,
                actionID: action.actionID,
                value: action.value,
                context: ExtensionCommandContext(
                    projectID: projectID,
                    sessionID: sessionID.uuidString.lowercased()
                )
            ) { result in
                let payload: RemoteExtensionPanelActionResponseDTO
                switch result {
                case let .success(response):
                    payload = RemoteExtensionPanelActionResponseDTO(
                        processGeneration: item.processGeneration,
                        panel: response.panel,
                        message: response.message,
                        error: response.error
                    )
                case let .failure(error):
                    payload = RemoteExtensionPanelActionResponseDTO(
                        processGeneration: item.processGeneration,
                        error: error.localizedDescription
                    )
                }
                respond(.respond(RemoteRouter.json(payload)))
            }
        }
    }

    /// Package images referenced by the semantic tree stay behind the same owner-only boundary.
    /// `ExtensionManager` resolves and bounds the package-relative path before any bytes are read.
    private func handleExtensionPanelResource(
        _ request: HTTPRequest,
        sessionID rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {
        guard let sessionID = authorizeOwnerSessionRead(
            request,
            rawSessionID: rawSessionID,
            respond: respond
        ) else { return }
        guard let reference = extensionPanelReference(in: request),
              let path = RemoteRouter.queryValue(named: "path", in: request.path),
              RemoteInboundPolicy.acceptsExtensionResourcePath(path)
        else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard RemoteSessionAccess.isVisible(
                self.services.sessionQueries.session(withID: sessionID)
            ), self.services.extensions.registeredPanel(
                extensionIdentifier: reference.extensionIdentifier,
                panelID: reference.panelID
            ) != nil,
                let url = self.services.extensions.extensionImageResourceURL(
                    extensionIdentifier: reference.extensionIdentifier,
                    relativePath: path
                )
            else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            let contentType = Self.attachmentContentType(for: url)
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = ExtensionImageResourcePolicy.validatedData(at: url) else {
                    respond(.respond(RemoteRouter.error(404, "Not Found")))
                    return
                }
                respond(.respond(RemoteRouter.data(data, contentType: contentType)))
            }
        }
    }

    private func extensionPanelReference(
        in request: HTTPRequest
    ) -> (extensionIdentifier: String, panelID: String)? {
        guard let extensionIdentifier = RemoteRouter.queryValue(
            named: "extension",
            in: request.path
        ), let panelID = RemoteRouter.queryValue(named: "panel", in: request.path),
        RemoteInboundPolicy.acceptsExtensionIdentifier(extensionIdentifier),
        RemoteInboundPolicy.acceptsExtensionIdentifier(panelID) else {
            return nil
        }
        return (extensionIdentifier, panelID)
    }

    private static func attachmentContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "html", "htm": return "text/html; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "zip": return "application/zip"
        case "tar": return "application/x-tar"
        case "gz", "tgz": return "application/gzip"
        case "bz2", "tbz2": return "application/x-bzip2"
        case "xz", "txz": return "application/x-xz"
        case "7z": return "application/x-7z-compressed"
        case "rar": return "application/vnd.rar"
        case "rtf": return "application/rtf"
        case "odt": return "application/vnd.oasis.opendocument.text"
        case "ods": return "application/vnd.oasis.opendocument.spreadsheet"
        case "odp": return "application/vnd.oasis.opendocument.presentation"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "dot", "gv": return "text/vnd.graphviz; charset=utf-8"
        case "mmd", "mermaid": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    /// Workspace and repository reads expose more than the shared conversation. Keep them behind
    /// the paired owner's all-session capability; an exact-session guest link must not become a
    /// source-code or browser-pixel viewer merely because its chat runs in that session.
    private func authorizeOwnerSessionRead(
        _ request: HTTPRequest,
        rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) -> SessionID? {
        guard let authorization = authorizeREST(request, respond: respond) else { return nil }
        guard authorization.principal == .ownerDevice,
              authorization.scope == .allSessions
        else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return nil
        }
        guard let sessionID = SessionID(uuidString: rawSessionID),
              authorization.scope.covers(sessionID)
        else {
            respond(.respond(RemoteRouter.error(404, "Not Found")))
            return nil
        }
        return sessionID
    }

    private func authorizeSessionManagement(
        _ request: HTTPRequest,
        rawSessionID: String,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) -> RemoteAuthorization? {
        guard let authorization = authorizeREST(request, respond: respond) else { return nil }
        guard canManageSessions(authorization) else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return nil
        }
        guard let sessionID = SessionID(uuidString: rawSessionID),
              authorization.scope.covers(sessionID)
        else {
            respond(.respond(RemoteRouter.error(404, "Not Found")))
            return nil
        }
        return authorization
    }

    private func authorizeREST(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) -> RemoteAuthorization? {
        let rawDevice = request.header(RemoteRouter.deviceHeader)
        let authorization: RemoteAuthorization
        switch resolveAuthorization(for: RemoteRouter.bearerToken(from: request), device: rawDevice) {
        case let .authorized(resolved):
            authorization = resolved
        case .rateLimited:
            respond(.respond(RemoteRouter.error(429, "Too Many Requests")))
            return nil
        case .unauthorized:
            respond(.respond(RemoteRouter.error(401, "Unauthorized")))
            return nil
        }

        // Negotiate only after the bearer has authenticated. This gives a paired, out-of-date
        // client a precise update message without exposing a public log-flooding path.
        let version = request.header(RemoteRouter.protocolHeader).flatMap { Int($0) }
        let minimum = request.header(RemoteRouter.protocolMinimumHeader).flatMap { Int($0) }
        if let update = protocolUpdateNeeded(version: version, minimum: minimum) {
            respond(.respond(RemoteRouter.json(
                upgradeRequired(update),
                status: 426,
                reason: "Upgrade Required"
            )))
            return nil
        }
        return authorization
    }

    private func canManageThemes(_ authorization: RemoteAuthorization) -> Bool {
        authorization.canManageHost
    }

    private func canManageSessions(_ authorization: RemoteAuthorization) -> Bool {
        authorization.canManageHost
    }

    // MARK: - WebSocket auth and input

    private func authenticate(_ connection: RemoteConnection, message: RemoteClientMessage) {
        guard connection.authorization == nil else { return }

        let rawDevice = message.device
        let device = RemoteInboundPolicy.normalizedDeviceID(rawDevice)
        let deviceName = RemoteInboundPolicy.normalizedDeviceName(message.deviceName)
        let replayBudget = RemoteInboundPolicy.normalizedTerminalReplayBudget(message.replayBudget)
        let authorization: RemoteAuthorization
        switch resolveAuthorization(for: message.token, device: rawDevice) {
        case let .authorized(resolved):
            authorization = resolved
        case .rateLimited:
            connection.sendClose(code: 4008, reason: "Too many authentication attempts")
            return
        case .unauthorized:
            connection.sendClose(code: 4001, reason: "Unauthorized")
            return
        }

        if let update = protocolUpdateNeeded(version: message.protocolVersion, minimum: message.protocolMinimum) {
            connection.sendText(encode(RemoteEndedDTO(reason: "protocolMismatch", update: update)))
            connection.sendClose(code: 4002, reason: "Protocol mismatch")
            return
        }

        if let rawTerminalID = connection.routedTerminalID {
            guard let terminalID = TerminalID(uuidString: rawTerminalID) else {
                connection.sendClose(code: 4004, reason: "Unknown terminal")
                return
            }
            guard authorization.scope.covers(terminalID) else {
                recordFailedAuth(reason: "scope", device: rawDevice)
                connection.sendClose(code: 4003, reason: "Forbidden")
                return
            }
            guard connection.authenticate(
                authorization: authorization,
                deviceID: device,
                deviceName: deviceName,
                terminalReplayBudget: replayBudget
            ) else { return }
            DispatchQueue.main.async {
                guard self.authorizer?.isCurrent(authorization) == true else {
                    connection.sendClose(code: 4003, reason: "Share revoked")
                    return
                }
                guard self.services.mirrors.attach(
                    connection,
                    to: terminalID,
                    authorization: authorization
                ) else {
                    connection.sendClose(code: 4004, reason: "Terminal not available")
                    return
                }
                self.services.eventLog.recordRemoteEvent("Remote terminal connected", [
                    .terminal: terminalID.uuidString,
                    .capability: authorization.capability.rawValue,
                    .device: device ?? "unknown",
                ])
            }
            return
        }

        guard let routed = connection.routedSessionID else {
            connection.sendClose(code: 4004, reason: "Unknown session")
            return
        }

        if routed == RemoteRouter.themeEventsRouteID {
            guard connection.authenticate(
                authorization: authorization,
                deviceID: device,
                deviceName: deviceName,
                terminalReplayBudget: replayBudget
            ) else { return }
            DispatchQueue.main.async {
                guard self.authorizer?.isCurrent(authorization) == true else {
                    connection.sendClose(code: 4003, reason: "Share revoked")
                    return
                }
                self.services.mirrors.attachThemeEvents(connection)
            }
            return
        }

        guard let sessionID = SessionID(uuidString: routed) else {
            connection.sendClose(code: 4004, reason: "Unknown session")
            return
        }

        guard authorization.scope.covers(sessionID) else {
            recordFailedAuth(reason: "scope", device: rawDevice)
            connection.sendClose(code: 4003, reason: "Forbidden")
            return
        }

        guard connection.authenticate(
            authorization: authorization,
            deviceID: device,
            deviceName: deviceName,
            terminalReplayBudget: replayBudget
        ) else { return }

        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendClose(code: 4003, reason: "Share revoked")
                return
            }
            let attach = self.services.mirrors.attachOrWaitForStartup(
                connection,
                to: sessionID,
                authorization: authorization,
                authorizationIsCurrent: { [weak self] in
                    self?.authorizer?.isCurrent(authorization) == true
                },
                didAttach: { [weak self] in
                    guard let self else { return }
                    self.recordSessionConnection(
                        sessionID: sessionID,
                        authorization: authorization,
                        device: device
                    )
                }
            )
            if case .unavailable = attach {
                connection.sendClose(code: 4004, reason: "Session not available")
            }
        }
    }

    private func recordSessionConnection(
        sessionID: SessionID,
        authorization: RemoteAuthorization,
        device: String?
    ) {
        services.eventLog.recordRemoteEvent("Remote client connected", [
            .session: sessionID.uuidString,
            .capability: authorization.capability.rawValue,
            .device: device ?? "unknown",
        ])
        var fields: [RemoteDiagnosticField: String] = [
            .session: MacRemoteDiagnostics.pseudonym(
                sessionID.uuidString,
                prefix: "session"
            ),
            .capability: authorization.capability.rawValue,
            .transport: "websocket",
        ]
        if let device {
            fields[.peer] = MacRemoteDiagnostics.pseudonym(device, prefix: "device")
        }
        MacRemoteDiagnostics.record(.socketConnected, fields: fields)
    }

    private func handleInput(
        _ connection: RemoteConnection,
        data: String?,
        requestID rawRequestID: String?
    ) {
        guard let authorization = connection.authorization, authorization.capability == .interact else {
            connection.sendText(#"{"type":"error","code":"forbidden"}"#)
            services.eventLog.recordRemoteEvent("Remote input refused", [.reason: "view-only"])
            return
        }
        guard let data else { return }
        guard RemoteInboundPolicy.acceptsTerminalInput(data) else {
            connection.sendText(encode(RemoteErrorDTO(code: "inputTooLarge")))
            return
        }

        // A request id is diagnostic sampling, not part of terminal input semantics. Invalid ids
        // are ignored so a stale or malformed probe can never make an otherwise valid key fail.
        let requestID = rawRequestID.flatMap(RemoteInboundPolicy.normalizedMutationRequestID)
        let startedAt = requestID.map { requestID in
            beginHostLatencyDiagnostic(
                event: .terminalInputProbeStarted,
                requestID: requestID,
                connection: connection,
                kind: "terminal"
            )
        }
        let bytes = Array(data.utf8)
        let device = connection.deviceID
        DispatchQueue.main.async {
            self.applyTerminalWireAdmissionDelayIfEnabled()
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                self.finishTerminalInputProbe(
                    connection,
                    requestID: requestID,
                    startedAt: startedAt,
                    accepted: false,
                    result: "forbidden"
                )
                return
            }
            let accepted: Bool
            if let rawTerminalID = connection.routedTerminalID,
               let terminalID = TerminalID(uuidString: rawTerminalID)
            {
                accepted = self.services.mirrors.sendInput(
                    bytes,
                    to: terminalID,
                    device: device,
                    authorization: authorization
                )
            } else if let routed = connection.routedSessionID,
                      let sessionID = SessionID(uuidString: routed)
            {
                accepted = self.services.mirrors.sendInput(
                    bytes,
                    to: sessionID,
                    device: device,
                    authorization: authorization
                )
            } else {
                accepted = false
            }
            if !accepted {
                connection.sendText(self.encode(RemoteErrorDTO(code: "controlHeld")))
            }
            self.finishTerminalInputProbe(
                connection,
                requestID: requestID,
                startedAt: startedAt,
                accepted: accepted,
                result: accepted ? "accepted" : "controlHeld"
            )
        }
    }

    private func finishTerminalInputProbe(
        _ connection: RemoteConnection,
        requestID: String?,
        startedAt: UInt64?,
        accepted: Bool,
        result: String
    ) {
        guard let requestID, let startedAt else { return }
        finishHostLatencyDiagnostic(
            event: .terminalInputProbeEnded,
            requestID: requestID,
            connection: connection,
            kind: "terminal",
            result: result,
            startedAt: startedAt
        )
        connection.sendText(encode(RemoteTerminalInputProbeResultDTO(
            requestID: requestID,
            accepted: accepted
        )))
    }

    private func beginHostLatencyDiagnostic(
        event: RemoteDiagnosticEvent,
        requestID: String,
        connection: RemoteConnection,
        kind: String
    ) -> UInt64 {
        let startedAt = MacRemoteDiagnostics.monotonicNow()
        MacRemoteDiagnostics.recordInteraction(event, fields: hostLatencyDiagnosticFields(
            requestID: requestID,
            connection: connection,
            kind: kind,
            result: "started"
        ))
        return startedAt
    }

    private func finishHostLatencyDiagnostic(
        event: RemoteDiagnosticEvent,
        requestID: String,
        connection: RemoteConnection,
        kind: String,
        result: String,
        startedAt: UInt64
    ) {
        var fields = hostLatencyDiagnosticFields(
            requestID: requestID,
            connection: connection,
            kind: kind,
            result: result
        )
        fields[.durationMS] = MacRemoteDiagnostics.elapsedMilliseconds(since: startedAt)
        MacRemoteDiagnostics.recordInteraction(
            event,
            level: result == RemotePromptSubmissionStatus.accepted.rawValue ? .info : .warning,
            fields: fields
        )
    }

    private func hostLatencyDiagnosticFields(
        requestID: String,
        connection: RemoteConnection,
        kind: String,
        result: String
    ) -> [RemoteDiagnosticField: String] {
        var fields: [RemoteDiagnosticField: String] = [
            .trace: MacRemoteDiagnostics.pseudonym(requestID, prefix: "trace"),
            .phase: "hostAdmission",
            .kind: kind,
            .result: result,
        ]
        if let routed = connection.routedSessionID,
           let sessionID = SessionID(uuidString: routed)
        {
            fields[.session] = MacRemoteDiagnostics.pseudonym(
                sessionID.uuidString,
                prefix: "session"
            )
        }
        if let device = connection.deviceID {
            fields[.peer] = MacRemoteDiagnostics.pseudonym(device, prefix: "device")
        }
        return fields
    }

    /// The real-wire simulator lab can reproduce a busy host without changing production
    /// behavior or relying on ambient load. Delaying inside the main-queue admission block has
    /// the same boundary as the stalls that made the reported terminal interaction sluggish.
    private func applyTerminalWireAdmissionDelayIfEnabled() {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["THREADING_REMOTE_TERMINAL_WIRE_FIXTURE"] == "1",
                  let raw = ProcessInfo.processInfo.environment[
                      "THREADING_REMOTE_TERMINAL_WIRE_ADMISSION_DELAY_MS"
                  ],
                  let milliseconds = UInt64(raw),
                  milliseconds > 0,
                  milliseconds <= 5000 else { return }
            Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
        #endif
    }

    private func handleViewport(
        _ connection: RemoteConnection,
        cols: Int?,
        rows: Int?,
        requestID rawRequestID: String?
    ) {
        guard let authorization = connection.authorization,
              authorization.capability == .interact
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        if let rawTerminalID = connection.routedTerminalID,
           let terminalID = TerminalID(uuidString: rawTerminalID)
        {
            guard let cols, let rows else {
                refuseViewport(
                    connection,
                    cols: cols,
                    rows: rows,
                    refusal: .missingSize
                )
                return
            }
            guard RemoteViewportRefusal.columns.contains(cols) else {
                refuseViewport(
                    connection,
                    cols: cols,
                    rows: rows,
                    refusal: .columnsOutOfRange
                )
                return
            }
            guard RemoteViewportRefusal.rows.contains(rows) else {
                refuseViewport(
                    connection,
                    cols: cols,
                    rows: rows,
                    refusal: .rowsOutOfRange
                )
                return
            }
            DispatchQueue.main.async {
                guard self.authorizer?.isCurrent(authorization) == true else { return }
                self.services.mirrors.requestViewport(
                    from: connection,
                    terminalID: terminalID,
                    cols: cols,
                    rows: rows
                )
            }
            return
        }
        switch Self.viewportRequest(
            cols: cols,
            rows: rows,
            routedSessionID: connection.routedSessionID
        ) {
        case let .refused(refusal):
            refuseViewport(connection, cols: cols, rows: rows, refusal: refusal)
        case let .accepted(cols, rows, sessionID):
            DispatchQueue.main.async {
                guard self.authorizer?.isCurrent(authorization) == true else {
                    connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                    return
                }
                self.services.mirrors.requestViewport(
                    from: connection,
                    sessionID: sessionID,
                    cols: cols,
                    rows: rows,
                    hydrationRequestID: rawRequestID.flatMap(
                        RemoteInboundPolicy.normalizedMutationRequestID
                    )
                )
            }
        }
    }

    enum ViewportRequest: Equatable {
        case accepted(cols: Int, rows: Int, sessionID: SessionID)
        case refused(RemoteViewportRefusal)
    }

    /// One decision, and it names the clause that refused.
    ///
    /// This used to be a five-clause `guard` that answered every failure with the single word
    /// `invalidViewport`, so a phone asking for a grid outside the accepted range and a
    /// connection routed to no session at all produced the same message and the same silence in
    /// the journal. Keeping the accepted case in the same result is what stops the diagnosis and
    /// the admission rule from drifting apart.
    static func viewportRequest(
        cols: Int?,
        rows: Int?,
        routedSessionID: String?
    ) -> ViewportRequest {
        guard let cols, let rows else { return .refused(.missingSize) }
        guard let routedSessionID else { return .refused(.unroutedConnection) }
        guard let sessionID = SessionID(uuidString: routedSessionID) else {
            return .refused(.malformedSessionID)
        }
        guard RemoteViewportRefusal.columns.contains(cols) else {
            return .refused(.columnsOutOfRange)
        }
        guard RemoteViewportRefusal.rows.contains(rows) else {
            return .refused(.rowsOutOfRange)
        }
        return .accepted(cols: cols, rows: rows, sessionID: sessionID)
    }

    private func refuseViewport(
        _ connection: RemoteConnection,
        cols: Int?,
        rows: Int?,
        refusal: RemoteViewportRefusal
    ) {
        connection.sendText(
            encode(RemoteErrorDTO(code: "invalidViewport", detail: refusal.rawValue))
        )
        let requested = Self.viewportDetail(cols: cols, rows: rows)
        ThreadingLogger.remote.warning(
            "Remote viewport refused reason=\(refusal.rawValue, privacy: .public) requested=\(requested, privacy: .public)"
        )
        var fields: [RemoteDiagnosticField: String] = [
            .code: "invalidViewport",
            .reason: refusal.rawValue,
            .detail: requested,
        ]
        if let routed = connection.routedSessionID {
            fields[.session] = MacRemoteDiagnostics.pseudonym(routed, prefix: "session")
        }
        MacRemoteDiagnostics.record(.socketFailed, level: .warning, fields: fields)
    }

    /// The grid the client asked for, as a token the share-safe journal accepts. Terminal
    /// dimensions are the client's own layout, never content, so the numbers travel verbatim.
    private static func viewportDetail(cols: Int?, rows: Int?) -> String {
        let columns = cols.map(String.init) ?? "none"
        let lines = rows.map(String.init) ?? "none"
        return "\(columns)x\(lines)"
    }

    private func handleViewportRelease(_ connection: RemoteConnection) {
        guard let authorization = connection.authorization,
              authorization.capability == .interact
        else {
            return
        }
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else { return }
            if let rawTerminalID = connection.routedTerminalID,
               let terminalID = TerminalID(uuidString: rawTerminalID)
            {
                self.services.mirrors.releaseViewport(
                    from: connection,
                    terminalID: terminalID
                )
            } else if let routed = connection.routedSessionID,
                      let sessionID = SessionID(uuidString: routed)
            {
                self.services.mirrors.releaseViewport(
                    from: connection,
                    sessionID: sessionID
                )
            }
        }
    }

    /// Removes a phone from every live-session side effect without paying for a new TLS and
    /// WebSocket handshake if it returns shortly. Standalone project terminals are excluded:
    /// they are shells rather than push/pop chat destinations and have no session route to
    /// re-authorize on resume.
    private func handleSessionPark(_ connection: RemoteConnection) {
        guard let authorization = connection.authorization,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed),
              authorization.scope.covers(sessionID)
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidSessionParking")))
            return
        }
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendClose(code: 4003, reason: "Share revoked")
                return
            }
            if !self.services.mirrors.park(connection, sessionID: sessionID) {
                connection.sendText(self.encode(RemoteErrorDTO(code: "invalidSessionParking")))
            }
        }
    }

    /// Rejoins the same authorized route. `attach` is intentionally the one resume path: its
    /// hello, bounded replay/snapshot and collaboration state are the authoritative state after
    /// time away, and avoid inventing a second partial synchronization protocol for warm sockets.
    private func handleSessionResume(_ connection: RemoteConnection) {
        guard let authorization = connection.authorization,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed),
              authorization.scope.covers(sessionID)
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidSessionParking")))
            return
        }
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendClose(code: 4003, reason: "Share revoked")
                return
            }
            guard !self.services.mirrors.isAttached(connection, to: sessionID) else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "invalidSessionParking")))
                return
            }
            guard self.services.mirrors.attach(
                connection,
                to: sessionID,
                authorization: authorization
            ) else {
                connection.sendText(self.encode(RemoteEndedDTO(reason: "sessionClosed")))
                connection.sendClose(code: 4004, reason: "Session not available")
                return
            }
        }
    }

    private func handleConversationPage(
        _ connection: RemoteConnection,
        beforeRowID: String?,
        limit: Int?
    ) {
        guard let authorization = connection.authorization,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed),
              beforeRowID.map(RemoteInboundPolicy.acceptsConversationRowID) ?? true,
              limit.map({ (1 ... RemoteAccessDefaults.maximumRemoteConversationRows).contains($0) })
              ?? true
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidConversationPage")))
            return
        }
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                return
            }
            self.services.mirrors.requestConversationPage(
                from: connection,
                sessionID: sessionID,
                beforeRowID: beforeRowID,
                limit: limit
            )
        }
    }

    private func handleConversationResync(_ connection: RemoteConnection) {
        guard let authorization = connection.authorization,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed)
        else {
            return
        }
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else { return }
            self.services.mirrors.resyncConversation(
                for: connection,
                sessionID: sessionID
            )
        }
    }

    private func handleRunPlanPage(
        _ connection: RemoteConnection,
        revision: Int?,
        offset: Int?,
        limit: Int?
    ) {
        guard let authorization = connection.authorization,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed),
              let revision, revision >= 0,
              let offset, offset >= 0,
              limit.map({ (1 ... RemoteAccessDefaults.maximumRemoteRunPlanPageSteps).contains($0) })
              ?? true
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidRunPlanPage")))
            return
        }
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                return
            }
            self.services.mirrors.requestRunPlanPage(
                from: connection,
                sessionID: sessionID,
                revision: revision,
                offset: offset,
                limit: limit
            )
        }
    }

    private func handleSubmit(
        _ connection: RemoteConnection,
        text: String?,
        contextAttachments: [RemoteConversationContextAttachmentDTO]?,
        attachmentUploadIDs: [String]?,
        requestID rawRequestID: String?
    ) {
        guard let authorization = connection.authorization, authorization.capability == .interact else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        guard let text, let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed)
        else {
            return
        }
        guard RemoteInboundPolicy.acceptsPrompt(text),
              RemoteInboundPolicy.acceptsContextAttachments(contextAttachments)
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "promptTooLarge")))
            return
        }

        let requestID = rawRequestID.flatMap(RemoteInboundPolicy.normalizedMutationRequestID)
        if rawRequestID != nil, requestID == nil {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidRequestID")))
            return
        }

        let device = connection.deviceID
        let diagnosticStartedAt = requestID.map { requestID in
            beginHostLatencyDiagnostic(
                event: .promptSubmissionStarted,
                requestID: requestID,
                connection: connection,
                kind: "conversation"
            )
        }

        // Claimed here, on the queue that owns staging, and never on the main actor: the hop
        // below is asynchronous, and two submits racing for the same upload would otherwise
        // both find it present and both name a file only one of them still owns.
        //
        // A refusal ends the submission rather than sending the words alone. Somebody who
        // attached a picture and pressed send meant to send the picture; a prompt that silently
        // lost it and went anyway cannot be taken back.
        let stagedPaths: [String]
        if let attachmentUploadIDs, !attachmentUploadIDs.isEmpty {
            guard let deviceID = device, authorization.principal == .ownerDevice,
                  authorization.scope == .allSessions,
                  attachmentUploadIDs.count
                  <= RemoteAttachmentUploadDefaults.maximumStagedUploadsPerSession,
                  let claimed = attachmentUploads.claim(
                      ids: attachmentUploadIDs,
                      sessionID: sessionID.uuidString,
                      deviceID: deviceID
                  )
            else {
                connection.sendText(encode(RemoteErrorDTO(code: "unknownAttachmentUpload")))
                if let requestID {
                    connection.sendText(encode(RemotePromptSubmissionResultDTO(
                        requestID: requestID,
                        status: .rejected
                    )))
                    if let diagnosticStartedAt {
                        finishHostLatencyDiagnostic(
                            event: .promptSubmissionEnded,
                            requestID: requestID,
                            connection: connection,
                            kind: "conversation",
                            result: RemotePromptSubmissionStatus.rejected.rawValue,
                            startedAt: diagnosticStartedAt
                        )
                    }
                }
                return
            }
            stagedPaths = claimed.map(\.path)
        } else {
            stagedPaths = []
        }

        let claimedIDs = stagedPaths.isEmpty ? [] : (attachmentUploadIDs ?? [])
        DispatchQueue.main.async {
            self.applyTerminalWireAdmissionDelayIfEnabled()
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                self.resolveClaim(claimedIDs, accepted: false)
                if let requestID, let diagnosticStartedAt {
                    self.finishHostLatencyDiagnostic(
                        event: .promptSubmissionEnded,
                        requestID: requestID,
                        connection: connection,
                        kind: "conversation",
                        result: "forbidden",
                        startedAt: diagnosticStartedAt
                    )
                }
                return
            }
            let status = self.services.mirrors.submitPrompt(
                text,
                contextAttachments: contextAttachments,
                attachmentPaths: stagedPaths,
                to: sessionID,
                device: device,
                authorization: authorization,
                requestID: requestID
            )
            // The outcome decides what happens to the loan. Accepted means custody was taken and
            // the staged duplicate can go; anything else gives the files back, so the draft the
            // composer is still showing can be sent again without re-uploading a thing.
            self.resolveClaim(claimedIDs, accepted: status == .accepted)
            guard let requestID else { return }
            if let diagnosticStartedAt {
                self.finishHostLatencyDiagnostic(
                    event: .promptSubmissionEnded,
                    requestID: requestID,
                    connection: connection,
                    kind: "conversation",
                    result: status.rawValue,
                    startedAt: diagnosticStartedAt
                )
            }
            connection.sendText(self.encode(RemotePromptSubmissionResultDTO(
                requestID: requestID,
                status: status
            )))
        }
    }

    /// Answers a `claim` from whichever thread the submission finished on, back on the queue that
    /// owns staging.
    private func resolveClaim(_ ids: [String], accepted: Bool) {
        guard !ids.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if accepted {
                attachmentUploads.discardClaimed(ids: ids)
            } else {
                attachmentUploads.release(ids: ids)
            }
        }
    }

    private func handleTerminalSubmit(
        _ connection: RemoteConnection,
        text: String?,
        attachmentUploadIDs: [String]?,
        requestID rawRequestID: String?
    ) {
        guard let authorization = connection.authorization,
              authorization.capability == .interact
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || attachmentUploadIDs?.isEmpty == false,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed)
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidTerminalSubmission")))
            return
        }
        guard RemoteInboundPolicy.acceptsTerminalInput(text + "\r") else {
            connection.sendText(encode(RemoteErrorDTO(code: "promptTooLarge")))
            return
        }

        let requestID = rawRequestID.flatMap(RemoteInboundPolicy.normalizedMutationRequestID)
        guard let requestID else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidRequestID")))
            return
        }

        let device = connection.deviceID
        let diagnosticStartedAt = beginHostLatencyDiagnostic(
            event: .promptSubmissionStarted,
            requestID: requestID,
            connection: connection,
            kind: "terminal"
        )
        let stagedPaths: [String]
        if let attachmentUploadIDs, !attachmentUploadIDs.isEmpty {
            guard let deviceID = device,
                  authorization.principal == .ownerDevice,
                  authorization.scope == .allSessions,
                  attachmentUploadIDs.count
                  <= RemoteAttachmentUploadDefaults.maximumStagedUploadsPerSession,
                  let claimed = attachmentUploads.claim(
                      ids: attachmentUploadIDs,
                      sessionID: sessionID.uuidString,
                      deviceID: deviceID
                  )
            else {
                connection.sendText(encode(RemoteErrorDTO(code: "unknownAttachmentUpload")))
                connection.sendText(encode(RemotePromptSubmissionResultDTO(
                    requestID: requestID,
                    status: .rejected
                )))
                finishHostLatencyDiagnostic(
                    event: .promptSubmissionEnded,
                    requestID: requestID,
                    connection: connection,
                    kind: "terminal",
                    result: RemotePromptSubmissionStatus.rejected.rawValue,
                    startedAt: diagnosticStartedAt
                )
                return
            }
            stagedPaths = claimed.map(\.path)
        } else {
            stagedPaths = []
        }
        let claimedIDs = stagedPaths.isEmpty ? [] : (attachmentUploadIDs ?? [])
        DispatchQueue.main.async {
            self.applyTerminalWireAdmissionDelayIfEnabled()
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                self.resolveClaim(claimedIDs, accepted: false)
                self.finishHostLatencyDiagnostic(
                    event: .promptSubmissionEnded,
                    requestID: requestID,
                    connection: connection,
                    kind: "terminal",
                    result: "forbidden",
                    startedAt: diagnosticStartedAt
                )
                return
            }
            let status = self.services.mirrors.submitTerminalLine(
                text,
                stagedAttachmentPaths: stagedPaths,
                to: sessionID,
                device: device,
                authorization: authorization,
                requestID: requestID
            )
            self.finishHostLatencyDiagnostic(
                event: .promptSubmissionEnded,
                requestID: requestID,
                connection: connection,
                kind: "terminal",
                result: status.rawValue,
                startedAt: diagnosticStartedAt
            )
            connection.sendText(self.encode(RemotePromptSubmissionResultDTO(
                requestID: requestID,
                status: status
            )))
            self.resolveClaim(claimedIDs, accepted: status == .accepted)
        }
    }

    private func handleTerminalAttachmentInsert(
        _ connection: RemoteConnection,
        attachmentUploadIDs: [String]?,
        requestID rawRequestID: String?
    ) {
        guard let authorization = connection.authorization,
              authorization.capability == .interact
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        guard let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed),
              let attachmentUploadIDs,
              !attachmentUploadIDs.isEmpty,
              attachmentUploadIDs.count
              <= RemoteAttachmentUploadDefaults.maximumStagedUploadsPerSession
        else {
            connection.sendText(encode(RemoteErrorDTO(
                code: "invalidTerminalAttachmentInsertion"
            )))
            return
        }
        guard let requestID = rawRequestID.flatMap(
            RemoteInboundPolicy.normalizedMutationRequestID
        ) else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidRequestID")))
            return
        }
        let diagnosticStartedAt = beginHostLatencyDiagnostic(
            event: .promptSubmissionStarted,
            requestID: requestID,
            connection: connection,
            kind: "terminalAttachment"
        )
        guard let deviceID = connection.deviceID,
              authorization.principal == .ownerDevice,
              authorization.scope == .allSessions,
              let claimed = attachmentUploads.claim(
                  ids: attachmentUploadIDs,
                  sessionID: sessionID.uuidString,
                  deviceID: deviceID
              )
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "unknownAttachmentUpload")))
            connection.sendText(encode(RemotePromptSubmissionResultDTO(
                requestID: requestID,
                status: .rejected
            )))
            finishHostLatencyDiagnostic(
                event: .promptSubmissionEnded,
                requestID: requestID,
                connection: connection,
                kind: "terminalAttachment",
                result: RemotePromptSubmissionStatus.rejected.rawValue,
                startedAt: diagnosticStartedAt
            )
            return
        }

        let stagedPaths = claimed.map(\.path)
        DispatchQueue.main.async {
            self.applyTerminalWireAdmissionDelayIfEnabled()
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                self.resolveClaim(attachmentUploadIDs, accepted: false)
                self.finishHostLatencyDiagnostic(
                    event: .promptSubmissionEnded,
                    requestID: requestID,
                    connection: connection,
                    kind: "terminalAttachment",
                    result: "forbidden",
                    startedAt: diagnosticStartedAt
                )
                return
            }
            let status = self.services.mirrors.insertTerminalAttachments(
                stagedPaths: stagedPaths,
                into: sessionID,
                device: connection.deviceID,
                authorization: authorization,
                requestID: requestID
            )
            self.finishHostLatencyDiagnostic(
                event: .promptSubmissionEnded,
                requestID: requestID,
                connection: connection,
                kind: "terminalAttachment",
                result: status.rawValue,
                startedAt: diagnosticStartedAt
            )
            connection.sendText(self.encode(RemotePromptSubmissionResultDTO(
                requestID: requestID,
                status: status
            )))
            self.resolveClaim(attachmentUploadIDs, accepted: status == .accepted)
        }
    }

    private func handleQuestionAnswer(
        _ connection: RemoteConnection, id: String?, answers: [String: String]?, decision: String?
    ) {
        guard let authorization = connection.authorization, authorization.capability == .interact,
              let routed = connection.routedSessionID, let sessionID = SessionID(uuidString: routed),
              authorization.scope.covers(sessionID) else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        guard let id, UUID(uuidString: id) != nil,
              (decision == "answer" && answers.map { (1...3).contains($0.count) } == true)
                || (decision == "cancel" && answers == nil) else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidQuestionAnswer")))
            return
        }
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                return
            }
            guard self.services.mirrors.answerQuestion(
                id: id, answers: answers, sessionID: sessionID, authorization: authorization
            ) else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "questionNotPending")))
                return
            }
            self.services.eventLog.recordRemoteEvent("Remote question answered", [
                .session: sessionID.uuidString, .decision: decision ?? "answer",
                .device: connection.deviceID ?? "unknown"
            ])
        }
    }

    private func handlePermission(
        _ connection: RemoteConnection,
        id: String?,
        decision rawDecision: String?
    ) {
        guard let authorization = connection.authorization,
              authorization.canApprovePermissions
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        guard let id, let rawDecision,
              let decision = RemotePermissionDecision(rawValue: rawDecision),
              RemoteInboundPolicy.acceptsPermissionID(id),
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed)
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidPermissionDecision")))
            return
        }

        let notPending = encode(RemoteErrorDTO(code: "permissionNotPending"))
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                return
            }
            guard RemoteSessionAccess.isVisible(
                self.services.sessionQueries.session(withID: sessionID)
            ), self.services.runtimeStatus.resolveRemotePermission(
                sessionID: sessionID,
                id: id,
                decision: decision
            ) else {
                connection.sendText(notPending)
                return
            }
            self.services.eventLog.recordRemoteEvent("Remote permission decision", [
                .session: sessionID.uuidString,
                .decision: decision.rawValue,
                .device: connection.deviceID ?? "unknown",
            ])
            var fields: [RemoteDiagnosticField: String] = [
                .trace: id,
                .session: MacRemoteDiagnostics.pseudonym(
                    sessionID.uuidString,
                    prefix: "session"
                ),
                .result: decision.rawValue,
            ]
            if let device = connection.deviceID {
                fields[.peer] = MacRemoteDiagnostics.pseudonym(
                    device,
                    prefix: "device"
                )
            }
            MacRemoteDiagnostics.record(.permissionDecisionReceived, fields: fields)
        }
    }

    private func handleAttentionRequest(
        _ connection: RemoteConnection,
        recipientID: String?,
        note rawNote: String?,
        requestID rawRequestID: String?
    ) {
        guard let authorization = connection.authorization,
              authorization.capability == .interact
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        let requestID = rawRequestID.flatMap(RemoteInboundPolicy.normalizedMutationRequestID)
        guard let requestID,
              let recipientID,
              RemoteInboundPolicy.acceptsAttentionRecipientID(recipientID),
              rawNote.map(RemoteInboundPolicy.acceptsAttentionNote) ?? true,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed)
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidAttentionRequest")))
            return
        }
        let note = RemoteInboundPolicy.normalizedAttentionNote(rawNote)
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                return
            }
            let status = self.services.mirrors.requestAttention(
                from: connection,
                sessionID: sessionID,
                recipientID: recipientID,
                note: note,
                requestID: requestID
            )
            connection.sendText(self.encode(RemoteAttentionRequestResultDTO(
                requestID: requestID,
                status: status
            )))
        }
    }

    private func handleInputControl(
        _ connection: RemoteConnection,
        action rawAction: String?,
        targetID: String?,
        requestID rawRequestID: String?
    ) {
        guard let authorization = connection.authorization,
              authorization.capability == .interact
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        let requestID = rawRequestID.flatMap(RemoteInboundPolicy.normalizedMutationRequestID)
        guard let requestID,
              let rawAction,
              let action = RemoteInputControlAction(rawValue: rawAction),
              targetID.map(RemoteInboundPolicy.acceptsAttentionRecipientID) ?? true,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed)
        else {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidInputControl")))
            return
        }
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                return
            }
            let status = self.services.mirrors.updateInputControl(
                from: connection,
                sessionID: sessionID,
                action: action,
                targetID: targetID,
                requestID: requestID
            )
            connection.sendText(self.encode(RemoteInputControlResultDTO(
                requestID: requestID,
                status: status
            )))
        }
    }

    private func handlePresence(_ connection: RemoteConnection, state rawState: String?) {
        guard let authorization = connection.authorization,
              authorization.capability == .interact,
              let rawState,
              let state = RemotePresenceUpdate(rawValue: rawState),
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed)
        else {
            return
        }
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else { return }
            self.services.mirrors.updatePresence(
                state,
                from: connection,
                sessionID: sessionID
            )
        }
    }

    private func recordFailedAuth(reason: String, device: String?) {
        authLimiter.recordFailure(device: device)
        ThreadingLogger.remote.warning("Remote auth denied: \(reason, privacy: .public)")
        services.eventLog.recordRemoteEvent("Remote auth denied", [.reason: reason])
        var fields: [RemoteDiagnosticField: String] = [.reason: reason]
        if let device {
            fields[.peer] = MacRemoteDiagnostics.pseudonym(device, prefix: "device")
        }
        MacRemoteDiagnostics.record(
            .authenticationRefused,
            level: .warning,
            fields: fields
        )
    }

    private enum AuthorizationResult {
        case authorized(RemoteAuthorization)
        case unauthorized
        case rateLimited
    }

    /// The public failure budget protects credential parsing and log volume, not authenticated
    /// clients. Looking up the 256-bit bearer first prevents unauthenticated traffic from
    /// locking every already-paired device out of its own Mac.
    private func resolveAuthorization(for token: String?, device: String?) -> AuthorizationResult {
        if let token,
           RemoteInboundPolicy.acceptsBearerToken(token),
           let authorization = authorizer?.authorization(forToken: token),
           authorization.isBound(to: device)
        {
            return .authorized(authorization)
        }
        guard !authLimiter.shouldReject(device: device) else {
            return .rateLimited
        }
        recordFailedAuth(reason: "bad token", device: device)
        return .unauthorized
    }

    // MARK: - Protocol negotiation

    /// Which side must update, or nil if the client's declared protocol is compatible. An absent
    /// version is treated as current so probes and lenient clients are never falsely blocked.
    private func protocolUpdateNeeded(version: Int?, minimum: Int?) -> RemoteUpdateTarget? {
        let peerVersion = version ?? RemoteProtocol.current
        let peerMinimum = minimum ?? RemoteProtocol.minimumSupported
        switch RemoteProtocolCompatibility.evaluate(peerVersion: peerVersion, peerMinimumSupported: peerMinimum) {
        case .compatible: return nil
        case .peerTooOld: return .client
        case .selfTooOld: return .host
        }
    }

    private func upgradeRequired(_ update: RemoteUpdateTarget) -> RemoteUpgradeRequiredDTO {
        let message = update == .client
            ? "This client is out of date. Reload the page or update the app."
            : "Threading on the Mac is out of date. Update it to connect."
        ThreadingLogger.remote.warning(
            "Remote protocol mismatch, update needed on: \(update.rawValue, privacy: .public)"
        )
        services.eventLog.recordRemoteEvent("Remote protocol mismatch", [.update: update.rawValue])
        return RemoteUpgradeRequiredDTO(update: update, message: message)
    }

    private func encode<Value: Encodable>(_ value: Value) -> String {
        do {
            return try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        } catch {
            ThreadingLogger.remote.fault(
                "Remote server encoding failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return #"{"type":"error","code":"encodingFailed"}"#
        }
    }
}

/// Resolves one HTTP byte-range request into the bounded piece this server will read.
///
/// A decoder commonly asks for `bytes=N-` (the rest of the movie). Returning at most one chunk
/// is legal partial content; the iOS resource loader continues from the returned upper bound.
/// Multiple ranges are refused because a multipart response would turn one bounded read into an
/// externally sized list of them.
struct RemoteAttachmentByteRange {
    static func resolve(
        _ header: String,
        fileSize: Int64,
        maximumLength: Int64 = Int64(RemoteAttachmentVideo.maximumChunkBytes)
    ) -> Range<Int64>? {
        guard fileSize > 0, maximumLength > 0 else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let expression = String(trimmed.dropFirst("bytes=".count))
        guard !expression.contains(",") else { return nil }
        let halves = expression.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }

        let lower: Int64
        let requestedLength: Int64
        if halves[0].isEmpty {
            guard let suffix = Int64(halves[1]), suffix > 0 else { return nil }
            let length = min(min(suffix, fileSize), maximumLength)
            lower = fileSize - length
            requestedLength = length
        } else {
            guard let start = Int64(halves[0]), start >= 0, start < fileSize else { return nil }
            lower = start
            if halves[1].isEmpty {
                requestedLength = fileSize - start
            } else {
                guard let inclusiveEnd = Int64(halves[1]), inclusiveEnd >= start else { return nil }
                let cappedEnd = min(inclusiveEnd, fileSize - 1)
                requestedLength = cappedEnd - start + 1
            }
        }
        let length = min(requestedLength, maximumLength)
        guard length > 0 else { return nil }
        return lower ..< (lower + length)
    }

    static func read(_ url: URL, range: Range<Int64>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound > range.lowerBound,
              range.upperBound - range.lowerBound <= Int64(RemoteAttachmentVideo.maximumChunkBytes),
              let count = Int(exactly: range.upperBound - range.lowerBound),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

/// A bounded rolling window for a public relay's only credential check. Device ids are
/// untrusted, so both per-device and global limits are enforced; pruning also drops empty
/// device buckets so rotating identifiers cannot grow memory without bound.
struct RemoteAuthRateLimiter {
    private var global: [TimeInterval] = []
    private var byDevice: [String: [TimeInterval]] = [:]

    mutating func shouldReject(
        device: String?,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> Bool {
        prune(now: now)
        let key = RemoteInboundPolicy.normalizedDeviceID(device) ?? "unknown"
        return global.count >= RemoteAccessDefaults.failedAuthLimitGlobal
            || (byDevice[key]?.count ?? 0) >= RemoteAccessDefaults.failedAuthLimitPerDevice
    }

    mutating func recordFailure(
        device: String?,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        prune(now: now)
        let key = RemoteInboundPolicy.normalizedDeviceID(device) ?? "unknown"
        global.append(now)
        byDevice[key, default: []].append(now)
    }

    private mutating func prune(now: TimeInterval) {
        let cutoff = now - RemoteAccessDefaults.failedAuthWindow
        global.removeAll { $0 < cutoff }
        for key in Array(byDevice.keys) {
            byDevice[key]?.removeAll { $0 < cutoff }
            if byDevice[key]?.isEmpty == true {
                byDevice.removeValue(forKey: key)
            }
        }
    }
}
