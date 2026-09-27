#if DEBUG
import CryptoKit
import Foundation
import XCTest
import ThreadingRemoteKit
@testable import Threading

final class SecretApprovalLabTests: XCTestCase {
    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_800_000_000)
        private var uses = 0
        func now() -> Date { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time.addTimeInterval(seconds) } }
        func use() { lock.withLock { uses += 1 } }
        var count: Int { lock.withLock { uses } }
        func lab() -> SecretApprovalLab {
            SecretApprovalLab(now: { self.now() }, createCredential: {},
                              useCredential: { _ in self.use() }, removeCredential: {},
                              removeGitHubToken: {}, protectedStorageAvailable: { false })
        }
    }
    private let device = "test-phone"
    private let share = "test-owner"

    private func enroll(_ lab: SecretApprovalLab, key: P256.Signing.PrivateKey) async throws {
        let status = try await lab.enable()
        _ = try await lab.handle(.init(action: .enroll, enrollmentCode: status.enrollmentCode,
                                      publicKey: key.publicKey.x963Representation),
                                 device: device, share: share, isAuthorized: { true })
    }
    private func challenge(_ lab: SecretApprovalLab) async throws -> RemoteSecretApprovalLab.Challenge {
        let response = try await lab.handle(.init(action: .challenge), device: device,
                                            share: share, isAuthorized: { true })
        return try XCTUnwrap(response.challenge)
    }
    private func approval(_ value: RemoteSecretApprovalLab.Challenge, key: P256.Signing.PrivateKey) throws -> RemoteSecretApprovalLab.Request {
        .init(action: .approve, challengeID: value.id,
              signature: try key.signature(for: value.signingData()).derRepresentation)
    }
    private func expectRefused(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Operation should have been refused") }
        catch { }
    }

    func testSignedApprovalUsesCredentialExactlyOnce() async throws {
        let fixture = Fixture(), key = P256.Signing.PrivateKey()
        let lab = fixture.lab()
        try await enroll(lab, key: key)
        let offered = try await challenge(lab)
        let request = try approval(offered, key: key)
        let result = try await lab.handle(request, device: device, share: share, isAuthorized: { true })
        XCTAssertEqual(result.receipt, offered.id)
        XCTAssertEqual(fixture.count, 1)
        await expectRefused { _ = try await lab.handle(request, device: self.device, share: self.share, isAuthorized: { true }) }
        XCTAssertEqual(fixture.count, 1)
    }

    func testWrongKeyChangedPayloadAndWrongDeviceCannotAuthorize() async throws {
        let fixture = Fixture(), key = P256.Signing.PrivateKey()
        let lab = fixture.lab()
        try await enroll(lab, key: key)
        let offered = try await challenge(lab)
        let wrongKey = try approval(offered, key: P256.Signing.PrivateKey())
        await expectRefused { _ = try await lab.handle(wrongKey, device: self.device, share: self.share, isAuthorized: { true }) }
        let altered = RemoteSecretApprovalLab.Challenge(experimentID: offered.experimentID, id: offered.id,
                                                       deviceID: device, expiresAt: offered.expiresAt + 1)
        let alteredRequest = try approval(altered, key: key)
        await expectRefused { _ = try await lab.handle(alteredRequest, device: self.device, share: self.share, isAuthorized: { true }) }
        let valid = try approval(offered, key: key)
        await expectRefused { _ = try await lab.handle(valid, device: "other-phone", share: self.share, isAuthorized: { true }) }
        await expectRefused { _ = try await lab.handle(valid, device: self.device, share: "replacement-owner-grant", isAuthorized: { true }) }
        XCTAssertEqual(fixture.count, 0)
    }

    func testExpiryRevocationCancellationAndDisableFailClosed() async throws {
        let fixture = Fixture(), key = P256.Signing.PrivateKey()
        let lab = fixture.lab()
        try await enroll(lab, key: key)
        let first = try await challenge(lab)
        let same = try await challenge(lab)
        XCTAssertEqual(first, same)
        fixture.advance(60)
        let expired = try approval(first, key: key)
        await expectRefused { _ = try await lab.handle(expired, device: self.device, share: self.share, isAuthorized: { true }) }
        let next = try await challenge(lab)
        let valid = try approval(next, key: key)
        await expectRefused { _ = try await lab.handle(valid, device: self.device, share: self.share, isAuthorized: { false }) }
        _ = try await lab.handle(.init(action: .cancel, challengeID: next.id), device: device, share: share, isAuthorized: { true })
        await expectRefused { _ = try await lab.handle(valid, device: self.device, share: self.share, isAuthorized: { true }) }
        let third = try await challenge(lab)
        let stopped = try approval(third, key: key)
        try await lab.disable()
        await expectRefused { _ = try await lab.handle(stopped, device: self.device, share: self.share, isAuthorized: { true }) }
        XCTAssertEqual(fixture.count, 0)
    }

    func testEnrollmentIsLocallyEnabledExpiringAndAttemptLimited() async throws {
        let fixture = Fixture(), key = P256.Signing.PrivateKey()
        let lab = fixture.lab()
        let request = RemoteSecretApprovalLab.Request(action: .enroll, enrollmentCode: "00000000", publicKey: key.publicKey.x963Representation)
        await expectRefused { _ = try await lab.handle(request, device: self.device, share: self.share, isAuthorized: { true }) }
        let state = try await lab.enable()
        let invalid = RemoteSecretApprovalLab.Request(action: .enroll, enrollmentCode: "invalid", publicKey: key.publicKey.x963Representation)
        for _ in 0..<5 {
            await expectRefused { _ = try await lab.handle(invalid, device: self.device, share: self.share, isAuthorized: { true }) }
        }
        let correct = RemoteSecretApprovalLab.Request(action: .enroll, enrollmentCode: state.enrollmentCode, publicKey: key.publicKey.x963Representation)
        await expectRefused { _ = try await lab.handle(correct, device: self.device, share: self.share, isAuthorized: { true }) }
        let newState = try await lab.enable()
        fixture.advance(300)
        let tooLate = RemoteSecretApprovalLab.Request(action: .enroll, enrollmentCode: newState.enrollmentCode, publicKey: key.publicKey.x963Representation)
        await expectRefused { _ = try await lab.handle(tooLate, device: self.device, share: self.share, isAuthorized: { true }) }
    }

    func testCredentialFailureStillConsumesApproval() async throws {
        let lab = SecretApprovalLab(createCredential: {}, useCredential: { _ in throw CocoaError(.fileReadNoPermission) },
                                    removeCredential: {}, removeGitHubToken: {}, protectedStorageAvailable: { false })
        let key = P256.Signing.PrivateKey()
        try await enroll(lab, key: key)
        let offered = try await challenge(lab)
        let request = try approval(offered, key: key)
        await expectRefused { _ = try await lab.handle(request, device: self.device, share: self.share, isAuthorized: { true }) }
        await expectRefused { _ = try await lab.handle(request, device: self.device, share: self.share, isAuthorized: { true }) }
        let next = try await challenge(lab)
        XCTAssertNotEqual(next.id, offered.id)
    }

    func testGitHubRequestRequiresItsOwnSignedApprovalAndReturnsOnlyLoginAndReceipt() async throws {
        let fixture = Fixture(), key = P256.Signing.PrivateKey()
        let lab = SecretApprovalLab(createCredential: {}, useCredential: { _ in XCTFail("Wrong credential") },
            removeCredential: {}, saveGitHubToken: { _ in },
            fetchGitHubProfile: { fixture.use(); return "octocat" }, removeGitHubToken: {}, protectedStorageAvailable: { true })
        let state = try await lab.enableGitHub(token: "github_pat_testValue")
        _ = try await lab.handle(.init(action: .enroll, enrollmentCode: state.enrollmentCode,
                                      publicKey: key.publicKey.x963Representation),
                                 device: device, share: share, isAuthorized: { true })
        let offered = try await challenge(lab)
        XCTAssertTrue(offered.isGitHubProfile)
        XCTAssertEqual(fixture.count, 0, "Neither enrollment nor requesting an approval may read or send the token")
        let disposable = RemoteSecretApprovalLab.Challenge(experimentID: offered.experimentID, id: offered.id,
            deviceID: offered.deviceID, expiresAt: offered.expiresAt)
        let wrongPurpose = try approval(disposable, key: key)
        await expectRefused { _ = try await lab.handle(wrongPurpose, device: self.device, share: self.share, isAuthorized: { true }) }
        XCTAssertEqual(fixture.count, 0)
        let request = try approval(offered, key: key)
        let response = try await lab.handle(request, device: device, share: share, isAuthorized: { true })
        XCTAssertEqual(response.githubLogin, "octocat")
        XCTAssertEqual(response.receipt, offered.id)
        XCTAssertEqual(fixture.count, 1)
        await expectRefused { _ = try await lab.handle(request, device: self.device, share: self.share, isAuthorized: { true }) }
        XCTAssertEqual(fixture.count, 1)
    }

    func testGitHubEnrollmentRefusesUnprotectedStorageWithoutSavingAnything() async {
        let lab = SecretApprovalLab(createCredential: {}, useCredential: { _ in }, removeCredential: {},
            saveGitHubToken: { _ in XCTFail("Never save a real token to an unprotected build") },
            removeGitHubToken: {}, protectedStorageAvailable: { false })
        await expectRefused { _ = try await lab.enableGitHub(token: "github_pat_testValue") }
        let state = await lab.status()
        XCTAssertFalse(state.enabled)
    }

    func testFailedGitHubRequestConsumesApprovalWithoutRetry() async throws {
        let fixture = Fixture(), key = P256.Signing.PrivateKey()
        let lab = SecretApprovalLab(createCredential: {}, useCredential: { _ in }, removeCredential: {},
            saveGitHubToken: { _ in }, fetchGitHubProfile: { fixture.use(); throw URLError(.timedOut) },
            removeGitHubToken: {}, protectedStorageAvailable: { true })
        let state = try await lab.enableGitHub(token: "github_pat_testValue")
        _ = try await lab.handle(.init(action: .enroll, enrollmentCode: state.enrollmentCode,
                                      publicKey: key.publicKey.x963Representation),
                                 device: device, share: share, isAuthorized: { true })
        let offered = try await challenge(lab)
        let request = try approval(offered, key: key)
        for _ in 0..<2 {
            await expectRefused { _ = try await lab.handle(request, device: self.device, share: self.share, isAuthorized: { true }) }
        }
        XCTAssertEqual(fixture.count, 1)
    }

    private actor NetworkGate {
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var response: CheckedContinuation<String, Never>?
        func fetch() async -> String {
            started = true
            startWaiter?.resume()
            startWaiter = nil
            return await withCheckedContinuation { response = $0 }
        }
        func waitUntilStarted() async {
            if !started { await withCheckedContinuation { startWaiter = $0 } }
        }
        func finish() { response?.resume(returning: "octocat"); response = nil }
    }

    func testInFlightRequestCannotBeReplacedAndStopSuppressesItsResult() async throws {
        let gate = NetworkGate(), key = P256.Signing.PrivateKey()
        let lab = SecretApprovalLab(createCredential: {}, useCredential: { _ in }, removeCredential: {},
            saveGitHubToken: { _ in }, fetchGitHubProfile: { await gate.fetch() },
            removeGitHubToken: {}, protectedStorageAvailable: { true })
        let state = try await lab.enableGitHub(token: "github_pat_testValue")
        let device = self.device, share = self.share
        _ = try await lab.handle(.init(action: .enroll, enrollmentCode: state.enrollmentCode,
                                      publicKey: key.publicKey.x963Representation),
                                 device: device, share: share, isAuthorized: { true })
        let offered = try await challenge(lab)
        let request = try approval(offered, key: key)
        let operation = Task { try await lab.handle(request, device: device, share: share, isAuthorized: { true }) }
        await gate.waitUntilStarted()
        await expectRefused { _ = try await self.challenge(lab) }
        await expectRefused { _ = try await lab.enableGitHub(token: "github_pat_replacement") }
        try await lab.disable()
        await gate.finish()
        await expectRefused { _ = try await operation.value }
        let stopped = await lab.status()
        XCTAssertFalse(stopped.enabled)
        _ = try await lab.enableGitHub(token: "github_pat_newExperiment")
    }
}
#endif
