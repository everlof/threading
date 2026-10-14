import AppKit
import ThreadingSimulatorKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorAgentToolTests: HostedStoreTestCase {
    func testSimulatorGroupTellsAgentsToPreferTheAdoptedPanel() throws {
        let group = MCPToolCatalog.simulator

        XCTAssertEqual(group.id, "simulator")
        XCTAssertEqual(group.tools.map(\.name), MCPTools.simulatorTools)
        XCTAssertEqual(group.tools.compactMap(\.builtInTool), [
            .simulatorPrepare,
            .simulatorInstallLaunch,
            .simulatorScreenshot,
            .simulatorSnapshot,
            .simulatorAnnotations,
            .simulatorWait,
            .simulatorTap,
            .simulatorSwipe,
            .simulatorTypeText,
            .simulatorPressButton,
            .simulatorScenario,
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
        XCTAssertTrue(result.text.contains("exact device id"), result.text)
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
            .simulatorScreenshot(SimulatorScreenshotArguments(includeImage: true, ref: nil, role: nil, label: nil, identifier: nil)),
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

    func testInputToolsUseTheAdoptedDirectStream() async throws {
        let fixture = makeFixture(visible: true)
        defer { fixture.cleanup() }

        let prepare = await execute(
            .simulatorPrepare(SimulatorPrepareArguments(deviceID: nil)),
            with: fixture.coordinator,
            sessionID: fixture.sessionID
        )
        XCTAssertFalse(prepare.isError, prepare.text)

        let results = [
            await execute(
                .simulatorTap(SimulatorTapArguments(x: 0.25, y: 0.75, ref: nil, role: nil, label: nil, identifier: nil)),
                with: fixture.coordinator,
                sessionID: fixture.sessionID
            ),
            await execute(
                .simulatorSwipe(SimulatorSwipeArguments(
                    fromX: 0.1,
                    fromY: 0.2,
                    toX: 0.8,
                    toY: 0.9,
                    durationMilliseconds: 450
                )),
                with: fixture.coordinator,
                sessionID: fixture.sessionID
            ),
            await execute(
                .simulatorTypeText(SimulatorTypeTextArguments(text: "Hello!\n", ref: nil, role: nil, label: nil, identifier: nil)),
                with: fixture.coordinator,
                sessionID: fixture.sessionID
            ),
            await execute(
                .simulatorPressButton(SimulatorPressButtonArguments(button: "home")),
                with: fixture.coordinator,
                sessionID: fixture.sessionID
            ),
        ]

        for result in results {
            XCTAssertFalse(result.isError, result.text)
            XCTAssertTrue(result.text.contains(#""surface" : "Threading right panel""#))
        }
        XCTAssertEqual(fixture.stream.session.inputs, [
            .tap(x: 0.25, y: 0.75),
            .drag(
                fromX: 0.1,
                fromY: 0.2,
                toX: 0.8,
                toY: 0.9,
                durationMilliseconds: 450
            ),
            .text("Hello!\n"),
            .button(.home),
        ])
        XCTAssertEqual(fixture.authorizer.authorizedDeviceIDs, [simulatorAgentTestDevice.id])
    }

    func testInputValidationFailsBeforeControlAuthorityIsRequested() async {
        let fixture = makeFixture(visible: true)
        defer { fixture.cleanup() }

        let results = [
            await execute(
                .simulatorTap(SimulatorTapArguments(x: -0.01, y: 0.5, ref: nil, role: nil, label: nil, identifier: nil)),
                with: fixture.coordinator,
                sessionID: fixture.sessionID
            ),
            await execute(
                .simulatorSwipe(SimulatorSwipeArguments(
                    fromX: 0,
                    fromY: 0,
                    toX: 1,
                    toY: 1,
                    durationMilliseconds: 99
                )),
                with: fixture.coordinator,
                sessionID: fixture.sessionID
            ),
            await execute(
                .simulatorTypeText(SimulatorTypeTextArguments(text: "nul\u{0}", ref: nil, role: nil, label: nil, identifier: nil)),
                with: fixture.coordinator,
                sessionID: fixture.sessionID
            ),
            await execute(
                .simulatorPressButton(SimulatorPressButtonArguments(button: "volume-up")),
                with: fixture.coordinator,
                sessionID: fixture.sessionID
            ),
        ]

        XCTAssertTrue(results.allSatisfy(\.isError))
        XCTAssertTrue(fixture.pane.tabs(for: fixture.sessionID).isEmpty)
        XCTAssertTrue(fixture.authorizer.authorizedDeviceIDs.isEmpty)
        XCTAssertTrue(fixture.stream.session.inputs.isEmpty)
    }

    func testNamingAnotherDeviceTakesTheLoneDevicesPlaceAndSaysSo() async throws {
        let fixture = makeFixture(visible: true, multipleDevices: true)
        defer { fixture.cleanup() }
        let first = await execute(.simulatorPrepare(SimulatorPrepareArguments(deviceID: simulatorAgentTestDevice.id.rawValue)),
                                  with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertFalse(first.isError, first.text)
        let second = await execute(.simulatorPrepare(SimulatorPrepareArguments(deviceID: simulatorAgentSecondDevice.id.rawValue)),
                                   with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertFalse(second.isError, second.text)
        XCTAssertTrue(second.text.contains("\"removed\"") && second.text.contains(simulatorAgentTestDevice.id.rawValue),
                      second.text)
        let workspace = try XCTUnwrap(fixture.pane.simulatorWorkspace(for: fixture.sessionID))
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [simulatorAgentSecondDevice.id],
                       "one device shown, not two")
    }

    func testMultipleDevicesRefuseAmbiguousInputAndTargetTheExactHelper() async throws {
        let fixture = makeFixture(visible: true, multipleDevices: true)
        defer { fixture.cleanup() }
        let pair = [simulatorAgentTestDevice.id.rawValue, simulatorAgentSecondDevice.id.rawValue]
        let prepared = await execute(.simulatorPrepare(SimulatorPrepareArguments(deviceID: nil, devices: pair)),
                                     with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertFalse(prepared.isError, prepared.text)
        XCTAssertTrue(prepared.text.contains("\"added\""), prepared.text)
        for repeated in [SimulatorPrepareArguments(deviceID: nil, devices: pair),
                         SimulatorPrepareArguments(deviceID: simulatorAgentSecondDevice.id.rawValue)] {
            let again = await execute(.simulatorPrepare(repeated), with: fixture.coordinator, sessionID: fixture.sessionID)
            XCTAssertFalse(again.isError, again.text)
            XCTAssertFalse(again.text.contains("\"added\"") || again.text.contains("\"removed\""),
                           "asking for what is already shown changes nothing: \(again.text)")
        }
        let workspace = try XCTUnwrap(fixture.pane.simulatorWorkspace(for: fixture.sessionID))
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), pair.compactMap(SimulatorDeviceID.init))
        let ambiguous = await execute(.simulatorTap(SimulatorTapArguments(x: 0.25, y: 0.75, ref: nil, role: nil, label: nil, identifier: nil)),
                                      with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.text.contains("device_id"))
        XCTAssertTrue(fixture.authorizer.authorizedDeviceIDs.isEmpty)
        let firstID = try XCTUnwrap(workspace.state.members.first?.id)
        workspace.select(firstID)
        let tap = SimulatorTapArguments(x: 0.25, y: 0.75, ref: nil, role: nil, label: nil, identifier: nil,
                                       deviceID: simulatorAgentSecondDevice.id.rawValue)
        let result = await execute(.simulatorTap(tap), with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains(simulatorAgentSecondDevice.id.rawValue))
        let firstInputs = await fixture.stream.inputs(for: simulatorAgentTestDevice.id)
        let secondInputs = await fixture.stream.inputs(for: simulatorAgentSecondDevice.id)
        XCTAssertEqual(firstInputs, [])
        XCTAssertEqual(secondInputs, [.tap(x: 0.25, y: 0.75)])
        XCTAssertEqual(fixture.authorizer.authorizedDeviceIDs, [simulatorAgentSecondDevice.id])
        let invalid = await execute(.simulatorPressButton(SimulatorPressButtonArguments(button: "home", deviceID: UUID().uuidString)),
                                    with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertTrue(invalid.isError)
        let unchangedInputs = await fixture.stream.inputs(for: simulatorAgentSecondDevice.id)
        XCTAssertEqual(unchangedInputs, secondInputs)
    }

    func testScenarioToolListsOpensAndStepsTheCheckoutsScenarios() async throws {
        let fixture = makeFixture(visible: false)
        defer { fixture.cleanup() }
        let checkout = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenario-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".threading"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkout) }
        fixture.pane.simulatorScenarioCheckout = { _ in checkout }

        let early = await execute(.simulatorScenario(SimulatorScenarioArguments(scenario: nil, step: nil)),
                                  with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertTrue(early.isError)
        XCTAssertTrue(early.text.contains("simulator_prepare"), early.text)

        _ = await execute(.simulatorPrepare(SimulatorPrepareArguments(deviceID: nil)),
                          with: fixture.coordinator, sessionID: fixture.sessionID)
        let missing = await execute(.simulatorScenario(SimulatorScenarioArguments(scenario: nil, step: nil)),
                                    with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains(".threading/scenarios.json"), missing.text)

        try Data(SimulatorScenarioGuide.example.utf8).write(to: checkout.appendingPathComponent(".threading/scenarios.json"))
        let listed = await execute(.simulatorScenario(SimulatorScenarioArguments(scenario: nil, step: nil)),
                                   with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertFalse(listed.isError, listed.text)
        XCTAssertTrue(listed.text.contains(#""id" : "order/delivery""#), listed.text)
        XCTAssertTrue(listed.text.contains(#""device_platforms" : ["#), listed.text)

        let opened = await execute(.simulatorScenario(SimulatorScenarioArguments(scenario: "order/delivery", step: 2)),
                                   with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertFalse(opened.isError, opened.text)
        XCTAssertTrue(opened.text.contains(#""step_title" : "Courier on the way""#), opened.text)
        let stepped = await execute(.simulatorScenario(SimulatorScenarioArguments(scenario: nil, step: 3)),
                                    with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertFalse(stepped.isError, stepped.text)
        let state = await fixture.control.snapshot()
        XCTAssertEqual(state.appLaunches, [.iOS(bundleIdentifier: "com.example.shop", arguments: ["-scene", "order", "-step", "0"])])
        XCTAssertEqual(state.links.map(\.url.absoluteString), ["exampleshop://debug/step?n=2", "exampleshop://debug/step?n=3"])

        let unknown = await execute(.simulatorScenario(SimulatorScenarioArguments(scenario: "nope", step: nil)),
                                    with: fixture.coordinator, sessionID: fixture.sessionID)
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.text.contains("nope"), unknown.text)
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

    private func makeFixture(visible: Bool, multipleDevices: Bool = false) -> SimulatorAgentFixture {
        let sessionID = SessionID()
        let control = SimulatorAgentControlFake(multipleDevices: multipleDevices)
        let stream = SimulatorAgentStreamCoordinatorFake()
        let authorizer = SimulatorAgentInputAuthorizerFake()
        let pane = DisplayPaneController(
            simulatorControl: control,
            simulatorStreamCoordinator: stream,
            simulatorInputAuthorizer: authorizer
        )
        var paneVisible = false
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { visible ? sessionID : nil },
            setPaneVisible: { paneVisible = $0 },
            windowProvider: { nil }
        )
        if visible {
            _ = pane.view
            pane.showSession(sessionID)
        }
        return SimulatorAgentFixture(
            sessionID: sessionID,
            control: control,
            stream: stream,
            authorizer: authorizer,
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
    let stream: SimulatorAgentStreamCoordinatorFake
    let authorizer: SimulatorAgentInputAuthorizerFake
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

private let simulatorAgentSecondDevice = SimulatorDevice(
    id: SimulatorDeviceID("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!, name: "iPhone SE",
    runtimeIdentifier: simulatorAgentTestDevice.runtimeIdentifier, runtimeName: simulatorAgentTestDevice.runtimeName,
    deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-SE", family: .iPhone,
    state: .booted, lastBootedAt: nil
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
        var appLaunches: [SimulatorAppLaunch] = []
        var links: [SimulatorAppLink] = []
    }

    private var state = Snapshot()
    private let multipleDevices: Bool
    init(multipleDevices: Bool = false) { self.multipleDevices = multipleDevices }

    func snapshot() -> Snapshot { state }

    func availableDevices() async throws -> [SimulatorDevice] {
        multipleDevices ? [simulatorAgentTestDevice, simulatorAgentSecondDevice] : [simulatorAgentTestDevice]
    }

    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        let device = deviceID == simulatorAgentSecondDevice.id && multipleDevices ? simulatorAgentSecondDevice : simulatorAgentTestDevice
        if let deviceID, deviceID != device.id { throw SimulatorControlError.deviceNotFound(deviceID) }
        state.prepares += 1
        return SimulatorDeviceLease(device: device, bootOwnership: .user)
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

    func launchApp(_ launch: SimulatorAppLaunch, on deviceID: SimulatorDeviceID) async throws -> SimulatorLaunchReceipt {
        state.appLaunches.append(launch)
        return SimulatorLaunchReceipt(deviceID: deviceID, bundleIdentifier: "com.example.shop", processIdentifier: 7)
    }

    func openAppLink(_ link: SimulatorAppLink, on deviceID: SimulatorDeviceID) async throws {
        state.links.append(link)
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/"
        + "ScLhWQAAAABJRU5ErkJggg=="
}

private actor SimulatorAgentStreamCoordinatorFake: SimulatorLiveStreamCoordinating {
    nonisolated let session = SimulatorAgentStreamSessionFake()
    private var sessions: [SimulatorDeviceID: SimulatorAgentStreamSessionFake] = [:]

    func inputs(for device: SimulatorDeviceID) -> [SimulatorBridgeInput] { sessions[device]?.inputs ?? [] }

    func openStream(
        for deviceID: SimulatorDeviceID
    ) async throws -> any SimulatorLiveStreamSession {
        if let existing = sessions[deviceID] { return existing }
        let created = sessions.isEmpty ? session : SimulatorAgentStreamSessionFake()
        sessions[deviceID] = created
        return created
    }
}

private final class SimulatorAgentStreamSessionFake: SimulatorLiveStreamSession, @unchecked Sendable {
    let events: AsyncStream<SimulatorLiveStreamEvent>

    private let lock = NSLock()
    private var recordedInputs: [SimulatorBridgeInput] = []

    init() {
        let pair = AsyncStream<SimulatorLiveStreamEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        events = pair.stream
        pair.continuation.yield(.ready(
            backend: .direct(codec: .h264),
            capabilities: SimulatorBridgeCapabilities(
                codecs: [.h264, .jpeg],
                supportsTouch: true,
                supportsKeyboard: true,
                supportsButtons: true,
                maximumFramesPerSecond: 60
            ),
            coreSimulatorVersion: "1065",
            simulatorKitVersion: "1065"
        ))
    }

    var inputs: [SimulatorBridgeInput] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInputs
    }

    func setVisible(_ visible: Bool) {}

    func sendInput(_ input: SimulatorBridgeInput) async throws {
        lock.withLock { recordedInputs.append(input) }
    }

    func stop() {}
}

@MainActor
private final class SimulatorAgentInputAuthorizerFake: SimulatorInputAuthorizing {
    private(set) var authorizedDeviceIDs: [SimulatorDeviceID] = []
    private var decisions: Set<SimulatorDeviceID> = []

    func authorize(
        device: SimulatorDevice,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        if decisions.insert(device.id).inserted {
            authorizedDeviceIDs.append(device.id)
        }
        completion(true)
    }
}
