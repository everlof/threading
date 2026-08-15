import XCTest
@testable import Threading

@MainActor
final class BrowserDownloadCoordinatorTests: XCTestCase {
    func testAgentRequestOwnsApprovedDestinationUntilCompletion() async throws {
        var prepared: [URL] = []
        let coordinator = BrowserDownloadCoordinator { prepared.append($0) }
        let request = try XCTUnwrap(coordinator.beginAgentRequest())
        let download = DownloadIdentity()
        let downloadID = BrowserDownloadID(download)

        coordinator.attachPendingAgentRequest(to: downloadID)
        XCTAssertTrue(request.isAttached)
        XCTAssertTrue(coordinator.isAgentRequested(downloadID))

        let destination = URL(fileURLWithPath: "/tmp/threading-download")
        XCTAssertEqual(
            coordinator.decideDestination(destination, for: downloadID),
            .approved(destination)
        )
        XCTAssertEqual(prepared, [destination])
        XCTAssertEqual(coordinator.finish(downloadID), .completed(destination))
        let result = await request.wait()
        XCTAssertEqual(result, .success(destination))
        XCTAssertEqual(coordinator.recentDownloads, [destination])
    }

    func testOnlyOneAgentRequestCanWaitForAWebKitDownload() throws {
        let coordinator = BrowserDownloadCoordinator()
        let first = try XCTUnwrap(coordinator.beginAgentRequest())

        XCTAssertNil(coordinator.beginAgentRequest())

        coordinator.endAgentRequest(first)
        XCTAssertNotNil(coordinator.beginAgentRequest())
    }

    func testCancellingDestinationCompletesAgentRequestWithoutHistory() async throws {
        let coordinator = BrowserDownloadCoordinator()
        let request = try XCTUnwrap(coordinator.beginAgentRequest())
        let downloadID = BrowserDownloadID(DownloadIdentity())
        coordinator.attachPendingAgentRequest(to: downloadID)

        XCTAssertEqual(coordinator.decideDestination(nil, for: downloadID), .cancelled)
        let result = await request.wait()
        XCTAssertEqual(
            result,
            .failure("The user cancelled the native download save panel.")
        )
        XCTAssertTrue(coordinator.recentDownloads.isEmpty)
    }

    func testDestinationPreparationFailureCompletesAgentRequest() async throws {
        let failure = CocoaError(.fileWriteNoPermission)
        let coordinator = BrowserDownloadCoordinator { _ in throw failure }
        let request = try XCTUnwrap(coordinator.beginAgentRequest())
        let downloadID = BrowserDownloadID(DownloadIdentity())
        coordinator.attachPendingAgentRequest(to: downloadID)

        guard case .rejected(let message) = coordinator.decideDestination(
            URL(fileURLWithPath: "/denied"),
            for: downloadID
        ) else {
            return XCTFail("Expected destination rejection")
        }
        XCTAssertEqual(message, failure.localizedDescription)
        let result = await request.wait()
        XCTAssertEqual(
            result,
            .failure(
                "Could not use the user-approved download destination: "
                    + failure.localizedDescription
            )
        )
    }

    func testRecentDownloadHistoryIsRuntimeBounded() {
        let coordinator = BrowserDownloadCoordinator(prepareDestination: { _ in })
        let downloads = (0...BrowserDownloadCoordinator.maximumRecentDownloads).map { _ in
            DownloadIdentity()
        }

        for (index, download) in downloads.enumerated() {
            let downloadID = BrowserDownloadID(download)
            let destination = URL(fileURLWithPath: "/tmp/download-\(index)")
            XCTAssertEqual(
                coordinator.decideDestination(destination, for: downloadID),
                .approved(destination)
            )
            XCTAssertEqual(coordinator.finish(downloadID), .completed(destination))
        }

        XCTAssertEqual(
            coordinator.recentDownloads.count,
            BrowserDownloadCoordinator.maximumRecentDownloads
        )
        XCTAssertEqual(coordinator.recentDownloads.first?.lastPathComponent, "download-1")
        XCTAssertEqual(
            coordinator.recentDownloads.last?.lastPathComponent,
            "download-\(BrowserDownloadCoordinator.maximumRecentDownloads)"
        )
    }
}

private final class DownloadIdentity {}
