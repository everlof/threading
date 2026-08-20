import XCTest
@testable import Threading

@MainActor
final class SimulatorAgentToolTests: XCTestCase {
    func testSimulatorGroupTellsAgentsToPreferTheAdoptedPanel() throws {
        let group = MCPToolCatalog.simulator

        XCTAssertEqual(group.id, "simulator")
        XCTAssertEqual(group.tools.map(\.name), MCPTools.simulatorTools)
        XCTAssertEqual(group.tools.compactMap(\.builtInTool), [
            .simulatorPrepare,
            .simulatorInstallLaunch,
            .simulatorScreenshot,
        ])
        XCTAssertTrue(group.instruction.contains("prefer Threading's adopted Simulator"))
        XCTAssertTrue(group.instruction.contains("Do not run open -a Simulator"))
        XCTAssertTrue(group.instruction.contains("-destination id=<device_id>"))

        let install = try XCTUnwrap(MCPTools.definition(for: .simulatorInstallLaunch))
        XCTAssertEqual(install.inputSchema.required, ["application_path", "bundle_identifier"])
        XCTAssertEqual(install.annotations?.destructiveHint, true)
        XCTAssertEqual(
            MCPTools.definition(for: .simulatorScreenshot)?.annotations?.readOnlyHint,
            true
        )
    }

    func testPrepareCreatesOneVisibleSimulatorTabAndReturnsBuildDestination() async throws {
        let fixture = makeFixture(visible: true)
        defer { fixture.cleanup() }

        let result = await execute(
            .simulatorPrepare(SimulatorPrepareArguments(deviceID: nil)),
            with: fixture.coordinator,
            sessionID: fixture.sessionID
        )

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains(#""surface" : "Threading right panel""#))
        XCTAssertTrue(result.text.contains(simulatorAgentTestDevice.id.rawValue))
        XCTAssertTrue(result.text.contains(
            "platform=iOS Simulator,id=\(simulatorAgentTestDevice.id.rawValue)"
        ))
        XCTAssertTrue(fixture.paneWasRevealed())
        XCTAssertEqual(fixture.pane.tabs(for: fixture.sessionID).count, 1)
        XCTAssertNotNil(fixture.pane.tabs(for: fixture.sessionID).first?.simulator)

        let listed = fixture.coordinator.panelListTabs(for: fixture.sessionID)
        XCTAssertTrue(listed.text.contains(#""kind" : "simulator""#))
        let counts = await fixture.control.snapshot()
        XCTAssertEqual(counts.prepares, 1)
    }

    func testInvalidDeviceIDFailsBeforeCreatingAPanelTab() async {
        let fixture = makeFixture(visible: false)
        defer { fixture.cleanup() }

        let result = await execute(
            .simulatorPrepare(SimulatorPrepareArguments(deviceID: "not-a-uuid")),
            with: fixture.coordinator,
            sessionID: fixture.sessionID
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("exact CoreSimulator device UUID"))
        XCTAssertTrue(fixture.pane.tabs(for: fixture.sessionID).isEmpty)
    }

    func testPrepareInstallLaunchAndScreenshotShareTheAdoptedDevice() async throws {
        let fixture = makeFixture(visible: false)
        defer { fixture.cleanup() }
        let applicationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SimulatorAgentToolTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let applicationURL = applicationRoot.appendingPathComponent(
            "Example.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: applicationRoot) }

        let prepare = await execute(
            .simulatorPrepare(SimulatorPrepareArguments(
                deviceID: simulatorAgentTestDevice.id.rawValue.lowercased()
            )),
            with: fixture.coordinator,
            sessionID: fixture.sessionID
        )
        XCTAssertFalse(prepare.isError, prepare.text)

        let launch = await execute(
            .simulatorInstallLaunch(SimulatorInstallLaunchArguments(
                applicationPath: applicationURL.path,
                bundleIdentifier: "codes.threading.Example",
                arguments: ["-uitesting", "YES"]
            )),
            with: fixture.coordinator,
            sessionID: fixture.sessionID
        )
        XCTAssertFalse(launch.isError, launch.text)
        XCTAssertTrue(launch.text.contains(#""process_identifier" : 4242"#))

        let screenshot = await execute(
            .simulatorScreenshot(SimulatorScreenshotArguments(includeImage: true)),
            with: fixture.coordinator,
            sessionID: fixture.sessionID
        )
        XCTAssertFalse(screenshot.isError, screenshot.text)
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(screenshot)
        ) as? [String: Any]
        let content = try XCTUnwrap(encoded?["content"] as? [[String: Any]])
        XCTAssertEqual(content.compactMap { $0["type"] as? String }, ["text", "image"])

        let snapshot = await fixture.control.snapshot()
        XCTAssertEqual(snapshot.prepares, 1)
        XCTAssertEqual(snapshot.launch?.deviceID, simulatorAgentTestDevice.id)
        XCTAssertEqual(snapshot.launch?.applicationURL, applicationURL)
        XCTAssertEqual(snapshot.launch?.bundleIdentifier, "codes.threading.Example")
        XCTAssertEqual(snapshot.launch?.arguments, ["-uitesting", "YES"])
        XCTAssertEqual(snapshot.screenshots, 1)
        XCTAssertEqual(
            fixture.pane.tabs(for: fixture.sessionID).filter { $0.simulator != nil }.count,
            1
        )
    }

    func testInstallRefusesToInventADeviceLease() async throws {
        let fixture = makeFixture(visible: false)
        defer { fixture.cleanup() }
        let applicationURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Unprepared.app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: applicationURL) }

        let result = await execute(
            .simulatorInstallLaunch(SimulatorInstallLaunchArguments(
                applicationPath: applicationURL.path,
                bundleIdentifier: "codes.threading.Unprepared",
                arguments: nil
            )),
            with: fixture.coordinator,
            sessionID: fixture.sessionID
        )

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Call simulator_prepare before installing an app.")
        let snapshot = await fixture.control.snapshot()
        XCTAssertNil(snapshot.launch)
    }

    private func execute(
        _ command: AgentCommand,
        with coordinator: AgentToolCoordinator,
        sessionID: SessionID
    ) async -> MCPToolResult {
        await withCheckedContinuation { continuation in
            coordinator.handle(command, for: sessionID) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func makeFixture(visible: Bool) -> SimulatorAgentFixture {
        let sessionID = SessionID()
        let control = SimulatorAgentControlFake()
        let pane = DisplayPaneController(simulatorControl: control)
        var paneVisible = false
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { visible ? sessionID : nil },
            setPaneVisible: { paneVisible = $0 },
            windowProvider: { nil }
        )
        return SimulatorAgentFixture(
            sessionID: sessionID,
            control: control,
            pane: pane,
            coordinator: coordinator,
            paneWasRevealed: { paneVisible }
        )
    }
}

@MainActor
private struct SimulatorAgentFixture {
    let sessionID: SessionID
    let control: SimulatorAgentControlFake
    let pane: DisplayPaneController
    let coordinator: AgentToolCoordinator
    let paneWasRevealed: () -> Bool

    func cleanup() {
        for tab in pane.tabs(for: sessionID) {
            _ = pane.closeTab(id: tab.id, for: sessionID)
        }
        DisplayPaneStore.shared.removeSession(sessionID)
    }
}

private let simulatorAgentTestDevice = SimulatorDevice(
    id: SimulatorDeviceID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
    name: "iPhone 17 Pro",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    runtimeName: "iOS 26.5",
    deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    family: .iPhone,
    state: .booted,
    lastBootedAt: nil
)

private actor SimulatorAgentControlFake: SimulatorControlling {
    struct Launch: Sendable {
        let applicationURL: URL
        let bundleIdentifier: String
        let deviceID: SimulatorDeviceID
        let arguments: [String]
    }

    struct Snapshot: Sendable {
        var prepares = 0
        var launch: Launch?
        var screenshots = 0
    }

    private var state = Snapshot()

    func snapshot() -> Snapshot { state }

    func availableDevices() async throws -> [SimulatorDevice] {
        [simulatorAgentTestDevice]
    }

    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        if let deviceID, deviceID != simulatorAgentTestDevice.id {
            throw SimulatorControlError.deviceNotFound(deviceID)
        }
        state.prepares += 1
        return SimulatorDeviceLease(device: simulatorAgentTestDevice, bootOwnership: .user)
    }

    func installAndLaunch(
        applicationURL: URL,
        bundleIdentifier: String,
        on deviceID: SimulatorDeviceID,
        arguments: [String]
    ) async throws -> SimulatorLaunchReceipt {
        state.launch = Launch(
            applicationURL: applicationURL,
            bundleIdentifier: bundleIdentifier,
            deviceID: deviceID,
            arguments: arguments
        )
        return SimulatorLaunchReceipt(
            deviceID: deviceID,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: 4242
        )
    }

    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data {
        state.screenshots += 1
        return Data(base64Encoded: Self.onePixelPNG)!
    }

    func release(_ lease: SimulatorDeviceLease) async throws {}

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/"
        + "ScLhWQAAAABJRU5ErkJggg=="
}
