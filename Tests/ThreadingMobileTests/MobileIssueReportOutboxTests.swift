import XCTest
@testable import ThreadingMobile

final class MobileIssueReportOutboxTests: XCTestCase {
    func testConnectivityRetryMonitorFollowsForegroundLifetime() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mobile-issue-outbox-\(UUID().uuidString)",
            isDirectory: true
        )
        let outbox = MobileIssueReportOutbox(
            directory: directory,
            endpoint: URL(string: "https://example.invalid/v1/reports")!
        )

        await outbox.setConnectivityRetryActive(true)
        let active = await outbox.connectivityRetryIsActive
        XCTAssertTrue(active)

        await outbox.setConnectivityRetryActive(false)
        let inactive = await outbox.connectivityRetryIsActive
        XCTAssertFalse(inactive)

        try? FileManager.default.removeItem(at: directory)
    }
}
