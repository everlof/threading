import CryptoKit
import XCTest
@testable import ThreadingRemoteKit

final class RemoteSecretApprovalTests: XCTestCase {
    private let secret = Data("test secret, opened only by the enrolled phone".utf8)

    func testAnEnvelopeOpensOnlyWithItsRecipientsKey() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let envelope = try RemoteSecretEnvelope.seal(secret, to: phone.publicKey)
        let opened = try RemoteSecretEnvelope.open(envelope, as: phone.publicKey) {
            try phone.sharedSecretFromKeyAgreement(with: $0)
        }
        XCTAssertEqual(opened, secret)

        let other = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try RemoteSecretEnvelope.open(envelope, as: other.publicKey) {
            try other.sharedSecretFromKeyAgreement(with: $0)
        }) { XCTAssertEqual($0 as? RemoteSecretEnvelope.Failure, .wrongRecipient) }
    }

    func testTheSealedBytesDoNotHoldTheSecret() throws {
        let envelope = try RemoteSecretEnvelope.seal(secret, to: P256.KeyAgreement.PrivateKey().publicKey)
        let encoded = try JSONEncoder().encode(envelope)
        XCTAssertNil(encoded.range(of: secret))
        XCTAssertNil(encoded.range(of: Data("test secret".utf8)))
    }

    func testATamperedEnvelopeIsRefused() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let envelope = try RemoteSecretEnvelope.seal(secret, to: phone.publicKey)
        var bytes = envelope.sealed
        bytes[bytes.count - 1] ^= 0x01
        let tampered = RemoteSecretApproval.Envelope(version: envelope.version, recipient: envelope.recipient,
                                                     ephemeral: envelope.ephemeral, sealed: bytes)
        XCTAssertThrowsError(try RemoteSecretEnvelope.open(tampered, as: phone.publicKey) {
            try phone.sharedSecretFromKeyAgreement(with: $0)
        })
    }

    func testAnUnknownVersionAndAnOversizedSecretAreRefused() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let envelope = try RemoteSecretEnvelope.seal(secret, to: phone.publicKey)
        let future = RemoteSecretApproval.Envelope(version: 2, recipient: envelope.recipient,
                                                   ephemeral: envelope.ephemeral, sealed: envelope.sealed)
        XCTAssertThrowsError(try RemoteSecretEnvelope.open(future, as: phone.publicKey) {
            try phone.sharedSecretFromKeyAgreement(with: $0)
        }) { XCTAssertEqual($0 as? RemoteSecretEnvelope.Failure, .unsupportedVersion) }
        let huge = Data(repeating: 1, count: RemoteSecretApproval.maximumSecretBytes + 1)
        XCTAssertThrowsError(try RemoteSecretEnvelope.seal(huge, to: phone.publicKey)) {
            XCTAssertEqual($0 as? RemoteSecretEnvelope.Failure, .tooLarge)
        }
    }

    /// The Mac seals and the phone opens with separate builds; one fixed vector keeps them one
    /// algorithm. Recomputed here from fixed keys, so a changed KDF, AAD or cipher fails loudly.
    func testAFixedVectorStaysStable() throws {
        let phone = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: phone.publicKey)
        let key = RemoteSecretEnvelope.symmetricKey(shared, ephemeral: ephemeral.publicKey.x963Representation,
                                                    recipient: phone.publicKey.x963Representation)
        let digest = SHA256.hash(data: key.withUnsafeBytes { Data($0) }).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.fixedDerivationDigest)
    }

    // SHA-256 of the derived key for the fixed keys above: a changed KDF, salt or info changes it.
    static let fixedDerivationDigest = "955154813aae44bacb0fe01244a7179115930e2af35ad6d5ae87ab0551267357"

    func testSigningBytesAreDomainSeparatedAndCoverWhatIsShown() throws {
        let envelope = try RemoteSecretEnvelope.seal(secret, to: P256.KeyAgreement.PrivateKey().publicKey)
        let pending = RemoteSecretApproval.Pending(
            id: UUID(), deviceID: "device", expiresAt: 1_900_000_000, client: "keyvault",
            title: "Approve grant kv-1a2b3c4d", lines: ["AuthKey_ABCDE12345.p8", "for 30m"],
            requester: "bash<claude<zsh", envelope: envelope)
        let bytes = try pending.signingData()
        XCTAssertTrue(bytes.starts(with: Data(RemoteSecretApproval.signingDomain.utf8)))
        let changed = RemoteSecretApproval.Pending(
            id: pending.id, deviceID: pending.deviceID, expiresAt: pending.expiresAt, client: pending.client,
            title: pending.title, lines: ["AuthKey_ABCDE12345.p8", "for 12h"],
            requester: pending.requester, envelope: envelope)
        XCTAssertNotEqual(try changed.signingData(), bytes)
        XCTAssertTrue(pending.isWellFormed)
    }

    func testOversizedRequestsAreNotWellFormed() throws {
        let envelope = try RemoteSecretEnvelope.seal(secret, to: P256.KeyAgreement.PrivateKey().publicKey)
        func pending(title: String = "t", lines: [String] = [], requester: String = "r") -> RemoteSecretApproval.Pending {
            .init(id: UUID(), deviceID: "d", expiresAt: 1, client: "keyvault", title: title, lines: lines,
                  requester: requester, envelope: envelope)
        }
        XCTAssertFalse(pending(title: "").isWellFormed)
        XCTAssertFalse(pending(title: String(repeating: "x", count: RemoteSecretApproval.maximumTitleBytes + 1)).isWellFormed)
        XCTAssertFalse(pending(lines: Array(repeating: "x", count: RemoteSecretApproval.maximumLines + 1)).isWellFormed)
        XCTAssertFalse(pending(lines: [String(repeating: "x", count: RemoteSecretApproval.maximumLineBytes + 1)]).isWellFormed)
        XCTAssertFalse(pending(requester: String(repeating: "x", count: RemoteSecretApproval.maximumRequesterBytes + 1)).isWellFormed)
    }
}
