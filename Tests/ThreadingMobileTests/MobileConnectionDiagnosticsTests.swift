import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

@MainActor
final class MobileConnectionDiagnosticsTests: XCTestCase {

    private enum RaceFixtureError: Error, Equatable {
        case privateRoute
        case hostedRoute
    }

    private actor CancellationFlag {
        private(set) var wasCancelled = false

        func markCancelled() {
            wasCancelled = true
        }
    }

    override func setUp() {
        super.setUp()
        MobileConnectionStateLog.reset()
    }

    override func tearDown() {
        MobileConnectionStateLog.reset()
        super.tearDown()
    }

    // MARK: - Reachability history

    func testTheHistoryKeepsTransitionsRatherThanOneSnapshot() {
        let base = Date(timeIntervalSince1970: 1_000)
        MobileConnectionStateLog.record("idle", at: base)
        MobileConnectionStateLog.record("connecting", at: base.addingTimeInterval(2))
        MobileConnectionStateLog.record("online", at: base.addingTimeInterval(5))
        MobileConnectionStateLog.record("offline", at: base.addingTimeInterval(9))

        XCTAssertEqual(
            MobileConnectionStateLog.summary(now: base.addingTimeInterval(10)),
            "idle-10:connecting-8:online-5:offline-1"
        )
    }

    func testRepeatedStatesDoNotFillTheRing() {
        let base = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<50 {
            MobileConnectionStateLog.record("connecting", at: base.addingTimeInterval(Double(offset)))
        }

        XCTAssertEqual(
            MobileConnectionStateLog.summary(now: base.addingTimeInterval(50)),
            "connecting-50"
        )
    }

    /// Constant size is the point: a report header field is bounded, and a process that has been
    /// running for a week must not push a longer value into it than one launched a minute ago.
    func testTheRingIsBoundedAndItsValueFitsTheReportField() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let states = ["idle", "connecting", "online", "offline"]
        for offset in 0..<200 {
            MobileConnectionStateLog.record(
                states[offset % states.count],
                at: base.addingTimeInterval(Double(offset))
            )
        }

        let value = try XCTUnwrap(
            MobileConnectionStateLog.summary(now: base.addingTimeInterval(200))
        )
        XCTAssertEqual(value.split(separator: ":").count, MobileConnectionStateLog.capacity)
        XCTAssertLessThanOrEqual(value.utf8.count, 160)
    }

    func testAgesAreClampedSoOneOldEntryCannotWidenTheValue() {
        let base = Date(timeIntervalSince1970: 0)
        MobileConnectionStateLog.record("idle", at: base)

        XCTAssertEqual(
            MobileConnectionStateLog.summary(now: base.addingTimeInterval(10_000_000)),
            "idle-\(MobileConnectionStateLog.maximumAgeSeconds)"
        )
    }

    func testAnEmptyRingHasNoSummaryRatherThanAMisleadingOne() {
        XCTAssertNil(MobileConnectionStateLog.summary())
    }

    // MARK: - Origin hashing

    func testTheOriginDigestIdentifiesAnAddressWithoutNamingIt() {
        let address = URL(string: "https://192.168.1.42:8760")!
        let digest = MobileDiagnostics.originDigest(address)

        XCTAssertTrue(digest.hasPrefix("origin-"))
        XCTAssertFalse(digest.contains("192.168"))
        XCTAssertFalse(digest.contains("8760"))
        XCTAssertEqual(digest, MobileDiagnostics.originDigest(address))
    }

    /// The fragment of a pairing URL is a bearer. A digest that included it would be a hash of a
    /// credential rather than of an address.
    func testTheDigestIgnoresPathAndFragmentAndSeparatesRealAddresses() {
        let plain = URL(string: "https://192.168.1.42:8760")!
        let decorated = URL(string: "https://192.168.1.42:8760/api/me#SECRET")!
        let other = URL(string: "https://192.168.1.43:8760")!
        let otherPort = URL(string: "https://192.168.1.42:8761")!

        XCTAssertEqual(
            MobileDiagnostics.originDigest(plain),
            MobileDiagnostics.originDigest(decorated)
        )
        XCTAssertNotEqual(
            MobileDiagnostics.originDigest(plain),
            MobileDiagnostics.originDigest(other)
        )
        XCTAssertNotEqual(
            MobileDiagnostics.originDigest(plain),
            MobileDiagnostics.originDigest(otherPort)
        )
    }

    /// The shared upload policy must keep accepting what this client now sends, and must keep
    /// refusing an address smuggled through the same field.
    func testTheSharedPolicyAcceptsAHashedOriginAndRefusesARawAddress() {
        let hashed = record(origin: MobileDiagnostics.originDigest(
            URL(string: "https://192.168.1.42:8760")!
        ))
        let raw = record(origin: "192.168.1.42:8760")

        XCTAssertTrue(RemoteDiagnosticUploadPolicy.accepts(hashed))
        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(raw))
    }

    func testTheSharedPolicyAcceptsConnectivityLifecycleFields() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let request = RemoteDiagnosticUploadRequestDTO(
            source: .iOSClient,
            records: [RemoteDiagnosticRecord(
                timestamp: formatter.string(from: Date()),
                source: .iOSClient,
                level: .warning,
                event: .hostRouteEnded,
                fields: [
                    RemoteDiagnosticField.trace.rawValue: UUID().uuidString.lowercased(),
                    RemoteDiagnosticField.transport.rawValue: "hosted",
                    RemoteDiagnosticField.phase.rawValue: "hosted.awaitingHost",
                    RemoteDiagnosticField.result.rawValue: "failed",
                    RemoteDiagnosticField.durationMS.rawValue: "15017",
                    RemoteDiagnosticField.timeoutMS.rawValue: "15000",
                    RemoteDiagnosticField.attempt.rawValue: "1",
                    RemoteDiagnosticField.total.rawValue: "2",
                    RemoteDiagnosticField.code.rawValue: "url.-1001",
                ]
            )]
        )

        XCTAssertTrue(RemoteDiagnosticUploadPolicy.accepts(request))
    }

    func testTheSharedPolicyRefusesNonNumericConnectivityMeasurements() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let request = RemoteDiagnosticUploadRequestDTO(
            source: .iOSClient,
            records: [RemoteDiagnosticRecord(
                timestamp: formatter.string(from: Date()),
                source: .iOSClient,
                level: .warning,
                event: .hostRouteEnded,
                fields: [RemoteDiagnosticField.durationMS.rawValue: "fifteen-seconds"]
            )]
        )

        XCTAssertFalse(RemoteDiagnosticUploadPolicy.accepts(request))
    }

    // MARK: - First-success route racing

    func testTheFirstSuccessfulRouteWinsAndCancelsTheLoser() async throws {
        let cancellation = CancellationFlag()
        let winner: FirstSuccessfulTaskRace.Winner<String> = try await
            FirstSuccessfulTaskRace.run([
                .init(id: "private", failurePriority: 0) {
                    try await Task.sleep(for: .milliseconds(20))
                    return "lan"
                },
                .init(id: "hosted", failurePriority: 1) {
                    try await withTaskCancellationHandler {
                        try await Task.sleep(for: .seconds(5))
                        return "hosted"
                    } onCancel: {
                        Task { await cancellation.markCancelled() }
                    }
                },
            ])

        XCTAssertEqual(winner.id, "private")
        XCTAssertEqual(winner.value, "lan")
        for _ in 0..<20 {
            if await cancellation.wasCancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let loserWasCancelled = await cancellation.wasCancelled
        XCTAssertTrue(loserWasCancelled)
    }

    func testAnEarlyRouteFailureDoesNotSuppressASlowerSuccess() async throws {
        let winner: FirstSuccessfulTaskRace.Winner<String> = try await
            FirstSuccessfulTaskRace.run([
                .init(id: "hosted", failurePriority: 1) {
                    throw RaceFixtureError.hostedRoute
                },
                .init(id: "private", failurePriority: 0) {
                    try await Task.sleep(for: .milliseconds(20))
                    return "lan"
                },
            ])

        XCTAssertEqual(winner.id, "private")
        XCTAssertEqual(winner.value, "lan")
    }

    func testAllRouteFailuresChooseTheStablePreferredError() async {
        do {
            let _: FirstSuccessfulTaskRace.Winner<String> = try await
                FirstSuccessfulTaskRace.run([
                    .init(id: "hosted", failurePriority: 1) {
                        throw RaceFixtureError.hostedRoute
                    },
                    .init(id: "private", failurePriority: 0) {
                        try await Task.sleep(for: .milliseconds(20))
                        throw RaceFixtureError.privateRoute
                    },
                ])
            XCTFail("Every route should have failed.")
        } catch {
            XCTAssertEqual(error as? RaceFixtureError, .privateRoute)
        }
    }

    private func record(origin: String) -> RemoteDiagnosticUploadRequestDTO {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return RemoteDiagnosticUploadRequestDTO(
            source: .iOSClient,
            records: [RemoteDiagnosticRecord(
                timestamp: formatter.string(from: Date()),
                source: .iOSClient,
                level: .error,
                event: .socketFailed,
                fields: [
                    RemoteDiagnosticField.origin.rawValue: origin,
                    RemoteDiagnosticField.transport.rawValue: "relay",
                ]
            )]
        )
    }
}
