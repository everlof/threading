#if DEBUG
import CryptoKit
import Foundation
import Security
import ThreadingRemoteKit

/// One experiment, one enrolled device, one pending operation. No persistence of authority.
/// Actor isolation keeps Keychain and cryptographic work off the UI/network executors.
actor SecretApprovalLab {
    static let shared = SecretApprovalLab()
    enum Failure: Error { case disabled, enrollmentRefused, approvalRefused, keychain(OSStatus) }
    struct LocalStatus: Sendable {
        let enrollmentCode: String?
        let enabled: Bool
        var githubProfile = false
        var protectedStorageAvailable = false
    }
    private var experimentID: UUID?
    private var enrollmentCode: String?
    private var enrollmentDeadline = Date.distantPast
    private var attempts = 0
    private var enrolled: (device: String, share: String, key: P256.Signing.PublicKey)?
    private var pending: RemoteSecretApprovalLab.Challenge?
    private var pendingDeadline = Date.distantPast
    private var githubProfile = false
    private var executing: UUID?
    private let now: @Sendable () -> Date
    private let createCredential: @Sendable () throws -> Void
    private let useCredential: @Sendable (Data) throws -> Void
    private let removeCredential: @Sendable () throws -> Void
    private let saveGitHubToken: @Sendable (String) throws -> Void
    private let fetchGitHubProfile: @Sendable () async throws -> String
    private let removeGitHubToken: @Sendable () throws -> Void
    private let protectedStorageAvailable: @Sendable () -> Bool

    init(now: @escaping @Sendable () -> Date = { Date() },
         createCredential: @escaping @Sendable () throws -> Void = { try SecretApprovalLabCredential.create() },
         useCredential: @escaping @Sendable (Data) throws -> Void = { try SecretApprovalLabCredential.use($0) },
         removeCredential: @escaping @Sendable () throws -> Void = { try SecretApprovalLabCredential.remove() },
         saveGitHubToken: @escaping @Sendable (String) throws -> Void = { try SecretApprovalGitHubStore().save($0) },
         fetchGitHubProfile: @escaping @Sendable () async throws -> String = { try await SecretApprovalGitHub.fetchProfile() },
         removeGitHubToken: @escaping @Sendable () throws -> Void = { try SecretApprovalGitHubStore().remove() },
         protectedStorageAvailable: @escaping @Sendable () -> Bool = { SecretApprovalGitHubStore.isAvailable }) {
        self.now = now
        self.createCredential = createCredential
        self.useCredential = useCredential
        self.removeCredential = removeCredential
        self.saveGitHubToken = saveGitHubToken
        self.fetchGitHubProfile = fetchGitHubProfile
        self.removeGitHubToken = removeGitHubToken
        self.protectedStorageAvailable = protectedStorageAvailable
    }

    func status() -> LocalStatus {
        LocalStatus(enrollmentCode: enrollmentCode, enabled: experimentID != nil,
                    githubProfile: githubProfile, protectedStorageAvailable: protectedStorageAvailable())
    }

    /// Called only by the local settings surface. No remote enable/reset route exists.
    func enable() throws -> LocalStatus {
        guard executing == nil else { throw Failure.approvalRefused }
        try disable()
        try createCredential()
        return start(githubProfile: false)
    }

    /// Token entry and mode selection are local-only. Replacing a token starts new authority.
    func enableGitHub(token: String) throws -> LocalStatus {
        guard executing == nil else { throw Failure.approvalRefused }
        guard protectedStorageAvailable() else { throw SecretApprovalGitHubFailure.protectedStorageRequired }
        guard SecretApprovalGitHubStore.accepts(token) else { throw SecretApprovalGitHubFailure.invalidToken }
        try disable()
        try saveGitHubToken(token)
        return start(githubProfile: true)
    }

    private func start(githubProfile: Bool) -> LocalStatus {
        self.githubProfile = githubProfile
        experimentID = UUID()
        enrollmentCode = String(format: "%08u", UInt32.random(in: 0..<RemoteSecretApprovalLab.enrollmentCodeUpperBound))
        enrollmentDeadline = now().addingTimeInterval(RemoteSecretApprovalLab.enrollmentLifetime)
        return status()
    }

    func disable() throws {
        experimentID = nil
        enrollmentCode = nil
        enrolled = nil
        pending = nil
        attempts = 0
        githubProfile = false
        let disposableRemoval = Result { try removeCredential() }
        let githubRemoval = Result { try removeGitHubToken() }
        try disposableRemoval.get()
        try githubRemoval.get()
    }

    func handle(_ request: RemoteSecretApprovalLab.Request, device: String, share: String,
                isAuthorized: @Sendable () -> Bool) async throws -> RemoteSecretApprovalLab.Response {
        guard isAuthorized(), let experimentID else { throw Failure.disabled }
        switch request.action {
        case .enroll:
            guard enrolled == nil, attempts < RemoteSecretApprovalLab.maximumEnrollmentAttempts, now() < enrollmentDeadline else {
                throw Failure.enrollmentRefused
            }
            attempts += 1
            guard let code = request.enrollmentCode, code == enrollmentCode,
                  let bytes = request.publicKey, bytes.count == RemoteSecretApprovalLab.publicKeyBytes,
                  let key = try? P256.Signing.PublicKey(x963Representation: bytes) else {
                throw Failure.enrollmentRefused
            }
            enrolled = (device, share, key)
            enrollmentCode = nil
            return .init()
        case .challenge:
            guard enrolled?.device == device, enrolled?.share == share, executing == nil else {
                throw Failure.approvalRefused
            }
            // One outstanding operation; returning it does not extend its lifetime.
            if let pending, now() < pendingDeadline { return .init(challenge: pending) }
            pendingDeadline = now().addingTimeInterval(TimeInterval(RemoteSecretApprovalLab.approvalLifetime))
            let challenge = RemoteSecretApprovalLab.Challenge(
                experimentID: experimentID, id: UUID(), deviceID: device,
                expiresAt: Int64(pendingDeadline.timeIntervalSince1970), githubProfile: githubProfile
            )
            pending = challenge
            return .init(challenge: challenge)
        case .approve:
            guard let enrolled, enrolled.device == device, enrolled.share == share,
                  let challenge = pending, request.challengeID == challenge.id,
                  now() < pendingDeadline,
                  let bytes = request.signature, bytes.count <= RemoteSecretApprovalLab.maximumSignatureBytes,
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: bytes),
                  enrolled.key.isValidSignature(signature, for: try challenge.signingData()),
                  isAuthorized() else { throw Failure.approvalRefused }
            // Consume before touching Keychain, including failure: never execute a retry twice.
            pending = nil
            executing = challenge.id
            defer { executing = nil }
            if challenge.isGitHubProfile {
                let login = try await fetchGitHubProfile()
                guard RemoteSecretApprovalLab.isValidGitHubLogin(login), self.experimentID == experimentID,
                      isAuthorized() else { throw Failure.approvalRefused }
                return .init(receipt: challenge.id, githubLogin: login)
            } else {
                try useCredential(challenge.signingData())
                return .init(receipt: challenge.id)
            }
        case .cancel:
            guard enrolled?.device == device, enrolled?.share == share else {
                throw Failure.approvalRefused
            }
            if pending?.id == request.challengeID { pending = nil }
            return .init()
        }
    }
}

/// Only this disposable item is ever touched. Never queries a user's existing credentials.
private enum SecretApprovalLabCredential {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: KeychainStoragePolicy.remoteService("com.threading.secret-approval-lab"),
         kSecAttrAccount as String: "disposable-test-only",
         kSecUseDataProtectionKeychain as String: KeychainStoragePolicy.usesDataProtectionKeychain]
    }
    static func create() throws {
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var attributes = query
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = secret
        let result = SecItemAdd(attributes as CFDictionary, nil)
        guard result == errSecSuccess else { throw SecretApprovalLab.Failure.keychain(result) }
    }
    static func use(_ message: Data) throws {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let bytes = result as? Data else {
            throw SecretApprovalLab.Failure.keychain(status)
        }
        let key = SymmetricKey(data: bytes)
        let proof = HMAC<SHA256>.authenticationCode(for: message, using: key)
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: key) else {
            throw SecretApprovalLab.Failure.approvalRefused
        }
        // The result is deliberately only a receipt, never the secret or its derived proof.
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretApprovalLab.Failure.keychain(status)
        }
    }
}
#endif
