import Foundation
import Security

/// What the credential resolver needs from the app connection, separated so tests can supply
/// a fixed token without a Keychain or a network.
protocol GitHubAppTokenProviding: Sendable {
    /// A currently valid access token, refreshed first when the stored one has expired.
    func freshAccessToken() async -> String?
    /// GitHub answered 401 for a token this provider issued: drop it so the next read refreshes.
    func noteRejectedAccessToken() async
}

/// Where the connection's secrets live. Only the tokens are secret; the login name and expiry
/// are presentation state and stay in `UserDefaults`.
protocol GitHubTokenStoring: AnyObject, Sendable {
    func token(_ key: GitHubTokenKey) -> String?
    func setToken(_ value: String?, for key: GitHubTokenKey)
}

enum GitHubTokenKey: String, CaseIterable {
    case access = "access-token"
    case refresh = "refresh-token"
}

/// Threading's own GitHub App login, connected through the OAuth device flow.
///
/// This is the "most correct" tier of the credential chain: the user registers (or is given)
/// a GitHub App, chooses which repositories it may see at install time, and GitHub's device
/// flow signs this Mac in without a client secret. Access tokens are user-to-server tokens
/// that expire after hours, so a refresh token is stored beside them and renewal is silent.
///
/// The device flow needs only a client ID, which is configuration rather than a secret — it
/// lives in Settings. Without one, this tier simply reports no credential and the chain moves
/// on to `gh`.
@MainActor
final class GitHubAppConnection {
    static let shared = GitHubAppConnection()
    static let statusDidChange = Notification.Name("GitHubAppConnectionStatusDidChange")

    enum Status: Equatable {
        case disconnected
        /// The user must enter `userCode` at `verificationURL`; polling runs underneath.
        case awaitingAuthorization(userCode: String, verificationURL: URL)
        case connected(login: String?)
        case failed(message: String)
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private enum DefaultsKeys {
        static let login = "githubAppConnectionLogin"
        static let accessExpiry = "githubAppAccessTokenExpiry"
        /// The client ID the stored grant belongs to — a refresh must present the same one.
        static let clientID = "githubAppConnectionClientID"
    }

    /// Renew this long before nominal expiry, so a token is never presented mid-death.
    private static let expiryMargin: TimeInterval = 120

    private let store: GitHubTokenStoring
    private let defaults: UserDefaults
    private let transport: Transport
    private var pollTask: Task<Void, Never>?

    private(set) var status: Status = .disconnected {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(name: Self.statusDidChange, object: self)
        }
    }

    init(
        store: GitHubTokenStoring = KeychainGitHubTokenStore.shared,
        defaults: UserDefaults = .standard,
        transport: @escaping Transport = GitHubAppConnection.liveTransport
    ) {
        self.store = store
        self.defaults = defaults
        self.transport = transport
        status = store.token(.access) == nil && store.token(.refresh) == nil
            ? .disconnected
            : .connected(login: defaults.string(forKey: DefaultsKeys.login))
    }

    nonisolated static let liveTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    // MARK: - Presentation

    var connectedLogin: String? {
        defaults.string(forKey: DefaultsKeys.login)
    }

    // MARK: - Device flow

    /// Starts the device flow with the configured client ID and polls until the user approves,
    /// declines, or the code expires. Safe to call again: a running flow is cancelled first.
    func beginAuthorization(clientID: String) {
        cancelAuthorization()
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = .failed(message: L10n.string(
                "Enter your GitHub App's client ID before connecting."
            ))
            return
        }

        defaults.set(trimmed, forKey: DefaultsKeys.clientID)
        pollTask = Task { [transport] in
            do {
                let device = try await Self.requestDeviceCode(
                    clientID: trimmed,
                    transport: transport
                )
                guard !Task.isCancelled else { return }
                self.status = .awaitingAuthorization(
                    userCode: device.userCode,
                    verificationURL: device.verificationURL
                )
                let grant = try await Self.pollForGrant(
                    clientID: trimmed,
                    device: device,
                    transport: transport
                )
                guard !Task.isCancelled else { return }
                self.adopt(grant)
                await self.refreshLogin()
            } catch is CancellationError {
                // The user backed out; whoever cancelled has already set the status.
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .failed(message: error.localizedDescription)
            }
            self.pollTask = nil
        }
    }

    func cancelAuthorization() {
        pollTask?.cancel()
        pollTask = nil
        if case .awaitingAuthorization = status {
            status = store.token(.access) == nil && store.token(.refresh) == nil
                ? .disconnected
                : .connected(login: connectedLogin)
        }
    }

    /// Forgets the stored tokens. Revoking the grant itself is done on GitHub, where the app
    /// installation lives; this ends what this Mac holds.
    func disconnect() {
        cancelAuthorization()
        store.setToken(nil, for: .access)
        store.setToken(nil, for: .refresh)
        defaults.removeObject(forKey: DefaultsKeys.login)
        defaults.removeObject(forKey: DefaultsKeys.accessExpiry)
        defaults.removeObject(forKey: DefaultsKeys.clientID)
        status = .disconnected
    }

    // MARK: - GitHubAppTokenProviding

    func freshAccessToken() async -> String? {
        if let token = store.token(.access), !accessTokenIsExpired {
            return token
        }
        guard let refresh = store.token(.refresh),
              let clientID = defaults.string(forKey: DefaultsKeys.clientID) else {
            return store.token(.access)
        }
        do {
            let grant = try await Self.refreshGrant(
                clientID: clientID,
                refresh: refresh,
                transport: transport
            )
            adopt(grant)
            return grant.accessToken
        } catch {
            ThreadingLogger.github.error(
                "GitHub App token refresh failed: \(error.localizedDescription)"
            )
            return store.token(.access)
        }
    }

    func noteRejectedAccessToken() async {
        store.setToken(nil, for: .access)
        defaults.removeObject(forKey: DefaultsKeys.accessExpiry)
    }

    private var accessTokenIsExpired: Bool {
        let stored = defaults.double(forKey: DefaultsKeys.accessExpiry)
        guard stored > 0 else { return false }
        return Date(timeIntervalSince1970: stored)
            .timeIntervalSinceNow < Self.expiryMargin
    }

    private func adopt(_ grant: GitHubTokenGrant) {
        store.setToken(grant.accessToken, for: .access)
        if let refresh = grant.refreshToken {
            store.setToken(refresh, for: .refresh)
        }
        if let expiresIn = grant.expiresIn {
            defaults.set(
                Date().addingTimeInterval(expiresIn).timeIntervalSince1970,
                forKey: DefaultsKeys.accessExpiry
            )
        } else {
            defaults.removeObject(forKey: DefaultsKeys.accessExpiry)
        }
        status = .connected(login: connectedLogin)
    }

    private func refreshLogin() async {
        guard let token = store.token(.access) else { return }
        guard let endpoint = URL(string: "https://\(GitHubDefaults.apiHost)/user") else {
            ThreadingLogger.github.error("GitHub API endpoint is invalid")
            return
        }
        var request = URLRequest(
            url: endpoint,
            timeoutInterval: GitHubDefaults.requestTimeout
        )
        request.setValue(GitHubDefaults.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(GitHubDefaults.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(GitHubDefaults.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, http) = try? await transport(request), http.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = payload["login"] as? String else {
            return
        }
        defaults.set(login, forKey: DefaultsKeys.login)
        status = .connected(login: login)
    }
}

// MARK: - Wire

struct GitHubDeviceCode: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let pollInterval: TimeInterval
}

struct GitHubTokenGrant: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval?
}

enum GitHubDeviceFlowError: Error, LocalizedError, Equatable {
    case malformedResponse
    case declined
    case expired
    case service(String)

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return L10n.string("GitHub's sign-in response could not be read.")
        case .declined:
            return L10n.string("The sign-in was declined on GitHub.")
        case .expired:
            return L10n.string("The sign-in code expired before it was entered.")
        case .service(let message):
            return message
        }
    }
}

extension GitHubAppConnection {
    /// The device-flow steps are static and pure-ish (transport in, values out) so the state
    /// machine is testable without the singleton, a Keychain, or real time.
    static func requestDeviceCode(
        clientID: String,
        transport: Transport
    ) async throws -> GitHubDeviceCode {
        let payload = try await postForm(
            to: "https://\(GitHubDefaults.webHost)/login/device/code",
            fields: ["client_id": clientID],
            transport: transport
        )
        guard let deviceCode = payload["device_code"] as? String,
              let userCode = payload["user_code"] as? String,
              let verification = payload["verification_uri"] as? String,
              let verificationURL = URL(string: verification),
              let expiresIn = payload["expires_in"] as? Double,
              let interval = payload["interval"] as? Double else {
            throw GitHubDeviceFlowError.malformedResponse
        }
        return GitHubDeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            expiresAt: Date().addingTimeInterval(expiresIn),
            pollInterval: interval
        )
    }

    static func pollForGrant(
        clientID: String,
        device: GitHubDeviceCode,
        transport: Transport
    ) async throws -> GitHubTokenGrant {
        var interval = max(device.pollInterval, 1)
        while Date() < device.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try Task.checkCancellation()
            let payload = try await postForm(
                to: "https://\(GitHubDefaults.webHost)/login/oauth/access_token",
                fields: [
                    "client_id": clientID,
                    "device_code": device.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ],
                transport: transport
            )
            if let grant = grant(from: payload) { return grant }
            switch payload["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw GitHubDeviceFlowError.expired
            case "access_denied":
                throw GitHubDeviceFlowError.declined
            case let other?:
                let description = payload["error_description"] as? String
                throw GitHubDeviceFlowError.service(description ?? other)
            case nil:
                throw GitHubDeviceFlowError.malformedResponse
            }
        }
        throw GitHubDeviceFlowError.expired
    }

    static func refreshGrant(
        clientID: String,
        refresh: String,
        transport: Transport
    ) async throws -> GitHubTokenGrant {
        let payload = try await postForm(
            to: "https://\(GitHubDefaults.webHost)/login/oauth/access_token",
            fields: [
                "client_id": clientID,
                "refresh_token": refresh,
                "grant_type": "refresh_token"
            ],
            transport: transport
        )
        guard let grant = grant(from: payload) else {
            let description = payload["error_description"] as? String
                ?? payload["error"] as? String
            throw GitHubDeviceFlowError.service(
                description ?? L10n.string("GitHub did not renew the connection.")
            )
        }
        return grant
    }

    private static func grant(from payload: [String: Any]) -> GitHubTokenGrant? {
        guard let accessToken = payload["access_token"] as? String else { return nil }
        return GitHubTokenGrant(
            accessToken: accessToken,
            refreshToken: payload["refresh_token"] as? String,
            expiresIn: payload["expires_in"] as? Double
        )
    }

    private static func postForm(
        to url: String,
        fields: [String: String],
        transport: Transport
    ) async throws -> [String: Any] {
        guard let url = URL(string: url) else {
            throw GitHubDeviceFlowError.malformedResponse
        }
        var request = URLRequest(url: url, timeoutInterval: GitHubDefaults.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(GitHubDefaults.userAgent, forHTTPHeaderField: "User-Agent")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed)
                return "\(key)=\(encoded ?? value)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await transport(request)
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubDeviceFlowError.malformedResponse
        }
        return payload
    }
}

// The witnesses live in the class body under their MARK; the declaration is here so the
// conformance reads as the seam it is.
extension GitHubAppConnection: GitHubAppTokenProviding {}

/// The app's own GitHub tokens, in its own Keychain service — separate from extension
/// secrets, which are namespaced per extension identifier.
final class KeychainGitHubTokenStore: GitHubTokenStoring {
    static let shared = KeychainGitHubTokenStore()

    private static let service = "codes.threading.github.v1"

    private init() {}

    func token(_ key: GitHubTokenKey) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ value: String?, for key: GitHubTokenKey) {
        guard let value else {
            SecItemDelete(baseQuery(key) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery(key) as CFDictionary,
            update as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else { return }
        var query = baseQuery(key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private func baseQuery(_ key: GitHubTokenKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
