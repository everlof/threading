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

    /// Every path this host answers, and the only place a `/v1/…` literal is written.
    ///
    /// The route table used to be spelled three times: a block of path constants, the `||`
    /// chain that decides whether an unknown path is a 404, and the dispatch `switch`. Half
    /// the chain re-spelled its literals rather than using the constants, so the three lists
    /// could disagree with nothing to catch it — a route added to the dispatch but missed in
    /// the gate is silently unreachable, and the gate fails closed. Parsing here makes the
    /// gate and the dispatch the same list by construction: `route(_:respond:)` switches over
    /// this type with no `default:`, so a new case has to be answered.
    ///
    /// Payloads carry the already-decoded identifier, so no handler re-derives one from a
    /// prefix it would have to spell again.
    enum Route: Equatable {
        /// Read routes share a `GET` guard and a snapshot refresh, so they are grouped rather
        /// than repeating both in five sibling cases.
        enum Read: Equatable {
            case projects(String?)
            case sessions(Session)
            case providers(String?)
            case accounts(String?)
            case events
        }

        enum Session: Equatable {
            case collection
            case item(String)
            case runtime(String)
        }

        case componentPatches
        case facts
        case identityResolutions
        /// The suffix after `/v1/services/`, still unparsed: the handler answers a malformed
        /// one with 400 *after* its capability check, which a refusal here would turn into 404.
        case services(String)
        /// The suffix after `/v1/companions/`, unparsed for the same reason.
        case companions(String)
        case networkFetch
        case projectFilesQuery
        /// `nil` is the collection; a value is one item, decoded and possibly empty.
        case secrets(String?)
        case keyValue(String?)
        case cache(String?)
        case read(Read)

        init?(path: String) {
            switch path {
            case "/v1/component-patches": self = .componentPatches
            case "/v1/facts": self = .facts
            case "/v1/identity-resolutions": self = .identityResolutions
            case "/v1/network/fetch": self = .networkFetch
            case "/v1/project-files/query": self = .projectFilesQuery
            case "/v1/secrets": self = .secrets(nil)
            case "/v1/storage/kv": self = .keyValue(nil)
            case "/v1/storage/cache": self = .cache(nil)
            case "/v1/projects": self = .read(.projects(nil))
            case "/v1/sessions": self = .read(.sessions(.collection))
            case "/v1/providers": self = .read(.providers(nil))
            case "/v1/accounts": self = .read(.accounts(nil))
            case "/v1/events": self = .read(.events)
            default:
                if let suffix = Self.suffix(of: path, after: "/v1/services/") {
                    self = .services(suffix)
                } else if let suffix = Self.suffix(of: path, after: "/v1/companions/") {
                    self = .companions(suffix)
                } else if let key = Self.identifier(of: path, after: "/v1/secrets/") {
                    self = .secrets(key)
                } else if let key = Self.identifier(of: path, after: "/v1/storage/kv/") {
                    self = .keyValue(key)
                } else if let name = Self.identifier(of: path, after: "/v1/storage/cache/") {
                    self = .cache(name)
                } else if let id = Self.identifier(of: path, after: "/v1/projects/") {
                    self = .read(.projects(id))
                } else if let suffix = Self.suffix(of: path, after: "/v1/sessions/") {
                    self = .read(.sessions(Self.session(suffix: suffix, in: path)))
                } else if let id = Self.identifier(of: path, after: "/v1/providers/") {
                    self = .read(.providers(id))
                } else if let id = Self.identifier(of: path, after: "/v1/accounts/") {
                    self = .read(.accounts(id))
                } else {
                    return nil
                }
            }
        }

        private static let runtimeSuffix = "/runtime"

        /// The runtime test is on the **whole path**, not on the suffix, because that is what
        /// the dispatch it replaced did. `/v1/sessions/runtime` therefore parses as a runtime
        /// read of the empty id — a 404 that costs `hostSessionRuntimeRead` — rather than as a
        /// session named `runtime`. Reading it off the suffix instead would quietly move which
        /// capability that path demands.
        private static func session(suffix: String, in path: String) -> Session {
            guard path.hasSuffix(runtimeSuffix) else { return .item(decoded(suffix)) }
            return .runtime(decoded(String(suffix.dropLast(runtimeSuffix.count))))
        }

        private static func suffix(of path: String, after prefix: String) -> String? {
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        }

        private static func identifier(of path: String, after prefix: String) -> String? {
            suffix(of: path, after: prefix).map(decoded)
        }

        private static func decoded(_ value: String) -> String {
            value.removingPercentEncoding ?? value
        }
    }

    private static let host = "127.0.0.1"
    /// A brokered cache write is base64 in JSON, which inflates the entry by a third. The
    /// allowance is the entry cap plus that inflation and the envelope, and still well under
    /// `MCPDefaults.maximumRequestBytes`.
    private static let maximumCacheRequestBytes = 6 * 1024 * 1024
    private static let maximumPublicationBytes = 1024 * 1024
    private static let maximumRetainedEvents = 1_000
    private static let maximumEventPageSize = 200
    private static let hostCapabilities: Set<ExtensionCapability> = [
        .componentCustomization,
        .factsProvide,
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
    private weak var factRegistry: ExtensionFactRegistry?
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
        registry: ComponentCustomizationRegistry? = nil,
        factRegistry: ExtensionFactRegistry? = nil,
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
        self.factRegistry = factRegistry
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
        registry: ComponentCustomizationRegistry?,
        factRegistry: ExtensionFactRegistry? = nil,
        identityRegistry: ExtensionIdentityResolverRegistry? = nil,
        completion: @escaping () -> Void
    ) {
        self.registry = registry
        self.factRegistry = factRegistry
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
            factRegistry?.removeGeneration(
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
        factDefinitions: [ExtensionFactDefinition] = [],
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
        try Self.validateFactAuthorization(
            capabilities: capabilities,
            definitions: factDefinitions
        )
        guard let token = Self.randomToken(using: entropySource) else {
            throw ExtensionHostServiceError.secureTokenUnavailable
        }
        let factSource = ComponentCustomizationSource(
            extensionIdentifier: extensionIdentifier,
            processGeneration: processGeneration,
            // Persisted user ordering arrives in rollout 8. Until then every provider has the
            // same priority and the registry's identifier tie-break is independent of start order.
            order: 0
        )
        let installedFactDefinitions: Bool
        if capabilities.contains(.factsProvide) {
            guard let factRegistry else { throw ExtensionHostServiceError.unavailable }
            try factRegistry.replaceDefinitions(
                factDefinitions.map(localization.factDefinition),
                from: factSource
            )
            installedFactDefinitions = true
        } else {
            installedFactDefinitions = false
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
                if installedFactDefinitions {
                    factRegistry?.removeGeneration(
                        extensionIdentifier: extensionIdentifier,
                        processGeneration: processGeneration
                    )
                }
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

    /// The package loader validates the manifest first, but authorization is the trust boundary:
    /// tests and future launch paths must not be able to install a broader declaration directly.
    private static func validateFactAuthorization(
        capabilities: Set<ExtensionCapability>,
        definitions: [ExtensionFactDefinition]
    ) throws {
        let providesFacts = capabilities.contains(.factsProvide)
        var issues: [ExtensionValidationIssue] = []
        if !definitions.isEmpty, !providesFacts {
            issues.append(.init(
                path: "capabilities",
                message: "must contain 'facts.provide' when fact definitions are declared"
            ))
        }
        if providesFacts, definitions.isEmpty {
            issues.append(.init(
                path: "factDefinitions",
                message: "must declare at least one definition for 'facts.provide'"
            ))
        }
        if definitions.count > ExtensionFactProviderLimits.maximumDefinitions {
            issues.append(.init(
                path: "factDefinitions",
                message: "must contain at most "
                    + "\(ExtensionFactProviderLimits.maximumDefinitions) definitions"
            ))
        }
        var seenKeys: Set<ExtensionFactKey> = []
        for (index, definition) in definitions.enumerated() {
            let path = "factDefinitions[\(index)]"
            issues.append(contentsOf: definition.providerValidationIssues(path: path))
            if !seenKeys.insert(definition.key).inserted {
                issues.append(.init(path: "\(path).key", message: "duplicates this fact key"))
            }
        }
        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
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
        factRegistry?.removeGeneration(
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
        // The 404 comes *before* authentication, deliberately: an unknown path is refused
        // without ever consulting the token, so an unauthenticated caller cannot map which
        // routes exist by telling 404 from 401.
        guard let route = Route(path: components.path) else {
            respond(.status(404, "Not Found"))
            return
        }
        guard let authority = authenticatedAuthority(for: request) else {
            respond(jsonFailure(status: 401, reason: "Unauthorized", "Invalid bearer token."))
            return
        }

        // No `default:`. A case added to `Route` has to be answered here, which is the whole
        // point of the type: the gate and the dispatch cannot drift apart any more.
        switch route {
        case .componentPatches:
            guard request.method == "PUT" else {
                respond(Self.unsupportedMethod(request))
                return
            }
            routeComponentPublication(request, authority: authority, respond: respond)

        case .facts:
            guard request.method == "PUT" else {
                respond(Self.unsupportedMethod(request))
                return
            }
            routeFactPublication(request, authority: authority, respond: respond)

        case .identityResolutions:
            guard request.method == "PUT" else {
                respond(Self.unsupportedMethod(request))
                return
            }
            routeIdentityPublication(request, authority: authority, respond: respond)

        case let .services(suffix):
            guard request.method == "POST" else {
                respond(Self.unsupportedMethod(request))
                return
            }
            routeServiceCall(request, suffix: suffix, authority: authority, respond: respond)

        case let .companions(suffix):
            guard request.method == "POST" else {
                respond(Self.unsupportedMethod(request))
                return
            }
            routeCompanionOperation(
                request,
                suffix: suffix,
                authority: authority,
                respond: respond
            )

        case .networkFetch:
            guard request.method == "POST" else {
                respond(Self.unsupportedMethod(request))
                return
            }
            routeBrokeredFetch(request, authority: authority, respond: respond)

        case .projectFilesQuery:
            guard request.method == "POST" else {
                respond(Self.unsupportedMethod(request))
                return
            }
            routeProjectFileQuery(request, authority: authority, respond: respond)

        case let .secrets(key):
            routeSecretRequest(request, key: key, authority: authority, respond: respond)

        case let .keyValue(key):
            guard require(.keyValueStorage, for: authority, respond: respond) else { return }
            storageRouter.routeKeyValue(
                request,
                key: key,
                extensionIdentifier: authority.extensionIdentifier,
                respond: respond
            )

        case let .cache(name):
            guard require(.cacheStorage, for: authority, respond: respond) else { return }
            storageRouter.routeCache(
                request,
                name: name,
                extensionIdentifier: authority.extensionIdentifier,
                maximumRequestBytes: Self.maximumCacheRequestBytes,
                respond: respond
            )

        case let .read(read):
            guard request.method == "GET" else {
                respond(.status(405, "Method Not Allowed"))
                return
            }
            refreshSnapshotJournal()
            routeSnapshotRead(
                read,
                queryItems: components.queryItems ?? [],
                authority: authority,
                respond: respond
            )
        }
    }

    /// What a known route answers a method it does not implement.
    ///
    /// `GET` is 404 rather than 405, which looks wrong until you follow the code this replaced:
    /// a `GET` of a write-only route fell past the method-matched `if` chain, through the read
    /// `switch`, and out of its `default:`. Preserved deliberately so unifying the gate and the
    /// dispatch changed no response anybody could observe.
    private static func unsupportedMethod(_ request: HTTPRequest) -> HTTPResponse {
        request.method == "GET"
            ? .status(404, "Not Found")
            : .status(405, "Method Not Allowed")
    }

    /// The `GET`-only snapshot reads, answered from the journal `route(_:respond:)` refreshed.
    private func routeSnapshotRead(
        _ read: Route.Read,
        queryItems: [URLQueryItem],
        authority: Authority,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        switch read {
        case let .projects(identifier):
            guard require(.hostProjectsRead, for: authority, respond: respond) else { return }
            guard let identifier else {
                respond(jsonResponse(ExtensionProjectSnapshotPage(
                    cursor: currentCursor,
                    projects: visibleProjects(for: authority)
                )))
                return
            }
            guard !identifier.isEmpty, let project = projectSnapshots[identifier] else {
                respond(jsonFailure(status: 404, reason: "Not Found", "Project not found."))
                return
            }
            respond(jsonResponse(ExtensionProjectSnapshotResult(
                cursor: currentCursor,
                project: visible(project: project, for: authority)
            )))

        case let .sessions(session):
            routeSessionRead(session, authority: authority, respond: respond)

        case let .providers(identifier):
            guard require(.hostProvidersRead, for: authority, respond: respond) else { return }
            guard let identifier else {
                respond(jsonResponse(ExtensionProviderSnapshotPage(
                    cursor: currentCursor,
                    providers: providerSnapshots.values.sorted { $0.id < $1.id }
                )))
                return
            }
            guard !identifier.isEmpty, let provider = providerSnapshots[identifier] else {
                respond(jsonFailure(status: 404, reason: "Not Found", "Provider not found."))
                return
            }
            respond(jsonResponse(ExtensionProviderSnapshotResult(
                cursor: currentCursor,
                provider: provider
            )))

        case let .accounts(identifier):
            guard require(
                .hostAccountsPresentationRead,
                for: authority,
                respond: respond
            ) else { return }
            guard let identifier else {
                respond(jsonResponse(ExtensionAccountSnapshotPage(
                    cursor: currentCursor,
                    accounts: accountSnapshots.values.sorted { $0.id < $1.id }
                )))
                return
            }
            guard !identifier.isEmpty, let account = accountSnapshots[identifier] else {
                respond(jsonFailure(status: 404, reason: "Not Found", "Account not found."))
                return
            }
            respond(jsonResponse(ExtensionAccountSnapshotResult(
                cursor: currentCursor,
                account: account
            )))

        case .events:
            guard require(.hostEvents, for: authority, respond: respond) else { return }
            routeEvents(queryItems: queryItems, respond: respond)
        }
    }

    /// The collection, one session, and one session's runtime reading — three capabilities,
    /// so they stay separate cases rather than an optional identifier.
    private func routeSessionRead(
        _ session: Route.Session,
        authority: Authority,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        switch session {
        case .collection:
            guard require(.hostSessionsRead, for: authority, respond: respond) else { return }
            respond(jsonResponse(ExtensionSessionSnapshotPage(
                cursor: currentCursor,
                sessions: sessionSnapshots.values.sorted { $0.id < $1.id }
            )))

        case let .item(identifier):
            guard require(.hostSessionsRead, for: authority, respond: respond) else { return }
            guard !identifier.isEmpty, let session = sessionSnapshots[identifier] else {
                respond(jsonFailure(status: 404, reason: "Not Found", "Session not found."))
                return
            }
            respond(jsonResponse(ExtensionSessionSnapshotResult(
                cursor: currentCursor,
                session: session
            )))

        case let .runtime(identifier):
            guard require(
                .hostSessionRuntimeRead,
                for: authority,
                respond: respond
            ) else { return }
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

    /// `key` is `nil` for the collection and the decoded identifier for one secret.
    private func routeSecretRequest(
        _ request: HTTPRequest,
        key: String?,
        authority: Authority,
        respond: (HTTPResponse) -> Void
    ) {
        guard require(.secrets, for: authority, respond: respond) else { return }

        guard let key else {
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

    /// `suffix` is everything after `/v1/companions/`, still unparsed: a malformed one is a
    /// 400 answered *after* the capability check, which a refusal in `Route` would have turned
    /// into a 404.
    private func routeCompanionOperation(
        _ request: HTTPRequest,
        suffix: String,
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
                        credential: reading.credential.rawValue,
                        finalURL: reading.finalURL
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

    /// `suffix` is everything after `/v1/services/`, unparsed for the same reason as
    /// `routeCompanionOperation(_:suffix:authority:respond:)`.
    private func routeServiceCall(
        _ request: HTTPRequest,
        suffix: String,
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

    /// Applies the exact project-store delta to the extension event journal. A one-row rename
    /// must not rebuild repository and runtime snapshots for every retained conversation before
    /// the Enter key can return to AppKit.
    ///
    /// Internal, like the whole-catalogue refresh, so a focused test can hand it one exact
    /// impact and count what the provider was asked for.
    func refreshSnapshotJournal(for change: ProjectsDidChange) {
        guard hasSnapshotBaseline else {
            refreshSnapshotJournal()
            return
        }
        switch change.sidebarImpact {
        case .structure:
            refreshSnapshotJournal()
        case .projectStructure(let projectID):
            refreshProjectStructure(id: projectID.uuidString.lowercased())
        case .projectRemoved(let projectID, let sessionIDs, _):
            refreshProjectSnapshot(id: projectID.uuidString.lowercased())
            for sessionID in sessionIDs {
                refreshSessionSnapshot(id: sessionID.uuidString.lowercased())
            }
        case .projectRow(let projectID):
            refreshProjectSnapshot(id: projectID.uuidString.lowercased())
        case .sessionAdded(_, let sessionID), .sessionStructure(_, let sessionID),
             .sessionTitle(let sessionID, _), .sessionRow(let sessionID):
            refreshSessionSnapshot(id: sessionID.uuidString.lowercased())
        case .sessionRemoved(_, let sessionID):
            let identifier = sessionID.uuidString.lowercased()
            if let previous = sessionSnapshots.removeValue(forKey: identifier) {
                appendEvent(
                    kind: .sessionRemoved,
                    entityID: identifier,
                    projectID: previous.projectID
                )
            }
        case .terminalAdded, .terminalRow:
            break
        }
    }

    /// Rows joined, left or regrouped inside one project. Every other project's sessions, the
    /// checkouts, the providers and the accounts stand, so only that project's sessions are
    /// re-read and compared. This is the impact an archive publishes, and until it was routed
    /// here it was treated as `.structure`: one archived row re-snapshotted every retained
    /// conversation and re-read every checkout's git metadata on the main actor.
    private func refreshProjectStructure(id projectID: String) {
        let next = Dictionary(
            uniqueKeysWithValues: snapshotProvider.sessionSnapshots(inProject: projectID)
                .map { ($0.id, $0) }
        )
        let standing = sessionSnapshots.filter { $0.value.projectID == projectID }.keys
        for identifier in Set(standing).union(next.keys).sorted() {
            switch (sessionSnapshots[identifier], next[identifier]) {
            case (.some(let old), .some(let new)) where old != new:
                sessionSnapshots[identifier] = new
                appendEvent(
                    kind: .sessionChanged,
                    entityID: identifier,
                    projectID: new.projectID
                )
            case (.none, .some(let new)):
                sessionSnapshots[identifier] = new
                appendEvent(
                    kind: .sessionChanged,
                    entityID: identifier,
                    projectID: new.projectID
                )
            case (.some(let old), .none):
                sessionSnapshots.removeValue(forKey: identifier)
                appendEvent(
                    kind: .sessionRemoved,
                    entityID: identifier,
                    projectID: old.projectID
                )
            default:
                break
            }
        }
    }

    private func refreshProjectSnapshot(id identifier: String) {
        let next = snapshotProvider.projectSnapshot(id: identifier)
        switch (projectSnapshots[identifier], next) {
        case (.some(let old), .some(let new)) where old != new:
            projectSnapshots[identifier] = new
            appendEvent(kind: .projectChanged, entityID: identifier)
        case (.none, .some(let new)):
            projectSnapshots[identifier] = new
            appendEvent(kind: .projectChanged, entityID: identifier)
        case (.some, .none):
            projectSnapshots.removeValue(forKey: identifier)
            appendEvent(kind: .projectRemoved, entityID: identifier)
        default:
            break
        }
    }

    private func refreshSessionSnapshot(id identifier: String) {
        let next = snapshotProvider.sessionSnapshot(id: identifier)
        switch (sessionSnapshots[identifier], next) {
        case (.some(let old), .some(let new)) where old != new:
            sessionSnapshots[identifier] = new
            appendEvent(
                kind: .sessionChanged,
                entityID: identifier,
                projectID: new.projectID
            )
        case (.none, .some(let new)):
            sessionSnapshots[identifier] = new
            appendEvent(
                kind: .sessionChanged,
                entityID: identifier,
                projectID: new.projectID
            )
        case (.some(let old), .none):
            sessionSnapshots.removeValue(forKey: identifier)
            appendEvent(
                kind: .sessionRemoved,
                entityID: identifier,
                projectID: old.projectID
            )
        default:
            break
        }
    }

    private func routeFactPublication(
        _ request: HTTPRequest,
        authority: Authority,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        guard require(.factsProvide, for: authority, respond: respond) else { return }
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
                "A fact publication may not exceed 1 MiB."
            ))
            return
        }
        guard let factRegistry else {
            respond(jsonFailure(
                status: 503,
                reason: "Service Unavailable",
                "The fact registry is unavailable."
            ))
            return
        }

        do {
            let publication = try JSONDecoder().decode(
                ExtensionFactPublication.self,
                from: request.body
            )
            try publication.validate()
            try factRegistry.replaceFacts(
                publication.facts.map(authority.localization.fact),
                replacing: Set(publication.replacingSubjects),
                from: ComponentCustomizationSource(
                    extensionIdentifier: authority.extensionIdentifier,
                    processGeneration: authority.processGeneration,
                    order: 0
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

    private func beginObservingHostData() {
        guard appEvents == nil else { return }
        let observations = AppEventObservations()
        observations.observe(ProjectsDidChange.self) { [weak self] change in
            self?.refreshSnapshotJournal(for: change)
        }
        observations.observe(SessionActivityDidChange.self) { [weak self] event in
            guard let self else { return }
            if hasSnapshotBaseline {
                refreshSessionSnapshot(id: event.sessionID.uuidString.lowercased())
            } else {
                refreshSnapshotJournal()
            }
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
            handler: { [weak self] _, request, respond in
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
