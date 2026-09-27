import CryptoKit
import Foundation

/// One use of a secret on the Mac, approved with Face ID on a paired iPhone.
///
/// A local client on the Mac (keyvault first) holds an *envelope*: a secret sealed to a key that
/// lives in the iPhone's Secure Enclave and opens only after Face ID. The client hands the Mac the
/// envelope together with what the person is being asked to approve; the phone shows exactly that,
/// opens the envelope after Face ID, and signs the request it showed. The Mac checks the signature
/// against the enrolled device and returns the secret to the waiting client, which checks the
/// secret itself. Nothing on the Mac can open an envelope, and the Mac keeps no secret.
///
/// Off unless enabled on the Mac and enrolled from the phone. See
/// `docs/feature-drafts/faceid-secret-approval-poc.md`.
public enum RemoteSecretApproval {
    public static let path = "/api/secret-approval"
    public static let signingDomain = "Threading.SecretApproval.v1\n"
    public static let enrollmentLifetime: TimeInterval = 300
    /// Long enough to take the phone out of a pocket; short enough that a forgotten request dies.
    public static let approvalLifetime: Int64 = 120
    public static let maximumEnrollmentAttempts = 5
    public static let enrollmentCodeDigits = 8
    public static let enrollmentCodeUpperBound: UInt32 = 100_000_000
    public static let maximumRequestBytes = 8192
    public static let maximumResponseBytes = 8192
    public static let requestTimeout: TimeInterval = 10
    public static let publicKeyBytes = 65
    public static let maximumSignatureBytes = 80
    public static let maximumSecretBytes = 1024
    public static let maximumTitleBytes = 120
    public static let maximumLines = 12
    public static let maximumLineBytes = 240
    public static let maximumRequesterBytes = 240
    public static let maximumClientBytes = 32
    public static let allowedClockSkew: Int64 = 5

    public enum Action: String, Codable, Sendable {
        case enroll, pending, approve, deny
    }

    /// What the phone sends. `secret` travels only with `approve`, over the pinned connection.
    public struct Request: Codable, Sendable {
        public let action: Action
        public let enrollmentCode: String?
        public let signingKey: Data?
        public let agreementKey: Data?
        public let requestID: UUID?
        public let signature: Data?
        public let secret: Data?

        public init(action: Action, enrollmentCode: String? = nil, signingKey: Data? = nil,
                    agreementKey: Data? = nil, requestID: UUID? = nil, signature: Data? = nil,
                    secret: Data? = nil) {
            self.action = action
            self.enrollmentCode = enrollmentCode
            self.signingKey = signingKey
            self.agreementKey = agreementKey
            self.requestID = requestID
            self.signature = signature
            self.secret = secret
        }
    }

    /// A secret sealed to one enrolled device's key-agreement key. Not itself a secret: only that
    /// device's Secure Enclave, after Face ID, can open it.
    public struct Envelope: Codable, Equatable, Sendable {
        public let version: Int
        /// The recipient's X9.63 public key, so a phone can tell an envelope for another key.
        public let recipient: Data
        public let ephemeral: Data
        public let sealed: Data

        public init(version: Int, recipient: Data, ephemeral: Data, sealed: Data) {
            self.version = version
            self.recipient = recipient
            self.ephemeral = ephemeral
            self.sealed = sealed
        }
    }

    /// The one request waiting for this device, exactly as the phone shows and signs it.
    /// `requester` is the process chain the Mac observed on its own socket, not a claim.
    public struct Pending: Codable, Equatable, Sendable {
        public let id: UUID
        public let deviceID: String
        public let expiresAt: Int64
        public let client: String
        public let title: String
        public let lines: [String]
        public let requester: String
        public let envelope: Envelope

        public init(id: UUID, deviceID: String, expiresAt: Int64, client: String, title: String,
                    lines: [String], requester: String, envelope: Envelope) {
            self.id = id
            self.deviceID = deviceID
            self.expiresAt = expiresAt
            self.client = client
            self.title = title
            self.lines = lines
            self.requester = requester
            self.envelope = envelope
        }

        /// Bounded on both ends: the Mac refuses to create anything larger, the phone refuses to
        /// show it.
        public var isWellFormed: Bool {
            !client.isEmpty && client.utf8.count <= RemoteSecretApproval.maximumClientBytes
                && !title.isEmpty && title.utf8.count <= RemoteSecretApproval.maximumTitleBytes
                && lines.count <= RemoteSecretApproval.maximumLines
                && lines.allSatisfy { $0.utf8.count <= RemoteSecretApproval.maximumLineBytes }
                && requester.utf8.count <= RemoteSecretApproval.maximumRequesterBytes
                && envelope.version == RemoteSecretEnvelope.version
        }

        /// Same canonical bytes on both platforms; domain separation excludes other protocols,
        /// the lab's included.
        public func signingData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var result = Data(RemoteSecretApproval.signingDomain.utf8)
            result.append(try encoder.encode(self))
            return result
        }
    }

    public struct Response: Codable, Sendable {
        public let pending: Pending?
        public let receipt: UUID?

        public init(pending: Pending? = nil, receipt: UUID? = nil) {
            self.pending = pending
            self.receipt = receipt
        }
    }
}

/// ECIES over P-256: an ephemeral key agreement with the recipient, HKDF-SHA256, AES-GCM. The
/// phone opens with its Secure Enclave key; anything else opens with a software key in tests.
public enum RemoteSecretEnvelope {
    public static let version = 1
    static let info = Data("Threading.SecretEnvelope.v1".utf8)
    static let keyBytes = 32

    public enum Failure: Error, Equatable {
        case unsupportedVersion, wrongRecipient, malformed, tooLarge
    }

    public static func seal(
        _ secret: Data,
        to recipient: P256.KeyAgreement.PublicKey,
        ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()
    ) throws -> RemoteSecretApproval.Envelope {
        guard !secret.isEmpty, secret.count <= RemoteSecretApproval.maximumSecretBytes else { throw Failure.tooLarge }
        let recipientBytes = recipient.x963Representation
        let ephemeralBytes = ephemeral.publicKey.x963Representation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = symmetricKey(shared, ephemeral: ephemeralBytes, recipient: recipientBytes)
        let box = try AES.GCM.seal(secret, using: key, authenticating: associatedData(recipientBytes))
        guard let combined = box.combined else { throw Failure.malformed }
        return .init(version: version, recipient: recipientBytes, ephemeral: ephemeralBytes, sealed: combined)
    }

    /// `agree` performs the key agreement with the envelope's ephemeral key: a Secure Enclave key
    /// on the phone, which is where Face ID gates it.
    public static func open(
        _ envelope: RemoteSecretApproval.Envelope,
        as recipient: P256.KeyAgreement.PublicKey,
        agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret
    ) throws -> Data {
        guard envelope.version == version else { throw Failure.unsupportedVersion }
        guard envelope.recipient == recipient.x963Representation else { throw Failure.wrongRecipient }
        guard let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: envelope.ephemeral),
              let box = try? AES.GCM.SealedBox(combined: envelope.sealed) else { throw Failure.malformed }
        let key = symmetricKey(try agree(ephemeral), ephemeral: envelope.ephemeral, recipient: envelope.recipient)
        return try AES.GCM.open(box, using: key, authenticating: associatedData(envelope.recipient))
    }

    static func symmetricKey(_ shared: SharedSecret, ephemeral: Data, recipient: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + recipient,
                                       sharedInfo: info, outputByteCount: keyBytes)
    }

    static func associatedData(_ recipient: Data) -> Data {
        var data = Data([UInt8(version)])
        data.append(recipient)
        return data
    }
}
