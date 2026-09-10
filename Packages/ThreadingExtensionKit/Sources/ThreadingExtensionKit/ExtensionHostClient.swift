import Foundation

/// One complete, atomic component-state publication to Threading's extension host.
///
/// Sending a new value replaces every patch previously published by the same running extension
/// generation. Sending an empty array therefore clears that extension's component UI.
public struct ExtensionComponentPatchPublication: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let patches: [ExtensionComponentPatch]

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        patches: [ExtensionComponentPatch]
    ) {
        self.protocolVersion = protocolVersion
        self.patches = patches
    }

    public func validate() throws {
        var issues: [ExtensionValidationIssue] = []
        if protocolVersion != Self.currentProtocolVersion {
            issues.append(.init(
                path: "protocolVersion",
                message: "expected \(Self.currentProtocolVersion), got \(protocolVersion)"
            ))
        }

        var identifiers: Set<String> = []
        for (index, patch) in patches.enumerated() {
            let path = "patches[\(index)]"
            if patch.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(path).id", message: "must not be empty"))
            } else if !identifiers.insert(patch.id).inserted {
                issues.append(.init(path: "\(path).id", message: "duplicates '\(patch.id)'"))
            }
            if patch.target.component.rawValue.isEmpty {
                issues.append(.init(path: "\(path).target.component", message: "must not be empty"))
            }
            if patch.target.contractVersion < 1 {
                issues.append(.init(
                    path: "\(path).target.contractVersion",
                    message: "must be at least 1"
                ))
            }
            if let entityID = patch.target.entityID,
               entityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(path).target.entityID", message: "must not be empty"))
            }
        }

        if !issues.isEmpty {
            throw ExtensionValidationError(issues: issues)
        }
    }
}

/// Short-lived authority injected into one supervised extension process.
///
/// The bearer token identifies both the extension and its exact process generation. Extensions
/// never put their own identifier in a publication request.
public struct ExtensionHostConnection: Equatable, Sendable {
    public static let urlEnvironmentKey = "THREADING_EXTENSION_HOST_URL"
    public static let tokenEnvironmentKey = "THREADING_EXTENSION_HOST_TOKEN"
    /// The inherited socket the supported runner installs. Preferred over the loopback URL when
    /// both are present, since a runner-launched extension may hold no network authority at all.
    public static let descriptorEnvironmentKey = "THREADING_EXTENSION_HOST_FD"

    /// The authority used to build request targets in descriptor mode.
    ///
    /// Requests are still addressed by path, so every call site composes URLs exactly as it does
    /// over loopback; only the carrier changes. The host is never contacted by this name.
    public static let descriptorBaseURL = URL(string: "http://threading-extension-host/v1")!

    public let baseURL: URL
    public let bearerToken: String
    /// Non-nil when the host is reached over an inherited socket rather than a loopback port.
    public let descriptor: Int32?

    public init(baseURL: URL, bearerToken: String, descriptor: Int32? = nil) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.descriptor = descriptor
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let token = environment[Self.tokenEnvironmentKey], !token.isEmpty else {
            throw ExtensionHostClientError.configurationUnavailable
        }
        if let rawDescriptor = environment[Self.descriptorEnvironmentKey],
           let descriptor = Int32(rawDescriptor),
           descriptor >= 0 {
            self.init(
                baseURL: Self.descriptorBaseURL,
                bearerToken: token,
                descriptor: descriptor
            )
            return
        }
        guard let rawURL = environment[Self.urlEnvironmentKey],
              let baseURL = URL(string: rawURL) else {
            throw ExtensionHostClientError.configurationUnavailable
        }
        self.init(baseURL: baseURL, bearerToken: token)
    }
}

public enum ExtensionHostClientError: Error, Equatable, LocalizedError {
    case configurationUnavailable
    case invalidResponse
    case rejected(status: Int, message: String)
    case hostClosed

    public var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            return "Threading did not grant this process an extension-host connection."
        case .invalidResponse:
            return "Threading returned an invalid extension-host response."
        case .rejected(let status, let message):
            return "Threading rejected the extension-host request (\(status)): \(message)"
        case .hostClosed:
            return "Threading closed this extension's host connection."
        }
    }
}

/// Foundation-only client for the extension host's independent loopback channel.
public struct ExtensionHostClient: Sendable {
    private struct Failure: Decodable {
        let error: String
    }

    public let connection: ExtensionHostConnection

    public init(connection: ExtensionHostConnection) {
        self.connection = connection
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        connection = try ExtensionHostConnection(environment: environment)
    }

    public func publishComponentPatches(_ patches: [ExtensionComponentPatch]) async throws {
        let publication = ExtensionComponentPatchPublication(patches: patches)
        try publication.validate()
        _ = try await request(
            path: "component-patches",
            method: "PUT",
            body: JSONEncoder().encode(publication)
        )
    }

    /// Atomically replaces this process generation's facts for the named domain subjects.
    public func publishFacts(
        _ facts: [ExtensionFact],
        replacing subjects: [ExtensionFactSubject]
    ) async throws {
        let publication = ExtensionFactPublication(
            replacingSubjects: subjects,
            facts: facts
        )
        try publication.validate()
        _ = try await request(
            path: "facts",
            method: "PUT",
            body: JSONEncoder().encode(publication)
        )
    }

    public func publishIdentityResolutions(
        providerIcons: [ExtensionProviderIconResolution] = [],
        accountIcons: [ExtensionAccountIconResolution] = []
    ) async throws {
        let publication = ExtensionIdentityResolutionPublication(
            providerIcons: providerIcons,
            accountIcons: accountIcons
        )
        try publication.validate()
        _ = try await request(
            path: "identity-resolutions",
            method: "PUT",
            body: JSONEncoder().encode(publication)
        )
    }

    /// Returns the safe project snapshot and a cursor from the same host-data instant.
    public func projects() async throws -> ExtensionProjectSnapshotPage {
        try await get("projects", as: ExtensionProjectSnapshotPage.self)
    }

    public func project(id: String) async throws -> ExtensionProjectSnapshotResult {
        try await get(
            "projects/\(encodedPathComponent(id))",
            as: ExtensionProjectSnapshotResult.self
        )
    }

    /// Lists the project's documents matching a bounded query, as opaque handles.
    ///
    /// Requires `host.project.files.read`. The answer carries handles and bounded metadata; it
    /// never carries bytes or an absolute path, and a handle is only usable by naming it as an
    /// `ExtensionMediaSource.fileHandle` for a host renderer to resolve.
    public func projectFiles(_ query: ExtensionFileQuery) async throws -> ExtensionFilePage {
        try query.validate()
        let data = try await request(
            path: "project-files/query",
            method: "POST",
            body: JSONEncoder().encode(query)
        )
        let page = try decode(ExtensionFilePage.self, from: data)
        guard page.protocolVersion == ExtensionFilePage.currentProtocolVersion,
              page.handles.count <= query.maximumResults else {
            throw ExtensionHostClientError.invalidResponse
        }
        return page
    }

    /// Returns sessions across projects. Filesystem and transcript locations are never included.
    public func sessions() async throws -> ExtensionSessionSnapshotPage {
        try await get("sessions", as: ExtensionSessionSnapshotPage.self)
    }

    public func session(id: String) async throws -> ExtensionSessionSnapshotResult {
        try await get(
            "sessions/\(encodedPathComponent(id))",
            as: ExtensionSessionSnapshotResult.self
        )
    }

    /// Reads only the process and listening-port rows Threading attributes to this session.
    ///
    /// This does not expose the process table, arguments, environment, open files, or an
    /// arbitrary PID query.
    public func sessionRuntime(id: String) async throws -> ExtensionSessionRuntimeSnapshot {
        let snapshot = try await get(
            "sessions/\(encodedPathComponent(id))/runtime",
            as: ExtensionSessionRuntimeSnapshot.self
        )
        guard snapshot.version == ExtensionSessionRuntimeSnapshot.currentVersion,
              snapshot.sessionID == id else {
            throw ExtensionHostClientError.invalidResponse
        }
        return snapshot
    }

    public func providers() async throws -> ExtensionProviderSnapshotPage {
        try await get("providers", as: ExtensionProviderSnapshotPage.self)
    }

    public func provider(id: String) async throws -> ExtensionProviderSnapshotResult {
        try await get(
            "providers/\(encodedPathComponent(id))",
            as: ExtensionProviderSnapshotResult.self
        )
    }

    public func accounts() async throws -> ExtensionAccountSnapshotPage {
        try await get("accounts", as: ExtensionAccountSnapshotPage.self)
    }

    public func account(id: String) async throws -> ExtensionAccountSnapshotResult {
        try await get(
            "accounts/\(encodedPathComponent(id))",
            as: ExtensionAccountSnapshotResult.self
        )
    }

    /// Calls one exact service dependency declared by this extension's manifest.
    ///
    /// Threading's bearer token supplies caller identity. The provider receives that verified
    /// identity and never sees the consumer's token or storage.
    public func callService(
        providerIdentifier: String,
        serviceID: String,
        version: Int = 1,
        arguments: ExtensionJSONValue = .emptyObject
    ) async throws -> ExtensionJSONValue {
        let call = ExtensionServiceCall(
            serviceVersion: version,
            arguments: arguments
        )
        try call.validate()
        let path = "services/\(encodedPathComponent(providerIdentifier))"
            + "/\(encodedPathComponent(serviceID))"
        let data = try await request(
            path: path,
            method: "POST",
            body: JSONEncoder().encode(call)
        )
        let result = try decode(ExtensionServiceCallResult.self, from: data)
        guard result.protocolVersion == ExtensionServiceCallResult.currentProtocolVersion,
              result.providerIdentifier == providerIdentifier,
              result.serviceID == serviceID,
              result.serviceVersion == version else {
            throw ExtensionHostClientError.invalidResponse
        }
        return result.value
    }

    /// Invokes one operation declared by this extension's own companion.
    ///
    /// The core sends its normal host authority to Threading, never to the companion. Threading
    /// derives extension identity from that authority, starts an on-demand worker if necessary,
    /// and relays only this bounded operation envelope.
    public func callCompanion(
        _ companionID: String,
        operation operationID: String,
        arguments: ExtensionJSONValue = .emptyObject
    ) async throws -> ExtensionJSONValue {
        let call = ExtensionCompanionOperationCall(arguments: arguments)
        try call.validate()
        let path = "companions/\(encodedPathComponent(companionID))"
            + "/operations/\(encodedPathComponent(operationID))"
        let data = try await request(
            path: path,
            method: "POST",
            body: JSONEncoder().encode(call)
        )
        let result = try decode(
            ExtensionCompanionOperationCallResult.self,
            from: data
        )
        guard result.protocolVersion
                == ExtensionCompanionOperationCallResult.currentProtocolVersion,
              result.companionID == companionID,
              result.operationID == operationID else {
            throw ExtensionHostClientError.invalidResponse
        }
        return result.value
    }

    /// Performs one HTTPS fetch through the host broker.
    ///
    /// Requires the `network.brokered` capability, and the URL's host and the method must
    /// match one of the manifest's declared `networkGrants` — anything else is refused with
    /// `ExtensionHostClientError.rejected`. When the matching grant names a credential
    /// provider, Threading attaches the user's best connected credential itself and reports
    /// which tier answered in the response; the extension never receives a token.
    ///
    /// A completed HTTP exchange returns whatever status the server gave — a 404 is an
    /// answer, not an error, and interpreting it is the caller's business. Only a transport
    /// failure (DNS, timeout) throws `ExtensionBrokeredFetchFailure`.
    public func brokeredFetch(
        _ call: ExtensionBrokeredFetchRequest
    ) async throws -> ExtensionBrokeredFetchResponse {
        try call.validate()
        let data = try await request(
            path: "network/fetch",
            method: "POST",
            body: JSONEncoder().encode(call)
        )
        let result = try decode(ExtensionBrokeredFetchResult.self, from: data)
        guard result.protocolVersion == ExtensionBrokeredFetchResult.currentProtocolVersion
        else {
            throw ExtensionHostClientError.invalidResponse
        }
        if let failure = result.failure {
            throw failure
        }
        guard let response = result.response,
              (100...599).contains(response.status),
              response.bodyBase64.count
                  <= ExtensionBrokeredNetwork.maximumResponseBodyBytes * 4 / 3 + 4 else {
            throw ExtensionHostClientError.invalidResponse
        }
        return response
    }

    /// Performs one read beneath a host-configured source-control connection.
    ///
    /// The call names an opaque connection and an API-relative path. Threading selects the exact
    /// approved HTTPS origin, checks provider ownership and path scope, and attaches the Keychain
    /// credential. The raw secret is never returned to this process.
    public func sourceControlFetch(
        _ call: ExtensionSourceControlFetchRequest
    ) async throws -> ExtensionSourceControlFetchResponse {
        try call.validate()
        let data = try await request(
            path: "source-control/fetch",
            method: "POST",
            body: JSONEncoder().encode(call)
        )
        let result = try decode(ExtensionSourceControlFetchResult.self, from: data)
        guard result.protocolVersion == ExtensionSourceControlFetchResult.currentProtocolVersion
        else { throw ExtensionHostClientError.invalidResponse }
        if let failure = result.failure { throw failure }
        guard let response = result.response,
              (100...599).contains(response.status),
              response.bodyBase64.count
                <= ExtensionBrokeredNetwork.maximumResponseBodyBytes * 4 / 3 + 4 else {
            throw ExtensionHostClientError.invalidResponse
        }
        return response
    }

    /// Returns opaque Keychain data owned by this extension, or nil when the key is absent.
    public func secretData(forKey key: String) async throws -> Data? {
        try ExtensionSecretConstraints.validate(key: key)
        let result = try await get(
            "secrets/\(encodedPathComponent(key))",
            as: ExtensionSecretResult.self
        )
        guard result.protocolVersion == ExtensionSecretResult.currentProtocolVersion else {
            throw ExtensionHostClientError.invalidResponse
        }
        if let value = result.value {
            do {
                try ExtensionSecretConstraints.validate(value: value)
            } catch {
                throw ExtensionHostClientError.invalidResponse
            }
        }
        return result.value
    }

    public func setSecretData(_ value: Data, forKey key: String) async throws {
        try ExtensionSecretConstraints.validate(key: key)
        let write = ExtensionSecretWrite(value: value)
        try write.validate()
        _ = try await request(
            path: "secrets/\(encodedPathComponent(key))",
            method: "PUT",
            body: JSONEncoder().encode(write)
        )
    }

    public func secret(forKey key: String) async throws -> String? {
        guard let data = try await secretData(forKey: key) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw ExtensionHostClientError.invalidResponse
        }
        return value
    }

    public func setSecret(_ value: String, forKey key: String) async throws {
        try await setSecretData(Data(value.utf8), forKey: key)
    }

    public func removeSecret(forKey key: String) async throws {
        try ExtensionSecretConstraints.validate(key: key)
        _ = try await request(
            path: "secrets/\(encodedPathComponent(key))",
            method: "DELETE"
        )
    }

    /// Lists names only. Secret values remain individually requested and are never bulk-exported.
    public func secretKeys() async throws -> [String] {
        let result = try await get("secrets", as: ExtensionSecretKeyList.self)
        guard result.protocolVersion == ExtensionSecretKeyList.currentProtocolVersion,
              result.keys.count <= ExtensionSecretConstraints.maximumKeys,
              result.keys == result.keys.sorted(),
              Set(result.keys).count == result.keys.count else {
            throw ExtensionHostClientError.invalidResponse
        }
        do {
            try result.keys.forEach {
                try ExtensionSecretConstraints.validate(key: $0)
            }
        } catch {
            throw ExtensionHostClientError.invalidResponse
        }
        return result.keys
    }

    /// Reads changes after a cursor returned by a snapshot or previous event page.
    ///
    /// When `hasMore` is true, immediately request another page using `nextCursor`.
    public func events(
        after cursor: Int64,
        limit: Int = 100
    ) async throws -> ExtensionHostEventPage {
        guard var components = URLComponents(
            url: connection.baseURL.appendingPathComponent("events"),
            resolvingAgainstBaseURL: false
        ) else {
            throw ExtensionHostClientError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "after", value: String(cursor)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else {
            throw ExtensionHostClientError.invalidResponse
        }
        let data = try await request(url: url, method: "GET")
        return try decode(ExtensionHostEventPage.self, from: data)
    }

    private func get<Value: Decodable>(
        _ path: String,
        as type: Value.Type
    ) async throws -> Value {
        let data = try await request(path: path, method: "GET")
        return try decode(type, from: data)
    }

    private func request(
        path: String,
        method: String,
        body: Data? = nil
    ) async throws -> Data {
        try await request(
            url: connection.baseURL.appendingPathComponent(path),
            method: method,
            body: body
        )
    }

    private func request(
        url: URL,
        method: String,
        body: Data? = nil
    ) async throws -> Data {
#if os(WASI)
        // A Wasm guest has no socket or URL loading APIs. The descriptor value is only a
        // transport-selection sentinel; the native runner owns fd 3 and implements the guest's
        // one `threading.host_exchange` import.
        return try await requestOverDescriptor(
            connection.descriptor ?? 3,
            url: url,
            method: method,
            body: body
        )
#else
        if let descriptor = connection.descriptor {
            return try await requestOverDescriptor(
                descriptor,
                url: url,
                method: method,
                body: body
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(
            "Bearer \(connection.bearerToken)",
            forHTTPHeaderField: "Authorization"
        )
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExtensionHostClientError.invalidResponse
        }
        return try validate(status: http.statusCode, data: data)
#endif
    }

    private func requestOverDescriptor(
        _ descriptor: Int32,
        url: URL,
        method: String,
        body: Data? = nil
    ) async throws -> Data {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ExtensionHostClientError.invalidResponse
        }
        var target = components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            target += "?" + query
        }

        let response = try await ExtensionHostDescriptorTransport
            .shared(for: descriptor)
            .send(
                method: method,
                requestTarget: target,
                bearerToken: connection.bearerToken,
                contentType: body == nil ? nil : "application/json",
                body: body
            )
        return try validate(status: response.status, data: response.body)
    }

    private func validate(status: Int, data: Data) throws -> Data {
        guard (200..<300).contains(status) else {
#if os(WASI)
            let fallback = "HTTP status \(status)"
#else
            let fallback = HTTPURLResponse.localizedString(forStatusCode: status)
#endif
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error)
                ?? fallback
            throw ExtensionHostClientError.rejected(status: status, message: message)
        }
        return data
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ExtensionHostClientError.invalidResponse
        }
    }

    private func encodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-._~")
            )
        ) ?? value
    }
}
