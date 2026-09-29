import CryptoKit
import Foundation
import Security
import ThreadingRemoteKit

// MARK: - Enrollment

/// The one iPhone allowed to approve, bound to the owner grant it enrolled with. Public keys only:
/// losing this record revokes approval, it never discloses anything.
struct SecretApprovalEnrollment: Codable, Equatable, Sendable {
    let deviceID: String
    let shareID: String
    let signingKey: Data
    let agreementKey: Data
    let enrolledAt: Date

    /// Short, stable and comparable by eye on the phone: the first 64 bits of SHA-256 over the
    /// key-agreement key, the key every envelope is sealed to.
    var fingerprint: String {
        SHA256.hash(data: agreementKey).prefix(8).map { String(format: "%02X", $0) }
            .joined().chunked(into: 4).joined(separator: " ")
    }
}

protocol SecretApprovalEnrollmentStoring: Sendable {
    func load() throws -> SecretApprovalEnrollment?
    func save(_ enrollment: SecretApprovalEnrollment) throws
    func remove() throws
    var isShellReachable: Bool { get }
}

/// Protected Keychain when this build can use it: the enrolled key decides whom a secret is
/// sealed to, so a command line — an agent's included — must not be able to swap in its own.
struct SecretApprovalEnrollmentKeychainStore: SecretApprovalEnrollmentStoring {
    private let keychain: any KeychainItemAccessing & Sendable
    static let maximumBytes = 4096

    init(keychain: any KeychainItemAccessing & Sendable = SystemKeychainItemAccess()) {
        self.keychain = keychain
    }

    var isShellReachable: Bool { KeychainStoragePolicy.isShellReachable }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: KeychainStoragePolicy.remoteService("codes.threading.secret-approval.device"),
         kSecAttrAccount as String: "enrollment-v1",
         kSecUseDataProtectionKeychain as String: KeychainStoragePolicy.usesDataProtectionKeychain,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> SecretApprovalEnrollment? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = keychain.data(matching: item)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess, let data = result.data else {
            throw SecretApprovalBroker.Failure.keychain(result.status)
        }
        guard data.count <= Self.maximumBytes,
              let enrollment = try? JSONDecoder().decode(SecretApprovalEnrollment.self, from: data),
              SecretApprovalBroker.validKeys(enrollment) else {
            throw SecretApprovalBroker.Failure.malformed
        }
        return enrollment
    }

    func save(_ enrollment: SecretApprovalEnrollment) throws {
        try remove()
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = try JSONEncoder().encode(enrollment)
        let status = keychain.add(item)
        guard status == errSecSuccess else { throw SecretApprovalBroker.Failure.keychain(status) }
    }

    func remove() throws {
        let status = keychain.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretApprovalBroker.Failure.keychain(status)
        }
    }
}

// MARK: - Broker

/// Approval of one secret use at a time, by one enrolled iPhone.
///
/// Three callers, three doors: the Mac's own settings (enable, enroll, forget), a local client
/// over `SecretApprovalLocalServer` (seal a secret to the phone; ask the phone to open one) and
/// the paired phone over the pinned remote route (enroll, read the pending request, approve or
/// deny it). The broker never holds a secret beyond handing an opened one to the client that
/// asked for it, and there is no remote route to enable anything.
actor SecretApprovalBroker {
    static let shared = SecretApprovalBroker()

    enum Failure: Error, Equatable {
        case disabled, notEnrolled, enrollmentRefused, approvalRefused, busy, expired, denied,
             malformed, wrongDevice, keychain(OSStatus)
    }

    struct Status: Equatable, Sendable {
        let enabled: Bool
        let enrollmentCode: String?
        let enrollment: SecretApprovalEnrollment?
        let pendingTitle: String?
        let isShellReachable: Bool
        /// When the enrollment code stops working; nil without a live code.
        var enrollmentExpiresAt: Date? = nil
        /// When the waiting request expires; nil without one.
        var pendingExpiresAt: Date? = nil
    }

    // MARK: Properties

    private let store: any SecretApprovalEnrollmentStoring
    private let now: @Sendable () -> Date
    private let isEnabled: @Sendable () -> Bool
    private var enrollmentCode: String?
    private var enrollmentDeadline = Date.distantPast
    private var attempts = 0
    private var loaded = false
    private var enrollment: SecretApprovalEnrollment?
    private var pending: RemoteSecretApproval.Pending?
    private var waiter: CheckedContinuation<Data, Error>?
    /// Told of each new request so the enrolled iPhone can be alerted. It gets the request as the
    /// phone will see it; the envelope inside stays sealed to the phone.
    private var onRequest: (@Sendable (RemoteSecretApproval.Pending, _ shareID: String) -> Void)?

    // MARK: Initialization

    init(store: any SecretApprovalEnrollmentStoring = SecretApprovalEnrollmentKeychainStore(),
         now: @escaping @Sendable () -> Date = { Date() },
         isEnabled: @escaping @Sendable () -> Bool = { AppSettings.secretApprovalsEnabledFromAnyContext }) {
        self.store = store
        self.now = now
        self.isEnabled = isEnabled
    }

    // MARK: Local settings

    func observeRequests(_ observer: (@Sendable (RemoteSecretApproval.Pending, _ shareID: String) -> Void)?) {
        onRequest = observer
    }

    func status() -> Status {
        // A code past its deadline or out of attempts is gone, not merely refused: the page must
        // never show a code the phone can no longer use.
        if enrollmentCode != nil, now() >= enrollmentDeadline || attempts >= RemoteSecretApproval.maximumEnrollmentAttempts {
            enrollmentCode = nil
            ThreadingLogger.secretApproval.info("Enrollment code expired unused")
        }
        expireIfDue()
        return Status(enabled: isEnabled(), enrollmentCode: enrollmentCode, enrollment: try? currentEnrollment(),
                      pendingTitle: pending?.title, isShellReachable: store.isShellReachable,
                      enrollmentExpiresAt: enrollmentCode == nil ? nil : enrollmentDeadline,
                      pendingExpiresAt: pending.map { Date(timeIntervalSince1970: TimeInterval($0.expiresAt)) })
    }

    /// Local only: an eight-digit code the phone types within five minutes, five attempts.
    func beginEnrollment() throws -> String {
        guard isEnabled() else { throw Failure.disabled }
        let code = String(format: "%08u", UInt32.random(in: 0..<RemoteSecretApproval.enrollmentCodeUpperBound))
        enrollmentCode = code
        enrollmentDeadline = now().addingTimeInterval(RemoteSecretApproval.enrollmentLifetime)
        attempts = 0
        ThreadingLogger.secretApproval.notice("Enrollment code issued, valid \(Int(RemoteSecretApproval.enrollmentLifetime), privacy: .public) s")
        return code
    }

    func cancelEnrollment() {
        if enrollmentCode != nil { ThreadingLogger.secretApproval.info("Enrollment cancelled on this Mac") }
        enrollmentCode = nil
    }

    /// Forgetting the phone also refuses whatever it was about to approve. Envelopes sealed to it
    /// become useless; the client re-seals after a new enrollment.
    func forgetDevice() throws {
        try store.remove()
        enrollment = nil
        loaded = true
        enrollmentCode = nil
        ThreadingLogger.secretApproval.notice("iPhone forgotten on this Mac")
        finish(throwing: Failure.wrongDevice)
    }

    /// Turning the feature off keeps the enrollment but ends anything in flight.
    func disabled() {
        enrollmentCode = nil
        finish(throwing: Failure.disabled)
    }

    // MARK: Local client

    /// Seals `secret` to the enrolled phone. The Mac cannot open the result.
    func wrap(_ secret: Data) throws -> RemoteSecretApproval.Envelope {
        guard isEnabled() else { throw Failure.disabled }
        guard let enrollment = try currentEnrollment() else { throw Failure.notEnrolled }
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: enrollment.agreementKey)
        return try RemoteSecretEnvelope.seal(secret, to: recipient)
    }

    /// Waits until the phone approves (the opened secret), denies, or the request expires. One
    /// request at a time: a second one is refused rather than queued behind a person's decision.
    func unwrap(client: String, title: String, lines: [String], requester: String,
                envelope: RemoteSecretApproval.Envelope) async throws -> Data {
        guard isEnabled() else {
            ThreadingLogger.secretApproval.notice("Request from \(client, privacy: .public) refused: Face ID approvals are off")
            throw Failure.disabled
        }
        guard let enrollment = try currentEnrollment() else {
            ThreadingLogger.secretApproval.notice("Request from \(client, privacy: .public) refused: no iPhone enrolled")
            throw Failure.notEnrolled
        }
        guard envelope.recipient == enrollment.agreementKey else {
            ThreadingLogger.secretApproval.notice("Request from \(client, privacy: .public) refused: sealed to another iPhone")
            throw Failure.wrongDevice
        }
        expireIfDue()
        guard pending == nil else {
            ThreadingLogger.secretApproval.notice("Request from \(client, privacy: .public) refused: another is waiting")
            throw Failure.busy
        }
        let request = RemoteSecretApproval.Pending(
            id: UUID(), deviceID: enrollment.deviceID,
            expiresAt: Int64(now().timeIntervalSince1970) + RemoteSecretApproval.approvalLifetime,
            client: client, title: title, lines: lines, requester: requester, envelope: envelope)
        guard request.isWellFormed else { throw Failure.malformed }
        pending = request
        ThreadingLogger.secretApproval.notice(
            "Request from \(client, privacy: .public), asked by \(requester, privacy: .private(mask: .hash)), waits \(RemoteSecretApproval.approvalLifetime, privacy: .public) s for the iPhone")
        onRequest?(request, enrollment.shareID)
        let id = request.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RemoteSecretApproval.approvalLifetime) * 1_000_000_000)
            await self?.expire(id)
        }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    // MARK: Remote (the paired phone)

    func handle(_ request: RemoteSecretApproval.Request, device: String, share: String,
                isAuthorized: @Sendable () -> Bool) throws -> RemoteSecretApproval.Response {
        guard isAuthorized(), isEnabled() else { throw Failure.disabled }
        switch request.action {
        case .enroll:
            guard let code = enrollmentCode, attempts < RemoteSecretApproval.maximumEnrollmentAttempts,
                  now() < enrollmentDeadline else {
                ThreadingLogger.secretApproval.notice("Enrollment refused: no live code on this Mac")
                throw Failure.enrollmentRefused
            }
            attempts += 1
            guard request.enrollmentCode == code,
                  let signing = request.signingKey, let agreement = request.agreementKey else {
                ThreadingLogger.secretApproval.notice("Enrollment refused: wrong code, attempt \(self.attempts, privacy: .public)")
                throw Failure.enrollmentRefused
            }
            let candidate = SecretApprovalEnrollment(deviceID: device, shareID: share, signingKey: signing,
                                                     agreementKey: agreement, enrolledAt: now())
            guard Self.validKeys(candidate) else { throw Failure.enrollmentRefused }
            try store.save(candidate)
            enrollment = candidate
            loaded = true
            enrollmentCode = nil
            ThreadingLogger.secretApproval.notice("iPhone enrolled, key \(candidate.fingerprint, privacy: .public)")
            finish(throwing: Failure.wrongDevice)     // anything sealed to a previous phone
            return .init()
        case .pending:
            try requireEnrolled(device: device, share: share)
            expireIfDue()
            ThreadingLogger.secretApproval.debug("The iPhone checked: \(self.pending == nil ? "nothing waiting" : "a request is waiting", privacy: .public)")
            return .init(pending: pending)
        case .approve:
            let enrolled = try requireEnrolled(device: device, share: share)
            expireIfDue()
            guard let pending, request.requestID == pending.id,
                  let bytes = request.signature, bytes.count <= RemoteSecretApproval.maximumSignatureBytes,
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: bytes),
                  let key = try? P256.Signing.PublicKey(x963Representation: enrolled.signingKey),
                  key.isValidSignature(signature, for: try pending.signingData()),
                  let secret = request.secret, !secret.isEmpty,
                  secret.count <= RemoteSecretApproval.maximumSecretBytes,
                  isAuthorized() else {
                ThreadingLogger.secretApproval.notice("Approval refused: not the request shown, or a bad signature")
                throw Failure.approvalRefused
            }
            ThreadingLogger.secretApproval.notice("Approved with Face ID on the iPhone")
            finish(returning: secret)
            return .init(receipt: pending.id)
        case .deny:
            try requireEnrolled(device: device, share: share)
            guard let pending, request.requestID == pending.id else { throw Failure.approvalRefused }
            ThreadingLogger.secretApproval.notice("Denied on the iPhone")
            finish(throwing: Failure.denied)
            return .init(receipt: pending.id)
        }
    }

    // MARK: Private

    static func validKeys(_ enrollment: SecretApprovalEnrollment) -> Bool {
        enrollment.signingKey.count == RemoteSecretApproval.publicKeyBytes
            && enrollment.agreementKey.count == RemoteSecretApproval.publicKeyBytes
            && (try? P256.Signing.PublicKey(x963Representation: enrollment.signingKey)) != nil
            && (try? P256.KeyAgreement.PublicKey(x963Representation: enrollment.agreementKey)) != nil
    }

    private func currentEnrollment() throws -> SecretApprovalEnrollment? {
        if !loaded {
            enrollment = try store.load()
            loaded = true
        }
        return enrollment
    }

    @discardableResult
    private func requireEnrolled(device: String, share: String) throws -> SecretApprovalEnrollment {
        guard let enrolled = try currentEnrollment() else {
            ThreadingLogger.secretApproval.notice("An iPhone asked, but none is enrolled")
            throw Failure.notEnrolled
        }
        guard enrolled.deviceID == device, enrolled.shareID == share else {
            ThreadingLogger.secretApproval.notice(
                "Refused an iPhone that is not the enrolled one (device matches: \(enrolled.deviceID == device, privacy: .public), pairing matches: \(enrolled.shareID == share, privacy: .public))")
            throw Failure.wrongDevice
        }
        return enrolled
    }

    private func expireIfDue() {
        if let pending, Int64(now().timeIntervalSince1970) >= pending.expiresAt {
            ThreadingLogger.secretApproval.notice("Request expired unanswered")
            finish(throwing: Failure.expired)
        }
    }

    private func expire(_ id: UUID) {
        if pending?.id == id {
            ThreadingLogger.secretApproval.notice("Request expired unanswered")
            finish(throwing: Failure.expired)
        }
    }

    /// Consumes the request before resuming: an approval can never be used twice.
    private func finish(returning secret: Data) {
        let waiting = waiter
        pending = nil
        waiter = nil
        waiting?.resume(returning: secret)
    }

    private func finish(throwing failure: Failure) {
        let waiting = waiter
        pending = nil
        waiter = nil
        waiting?.resume(throwing: failure)
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map {
            let start = index(startIndex, offsetBy: $0)
            return String(self[start..<(index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex)])
        }
    }
}
