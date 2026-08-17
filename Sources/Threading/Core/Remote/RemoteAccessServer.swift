import Foundation
import CryptoKit
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
    var recordListenerDiagnostic: (
        @Sendable (RemoteDiagnosticEvent, RemoteDiagnosticLevel, [RemoteDiagnosticField: String]) -> Void
    ) {
        get { listeners.journal }
        set { listeners.journal = newValue }
    }

    private var connectionsByID: [ObjectIdentifier: RemoteConnection] = [:]
    private var authLimiter = RemoteAuthRateLimiter()
    private var mutationReplayCache: [MutationReplayKey: MutationReplayEntry] = [:]

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

    init(
        services: RemoteAccessServerServices,
        addressSource: @escaping RemoteNetworkAddressSource = RemoteNetworkInterfaces.current
    ) {
        self.services = services
        self.listeners = RemoteListenerSet(queue: queue, addressSource: addressSource)
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

    func stop() {
        queue.sync {
            // `cancel()` synchronously reports `didClose`, which removes its entry. Snapshot
            // and clear first so shutdown never mutates a Dictionary while iterating its live
            // values view.
            let connections = Array(connectionsByID.values)
            connectionsByID.removeAll()
            for connection in connections { connection.cancel() }
            authLimiter = RemoteAuthRateLimiter()
            mutationReplayCache.removeAll()
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
            where connection.authorization?.shareID == shareID {
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
              let rawRequestID = request.header(RemoteRouter.requestIDHeader) else {
            routeUncached(request, from: connection, respond: respond)
            return
        }
        guard let requestID = RemoteInboundPolicy.normalizedMutationRequestID(rawRequestID) else {
            respond(.respond(RemoteRouter.error(400, "Invalid request id")))
            return
        }
        guard let bearer = RemoteRouter.bearerToken(from: request),
              RemoteInboundPolicy.acceptsBearerToken(bearer),
              let deviceID = RemoteInboundPolicy.normalizedDeviceID(
                request.header(RemoteRouter.deviceHeader)
              ) else {
            // Authentication owns the response for missing or malformed credentials. Such a
            // request cannot have performed a mutation, so it does not belong in replay state.
            routeUncached(request, from: connection, respond: respond)
            return
        }

        let now = Date()
        mutationReplayCache = mutationReplayCache.filter {
            now.timeIntervalSince($0.value.createdAt) < RemoteAccessDefaults.mutationReplayLifetime
        }
        let key = MutationReplayKey(
            requestID: requestID,
            bearerDigest: Data(SHA256.hash(data: Data(bearer.utf8))),
            deviceID: deviceID
        )
        let fingerprint = Self.mutationFingerprint(for: request)
        if var existing = mutationReplayCache[key] {
            guard existing.fingerprint == fingerprint else {
                respond(.respond(RemoteRouter.error(409, "Request id was reused")))
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
            .min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            mutationReplayCache.removeValue(forKey: oldestCompleted)
        }
        guard mutationReplayCache.count < RemoteAccessDefaults.maximumMutationReplayEntries else {
            respond(.respond(RemoteRouter.error(503, "Replay cache busy")))
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
                guard case .respond(var response) = decision else {
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
        from connection: RemoteConnection,
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

        // The one REST call: the share and its sessions.
        if request.method == "GET", path == RemoteRouter.apiSessionsPath {
            handleMe(request, respond: respond)
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
           let sessionID = RemoteRouter.resumeSessionID(forPath: path) {
            handleResume(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST", path == RemoteRouter.appThemePath {
            handleAppTheme(request, respond: respond)
            return
        }

        if request.method == "POST",
           let identity = RemoteRouter.appSettingIdentity(forPath: path) {
            handleAppSetting(
                request,
                identity: identity,
                respond: respond
            )
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.themeSessionID(forPath: path) {
            handleSessionTheme(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.renameSessionID(forPath: path) {
            handleRenameSession(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.pinnedSessionID(forPath: path) {
            handlePinnedSession(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.archivedSessionID(forPath: path) {
            handleArchivedSession(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.snoozedSessionID(forPath: path) {
            handleSnoozedSession(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.surfaceSessionID(forPath: path) {
            handleSessionSurface(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.shareSessionID(forPath: path) {
            handleCreateShare(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.unshareSessionID(forPath: path) {
            handleRevokeShares(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "POST",
           let sessionID = RemoteRouter.extensionPanelSessionID(forPath: path) {
            handleExtensionPanelAction(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let route = RemoteRouter.gitReviewRoute(forPath: path) {
            handleGitReview(
                request,
                sessionID: route.sessionID,
                mode: route.mode,
                respond: respond
            )
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.repositoryFilesSessionID(forPath: path) {
            handleRepositoryFiles(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.repositoryFileSessionID(forPath: path) {
            handleRepositoryFile(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.attachmentsSessionID(forPath: path) {
            handleAttachments(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.workspaceSessionID(forPath: path) {
            handleWorkspace(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.browserPreviewSessionID(forPath: path) {
            handleBrowserPreview(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.extensionPanelSessionID(forPath: path) {
            handleExtensionPanel(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.extensionPanelResourceSessionID(forPath: path) {
            handleExtensionPanelResource(request, sessionID: sessionID, respond: respond)
            return
        }

        if request.method == "GET",
           let sessionID = RemoteRouter.attachmentSessionID(forPath: path) {
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
        input.append(request.body)
        return Data(SHA256.hash(data: input))
    }

    func handleMessage(_ message: RemoteWebSocket.Message, from connection: RemoteConnection) {
        guard case .text(let data) = message,
              let parsed = try? JSONDecoder().decode(RemoteClientMessage.self, from: data) else {
            return
        }

        switch parsed.type {
        case "auth":
            authenticate(connection, message: parsed)
        case "input":
            handleInput(connection, data: parsed.data)
        case "submit":
            handleSubmit(
                connection,
                text: parsed.text,
                contextAttachments: parsed.contextAttachments,
                requestID: parsed.requestID
            )
        case "terminalSubmit":
            handleTerminalSubmit(connection, text: parsed.text, requestID: parsed.requestID)
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
        case "permission":
            handlePermission(
                connection,
                id: parsed.id,
                decision: parsed.decision
            )
        case "presence":
            handlePresence(connection, state: parsed.state)
        case "viewport":
            handleViewport(connection, cols: parsed.cols, rows: parsed.rows)
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
    }

    // MARK: - REST

    private func handleMe(_ request: HTTPRequest, respond: @escaping @Sendable (RemoteRouteDecision) -> Void) {
        guard let authorization = authorizeREST(request, respond: respond) else { return }

        DispatchQueue.main.async {
            let payload = self.services.mirrors.meResponse(for: authorization)
            respond(.respond(RemoteRouter.json(payload)))
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

        let loader = usageDashboardLoader ?? self.services.usageDashboard
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
              UsageDashboardProjectionDefaults.overviewRanges.contains(days) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        let loader = usageLimitLoader ?? self.services.usageLimit
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
              authorization.scope.covers(sessionID) else {
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
                      sessionCommands.resumeRemoteSession(sessionID) else {
                    respond(.respond(RemoteRouter.error(503, "Mac Not Ready")))
                    return
                }
            }
            respond(.respond(RemoteRouter.json(
                ["state": self.services.runtimeStatus.isRunning(sessionID: sessionID) ? "ready" : "starting"],
                status: 202,
                reason: "Accepted"
            )))
        }
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

        let prompt = creation.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteInboundPolicy.acceptsPrompt(prompt), !prompt.isEmpty,
              RemoteInboundPolicy.acceptsLaunchIdentifier(creation.projectID),
              RemoteInboundPolicy.acceptsLaunchIdentifier(creation.agentKind),
              creation.accountHandle.map(RemoteInboundPolicy.acceptsLaunchIdentifier) ?? true,
              creation.model.map(RemoteInboundPolicy.acceptsLaunchIdentifier) ?? true,
              creation.reasoningEffort.map(RemoteInboundPolicy.acceptsLaunchIdentifier) ?? true,
              creation.permissionMode.map(RemoteInboundPolicy.acceptsLaunchIdentifier) ?? true,
              creation.surface.isKnown else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            guard let projectID = ProjectID(uuidString: creation.projectID),
                  self.services.sessionQueries.project(withID: projectID) != nil,
                  let kind = AgentKind(rawValue: creation.agentKind) else {
                respond(.respond(RemoteRouter.error(422, "Unknown Launch Choice")))
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
                    respond(.respond(RemoteRouter.error(422, "Unknown Account")))
                    return
                }
                account = selected
            }
            let modelOptions = AgentModels.options(for: kind, account: account)
            if let model = creation.model,
               !modelOptions.contains(where: { $0.identifier == model }) {
                respond(.respond(RemoteRouter.error(422, "Unknown Model")))
                return
            }
            if let effort = creation.reasoningEffort {
                guard let option = modelOptions.first(where: { $0.identifier == creation.model }),
                      option.supports(reasoningEffort: effort) else {
                    respond(.respond(RemoteRouter.error(422, "Unknown Reasoning Effort")))
                    return
                }
            }
            let permissionMode = creation.permissionMode.flatMap(AgentPermissionMode.init(rawValue:))
            guard creation.permissionMode == nil
                    || (permissionMode != nil && kind.supportsPermissionModes) else {
                respond(.respond(RemoteRouter.error(422, "Unknown Permission Mode")))
                return
            }
            if creation.fastMode != nil {
                guard AgentModels.supportsFastMode(
                    kind: kind,
                    model: creation.model,
                    account: account
                ) else {
                    respond(.respond(RemoteRouter.error(422, "Unsupported Speed")))
                    return
                }
            }
            let usesNativeUI = creation.surface == .conversation
            guard !usesNativeUI || kind.supportsNativeUI else {
                respond(.respond(RemoteRouter.error(422, "Unsupported Surface")))
                return
            }

            // An isolated workspace is checked the same way the composer's checkbox is gated,
            // rather than being discovered as a failed provision after the session record
            // exists: the checkout has to be able to host a worktree, and the agent has to be
            // able to hand it back. Publication is refused outright — opening a change request
            // is a decision made while looking at the repository, not one a phone may post.
            let managedWorkspacePlan: ManagedWorkspacePlan?
            if let requested = creation.managedWorkspace {
                guard let delivery = ManagedWorkspaceDelivery(rawValue: requested.delivery),
                      requested.publication == nil,
                      let project = self.services.sessionQueries.project(withID: projectID),
                      ManagedGitWorkspace.canProvision(from: project),
                      ManagedWorkspaceEligibility.supportsFinishHandshake(
                          kind: kind,
                          usesNativeUI: usesNativeUI
                      ) else {
                    respond(.respond(RemoteRouter.error(422, "Unsupported Workspace")))
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
                prompt: prompt
            )
            guard let sessionID = self.sessionCommands?.startRemoteSession(launch) else {
                respond(.respond(RemoteRouter.error(503, "Mac Not Ready")))
                return
            }

            respond(.respond(RemoteRouter.json(
                RemoteCreateSessionResponseDTO(
                    sessionID: sessionID.uuidString,
                    me: self.services.mirrors.meResponse(for: authorization)
                ),
                status: 201,
                reason: "Created"
            )))
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
            guard let result = self.services.notifications.register(
                registration,
                deviceID: deviceID,
                authorization: authorization
            ) else {
                respond(.respond(RemoteRouter.error(422, "Invalid Device Token")))
                return
            }
            self.services.eventLog.recordRemoteEvent("Remote notifications registered", [
                "share": authorization.shareID,
                "device": deviceID,
                "delivery": result.delivery,
            ])
            MacRemoteDiagnostics.record(.notificationRegistrationReceived, fields: [
                .peer: MacRemoteDiagnostics.pseudonym(deviceID, prefix: "device"),
                .transport: result.delivery,
                .capability: authorization.capability.rawValue,
                .enabledKindCount: String(registration.enabledKinds.count),
            ])
            respond(.respond(RemoteRouter.json(result)))
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
              receiveClientDiagnostics(upload.records, upload.source, deviceID) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        let peer = MacRemoteDiagnostics.pseudonym(deviceID, prefix: "device")
        self.services.eventLog.recordRemoteEvent("Remote diagnostics received", [
            "source": upload.source.rawValue,
            "records": String(upload.records.count),
            "peer": peer,
        ])
        respond(.respond(RemoteRouter.json(
            RemoteDiagnosticUploadResponseDTO(acceptedRecords: upload.records.count)
        )))
    }

    private static func diagnosticSource(
        forClientHeader header: String?
    ) -> RemoteDiagnosticSource? {
        switch header?.lowercased() {
        case "threading-ios": return .iOSClient
        case "threading-web": return .browserClient
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
              ) else {
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
           existing.isBound(to: deviceID) {
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
                          == "threading-ios"
                  ) else {
                self?.queue.async { [weak self] in
                    self?.recordFailedAuth(reason: "invalid invitation", device: deviceID)
                    respond(.respond(RemoteRouter.error(401, "Invalid Invitation")))
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
        guard authorization.canManageHost else {
            respond(.respond(RemoteRouter.error(403, "Owner access required")))
            return
        }
        guard let deviceID = RemoteInboundPolicy.normalizedDeviceID(
            request.header(RemoteRouter.deviceHeader)
        ) else {
            respond(.respond(RemoteRouter.error(400, "Invalid device")))
            return
        }
        Task { @MainActor in
            do {
                guard let hostCommands = self.hostCommands else {
                    respond(.respond(RemoteRouter.error(503, "Hosted service unavailable")))
                    return
                }
                let credential = try await hostCommands.issueHostedDeviceCredential(
                    deviceID: deviceID
                )
                respond(.respond(RemoteRouter.json(
                    credential,
                    status: 201,
                    reason: "Created",
                    maximumBytes: 16 * 1024
                )))
                hostCommands.completeHostedPairingBootstrap()
            } catch {
                ThreadingLogger.remote.error(
                    "Hosted device credential issue failed code=service"
                )
                respond(.respond(RemoteRouter.error(503, "Hosted service unavailable")))
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
            case .applied(let themeID):
                appliedThemeID = themeID
            case .unknownTheme:
                respond(.respond(RemoteRouter.error(422, "Unknown Theme")))
                return
            }
            self.services.eventLog.recordRemoteEvent("App theme changed remotely", [
                "theme": appliedThemeID.rawValue,
                "device": request.header(RemoteRouter.deviceHeader) ?? "unknown",
            ])
            respond(.respond(RemoteRouter.json(
                self.services.mirrors.meResponse(for: authorization)
            )))
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
                    "setting": identity,
                    "device": request.header(RemoteRouter.deviceHeader) ?? "unknown",
                ])
                respond(.respond(RemoteRouter.json(
                    self.services.mirrors.meResponse(for: authorization)
                )))
            case .unknownSetting:
                respond(.respond(RemoteRouter.error(404, "Unknown Setting")))
            case .notMutable:
                respond(.respond(RemoteRouter.error(403, "Setting Not Mutable")))
            case .invalidValue:
                respond(.respond(RemoteRouter.error(422, "Invalid Setting Value")))
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
              authorization.scope.covers(sessionID) else {
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
                respond(.respond(RemoteRouter.error(503, "Persistence Unavailable")))
                return
            case .unsupportedValue:
                respond(.respond(RemoteRouter.error(422, "Unsupported Value")))
                return
            }
            self.services.eventLog.recordRemoteEvent("Session theme changed remotely", [
                "session": sessionID.uuidString,
                "theme": themeID?.rawValue ?? "inherit",
                "device": request.header(RemoteRouter.deviceHeader) ?? "unknown",
            ])
            respond(.respond(RemoteRouter.json(
                self.services.mirrors.meResponse(for: authorization)
            )))
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
                  self.services.sessionQueries.session(withID: sessionID) != nil else {
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
                respond(.respond(RemoteRouter.error(503, "Persistence Unavailable")))
                return
            case .unsupportedValue:
                respond(.respond(RemoteRouter.error(422, "Unsupported Value")))
                return
            }
            self.services.eventLog.recordRemoteEvent("Session renamed remotely", [
                "session": sessionID.uuidString,
                "device": request.header(RemoteRouter.deviceHeader) ?? "unknown",
            ])
            respond(.respond(RemoteRouter.json(
                self.services.mirrors.meResponse(for: authorization)
            )))
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
                  self.services.sessionQueries.session(withID: sessionID) != nil else {
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
                respond(.respond(RemoteRouter.error(503, "Persistence Unavailable")))
                return
            case .unsupportedValue:
                respond(.respond(RemoteRouter.error(422, "Unsupported Value")))
                return
            }
            self.sessionCommands?.refreshAfterRemoteSessionMutation(
                sessionID: sessionID,
                archived: false
            )
            respond(.respond(RemoteRouter.json(
                self.services.mirrors.meResponse(for: authorization)
            )))
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
                  self.services.sessionQueries.session(withID: sessionID) != nil else {
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
                            "session": sessionID.uuidString,
                            "device": request.header(RemoteRouter.deviceHeader) ?? "unknown",
                        ])
                    respond(.respond(RemoteRouter.json(
                        self.services.mirrors.meResponse(for: authorization)
                    )))
                case .failure(let failure):
                    let status: Int
                    if case .alreadyChanging = failure {
                        status = 409
                    } else if case .sessionNotFound = failure {
                        status = 404
                    } else if case .persistenceUnavailable = failure {
                        status = 503
                    } else {
                        status = 500
                    }
                    respond(.respond(RemoteRouter.error(status, failure.localizedDescription)))
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
                  !session.isArchived else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            if let rawDeadline = choice.snoozedUntil {
                let deadline = Date(timeIntervalSince1970: rawDeadline)
                guard deadline > Date(), deadline < Date().addingTimeInterval(366 * 86_400) else {
                    respond(.respond(RemoteRouter.error(422, "Invalid snooze deadline")))
                    return
                }
                self.services.snoozeCenter.snooze(sessionID, until: deadline)
            } else {
                self.services.snoozeCenter.unsnooze(sessionID)
            }
            respond(.respond(RemoteRouter.json(
                self.services.mirrors.meResponse(for: authorization)
            )))
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
                  let session = self.services.sessionQueries.session(withID: sessionID) else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }
            let usesNativeUI = choice.surface == .conversation
            guard !usesNativeUI || session.kind.supportsNativeUI else {
                respond(.respond(RemoteRouter.error(422, "Unsupported Surface")))
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
                respond(.respond(RemoteRouter.error(422, "Unsupported Surface")))
                return
            case .persistenceRefused:
                respond(.respond(RemoteRouter.error(503, "Persistence Unavailable")))
                return
            }
            self.services.eventLog.recordRemoteEvent("Session UI changed remotely", [
                "session": sessionID.uuidString,
                "surface": choice.surface.rawValue,
                "device": request.header(RemoteRouter.deviceHeader) ?? "unknown",
            ])
            respond(.respond(RemoteRouter.json(
                self.services.mirrors.meResponse(for: authorization)
            )))
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
        guard let capability = RemoteCapability(rawValue: choice.capability) else {
            respond(.respond(RemoteRouter.error(422, "Unknown Share Role")))
            return
        }

        DispatchQueue.main.async {
            guard let hostCommands = self.hostCommands else {
                respond(.respond(RemoteRouter.error(503, "Secure Relay Not Ready")))
                return
            }
            hostCommands.createSessionShare(
                for: sessionID,
                capability: capability,
                canApprovePermissions: choice.canApprovePermissions
            ) { result in
                switch result {
                case .success(let created):
                    respond(.respond(RemoteRouter.json(RemoteCreateShareResponseDTO(
                        url: created.url.absoluteString,
                        capability: capability.rawValue,
                        canApprovePermissions: created.canApprovePermissions,
                        expiresAt: created.expiresAt.timeIntervalSince1970,
                        me: self.services.mirrors.meResponse(for: authorization)
                    ))))
                case .failure:
                    respond(.respond(RemoteRouter.error(503, "Secure Relay Not Ready")))
                }
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
                respond(.respond(RemoteRouter.error(503, "Mac Not Ready")))
                return
            }
            hostCommands.revokeSessionShares(sessionID)
            respond(.respond(RemoteRouter.json(
                self.services.mirrors.meResponse(for: authorization)
            )))
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
                case .success(let files):
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
              RemoteInboundPolicy.acceptsRepositoryPath(path) else {
            respond(.respond(RemoteRouter.error(400, "Bad Request")))
            return
        }

        DispatchQueue.main.async {
            RemoteGitReviewBridge.repositoryFile(
                sessionID: sessionID,
                path: path
            ) { result in
                switch result {
                case .success(let file):
                    respond(.respond(RemoteRouter.json(file)))
                case .failure:
                    respond(.respond(RemoteRouter.error(404, "Not Found")))
                }
            }
        }
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
                   size >= 0, size <= RemoteAccessDefaults.maximumAttachmentBytes else {
                    return nil
                }
                return RemoteAttachmentDTO(
                    path: attachment.relativePath,
                    name: attachment.name,
                    kind: attachment.kind.rawValue,
                    byteCount: Int64(size),
                    modifiedAt: values.contentModificationDate,
                    origin: attachment.origin.rawValue,
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
              let tabID = UUID(uuidString: rawTabID) else {
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
              RemoteInboundPolicy.acceptsAttachmentID(attachmentID) else {
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
               size >= 0, size <= RemoteAccessDefaults.maximumAttachmentBytes else {
                respond(.respond(RemoteRouter.error(404, "Not Found")))
                return
            }

            let url = attachment.url
            let contentType = Self.attachmentContentType(for: url)
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
              ), RemoteInboundPolicy.acceptsExtensionIdentifier(action.actionID) else {
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
                case .success(let response):
                    payload = RemoteExtensionPanelActionResponseDTO(
                        processGeneration: item.processGeneration,
                        panel: response.panel,
                        message: response.message,
                        error: response.error
                    )
                case .failure(let error):
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
              RemoteInboundPolicy.acceptsExtensionResourcePath(path) else {
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
            ) else {
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
              authorization.scope == .allSessions else {
            respond(.respond(RemoteRouter.error(403, "Forbidden")))
            return nil
        }
        guard let sessionID = SessionID(uuidString: rawSessionID),
              authorization.scope.covers(sessionID) else {
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
              authorization.scope.covers(sessionID) else {
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
        case .authorized(let resolved):
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
        let authorization: RemoteAuthorization
        switch resolveAuthorization(for: message.token, device: rawDevice) {
        case .authorized(let resolved):
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

        guard let routed = connection.routedSessionID else {
            connection.sendClose(code: 4004, reason: "Unknown session")
            return
        }

        if routed == RemoteRouter.themeEventsRouteID {
            guard connection.authenticate(
                authorization: authorization,
                deviceID: device,
                deviceName: deviceName
            ) else { return }
            DispatchQueue.main.async {
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
            deviceName: deviceName
        ) else { return }

        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendClose(code: 4003, reason: "Share revoked")
                return
            }
            let attached = self.services.mirrors.attach(
                connection,
                to: sessionID,
                authorization: authorization
            )
            if attached {
                self.services.eventLog.recordRemoteEvent("Remote client connected", [
                    "session": sessionID.uuidString,
                    "capability": authorization.capability.rawValue,
                    "device": device ?? "unknown",
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
                    fields[.peer] = MacRemoteDiagnostics.pseudonym(
                        device,
                        prefix: "device"
                    )
                }
                MacRemoteDiagnostics.record(.socketConnected, fields: fields)
            } else {
                connection.sendClose(code: 4004, reason: "Session not available")
            }
        }
    }

    private func handleInput(_ connection: RemoteConnection, data: String?) {
        guard let authorization = connection.authorization, authorization.capability == .interact else {
            connection.sendText(#"{"type":"error","code":"forbidden"}"#)
            self.services.eventLog.recordRemoteEvent("Remote input refused", ["reason": "view-only"])
            return
        }
        guard let data, let routed = connection.routedSessionID, let sessionID = SessionID(uuidString: routed) else {
            return
        }
        guard RemoteInboundPolicy.acceptsTerminalInput(data) else {
            connection.sendText(encode(RemoteErrorDTO(code: "inputTooLarge")))
            return
        }

        let bytes = Array(data.utf8)
        let device = connection.deviceID
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                return
            }
            let accepted = self.services.mirrors.sendInput(
                bytes,
                to: sessionID,
                device: device,
                authorization: authorization
            )
            if !accepted {
                connection.sendText(self.encode(RemoteErrorDTO(code: "controlHeld")))
            }
        }
    }

    private func handleViewport(_ connection: RemoteConnection, cols: Int?, rows: Int?) {
        guard let authorization = connection.authorization,
              authorization.capability == .interact else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        switch Self.viewportRequest(
            cols: cols,
            rows: rows,
            routedSessionID: connection.routedSessionID
        ) {
        case .refused(let refusal):
            refuseViewport(connection, cols: cols, rows: rows, refusal: refusal)
        case .accepted(let cols, let rows, let sessionID):
            DispatchQueue.main.async {
                guard self.authorizer?.isCurrent(authorization) == true else {
                    connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                    return
                }
                self.services.mirrors.requestViewport(
                    from: connection,
                    sessionID: sessionID,
                    cols: cols,
                    rows: rows
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
              authorization.capability == .interact,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed) else {
            return
        }
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else { return }
            self.services.mirrors.releaseViewport(
                from: connection,
                sessionID: sessionID
            )
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
              limit.map({ (1...RemoteAccessDefaults.maximumRemoteConversationRows).contains($0) })
                ?? true else {
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
              let sessionID = SessionID(uuidString: routed) else {
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

    private func handleSubmit(
        _ connection: RemoteConnection,
        text: String?,
        contextAttachments: [RemoteConversationContextAttachmentDTO]?,
        requestID rawRequestID: String?
    ) {
        guard let authorization = connection.authorization, authorization.capability == .interact else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        guard let text, let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed) else {
            return
        }
        guard RemoteInboundPolicy.acceptsPrompt(text),
              RemoteInboundPolicy.acceptsContextAttachments(contextAttachments) else {
            connection.sendText(encode(RemoteErrorDTO(code: "promptTooLarge")))
            return
        }

        let requestID = rawRequestID.flatMap(RemoteInboundPolicy.normalizedMutationRequestID)
        if rawRequestID != nil, requestID == nil {
            connection.sendText(encode(RemoteErrorDTO(code: "invalidRequestID")))
            return
        }

        let device = connection.deviceID
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                return
            }
            let status = self.services.mirrors.submitPrompt(
                text,
                contextAttachments: contextAttachments,
                to: sessionID,
                device: device,
                authorization: authorization,
                requestID: requestID
            )
            guard let requestID else { return }
            connection.sendText(self.encode(RemotePromptSubmissionResultDTO(
                requestID: requestID,
                status: status
            )))
        }
    }

    private func handleTerminalSubmit(
        _ connection: RemoteConnection,
        text: String?,
        requestID rawRequestID: String?
    ) {
        guard let authorization = connection.authorization,
              authorization.capability == .interact else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed) else {
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
        DispatchQueue.main.async {
            guard self.authorizer?.isCurrent(authorization) == true else {
                connection.sendText(self.encode(RemoteErrorDTO(code: "forbidden")))
                return
            }
            let status = self.services.mirrors.submitTerminalLine(
                text,
                to: sessionID,
                device: device,
                authorization: authorization,
                requestID: requestID
            )
            connection.sendText(self.encode(RemotePromptSubmissionResultDTO(
                requestID: requestID,
                status: status
            )))
        }
    }

    private func handlePermission(
        _ connection: RemoteConnection,
        id: String?,
        decision: String?
    ) {
        guard let authorization = connection.authorization,
              authorization.canApprovePermissions else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        guard let id, let decision,
              RemoteInboundPolicy.acceptsPermissionID(id),
              decision == "allow" || decision == "deny",
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed) else {
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
                "session": sessionID.uuidString,
                "decision": decision,
                "device": connection.deviceID ?? "unknown",
            ])
            var fields: [RemoteDiagnosticField: String] = [
                .trace: id,
                .session: MacRemoteDiagnostics.pseudonym(
                    sessionID.uuidString,
                    prefix: "session"
                ),
                .result: decision,
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
              authorization.capability == .interact else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        let requestID = rawRequestID.flatMap(RemoteInboundPolicy.normalizedMutationRequestID)
        guard let requestID,
              let recipientID,
              RemoteInboundPolicy.acceptsAttentionRecipientID(recipientID),
              rawNote.map(RemoteInboundPolicy.acceptsAttentionNote) ?? true,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed) else {
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
              authorization.capability == .interact else {
            connection.sendText(encode(RemoteErrorDTO(code: "forbidden")))
            return
        }
        let requestID = rawRequestID.flatMap(RemoteInboundPolicy.normalizedMutationRequestID)
        guard let requestID,
              let rawAction,
              let action = RemoteInputControlAction(rawValue: rawAction),
              targetID.map(RemoteInboundPolicy.acceptsAttentionRecipientID) ?? true,
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed) else {
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

    private func handlePresence(_ connection: RemoteConnection, state: String?) {
        guard let authorization = connection.authorization,
              authorization.capability == .interact,
              let state, state == "typing" || state == "idle",
              let routed = connection.routedSessionID,
              let sessionID = SessionID(uuidString: routed) else {
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
        self.services.eventLog.recordRemoteEvent("Remote auth denied", ["reason": reason])
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
           authorization.isBound(to: device) {
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
        self.services.eventLog.recordRemoteEvent("Remote protocol mismatch", ["update": update.rawValue])
        return RemoteUpgradeRequiredDTO(update: update, message: message)
    }

    private func encode<Value: Encodable>(_ value: Value) -> String {
        do {
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        } catch {
            ThreadingLogger.remote.fault(
                "Remote server encoding failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return #"{"type":"error","code":"encodingFailed"}"#
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
