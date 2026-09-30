import Foundation
import XCTest
@testable import Threading

@MainActor
final class Pymobiledevice3SettingsSurfaceTests: XCTestCase {
    func testSetupDestinationResolvesToTheActualToolingSettingsRow() {
        let controller = AdvancedPreferencesViewController(iphoneTooling:
            Pymobiledevice3SettingsSurface(initialState: .absent, automaticallyRefreshes: false)
        )
        XCTAssertNotNil(SettingsRowAnchor.locate(
            title: AdvancedStrings.iphoneToolingTitle,
            in: controller.view
        ))
    }

    func testOnlyASuccessfulInstallPublishesTheRetryEvent() async throws {
        let center = NotificationCenter()
        let observations = AppEventObservations(center: center)
        var notifications = 0
        observations.observe(Pymobiledevice3ToolDidInstall.self) { _ in notifications += 1 }
        let tool = Pymobiledevice3InstalledTool(
            version: "11.13.1",
            executable: URL(fileURLWithPath: "/test/pymobiledevice3")
        )
        let success = Pymobiledevice3SettingsSurface(
            initialState: .absent,
            readStatus: { .absent },
            install: { tool },
            notificationCenter: center
        )
        success.installLatest()
        success.installLatest()
        try await eventually { !success.state.isWorking }
        XCTAssertEqual(notifications, 1, "Repeated presses cannot start duplicate installations")
        XCTAssertEqual(success.state.installedTool, tool)

        let failure = Pymobiledevice3SettingsSurface(
            initialState: .absent,
            readStatus: { .absent },
            install: { throw Pymobiledevice3InstallError.unsupportedVersion },
            notificationCenter: center
        )
        failure.installLatest()
        try await eventually { !failure.state.isWorking }
        XCTAssertEqual(notifications, 1, "A failed installation must not trigger device retries")
        guard case .failed = failure.state else { return XCTFail("Expected installation failure") }

        success.refresh()
        try await eventually { !success.state.isWorking }
        XCTAssertEqual(notifications, 1, "Inspecting Settings never triggers device work")
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else { return XCTFail("State did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
