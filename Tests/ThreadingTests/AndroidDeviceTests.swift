import AppKit
import ThreadingAndroidKit
import ThreadingSimulatorKit
import XCTest
@testable import Threading

// MARK: - Identity and persistence

final class AndroidDeviceIdentityTests: XCTestCase {
    func testIdentityFormsAndPlatforms() throws {
        let uuid = UUID().uuidString.lowercased()
        let iOS = try XCTUnwrap(SimulatorDeviceID(uuid))
        XCTAssertEqual(iOS.platform, .iOSSimulator)
        XCTAssertEqual(iOS.rawValue, uuid.uppercased(), "an iOS identity is still the canonical UUID")
        XCTAssertNil(iOS.androidName)

        let avd = try XCTUnwrap(SimulatorDeviceID.androidEmulator(avdName: "Pixel_8_API_36"))
        XCTAssertEqual(avd.rawValue, "android-avd:Pixel_8_API_36")
        XCTAssertEqual(avd.platform, .androidEmulator)
        XCTAssertEqual(avd.androidName, "Pixel_8_API_36")

        let phone = try XCTUnwrap(SimulatorDeviceID("android-usb:0A141FDD4003NN"))
        XCTAssertEqual(phone.platform, .androidDevice)
        XCTAssertTrue(phone.platform.isAndroid)
    }

    func testRefusesAnythingThatIsNotOneOfTheThreeForms() {
        for value in ["", "emulator-5554", "android-avd:", "android-avd:has space", "android-usb:x;rm -rf /",
                      "android-avd:" + String(repeating: "a", count: 129), "android-avd:Pixel'8"] {
            XCTAssertNil(SimulatorDeviceID(value), value)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(SimulatorDeviceID.self, from: Data(#""android-usb:a b""#.utf8)))
    }

    func testAnAndroidMemberRequiresFormatSixAndTravelsInTheWorkspace() throws {
        let android = try XCTUnwrap(SimulatorDeviceID.androidEmulator(avdName: "Pixel"))
        let iOS = try XCTUnwrap(SimulatorDeviceID(UUID().uuidString))
        func panel(_ tab: PersistedTab) -> PersistedPanel { PersistedPanel(tabs: [tab], activeTabID: tab.id) }
        func tab(device: SimulatorDeviceID?, workspace: SimulatorWorkspaceState?) -> PersistedTab {
            PersistedTab(id: UUID().uuidString, kind: .simulator, title: "", subtitle: "", url: nil, html: nil,
                         cacheFile: nil, simulatorDeviceID: device?.rawValue, simulatorWorkspace: workspace)
        }
        XCTAssertEqual(panel(tab(device: iOS, workspace: nil)).requiredFormatVersion, 3, "an iOS-only document is unchanged")
        XCTAssertEqual(panel(tab(device: android, workspace: SimulatorWorkspaceState(deviceID: android))).requiredFormatVersion, 6)

        var mixed = SimulatorWorkspaceState(deviceID: iOS)
        mixed.members.append(.init(id: UUID(), deviceID: android))
        let document = panel(tab(device: iOS, workspace: mixed))
        let decoded = try JSONDecoder().decode(PersistedPanel.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.tabs.first?.simulatorWorkspace?.members.compactMap(\.deviceID), [iOS, android])
    }
}

// MARK: - Routing

private final class ScriptedControl: SimulatorControlling, @unchecked Sendable {
    let devices: Result<[SimulatorDevice], Error>
    private let lock = NSLock()
    private(set) var calls: [String] = []

    init(_ devices: Result<[SimulatorDevice], Error>) { self.devices = devices }

    private func record(_ call: String) { lock.withLock { calls.append(call) } }

    func availableDevices() async throws -> [SimulatorDevice] { record("list"); return try devices.get() }
    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        record("prepare \(deviceID?.rawValue ?? "nil")")
        return SimulatorDeviceLease(device: try devices.get()[0], bootOwnership: .user)
    }
    func installAndLaunch(applicationURL: URL, bundleIdentifier: String, on deviceID: SimulatorDeviceID,
                          arguments: [String]) async throws -> SimulatorLaunchReceipt {
        record("install \(deviceID.rawValue)")
        return SimulatorLaunchReceipt(deviceID: deviceID, bundleIdentifier: bundleIdentifier, processIdentifier: nil)
    }
    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data { record("screenshot \(deviceID.rawValue)"); return Data() }
    func release(_ lease: SimulatorDeviceLease) async throws { record("release \(lease.device.id.rawValue)") }
}

private func device(_ id: SimulatorDeviceID, booted: Bool = true, reason: String? = nil) -> SimulatorDevice {
    SimulatorDevice(id: id, name: id.androidName ?? "iPhone", runtimeIdentifier: "", runtimeName: "",
                    deviceTypeIdentifier: "", family: id.platform.isAndroid ? .androidPhone : .iPhone,
                    state: booted ? .booted : .shutdown, lastBootedAt: nil, unavailableReason: reason)
}

final class PlatformRoutingSimulatorControlTests: XCTestCase {
    private let phone = SimulatorDeviceID(UUID().uuidString)!
    private let pixel = SimulatorDeviceID.androidEmulator(avdName: "Pixel")!

    func testMergesCataloguesAndRoutesEachDeviceToItsOwnPlane() async throws {
        let iOS = ScriptedControl(.success([device(phone)]))
        let android = ScriptedControl(.success([device(pixel)]))
        let control = PlatformRoutingSimulatorControl(iOS: iOS, android: android)
        let devices = try await control.availableDevices()
        XCTAssertEqual(devices.map(\.id), [phone, pixel])
        _ = try await control.screenshot(of: pixel)
        _ = try await control.screenshot(of: phone)
        _ = try await control.prepare(deviceID: nil)
        XCTAssertEqual(android.calls, ["list", "screenshot \(pixel.rawValue)"])
        XCTAssertEqual(iOS.calls, ["list", "screenshot \(phone.rawValue)", "prepare nil"],
                       "an unnamed preparation keeps its iOS meaning")
    }

    func testOnePlaneFailingNeverHidesTheOther() async throws {
        let broken = ScriptedControl(.failure(SimulatorControlError.timedOut(operation: "device discovery")))
        let withAndroidDown = PlatformRoutingSimulatorControl(iOS: ScriptedControl(.success([device(phone)])), android: broken)
        let iOSDevices = try await withAndroidDown.availableDevices()
        XCTAssertEqual(iOSDevices.map(\.id), [phone])
        let withIOSDown = PlatformRoutingSimulatorControl(iOS: broken, android: ScriptedControl(.success([device(pixel)])))
        let androidDevices = try await withIOSDown.availableDevices()
        XCTAssertEqual(androidDevices.map(\.id), [pixel])
        // Nothing listed at all still reports why.
        let empty = PlatformRoutingSimulatorControl(iOS: broken, android: ScriptedControl(.success([])))
        do {
            _ = try await empty.availableDevices()
            XCTFail("an empty Android list must not hide the iOS failure")
        } catch {}
    }

    func testWithoutTheSDKAnAndroidIdentityIsNotFound() async {
        let control = PlatformRoutingSimulatorControl(iOS: ScriptedControl(.success([])), android: nil)
        XCTAssertFalse(control.supportsAndroid)
        do {
            _ = try await control.screenshot(of: pixel)
            XCTFail("no SDK, no Android device")
        } catch let error as SimulatorControlError {
            XCTAssertEqual(error, .deviceNotFound(pixel))
        } catch { XCTFail("\(error)") }
    }
}

// MARK: - Android control through a scripted adb

private final class ScriptedADB: SimulatorCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(prefix: [String], output: String, status: Int32)]
    private(set) var commands: [[String]] = []

    init(_ responses: [(prefix: [String], output: String, status: Int32)]) { self.responses = responses }

    func run(_ arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int,
             capture: SimulatorCommandCapture, cancellation: SimulatorCommandCancellation) throws -> SimulatorCommandResult {
        lock.withLock {
            commands.append(arguments)
            let match = responses.first { arguments.starts(with: $0.prefix) }
            return SimulatorCommandResult(output: Data((match?.output ?? "").utf8), outputWasTruncated: false,
                                          termination: .exited(match?.status ?? 0))
        }
    }
}

private struct RefusingLauncher: AndroidEmulatorLaunching {
    func launch(executable: URL, arguments: [String], logURL: URL) throws -> SpawnedChildProcess {
        throw SimulatorControlError.launchFailed("no virtual machines in tests")
    }
}

final class AndroidDeviceControlTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("android-control-\(UUID().uuidString)")
        let avd = home.appendingPathComponent("avd/Pixel_8.avd")
        try FileManager.default.createDirectory(at: avd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sdk/system-images/android-36/default/arm64-v8a"),
                                                withIntermediateDirectories: true)
        try "path=\(avd.path)\n".write(to: home.appendingPathComponent("avd/Pixel_8.ini"), atomically: true, encoding: .utf8)
        try """
        avd.ini.displayname=Pixel 8
        image.sysdir.1=system-images/android-36/default/arm64-v8a/
        hw.lcd.width=1080
        hw.lcd.height=2400
        hw.lcd.density=420
        """.write(to: avd.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    private func control(_ adb: ScriptedADB, running: [String: RunningEmulatorRecord] = [:]) -> AndroidDeviceControl {
        let sdk = AndroidSDK(root: home.appendingPathComponent("sdk"), adb: URL(fileURLWithPath: "/usr/bin/true"),
                             emulator: URL(fileURLWithPath: "/usr/bin/true"), avdHome: home.appendingPathComponent("avd"))
        return AndroidDeviceControl(sdk: sdk, adb: adb, launcher: RefusingLauncher(),
                                    directory: AndroidDeviceDirectory(sdk: sdk), runningRecords: { running })
    }

    private static let devicesOutput = """
    List of devices attached
    emulator-5554          device product:sdk_phone64_arm64 model:sdk transport_id:1
    R5CT1234ABC            unauthorized usb:1-1 transport_id:2
    0A141FDD4003NN         device usb:2-1 product:husky model:Pixel_8_Pro device:husky transport_id:3

    """

    func testCatalogueJoinsAVDsToRunningEmulatorsAndListsUSBDevices() async throws {
        let adb = ScriptedADB([
            (["devices", "-l"], Self.devicesOutput, 0),
            (["-s", "emulator-5554", "emu", "avd", "id"], "Pixel_8\r\nOK\r\n", 0),
            (["-s", "0A141FDD4003NN", "shell", "getprop"], "35\n", 0),
        ])
        let devices = try await control(adb).availableDevices()
        XCTAssertEqual(devices.map(\.id.rawValue), ["android-avd:Pixel_8", "android-usb:0A141FDD4003NN", "android-usb:R5CT1234ABC"])
        XCTAssertEqual(devices[0].name, "Pixel 8")
        XCTAssertEqual(devices[0].runtimeName, "Android 16 · API 36")
        XCTAssertTrue(devices[0].state.isBooted, "an emulator found running by its console's AVD id")
        XCTAssertEqual(devices[1].name, "Pixel 8 Pro")
        XCTAssertEqual(devices[1].runtimeName, "Android 15 · API 35")
        XCTAssertNotNil(devices[2].unavailableReason, "an unauthorized phone is listed but cannot be adopted")
    }

    func testARunningEmulatorIsTheUsersAndReleasingItStopsNothing() async throws {
        let adb = ScriptedADB([
            (["devices", "-l"], Self.devicesOutput, 0),
            (["-s", "emulator-5554", "emu", "avd", "id"], "Pixel_8\nOK\n", 0),
        ])
        let control = control(adb)
        let lease = try await control.prepare(deviceID: SimulatorDeviceID.androidEmulator(avdName: "Pixel_8"))
        XCTAssertEqual(lease.bootOwnership, .user)
        try await control.release(lease)
        XCTAssertFalse(adb.commands.contains { $0.contains("kill") }, "an adopted emulator is never stopped")
    }

    func testAnUnauthorizedDeviceRefusesPreparationWithItsReason() async {
        let adb = ScriptedADB([(["devices", "-l"], Self.devicesOutput, 0)])
        do {
            _ = try await control(adb).prepare(deviceID: SimulatorDeviceID.androidDevice(serial: "R5CT1234ABC"))
            XCTFail("an unauthorized device cannot be adopted")
        } catch let error as SimulatorControlError {
            guard case .deviceUnavailable(_, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("USB debugging"), detail)
        } catch { XCTFail("\(error)") }
    }

    func testInstallQuotesEverythingTheDeviceShellSees() async throws {
        let apk = home.appendingPathComponent("app-debug.apk")
        try Data([0x50, 0x4B]).write(to: apk)
        let adb = ScriptedADB([
            (["devices", "-l"], Self.devicesOutput, 0),
            (["-s", "0A141FDD4003NN", "shell", "cmd", "package"], "priority=0\ncom.example.app/.MainActivity\n", 0),
            (["-s", "0A141FDD4003NN", "shell", "pidof"], "4242\n", 0),
        ])
        let phone = try XCTUnwrap(SimulatorDeviceID.androidDevice(serial: "0A141FDD4003NN"))
        let receipt = try await control(adb).installAndLaunch(
            applicationURL: apk, bundleIdentifier: "com.example.app", on: phone, arguments: ["it's; reboot"]
        )
        XCTAssertEqual(receipt.processIdentifier, 4242)
        XCTAssertTrue(adb.commands.contains(["-s", "0A141FDD4003NN", "install", "-r", "-t", apk.path]))
        let start = try XCTUnwrap(adb.commands.first { $0.contains("am") })
        XCTAssertTrue(start.contains("'com.example.app/.MainActivity'"))
        XCTAssertTrue(start.contains("'it'\\''s; reboot'"), "an argument reaches the device shell only quoted")
    }

    func testRefusesAnAppBundleAndAnInvalidPackage() async throws {
        let phone = try XCTUnwrap(SimulatorDeviceID.androidDevice(serial: "0A141FDD4003NN"))
        let control = control(ScriptedADB([]))
        do {
            _ = try await control.installAndLaunch(applicationURL: URL(fileURLWithPath: "/tmp/Thing.app"),
                                                   bundleIdentifier: "com.example", on: phone, arguments: [])
            XCTFail("an .app is not an Android package")
        } catch let error as SimulatorControlError {
            guard case .invalidApplication = error else { return XCTFail("\(error)") }
        }
        for name in ["example", "com..example", "com.example;id", "1com.example", "com.exa mple"] {
            XCTAssertThrowsError(try AndroidDeviceControl.validatedPackageName(name), name)
        }
        XCTAssertEqual(try AndroidDeviceControl.validatedPackageName(" com.example.app_2 "), "com.example.app_2")
    }

    func testAMissingSystemImageMakesTheAVDUnavailable() async throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent("sdk/system-images"))
        let devices = try await control(ScriptedADB([(["devices", "-l"], "List of devices attached\n", 0)])).availableDevices()
        XCTAssertNotNil(devices.first?.unavailableReason)
    }
}

// MARK: - Geometry, buttons, accessibility

final class AndroidGeometryTests: XCTestCase {
    func testUprightPointsMapToTheNaturalDigitizerForEveryRotation() {
        // The top-left of the upright picture, on a 1080×2400 natural portrait display.
        func corner(_ turns: Int) -> (Int32, Int32) {
            AndroidGeometry.nativePixel(x: 0, y: 0, quarterTurns: turns, nativeWidth: 1080, nativeHeight: 2400)
        }
        XCTAssertTrue(corner(0) == (0, 0))
        XCTAssertTrue(corner(1) == (1079, 0), "ROTATION_90: the upright top-left is the natural top-right")
        XCTAssertTrue(corner(2) == (1079, 2399))
        XCTAssertTrue(corner(3) == (0, 2399))
        let clamped = AndroidGeometry.nativePixel(x: 2, y: -1, quarterTurns: 0, nativeWidth: 100, nativeHeight: 200)
        XCTAssertTrue(clamped == (99, 0))
    }

    func testSensorAnglesMatchTheMeasuredEmulatorRotations() {
        XCTAssertEqual(AndroidGeometry.sensorDegrees(quarterTurns: 1), 90)
        XCTAssertEqual(AndroidGeometry.sensorDegrees(quarterTurns: 3), -90)
        XCTAssertEqual(AndroidGeometry.sensorDegrees(quarterTurns: -1), -90)
    }

    func testCapsTheFrameAndReadsTheWindowSize() {
        XCTAssertTrue(AndroidGeometry.cappedSize(width: 1080, height: 2400) == (576, 1280))
        XCTAssertTrue(AndroidGeometry.cappedSize(width: 720, height: 1280) == (720, 1280))
        XCTAssertTrue(AndroidGeometry.parseWindowSize("Physical size: 1080x2400\n")! == (1080, 2400))
        XCTAssertTrue(AndroidGeometry.parseWindowSize("Physical size: 1440x3120\nOverride size: 1080x2340\n")! == (1080, 2340))
        XCTAssertNil(AndroidGeometry.parseWindowSize("error: device offline"))
    }

    func testEveryAndroidButtonTheTraitsOfferHasARoute() {
        for platform in [SimulatorDevicePlatform.androidEmulator, .androidDevice] {
            for button in SimulatorPlatformTraits.traits(for: platform).buttons where ![.rotateLeft, .rotateRight].contains(button) {
                XCTAssertNotNil(AndroidButtonMapping.emulatorKeys[button], "\(button)")
                XCTAssertNotNil(AndroidButtonMapping.keyEvents[button], "\(button)")
            }
        }
        XCTAssertEqual(SimulatorPlatformTraits.traits(for: .iOSSimulator).buttons, SimulatorBridgeButton.iOS)
        XCTAssertFalse(SimulatorPlatformTraits.traits(for: .androidDevice).buttons.contains(.rotateLeft),
                       "a phone is turned by hand")
    }

    func testMapsTheWindowHierarchyOntoTheElementModel() {
        func node(_ className: String, clickable: Bool = false, text: String = "", children: [AndroidUINode] = []) -> AndroidUINode {
            var value = AndroidUINode(
                className: className, text: text, contentDescription: "", resourceID: "", packageName: "",
                bounds: .init(x: 0, y: 0, width: 10, height: 10), isEnabled: true, isClickable: clickable,
                isFocusable: false, isScrollable: false, isCheckable: false, isChecked: false,
                isPassword: false, isSelected: false, children: children
            )
            value.resourceID = text.isEmpty ? "" : "com.example:id/\(text)"
            return value
        }
        let element = AndroidAccessibilityReader.element(node("android.widget.FrameLayout", children: [
            node("android.widget.Button", text: "go"),
            node("android.widget.EditText", text: "hello"),
            node("android.widget.TextView", clickable: true, text: "link"),
        ]))
        XCTAssertEqual(element.children.map(\.role), ["AXButton", "AXTextField", "AXButton"])
        XCTAssertEqual(element.children[1].value, "hello")
        XCTAssertEqual(element.children[0].identifier, "com.example:id/go")
        XCTAssertEqual(element.children[0].subrole, "android.widget.Button")
    }
}

// MARK: - Agent vocabulary

final class AndroidAgentCommandTests: XCTestCase {
    func testButtonsAreTheTargetPlatformsOwn() {
        func press(_ button: String, _ platform: SimulatorDevicePlatform) -> Bool {
            if case .accepted = SimulatorAgentCommandService.buttonInput(
                from: SimulatorPressButtonArguments(button: button), platform: platform
            ) { return true }
            return false
        }
        XCTAssertTrue(press("back", .androidDevice))
        XCTAssertTrue(press("rotateLeft", .androidEmulator))
        XCTAssertFalse(press("rotateLeft", .androidDevice))
        XCTAssertFalse(press("side", .androidEmulator))
        XCTAssertFalse(press("back", .iOSSimulator))
        XCTAssertTrue(press("side", .iOSSimulator))
    }

    func testThePackageKindFollowsThePlatform() {
        let directory = FileManager.default.temporaryDirectory
        func request(_ path: String, _ platform: SimulatorDevicePlatform) -> Bool {
            if case .accepted = SimulatorAgentCommandService.launchRequest(
                from: SimulatorInstallLaunchArguments(applicationPath: path, bundleIdentifier: "com.example", arguments: nil),
                platform: platform, resolve: { directory.appendingPathComponent($0) }
            ) { return true }
            return false
        }
        XCTAssertTrue(request("app-debug.apk", .androidEmulator))
        XCTAssertFalse(request("Thing.app", .androidDevice))
        XCTAssertTrue(request("Thing.app", .iOSSimulator))
        XCTAssertFalse(request("app-debug.apk", .iOSSimulator))
    }

    func testPlatformArgument() {
        func platform(_ raw: String?) -> Bool?? {
            if case .accepted(let value) = SimulatorAgentCommandService.requestedPlatform(
                from: SimulatorPrepareArguments(deviceID: nil, platform: raw)
            ) { return .some(value) }
            return nil
        }
        XCTAssertEqual(platform(nil), .some(nil))
        XCTAssertEqual(platform("Android"), .some(true))
        XCTAssertEqual(platform("ios"), .some(false))
        XCTAssertEqual(platform("windows phone"), .none)
    }

    func testAnAndroidPreparationNamesItsSerialAndNoXcodeDestination() throws {
        let id = try XCTUnwrap(SimulatorDeviceID.androidEmulator(avdName: "Pixel"))
        let result = SimulatorAgentCommandService.preparationResult(
            for: SimulatorDeviceLease(device: device(id), bootOwnership: .threading), adbSerial: "emulator-5554"
        )
        let text = result.text
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(payload["platform"] as? String, "android")
        XCTAssertEqual(payload["adb_serial"] as? String, "emulator-5554")
        XCTAssertNil(payload["xcodebuild_destination"])
        XCTAssertEqual(payload["buttons"] as? [String], SimulatorAgentCommandService.Button.androidEmulator.map(\.rawValue))
    }
}

// MARK: - Shared UI pieces

@MainActor
final class AndroidWorkspaceChromeTests: XCTestCase {
    func testDeviceMenusGroupByPlatformOnlyWhenBothArePresent() {
        let iOS = device(SimulatorDeviceID(UUID().uuidString)!)
        let android = device(SimulatorDeviceID.androidEmulator(avdName: "Pixel")!)
        func headers(_ devices: [SimulatorDevice]) -> [String] {
            SimulatorWorkspaceViewController.groupedDeviceEntries(devices) { ThemedMenuItem(title: $0.name) }.compactMap {
                if case .header(let title) = $0 { return title }
                return nil
            }
        }
        XCTAssertEqual(headers([iOS]), [], "an iOS-only Mac sees exactly the list it always did")
        XCTAssertEqual(headers([iOS, android]), [L10n.string("iOS"), L10n.string("Android")])
    }

    func testHardwareControlsSkipHiddenButtonsAndBalanceRows() {
        let buttons = (0..<10).map { index in
            ThemedIconButton(symbolName: "house", accessibility: "Button \(index)", target: .device, inkSource: .chrome)
        }
        buttons[9].isHidden = true
        let controls = SimulatorHardwareControlsView(buttons: buttons)
        let size = ThemedIconButton.Target.device.size
        // Room for eight across: nine visible buttons wrap 5 + 4, not 8 + 1.
        let width = 8 * size.width + 7 * Design.Spacing.medium
        controls.frame = NSRect(x: 0, y: 0, width: width, height: controls.preferredHeight(for: width))
        controls.layoutSubtreeIfNeeded()
        let rows = Dictionary(grouping: buttons.prefix(9), by: { $0.frame.minY })
        XCTAssertEqual(rows.values.map(\.count).sorted(), [4, 5])
        XCTAssertEqual(controls.preferredHeight(for: width), 2 * size.height + Design.Spacing.medium)
    }
}

// MARK: - Platforms side by side

@MainActor
final class SimulatorPlatformMixTests: HostedStoreTestCase {
    private let phone = SimulatorDeviceID("00000000-0000-0000-0000-000000000001")!
    private let otherPhone = SimulatorDeviceID("00000000-0000-0000-0000-000000000002")!
    private let pixel = SimulatorDeviceID.androidEmulator(avdName: "Pixel")!
    private let tablet = SimulatorDeviceID.androidEmulator(avdName: "Tablet")!

    func testTheAutomaticChoicePrefersABootedDeviceOfThePlatformAndSkipsMembers() {
        let devices = [device(phone), device(tablet, booted: false), device(pixel),
                       device(SimulatorDeviceID.androidDevice(serial: "R5CT")!, reason: "Allow USB debugging")]
        XCTAssertEqual(SimulatorAutomaticChoice.deviceID(in: devices, android: true), pixel)
        XCTAssertEqual(SimulatorAutomaticChoice.deviceID(in: devices, android: true, excluding: [pixel]), tablet,
                       "a member is never chosen twice, and an unauthorized phone is never chosen")
        XCTAssertNil(SimulatorAutomaticChoice.deviceID(in: devices, android: true, excluding: [pixel, tablet]))
        XCTAssertEqual(SimulatorAutomaticChoice.deviceID(in: devices, android: false), phone)
    }

    func testPreparationRoutes() {
        typealias Service = SimulatorAgentCommandService
        func route(_ arguments: SimulatorPrepareArguments, _ shape: Service.WorkspaceShape?) -> Service.PreparationRoute? {
            guard case .accepted(let request) = Service.preparationRequest(from: arguments),
                  case .accepted(let route) = Service.preparationRoute(for: request, in: shape) else { return nil }
            return route
        }
        let lone = Service.WorkspaceShape(memberCount: 1, isLoneAndEmpty: false, deviceOnPlatform: nil)
        let empty = Service.WorkspaceShape(memberCount: 1, isLoneAndEmpty: true, deviceOnPlatform: nil)
        let mixed = Service.WorkspaceShape(memberCount: 2, isLoneAndEmpty: false, deviceOnPlatform: pixel)
        let iOSPair = Service.WorkspaceShape(memberCount: 2, isLoneAndEmpty: false, deviceOnPlatform: nil)
        let android = SimulatorPrepareArguments(deviceID: nil, platform: "android")
        let besideAndroid = SimulatorPrepareArguments(deviceID: nil, platform: "android", beside: true, layout: "row")

        XCTAssertEqual(route(android, nil), .prepare(nil), "no tab yet: open one on Android")
        XCTAssertEqual(route(android, lone), .prepare(nil), "a lone device switches, as it always has")
        XCTAssertEqual(route(besideAndroid, lone), .addBeside)
        XCTAssertEqual(route(besideAndroid, empty), .prepare(nil), "nothing held yet: choose on Android")
        XCTAssertEqual(route(android, mixed), .prepare(pixel), "platform alone addresses its only member")
        XCTAssertEqual(route(android, iOSPair), .addBeside, "a pair without Android gains one")
        XCTAssertEqual(route(SimulatorPrepareArguments(deviceID: pixel.rawValue), iOSPair), .add(pixel),
                       "a pair without Android gains the named emulator")
        XCTAssertNil(route(SimulatorPrepareArguments(deviceID: nil), iOSPair), "several devices and no hint is ambiguous")
        XCTAssertNil(route(SimulatorPrepareArguments(deviceID: nil, layout: "diagonal"), nil))
        guard case .accepted(let request) = Service.preparationRequest(from: besideAndroid) else { return XCTFail() }
        XCTAssertEqual(request.layout, .row)
    }

    func testANamedDeviceTakesItsPlatformsPlaceAndOnlyBesideOrDevicesGrowTheWorkspace() {
        typealias Service = SimulatorAgentCommandService
        func route(_ arguments: SimulatorPrepareArguments, _ shape: Service.WorkspaceShape?) -> Service.PreparationRoute? {
            guard case .accepted(let request) = Service.preparationRequest(from: arguments),
                  case .accepted(let route) = Service.preparationRoute(for: request, in: shape) else { return nil }
            return route
        }
        let iPhone = Service.WorkspaceShape(memberCount: 1, isLoneAndEmpty: false, deviceOnPlatform: nil,
                                            devices: [phone], selected: phone)
        let mixed = Service.WorkspaceShape(memberCount: 2, isLoneAndEmpty: false, deviceOnPlatform: nil,
                                           devices: [phone, pixel], selected: pixel)
        let named = { (id: SimulatorDeviceID) in SimulatorPrepareArguments(deviceID: id.rawValue) }

        XCTAssertEqual(route(named(phone), iPhone), .prepare(phone), "the device on show: nothing changes")
        XCTAssertEqual(route(named(otherPhone), iPhone), .replace(phone, with: otherPhone),
                       "a second iPhone takes the first one's place")
        XCTAssertEqual(route(SimulatorPrepareArguments(deviceID: otherPhone.rawValue, beside: true), iPhone),
                       .add(otherPhone), "beside is what adds")
        XCTAssertEqual(route(named(pixel), iPhone), .replace(phone, with: pixel),
                       "a lone device switches platform, as platform alone does")
        XCTAssertEqual(route(named(tablet), mixed), .replace(pixel, with: tablet), "the emulator's place, not the iPhone's")
        XCTAssertEqual(route(named(otherPhone), mixed), .replace(phone, with: otherPhone),
                       "the iPhone's place, although the emulator is the selected device")
        XCTAssertEqual(route(SimulatorPrepareArguments(deviceID: pixel.rawValue, devices: [phone.rawValue, pixel.rawValue]),
                             iPhone), .set([phone, pixel], selecting: pixel))
        XCTAssertEqual(route(SimulatorPrepareArguments(deviceID: nil, devices: [pixel.rawValue, phone.rawValue]), nil),
                       .set([pixel, phone], selecting: pixel), "the first device answers when none is picked")
    }

    func testARequestedWorkspaceNamesEachDeviceOnceAndNothingElseDecidesIt() {
        func rejected(_ arguments: SimulatorPrepareArguments) -> Bool {
            if case .rejected = SimulatorAgentCommandService.preparationRequest(from: arguments) { return true }
            return false
        }
        let five = (1...5).map { "00000000-0000-0000-0000-00000000000\($0)" }
        XCTAssertTrue(rejected(SimulatorPrepareArguments(deviceID: nil, devices: [])))
        XCTAssertTrue(rejected(SimulatorPrepareArguments(deviceID: nil, devices: five)), "more than the workspace holds")
        XCTAssertFalse(rejected(SimulatorPrepareArguments(deviceID: nil, devices: Array(five.prefix(4)))))
        XCTAssertTrue(rejected(SimulatorPrepareArguments(deviceID: nil, devices: [phone.rawValue, phone.rawValue])))
        XCTAssertTrue(rejected(SimulatorPrepareArguments(deviceID: nil, devices: ["iPhone 17"])), "never a guessed name")
        XCTAssertTrue(rejected(SimulatorPrepareArguments(deviceID: nil, platform: "android", devices: [pixel.rawValue])))
        XCTAssertTrue(rejected(SimulatorPrepareArguments(deviceID: nil, beside: true, devices: [pixel.rawValue])))
        XCTAssertTrue(rejected(SimulatorPrepareArguments(deviceID: tablet.rawValue, devices: [pixel.rawValue])),
                      "device_id picks one of devices")
        XCTAssertFalse(rejected(SimulatorPrepareArguments(deviceID: nil, layout: "row", devices: [phone.rawValue, pixel.rawValue])))
    }

    func testTheResultNamesWhatACallAddedAndRemovedAndNothingWhenItChangedNothing() throws {
        typealias Service = SimulatorAgentCommandService
        let summary = Service.WorkspaceSummary(layout: "row", devices: [
            Service.WorkspaceMember(deviceID: phone, name: "iPhone", selected: true),
            Service.WorkspaceMember(deviceID: pixel, name: "Pixel", selected: false),
        ])
        let changed = summary.changes(since: [phone, tablet])
        XCTAssertEqual(changed.added, [pixel.rawValue])
        XCTAssertEqual(changed.removed, [tablet.rawValue])
        let unchanged = summary.changes(since: [pixel, phone])
        XCTAssertNil(unchanged.added, "the same devices in another order are no change")
        XCTAssertNil(unchanged.removed)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(unchanged), encoding: .utf8))
        XCTAssertFalse(json.contains("added") || json.contains("removed"))
    }

    func testAskingForAndroidBesideAnIPhoneAddsItAndAskingAgainSelectsIt() async throws {
        let control = ScriptedControl(.success([device(phone), device(pixel)]))
        let pane = DisplayPaneController(simulatorControl: control)
        let session = SessionID()
        defer { pane.removeSession(session); DisplayPaneStore.shared.removeSession(session) }
        _ = try pane.activateSimulator(for: session, deviceID: phone)
        let workspace = try XCTUnwrap(pane.simulatorWorkspace(for: session))
        XCTAssertEqual(workspace.platformMix, .iOS)

        pane.showSimulatorPlatform(android: true, for: session)
        for _ in 0..<200 where workspace.state.members.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(workspace.state.members.compactMap(\.deviceID), [phone, pixel])
        XCTAssertEqual(workspace.deviceID(ofMember: workspace.state.selectedID), pixel)
        XCTAssertEqual(workspace.platformMix, .mixed)
        XCTAssertEqual(pane.tabs(for: session).count, 1, "both platforms share the one workspace tab")

        pane.showSimulatorPlatform(android: false, for: session)
        XCTAssertEqual(workspace.state.members.count, 2, "the iPhone is already here: show it, add nothing")
        XCTAssertEqual(workspace.deviceID(ofMember: workspace.state.selectedID), phone)

        let summary = workspace.agentSummary
        XCTAssertEqual(summary.devices.map(\.platform), ["ios", "android"])
        XCTAssertEqual(summary.devices.map(\.selected), [true, false])
    }

    func testAddingBesideRefusesWhenEveryDeviceOfThePlatformIsAlreadyHere() async throws {
        let pane = DisplayPaneController(simulatorControl: ScriptedControl(.success([device(phone), device(pixel)])))
        let session = SessionID()
        defer { pane.removeSession(session); DisplayPaneStore.shared.removeSession(session) }
        _ = try pane.activateSimulator(for: session, deviceID: phone)
        let workspace = try XCTUnwrap(pane.simulatorWorkspace(for: session))
        try await workspace.addAutomaticMember(android: true)
        do {
            try await workspace.addAutomaticMember(android: true)
            XCTFail("the only emulator is already a member")
        } catch let failure as SimulatorWorkspaceViewController.Failure {
            XCTAssertEqual(failure, .noOtherDevice(android: true))
        }
        do {
            try await workspace.addAutomaticMember(android: false)
            XCTFail("the only iPhone is already a member")
        } catch let failure as SimulatorWorkspaceViewController.Failure {
            XCTAssertEqual(failure, .noOtherDevice(android: false))
        }
        XCTAssertEqual(workspace.state.members.count, 2)
    }

    func testThePanelOffersEachPlatformAsItsOwnCommand() {
        func target(_ id: String) -> PanelCommandTarget? { PanelCommands.entries.first { $0.id == id }?.target }
        XCTAssertEqual(target("panel.simulator"), .simulator)
        XCTAssertEqual(target("panel.android"), .androidDevice)
        XCTAssertTrue(PanelCommands.additionalCommands.contains { $0.id == "panel.android" },
                      "the command palette and editable shortcuts reach it too")
    }

    func testAnAndroidMemberSpeaksOfADevice() {
        let iOS = SimulatorPlatformTraits.traits(for: .iOSSimulator)
        let android = SimulatorPlatformTraits.traits(for: .androidEmulator)
        XCTAssertEqual(iOS.string(.enableControl), L10n.string("Enable Simulator Control"))
        XCTAssertEqual(android.string(.enableControl), L10n.string("Enable Device Control"))
        XCTAssertEqual(android.controlDenied(for: "Pixel"), L10n.format("Device control was not allowed for %@.", "Pixel"))
        let screen = SimulatorScreenView()
        XCTAssertEqual(screen.accessibilityLabel(), L10n.string("Simulator screen"))
        screen.namesDevice = true
        XCTAssertEqual(screen.accessibilityLabel(), L10n.string("Device screen"))
        let recovery = SimulatorRecoveryView()
        recovery.namesDevice = true
        XCTAssertEqual(recovery.chooseButton.title, L10n.string("Choose Device"))
    }

    func testThePreparationResultListsTheWholeWorkspace() throws {
        let summary = SimulatorAgentCommandService.WorkspaceSummary(layout: "row", devices: [
            .init(deviceID: phone, name: "iPhone", selected: false),
            .init(deviceID: pixel, name: "Pixel", selected: true),
        ])
        let result = SimulatorAgentCommandService.preparationResult(
            for: SimulatorDeviceLease(device: device(pixel), bootOwnership: .user), workspace: summary
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        let workspace = try XCTUnwrap(payload["workspace"] as? [String: Any])
        XCTAssertEqual(workspace["layout"] as? String, "row")
        let devices = try XCTUnwrap(workspace["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.compactMap { $0["device_id"] as? String }, [phone.rawValue, pixel.rawValue])
        XCTAssertEqual(devices.compactMap { $0["platform"] as? String }, ["ios", "android"])
    }
}
