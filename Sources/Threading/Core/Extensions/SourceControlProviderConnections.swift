import Foundation
import ThreadingExtensionKit

struct SourceControlProviderConnection: Codable, Equatable, Sendable {
    static let maximumCount = 64

    let id: String
    let extensionIdentifier: String
    let providerID: String
    let remoteHost: String
    let baseOrigin: String
    let apiPathPrefix: String
    let authenticationKind: ExtensionSourceControlAuthenticationKind
    let username: String?

    init(
        id: String = UUID().uuidString.lowercased(),
        extensionIdentifier: String,
        providerID: String,
        remoteHost: String,
        baseOrigin: String,
        apiPathPrefix: String,
        authenticationKind: ExtensionSourceControlAuthenticationKind,
        username: String? = nil
    ) {
        self.id = id
        self.extensionIdentifier = extensionIdentifier
        self.providerID = providerID
        self.remoteHost = remoteHost
        self.baseOrigin = baseOrigin
        self.apiPathPrefix = apiPathPrefix
        self.authenticationKind = authenticationKind
        self.username = username
    }

    var origin: URL? {
        guard let url = URL(string: baseOrigin),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil else { return nil }
        return url
    }

    /// The credential's bytes read strictly as UTF-8, or `nil` when they are not valid UTF-8.
    ///
    /// A token goes into an HTTP header, so a byte sequence that is not text is refused rather
    /// than repaired. The bytes are already bounded by `ExtensionSecretConstraints`, and the
    /// check is a pure round-trip comparison, so it is cheap enough for every caller.
    static func utf8Token(_ credential: Data) -> String? {
        let decoded = String(decoding: credential, as: UTF8.self)
        guard decoded.utf8.elementsEqual(credential) else { return nil }
        return decoded
    }

    func validate() throws {
        var issues: [String] = []
        if id.isEmpty || id.count > 256 { issues.append("connection id") }
        if !ExtensionIdentifierRules.isReverseDNSIdentifier(extensionIdentifier) {
            issues.append("extension identifier")
        }
        if !ExtensionIdentifierRules.isContributionIdentifier(providerID) {
            issues.append("provider identifier")
        }
        let hostCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-"
        )
        if remoteHost.isEmpty || remoteHost != remoteHost.lowercased()
            || remoteHost.count > 253 || remoteHost.hasPrefix(".")
            || remoteHost.hasSuffix(".") || remoteHost.contains("..")
            || !remoteHost.unicodeScalars.allSatisfy(hostCharacters.contains) {
            issues.append("remote host")
        }
        if origin == nil { issues.append("HTTPS origin") }
        if origin?.host?.lowercased() != remoteHost { issues.append("matching HTTPS origin") }
        let definition = ExtensionSourceControlProviderDefinition(
            id: providerID,
            displayName: "Provider",
            changeRequestName: "change request",
            changeRequestPluralName: "change requests",
            apiPathPrefix: apiPathPrefix,
            authenticationKinds: [authenticationKind]
        )
        if !definition.validationIssues(path: "provider").isEmpty {
            issues.append("API path or authentication")
        }
        if authenticationKind == .basicUsernameToken,
           username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append("basic-auth username")
        }
        if let username, username.count > 256 || username.contains(":") {
            issues.append("basic-auth username")
        }
        if !issues.isEmpty {
            throw SourceControlProviderConnectionError.invalid(issues.joined(separator: ", "))
        }
    }
}

enum SourceControlProviderConnectionError: LocalizedError, Equatable {
    case invalid(String)
    case duplicateRemoteHost(String)
    case builtInHost(String)
    case tooManyConnections
    case providerUnavailable
    case credentialRequired
    case credentialNotAllowed
    case credentialInvalid
    case usernameNotAllowed
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "The source-control connection has an invalid \(detail)."
        case .duplicateRemoteHost(let host):
            return "A source-control provider is already connected to \(host)."
        case .builtInHost(let host): return "\(host) is owned by Threading’s built-in provider."
        case .tooManyConnections:
            return "Threading cannot store more than \(SourceControlProviderConnection.maximumCount) source-control connections."
        case .providerUnavailable: return "The source-control provider is not installed and running."
        case .credentialRequired: return "This source-control connection requires a credential."
        case .credentialNotAllowed:
            return "An anonymous source-control connection cannot store a credential."
        case .credentialInvalid:
            return "The source-control credential is invalid."
        case .usernameNotAllowed:
            return "This source-control authentication kind does not use a username."
        case .persistenceFailed: return "Threading could not save the source-control connection."
        }
    }
}

struct SourceControlProviderConnectionsDidChange: AppEvent {
    static let name = Notification.Name("sourceControlProviderConnectionsDidChange")
}

/// Durable connection metadata plus host-only Keychain custody for provider credentials.
@MainActor
final class SourceControlProviderConnectionStore {
    static let shared = SourceControlProviderConnectionStore()
    static let credentialNamespace = "codes.threading.source-control-connections"
    static let reservedHosts: Set<String> = [GitHubDefaults.webHost, GitLabDefaults.webHost]

    private let persistence: RecoverableDefaultsStore<[SourceControlProviderConnection]>
    private let secrets: ExtensionSecretStoring
    private(set) var connections: [SourceControlProviderConnection]

    init(
        defaults: UserDefaults = PreferenceStore.shared,
        secrets: ExtensionSecretStoring = KeychainExtensionSecretStore.shared
    ) {
        let persistence = RecoverableDefaultsStore<[SourceControlProviderConnection]>(
            defaults: defaults,
            key: AppSettingDefinitions.sourceControlProviderConnections.persistenceKey,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.persistence = persistence
        self.secrets = secrets
        connections = persistence.load(defaultValue: []) { values in
            try Self.validateCollection(values)
        }.value
    }

    func connection(id: String, extensionIdentifier: String) -> SourceControlProviderConnection? {
        connections.first { $0.id == id && $0.extensionIdentifier == extensionIdentifier }
    }

    func connection(remoteHost: String) -> SourceControlProviderConnection? {
        connections.first { $0.remoteHost == remoteHost.lowercased() }
    }

    func upsert(
        _ connection: SourceControlProviderConnection,
        credential: Data?
    ) throws {
        try connection.validate()
        if Self.reservedHosts.contains(connection.remoteHost) {
            throw SourceControlProviderConnectionError.builtInHost(connection.remoteHost)
        }
        if connection.authenticationKind != .none, credential?.isEmpty != false {
            throw SourceControlProviderConnectionError.credentialRequired
        }
        if connection.authenticationKind == .none, credential != nil {
            throw SourceControlProviderConnectionError.credentialNotAllowed
        }
        if let credential {
            try ExtensionSecretConstraints.validate(value: credential)
            guard let token = SourceControlProviderConnection.utf8Token(credential),
                  !token.isEmpty,
                  !token.unicodeScalars.contains(where: {
                      CharacterSet.whitespacesAndNewlines.contains($0)
                          || CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw SourceControlProviderConnectionError.credentialInvalid
            }
        }
        if connection.authenticationKind != .basicUsernameToken,
           connection.username != nil {
            throw SourceControlProviderConnectionError.usernameNotAllowed
        }
        if let conflict = connections.first(where: {
            $0.remoteHost == connection.remoteHost && $0.id != connection.id
        }) {
            throw SourceControlProviderConnectionError.duplicateRemoteHost(conflict.remoteHost)
        }
        var next = connections
        if let index = next.firstIndex(where: { $0.id == connection.id }) {
            next[index] = connection
        } else {
            guard next.count < SourceControlProviderConnection.maximumCount else {
                throw SourceControlProviderConnectionError.tooManyConnections
            }
            next.append(connection)
        }
        try Self.validateCollection(next)

        let oldCredential = try secrets.data(
            extensionIdentifier: Self.credentialNamespace,
            key: connection.id
        )
        do {
            if let credential {
                try secrets.setData(
                    credential,
                    extensionIdentifier: Self.credentialNamespace,
                    key: connection.id
                )
            } else {
                try secrets.remove(
                    extensionIdentifier: Self.credentialNamespace,
                    key: connection.id
                )
            }
            guard persistence.save(next) else {
                throw SourceControlProviderConnectionError.persistenceFailed
            }
        } catch {
            if let oldCredential {
                try? secrets.setData(
                    oldCredential,
                    extensionIdentifier: Self.credentialNamespace,
                    key: connection.id
                )
            } else {
                try? secrets.remove(
                    extensionIdentifier: Self.credentialNamespace,
                    key: connection.id
                )
            }
            throw error
        }
        connections = next
        publishChange()
    }

    func remove(id: String) throws {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        let credential = try secrets.data(
            extensionIdentifier: Self.credentialNamespace,
            key: connection.id
        )
        var next = connections
        next.removeAll { $0.id == id }
        try secrets.remove(
            extensionIdentifier: Self.credentialNamespace,
            key: connection.id
        )
        guard persistence.save(next) else {
            if let credential {
                try? secrets.setData(
                    credential,
                    extensionIdentifier: Self.credentialNamespace,
                    key: connection.id
                )
            }
            throw SourceControlProviderConnectionError.persistenceFailed
        }
        connections = next
        publishChange()
    }

    func credential(for connection: SourceControlProviderConnection) throws -> Data? {
        try secrets.data(
            extensionIdentifier: Self.credentialNamespace,
            key: connection.id
        )
    }

    private static func validateCollection(_ values: [SourceControlProviderConnection]) throws {
        guard values.count <= SourceControlProviderConnection.maximumCount else {
            throw SourceControlProviderConnectionError.tooManyConnections
        }
        var ids = Set<String>()
        var hosts = Set<String>()
        for value in values {
            try value.validate()
            guard ids.insert(value.id).inserted else {
                throw SourceControlProviderConnectionError.invalid("duplicate id")
            }
            guard hosts.insert(value.remoteHost).inserted else {
                throw SourceControlProviderConnectionError.duplicateRemoteHost(value.remoteHost)
            }
            if reservedHosts.contains(value.remoteHost) {
                throw SourceControlProviderConnectionError.builtInHost(value.remoteHost)
            }
        }
    }

    private func publishChange() {
        Task {
            await ChangeRequestSummaryStore.shared.invalidateAll()
            NotificationCenter.default.post(SourceControlProviderConnectionsDidChange())
        }
    }
}

struct SourceControlConnectionFetchReading: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    let finalURL: String
    let usedCredential: Bool
}

struct SourceControlConnectionFetchFailure: Error, Sendable {
    let message: String
    let usedCredential: Bool
}

protocol SourceControlConnectionFetching: Sendable {
    func fetch(
        _ request: ExtensionSourceControlFetchRequest,
        connection: SourceControlProviderConnection,
        definition: ExtensionSourceControlProviderDefinition,
        credential: Data?
    ) async -> Result<SourceControlConnectionFetchReading, SourceControlConnectionFetchFailure>
}

/// The network half of a configured forge connection. Every byte of authority enters through
/// the validated host connection; the extension controls only a path below the declared prefix.
final class SourceControlConnectionNetworkBroker: SourceControlConnectionFetching, @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest, SourceControlRedirectGate) async throws
        -> (Data, HTTPURLResponse)

    private let transport: Transport

    init(transport: @escaping Transport = SourceControlURLSessionTransport.live) {
        self.transport = transport
    }

    func fetch(
        _ request: ExtensionSourceControlFetchRequest,
        connection: SourceControlProviderConnection,
        definition: ExtensionSourceControlProviderDefinition,
        credential: Data?
    ) async -> Result<SourceControlConnectionFetchReading, SourceControlConnectionFetchFailure> {
        do {
            try request.validate()
            try connection.validate()
            guard connection.providerID == definition.id,
                  connection.apiPathPrefix == definition.apiPathPrefix,
                  definition.authenticationKinds.contains(connection.authenticationKind),
                  let origin = connection.origin,
                  var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
            else { throw SourceControlProviderConnectionError.providerUnavailable }

            components.path = definition.apiPathPrefix + request.path
            components.queryItems = request.queryItems.map {
                URLQueryItem(name: $0.name, value: $0.value)
            }
            guard let url = components.url else {
                throw SourceControlProviderConnectionError.invalid("request URL")
            }
            var urlRequest = URLRequest(url: url, timeoutInterval: GitHubDefaults.requestTimeout)
            urlRequest.httpMethod = request.method
            request.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
            urlRequest.setValue(GitHubDefaults.userAgent, forHTTPHeaderField: "User-Agent")

            let usedCredential = connection.authenticationKind != .none
            if usedCredential {
                guard let credential, !credential.isEmpty,
                      let token = SourceControlProviderConnection.utf8Token(credential) else {
                    throw SourceControlProviderConnectionError.credentialRequired
                }
                try ExtensionSecretConstraints.validate(value: credential)
                guard !token.unicodeScalars.contains(where: {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                        || CharacterSet.controlCharacters.contains($0)
                }) else {
                    throw SourceControlProviderConnectionError.credentialInvalid
                }
                switch connection.authenticationKind {
                case .none:
                    break
                case .bearerToken:
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                case .authorizationToken:
                    urlRequest.setValue("token \(token)", forHTTPHeaderField: "Authorization")
                case .basicUsernameToken:
                    guard let username = connection.username else {
                        throw SourceControlProviderConnectionError.credentialRequired
                    }
                    let value = Data("\(username):\(token)".utf8).base64EncodedString()
                    urlRequest.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
                }
            }

            guard let gate = SourceControlRedirectGate(
                request: urlRequest,
                apiPathPrefix: definition.apiPathPrefix
            ) else { throw SourceControlProviderConnectionError.invalid("redirect authority") }
            let (data, response) = try await transport(urlRequest, gate)
            guard data.count <= ExtensionBrokeredNetwork.maximumResponseBodyBytes else {
                throw ExtensionBrokeredFetchFailure(
                    message: "The response exceeds the brokered size limit.",
                    credential: usedCredential ? "host-attached" : "anonymous"
                )
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                guard let key = key as? String, let value = value as? String,
                      !ExtensionBrokeredNetwork.deniedResponseHeaders.contains(key.lowercased())
                else { continue }
                headers[key.lowercased()] = String(
                    value.prefix(ExtensionBrokeredNetwork.maximumHeaderValueLength)
                )
            }
            return .success(SourceControlConnectionFetchReading(
                status: response.statusCode,
                headers: headers,
                body: data,
                finalURL: response.url?.absoluteString ?? url.absoluteString,
                usedCredential: usedCredential
            ))
        } catch {
            return .failure(SourceControlConnectionFetchFailure(
                message: error.localizedDescription,
                usedCredential: connection.authenticationKind != .none
            ))
        }
    }
}

struct SourceControlRedirectGate: Sendable {
    private let scheme: String
    private let host: String
    private let port: Int?
    private let method: String
    private let apiPathPrefix: String

    init?(request: URLRequest, apiPathPrefix: String) {
        guard let components = request.url.flatMap({
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }), components.scheme == "https", let host = components.host?.lowercased(),
        components.user == nil, components.password == nil,
        let method = request.httpMethod,
        components.path.hasPrefix(apiPathPrefix + "/") else { return nil }
        scheme = "https"
        self.host = host
        port = components.port
        self.method = method
        self.apiPathPrefix = apiPathPrefix
    }

    func allows(_ request: URLRequest) -> Bool {
        guard let components = request.url.flatMap({
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }) else { return false }
        return components.scheme == scheme
            && components.host?.lowercased() == host
            && components.port == port
            && components.user == nil
            && components.password == nil
            && request.httpMethod == method
            && components.path.hasPrefix(apiPathPrefix + "/")
    }
}

private final class SourceControlRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    let gate: SourceControlRedirectGate

    init(gate: SourceControlRedirectGate) { self.gate = gate }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(gate.allows(request) ? request : nil)
    }
}

private enum SourceControlURLSessionTransport {
    static let live: SourceControlConnectionNetworkBroker.Transport = { request, gate in
        let delegate = SourceControlRedirectDelegate(gate: gate)
        let (data, response) = try await URLSession.shared.data(for: request, delegate: delegate)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}
