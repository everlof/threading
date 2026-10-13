import AppKit
import XCTest
@testable import Threading

/// Opt-in: a real project's scenarios on real devices, through the shipping workspace, panes and
/// controls. Ordinary suites skip it. Give it a checkout with `.threading/scenarios.json`, one
/// scenario with steps whose app is installed on the devices, and the devices, already booted:
///
///     TEST_RUNNER_THREADING_SCENARIO_CHECKOUT=/path/to/app \
///     TEST_RUNNER_THREADING_SCENARIO_ID=live-match-journey \
///     TEST_RUNNER_THREADING_SCENARIO_DEVICES=<iOS UDID>,android-avd:<name> \
///     TEST_RUNNER_THREADING_SCENARIO_OUT=/tmp/scenario-live \
///     scripts/test.sh fast -only-testing:ThreadingTests/SimulatorScenarioLiveIntegrationTests
@MainActor
final class SimulatorScenarioLiveIntegrationTests: XCTestCase {
    func testAProjectsFlowStepsInPlaceOnEveryDevice() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let checkoutPath = environment["THREADING_SCENARIO_CHECKOUT"],
              let scenarioID = environment["THREADING_SCENARIO_ID"],
              let outputPath = environment["THREADING_SCENARIO_OUT"] else {
            throw XCTSkip("Set THREADING_SCENARIO_CHECKOUT, _ID, _DEVICES and _OUT to run against real devices.")
        }
        let devices = (environment["THREADING_SCENARIO_DEVICES"] ?? "").split(separator: ",")
            .compactMap { SimulatorDeviceID(String($0)) }
        XCTAssertFalse(devices.isEmpty)
        let checkout = URL(fileURLWithPath: checkoutPath, isDirectory: true)
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let catalog = SimulatorScenarioLoader.load(repositoryRoot: checkout)
        XCTAssertEqual(catalog.diagnostics, [], "the project's file reads without problems")
        let scenario = try XCTUnwrap(catalog.scenario(id: scenarioID))
        XCTAssertGreaterThanOrEqual(scenario.steps.count, 3)

        let control = PlatformRoutingSimulatorControl.shared
        let pane = DisplayPaneController(simulatorControl: control)
        pane.simulatorScenarioCheckout = { _ in checkout }
        let session = SessionID()
        defer {
            for tab in pane.tabs(for: session) { _ = pane.closeTab(id: tab.id, for: session) }
            DisplayPaneStore.shared.removeSession(session)
        }
        for device in devices { _ = try pane.activateSimulator(for: session, deviceID: device) }
        let workspace = try XCTUnwrap(pane.simulatorWorkspace(for: session))
        // Adopt each device the way simulator_prepare does; a pane nobody shows prepares on request.
        for member in workspace.simulators {
            member.prepareForAgent(deviceID: member.selectedDeviceID) { _ in }
        }
        try await waitUntil(seconds: 60) { workspace.simulators.allSatisfy { $0.adoptedDevice != nil } }
        XCTAssertEqual(Set(workspace.simulators.compactMap(\.adoptedDevice?.id)), Set(devices))

        let opened = try await workspace.scenarios.open(scenarioID)
        XCTAssertEqual(Set(opened.devices), Set(devices), "every device opened it: \(opened.failures)")
        XCTAssertEqual(opened.failures, [])
        try await Task.sleep(for: .seconds(4))
        let processes = try await processIDs(devices, catalog: catalog)
        var previous = try await capture(devices, control: control, output: output, name: "step-0")

        let last = scenario.steps.count - 1
        for step in Array(1...last) + [2, 0, last] {
            let outcome = try await workspace.scenarios.go(to: step)
            XCTAssertEqual(outcome.failures, [], "step \(step)")
            try await Task.sleep(for: .seconds(3))
            let frames = try await capture(devices, control: control, output: output, name: "step-\(step)")
            for device in devices where frames[device] == previous[device] {
                XCTFail("\(device) did not change for step \(step)")
            }
            previous = frames
        }
        let after = try await processIDs(devices, catalog: catalog)
        XCTAssertEqual(after, processes, "every step reached the running app; none started it again")
    }

    // MARK: - Helpers

    private func capture(
        _ devices: [SimulatorDeviceID], control: any SimulatorControlling, output: URL, name: String
    ) async throws -> [SimulatorDeviceID: Data] {
        var frames: [SimulatorDeviceID: Data] = [:]
        for device in devices {
            let png = try await control.screenshot(of: device)
            let platform = device.platform.isAndroid ? "android" : "ios"
            try png.write(to: output.appendingPathComponent("\(name)-\(platform).png"))
            frames[device] = png
        }
        return frames
    }

    /// The app's process on each device, so a relaunch shows as a new one.
    private func processIDs(
        _ devices: [SimulatorDeviceID], catalog: SimulatorScenarioCatalog
    ) async throws -> [SimulatorDeviceID: String] {
        var result: [SimulatorDeviceID: String] = [:]
        for device in devices {
            let arguments: [String]
            if device.platform.isAndroid {
                let sdk = try XCTUnwrap(AndroidSDK.locate())
                let serial = try await AndroidDeviceControl.shared?.target(for: device).serial ?? ""
                arguments = [sdk.adb.path, "-s", serial, "shell", "pidof", try XCTUnwrap(catalog.apps.android?.package)]
            } else {
                arguments = ["/usr/bin/xcrun", "simctl", "spawn", device.rawValue, "launchctl", "list"]
            }
            let text = try run(arguments)
            if device.platform.isAndroid {
                result[device] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let bundle = try XCTUnwrap(catalog.apps.iOS?.bundleIdentifier)
                result[device] = text.split(whereSeparator: \.isNewline)
                    .first { $0.contains("UIKitApplication:\(bundle)[") }
                    .map { String($0.split(whereSeparator: \.isWhitespace).first ?? "") }
            }
            XCTAssertFalse(result[device]?.isEmpty ?? true, "the app runs on \(device)")
        }
        return result
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertTrue(condition())
    }
}
