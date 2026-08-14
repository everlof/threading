import Foundation
import Network
import Security
import ThreadingExtensionKit

enum ExtensionHostServiceError: Error, LocalizedError {
    case unavailable
    case secureTokenUnavailable
    case missingCapability(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L10n.string("Threading’s extension host service is unavailable.")
        case .secureTokenUnavailable:
            return L10n.string("A secure extension authorization token could not be created.")
        case .missingCapability(let capability):
            return L10n.format(
                "The extension did not declare the required “%@” capability.",
                capability
            )
        }
    }
}

/// How a supervised extension reaches the broker.
///
/// `descriptor` is what the supported runner uses: a socket the child inherits needs no network
/// authority and has no port to guess. `loopback` is the experimental `sandbox-exec` path, which
/// cannot pass a descriptor because `Process` spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT` and has
/// no API for descriptors beyond the three standard streams.
enum ExtensionHostTransport: Sendable {
    case loopback
    case descriptor
}

struct ExtensionHostAuthorization: Sendable {
    let connection: ExtensionHostConnection
    let environment: [String: String]
    /// The host-created socket end a descriptor-mode launch must install as the child's
    /// `ExtensionHostDescriptorConnection.childDescriptorNumber`, and close in this process
    /// once the child holds it. Nil for loopback authorizations.
    let childDescriptor: Int32?

    init(
        connection: ExtensionHostConnection,
        environment: [String: String],
        childDescriptor: Int32? = nil
    ) {
        self.connection = connection
        self.environment = environment
        self.childDescriptor = childDescriptor
    }
}

/// Host-owned routing boundary for brokered extension-to-extension service calls.
///
/// The HTTP service authenticates and authorizes the consumer; the lifecycle manager resolves
/// the currently registered provider process. Neither side reaches into the other's storage.
@MainActor
protocol ExtensionServiceRouting: AnyObject {
    func invokeService(
        providerIdentifier: String,
        serviceID: String,
        serviceVersion: Int,
        callerExtensionIdentifier: String,
        arguments: ExtensionJSONValue,
        completion: @escaping @MainActor @Sendable (
            Result<ExtensionServiceResponse, Error>
        ) -> Void
    )
}

/// Host-owned bridge from an authenticated Wasm generation to its own declared companion.
///
/// Caller identity comes from the broker authority. The route never accepts a target extension
/// identifier from request data, so one extension cannot address another extension's worker.
@MainActor
protocol ExtensionCompanionRouting: AnyObject {
    func invokeCompanionOperation(
        extensionIdentifier: String,
        companionID: String,
        operationID: String,
        arguments: ExtensionJSONValue,
        completion: @escaping @MainActor @Sendable (
            Result<ExtensionCompanionOperationResponse, Error>
        ) -> Void
    )
}

/// Capability-gated host APIs for one supervised extension generation.
///
/// This is deliberately independent of MCP and of the extension's stdin/stdout request stream.
/// A random bearer token binds every request to an extension identifier, process generation,
/// stable extension order, and its manifest capabilities. Callers never submit those identities.
@MainActor
final class ExtensionHostService {
    static let shared = ExtensionHostService()

    private struct Authority {
        let extensionIdentifier: String
        let processGeneration: String
        let order: Int
        let capabilities: Set<ExtensionCapability>
        let serviceDependencies: Set<ExtensionServiceDependency>
        let networkGrants: [ExtensionNetworkGrant]
        let localization: ExtensionLocalizationResolver
    }

    private struct Failure: Encodable {
        let error: String
    }

    private static let host = "127.0.0.1"
    private static let componentPatchesPath = "/v1/component-patches"
    private static let identityResolutionsPath = "/v1/identity-resolutions"
    private static let servicesPathPrefix = "/v1/services/"
    private static let companionsPathPrefix = "/v1/companions/"
    private static let networkFetchPath = "/v1/network/fetch"
    private static let projectFilesQueryPath = "/v1/project-files/query"
    private static let secretsPath = "/v1/secrets"
    private static let secretsPathPrefix = "/v1/secrets/"
    private static let keyValuePath = "/v1/storage/kv"
    private static let keyValuePathPrefix = "/v1/storage/kv/"
    private static let cachePath = "/v1/storage/cache"
    private static let cachePathPrefix = "/v1/storage/cache/"
    /// A brokered cache write is base64 in JSON, which inflates the entry by a third. The
    /// allowance is the entry cap plus that inflation and the envelope, and still well under
    /// `MCPDefaults.maximumRequestBytes`.
    private static let maximumCacheRequestBytes = 6 * 1024 * 1024
    private static let maximumPublicationBytes = 1024 * 1024
    private static let maximumRetainedEvents = 1_000
    private static let maximumEventPageSize = 200
    private static let hostCapabilities: Set<ExtensionCapability> = [
        .componentCustomization,
        .hostProjectsRead,
        .hostProjectFilesRead,
        .hostSessionsRead,
        .hostSessionRuntimeRead,
        .hostRepositoriesRead,
        .hostProvidersRead,
        .hostAccountsPresentationRead,
        .hostEvents,
        .providerIconResolver,
        .accountIconResolver,
        .sessionIdentityRenderer,
        .servicesConsume,
        .companionOperations,
        .secrets,
        .networkBrokered
    ]
    /// Capabilities that qualify for a host connection **only** over the descriptor transport.
    ///
    /// Over loopback these are granted as a directory instead, so issuing a broker token for
    /// them there would widen what an extension can reach for no gain.
    private static let brokeredStorageCapabilities: Set<ExtensionCapability> = [
        .keyValueStorage,
        .cacheStorage
    ]
    private static let hostDataCapabilities: Set<ExtensionCapability> = [
        .hostProjectsRead,
        .hostProjectFilesRead,
        .hostSessionsRead,
        .hostSessionRuntimeRead,
        .hostRepositoriesRead,
        .hostProvidersRead,
        .hostAccountsPresentationRead,
        .hostEvents
    ]

    private weak var registry: ComponentCustomizationRegistry?
    private weak var identityRegistry: ExtensionIdentityResolverRegistry?
    private weak var serviceRouter: ExtensionServiceRouting?
    private weak var companionRouter: ExtensionCompanionRouting?
    private let snapshotProvider: ExtensionHostSnapshotProviding
    private let runtimeSnapshotProvider: ExtensionSessionRuntimeSnapshotProviding?
    private let secretStore: ExtensionSecretStoring
    private let networkBroker: ExtensionNetworkBrokering
    private let entropySource: EntropySource
    private weak var keyValueStore: ExtensionKeyValueStoring?
    private weak var cacheStore: ExtensionCacheStoring?
    private let storageRouter = ExtensionHostStorageRouter()
    private var baseURL: URL?
    private var authorities: [String: Authority] = [:]
    private var projectSnapshots: [String: ExtensionProjectSnapshot] = [:]
    private var sessionSnapshots: [String: ExtensionSessionSnapshot] = [:]
    private var providerSnapshots: [String: ExtensionProviderSnapshot] = [:]
    private var accountSnapshots: [String: ExtensionAccountSnapshot] = [:]
    private var eventJournal: [ExtensionHostEvent] = []
    private var currentCursor: Int64 = 0
    private var hasSnapshotBaseline = false
    private var appEvents: AppEventObservations?
    private var listener: NWListener?
    private var startupCompletion: (() -> Void)?
    private var connectionsByID: [ObjectIdentifier: MCPConnection] = [:]
    private var descriptorConnections: [String: ExtensionHostDescriptorConnection] = [:]
    private let queue = DispatchQueue(
        label: "codes.threading.extension-host",
        qos: .userInitiated
    )

    private init() {
        let provider = LiveExtensionHostSnapshotProvider()
        snapshotProvider = provider
        runtimeSnapshotProvider = provider
        secretStore = KeychainExtensionSecretStore.shared
        networkBroker = ExtensionNetworkBroker.live()
        entropySource = Self.secureEntropy
        ExtensionProjectFileBroker.shared.rootProvider = provider
    }

    /// Test seam which exercises authentication and routing without opening a listener.
    init(
        registry: ComponentCustomizationRegistry,
        baseURL: URL,
        snapshotProvider: ExtensionHostSnapshotProviding? = nil,
        runtimeSnapshotProvider: ExtensionSessionRuntimeSnapshotProviding? = nil,
        identityRegistry: ExtensionIdentityResolverRegistry? = nil,
        serviceRouter: ExtensionServiceRouting? = nil,
        companionRouter: ExtensionCompanionRouting? = nil,
        secretStore: ExtensionSecretStoring? = nil,
        keyValueStore: ExtensionKeyValueStoring? = nil,
        cacheStore: ExtensionCacheStoring? = nil,
        networkBroker: ExtensionNetworkBrokering? = nil,
        entropySource: @escaping EntropySource = ExtensionHostService.secureEntropy
    ) {
        self.registry = registry
        self.identityRegistry = identityRegistry ?? .shared
        self.serviceRouter = serviceRouter
        self.companionRouter = companionRouter
        self.baseURL = baseURL
        let snapshots = snapshotProvider ?? LiveExtensionHostSnapshotProvider()
        self.snapshotProvider = snapshots
        self.runtimeSnapshotProvider = runtimeSnapshotProvider
            ?? (snapshots as? ExtensionSessionRuntimeSnapshotProviding)
        if let roots = snapshots as? ExtensionProjectFileRootProviding {
            ExtensionProjectFileBroker.shared.rootProvider = roots
        }
        self.secretStore = secretStore ?? KeychainExtensionSecretStore.shared
        self.networkBroker = networkBroker ?? ExtensionNetworkBroker.live()
        self.entropySource = entropySource
        self.keyValueStore = keyValueStore
        self.cacheStore = cacheStore
        storageRouter.install(keyValue: keyValueStore, cache: cacheStore)
    }

    func installSessionRuntimeShellRootProvider(
        _ provider: @escaping (SessionID) -> pid_t?
    ) {
        (runtimeSnapshotProvider as? LiveExtensionHostSnapshotProvider)?
            .shellRootProvider = provider
    }

    func start(
        registry: ComponentCustomizationRegistry,
        identityRegistry: ExtensionIdentityResolverRegistry? = nil,
        completion: @escaping () -> Void
    ) {
        self.registry = registry
        self.identityRegistry = identityRegistry ?? .shared
        guard listener == nil else {
            completion()
            return
        }
        startupCompletion = completion

        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(Self.host),
                port: .any
            )
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.listenerStateDidChange(state, listener: listener)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: queue)
        } catch {
            baseURL = nil
            ThreadingLogger.extensions.error(
                "Extension host could not start: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            finishStartup()
        }
    }

    func installServiceRouter(_ router: ExtensionServiceRouting?) {
        serviceRouter = router
    }

    func installCompanionRouter(_ router: ExtensionCompanionRouting?) {
        companionRouter = router
    }

    /// The lifecycle manager owns the storage tree, so it supplies the stores rather than the
    /// service reaching for a singleton that tests would then have to work around.
    func installStorageStores(
        keyValue: ExtensionKeyValueStoring?,
        cache: ExtensionCacheStoring?
    ) {
        keyValueStore = keyValue
        cacheStore = cache
        storageRouter.install(keyValue: keyValue, cache: cache)
    }

    func stop() {
        let active = Array(authorities.values)
        authorities.removeAll()
        for authority in active {
            registry?.removePatches(
                extensionIdentifier: authority.extensionIdentifier,
                processGeneration: authority.processGeneration
            )
            identityRegistry?.remove(
                extensionIdentifier: authority.extensionIdentifier,
                processGeneration: authority.processGeneration
            )
        }

        for connection in descriptorConnections.values {
            connection.cancel()
        }
        descriptorConnections.removeAll()

        queue.sync {
            for connection in connectionsByID.values {
                connection.cancel()
            }
            connectionsByID.removeAll()
            listener?.cancel()
            listener = nil
        }
        baseURL = nil
        appEvents = nil
        projectSnapshots.removeAll()
        sessionSnapshots.removeAll()
        providerSnapshots.removeAll()
        accountSnapshots.removeAll()
        eventJournal.removeAll()
        currentCursor = 0
        hasSnapshotBaseline = false
    }

    func authorize(
        extensionIdentifier: String,
        processGeneration: String,
        order: Int,
        capabilities: Set<ExtensionCapability>,
        serviceDependencies: [ExtensionServiceDependency] = [],
        networkGrants: [ExtensionNetworkGrant] = [],
        localization: ExtensionLocalizationResolver = .init(strings: [:]),
        transport: ExtensionHostTransport = .loopback
    ) throws -> ExtensionHostAuthorization? {
        let qualifying = transport == .descriptor
            ? Self.hostCapabilities.union(Self.brokeredStorageCapabilities)
            : Self.hostCapabilities
        guard !capabilities.isDisjoint(with: qualifying) else {
            return nil
        }
        // A descriptor-mode authorization needs no listener: its socket is the whole channel.
        // Loopback cannot proceed without one, and failing here is what keeps a launch from
        // starting an extension that would silently have no host at all.
        guard let baseURL = baseURL ?? (transport == .descriptor
            ? ExtensionHostConnection.descriptorBaseURL
            : nil) else {
            throw ExtensionHostServiceError.unavailable
        }
        guard let token = Self.randomToken(using: entropySource) else {
            throw ExtensionHostServiceError.secureTokenUnavailable
        }
        if !capabilities.isDisjoint(with: Self.hostDataCapabilities) {
            beginObservingHostData()
            refreshSnapshotJournal()
        }
        authorities[token] = Authority(
            extensionIdentifier: extensionIdentifier,
            processGeneration: processGeneration,
            order: order,
            capabilities: capabilities,
            serviceDependencies: Set(serviceDependencies),
            networkGrants: networkGrants,
            localization: localization
        )

        switch transport {
        case .loopback:
            return ExtensionHostAuthorization(
                connection: ExtensionHostConnection(baseURL: baseURL, bearerToken: token),
                environment: [
                    ExtensionHostConnection.urlEnvironmentKey: baseURL.absoluteString,
                    ExtensionHostConnection.tokenEnvironmentKey: token
                ]
            )

        case .descriptor:
            guard let pair = ExtensionHostDescriptorConnection.makePair(
                queue: queue,
                handler: { [weak self] request, respond in
                    Task { @MainActor in
                        self?.route(request, respond: respond)
                    }
                },
                onClose: { [weak self] closed in
                    Task { @MainActor in
                        self?.descriptorConnections = self?.descriptorConnections.filter {
                            $0.value !== closed
                        } ?? [:]
                    }
                }
            ) else {
                authorities.removeValue(forKey: token)
                throw ExtensionHostServiceError.unavailable
            }
            descriptorConnections[token] = pair.connection
            let childNumber = ExtensionHostDescriptorConnection.childDescriptorNumber
            return ExtensionHostAuthorization(
                connection: ExtensionHostConnection(
                    baseURL: ExtensionHostConnection.descriptorBaseURL,
                    bearerToken: token,
                    descriptor: childNumber
                ),
                environment: [
                    ExtensionHostConnection.descriptorEnvironmentKey: String(childNumber),
                    ExtensionHostConnection.tokenEnvironmentKey: token
                ],
                childDescriptor: pair.childDescriptor
            )
        }
    }

    func revoke(
        extensionIdentifier: String,
        processGeneration: String
    ) {
        let revokedTokens = authorities.filter { _, authority in
            authority.extensionIdentifier == extensionIdentifier
                && authority.processGeneration == processGeneration
        }.keys
        authorities = authorities.filter { _, authority in
            authority.extensionIdentifier != extensionIdentifier
                || authority.processGeneration != processGeneration
        }
        // A revoked descriptor connection is closed rather than merely unauthenticated: the
        // child observes end-of-file immediately instead of discovering it on its next call.
        for token in revokedTokens {
            descriptorConnections.removeValue(forKey: token)?.cancel()
        }
        registry?.removePatches(
            extensionIdentifier: extensionIdentifier,
            processGeneration: processGeneration
        )
        identityRegistry?.remove(
            extensionIdentifier: extensionIdentifier,
            processGeneration: processGeneration
        )
        // File handles die with the token they were minted beside — the same rule, so a handle
        // cannot outlive the disclosure the user answered.
        ExtensionProjectFileBroker.shared.revoke(generation: processGeneration)
    }

    /// Internal for focused host tests; network connections call the same method.
    func route(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        guard let components = URLComponents(
            string: "http://localhost\(request.path)"
        ) else {
            respond(jsonFailure(status: 400, reason: "Bad Request", "Invalid request path."))
            return
        }
        let path = components.path
        let knownRoute = path == Self.componentPatchesPath
            || path == Self.identityResolutionsPath
            || path == "/v1/projects"
            || path.hasPrefix("/v1/projects/")
            || path == "/v1/sessions"
            || path.hasPrefix("/v1/sessions/")
            || path == "/v1/providers"
            || path.hasPrefix("/v1/providers/")
            || path == "/v1/accounts"
            || path.hasPrefix("/v1/accounts/")
            || path == "/v1/events"
            || path.hasPrefix(Self.servicesPathPrefix)
            || path.hasPrefix(Self.companionsPathPrefix)
            || path == Self.networkFetchPath
            || path == Self.projectFilesQueryPath
            || path == Self.secretsPath
            || path.hasPrefix(Self.secretsPathPrefix)
            || path == Self.keyValuePath
            || path.hasPrefix(Self.keyValuePathPrefix)
            || path == Self.cachePath
            || path.hasPrefix(Self.cachePathPrefix)
        guard knownRoute else {
            respond(.status(404, "Not Found"))
            return
        }
        guard let authority = authenticatedAuthority(for: request) else {
            respond(jsonFailure(status: 401, reason: "Unauthorized", "Invalid bearer token."))
            return
        }

        if request.method == "PUT", path == Self.componentPatchesPath {
            routeComponentPublication(request, authority: authority, respond: respond)
            return
        }
        if request.method == "PUT", path == Self.identityResolutionsPath {
            routeIdentityPublication(request, authority: authority, respond: respond)
            return
        }
        if request.method == "POST", path.hasPrefix(Self.servicesPathPrefix) {
            routeServiceCall(request, path: path, authority: authority, respond: respond)
            return
        }
        if request.method == "POST", path.hasPrefix(Self.companionsPathPrefix) {
            routeCompanionOperation(
                request,
                path: path,
                authority: authority,
                respond: respond
            )
            return
        }
        if request.method == "POST", path == Self.networkFetchPath {
            routeBrokeredFetch(request, authority: authority, respond: respond)
            return
        }
        if request.method == "POST", path == Self.projectFilesQueryPath {
            routeProjectFileQuery(request, authority: authority, respond: respond)
            return
        }
        if path == Self.secretsPath || path.hasPrefix(Self.secretsPathPrefix) {
            routeSecretRequest(
                request,
                path: path,
                authority: authority,
                respond: respond
            )
            return
        }
        if path == Self.keyValuePath || path.hasPrefix(Self.keyValuePathPrefix) {
            guard require(.keyValueStorage, for: authority, respond: respond) else { return }
            storageRouter.routeKeyValue(
                request,
                path: path,
                extensionIdentifier: authority.extensionIdentifier,
                respond: respond
            )
            return
        }
        if path == Self.cachePath || path.hasPrefix(Self.cachePathPrefix) {
            guard require(.cacheStorage, for: authority, respond: respond) else { return }
            storageRouter.routeCache(
                request,
                path: path,
                extensionIdentifier: authority.extensionIdentifier,
                maximumRequestBytes: Self.maximumCacheRequestBytes,
                respond: respond
            )
            return
        }

        guard request.method == "GET" else {
            respond(.status(405, "Method Not Allowed"))
            return
        }

        refreshSnapshotJournal()

        switch path {
        case "/v1/projects":
            guard require(.hostProjectsRead, for: authority, respond: respond) else { return }
            respond(jsonResponse(ExtensionProjectSnapshotPage(
                cursor: currentCursor,
                projects: visibleProjects(for: authority)
            )))

        case let value where value.hasPrefix("/v1/projects/"):
            guard require(.hostProjectsRead, for: authority, respond: respond) else { return }
            let identifier = decodedIdentifier(
                in: value,
                after: "/v1/projects/"
            )
            guard !identifier.isEmpty, let project = projectSnapshots[identifier] else {
                respond(jsonFailure(status: 404, reason: "Not Found", "Project not found."))
                return
            }
            respond(jsonResponse(ExtensionProjectSnapshotResult(
                cursor: currentCursor,
                project: visible(project: project, for: authority)
            )))

        case "/v1/sessions":
            guard require(.hostSessionsRead, for: authority, respond: respond) else { return }
            respond(jsonResponse(ExtensionSessionSnapshotPage(
                cursor: currentCursor,
                sessions: sessionSnapshots.values.sorted { $0.id < $1.id }
            )))

        case let value where value.hasPrefix("/v1/sessions/") && value.hasSuffix("/runtime"):
            guard require(
                .hostSessionRuntimeRead,
                for: authority,
                respond: respond
            ) else { return }
            let encoded = String(
                value.dropFirst("/v1/sessions/".count).dropLast("/runtime".count)
            )
            let identifier = encoded.removingPercentEncoding ?? encoded
            guard !identifier.isEmpty, sessionSnapshots[identifier] != nil else {
                respond(jsonFailure(status: 404, reason: "Not Found", "Session not found."))
                return
            }
            guard let runtimeSnapshotProvider else {
                respond(jsonFailure(
                    status: 503,
                    reason: "Service Unavailable",
                    "Session runtime readings are unavailable."
                ))
                return
            }
            runtimeSnapshotProvider.sessionRuntimeSnapshot(for: identifier) { snapshot in
                guard snapshot.sessionID == identifier,
                      snapshot.version == ExtensionSessionRuntimeSnapshot.currentVersion else {
                    respond(self.jsonFailure(
                        status: 502,
                        reason: "Bad Gateway",
                        "The runtime provider returned a different session contract."
                    ))
                    return
                }
                respond(self.jsonResponse(snapshot))
            }

        case let value where value.hasPrefix("/v1/sessions/"):
            guard require(.hostSessionsRead, for: authority, respond: respond) else { return }
            let identifier = decodedIdentifier(
                in: value,
                after: "/v1/sessions/"
            )
            guard !identifier.isEmpty, let session = sessionSnapshots[identifier] else {
                respond(jsonFailure(status: 404, reason: "Not Found", "Session not found."))
                return
            }
            respond(jsonResponse(ExtensionSessionSnapshotResult(
                cursor: currentCursor,
                session: session
            )))

        case "/v1/providers":
            guard require(.hostProvidersRead, for: authority, respond: respond) else { return }
            respond(jsonResponse(ExtensionProviderSnapshotPage(
                cursor: currentCursor,
                providers: providerSnapshots.values.sorted { $0.id < $1.id }
            )))

        case let value where value.hasPrefix("/v1/providers/"):
            guard require(.hostProvidersRead, for: authority, respond: respond) else { return }
            let identifier = decodedIdentifier(
                in: value,
                after: "/v1/providers/"
            )
            guard !identifier.isEmpty, let provider = providerSnapshots[identifier] else {
                respond(jsonFailure(status: 404, reason: "Not Found", "Provider not found."))
                return
            }
            respond(jsonResponse(ExtensionProviderSnapshotResult(
                cursor: currentCursor,
                provider: provider
            )))

        case "/v1/accounts":
            guard require(
                .hostAccountsPresentationRead,
                for: authority,
                respond: respond
            ) else { return }
            respond(jsonResponse(ExtensionAccountSnapshotPage(
                cursor: currentCursor,
                accounts: accountSnapshots.values.sorted { $0.id < $1.id }
            )))

        case let value where value.hasPrefix("/v1/accounts/"):
            guard require(
                .hostAccountsPresentationRead,
                for: authority,
                respond: respond
            ) else { return }
            let identifier = decodedIdentifier(
                in: value,
                after: "/v1/accounts/"
            )
            guard !identifier.isEmpty, let account = accountSnapshots[identifier] else {
                respond(jsonFailure(status: 404, reason: "Not Found", "Account not found."))
                return
            }
            respond(jsonResponse(ExtensionAccountSnapshotResult(
                cursor: currentCursor,
                account: account
            )))

        case "/v1/events":
            guard require(.hostEvents, for: authority, respond: respond) else { return }
            routeEvents(queryItems: components.queryItems ?? [], respond: respond)

        default:
            respond(.status(404, "Not Found"))
        }
    }

    /// Bounded project-file enumeration.
    ///
    /// A POST rather than a GET with query items: the query is a value with a scope, a filter list
    /// and a cursor, and encoding that into a URL is how a broker ends up parsing a path.
    private func routeProjectFileQuery(
        _ request: HTTPRequest,
        authority: Authority,
        respond: @escaping (HTTPResponse) -> Void
    ) {
        guard require(.hostProjectFilesRead, for: authority, respond: respond) else { return }
        let body = request.body
        guard body.count <= Self.maximumPublicationBytes else {
            respond(jsonFailure(status: 413, reason: "Payload Too Large", "Query is too large."))
            return
        }
        guard let query = try? JSONDecoder().decode(ExtensionFileQuery.self, from: body) else {
            respond(jsonFailure(status: 400, reason: "Bad Request", "Invalid file query."))
            return
        }
        // The snapshot is refreshed first, exactly as the GET routes do. Without it, an
        // extension whose very first call is a file query is answered from an empty journal and
        // told its own project does not exist.
        refreshSnapshotJournal()
        // The project must be one this extension can already see. Enumeration is a *narrower*
        // authority than the snapshot it names, never a way around the snapshot's own filtering.
        guard visibleProjects(for: authority).contains(where: { $0.id == query.projectID }) else {
            respond(jsonFailure(status: 404, reason: "Not Found", "Project not found."))
            return
        }

        let identifier = authority.extensionIdentifier
        let generation = authority.processGeneration
        Task { @MainActor in
            do {
                let page = try await ExtensionProjectFileBroker.shared.page(
                    for: query,
                    extensionIdentifier: identifier,
                    generation: generation
                )
                respond(self.jsonResponse(page))
            } catch let error as ExtensionValidationError {
                respond(self.jsonFailure(
                    status: 400,
                    reason: "Bad Request",
                    error.localizedDescription
                ))
            } catch let error as ExtensionProjectFileError {
                let status = error == .unavailable ? 503 : 400
                respond(self.jsonFailure(
                    status: status,
                    reason: status == 503 ? "Service Unavailable" : "Bad Request",
                    error.localizedDescription
                ))
            } catch {
                respond(self.jsonFailure(
                    status: 500,
                    reason: "Internal Server Error",
                    error.localizedDescription
                ))
            }
        }
    }

    private func routeSecretRequest(
        _ request: HTTPRequest,
        path: String,
        authority: Authority,
        respond: (HTTPResponse) -> Void
    ) {
        guard require(.secrets, for: authority, respond: respond) else { return }

        if path == Self.secretsPath {
            guard request.method == "GET" else {
                respond(.status(405, "Method Not Allowed"))
                return
            }
            do {
                let keys = try secretStore.keys(
                    extensionIdentifier: authority.extensionIdentifier
                )
                guard keys.count <= ExtensionSecretConstraints.maximumKeys else {
                    respond(secretStoreFailure(
                        ExtensionSecretStoreError.tooManyKeys(
                            maximum: ExtensionSecretConstraints.maximumKeys
                        )
                    ))
                    return
                }
                try keys.forEach {
                    try ExtensionSecretConstraints.validate(key: $0)
                }
                respond(jsonResponse(ExtensionSecretKeyList(
                    keys: keys.sorted()
                )))
            } catch {
                respond(secretStoreFailure(error))
            }
            return
        }

        let key = decodedIdentifier(in: path, after: Self.secretsPathPrefix)
        do {
            try ExtensionSecretConstraints.validate(key: key)
        } catch {
            respond(jsonFailure(
                status: 400,
                reason: "Bad Request",
                "Invalid secret key."
            ))
            return
        }

        switch request.method {
        case "GET":
            do {
                let value = try secretStore.data(
                    extensionIdentifier: authority.extensionIdentifier,
                    key: key
                )
                if let value {
                    try ExtensionSecretConstraints.validate(value: value)
                }
                respond(jsonResponse(ExtensionSecretResult(
                    value: value
                )))
            } catch {
                respond(secretStoreFailure(error))
            }

        case "PUT":
            guard request.header("content-type")?
                .lowercased()
                .hasPrefix("application/json") == true else {
                respond(jsonFailure(
                    status: 415,
                    reason: "Unsupported Media Type",
                    "Expected application/json."
                ))
                return
            }
            guard request.body.count <= 96 * 1024 else {
                respond(jsonFailure(
                    status: 413,
                    reason: "Payload Too Large",
                    "The encoded secret request is too large."
                ))
                return
            }
            do {
                let write = try JSONDecoder().decode(
                    ExtensionSecretWrite.self,
                    from: request.body
                )
                try write.validate()
                try secretStore.setData(
                    write.value,
                    extensionIdentifier: authority.extensionIdentifier,
                    key: key
                )
                respond(.status(204, "No Content"))
            } catch is DecodingError {
                respond(jsonFailure(
                    status: 400,
                    reason: "Bad Request",
                    "Invalid secret request."
                ))
            } catch is ExtensionSecretError {
                respond(jsonFailure(
                    status: 413,
                    reason: "Payload Too Large",
                    "The secret value is too large."
                ))
            } catch is ExtensionValidationError {
                respond(jsonFailure(
                    status: 422,
                    reason: "Unprocessable Content",
                    "The secret protocol version is unsupported."
                ))
            } catch {
                respond(secretStoreFailure(error))
            }

        case "DELETE":
            do {
                try secretStore.remove(
                    extensionIdentifier: authority.extensionIdentifier,
                    key: key
                )
                respond(.status(204, "No Content"))
            } catch {
                respond(secretStoreFailure(error))
            }

        default:
            respond(.status(405, "Method Not Allowed"))
        }
    }

    /// Brokered key-value storage: the whole store on `GET`, one key per `PUT`/`DELETE`.
    ///
    /// The limits are enforced here rather than in the extension because this is where the
    /// authority is. The SDK keeps its own pre-checks so an obvious mistake answers without a
    /// round trip, but a client that skipped them still cannot exceed a quota.
    private func routeKeyValueRequest(
        _ request: HTTPRequest,
        path: String,
        authority: Authority,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        guard require(.keyValueStorage, for: authority, respond: respond) else { return }
        guard let keyValueStore else {
            respond(jsonFailure(
                status: 503,
                reason: "Service Unavailable",
                "Extension key-value storage is unavailable."
            ))
            return
        }

        if path == Self.keyValuePath {
            guard request.method == "GET" else {
                respond(.status(405, "Method Not Allowed"))
                return
            }
            do {
                respond(jsonResponse(ExtensionKeyValueSnapshot(
                    values: try keyValueStore.keyValues(
                        extensionIdentifier: authority.extensionIdentifier
                    )
                )))
            } catch {
                respond(keyValueFailure(error))
            }
            return
        }

        let key = decodedIdentifier(in: path, after: Self.keyValuePathPrefix)
        guard !key.isEmpty, (try? ExtensionKeyValueStore.validate(key: key)) != nil else {
            respond(jsonFailure(status: 400, reason: "Bad Request", "Invalid storage key."))
            return
        }

        switch request.method {
        case "PUT":
            guard request.header("content-type")?
                .lowercased()
                .hasPrefix("application/json") == true else {
                respond(jsonFailure(
                    status: 415,
                    reason: "Unsupported Media Type",
                    "Expected application/json."
                ))
                return
            }
            guard request.body.count <= ExtensionKeyValueStore.maximumStoreBytes else {
                respond(jsonFailure(
                    status: 413,
                    reason: "Payload Too Large",
                    "The value exceeds the key-value store quota."
                ))
                return
            }
            do {
                let write = try JSONDecoder().decode(
                    ExtensionKeyValueWrite.self,
                    from: request.body
                )
                guard write.protocolVersion
                    == ExtensionKeyValueWrite.currentProtocolVersion else {
                    respond(jsonFailure(
                        status: 422,
                        reason: "Unprocessable Content",
                        "The key-value protocol version is unsupported."
                    ))
                    return
                }
                try keyValueStore.setKeyValue(
                    write.value,
                    extensionIdentifier: authority.extensionIdentifier,
                    key: key
                )
                respond(.status(204, "No Content"))
            } catch is DecodingError {
                respond(jsonFailure(
                    status: 400,
                    reason: "Bad Request",
                    "Invalid key-value request."
                ))
            } catch {
                respond(keyValueFailure(error))
            }

        case "DELETE":
            do {
                try keyValueStore.removeKeyValue(
                    extensionIdentifier: authority.extensionIdentifier,
                    key: key
                )
                respond(.status(204, "No Content"))
            } catch {
                respond(keyValueFailure(error))
            }

        default:
            respond(.status(405, "Method Not Allowed"))
        }
    }

    /// Brokered cache storage: names on `GET` of the collection, one entry per name otherwise.
    ///
    /// A miss is a 200 carrying a null value rather than a 404, because a cache miss is an
    /// ordinary answer here — Threading may reclaim any entry at any moment, and an extension
    /// that had to tell "absent" from "refused" by status code would get that wrong.
    private func routeCacheRequest(
        _ request: HTTPRequest,
        path: String,
        authority: Authority,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        guard require(.cacheStorage, for: authority, respond: respond) else { return }
        guard let cacheStore else {
            respond(jsonFailure(
                status: 503,
                reason: "Service Unavailable",
                "Extension cache storage is unavailable."
            ))
            return
        }

        if path == Self.cachePath {
            guard request.method == "GET" else {
                respond(.status(405, "Method Not Allowed"))
                return
            }
            do {
                respond(jsonResponse(ExtensionCacheListing(
                    names: try cacheStore.cacheNames(
                        extensionIdentifier: authority.extensionIdentifier
                    )
                )))
            } catch {
                respond(cacheFailure(error))
            }
            return
        }

        let name = decodedIdentifier(in: path, after: Self.cachePathPrefix)
        guard !name.isEmpty, (try? ExtensionCacheStore.validate(name: name)) != nil else {
            respond(jsonFailure(status: 400, reason: "Bad Request", "Invalid cache name."))
            return
        }

        switch request.method {
        case "GET":
            do {
                respond(jsonResponse(ExtensionCacheEntry(
                    value: try cacheStore.cacheData(
                        extensionIdentifier: authority.extensionIdentifier,
                        name: name
                    )
                )))
            } catch {
                respond(cacheFailure(error))
            }

        case "PUT":
            guard request.header("content-type")?
                .lowercased()
                .hasPrefix("application/json") == true else {
                respond(jsonFailure(
                    status: 415,
                    reason: "Unsupported Media Type",
                    "Expected application/json."
                ))
                return
            }
            guard request.body.count <= Self.maximumCacheRequestBytes else {
                respond(jsonFailure(
                    status: 413,
                    reason: "Payload Too Large",
                    "The cache entry exceeds its size limit."
                ))
                return
            }
            do {
                let write = try JSONDecoder().decode(
                    ExtensionCacheWrite.self,
                    from: request.body
                )
                guard write.protocolVersion
                    == ExtensionCacheWrite.currentProtocolVersion else {
                    respond(jsonFailure(
                        status: 422,
                        reason: "Unprocessable Content",
                        "The cache protocol version is unsupported."
                    ))
                    return
                }
                guard write.value.count <= ExtensionCacheStore.maximumEntryBytes else {
                    respond(jsonFailure(
                        status: 413,
                        reason: "Payload Too Large",
                        "The cache entry exceeds its size limit."
                    ))
                    return
                }
                try cacheStore.setCacheData(
                    write.value,
                    extensionIdentifier: authority.extensionIdentifier,
                    name: name
                )
                respond(.status(204, "No Content"))
            } catch is DecodingError {
                respond(jsonFailure(
                    status: 400,
                    reason: "Bad Request",
                    "Invalid cache request."
                ))
            } catch {
                respond(cacheFailure(error))
            }

        case "DELETE":
            do {
                try cacheStore.removeCacheData(
                    extensionIdentifier: authority.extensionIdentifier,
                    name: name
                )
                respond(.status(204, "No Content"))
            } catch {
                respond(cacheFailure(error))
            }

        default:
            respond(.status(405, "Method Not Allowed"))
        }
    }

    private func cacheFailure(_ error: Error) -> HTTPResponse {
        switch error as? ExtensionStorageError {
        case .invalidName:
            return jsonFailure(status: 400, reason: "Bad Request", "Invalid cache name.")
        case .quotaExceeded:
            return jsonFailure(
                status: 413,
                reason: "Payload Too Large",
                "The extension cache is full."
            )
        default:
            ThreadingLogger.extensions.error(
                "Extension cache operation failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return jsonFailure(
                status: 500,
                reason: "Internal Server Error",
                "The extension cache is unavailable."
            )
        }
    }

    /// Maps the store's own errors onto the status codes the SDK translates back into the same
    /// `ExtensionStorageError` cases the directory backing raises.
    private func keyValueFailure(_ error: Error) -> HTTPResponse {
        switch error as? ExtensionStorageError {
        case .invalidKey:
            return jsonFailure(status: 400, reason: "Bad Request", "Invalid storage key.")
        case .tooManyKeys:
            return jsonFailure(
                status: 409,
                reason: "Conflict",
                "The key-value store is full."
            )
        case .quotaExceeded:
            return jsonFailure(
                status: 413,
                reason: "Payload Too Large",
                "The key-value store exceeds its quota."
            )
        default:
            ThreadingLogger.extensions.error(
                "Extension key-value operation failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return jsonFailure(
                status: 500,
                reason: "Internal Server Error",
                "The extension key-value store is unavailable."
            )
        }
    }

    private func secretStoreFailure(_ error: Error) -> HTTPResponse {
        ThreadingLogger.extensions.error(
                "Extension Keychain operation failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
        )
        return jsonFailure(
            status: 500,
            reason: "Internal Server Error",
            "The extension secret store is unavailable."
        )
    }

    private func routeCompanionOperation(
        _ request: HTTPRequest,
        path: String,
        authority: Authority,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        guard require(.companionOperations, for: authority, respond: respond) else { return }
        guard request.header("content-type")?
            .lowercased()
            .hasPrefix("application/json") == true else {
            respond(jsonFailure(
                status: 415,
                reason: "Unsupported Media Type",
                "Expected application/json."
            ))
            return
        }
        guard request.body.count <= ExtensionCompanionSupervisor.maximumLineBytes else {
            respond(jsonFailure(
                status: 413,
                reason: "Payload Too Large",
                "A companion operation may not exceed "
                    + "\(ExtensionCompanionSupervisor.maximumLineBytes) bytes."
            ))
            return
        }

        let suffix = path.dropFirst(Self.companionsPathPrefix.count)
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[1] == "operations",
              let companionID = String(parts[0]).removingPercentEncoding,
              let operationID = String(parts[2]).removingPercentEncoding,
              !companionID.isEmpty,
              !operationID.isEmpty else {
            respond(jsonFailure(
                status: 400,
                reason: "Bad Request",
                "Invalid companion operation path."
            ))
            return
        }

        let call: ExtensionCompanionOperationCall
        do {
            call = try JSONDecoder().decode(
                ExtensionCompanionOperationCall.self,
                from: request.body
            )
            try call.validate()
        } catch {
            let detail = (error as? ExtensionValidationError)?.description
                ?? error.localizedDescription
            respond(jsonFailure(
                status: 422,
                reason: "Unprocessable Content",
                detail
            ))
            return
        }
        guard let companionRouter else {
            respond(jsonFailure(
                status: 503,
                reason: "Service Unavailable",
                "The companion broker is unavailable."
            ))
            return
        }

        companionRouter.invokeCompanionOperation(
            extensionIdentifier: authority.extensionIdentifier,
            companionID: companionID,
            operationID: operationID,
            arguments: call.arguments
        ) { [weak self] result in
            guard let self else {
                respond(.status(503, "Service Unavailable"))
                return
            }
            switch result {
            case .failure(let error):
                respond(self.jsonFailure(
                    status: 502,
                    reason: "Bad Gateway",
                    error.localizedDescription
                ))
            case .success(let response):
                do {
                    try response.validate()
                } catch {
                    respond(self.jsonFailure(
                        status: 502,
                        reason: "Bad Gateway",
                        "The companion returned an invalid operation response."
                    ))
                    return
                }
                guard response.operationID == operationID,
                      response.error == nil,
                      let value = response.value else {
                    respond(self.jsonFailure(
                        status: 502,
                        reason: "Bad Gateway",
                        response.error ?? "The companion returned no value."
                    ))
                    return
                }
                respond(self.jsonResponse(ExtensionCompanionOperationCallResult(
                    companionID: companionID,
                    operationID: operationID,
                    value: value
                )))
            }
        }
    }

    /// The brokered network fetch.
    ///
    /// The fetch runs host-side, so the capability grants *questions*, never a socket and
    /// never a token. The bound is the manifest's own `networkGrants`: the URL's host and the
    /// method must match a declared grant — the same list the user read in the install
    /// dialog. When the matching grant names a credential provider, the broker attaches the
    /// user's best connected credential and reports which tier answered. A completed HTTP
    /// exchange returns whatever status the server gave (a 404 is an answer, not a broker
    /// error); only transport failure returns as `failure` in the envelope.
    private func routeBrokeredFetch(
        _ request: HTTPRequest,
        authority: Authority,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        guard require(.networkBrokered, for: authority, respond: respond) else { return }
        guard request.header("content-type")?
            .lowercased()
            .hasPrefix("application/json") == true else {
            respond(jsonFailure(
                status: 415,
                reason: "Unsupported Media Type",
                "Expected application/json."
            ))
            return
        }
        guard request.body.count <= Self.maximumPublicationBytes else {
            respond(jsonFailure(
                status: 413,
                reason: "Payload Too Large",
                "A brokered fetch may not exceed 1 MiB."
            ))
            return
        }

        let call: ExtensionBrokeredFetchRequest
        do {
            call = try JSONDecoder().decode(
                ExtensionBrokeredFetchRequest.self,
                from: request.body
            )
            try call.validate()
        } catch {
            let detail = (error as? ExtensionValidationError)?.description
                ?? error.localizedDescription
            respond(jsonFailure(status: 422, reason: "Unprocessable Content", detail))
            return
        }

        guard let host = URLComponents(string: call.url)?.host?.lowercased(),
              let grant = authority.networkGrants.first(where: { $0.host == host }) else {
            respond(jsonFailure(
                status: 403,
                reason: "Forbidden",
                "The URL's host was not declared in this extension's network grants."
            ))
            return
        }
        guard grant.methods.contains(call.method) else {
            respond(jsonFailure(
                status: 403,
                reason: "Forbidden",
                "The method was not declared for this host's network grant."
            ))
            return
        }

        networkBroker.fetch(
            request: call,
            credentialProvider: grant.credential
        ) { [weak self] result in
            guard let self else {
                respond(.status(503, "Service Unavailable"))
                return
            }
            switch result {
            case .success(let reading):
                respond(self.jsonResponse(ExtensionBrokeredFetchResult(
                    response: ExtensionBrokeredFetchResponse(
                        status: reading.status,
                        headers: reading.headers,
                        bodyBase64: reading.body.base64EncodedString(),
                        credential: reading.credential.rawValue
                    )
                )))
            case .failure(let failure):
                respond(self.jsonResponse(ExtensionBrokeredFetchResult(
                    failure: ExtensionBrokeredFetchFailure(
                        message: failure.message,
                        credential: failure.credential.rawValue
                    )
                )))
            }
        }
    }

    private func routeServiceCall(
        _ request: HTTPRequest,
        path: String,
        authority: Authority,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        guard require(.servicesConsume, for: authority, respond: respond) else { return }
        guard request.header("content-type")?
            .lowercased()
            .hasPrefix("application/json") == true else {
            respond(jsonFailure(
                status: 415,
                reason: "Unsupported Media Type",
                "Expected application/json."
            ))
            return
        }
        guard request.body.count <= Self.maximumPublicationBytes else {
            respond(jsonFailure(
                status: 413,
                reason: "Payload Too Large",
                "A service call may not exceed 1 MiB."
            ))
            return
        }

        let suffix = path.dropFirst(Self.servicesPathPrefix.count)
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let providerIdentifier = String(parts[0]).removingPercentEncoding,
              let serviceID = String(parts[1]).removingPercentEncoding,
              !providerIdentifier.isEmpty,
              !serviceID.isEmpty else {
            respond(jsonFailure(status: 400, reason: "Bad Request", "Invalid service path."))
            return
        }
        guard providerIdentifier != authority.extensionIdentifier else {
            respond(jsonFailure(
                status: 409,
                reason: "Conflict",
                "An extension cannot call its own brokered service."
            ))
            return
        }

        let call: ExtensionServiceCall
        do {
            call = try JSONDecoder().decode(ExtensionServiceCall.self, from: request.body)
            try call.validate()
        } catch {
            let detail = (error as? ExtensionValidationError)?.description
                ?? error.localizedDescription
            respond(jsonFailure(status: 422, reason: "Unprocessable Content", detail))
            return
        }

        let dependency = ExtensionServiceDependency(
            providerIdentifier: providerIdentifier,
            serviceID: serviceID,
            version: call.serviceVersion
        )
        guard authority.serviceDependencies.contains(where: {
            $0.providerIdentifier == dependency.providerIdentifier
                && $0.serviceID == dependency.serviceID
                && $0.version == dependency.version
        }) else {
            respond(jsonFailure(
                status: 403,
                reason: "Forbidden",
                "The exact service dependency was not declared."
            ))
            return
        }
        guard let serviceRouter else {
            respond(jsonFailure(
                status: 503,
                reason: "Service Unavailable",
                "The extension service broker is unavailable."
            ))
            return
        }

        serviceRouter.invokeService(
            providerIdentifier: providerIdentifier,
            serviceID: serviceID,
            serviceVersion: call.serviceVersion,
            callerExtensionIdentifier: authority.extensionIdentifier,
            arguments: call.arguments
        ) { [weak self] result in
            guard let self else {
                respond(.status(503, "Service Unavailable"))
                return
            }
            switch result {
            case .failure(let error):
                respond(self.jsonFailure(
                    status: 503,
                    reason: "Service Unavailable",
                    error.localizedDescription
                ))
            case .success(let response):
                do {
                    try response.validate()
                } catch {
                    respond(self.jsonFailure(
                        status: 502,
                        reason: "Bad Gateway",
                        "The provider returned an invalid service response."
                    ))
                    return
                }
                guard response.serviceID == serviceID,
                      response.serviceVersion == call.serviceVersion else {
                    respond(self.jsonFailure(
                        status: 502,
                        reason: "Bad Gateway",
                        "The provider returned a different service contract."
                    ))
                    return
                }
                guard response.error == nil, let value = response.value else {
                    respond(self.jsonFailure(
                        status: 502,
                        reason: "Bad Gateway",
                        response.error ?? "The provider returned no value."
                    ))
                    return
                }
                respond(self.jsonResponse(ExtensionServiceCallResult(
                    providerIdentifier: providerIdentifier,
                    serviceID: serviceID,
                    serviceVersion: call.serviceVersion,
                    value: value
                )))
            }
        }
    }

    /// Re-reads the provider and appends only semantic differences. Internal so focused tests
    /// can move a fake provider forward without coupling themselves to notifications.
    func refreshSnapshotJournal() {
        let nextProjects = Dictionary(
            uniqueKeysWithValues: snapshotProvider.projectSnapshots().map { ($0.id, $0) }
        )
        let nextSessions = Dictionary(
            uniqueKeysWithValues: snapshotProvider.sessionSnapshots().map { ($0.id, $0) }
        )
        let nextProviders = Dictionary(
            uniqueKeysWithValues: snapshotProvider.providerSnapshots().map { ($0.id, $0) }
        )
        let nextAccounts = Dictionary(
            uniqueKeysWithValues: snapshotProvider.accountSnapshots().map { ($0.id, $0) }
        )

        guard hasSnapshotBaseline else {
            projectSnapshots = nextProjects
            sessionSnapshots = nextSessions
            providerSnapshots = nextProviders
            accountSnapshots = nextAccounts
            hasSnapshotBaseline = true
            return
        }

        for identifier in Set(projectSnapshots.keys).union(nextProjects.keys).sorted() {
            switch (projectSnapshots[identifier], nextProjects[identifier]) {
            case (.some(let old), .some(let new)) where old != new:
                appendEvent(kind: .projectChanged, entityID: identifier)
            case (.none, .some):
                appendEvent(kind: .projectChanged, entityID: identifier)
            case (.some, .none):
                appendEvent(kind: .projectRemoved, entityID: identifier)
            default:
                break
            }
        }
        for identifier in Set(sessionSnapshots.keys).union(nextSessions.keys).sorted() {
            switch (sessionSnapshots[identifier], nextSessions[identifier]) {
            case (.some(let old), .some(let new)) where old != new:
                appendEvent(
                    kind: .sessionChanged,
                    entityID: identifier,
                    projectID: new.projectID
                )
            case (.none, .some(let new)):
                appendEvent(
                    kind: .sessionChanged,
                    entityID: identifier,
                    projectID: new.projectID
                )
            case (.some(let old), .none):
                appendEvent(
                    kind: .sessionRemoved,
                    entityID: identifier,
                    projectID: old.projectID
                )
            default:
                break
            }
        }
        for identifier in Set(providerSnapshots.keys).union(nextProviders.keys).sorted() {
            switch (providerSnapshots[identifier], nextProviders[identifier]) {
            case (.some(let old), .some(let new)) where old != new:
                appendEvent(kind: .providerChanged, entityID: identifier)
            case (.none, .some):
                appendEvent(kind: .providerChanged, entityID: identifier)
            default:
                break
            }
        }
        for identifier in Set(accountSnapshots.keys).union(nextAccounts.keys).sorted() {
            switch (accountSnapshots[identifier], nextAccounts[identifier]) {
            case (.some(let old), .some(let new)) where old != new:
                appendEvent(kind: .accountChanged, entityID: identifier)
            case (.none, .some):
                appendEvent(kind: .accountChanged, entityID: identifier)
            case (.some, .none):
                appendEvent(kind: .accountRemoved, entityID: identifier)
            default:
                break
            }
        }

        projectSnapshots = nextProjects
        sessionSnapshots = nextSessions
        providerSnapshots = nextProviders
        accountSnapshots = nextAccounts
    }

    private func routeComponentPublication(
        _ request: HTTPRequest,
        authority: Authority,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        let hasGeneralComponentAuthority = authority.capabilities.contains(
            .componentCustomization
        )
        let hasSessionIdentityAuthority = authority.capabilities.contains(
            .sessionIdentityRenderer
        )
        guard hasGeneralComponentAuthority || hasSessionIdentityAuthority else {
            respond(jsonFailure(
                status: 403,
                reason: "Forbidden",
                "Neither ui.components nor appearance.session-identity was granted."
            ))
            return
        }
        guard request.header("content-type")?
            .lowercased()
            .hasPrefix("application/json") == true else {
            respond(jsonFailure(
                status: 415,
                reason: "Unsupported Media Type",
                "Expected application/json."
            ))
            return
        }
        guard request.body.count <= Self.maximumPublicationBytes else {
            respond(jsonFailure(
                status: 413,
                reason: "Payload Too Large",
                "A component publication may not exceed 1 MiB."
            ))
            return
        }
        guard let registry else {
            respond(jsonFailure(
                status: 503,
                reason: "Service Unavailable",
                "The component registry is unavailable."
            ))
            return
        }

        do {
            let publication = try JSONDecoder().decode(
                ExtensionComponentPatchPublication.self,
                from: request.body
            )
            try publication.validate()
            if publication.patches.contains(where: Self.patchUsesMetalSurface),
               !authority.capabilities.contains(.customMetalSurfaces) {
                respond(jsonFailure(
                    status: 403,
                    reason: "Forbidden",
                    "ui.rendering.metal is required for Metal custom surfaces."
                ))
                return
            }
            if publication.patches.contains(where: Self.patchUsesUnsupportedSignal) {
                respond(jsonFailure(
                    status: 422,
                    reason: "Unprocessable Content",
                    "The component hook uses a host signal this version of Threading does not provide."
                ))
                return
            }
            if !hasGeneralComponentAuthority,
               publication.patches.contains(where: {
                   $0.target.component != .sidebarSessionIdentity
               }) {
                respond(jsonFailure(
                    status: 403,
                    reason: "Forbidden",
                    "appearance.session-identity may publish only sidebar.session-identity patches."
                ))
                return
            }
            try registry.replacePatches(
                publication.patches.map(authority.localization.componentPatch),
                from: ComponentCustomizationSource(
                    extensionIdentifier: authority.extensionIdentifier,
                    processGeneration: authority.processGeneration,
                    order: authority.order
                )
            )
            respond(HTTPResponse(
                status: 204,
                reason: "No Content",
                contentType: nil,
                body: Data()
            ))
        } catch {
            let message = (error as? ExtensionValidationError)?.description
                ?? error.localizedDescription
            respond(jsonFailure(
                status: 422,
                reason: "Unprocessable Content",
                message
            ))
        }
    }

    private static func patchUsesMetalSurface(_ patch: ExtensionComponentPatch) -> Bool {
        [patch.replacement, patch.hook]
            .compactMap { $0 }
            .contains(where: nodeUsesMetalSurface)
            || patch.slots.flatMap(\.children).contains(where: nodeUsesMetalSurface)
    }

    private static func nodeUsesMetalSurface(_ node: ExtensionNode) -> Bool {
        switch node {
        case .customSurface(.metal, _):
            return true
        case .overlay(let base, let overlay):
            return nodeUsesMetalSurface(base) || nodeUsesMetalSurface(overlay)
        case .stack(_, _, let children):
            return children.contains(where: nodeUsesMetalSurface)
        default:
            return false
        }
    }

    private static func patchUsesUnsupportedSignal(_ patch: ExtensionComponentPatch) -> Bool {
        [patch.replacement, patch.hook]
            .compactMap { $0 }
            .contains(where: nodeUsesUnsupportedSignal)
            || patch.slots.flatMap(\.children).contains(where: nodeUsesUnsupportedSignal)
    }

    private static func nodeUsesUnsupportedSignal(_ node: ExtensionNode) -> Bool {
        switch node {
        case .customSurface(.metal(let surface), _):
            return surface.inputs.contains { input in
                guard case .signal(let signal, _) = input.value else { return false }
                return signal != .activeAccountUsageRemaining
            }
        case .overlay(let base, let overlay):
            return nodeUsesUnsupportedSignal(base) || nodeUsesUnsupportedSignal(overlay)
        case .stack(_, _, let children):
            return children.contains(where: nodeUsesUnsupportedSignal)
        default:
            return false
        }
    }

    private func routeIdentityPublication(
        _ request: HTTPRequest,
        authority: Authority,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        guard request.header("content-type")?
            .lowercased()
            .hasPrefix("application/json") == true else {
            respond(jsonFailure(
                status: 415,
                reason: "Unsupported Media Type",
                "Expected application/json."
            ))
            return
        }
        guard request.body.count <= Self.maximumPublicationBytes else {
            respond(jsonFailure(
                status: 413,
                reason: "Payload Too Large",
                "An identity publication may not exceed 1 MiB."
            ))
            return
        }
        guard let identityRegistry else {
            respond(jsonFailure(
                status: 503,
                reason: "Service Unavailable",
                "The identity resolver registry is unavailable."
            ))
            return
        }

        do {
            let publication = try JSONDecoder().decode(
                ExtensionIdentityResolutionPublication.self,
                from: request.body
            )
            try publication.validate()
            if !publication.providerIcons.isEmpty,
               !authority.capabilities.contains(.providerIconResolver) {
                throw ExtensionHostServiceError.missingCapability(
                    ExtensionCapability.providerIconResolver.rawValue
                )
            }
            if !publication.accountIcons.isEmpty,
               !authority.capabilities.contains(.accountIconResolver) {
                throw ExtensionHostServiceError.missingCapability(
                    ExtensionCapability.accountIconResolver.rawValue
                )
            }
            try identityRegistry.replace(
                publication,
                from: ComponentCustomizationSource(
                    extensionIdentifier: authority.extensionIdentifier,
                    processGeneration: authority.processGeneration,
                    order: authority.order
                )
            )
            respond(HTTPResponse(
                status: 204,
                reason: "No Content",
                contentType: nil,
                body: Data()
            ))
        } catch let error as ExtensionHostServiceError {
            respond(jsonFailure(
                status: 403,
                reason: "Forbidden",
                error.localizedDescription
            ))
        } catch {
            let message = (error as? ExtensionValidationError)?.description
                ?? error.localizedDescription
            respond(jsonFailure(
                status: 422,
                reason: "Unprocessable Content",
                message
            ))
        }
    }

    private func routeEvents(
        queryItems: [URLQueryItem],
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        let values = Dictionary(
            queryItems.map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        let after: Int64
        if let rawAfter = values["after"] {
            guard let parsed = Int64(rawAfter), parsed >= 0 else {
                respond(jsonFailure(
                    status: 400,
                    reason: "Bad Request",
                    "The after cursor must be a non-negative integer."
                ))
                return
            }
            after = parsed
        } else {
            after = 0
        }
        guard after <= currentCursor else {
            respond(jsonFailure(
                status: 400,
                reason: "Bad Request",
                "The after cursor is newer than the host's current cursor."
            ))
            return
        }

        let limit: Int
        if let rawLimit = values["limit"] {
            guard let parsed = Int(rawLimit),
                  (1...Self.maximumEventPageSize).contains(parsed) else {
                respond(jsonFailure(
                    status: 400,
                    reason: "Bad Request",
                    "The event limit must be between 1 and \(Self.maximumEventPageSize)."
                ))
                return
            }
            limit = parsed
        } else {
            limit = 100
        }

        if let first = eventJournal.first, after < first.cursor - 1 {
            respond(jsonFailure(
                status: 410,
                reason: "Gone",
                "The event cursor expired; request fresh snapshots and resume from their cursor."
            ))
            return
        }

        let available = eventJournal.filter { $0.cursor > after }
        let events = Array(available.prefix(limit))
        respond(jsonResponse(ExtensionHostEventPage(
            events: events,
            nextCursor: events.last?.cursor ?? after,
            hasMore: available.count > events.count
        )))
    }

    private func decodedIdentifier(in path: String, after prefix: String) -> String {
        let encoded = String(path.dropFirst(prefix.count))
        return encoded.removingPercentEncoding ?? encoded
    }

    private func beginObservingHostData() {
        guard appEvents == nil else { return }
        let observations = AppEventObservations()
        observations.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.refreshSnapshotJournal()
        }
        observations.observe(AppSettingsDidChange.self) { [weak self] _ in
            self?.refreshSnapshotJournal()
        }
        observations.observe(SessionActivityDidChange.self) { [weak self] _ in
            self?.refreshSnapshotJournal()
        }
        observations.observe(AccountPreferencesDidChange.self) { [weak self] _ in
            self?.refreshSnapshotJournal()
        }
        appEvents = observations
    }

    private func appendEvent(
        kind: ExtensionHostEventKind,
        entityID: String,
        projectID: String? = nil
    ) {
        currentCursor += 1
        eventJournal.append(ExtensionHostEvent(
            cursor: currentCursor,
            kind: kind,
            entityID: entityID,
            projectID: projectID
        ))
        if eventJournal.count > Self.maximumRetainedEvents {
            eventJournal.removeFirst(eventJournal.count - Self.maximumRetainedEvents)
        }
    }

    private func visibleProjects(for authority: Authority) -> [ExtensionProjectSnapshot] {
        projectSnapshots.values
            .map { visible(project: $0, for: authority) }
            .sorted { $0.id < $1.id }
    }

    private func visible(
        project: ExtensionProjectSnapshot,
        for authority: Authority
    ) -> ExtensionProjectSnapshot {
        guard authority.capabilities.contains(.hostRepositoriesRead) else {
            return ExtensionProjectSnapshot(
                version: project.version,
                id: project.id,
                displayName: project.displayName
            )
        }
        return project
    }

    private func require(
        _ capability: ExtensionCapability,
        for authority: Authority,
        respond: (HTTPResponse) -> Void
    ) -> Bool {
        guard authority.capabilities.contains(capability) else {
            respond(jsonFailure(
                status: 403,
                reason: "Forbidden",
                "The \(capability.rawValue) capability was not granted."
            ))
            return false
        }
        return true
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = MCPConnection(
            connection: nwConnection,
            queue: queue,
            handler: { [weak self] request, respond in
                Task { @MainActor in
                    self?.route(request, respond: respond)
                }
            },
            onClose: { [weak self] closed in
                let identifier = ObjectIdentifier(closed)
                Task { @MainActor in
                    _ = self?.connectionsByID.removeValue(forKey: identifier)
                }
            }
        )
        connectionsByID[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    private func listenerStateDidChange(
        _ state: NWListener.State,
        listener: NWListener
    ) {
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                baseURL = nil
                finishStartup()
                return
            }
            baseURL = URL(string: "http://\(Self.host):\(port)/v1")
            ThreadingLogger.extensions.info(
            "Extension host listening on port \(port, privacy: .public)"
            )
            finishStartup()

        case .failed(let error):
            baseURL = nil
            ThreadingLogger.extensions.error(
                "Extension host failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            finishStartup()

        default:
            break
        }
    }

    private func finishStartup() {
        let completion = startupCompletion
        startupCompletion = nil
        completion?()
    }

    private func authenticatedAuthority(for request: HTTPRequest) -> Authority? {
        guard let header = request.header("authorization"),
              header.hasPrefix("Bearer ") else {
            return nil
        }
        return authorities[String(header.dropFirst("Bearer ".count))]
    }

    private func jsonFailure(
        status: Int,
        reason: String,
        _ message: String
    ) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(Failure(error: message))) ?? Data()
        return HTTPResponse(
            status: status,
            reason: reason,
            contentType: "application/json",
            body: body
        )
    }

    private func jsonResponse<Value: Encodable>(_ value: Value) -> HTTPResponse {
        do {
            return HTTPResponse(
                status: 200,
                reason: "OK",
                contentType: "application/json",
                body: try JSONEncoder().encode(value)
            )
        } catch {
            return jsonFailure(
                status: 500,
                reason: "Internal Server Error",
                "The host response could not be encoded."
            )
        }
    }

    typealias EntropySource = (_ byteCount: Int) -> [UInt8]?

    static func randomToken(using source: EntropySource = secureEntropy) -> String? {
        guard let bytes = source(32), bytes.count == 32 else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Security.framework owns this operation; it does not touch host state and is safe to pass
    /// through the nonisolated entropy seam without erasing a main-actor function type.
    nonisolated private static func secureEntropy(bytes count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            ThreadingLogger.extensions.fault(
                "Could not generate extension host entropy: \(status, privacy: .public)"
            )
            return nil
        }
        return bytes
    }
}
