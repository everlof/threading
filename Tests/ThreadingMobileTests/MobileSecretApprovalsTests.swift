import CryptoKit
import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

@MainActor
final class MobileSecretApprovalsTests: XCTestCase {
    /// The phone and the Mac show one fingerprint for the enrolled key, so a person can compare
    /// them by eye. Same bytes in, same sixteen hex digits out, grouped in fours.
    func testTheCodeFieldKeepsEightDigitsInTwoGroups() {
        XCTAssertEqual(MobileSecretApprovals.formatted("12345678"), "1234 5678")
        XCTAssertEqual(MobileSecretApprovals.formatted("1234 5678"), "1234 5678")
        XCTAssertEqual(MobileSecretApprovals.formatted("12a34-5678 99"), "1234 5678")
        XCTAssertEqual(MobileSecretApprovals.formatted("123"), "123")
        XCTAssertEqual(MobileSecretApprovals.digits("1234 5678"), "12345678")
    }

    func testTheCountdownNeverGoesBelowZero() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(MobileSecretApprovals.remaining(until: 1_095, now: now), "1:35")
        XCTAssertEqual(MobileSecretApprovals.remaining(until: 990, now: now), "0:00")
    }

    func testEveryEvidenceStateResolves() {
        XCTAssertEqual(MobileSecretApprovals.Preview.demo("secret-approvals-enroll"), .enroll)
        XCTAssertEqual(MobileSecretApprovals.Preview.demo("secret-approvals-ready"), .ready)
        XCTAssertEqual(MobileSecretApprovals.Preview.demo("secret-approvals-approved"), .approved)
        guard case .request(let request) = MobileSecretApprovals.Preview.demo("secret-approvals-request") else {
            return XCTFail("the request state needs a request")
        }
        XCTAssertTrue(request.isWellFormed, "the evidence request must be one the app would show")
    }

    func testTheFingerprintIsTheMacsFormat() throws {
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let fingerprint = MobileSecretApprovalKeys.fingerprint(key.publicKey.x963Representation)
        let expected = SHA256.hash(data: key.publicKey.x963Representation).prefix(8)
            .map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(fingerprint.replacingOccurrences(of: " ", with: ""), expected)
        XCTAssertEqual(fingerprint.split(separator: " ").count, 4)
    }

    /// Every refusal says that nothing was opened, or what to change; none claims success.
    func testFailuresSayWhatHappenedWithoutClaimingAnApproval() {
        let failures: [Error] = [
            MobileSecretApprovalFailure.preview, MobileSecretApprovalFailure.pairFirst,
            MobileSecretApprovalFailure.directConnectionRequired, MobileSecretApprovalFailure.pinnedConnectionRequired,
            MobileSecretApprovalFailure.invalidCode, MobileSecretApprovalKeys.Failure.faceIDRequired,
            MobileSecretApprovalKeys.Failure.invalidRequest, URLError(.timedOut)
        ]
        let messages = failures.map { MobileSecretApprovals.message(for: $0) }
        XCTAssertEqual(Set(messages).count, messages.count, "each failure has its own explanation")
        for message in messages {
            XCTAssertFalse(message.localizedCaseInsensitiveContains("approved"), message)
        }
    }

    /// The phone refuses to show or sign what the Mac should never have sent.
    func testAnOversizedOrForeignRequestIsNotWellFormed() throws {
        let envelope = try RemoteSecretEnvelope.seal(Data("x".utf8), to: P256.KeyAgreement.PrivateKey().publicKey)
        let oversized = RemoteSecretApproval.Pending(
            id: UUID(), deviceID: "d", expiresAt: 1, client: "keyvault",
            title: String(repeating: "x", count: RemoteSecretApproval.maximumTitleBytes + 1),
            lines: [], requester: "r", envelope: envelope)
        XCTAssertFalse(oversized.isWellFormed)
    }
}
