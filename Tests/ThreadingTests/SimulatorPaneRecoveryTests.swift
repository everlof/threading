import AppKit
import Foundation
import ThreadingSimulatorKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorPaneRecoveryTests: XCTestCase {
    func testHelperCrashFallsBackInsideTheAdoptedPane() async throws {
        let session = SimulatorRecoveryStreamSessionFake()
        let coordinator = SimulatorRecoveryStreamCoordinatorFake([.success(session)])
        let control = SimulatorRecoveryControlFake()
        let controller = makeController(control: control, coordinator: coordinator)
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually { controller.liveBackendForTesting == .direct(codec: .h264) }

        session.emit(.failed("The signed helper exited unexpectedly."))

        try await eventually {
            if case .screenshotFallback = controller.liveBackendForTesting { return true }
            return false
        }
        try await eventually { await control.screenshotCount > 0 }
        XCTAssertEqual(controller.selectedDeviceID, simulatorRecoveryFirstDevice.id)
        XCTAssertTrue(controller.isPresentedForTesting)
    }

    func testSwitchingDeviceStopsOldTransportAndIgnoresItsLateFailure() async throws {
        let firstSession = SimulatorRecoveryStreamSessionFake()
        let secondSession = SimulatorRecoveryStreamSessionFake()
        let coordinator = SimulatorRecoveryStreamCoordinatorFake([
            .success(firstSession),
            .success(secondSession),
        ])
        let control = SimulatorRecoveryControlFake()
        let controller = makeController(control: control, coordinator: coordinator)
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually { controller.liveBackendForTesting == .direct(codec: .h264) }
        controller.selectDevice(simulatorRecoverySecondDevice.id)

        try await eventually {
            controller.selectedDeviceID == simulatorRecoverySecondDevice.id
                && controller.liveBackendForTesting == .direct(codec: .h264)
        }
        XCTAssertTrue(firstSession.didStop)

        firstSession.emit(.failed("late failure from the old device"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.selectedDeviceID, simulatorRecoverySecondDevice.id)
        XCTAssertEqual(controller.liveBackendForTesting, .direct(codec: .h264))
        let requestedDevices = await coordinator.requestedDeviceIDs
        XCTAssertEqual(requestedDevices, [
            simulatorRecoveryFirstDevice.id,
            simulatorRecoverySecondDevice.id,
        ])
    }

    func testXcodeCompatibilityFailureFallsBackAndRetryReconnectsDirectly() async throws {
        let recoveredSession = SimulatorRecoveryStreamSessionFake()
        let coordinator = SimulatorRecoveryStreamCoordinatorFake([
            .failure(.refused(
                .apiUnavailable,
                "The selected Xcode does not expose the required Simulator API."
            )),
            .success(recoveredSession),
        ])
        let control = SimulatorRecoveryControlFake()
        let controller = makeController(control: control, coordinator: coordinator)
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually {
            if case .screenshotFallback = controller.liveBackendForTesting { return true }
            return false
        }

        controller.retryForTesting()

        try await eventually { controller.liveBackendForTesting == .direct(codec: .h264) }
        let openCount = await coordinator.openCount
        let prepareCount = await control.prepareCount
        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(prepareCount, 1)
    }

    func testInputReconnectsDirectTransportAfterFallback() async throws {
        let failedSession = SimulatorRecoveryStreamSessionFake()
        let recoveredSession = SimulatorRecoveryStreamSessionFake()
        let coordinator = SimulatorRecoveryStreamCoordinatorFake([
            .success(failedSession),
            .success(recoveredSession),
        ])
        let control = SimulatorRecoveryControlFake()
        let controller = makeController(control: control, coordinator: coordinator)
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually { controller.liveBackendForTesting == .direct(codec: .h264) }
        failedSession.emit(.failed("The install replaced the active framebuffer connection."))
        try await eventually {
            if case .screenshotFallback = controller.liveBackendForTesting { return true }
            return false
        }

        let result: SimulatorPaneAgentResult<Void> = await withCheckedContinuation {
            continuation in
            controller.sendInputForAgent(.button(.home)) {
                continuation.resume(returning: $0)
            }
        }

        guard case .success = result else {
            return XCTFail("Input did not recover the adopted direct transport.")
        }
        XCTAssertEqual(recoveredSession.inputs, [.button(.home)])
        XCTAssertEqual(controller.liveBackendForTesting, .direct(codec: .h264))
        let openCount = await coordinator.openCount
        XCTAssertEqual(openCount, 2)
    }

    func testAgentInstallQuiescesDirectTransportAndReconnectsAfterMutation() async throws {
        let firstSession = SimulatorRecoveryStreamSessionFake()
        let recoveredSession = SimulatorRecoveryStreamSessionFake()
        let coordinator = SimulatorRecoveryStreamCoordinatorFake([
            .success(firstSession),
            .success(recoveredSession),
        ])
        let control = SimulatorRecoveryControlFake(
            transportStoppedProbe: { firstSession.didStop }
        )
        let controller = makeController(control: control, coordinator: coordinator)
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually { controller.liveBackendForTesting == .direct(codec: .h264) }

        let result: SimulatorPaneAgentResult<SimulatorLaunchReceipt> =
            await withCheckedContinuation { continuation in
                controller.installAndLaunchForAgent(
                    applicationURL: URL(fileURLWithPath: "/tmp/Dogfood.app"),
                    bundleIdentifier: "codes.threading.dogfood",
                    arguments: []
                ) {
                    continuation.resume(returning: $0)
                }
            }

        guard case .success = result else {
            return XCTFail("The mutation did not complete through the adopted pane.")
        }
        let installObservedTransportStopped = await control.installObservedTransportStopped
        XCTAssertEqual(installObservedTransportStopped, true)
        XCTAssertTrue(firstSession.didStop)
        try await eventually { controller.liveBackendForTesting == .direct(codec: .h264) }
        let installOpenCount = await coordinator.openCount
        XCTAssertEqual(installOpenCount, 2)
    }

    func testAgentScreenshotQuiescesDirectTransportAndReconnectsAfterCapture() async throws {
        let firstSession = SimulatorRecoveryStreamSessionFake()
        let recoveredSession = SimulatorRecoveryStreamSessionFake()
        let coordinator = SimulatorRecoveryStreamCoordinatorFake([
            .success(firstSession),
            .success(recoveredSession),
        ])
        let control = SimulatorRecoveryControlFake(
            transportStoppedProbe: { firstSession.didStop }
        )
        let controller = makeController(control: control, coordinator: coordinator)
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually { controller.liveBackendForTesting == .direct(codec: .h264) }

        let result: SimulatorPaneAgentResult<SimulatorPaneScreenshot> =
            await withCheckedContinuation { continuation in
                controller.screenshotForAgent {
                    continuation.resume(returning: $0)
                }
            }

        guard case .success = result else {
            return XCTFail("The capture did not complete through the adopted pane.")
        }
        let screenshotObservedTransportStopped = await control.screenshotObservedTransportStopped
        XCTAssertEqual(screenshotObservedTransportStopped, true)
        XCTAssertTrue(firstSession.didStop)
        try await eventually { controller.liveBackendForTesting == .direct(codec: .h264) }
        let screenshotOpenCount = await coordinator.openCount
        XCTAssertEqual(screenshotOpenCount, 2)
    }

    func testStoppedDeviceFailureRefreshesLeaseBeforeRetryingTransport() async throws {
        let failedSession = SimulatorRecoveryStreamSessionFake()
        let recoveredSession = SimulatorRecoveryStreamSessionFake()
        let coordinator = SimulatorRecoveryStreamCoordinatorFake([
            .success(failedSession),
            .success(recoveredSession),
        ])
        let control = SimulatorRecoveryControlFake(screenshotFailures: 1)
        let controller = makeController(control: control, coordinator: coordinator)
        _ = controller.view
        defer { controller.terminate() }

        controller.setPresented(true)
        try await eventually { controller.liveBackendForTesting == .direct(codec: .h264) }
        failedSession.emit(.failed("The helper lost the device framebuffer."))
        try await eventually {
            if case .failed = controller.presentationState { return true }
            return false
        }

        controller.retryForTesting()

        try await eventually { controller.liveBackendForTesting == .direct(codec: .h264) }
        XCTAssertEqual(controller.selectedDeviceID, simulatorRecoveryFirstDevice.id)
        let prepareCount = await control.prepareCount
        let openCount = await coordinator.openCount
        XCTAssertEqual(prepareCount, 2)
        XCTAssertEqual(openCount, 2)
    }

    private func makeController(
        control: SimulatorRecoveryControlFake,
        coordinator: SimulatorRecoveryStreamCoordinatorFake
    ) -> SimulatorPaneViewController {
        SimulatorPaneViewController(
            preferredDeviceID: simulatorRecoveryFirstDevice.id,
            control: control,
            leaseManager: SimulatorLeaseManager(
                control: control,
                releaseGraceNanoseconds: 1_000_000
            ),
            streamCoordinator: coordinator,
            inputAuthorizer: SimulatorRecoveryInputAuthorizerFake()
        )
    }

    private func eventually(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for Simulator recovery state.")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func eventually(
        timeout: TimeInterval = 3,
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline {
                XCTFail("Timed out waiting for async Simulator recovery state.")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private actor SimulatorRecoveryStreamCoordinatorFake: SimulatorLiveStreamCoordinating {
    private var results: [Result<SimulatorRecoveryStreamSessionFake, SimulatorLiveStreamError>]
    private(set) var requestedDeviceIDs: [SimulatorDeviceID] = []

    init(_ results: [Result<SimulatorRecoveryStreamSessionFake, SimulatorLiveStreamError>]) {
        self.results = results
    }

    var openCount: Int { requestedDeviceIDs.count }

    func openStream(
        for deviceID: SimulatorDeviceID
    ) async throws -> any SimulatorLiveStreamSession {
        requestedDeviceIDs.append(deviceID)
        guard !results.isEmpty else { throw SimulatorLiveStreamError.disconnected }
        return try results.removeFirst().get()
    }
}

private final class SimulatorRecoveryStreamSessionFake: SimulatorLiveStreamSession,
    @unchecked Sendable {
    let events: AsyncStream<SimulatorLiveStreamEvent>

    private let continuation: AsyncStream<SimulatorLiveStreamEvent>.Continuation
    private let lock = NSLock()
    private var stopped = false
    private var visibility: [Bool] = []
    private var recordedInputs: [SimulatorBridgeInput] = []

    init() {
        let pair = AsyncStream<SimulatorLiveStreamEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        events = pair.stream
        continuation = pair.continuation
        continuation.yield(.ready(
            backend: .direct(codec: .h264),
            capabilities: SimulatorBridgeCapabilities(
                codecs: [.h264, .jpeg],
                supportsTouch: true,
                supportsKeyboard: true,
                supportsButtons: true,
                maximumFramesPerSecond: 60
            ),
            coreSimulatorVersion: "CoreSimulator-test",
            simulatorKitVersion: "SimulatorKit-test"
        ))
    }

    var didStop: Bool { lock.withLock { stopped } }
    var inputs: [SimulatorBridgeInput] { lock.withLock { recordedInputs } }

    func emit(_ event: SimulatorLiveStreamEvent) {
        continuation.yield(event)
    }

    func setVisible(_ visible: Bool) {
        lock.withLock { visibility.append(visible) }
    }

    func sendInput(_ input: SimulatorBridgeInput) async throws {
        lock.withLock { recordedInputs.append(input) }
    }

    func stop() {
        lock.withLock { stopped = true }
    }
}

@MainActor
private final class SimulatorRecoveryInputAuthorizerFake: SimulatorInputAuthorizing {
    func authorize(
        device: SimulatorDevice,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        completion(true)
    }
}

private actor SimulatorRecoveryControlFake: SimulatorControlling {
    private(set) var prepareCount = 0
    private(set) var screenshotCount = 0
    private(set) var installObservedTransportStopped: Bool?
    private(set) var screenshotObservedTransportStopped: Bool?
    private var screenshotFailures: Int
    private let transportStoppedProbe: @Sendable () -> Bool

    init(
        screenshotFailures: Int = 0,
        transportStoppedProbe: @escaping @Sendable () -> Bool = { true }
    ) {
        self.screenshotFailures = screenshotFailures
        self.transportStoppedProbe = transportStoppedProbe
    }

    func availableDevices() async throws -> [SimulatorDevice] {
        [simulatorRecoveryFirstDevice, simulatorRecoverySecondDevice]
    }

    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        prepareCount += 1
        let selectedID = deviceID ?? simulatorRecoveryFirstDevice.id
        let devices = try await availableDevices()
        guard let device = devices.first(where: { $0.id == selectedID }) else {
            throw SimulatorControlError.deviceNotFound(selectedID)
        }
        return SimulatorDeviceLease(device: device, bootOwnership: .user)
    }

    func installAndLaunch(
        applicationURL: URL,
        bundleIdentifier: String,
        on deviceID: SimulatorDeviceID,
        arguments: [String]
    ) async throws -> SimulatorLaunchReceipt {
        installObservedTransportStopped = transportStoppedProbe()
        return SimulatorLaunchReceipt(
            deviceID: deviceID,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: nil
        )
    }

    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data {
        screenshotCount += 1
        screenshotObservedTransportStopped = transportStoppedProbe()
        if screenshotFailures > 0 {
            screenshotFailures -= 1
            throw SimulatorControlError.deviceNotFound(deviceID)
        }
        return Data(base64Encoded: Self.onePixelPNG)!
    }

    func release(_ lease: SimulatorDeviceLease) async throws {}

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/"
        + "ScLhWQAAAABJRU5ErkJggg=="
}

private let simulatorRecoveryFirstDevice = SimulatorDevice(
    id: SimulatorDeviceID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
    name: "iPhone 17 Pro",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    runtimeName: "iOS 26.5",
    deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    family: .iPhone,
    state: .booted,
    lastBootedAt: nil
)

private let simulatorRecoverySecondDevice = SimulatorDevice(
    id: SimulatorDeviceID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
    name: "iPhone Air",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    runtimeName: "iOS 26.5",
    deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Air",
    family: .iPhone,
    state: .booted,
    lastBootedAt: nil
)
