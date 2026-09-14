import AppKit
import ThreadingSimulatorKit
import XCTest
@testable import Threading

/// Opt-in end-to-end proof of the workflow agents are told to prefer.
///
/// Unlike the direct transport integration test, this enters through `AgentToolCoordinator` and
/// exercises prepare, install/launch, inspection, consent and input against the one Simulator tab
/// in Threading's right panel. The harness provides an already-booted device and a built iOS app;
/// cleanup never shuts the device down or opens Simulator.app.
@MainActor
final class SimulatorAgentDogfoodIntegrationTests: HostedStoreTestCase {
    func testAgentBuildLaunchInspectAndControlStayInTheRightPanel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawDeviceID = environment["THREADING_SIMULATOR_INTEGRATION_UDID"],
              !rawDeviceID.isEmpty,
              let applicationPath = environment["THREADING_SIMULATOR_DOGFOOD_APP_PATH"],
              !applicationPath.isEmpty,
              let bundleIdentifier = environment["THREADING_SIMULATOR_DOGFOOD_BUNDLE_ID"],
              !bundleIdentifier.isEmpty else {
            throw XCTSkip(
                "Set the Simulator UDID, dogfood app path, and dogfood bundle identifier."
            )
        }
        let deviceID = try XCTUnwrap(SimulatorDeviceID(rawDeviceID))
        let applicationURL = URL(fileURLWithPath: applicationPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: applicationURL.path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(applicationURL.pathExtension.lowercased(), "app")

        let control = SimctlSimulatorControl()
        let authorizer = SimulatorDogfoodInputAuthorizer()
        let sessionID = SessionID()
        let pane = DisplayPaneController(
            simulatorControl: control,
            simulatorStreamCoordinator: SimulatorLiveStreamCoordinator(maximumStreams: 1),
            simulatorInputAuthorizer: authorizer
        )
        var paneVisible = false
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { sessionID },
            setPaneVisible: { paneVisible = $0 },
            windowProvider: { nil },
            activateApp: {}
        )
        _ = pane.view
        pane.showSession(sessionID)
        defer {
            for tab in pane.tabs(for: sessionID) {
                _ = pane.closeTab(id: tab.id, for: sessionID)
            }
            DisplayPaneStore.shared.removeSession(sessionID)
        }

        let prepare = await execute(
            .simulatorPrepare(SimulatorPrepareArguments(deviceID: deviceID.rawValue)),
            coordinator: coordinator,
            sessionID: sessionID
        )
        XCTAssertFalse(prepare.isError, prepare.text)
        XCTAssertTrue(prepare.text.contains(#""surface" : "Threading right panel""#))
        XCTAssertTrue(prepare.text.contains(#""boot_ownership" : "user""#))
        XCTAssertTrue(prepare.text.contains(
            "platform=iOS Simulator,id=\(deviceID.rawValue)"
        ))

        let launch = await execute(
            .simulatorInstallLaunch(SimulatorInstallLaunchArguments(
                applicationPath: applicationURL.path,
                bundleIdentifier: bundleIdentifier,
                arguments: ["-ThreadingSimulatorDogfood", "YES"]
            )),
            coordinator: coordinator,
            sessionID: sessionID
        )
        XCTAssertFalse(launch.isError, launch.text)
        XCTAssertTrue(launch.text.contains(bundleIdentifier))

        let screenshot = await execute(
            .simulatorScreenshot(SimulatorScreenshotArguments(includeImage: false, ref: nil, role: nil, label: nil, identifier: nil)),
            coordinator: coordinator,
            sessionID: sessionID
        )
        XCTAssertFalse(screenshot.isError, screenshot.text)
        XCTAssertTrue(screenshot.text.contains(deviceID.rawValue))

        let tap = await execute(
            .simulatorTap(SimulatorTapArguments(x: 0.5, y: 0.5, ref: nil, role: nil, label: nil, identifier: nil)),
            coordinator: coordinator,
            sessionID: sessionID
        )
        XCTAssertFalse(tap.isError, tap.text)
        XCTAssertTrue(tap.text.contains(#""surface" : "Threading right panel""#))

        let home = await execute(
            .simulatorPressButton(SimulatorPressButtonArguments(button: "home")),
            coordinator: coordinator,
            sessionID: sessionID
        )
        XCTAssertFalse(home.isError, home.text)
        XCTAssertTrue(home.text.contains(#""surface" : "Threading right panel""#))

        XCTAssertTrue(paneVisible)
        XCTAssertEqual(pane.tabs(for: sessionID).filter { $0.simulator != nil }.count, 1)
        XCTAssertEqual(pane.tabs(for: sessionID).first?.simulator?.selectedDeviceID, deviceID)
        guard let finalBackend = pane.tabs(for: sessionID).first?
            .simulator?.liveBackendForTesting,
              case .direct = finalBackend else {
            return XCTFail("The agent workflow did not finish on the direct adopted transport.")
        }
        XCTAssertEqual(authorizer.authorizedDeviceIDs, [deviceID])
    }

    private func execute(
        _ command: AgentCommand,
        coordinator: AgentToolCoordinator,
        sessionID: SessionID
    ) async -> MCPToolResult {
        await withCheckedContinuation { continuation in
            coordinator.handle(command, for: sessionID) { result in
                continuation.resume(returning: result)
            }
        }
    }
}

@MainActor
private final class SimulatorDogfoodInputAuthorizer: SimulatorInputAuthorizing {
    private(set) var authorizedDeviceIDs: [SimulatorDeviceID] = []

    func authorize(
        device: SimulatorDevice,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        if !authorizedDeviceIDs.contains(device.id) {
            authorizedDeviceIDs.append(device.id)
        }
        completion(true)
    }
}
