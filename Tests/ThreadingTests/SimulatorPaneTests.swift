import AppKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorPaneTests: XCTestCase {
    func testHiddenPaneDoesNoWorkAndStopsFramebufferRequestsWhenHidden() async throws {
        let control = SimulatorPaneControlFake()
        let controller = SimulatorPaneViewController(control: control)
        _ = controller.view

        XCTAssertEqual(controller.presentationState, .idle)
        let initialCounts = await control.counts()
        XCTAssertEqual(initialCounts.available, 0)

        controller.setPresented(true)
        try await eventually {
            controller.frameImageForTesting != nil
        }
        XCTAssertEqual(controller.selectedDeviceID, simulatorPaneTestDevice.id)
        XCTAssertTrue(controller.isPresentedForTesting)

        controller.setPresented(false)
        let hiddenCount = await control.counts().screenshots
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let finalHiddenCount = await control.counts().screenshots
        XCTAssertEqual(finalHiddenCount, hiddenCount)
        XCTAssertFalse(controller.isPresentedForTesting)
    }

    func testFailureRemainsInThePaneAndRetryUsesTheSameController() async throws {
        let control = SimulatorPaneControlFake(failure: SimulatorControlError.noAvailableIOSDevices)
        let controller = SimulatorPaneViewController(control: control)
        _ = controller.view

        controller.setPresented(true)
        try await eventually {
            if case .failed = controller.presentationState { return true }
            return false
        }

        guard case .failed(let message) = controller.presentationState else {
            return XCTFail("Simulator failure did not remain visible in its pane.")
        }
        XCTAssertTrue(message.contains("No available iOS Simulator"))
        XCTAssertTrue(controller.isPresentedForTesting)
    }

    func testDisplayPaneKeepsOnePersistedSimulatorTabAndRestoresItLazily() async throws {
        let control = SimulatorPaneControlFake()
        let sessionID = SessionID()
        defer { DisplayPaneStore.shared.removeSession(sessionID) }

        let pane = DisplayPaneController(simulatorControl: control)
        let first = pane.activateSimulator(for: sessionID, deviceID: simulatorPaneTestDevice.id)
        let second = pane.activateSimulator(for: sessionID, deviceID: simulatorPaneTestDevice.id)

        XCTAssertTrue(first === second)
        XCTAssertEqual(pane.tabs(for: sessionID).filter { $0.simulator != nil }.count, 1)
        let stored = try XCTUnwrap(
            DisplayPaneStore.shared.loadLayout(for: sessionID)?.panelTabs.first
        )
        XCTAssertEqual(stored.kind, .simulator)
        XCTAssertEqual(stored.simulatorDeviceID, simulatorPaneTestDevice.id.rawValue)
        XCTAssertEqual(
            DisplayPaneStore.shared.loadLayout(for: sessionID)?.requiredFormatVersion,
            3
        )
        let unpresentedCounts = await control.counts()
        XCTAssertEqual(unpresentedCounts.available, 0)

        let restoredControl = SimulatorPaneControlFake()
        let restored = DisplayPaneController(simulatorControl: restoredControl)
        let restoredTab = try XCTUnwrap(restored.tabs(for: sessionID).first)
        XCTAssertEqual(restoredTab.simulator?.selectedDeviceID, simulatorPaneTestDevice.id)
        let restoredCounts = await restoredControl.counts()
        XCTAssertEqual(restoredCounts.available, 0)
    }

    func testSimulatorFramesOptIntoUpscalingWithoutChangingImagePreviewDefault() {
        let imageSize = NSSize(width: 100, height: 200)
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 400)

        XCTAssertEqual(
            ThemedImagePreview.fittedRect(for: imageSize, in: bounds).size,
            imageSize
        )
        XCTAssertEqual(
            ThemedImagePreview.fittedRect(
                for: imageSize,
                in: bounds,
                allowsUpscaling: true
            ).size,
            bounds.size
        )
    }

    private func eventually(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for simulator pane state.")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

}

private let simulatorPaneTestDevice = SimulatorDevice(
    id: SimulatorDeviceID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
    name: "iPhone 17 Pro",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    runtimeName: "iOS 26.5",
    deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    family: .iPhone,
    state: .booted,
    lastBootedAt: nil
)

private actor SimulatorPaneControlFake: SimulatorControlling {
    struct Counts: Sendable {
        var available = 0
        var prepares = 0
        var screenshots = 0
        var releases = 0
    }

    private let failure: SimulatorControlError?
    private var callCounts = Counts()

    init(failure: SimulatorControlError? = nil) {
        self.failure = failure
    }

    func counts() -> Counts { callCounts }

    func availableDevices() async throws -> [SimulatorDevice] {
        callCounts.available += 1
        if let failure { throw failure }
        return [simulatorPaneTestDevice]
    }

    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        callCounts.prepares += 1
        if let failure { throw failure }
        return SimulatorDeviceLease(
            device: simulatorPaneTestDevice,
            bootOwnership: .user
        )
    }

    func installAndLaunch(
        applicationURL: URL,
        bundleIdentifier: String,
        on deviceID: SimulatorDeviceID,
        arguments: [String]
    ) async throws -> SimulatorLaunchReceipt {
        SimulatorLaunchReceipt(
            deviceID: deviceID,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: nil
        )
    }

    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data {
        callCounts.screenshots += 1
        return Data(base64Encoded: Self.onePixelPNG)!
    }

    func release(_ lease: SimulatorDeviceLease) async throws {
        callCounts.releases += 1
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/"
        + "ScLhWQAAAABJRU5ErkJggg=="
}
