import ThreadingAndroidKit
import ThreadingSimulatorKit
import XCTest
@testable import Threading

/// Opt-in: `THREADING_ANDROID_LIVE_AVD` names an emulator that is already running with gRPC on
/// (`scripts/android_workspace_verify.sh` boots a dedicated one). It drives the shipping Android
/// control and both transports against it: catalogue, adoption lease, gRPC frames, touch, keys,
/// rotation, the uiautomator tree, and the adb fallback. `THREADING_ANDROID_LIVE_APK` plus
/// `THREADING_ANDROID_LIVE_PACKAGE` add an install-and-launch.
final class AndroidLiveIntegrationTests: XCTestCase {
    private var deviceID: SimulatorDeviceID!
    private var control: AndroidDeviceControl!
    private var directory: AndroidDeviceDirectory!

    override func setUpWithError() throws {
        guard let avd = ProcessInfo.processInfo.environment["THREADING_ANDROID_LIVE_AVD"], !avd.isEmpty else {
            throw XCTSkip("Set THREADING_ANDROID_LIVE_AVD to a running emulator's AVD name.")
        }
        directory = AndroidDeviceDirectory(sdk: try XCTUnwrap(AndroidSDK.locate(), "the Android SDK is not installed"))
        control = AndroidDeviceControl(sdk: directory.sdk!, directory: directory)
        deviceID = try XCTUnwrap(SimulatorDeviceID.androidEmulator(avdName: avd))
    }

    private func nextEvent(
        _ iterator: inout AsyncStream<SimulatorLiveStreamEvent>.Iterator, timeout: TimeInterval = 15,
        where matches: (SimulatorLiveStreamEvent) -> Bool
    ) async throws -> SimulatorLiveStreamEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let event = await iterator.next() else { throw SimulatorLiveStreamError.disconnected }
            if case .failed(let message) = event { XCTFail(message); throw SimulatorLiveStreamError.disconnected }
            if matches(event) { return event }
        }
        throw SimulatorLiveStreamError.stalled
    }

    /// How many distinct colours a coarse grid of samples finds.
    private static func distinctSampleCount(_ image: CGImage) -> Int {
        let width = 32, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var colours = Set<Int>()
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset]) << 16
            let green = Int(pixels[offset + 1]) << 8
            colours.insert(red | green | Int(pixels[offset + 2]))
        }
        return colours.count
    }

    func testCatalogueAdoptsTheRunningEmulatorAsTheUsers() async throws {
        let devices = try await control.availableDevices()
        let device = try XCTUnwrap(devices.first { $0.id == deviceID })
        XCTAssertTrue(device.state.isBooted)
        XCTAssertTrue(device.runtimeName.hasPrefix("Android"), device.runtimeName)
        let lease = try await control.prepare(deviceID: deviceID)
        XCTAssertEqual(lease.bootOwnership, .user, "a running emulator is the user's and is never stopped")
        try await control.release(lease)
        let screenshot = try await control.screenshot(of: deviceID)
        XCTAssertTrue(screenshot.starts(with: SimulatorControlDefaults.pngSignature))
    }

    func testEmulatorControlStreamsFramesTakesInputAndRotates() async throws {
        let coordinator = AndroidStreamCoordinator(control: control, directory: directory)
        let session = try await coordinator.openStream(for: deviceID)
        defer { session.stop() }
        var events = session.events.makeAsyncIterator()
        let ready = try await nextEvent(&events) { if case .ready = $0 { return true }; return false }
        guard case .ready(.android(.emulatorControl), _, _, _) = ready else {
            return XCTFail("expected the gRPC transport, got \(ready)")
        }
        session.setVisible(true)
        _ = try await nextEvent(&events) { if case .frame = $0 { return true }; return false }
        // A key press changes the screen, so a second, newer frame must follow.
        try await session.sendInput(.button(.home))
        let first = try await nextEvent(&events) { if case .frame = $0 { return true }; return false }
        try await session.sendInput(.tap(x: 0.5, y: 0.5))
        try await session.sendInput(.drag(fromX: 0.5, fromY: 0.8, toX: 0.5, toY: 0.3, durationMilliseconds: 300))
        try await session.sendInput(.button(.home))
        let second = try await nextEvent(&events) { if case .frame = $0 { return true }; return false }
        if case .frame(let a) = first, case .frame(let b) = second {
            XCTAssertGreaterThan(b.sequence, a.sequence)
            // Frames arrive through the mapped region; an unwritten region is uniformly zero.
            XCTAssertGreaterThan(Self.distinctSampleCount(b.image), 4, "the frame carries real pixels")
        }

        let tree = try await session.requestAccessibilitySnapshot()
        XCTAssertGreaterThan(tree.frame.width, 0)
        XCTAssertFalse(tree.children.isEmpty)

        try await session.sendInput(.button(.rotateRight))
        _ = try await nextEvent(&events, timeout: 20) { if case .geometryChanged = $0 { return true }; return false }

        // Put it back for the next run, from a session that has seen the rotated picture.
        let rotated = try await coordinator.openStream(for: deviceID)
        rotated.setVisible(true)
        var rotatedEvents = rotated.events.makeAsyncIterator()
        _ = try await nextEvent(&rotatedEvents) { if case .frame = $0 { return true }; return false }
        try await rotated.sendInput(.button(.rotateLeft))
        _ = try await nextEvent(&rotatedEvents, timeout: 20) { if case .geometryChanged = $0 { return true }; return false }
        rotated.stop()
    }

    /// The input mapping has to agree with the picture after a rotation: tap the centre of an
    /// element the tree reports in landscape and the app must open what is under it — in both
    /// landscape directions, since each maps the digitizer differently. Settings is on every
    /// image; the dedicated verify AVD has auto-rotate on.
    func testLandscapeTapsOpenTheElementUnderThemBothWays() async throws {
        try await resetToPortrait()
        do {
            try await assertLandscapeTap(rotation: .rotateLeft, restore: .rotateRight)
            try await assertLandscapeTap(rotation: .rotateRight, restore: .rotateLeft)
        } catch {
            try? await resetToPortrait()
            throw error
        }
    }

    private func resetToPortrait() async throws {
        let session = try await AndroidStreamCoordinator(control: control, directory: directory).openStream(for: deviceID)
        defer { session.stop() }
        try await XCTUnwrap(session as? AndroidEmulatorStreamSession).setRotation(quarterTurns: 0)
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    private func assertLandscapeTap(rotation: SimulatorBridgeButton, restore: SimulatorBridgeButton) async throws {
        guard let sdk = directory.sdk else { return }
        let serial = try await control.target(for: deviceID).serial
        func adb(_ arguments: String...) async throws -> String {
            String(decoding: try await AndroidADBCommand.run(adb: sdk.adb, arguments: ["-s", serial] + arguments, timeout: 20), as: UTF8.self)
        }
        let coordinator = AndroidStreamCoordinator(control: control, directory: directory)
        func session(expectLandscape: Bool?) async throws -> (any SimulatorLiveStreamSession, AsyncStream<SimulatorLiveStreamEvent>.Iterator) {
            let session = try await coordinator.openStream(for: deviceID)
            session.setVisible(true)
            var events = session.events.makeAsyncIterator()
            guard case .frame(let frame) = try await nextEvent(&events, where: { if case .frame = $0 { return true }; return false }) else {
                throw SimulatorLiveStreamError.disconnected
            }
            if let expectLandscape {
                XCTAssertEqual(frame.image.width > frame.image.height, expectLandscape, "the delivered picture is upright")
            }
            return (session, events)
        }
        // A clean main page: Settings' search is its own package, so force-stopping Settings
        // alone can leave it on top.
        _ = try await adb("shell", "input keyevent KEYCODE_HOME; am force-stop com.android.settings.intelligence; "
                          + "am start -W -S --activity-clear-task -a android.settings.SETTINGS")
        var (live, events) = try await session(expectLandscape: false)
        try await live.sendInput(.button(rotation))
        _ = try await nextEvent(&events, timeout: 20) { if case .geometryChanged = $0 { return true }; return false }
        live.stop()
        (live, events) = try await session(expectLandscape: true)
        // Settle the rotation animation before reading the tree.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let tree = try await live.requestAccessibilitySnapshot()
        XCTAssertGreaterThan(tree.frame.width, tree.frame.height, "the tree is in landscape axes too")
        func find(_ element: SimulatorAccessibilityElement, _ label: String) -> SimulatorAccessibilityElement? {
            if element.label == label { return element }
            return element.children.lazy.compactMap { find($0, label) }.first
        }
        // The first row is on screen in either orientation; opening it leaves the main page's
        // search field behind.
        XCTAssertNotNil(find(tree, "Search Settings"), "Settings' main page is showing")
        let row = try XCTUnwrap(find(tree, "Network & internet"), "Settings shows its first row")
        try await live.sendInput(.tap(x: row.frame.midX / tree.frame.width, y: row.frame.midY / tree.frame.height))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let after = try await live.requestAccessibilitySnapshot()
        XCTAssertNil(find(after, "Search Settings"), "\(rotation): the tap did not open the row under it")
        try await live.sendInput(.button(restore))
        _ = try await nextEvent(&events, timeout: 20) { if case .geometryChanged = $0 { return true }; return false }
        live.stop()
        let (upright, _) = try await session(expectLandscape: false)
        upright.stop()
    }

    func testScreenRecordFallbackStreamsAndTakesInput() async throws {
        guard let sdk = directory.sdk else { return }
        let target = try await control.target(for: deviceID)
        let session = try await AndroidScreenRecordStreamSession.open(target: target, sdk: sdk, onStop: {})
        defer { session.stop() }
        var events = session.events.makeAsyncIterator()
        let ready = try await nextEvent(&events) { if case .ready = $0 { return true }; return false }
        guard case .ready(.android(.screenRecord), _, _, _) = ready else { return XCTFail("\(ready)") }
        session.setVisible(true)
        _ = try await nextEvent(&events, timeout: 20) { if case .frame = $0 { return true }; return false }
        try await session.sendInput(.button(.home))
        try await session.sendInput(.tap(x: 0.5, y: 0.5))
        try await session.sendInput(.touch(phase: .began, x: 0.5, y: 0.7))
        try await session.sendInput(.touch(phase: .moved, x: 0.5, y: 0.5))
        try await session.sendInput(.touch(phase: .ended, x: 0.5, y: 0.4))
        _ = try await nextEvent(&events, timeout: 20) { if case .frame = $0 { return true }; return false }
    }

    func testInstallsAndLaunchesAnAPK() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["THREADING_ANDROID_LIVE_APK"], !path.isEmpty,
              let package = environment["THREADING_ANDROID_LIVE_PACKAGE"], !package.isEmpty else {
            throw XCTSkip("Set THREADING_ANDROID_LIVE_APK and THREADING_ANDROID_LIVE_PACKAGE.")
        }
        let receipt = try await control.installAndLaunch(
            applicationURL: URL(fileURLWithPath: path), bundleIdentifier: package, on: deviceID, arguments: ["hello world"]
        )
        XCTAssertEqual(receipt.bundleIdentifier, package)
        XCTAssertNotNil(receipt.processIdentifier)
    }
}
