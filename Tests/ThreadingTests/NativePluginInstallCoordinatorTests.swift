import Foundation
import XCTest
@testable import Threading

final class NativePluginInstallCoordinatorTests: XCTestCase {
    func testConcurrentRequestsShareOneActivationAndLaterRequestCanRetry() async throws {
        let coordinator = InstallCoordinator()
        let key = InstallCoordinator.Key(
            directoryPath: "/tmp/plugins",
            bundleIdentifier: "codes.threading.plugin.devicelogs",
            archiveSHA256: String(repeating: "a", count: 64)
        )
        let counter = InvocationCounter()
        let destination = URL(fileURLWithPath: "/tmp/plugins/DeviceLogsPlugin.bundle")

        async let first = coordinator.run(key: key) {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return destination
        }
        async let second = coordinator.run(key: key) {
            await counter.increment()
            return destination
        }
        let firstResult = try await first
        let secondResult = try await second
        XCTAssertEqual([firstResult, secondResult], [destination, destination])
        let sharedCount = await counter.value
        XCTAssertEqual(sharedCount, 1)

        let repeated = try await coordinator.run(key: key) {
            await counter.increment()
            return destination
        }
        XCTAssertEqual(repeated, destination)
        let retryCount = await counter.value
        XCTAssertEqual(retryCount, 2)
    }
}

private actor InvocationCounter {
    private var count = 0

    var value: Int { count }

    func increment() { count += 1 }
}
