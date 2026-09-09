import Foundation

public enum PeerControlPlaneBounds {
    public static let maximumRequestBytes = 64 * 1024
    public static let maximumResponseBytes = 64 * 1024
    public static let maximumIdentityTokenBytes = 16 * 1024
    public static let maximumBearerBytes = 4 * 1024
    public static let maximumDisplayNameBytes = 128
    public static let requestTimeout: TimeInterval = 15
}

public enum PeerControlPlaneError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidRequest
    case invalidCredential
    case responseTooLarge(actual: Int, limit: Int)
    case invalidResponse
    case rejected(status: Int, code: String)
    case transport(String)
}

/// A service bearer whose description can safely appear in diagnostics.
public struct PeerControlPlaneBearer: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    fileprivate let rawValue: String

    public init(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= PeerControlPlaneBounds.maximumBearerBytes,
              !value.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f })
        else {
            throw PeerControlPlaneError.invalidCredential
        }
        rawValue = value
    }

    public var description: String { "<redacted>" }

    /// Gives a narrowly scoped caller access for Keychain serialization or an authenticated
    /// protocol field. Prefer passing the bearer type itself everywhere else.
    public func withValue<Result>(_ body: (String) throws -> Result) rethrows -> Result {
        try body(rawValue)
    }

    public func withValue<Result>(
        _ body: (String) async throws -> Result
    ) async rethrows -> Result {
        try await body(rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PeerControlPlaneSession: Codable, Equatable, Hashable, Sendable {
    public let accountID: String
    public let accessToken: PeerControlPlaneBearer
    public let accessTokenExpiresAt: Date
    public let refreshToken: PeerControlPlaneBearer
    public let refreshTokenExpiresAt: Date

    public init(
        accountID: String,
        accessToken: PeerControlPlaneBearer,
        accessTokenExpiresAt: Date,
        refreshToken: PeerControlPlaneBearer,
        refreshTokenExpiresAt: Date
    ) {
        self.accountID = accountID
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }
}

public struct PeerHostServiceCredential: Codable, Equatable, Hashable, Sendable {
    public let hostID: String
    public let credential: PeerControlPlaneBearer
    public let expiresAt: Date

    public init(hostID: String, credential: PeerControlPlaneBearer, expiresAt: Date) {
        self.hostID = hostID
        self.credential = credential
        self.expiresAt = expiresAt
    }
}

public struct PeerDeviceServiceCredential: Codable, Equatable, Hashable, Sendable {
    public let hostID: String
    public let deviceID: String
    public let credential: PeerControlPlaneBearer
    public let expiresAt: Date

    public init(
        hostID: String,
        deviceID: String,
        credential: PeerControlPlaneBearer,
        expiresAt: Date
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.credential = credential
        self.expiresAt = expiresAt
    }
}

public struct PeerDevelopmentSignInTransaction: Equatable, Sendable {
    public let transactionID: PeerControlPlaneBearer
    public let pollToken: PeerControlPlaneBearer
    public let authorizationURL: URL
    public let expiresAt: Date

    public init(
        transactionID: PeerControlPlaneBearer,
        pollToken: PeerControlPlaneBearer,
        authorizationURL: URL,
        expiresAt: Date
    ) {
        self.transactionID = transactionID
        self.pollToken = pollToken
        self.authorizationURL = authorizationURL
        self.expiresAt = expiresAt
    }
}

public struct PeerPushRegistration: Equatable, Sendable {
    public let registrationID: String
    public let hostID: String
    public let deviceID: String
    public let environment: String

    public init(
        registrationID: String,
        hostID: String,
        deviceID: String,
        environment: String
    ) {
        self.registrationID = registrationID
        self.hostID = hostID
        self.deviceID = deviceID
        self.environment = environment
    }
}

public struct PeerPushDeliveryResult: Codable, Equatable, Hashable, Sendable {
    public let accepted: Bool
    public let statusCode: Int
    public let reason: String
    public let apnsID: String?

    public init(accepted: Bool, statusCode: Int, reason: String, apnsID: String?) {
        self.accepted = accepted
        self.statusCode = statusCode
        self.reason = reason
        self.apnsID = apnsID
    }

    fileprivate func validated() throws -> Self {
        guard (100...599).contains(statusCode), accepted == (statusCode == 200),
              isBoundedNonEmpty(reason, maximumBytes: 256),
              apnsID.map({ isBoundedNonEmpty($0, maximumBytes: 128) }) ?? true
        else {
            throw PeerControlPlaneError.invalidResponse
        }
        return self
    }
}

/// HTTPS endpoint for the account/enrollment API and WebSocket rendezvous API.
/// Plain HTTP is accepted only for a loopback development service.
public struct PeerControlPlaneServiceEndpoint: Equatable, Sendable {
    public let baseURL: URL

    public init(_ url: URL) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            throw PeerControlPlaneError.invalidEndpoint
        }
        guard scheme == "https" || (scheme == "http" && Self.isLoopback(host)) else {
            throw PeerControlPlaneError.invalidEndpoint
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        guard let normalized = components.url else {
            throw PeerControlPlaneError.invalidEndpoint
        }
        baseURL = normalized
    }

    public var rendezvousEndpoint: PeerRendezvousServiceEndpoint {
        // The endpoint was already constrained more strictly than the WebSocket endpoint.
        try! PeerRendezvousServiceEndpoint(baseURL)
    }

    public var isLoopback: Bool {
        guard let host = baseURL.host?.lowercased() else { return false }
        return Self.isLoopback(host)
    }

    fileprivate func route(_ components: String...) -> URL {
        components.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

/// Low-frequency, bounded account/enrollment client. It deliberately creates one ephemeral
/// URLSession per request so cookies, URL credentials, caches, and bearer headers cannot persist.
public struct PeerControlPlaneClient: Sendable {
    public let endpoint: PeerControlPlaneServiceEndpoint

    public init(endpoint: PeerControlPlaneServiceEndpoint) {
        self.endpoint = endpoint
    }

    public func signInWithApple(
        identityToken: String,
        authorizationCode: String,
        rawNonce: String
    ) async throws -> PeerControlPlaneSession {
        guard !identityToken.isEmpty,
              identityToken.utf8.count <= PeerControlPlaneBounds.maximumIdentityTokenBytes,
              isBoundedNonEmpty(authorizationCode, maximumBytes: 4 * 1024),
              isBoundedNonEmpty(rawNonce, maximumBytes: 512)
        else {
            throw PeerControlPlaneError.invalidRequest
        }
        let response: SessionResponse = try await request(
            method: "POST",
            url: endpoint.route("v1", "auth", "apple"),
            body: AppleSignInRequest(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: rawNonce
            )
        )
        return try response.validated()
    }

    /// Authenticates against the explicit loopback-only development route. The production
    /// service does not expose this route and a non-loopback endpoint is rejected client-side.
    public func signInForLocalDevelopment() async throws -> PeerControlPlaneSession {
        guard endpoint.isLoopback else { throw PeerControlPlaneError.invalidEndpoint }
        let response: SessionResponse = try await request(
            method: "POST",
            url: endpoint.route("v1", "auth", "local-development"),
            body: EmptyRequest()
        )
        return try response.validated()
    }

    /// Begins the browser-authenticated flow exposed only by the isolated development service.
    /// The verifier never crosses this request; only its SHA-256 challenge does.
    public func startDevelopmentSignIn(
        hostID: String,
        codeChallenge: String
    ) async throws -> PeerDevelopmentSignInTransaction {
        try validateIdentifier(hostID)
        guard codeChallenge.count == 64,
              codeChallenge.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw PeerControlPlaneError.invalidRequest
        }
        let response: DevelopmentSignInStartResponse = try await request(
            method: "POST",
            url: endpoint.route("v1", "auth", "development", "start"),
            body: DevelopmentSignInStartRequest(hostID: hostID, codeChallenge: codeChallenge)
        )
        return try response.validated(endpoint: endpoint)
    }

    public func redeemDevelopmentSignIn(
        transaction: PeerDevelopmentSignInTransaction,
        hostID: String,
        codeVerifier: String
    ) async throws -> PeerControlPlaneSession {
        try validateIdentifier(hostID)
        guard (43...128).contains(codeVerifier.count),
              codeVerifier.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || scalar.value == 45 || scalar.value == 95
              }), transaction.expiresAt > Date() else {
            throw PeerControlPlaneError.invalidRequest
        }
        let response: SessionResponse = try await transaction.transactionID.withValue {
            transactionID in
            try await transaction.pollToken.withValue { pollToken in
                try await request(
                    method: "POST",
                    url: endpoint.route("v1", "auth", "development", "redeem"),
                    body: DevelopmentSignInRedeemRequest(
                        transactionID: transactionID,
                        pollToken: pollToken,
                        codeVerifier: codeVerifier,
                        hostID: hostID
                    )
                )
            }
        }
        return try response.validated()
    }

    public func refresh(
        refreshToken: PeerControlPlaneBearer
    ) async throws -> PeerControlPlaneSession {
        let response: SessionResponse = try await request(
            method: "POST",
            url: endpoint.route("v1", "auth", "refresh"),
            body: RefreshRequest(refreshToken: refreshToken.rawValue)
        )
        return try response.validated()
    }

    public func signOut(refreshToken: PeerControlPlaneBearer) async throws {
        try await requestWithoutResponse(
            method: "POST",
            url: endpoint.route("v1", "auth", "signout"),
            body: RefreshRequest(refreshToken: refreshToken.rawValue)
        )
    }

    public func enrollHost(
        accessToken: PeerControlPlaneBearer,
        hostID: String,
        displayName: String
    ) async throws -> PeerHostServiceCredential {
        try validateIdentifier(hostID)
        guard isBoundedNonEmpty(
            displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumBytes: PeerControlPlaneBounds.maximumDisplayNameBytes
        ) else {
            throw PeerControlPlaneError.invalidRequest
        }
        let response: HostCredentialResponse = try await request(
            method: "POST",
            url: endpoint.route("v1", "hosts"),
            bearer: accessToken,
            body: HostEnrollmentRequest(hostID: hostID, displayName: displayName)
        )
        return try response.validated(expectedHostID: hostID)
    }

    public func rotateHostCredential(
        accessToken: PeerControlPlaneBearer,
        hostID: String
    ) async throws -> PeerHostServiceCredential {
        try validateIdentifier(hostID)
        let response: HostCredentialResponse = try await request(
            method: "POST",
            url: endpoint.route("v1", "hosts", hostID, "credentials", "rotate"),
            bearer: accessToken,
            body: EmptyRequest()
        )
        return try response.validated(expectedHostID: hostID)
    }

    public func issueDeviceCredential(
        hostCredential: PeerControlPlaneBearer,
        hostID: String,
        deviceID: String,
        lifetimeSeconds: Int? = nil
    ) async throws -> PeerDeviceServiceCredential {
        try validateIdentifier(hostID)
        try validateIdentifier(deviceID)
        if let lifetimeSeconds,
           !(60...(30 * 24 * 60 * 60)).contains(lifetimeSeconds) {
            throw PeerControlPlaneError.invalidRequest
        }
        let response: DeviceCredentialResponse = try await request(
            method: "POST",
            url: endpoint.route("v1", "hosts", hostID, "devices"),
            bearer: hostCredential,
            body: DeviceEnrollmentRequest(
                deviceID: deviceID,
                lifetimeSeconds: lifetimeSeconds
            )
        )
        return try response.validated(expectedHostID: hostID, expectedDeviceID: deviceID)
    }

    public func revokeDeviceCredential(
        hostCredential: PeerControlPlaneBearer,
        hostID: String,
        deviceID: String
    ) async throws {
        try validateIdentifier(hostID)
        try validateIdentifier(deviceID)
        try await requestWithoutResponse(
            method: "DELETE",
            url: endpoint.route("v1", "hosts", hostID, "devices", deviceID),
            bearer: hostCredential
        )
    }

    public func revokeHost(
        accessToken: PeerControlPlaneBearer,
        hostID: String
    ) async throws {
        try validateIdentifier(hostID)
        try await requestWithoutResponse(
            method: "DELETE",
            url: endpoint.route("v1", "hosts", hostID),
            bearer: accessToken
        )
    }

    /// Sends one already-authorized, bounded notification through the hosted APNs broker. The
    /// generic payload keeps the peer package independent of ThreadingRemoteKit; the endpoint is
    /// fixed and the Worker independently validates its exact event schema.
    public func sendHostedPush<Payload: Encodable & Sendable>(
        hostCredential: PeerControlPlaneBearer,
        payload: Payload
    ) async throws -> PeerPushDeliveryResult {
        let response: PeerPushDeliveryResult = try await request(
            method: "POST",
            url: endpoint.route("v1", "push"),
            bearer: hostCredential,
            body: payload
        )
        return try response.validated()
    }

    /// Sends a content-free silent recall through the separately authenticated endpoint.
    public func sendHostedPushRetraction<Payload: Encodable & Sendable>(
        hostCredential: PeerControlPlaneBearer,
        payload: Payload
    ) async throws -> PeerPushDeliveryResult {
        let response: PeerPushDeliveryResult = try await request(
            method: "POST",
            url: endpoint.route("v1", "push", "retractions"),
            bearer: hostCredential,
            body: payload
        )
        return try response.validated()
    }

    /// Stores the APNs token under the paired phone's device credential and returns the only
    /// recipient identifier a host is allowed to use for subsequent sends.
    public func registerPushRecipient(
        deviceCredential: PeerDeviceServiceCredential,
        deviceToken: String,
        environment: String
    ) async throws -> PeerPushRegistration {
        try validateIdentifier(deviceCredential.hostID)
        try validateIdentifier(deviceCredential.deviceID)
        guard deviceCredential.expiresAt > Date(),
              (environment == "sandbox" || environment == "production"),
              (32...512).contains(deviceToken.count),
              deviceToken.count.isMultiple(of: 2),
              deviceToken.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw PeerControlPlaneError.invalidRequest
        }
        let response: PushRegistrationResponse = try await request(
            method: "POST",
            url: endpoint.route("v1", "push", "registrations"),
            bearer: deviceCredential.credential,
            body: PushRegistrationRequest(
                deviceToken: deviceToken,
                environment: environment
            )
        )
        return try response.validated(
            expectedHostID: deviceCredential.hostID,
            expectedDeviceID: deviceCredential.deviceID,
            expectedEnvironment: environment
        )
    }

    public func deleteAccount(accessToken: PeerControlPlaneBearer) async throws {
        try await requestWithoutResponse(
            method: "DELETE",
            url: endpoint.route("v1", "account"),
            bearer: accessToken
        )
    }

    /// The notification schema version this service advertises, or `0` where it publishes none.
    ///
    /// Unauthenticated, because it is the one question a client must be able to ask *before* it
    /// has anything to send: the broker validates a notification against an exact key list and
    /// refuses the whole request over one field it has not heard of. A service too old to
    /// publish the number is exactly the service that cannot take the newest schema, so its
    /// silence answers the question.
    public func notificationProtocolVersion() async throws -> Int {
        let health: ServiceHealth = try await get(url: endpoint.route("health"))
        return health.notificationProtocol ?? 0
    }

    private func get<Response: Decodable>(url: URL) async throws -> Response {
        let request = try makeRequest(method: "GET", url: url, bearer: nil)
        let (data, response) = try await BoundedHTTP.perform(request)
        try validateHTTP(response, data: data, expectedStatuses: 200..<300)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw PeerControlPlaneError.invalidResponse
        }
    }

    private func request<Body: Encodable, Response: Decodable>(
        method: String,
        url: URL,
        bearer: PeerControlPlaneBearer? = nil,
        body: Body
    ) async throws -> Response {
        var request = try makeRequest(method: method, url: url, bearer: bearer)
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw PeerControlPlaneError.invalidRequest
        }
        guard encoded.count <= PeerControlPlaneBounds.maximumRequestBytes else {
            throw PeerControlPlaneError.invalidRequest
        }
        request.httpBody = encoded
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await BoundedHTTP.perform(request)
        try validateHTTP(response, data: data, expectedStatuses: 200..<300)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw PeerControlPlaneError.invalidResponse
        }
    }

    private func requestWithoutResponse(
        method: String,
        url: URL,
        bearer: PeerControlPlaneBearer
    ) async throws {
        let request = try makeRequest(method: method, url: url, bearer: bearer)
        let (data, response) = try await BoundedHTTP.perform(request)
        try validateHTTP(response, data: data, expectedStatuses: 200..<300)
    }

    private func requestWithoutResponse<Body: Encodable>(
        method: String,
        url: URL,
        bearer: PeerControlPlaneBearer? = nil,
        body: Body
    ) async throws {
        var request = try makeRequest(method: method, url: url, bearer: bearer)
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw PeerControlPlaneError.invalidRequest
        }
        guard encoded.count <= PeerControlPlaneBounds.maximumRequestBytes else {
            throw PeerControlPlaneError.invalidRequest
        }
        request.httpBody = encoded
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await BoundedHTTP.perform(request)
        try validateHTTP(response, data: data, expectedStatuses: 200..<300)
    }

    private func makeRequest(
        method: String,
        url: URL,
        bearer: PeerControlPlaneBearer?
    ) throws -> URLRequest {
        guard url.scheme == "https" || url.scheme == "http" else {
            throw PeerControlPlaneError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = PeerControlPlaneBounds.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer.rawValue)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

/// Only the field the client acts on. `/health` is a public document that may grow, so decoding
/// it exactly would make an ordinary addition on the service look like an unreachable service.
private struct ServiceHealth: Decodable {
    let notificationProtocol: Int?
}

private struct AppleSignInRequest: Encodable {
    let identityToken: String
    let authorizationCode: String
    let nonce: String
}

private struct DevelopmentSignInStartRequest: Encodable {
    let hostID: String
    let codeChallenge: String
}

private struct DevelopmentSignInRedeemRequest: Encodable {
    let transactionID: String
    let pollToken: String
    let codeVerifier: String
    let hostID: String
}

private struct PushRegistrationRequest: Encodable {
    let deviceToken: String
    let environment: String
}

private struct RefreshRequest: Encodable { let refreshToken: String }
private struct HostEnrollmentRequest: Encodable { let hostID: String; let displayName: String }
private struct DeviceEnrollmentRequest: Encodable {
    let deviceID: String
    let lifetimeSeconds: Int?
}
private struct EmptyRequest: Encodable {}

private struct DevelopmentSignInStartResponse: Decodable {
    let transactionID: String
    let pollToken: String
    let authorizationURL: String
    let expiresAt: Double

    func validated(
        endpoint: PeerControlPlaneServiceEndpoint,
        now: Date = Date()
    ) throws -> PeerDevelopmentSignInTransaction {
        guard let url = URL(string: authorizationURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == endpoint.baseURL.scheme,
              components.host?.lowercased() == endpoint.baseURL.host?.lowercased(),
              components.port == endpoint.baseURL.port,
              components.path == "/v1/auth/development/authorize",
              components.fragment == nil,
              components.queryItems?.count == 1,
              components.queryItems?.first?.name == "transaction",
              components.queryItems?.first?.value == transactionID else {
            throw PeerControlPlaneError.invalidResponse
        }
        let expiry = try validatedFutureDate(expiresAt, now: now)
        guard expiry <= now.addingTimeInterval(10 * 60) else {
            throw PeerControlPlaneError.invalidResponse
        }
        return try PeerDevelopmentSignInTransaction(
            transactionID: PeerControlPlaneBearer(transactionID),
            pollToken: PeerControlPlaneBearer(pollToken),
            authorizationURL: url,
            expiresAt: expiry
        )
    }
}

private struct PushRegistrationResponse: Decodable {
    let registrationID: String
    let hostID: String
    let deviceID: String
    let environment: String

    func validated(
        expectedHostID: String,
        expectedDeviceID: String,
        expectedEnvironment: String
    ) throws -> PeerPushRegistration {
        guard hostID == expectedHostID,
              deviceID == expectedDeviceID,
              environment == expectedEnvironment,
              registrationID.hasPrefix("th_push_"),
              (40...256).contains(registrationID.count),
              registrationID.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || scalar.value == 45 || scalar.value == 95
              }) else {
            throw PeerControlPlaneError.invalidResponse
        }
        return PeerPushRegistration(
            registrationID: registrationID,
            hostID: hostID,
            deviceID: deviceID,
            environment: environment
        )
    }
}

private struct SessionResponse: Decodable {
    let accessToken: String
    let accessTokenExpiresAt: Double
    let refreshToken: String
    let refreshTokenExpiresAt: Double
    let accountID: String

    func validated(now: Date = Date()) throws -> PeerControlPlaneSession {
        try validateIdentifier(accountID)
        let accessExpiry = try validatedFutureDate(accessTokenExpiresAt, now: now)
        let refreshExpiry = try validatedFutureDate(refreshTokenExpiresAt, now: now)
        guard refreshExpiry > accessExpiry else { throw PeerControlPlaneError.invalidResponse }
        return try PeerControlPlaneSession(
            accountID: accountID,
            accessToken: PeerControlPlaneBearer(accessToken),
            accessTokenExpiresAt: accessExpiry,
            refreshToken: PeerControlPlaneBearer(refreshToken),
            refreshTokenExpiresAt: refreshExpiry
        )
    }
}

private struct HostCredentialResponse: Decodable {
    let hostID: String
    let credential: String
    let expiresAt: Double

    func validated(expectedHostID: String, now: Date = Date()) throws -> PeerHostServiceCredential {
        guard hostID == expectedHostID else { throw PeerControlPlaneError.invalidResponse }
        return try PeerHostServiceCredential(
            hostID: hostID,
            credential: PeerControlPlaneBearer(credential),
            expiresAt: validatedFutureDate(expiresAt, now: now)
        )
    }
}

private struct DeviceCredentialResponse: Decodable {
    let hostID: String
    let deviceID: String
    let credential: String
    let expiresAt: Double

    func validated(
        expectedHostID: String,
        expectedDeviceID: String,
        now: Date = Date()
    ) throws -> PeerDeviceServiceCredential {
        guard hostID == expectedHostID, deviceID == expectedDeviceID else {
            throw PeerControlPlaneError.invalidResponse
        }
        return try PeerDeviceServiceCredential(
            hostID: hostID,
            deviceID: deviceID,
            credential: PeerControlPlaneBearer(credential),
            expiresAt: validatedFutureDate(expiresAt, now: now)
        )
    }
}

private struct ServiceErrorResponse: Decodable {
    struct Detail: Decodable { let code: String }
    let error: Detail
}

private func validateHTTP(
    _ response: URLResponse,
    data: Data,
    expectedStatuses: Range<Int>
) throws {
    guard let http = response as? HTTPURLResponse else {
        throw PeerControlPlaneError.invalidResponse
    }
    guard expectedStatuses.contains(http.statusCode) else {
        let code = (try? JSONDecoder().decode(ServiceErrorResponse.self, from: data))?.error.code
        throw PeerControlPlaneError.rejected(
            status: http.statusCode,
            code: code.flatMap { isBoundedNonEmpty($0, maximumBytes: 128) ? $0 : nil }
                ?? "unknown"
        )
    }
}

private func validatedFutureDate(_ milliseconds: Double, now: Date) throws -> Date {
    guard milliseconds.isFinite, milliseconds > 0 else {
        throw PeerControlPlaneError.invalidResponse
    }
    let date = Date(timeIntervalSince1970: milliseconds / 1_000)
    guard date > now, date < now.addingTimeInterval(370 * 24 * 60 * 60) else {
        throw PeerControlPlaneError.invalidResponse
    }
    return date
}

private func validateIdentifier(_ value: String) throws {
    guard isBoundedNonEmpty(value, maximumBytes: PeerRendezvousBounds.maximumIdentifierBytes),
          value.unicodeScalars.allSatisfy({ scalar in
              switch scalar.value {
              case 45, 46, 48...57, 58, 65...90, 95, 97...122: true
              default: false
              }
          })
    else {
        throw PeerControlPlaneError.invalidRequest
    }
}

private func isBoundedNonEmpty(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
}

private enum BoundedHTTP {
    static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let loader = Loader(maximumBytes: PeerControlPlaneBounds.maximumResponseBytes)
        return try await loader.perform(request)
    }

    private final class Loader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maximumBytes: Int
        private let lock = NSLock()
        private var data = Data()
        private var response: URLResponse?
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        private var task: URLSessionDataTask?
        private var session: URLSession?
        private var terminalError: Error?

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.urlCache = nil
                    configuration.httpCookieStorage = nil
                    configuration.urlCredentialStorage = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    configuration.timeoutIntervalForRequest = PeerControlPlaneBounds.requestTimeout
                    configuration.timeoutIntervalForResource = PeerControlPlaneBounds.requestTimeout
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    let task = session.dataTask(with: request)
                    lock.withLock {
                        self.continuation = continuation
                        self.session = session
                        self.task = task
                    }
                    task.resume()
                }
            } onCancel: {
                self.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            let expected = response.expectedContentLength
            if expected > maximumBytes {
                lock.withLock {
                    terminalError = PeerControlPlaneError.responseTooLarge(
                        actual: Int(expected),
                        limit: maximumBytes
                    )
                }
                completionHandler(.cancel)
                return
            }
            lock.withLock { self.response = response }
            completionHandler(.allow)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive received: Data
        ) {
            let exceeded = lock.withLock { () -> Bool in
                guard data.count <= maximumBytes - received.count else {
                    terminalError = PeerControlPlaneError.responseTooLarge(
                        actual: data.count + received.count,
                        limit: maximumBytes
                    )
                    return true
                }
                data.append(received)
                return false
            }
            if exceeded { dataTask.cancel() }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            let completion = lock.withLock { () -> (
                CheckedContinuation<(Data, URLResponse), Error>?,
                Result<(Data, URLResponse), Error>
            ) in
                let result: Result<(Data, URLResponse), Error>
                if let terminalError {
                    result = .failure(terminalError)
                } else if let error {
                    result = .failure(PeerControlPlaneError.transport(error.localizedDescription))
                } else if let response {
                    result = .success((data, response))
                } else {
                    result = .failure(PeerControlPlaneError.invalidResponse)
                }
                let saved = continuation
                continuation = nil
                self.task = nil
                self.session = nil
                return (saved, result)
            }
            session.finishTasksAndInvalidate()
            completion.0?.resume(with: completion.1)
        }

        private func cancel() {
            lock.withLock { task }?.cancel()
        }
    }
}
