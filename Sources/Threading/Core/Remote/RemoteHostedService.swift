import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import ThreadingPeerTransport
import ThreadingRemoteKit

/// Which first-party hosted control plane a developer-enabled build talks to.
///
/// Public Release builds ignore the persisted choice and always resolve the production endpoint.
/// The two services have separate credentials and push registrations, so this is a service
/// identity, not merely a different URL for the same account.
enum RemoteHostedServiceEnvironment: String, CaseIterable, Sendable {
    case production
    case development

    static let developmentServiceURL = URL(string: "https://dev.remote.threading.codes")!
}

enum RemoteHostedServiceState: Equatable {
    case stopped
    case notConfigured
    case signInRequired
    case connecting
    case ready
    case unavailable(String)
}

private enum RemoteHostedServiceDefaults {
    static let keychainService = "codes.threading.remote.hosted-service"
    static let keychainAccount = "host-credentials-v1"
    static let developmentKeychainAccount = "host-credentials-development-v1"
    static let recordVersion = 1
    static let maximumPendingRevocations = 64
    static let credentialRenewalLeadTime: TimeInterval = 60 * 60
    static let sessionRenewalLeadTime: TimeInterval = 7 * 24 * 60 * 60
    static let maintenanceRetryDelay: TimeInterval = 60
    static let maximumReconnectDelay: TimeInterval = 60
}

struct RemoteHostedServiceRecord: Codable, Equatable {
    let version: Int
    let endpoint: URL
    var session: PeerControlPlaneSession
    var hostCredential: PeerHostServiceCredential
    var pendingRevokedDeviceIDs: [String]
}

protocol RemoteHostedServicePersisting: AnyObject {
    func load() throws -> RemoteHostedServiceRecord?
    func save(_ record: RemoteHostedServiceRecord) throws
    func delete() throws
}

private enum RemoteHostedServiceStoreError: LocalizedError {
    case keychain(OSStatus)
    case corrupt

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "The hosted-service Keychain item could not be accessed (\(status))."
        case .corrupt:
            return "The hosted-service Keychain item is unreadable and was left untouched."
        }
    }
}

private final class RemoteHostedServiceKeychainStore: RemoteHostedServicePersisting {
    private let account: String

    init(account: String = RemoteHostedServiceDefaults.keychainAccount) {
        self.account = account
    }

    func load() throws -> RemoteHostedServiceRecord? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RemoteHostedServiceStoreError.keychain(status)
        }
        do {
            return try JSONDecoder().decode(RemoteHostedServiceRecord.self, from: data)
        } catch {
            throw RemoteHostedServiceStoreError.corrupt
        }
    }

    func save(_ record: RemoteHostedServiceRecord) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw RemoteHostedServiceStoreError.corrupt
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw RemoteHostedServiceStoreError.keychain(updated)
        }
        var item = baseQuery
        attributes.forEach { item[$0.key] = $0.value }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw RemoteHostedServiceStoreError.keychain(added)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteHostedServiceStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteHostedServiceDefaults.keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private var readQuery: [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}

private final class InMemoryRemoteHostedServiceStore: RemoteHostedServicePersisting {
    private var record: RemoteHostedServiceRecord?
    func load() throws -> RemoteHostedServiceRecord? { record }
    func save(_ record: RemoteHostedServiceRecord) throws { self.record = record }
    func delete() throws { record = nil }
}

/// Owns the Mac's low-frequency hosted control connection. The loopback remote server remains
/// authoritative; this controller only publishes a direct ICE/TURN path to that same server.
@MainActor
final class RemoteHostedServiceController {
    private(set) var state: RemoteHostedServiceState = .stopped {
        didSet {
            guard state != oldValue else { return }
            onStateChange?()
        }
    }

    var onStateChange: (() -> Void)?

    private let store: RemoteHostedServicePersisting
    private let endpoint: PeerControlPlaneServiceEndpoint?
    private let hostID: String
    private let hostName: String
    private let localDevelopmentAuthentication: Bool
    private let developmentBrowserAuthentication: Bool
    private var record: RemoteHostedServiceRecord?
    private var persistenceError: String?
    private var listener: PeerHostedHostListener?
    private var listenerEventsTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var desiredPort: UInt16?
    private var lifecycleGeneration = 0
    private var retryAttempt = 0
    // NotificationCenter's opaque token is created in init and read only in deinit. Marking this
    // storage nonisolated avoids treating NSObjectProtocol as transferable actor state.
    nonisolated(unsafe) private var credentialRevokedObserver: NSObjectProtocol?

    init(
        store: (any RemoteHostedServicePersisting)? = nil,
        endpoint: PeerControlPlaneServiceEndpoint? = RemoteHostedServiceController
            .configuredEndpoint(),
        hostID: String = RemoteHostIdentity.current.id,
        hostName: String = RemoteHostIdentity.current.name,
        localDevelopmentAuthentication: Bool = RemoteHostedServiceController
            .configuredLocalDevelopmentAuthentication(),
        developmentBrowserAuthentication: Bool? = nil
    ) {
        self.store = store ?? Self.defaultStore(endpoint: endpoint)
        self.endpoint = endpoint
        self.hostID = hostID
        self.hostName = hostName
        self.localDevelopmentAuthentication = localDevelopmentAuthentication
        self.developmentBrowserAuthentication = developmentBrowserAuthentication
            ?? Self.configuredDevelopmentBrowserAuthentication(endpoint: endpoint)
        do {
            let loaded = try self.store.load()
            if let loaded, Self.isValid(loaded, endpoint: endpoint, hostID: hostID) {
                record = loaded
            } else if loaded != nil {
                persistenceError = RemoteHostedServiceStoreError.corrupt.localizedDescription
            }
        } catch {
            persistenceError = error.localizedDescription
        }
        credentialRevokedObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.forgetRevokedAppleCredential() }
        }
    }

    deinit {
        if let credentialRevokedObserver {
            NotificationCenter.default.removeObserver(credentialRevokedObserver)
        }
    }

    var canIssueDeviceCredentials: Bool {
        guard persistenceError == nil, endpoint != nil, let record else { return false }
        guard state != .signInRequired else { return false }
        return record.hostCredential.hostID == hostID
            && record.hostCredential.expiresAt > Date()
    }

    var serviceURL: URL? { endpoint?.baseURL }

    var canSendHostedPush: Bool {
        endpoint?.isLoopback == false && canIssueDeviceCredentials
    }

    private var sessionRenewalLeadTime: TimeInterval {
        developmentBrowserAuthentication
            ? 60 * 60
            : RemoteHostedServiceDefaults.sessionRenewalLeadTime
    }

    func start(targetPort: UInt16) {
        desiredPort = targetPort
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        stopConnection(keepingDesiredPort: true)
        guard endpoint != nil else {
            state = .notConfigured
            return
        }
        guard persistenceError == nil else {
            state = .unavailable("credentials")
            return
        }
        guard record != nil else {
            if localDevelopmentAuthentication, endpoint?.isLoopback == true {
                state = .connecting
                connectionTask = Task { [weak self] in
                    await self?.bootstrapLocalDevelopment(
                        targetPort: targetPort,
                        generation: generation
                    )
                }
                return
            }
            if developmentBrowserAuthentication, endpoint?.isLoopback == false {
                state = .connecting
                connectionTask = Task { [weak self] in
                    await self?.bootstrapDevelopmentBrowserAuthentication(
                        targetPort: targetPort,
                        generation: generation
                    )
                }
                return
            }
            state = .signInRequired
            return
        }
        state = .connecting
        connectionTask = Task { [weak self] in
            await self?.connect(targetPort: targetPort, generation: generation)
        }
    }

    func stop() {
        desiredPort = nil
        lifecycleGeneration &+= 1
        stopConnection(keepingDesiredPort: false)
        state = .stopped
    }

    func signInWithApple(
        identityToken: String,
        authorizationCode: String,
        rawNonce: String
    ) async throws {
        guard let endpoint else { throw PeerControlPlaneError.invalidEndpoint }
        let generation = lifecycleGeneration
        state = .connecting
        let client = PeerControlPlaneClient(endpoint: endpoint)
        do {
            let session = try await client.signInWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                rawNonce: rawNonce
            )
            let hostCredential = try await client.enrollHost(
                accessToken: session.accessToken,
                hostID: hostID,
                displayName: hostName
            )
            let candidate = RemoteHostedServiceRecord(
                version: RemoteHostedServiceDefaults.recordVersion,
                endpoint: endpoint.baseURL,
                session: session,
                hostCredential: hostCredential,
                pendingRevokedDeviceIDs: []
            )
            try persist(candidate)
        } catch {
            state = persistenceError == nil ? .signInRequired : .unavailable("credentials")
            throw error
        }
        guard generation == lifecycleGeneration else { return }
        if let desiredPort {
            start(targetPort: desiredPort)
        } else {
            state = .stopped
        }
    }

    private func bootstrapLocalDevelopment(targetPort: UInt16, generation: Int) async {
        guard let endpoint, endpoint.isLoopback else {
            state = .signInRequired
            return
        }
        let client = PeerControlPlaneClient(endpoint: endpoint)
        do {
            let session = try await client.signInForLocalDevelopment()
            let hostCredential = try await client.enrollHost(
                accessToken: session.accessToken,
                hostID: hostID,
                displayName: hostName
            )
            try persist(RemoteHostedServiceRecord(
                version: RemoteHostedServiceDefaults.recordVersion,
                endpoint: endpoint.baseURL,
                session: session,
                hostCredential: hostCredential,
                pendingRevokedDeviceIDs: []
            ))
        } catch {
            guard generation == lifecycleGeneration else { return }
            state = .unavailable("local-service")
            return
        }
        guard generation == lifecycleGeneration else { return }
        start(targetPort: targetPort)
    }

    private func bootstrapDevelopmentBrowserAuthentication(
        targetPort: UInt16,
        generation: Int
    ) async {
        guard let endpoint, !endpoint.isLoopback else {
            state = .signInRequired
            return
        }
        let client = PeerControlPlaneClient(endpoint: endpoint)
        do {
            let verifier = try Self.developmentCodeVerifier()
            let transaction = try await client.startDevelopmentSignIn(
                hostID: hostID,
                codeChallenge: Self.sha256(verifier)
            )
            guard NSWorkspace.shared.open(transaction.authorizationURL) else {
                throw PeerControlPlaneError.transport("browser")
            }
            var session: PeerControlPlaneSession?
            while !Task.isCancelled, Date() < transaction.expiresAt {
                do {
                    session = try await client.redeemDevelopmentSignIn(
                        transaction: transaction,
                        hostID: hostID,
                        codeVerifier: verifier
                    )
                    break
                } catch PeerControlPlaneError.rejected(
                    let status,
                    let code
                ) where status == 409 && code == "developmentAuthPending" {
                    try await Task.sleep(for: .seconds(1))
                }
            }
            guard let session else {
                throw PeerControlPlaneError.rejected(
                    status: 410,
                    code: "developmentAuthExpired"
                )
            }
            let hostCredential = try await client.enrollHost(
                accessToken: session.accessToken,
                hostID: hostID,
                displayName: hostName
            )
            try persist(RemoteHostedServiceRecord(
                version: RemoteHostedServiceDefaults.recordVersion,
                endpoint: endpoint.baseURL,
                session: session,
                hostCredential: hostCredential,
                pendingRevokedDeviceIDs: []
            ))
        } catch is CancellationError {
            return
        } catch {
            guard generation == lifecycleGeneration else { return }
            state = persistenceError == nil ? .signInRequired : .unavailable("credentials")
            return
        }
        guard generation == lifecycleGeneration else { return }
        start(targetPort: targetPort)
    }

    func signOut() async throws {
        lifecycleGeneration &+= 1
        stopConnection(keepingDesiredPort: true)
        guard let endpoint else { throw PeerControlPlaneError.invalidEndpoint }
        guard var current = record else {
            try store.delete()
            persistenceError = nil
            state = desiredPort == nil ? .stopped : .signInRequired
            return
        }

        state = .connecting
        let client = PeerControlPlaneClient(endpoint: endpoint)
        do {
            let session = try await validSession(current: &current, client: client)
            do {
                try await client.revokeHost(accessToken: session.accessToken, hostID: hostID)
            } catch PeerControlPlaneError.rejected(let status, _) where status == 404 {
                // An earlier attempt may have revoked the host before its response was lost.
            }
            try await client.signOut(refreshToken: session.refreshToken)
            try store.delete()
            record = nil
            persistenceError = nil
            state = desiredPort == nil ? .stopped : .signInRequired
        } catch {
            state = .unavailable("service")
            throw error
        }
    }

    func deleteAccount() async throws {
        lifecycleGeneration &+= 1
        stopConnection(keepingDesiredPort: true)
        guard let endpoint else { throw PeerControlPlaneError.invalidEndpoint }
        guard var current = record else { throw PeerControlPlaneError.invalidCredential }
        state = .connecting
        let client = PeerControlPlaneClient(endpoint: endpoint)
        do {
            let session = try await validSession(current: &current, client: client)
            try await client.deleteAccount(accessToken: session.accessToken)
            try store.delete()
            record = nil
            persistenceError = nil
            state = desiredPort == nil ? .stopped : .signInRequired
        } catch {
            state = .unavailable("service")
            throw error
        }
    }

    func issueDeviceCredential(
        deviceID: String,
        lifetimeSeconds: Int? = nil
    ) async throws -> PeerDeviceServiceCredential {
        guard let endpoint else { throw PeerControlPlaneError.invalidEndpoint }
        var current = try await validRecord(client: PeerControlPlaneClient(endpoint: endpoint))
        if current.pendingRevokedDeviceIDs.contains(deviceID) {
            current.pendingRevokedDeviceIDs.removeAll { $0 == deviceID }
            try persist(current)
        }
        let credential = try await PeerControlPlaneClient(endpoint: endpoint).issueDeviceCredential(
            hostCredential: current.hostCredential.credential,
            hostID: hostID,
            deviceID: deviceID,
            lifetimeSeconds: lifetimeSeconds
        )
        return credential
    }

    func sendHostedPush(
        event: RemoteNotificationEventDTO,
        registrationID: String,
        playsSound: Bool
    ) async -> RemoteAPNSDeliveryResult {
        guard let endpoint, !endpoint.isLoopback else {
            return RemoteAPNSDeliveryResult(
                statusCode: nil,
                reason: "Hosted push is unavailable for a loopback service.",
                apnsID: nil
            )
        }
        do {
            let current = try await validRecord(client: PeerControlPlaneClient(endpoint: endpoint))
            let result = try await PeerControlPlaneClient(endpoint: endpoint).sendHostedPush(
                hostCredential: current.hostCredential.credential,
                payload: RemoteHostedPushEnvelope(
                    registrationID: registrationID,
                    playsSound: playsSound,
                    event: event
                )
            )
            return RemoteAPNSDeliveryResult(
                statusCode: result.statusCode,
                reason: result.reason,
                apnsID: result.apnsID
            )
        } catch {
            return RemoteAPNSDeliveryResult(
                statusCode: nil,
                reason: "Hosted push broker was unavailable.",
                apnsID: nil
            )
        }
    }

    func revokeDevice(deviceID: String) {
        Task { [weak self] in
            await self?.revokeDeviceNow(deviceID: deviceID)
        }
    }

    func revokeDeviceImmediately(deviceID: String) async {
        await revokeDeviceNow(deviceID: deviceID)
    }

    private func connect(targetPort: UInt16, generation: Int) async {
        guard let endpoint else { return }
        do {
            let current = try await validRecord(client: PeerControlPlaneClient(endpoint: endpoint))
            try await flushPendingRevocations(current: current)
            guard generation == lifecycleGeneration, desiredPort == targetPort else { return }
            let credential = try current.hostCredential.credential.withValue {
                try PeerRendezvousCredential($0)
            }
            let listener = PeerHostedHostListener(
                endpoint: endpoint.rendezvousEndpoint,
                hostID: hostID,
                credential: credential,
                targetPort: targetPort
            )
            try await listener.start()
            guard generation == lifecycleGeneration, desiredPort == targetPort else {
                await listener.stop()
                return
            }
            self.listener = listener
            retryAttempt = 0
            state = .ready
            listenerEventsTask = Task { [weak self] in
                for await event in listener.events {
                    await self?.handle(event, listener: listener, generation: generation)
                }
            }
            scheduleMaintenance(generation: generation, targetPort: targetPort)
        } catch is CancellationError {
            return
        } catch {
            guard generation == lifecycleGeneration else { return }
            if await reauthorizeDevelopmentIfNeeded(
                after: error,
                targetPort: targetPort,
                generation: generation
            ) {
                return
            }
            ThreadingLogger.remote.error(
                "Hosted remote connection failed code=\(Self.errorCode(error), privacy: .public)"
            )
            state = Self.requiresSignIn(error) ? .signInRequired : .unavailable("service")
            if !Self.requiresSignIn(error) { scheduleReconnect(generation: generation) }
        }
    }

    private func handle(
        _ event: PeerHostedHostEvent,
        listener: PeerHostedHostListener,
        generation: Int
    ) async {
        guard generation == lifecycleGeneration, self.listener === listener else { return }
        switch event {
        case .ready:
            state = .ready
        case .sessionConnected(_, _, let route):
            ThreadingLogger.remote.info(
                "Hosted remote session connected relay=\(route?.usesRelay ?? false, privacy: .public)"
            )
        case .sessionClosed:
            break
        case .sessionFailed(_, let reason):
            ThreadingLogger.remote.error(
                "Hosted remote session failed reason=\(reason.rawValue, privacy: .public)"
            )
        case .listenerFailed(let reason):
            ThreadingLogger.remote.error(
                "Hosted remote listener failed reason=\(reason.rawValue, privacy: .public)"
            )
            self.listener = nil
            listenerEventsTask = nil
            maintenanceTask?.cancel()
            maintenanceTask = nil
            state = reason == .unauthorized ? .signInRequired : .unavailable("service")
            if reason != .unauthorized { scheduleReconnect(generation: generation) }
        }
    }

    private func validRecord(client: PeerControlPlaneClient) async throws
        -> RemoteHostedServiceRecord {
        guard var current = record else { throw PeerControlPlaneError.invalidCredential }
        if current.session.refreshTokenExpiresAt
            <= Date().addingTimeInterval(sessionRenewalLeadTime) {
            current.session = try await validSession(
                current: &current,
                client: client,
                forceRefresh: true
            )
            try persist(current)
        }
        let renewalDate = Date().addingTimeInterval(
            RemoteHostedServiceDefaults.credentialRenewalLeadTime
        )
        if current.hostCredential.expiresAt > renewalDate { return current }

        let session = try await validSession(current: &current, client: client)
        let hostCredential = try await client.enrollHost(
            accessToken: session.accessToken,
            hostID: hostID,
            displayName: hostName
        )
        current.session = session
        current.hostCredential = hostCredential
        try persist(current)
        return current
    }

    private func validSession(
        current: inout RemoteHostedServiceRecord,
        client: PeerControlPlaneClient,
        forceRefresh: Bool = false
    ) async throws -> PeerControlPlaneSession {
        if !forceRefresh,
           current.session.accessTokenExpiresAt > Date().addingTimeInterval(60) {
            return current.session
        }
        guard current.session.refreshTokenExpiresAt > Date().addingTimeInterval(60) else {
            throw PeerControlPlaneError.invalidCredential
        }
        let session = try await client.refresh(refreshToken: current.session.refreshToken)
        current.session = session
        try persist(current)
        return session
    }

    private func revokeDeviceNow(deviceID: String) async {
        if let listener { await listener.disconnect(deviceID: deviceID) }
        guard var current = record else { return }
        if !current.pendingRevokedDeviceIDs.contains(deviceID),
           current.pendingRevokedDeviceIDs.count
            < RemoteHostedServiceDefaults.maximumPendingRevocations {
            current.pendingRevokedDeviceIDs.append(deviceID)
            do {
                try persist(current)
            } catch {
                state = .unavailable("credentials")
                return
            }
        }
        guard let endpoint else { return }
        do {
            current = try await validRecord(client: PeerControlPlaneClient(endpoint: endpoint))
            try await revoke(deviceID: deviceID, current: &current, endpoint: endpoint)
        } catch {
            ThreadingLogger.remote.error(
                "Hosted remote revocation deferred code=\(Self.errorCode(error), privacy: .public)"
            )
        }
    }

    private func flushPendingRevocations(current: RemoteHostedServiceRecord) async throws {
        guard let endpoint else { return }
        var candidate = current
        for deviceID in current.pendingRevokedDeviceIDs {
            try await revoke(deviceID: deviceID, current: &candidate, endpoint: endpoint)
        }
    }

    private func revoke(
        deviceID: String,
        current: inout RemoteHostedServiceRecord,
        endpoint: PeerControlPlaneServiceEndpoint
    ) async throws {
        try await PeerControlPlaneClient(endpoint: endpoint).revokeDeviceCredential(
            hostCredential: current.hostCredential.credential,
            hostID: hostID,
            deviceID: deviceID
        )
        current.pendingRevokedDeviceIDs.removeAll { $0 == deviceID }
        try persist(current)
    }

    private func persist(_ candidate: RemoteHostedServiceRecord) throws {
        do {
            try store.save(candidate)
            record = candidate
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            throw error
        }
    }

    private func stopConnection(keepingDesiredPort: Bool) {
        connectionTask?.cancel()
        connectionTask = nil
        retryTask?.cancel()
        retryTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        listenerEventsTask?.cancel()
        listenerEventsTask = nil
        if let listener {
            Task { await listener.stop() }
        }
        listener = nil
        retryAttempt = 0
        if !keepingDesiredPort { desiredPort = nil }
    }

    private func scheduleMaintenance(
        generation: Int,
        targetPort: UInt16,
        retryAfter: TimeInterval? = nil
    ) {
        maintenanceTask?.cancel()
        guard let record else { return }
        let nextDate = min(
            record.session.refreshTokenExpiresAt.addingTimeInterval(
                -sessionRenewalLeadTime
            ),
            record.hostCredential.expiresAt.addingTimeInterval(
                -RemoteHostedServiceDefaults.credentialRenewalLeadTime
            )
        )
        let delay = retryAfter ?? max(1, nextDate.timeIntervalSinceNow)
        maintenanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self,
                  generation == self.lifecycleGeneration,
                  self.desiredPort == targetPort else { return }
            self.maintenanceTask = nil
            await self.performMaintenance(generation: generation, targetPort: targetPort)
        }
    }

    private func performMaintenance(generation: Int, targetPort: UInt16) async {
        guard let endpoint, let previous = record else { return }
        do {
            let current = try await validRecord(client: PeerControlPlaneClient(endpoint: endpoint))
            guard generation == lifecycleGeneration, desiredPort == targetPort else { return }
            if current.hostCredential != previous.hostCredential {
                start(targetPort: targetPort)
                return
            }
            if listener != nil { state = .ready }
            scheduleMaintenance(generation: generation, targetPort: targetPort)
        } catch is CancellationError {
            return
        } catch {
            guard generation == lifecycleGeneration, desiredPort == targetPort else { return }
            if await reauthorizeDevelopmentIfNeeded(
                after: error,
                targetPort: targetPort,
                generation: generation
            ) {
                return
            }
            let requiresSignIn = Self.requiresSignIn(error)
            state = requiresSignIn ? .signInRequired : .unavailable("service")
            if !requiresSignIn {
                scheduleMaintenance(
                    generation: generation,
                    targetPort: targetPort,
                    retryAfter: RemoteHostedServiceDefaults.maintenanceRetryDelay
                )
            }
        }
    }

    private func scheduleReconnect(generation: Int) {
        guard retryTask == nil, let targetPort = desiredPort else { return }
        retryAttempt = min(retryAttempt + 1, 7)
        let delay = min(
            pow(2, Double(retryAttempt - 1)),
            RemoteHostedServiceDefaults.maximumReconnectDelay
        )
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self,
                  generation == self.lifecycleGeneration,
                  self.desiredPort == targetPort else { return }
            self.retryTask = nil
            self.state = .connecting
            await self.connect(targetPort: targetPort, generation: generation)
        }
    }

    private func forgetRevokedAppleCredential() {
        lifecycleGeneration &+= 1
        stopConnection(keepingDesiredPort: true)
        do {
            try store.delete()
            record = nil
            persistenceError = nil
            state = desiredPort == nil ? .stopped : .signInRequired
        } catch {
            persistenceError = error.localizedDescription
            state = .unavailable("credentials")
        }
    }

    private func reauthorizeDevelopmentIfNeeded(
        after error: Error,
        targetPort: UInt16,
        generation: Int
    ) async -> Bool {
        guard developmentBrowserAuthentication,
              Self.requiresSignIn(error),
              endpoint?.isLoopback == false,
              generation == lifecycleGeneration,
              desiredPort == targetPort else { return false }
        do {
            try store.delete()
            record = nil
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
            state = .unavailable("credentials")
            return true
        }
        state = .connecting
        await bootstrapDevelopmentBrowserAuthentication(
            targetPort: targetPort,
            generation: generation
        )
        return true
    }

    private static func isValid(
        _ record: RemoteHostedServiceRecord,
        endpoint: PeerControlPlaneServiceEndpoint?,
        hostID: String
    ) -> Bool {
        guard record.version == RemoteHostedServiceDefaults.recordVersion,
              record.endpoint == endpoint?.baseURL,
              record.hostCredential.hostID == hostID,
              record.pendingRevokedDeviceIDs.count
                <= RemoteHostedServiceDefaults.maximumPendingRevocations,
              Set(record.pendingRevokedDeviceIDs).count == record.pendingRevokedDeviceIDs.count
        else { return false }
        return Self.isIdentifier(record.session.accountID)
            && Self.isIdentifier(record.hostCredential.hostID)
            && record.pendingRevokedDeviceIDs.allSatisfy(Self.isIdentifier)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= PeerRendezvousBounds.maximumIdentifierBytes
            && value.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 45, 46, 48...57, 58, 65...90, 95, 97...122: true
                default: false
                }
            }
    }

    private static func defaultStore(
        endpoint: PeerControlPlaneServiceEndpoint?
    ) -> RemoteHostedServicePersisting {
        NSClassFromString("XCTestCase") == nil
            ? RemoteHostedServiceKeychainStore(
                account: configuredDevelopmentBrowserAuthentication(endpoint: endpoint)
                    ? RemoteHostedServiceDefaults.developmentKeychainAccount
                    : RemoteHostedServiceDefaults.keychainAccount
            )
            : InMemoryRemoteHostedServiceStore()
    }

    static func configuredEndpoint(
        preferredEnvironment: RemoteHostedServiceEnvironment = .production,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PeerControlPlaneServiceEndpoint? {
#if DEBUG || THREADING_INTERNAL
        if let override = environment["THREADING_CONTROL_PLANE_URL"],
           let url = URL(string: override) {
            return try? PeerControlPlaneServiceEndpoint(url)
        }
        if preferredEnvironment == .development {
            return try? PeerControlPlaneServiceEndpoint(
                RemoteHostedServiceEnvironment.developmentServiceURL
            )
        }
#endif
        guard let value = bundle.object(forInfoDictionaryKey: "ThreadingControlPlaneURL") as? String,
              let url = URL(string: value) else { return nil }
        return try? PeerControlPlaneServiceEndpoint(url)
    }

    static func hasConfiguredEndpointOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
#if DEBUG || THREADING_INTERNAL
        guard let override = environment["THREADING_CONTROL_PLANE_URL"],
              let url = URL(string: override) else { return false }
        return (try? PeerControlPlaneServiceEndpoint(url)) != nil
#else
        return false
#endif
    }

    private static func configuredLocalDevelopmentAuthentication(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
#if DEBUG || THREADING_INTERNAL
        environment["THREADING_CONTROL_PLANE_LOCAL_AUTH"] == "1"
#else
        false
#endif
    }

    private static func configuredDevelopmentBrowserAuthentication(
        endpoint: PeerControlPlaneServiceEndpoint?
    ) -> Bool {
#if DEBUG || THREADING_INTERNAL
        endpoint?.baseURL.host?.lowercased() == "dev.remote.threading.codes"
#else
        false
#endif
    }

    private static func developmentCodeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PeerControlPlaneError.transport("entropy")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func requiresSignIn(_ error: Error) -> Bool {
        if error as? PeerControlPlaneError == .invalidCredential { return true }
        if case .rejected(let status, _) = error as? PeerControlPlaneError, status == 401 {
            return true
        }
        return false
    }

    private static func errorCode(_ error: Error) -> String {
        switch error as? PeerControlPlaneError {
        case .invalidCredential: "credential"
        case .rejected(let status, _): "http_\(status)"
        case .transport: "network"
        case .responseTooLarge: "response_size"
        case .invalidEndpoint: "endpoint"
        case .invalidRequest: "request"
        case .invalidResponse: "response"
        case nil: "other"
        }
    }
}

private struct RemoteHostedPushEnvelope: Encodable, Sendable {
    let registrationID: String
    let playsSound: Bool
    let event: RemoteNotificationEventDTO
}
