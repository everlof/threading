import CryptoKit
import Foundation
import Security
import XCTest
import ThreadingRemoteKit
@testable import Threading

final class SecretApprovalBrokerTests: XCTestCase {
    // MARK: - Fixtures

    private final class MemoryStore: SecretApprovalEnrollmentStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SecretApprovalEnrollment?
        var isShellReachable: Bool { false }
        func load() throws -> SecretApprovalEnrollment? { lock.withLock { stored } }
        func save(_ enrollment: SecretApprovalEnrollment) throws { lock.withLock { stored = enrollment } }
        func remove() throws { lock.withLock { stored = nil } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_900_000_000)
        func now() -> Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    }

    /// The phone, with software keys standing in for its Secure Enclave.
    private struct Phone {
        let signing = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()

        func enroll(_ code: String?) -> RemoteSecretApproval.Request {
            .init(action: .enroll, enrollmentCode: code, signingKey: signing.publicKey.x963Representation,
                  agreementKey: agreement.publicKey.x963Representation)
        }

        func approve(_ pending: RemoteSecretApproval.Pending) throws -> RemoteSecretApproval.Request {
            let secret = try RemoteSecretEnvelope.open(pending.envelope, as: agreement.publicKey) {
                try agreement.sharedSecretFromKeyAgreement(with: $0)
            }
            return .init(action: .approve, requestID: pending.id,
                         signature: try signing.signature(for: pending.signingData()).derRepresentation,
                         secret: secret)
        }
    }

    private let device = "phone-device"
    private let share = "owner-share"
    private let secret = Data("test secret, opened only by the enrolled phone".utf8)
    private let clock = Clock()
    private var enabled = true

    private func makeBroker(store: MemoryStore = MemoryStore()) -> SecretApprovalBroker {
        let clock = clock
        let enabled = enabled
        return SecretApprovalBroker(store: store, now: { clock.now() }, isEnabled: { enabled })
    }

    private func handle(_ broker: SecretApprovalBroker, _ request: RemoteSecretApproval.Request,
                        device: String? = nil, share: String? = nil) async throws -> RemoteSecretApproval.Response {
        try await broker.handle(request, device: device ?? self.device, share: share ?? self.share) { true }
    }

    private func enrolled(_ broker: SecretApprovalBroker, _ phone: Phone) async throws {
        let code = try await broker.beginEnrollment()
        _ = try await handle(broker, phone.enroll(code))
    }

    /// Starts an unwrap and waits until the phone can see it.
    private func ask(_ broker: SecretApprovalBroker, envelope: RemoteSecretApproval.Envelope,
                     title: String = "Approve grant kv-1a2b3c4d") async throws -> (Task<Data, Error>, RemoteSecretApproval.Pending) {
        let task = Task {
            try await broker.unwrap(client: "keyvault", title: title, lines: ["AuthKey_ABCDE12345.p8"],
                                    requester: "nc<keyvault<claude<zsh", envelope: envelope)
        }
        for _ in 0..<200 {
            if let pending = try await handle(broker, .init(action: .pending)).pending { return (task, pending) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("the request never reached the phone")
        throw SecretApprovalBroker.Failure.malformed
    }

    // MARK: - Tests

    func testTheWholeFlowHandsTheOpenedSecretToTheClientOnce() async throws {
        let broker = makeBroker()
        let phone = Phone()
        try await enrolled(broker, phone)
        let envelope = try await broker.wrap(secret)
        let (waiting, pending) = try await ask(broker, envelope: envelope)
        XCTAssertEqual(pending.requester, "nc<keyvault<claude<zsh")
        XCTAssertEqual(pending.lines, ["AuthKey_ABCDE12345.p8"])
        let approval = try phone.approve(pending)
        let receipt = try await handle(broker, approval)
        XCTAssertEqual(receipt.receipt, pending.id)
        let opened = try await waiting.value
        XCTAssertEqual(opened, secret)
        do {
            _ = try await handle(broker, approval)
            XCTFail("an approval must never be used twice")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .approvalRefused)
        }
        let after = try await handle(broker, .init(action: .pending))
        XCTAssertNil(after.pending)
    }

    /// The phone hears about a request the moment it exists, for the grant it enrolled with, and
    /// the alert is told nothing the phone could not already see.
    func testEachRequestIsAnnouncedForTheEnrolledGrant() async throws {
        final class Heard: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(UUID, String, String)] = []
            func add(_ item: (UUID, String, String)) { lock.withLock { items.append(item) } }
            var all: [(UUID, String, String)] { lock.withLock { items } }
        }
        let heard = Heard()
        let broker = makeBroker()
        await broker.observeRequests { request, shareID in heard.add((request.id, request.deviceID, shareID)) }
        let phone = Phone()
        try await enrolled(broker, phone)
        let (waiting, pending) = try await ask(broker, envelope: try await broker.wrap(secret))
        XCTAssertEqual(heard.all.count, 1)
        XCTAssertEqual(heard.all.first?.0, pending.id)
        XCTAssertEqual(heard.all.first?.1, device)
        XCTAssertEqual(heard.all.first?.2, share)
        _ = try await handle(broker, .init(action: .deny, requestID: pending.id))
        _ = try? await waiting.value
        // A refused request (another one waiting) is not announced.
        let (second, _) = try await ask(broker, envelope: try await broker.wrap(secret))
        do {
            _ = try await broker.unwrap(client: "keyvault", title: "t", lines: [], requester: "r",
                                        envelope: try await broker.wrap(secret))
            XCTFail("a second request must be refused while one waits")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .busy)
        }
        XCTAssertEqual(heard.all.count, 2)
        try await broker.forgetDevice()
        _ = try? await second.value
    }

    func testTheStatusSaysWhenTheRequestAndTheCodeRunOut() async throws {
        let broker = makeBroker()
        let phone = Phone()
        _ = try await broker.beginEnrollment()
        let coding = await broker.status()
        XCTAssertEqual(coding.enrollmentExpiresAt, clock.now().addingTimeInterval(RemoteSecretApproval.enrollmentLifetime))
        try await enrolled(broker, phone)
        let enrolledStatus = await broker.status()
        XCTAssertNil(enrolledStatus.enrollmentExpiresAt)
        let (waiting, pending) = try await ask(broker, envelope: try await broker.wrap(secret))
        let status = await broker.status()
        XCTAssertEqual(status.pendingTitle, pending.title)
        XCTAssertEqual(status.pendingExpiresAt, Date(timeIntervalSince1970: TimeInterval(pending.expiresAt)))
        clock.advance(TimeInterval(RemoteSecretApproval.approvalLifetime))
        let expiredStatus = await broker.status()
        XCTAssertNil(expiredStatus.pendingTitle, "the page must not show a request that has run out")
        do {
            _ = try await waiting.value
            XCTFail("an expired request must end its wait")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .expired)
        }
    }

    func testTheMacCannotOpenWhatItSeals() async throws {
        let broker = makeBroker()
        let phone = Phone()
        try await enrolled(broker, phone)
        let envelope = try await broker.wrap(secret)
        XCTAssertEqual(envelope.recipient, phone.agreement.publicKey.x963Representation)
        let otherKey = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try RemoteSecretEnvelope.open(envelope, as: otherKey.publicKey) {
            try otherKey.sharedSecretFromKeyAgreement(with: $0)
        })
        XCTAssertNil(try JSONEncoder().encode(envelope).range(of: secret))
    }

    func testAForgedSignatureIsRefusedAndTheRequestKeepsWaitingUntilDenied() async throws {
        let broker = makeBroker()
        let phone = Phone()
        try await enrolled(broker, phone)
        let (waiting, pending) = try await ask(broker, envelope: try await broker.wrap(secret))
        let impostor = Phone()
        let forged = RemoteSecretApproval.Request(
            action: .approve, requestID: pending.id,
            signature: try impostor.signing.signature(for: pending.signingData()).derRepresentation, secret: secret)
        do {
            _ = try await handle(broker, forged)
            XCTFail("a signature from another key must be refused")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .approvalRefused)
        }
        _ = try await handle(broker, .init(action: .deny, requestID: pending.id))
        do {
            _ = try await waiting.value
            XCTFail("a denied request must not return a secret")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .denied)
        }
    }

    func testAnExpiredRequestCannotBeApproved() async throws {
        let broker = makeBroker()
        let phone = Phone()
        try await enrolled(broker, phone)
        let (waiting, pending) = try await ask(broker, envelope: try await broker.wrap(secret))
        clock.advance(TimeInterval(RemoteSecretApproval.approvalLifetime))
        do {
            _ = try await handle(broker, try phone.approve(pending))
            XCTFail("an expired request must not be approved")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .approvalRefused)
        }
        do {
            _ = try await waiting.value
            XCTFail("the client must learn that the request expired")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .expired)
        }
    }

    func testOnlyTheEnrolledDeviceAndGrantMaySeeOrAnswer() async throws {
        let broker = makeBroker()
        let phone = Phone()
        try await enrolled(broker, phone)
        let (waiting, pending) = try await ask(broker, envelope: try await broker.wrap(secret))
        for (otherDevice, otherShare) in [("other-device", share), (device, "other-share")] {
            do {
                _ = try await handle(broker, .init(action: .pending), device: otherDevice, share: otherShare)
                XCTFail("another device or grant must not see the request")
            } catch {
                XCTAssertEqual(error as? SecretApprovalBroker.Failure, .wrongDevice)
            }
        }
        _ = try await handle(broker, .init(action: .deny, requestID: pending.id))
        _ = try? await waiting.value
    }

    func testEnrollmentNeedsTheCurrentCodeWithinItsAttemptsAndLifetime() async throws {
        let broker = makeBroker()
        let phone = Phone()
        do {
            _ = try await handle(broker, phone.enroll("00000000"))
            XCTFail("no enrollment without a code shown on the Mac")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .enrollmentRefused)
        }
        let code = try await broker.beginEnrollment()
        for _ in 0..<RemoteSecretApproval.maximumEnrollmentAttempts {
            _ = try? await handle(broker, phone.enroll("wrong"))
        }
        do {
            _ = try await handle(broker, phone.enroll(code))
            XCTFail("the right code after five wrong ones must still be refused")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .enrollmentRefused)
        }
        let fresh = try await broker.beginEnrollment()
        clock.advance(RemoteSecretApproval.enrollmentLifetime)
        do {
            _ = try await handle(broker, phone.enroll(fresh))
            XCTFail("an expired code must be refused")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .enrollmentRefused)
        }
        let status = await broker.status()
        XCTAssertNil(status.enrollment)
    }

    func testOneRequestAtATimeAndAnEnvelopeForAnotherPhoneIsRefused() async throws {
        let broker = makeBroker()
        let phone = Phone()
        try await enrolled(broker, phone)
        let envelope = try await broker.wrap(secret)
        let (waiting, pending) = try await ask(broker, envelope: envelope)
        do {
            _ = try await broker.unwrap(client: "keyvault", title: "second", lines: [], requester: "r", envelope: envelope)
            XCTFail("a second request must not queue behind a person's decision")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .busy)
        }
        _ = try await handle(broker, .init(action: .deny, requestID: pending.id))
        _ = try? await waiting.value
        let foreign = try RemoteSecretEnvelope.seal(secret, to: P256.KeyAgreement.PrivateKey().publicKey)
        do {
            _ = try await broker.unwrap(client: "keyvault", title: "t", lines: [], requester: "r", envelope: foreign)
            XCTFail("an envelope sealed to another key must be refused")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .wrongDevice)
        }
    }

    func testForgettingThePhoneRefusesWhatWasWaiting() async throws {
        let broker = makeBroker()
        let phone = Phone()
        try await enrolled(broker, phone)
        let (waiting, _) = try await ask(broker, envelope: try await broker.wrap(secret))
        try await broker.forgetDevice()
        do {
            _ = try await waiting.value
            XCTFail("forgetting the phone must refuse the pending request")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .wrongDevice)
        }
        let status = await broker.status()
        XCTAssertNil(status.enrollment)
    }

    func testNothingWorksWhileTheMacSwitchIsOff() async throws {
        enabled = false
        let broker = makeBroker()
        do {
            _ = try await broker.beginEnrollment()
            XCTFail("enrollment must need the Mac's switch")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .disabled)
        }
        do {
            _ = try await broker.wrap(secret)
            XCTFail("sealing must need the Mac's switch")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .disabled)
        }
        do {
            _ = try await handle(broker, .init(action: .pending))
            XCTFail("the phone must get nothing while the switch is off")
        } catch {
            XCTAssertEqual(error as? SecretApprovalBroker.Failure, .disabled)
        }
    }

    func testTheSettingIsOffByDefaultAndNeverRemotelyMutable() {
        let definition = AppSettingDefinitions.secretApprovalsEnabled.definition
        XCTAssertEqual(definition.remotePolicy, .catalogueOnly)
        let defaults = UserDefaults(suiteName: "SecretApprovalBrokerTests.\(UUID().uuidString)")!
        XCTAssertFalse(AppSettingDefinitions.secretApprovalsEnabled.read(from: defaults) ?? false)
    }

    // MARK: - Local socket

    func testTheLocalSocketAnswersStatusAndSealsWithoutEverOpening() async throws {
        let broker = makeBroker()
        let phone = Phone()
        try await enrolled(broker, phone)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sa-\(UUID().uuidString.prefix(8))")
        let path = directory.appendingPathComponent("a.sock").path
        let server = SecretApprovalLocalServer(path: path, broker: broker)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, SecretApprovalLocalDefaults.directoryPermissions)

        let status = try JSONSerialization.jsonObject(with: try Self.exchange(path, #"{"op":"status"}"#)) as? [String: Any]
        XCTAssertEqual(status?["ok"] as? Bool, true)
        XCTAssertEqual(status?["enrolled"] as? Bool, true)

        let request = try JSONSerialization.data(withJSONObject: ["op": "wrap", "secret": secret.base64EncodedString()])
        let reply = try Self.exchange(path, String(decoding: request, as: UTF8.self))
        XCTAssertNil(reply.range(of: secret))
        let wrapped = try JSONDecoder().decode(Wrapped.self, from: reply)
        let opened = try RemoteSecretEnvelope.open(wrapped.envelope, as: phone.agreement.publicKey) {
            try phone.agreement.sharedSecretFromKeyAgreement(with: $0)
        }
        XCTAssertEqual(opened, secret)

        let garbage = try JSONSerialization.jsonObject(with: try Self.exchange(path, "not json")) as? [String: Any]
        XCTAssertEqual(garbage?["error"] as? String, "malformed")
    }

    func testTheRequesterIsTheKernelsAccountOfTheCaller() {
        let chain = SecretApprovalLocalServer.requester(startingAt: getpid())
        XCTAssertFalse(chain.isEmpty)
        XCTAssertNotEqual(chain, "?")
        XCTAssertLessThanOrEqual(chain.utf8.count, RemoteSecretApproval.maximumRequesterBytes)
    }

    private struct Wrapped: Decodable { let envelope: RemoteSecretApproval.Envelope }

    private static func exchange(_ path: String, _ line: String) throws -> Data {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EIO) }
        defer { close(socket) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let bytes = Array((line + "\n").utf8)
        _ = write(socket, bytes, bytes.count)
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(socket, &chunk, chunk.count)
            guard count > 0 else { break }
            reply.append(contentsOf: chunk[0..<count])
        }
        return reply
    }
}
