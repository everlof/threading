import AppKit
import ThreadingSimulatorKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorPaneTests: XCTestCase {
    func testHiddenPaneDoesNoWorkAndStopsFramebufferRequestsWhenHidden() async throws {
        let control = SimulatorPaneControlFake()
        let stream = SimulatorPaneStreamCoordinatorFake()
        let controller = SimulatorPaneViewController(
            control: control,
            streamCoordinator: stream
        )
        _ = controller.view

        XCTAssertEqual(controller.presentationState, .idle)
        let initialCounts = await control.counts()
        XCTAssertEqual(initialCounts.available, 0)

        controller.setPresented(true)
        try await eventually {
            controller.liveBackendForTesting == .direct(codec: .h264)
        }
        XCTAssertEqual(controller.selectedDeviceID, simulatorPaneTestDevice.id)
        XCTAssertTrue(controller.isPresentedForTesting)

        controller.setPresented(false)
        try await eventually { stream.session.lastVisibility == false }
        let hiddenCounts = await control.counts()
        XCTAssertEqual(hiddenCounts.screenshots, 0)
        XCTAssertEqual(stream.session.visibilityChanges, [true, false])
        XCTAssertFalse(controller.isPresentedForTesting)
    }

    func testLeaseManagerSharesOneCapabilityAndCancelsPrematureRelease() async throws {
        let control = SimulatorPaneControlFake()
        let manager = SimulatorLeaseManager(
            control: control,
            releaseGraceNanoseconds: 20_000_000
        )

        let first = try await manager.acquire(deviceID: simulatorPaneTestDevice.id)
        let second = try await manager.acquire(deviceID: simulatorPaneTestDevice.id)
        XCTAssertEqual(first, second)
        let preparedCounts = await control.counts()
        XCTAssertEqual(preparedCounts.prepares, 1)

        await manager.release(first)
        try await Task.sleep(nanoseconds: 40_000_000)
        let retainedCounts = await control.counts()
        XCTAssertEqual(retainedCounts.releases, 0)

        await manager.release(second)
        try await Task.sleep(nanoseconds: 5_000_000)
        let reacquired = try await manager.acquire(deviceID: simulatorPaneTestDevice.id)
        let reacquiredCounts = await control.counts()
        XCTAssertEqual(reacquiredCounts.prepares, 1)
        try await Task.sleep(nanoseconds: 40_000_000)
        let graceCounts = await control.counts()
        XCTAssertEqual(graceCounts.releases, 0)

        await manager.release(reacquired)
        try await eventually {
            await control.counts().releases == 1
        }
    }

    func testLiveStreamBudgetCapsAndReleasesExactReservations() throws {
        var budget = SimulatorStreamBudget(maximum: 4)
        let reservations = try (0..<4).map { _ in try budget.reserve() }
        XCTAssertEqual(budget.activeCount, 4)
        XCTAssertThrowsError(try budget.reserve()) { error in
            XCTAssertEqual(error as? SimulatorLiveStreamError, .streamLimit(maximum: 4))
        }

        budget.release(reservations[2])
        XCTAssertEqual(budget.activeCount, 3)
        _ = try budget.reserve()
        XCTAssertEqual(budget.activeCount, 4)
        budget.release(UUID())
        XCTAssertEqual(budget.activeCount, 4)
    }

    func testStreamDiagnosticsStayContentFreeAndAccountForFinalStatistics() {
        let diagnostics = SimulatorStreamDiagnostics()
        let id = UUID()
        diagnostics.started(id: id, codec: .h264)
        diagnostics.update(id: id, statistics: SimulatorBridgeStatistics(
            capturedFrames: 12,
            sentFrames: 8,
            replacedFrames: 3,
            encodedBytes: 65_536
        ))
        diagnostics.ended(id: id)
        diagnostics.recordedFallback()
        diagnostics.recordedFailure(.refused(.screenUnavailable, "secret device detail"))

        let token = diagnostics.reportToken
        XCTAssertTrue(token.contains("active=0"))
        XCTAssertTrue(token.contains("h264=1"))
        XCTAssertTrue(token.contains("fallback=1"))
        XCTAssertTrue(token.contains("frames=8"))
        XCTAssertTrue(token.contains("replaced=3"))
        XCTAssertTrue(token.contains("last=refused-screenUnavailable"))
        XCTAssertFalse(token.contains("secret"))
        XCTAssertFalse(token.contains(simulatorPaneTestDevice.id.rawValue))
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

    private func eventually(
        timeout: TimeInterval = 3,
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline {
                XCTFail("Timed out waiting for async simulator state.")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

}

private actor SimulatorPaneStreamCoordinatorFake: SimulatorLiveStreamCoordinating {
    nonisolated let session = SimulatorPaneStreamSessionFake()

    func openStream(
        for deviceID: SimulatorDeviceID
    ) async throws -> any SimulatorLiveStreamSession {
        session
    }
}

private final class SimulatorPaneStreamSessionFake: SimulatorLiveStreamSession, @unchecked Sendable {
    let events: AsyncStream<SimulatorLiveStreamEvent>

    private let lock = NSLock()
    private var visibility: [Bool] = []

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

    var visibilityChanges: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return visibility
    }

    var lastVisibility: Bool? { visibilityChanges.last }

    func setVisible(_ visible: Bool) {
        lock.lock()
        visibility.append(visible)
        lock.unlock()
    }

    func sendInput(_ input: SimulatorBridgeInput) async throws {}
    func stop() {}
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
