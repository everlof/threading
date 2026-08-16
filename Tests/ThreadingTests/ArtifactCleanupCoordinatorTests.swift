import XCTest
@testable import Threading

@MainActor
final class ArtifactCleanupCoordinatorTests: XCTestCase {

    func testCleanupIsSingleFlightAndPublishesBoundedProgress() async {
        let center = NotificationCenter()
        let observations = AppEventObservations(center: center)
        var progress: [ArtifactCleanupProgress] = []
        observations.observe(ArtifactCleanupDidChange.self) { event in
            progress.append(event.progress)
        }

        let first = artifact(named: "first", bytes: 3_000)
        let second = artifact(named: "second", bytes: 7_000)
        let coordinator = ArtifactCleanupCoordinator(
            removeArtifact: { artifact in
                artifact.url.lastPathComponent == "first" ? .removed : .refused
            },
            recoverPersistence: { .restored },
            notificationCenter: center
        )
        let completed = expectation(description: "cleanup completed")
        var outcome: ArtifactCleanupOutcome?

        XCTAssertTrue(coordinator.remove([first, second]) { result in
            outcome = result
            completed.fulfill()
        })
        XCTAssertFalse(
            coordinator.remove([first]) { _ in
                XCTFail("a concurrent cleanup must not start")
            }
        )

        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(outcome?.removed, [first])
        XCTAssertEqual(outcome?.refusedCount, 1)
        XCTAssertEqual(outcome?.failedCount, 0)
        XCTAssertEqual(outcome?.reclaimedBytes, 3_000)
        XCTAssertEqual(outcome?.persistenceRecovery, .restored)
        XCTAssertEqual(progress.first?.fraction, 0)
        XCTAssertTrue(progress.allSatisfy { 0...1 ~= $0.fraction })
        XCTAssertEqual(progress.last?.phase, .completed)
        XCTAssertEqual(progress.last?.fraction, 1)
        XCTAssertEqual(progress.last?.persistenceRecovery, .restored)
        XCTAssertFalse(coordinator.isRunning)
    }

    func testDuplicatePathsAreRemovedOnce() async {
        let artifact = artifact(named: "same", bytes: 5)
        let coordinator = ArtifactCleanupCoordinator(
            removeArtifact: { _ in .removed },
            recoverPersistence: { .notNeeded }
        )
        let completed = expectation(description: "cleanup completed")
        var outcome: ArtifactCleanupOutcome?

        XCTAssertTrue(coordinator.remove([artifact, artifact]) { result in
            outcome = result
            completed.fulfill()
        })
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(outcome?.requestedCount, 1)
        XCTAssertEqual(outcome?.removed, [artifact])
    }

    private func artifact(named name: String, bytes: Int64) -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true),
            kind: .rust,
            byteCount: bytes,
            modifiedAt: nil,
            checkoutPath: "/tmp/project"
        )
    }
}
