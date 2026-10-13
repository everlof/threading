import Foundation
import XCTest
@testable import Threading

/// The commands a scenario becomes on each platform, through scripted `simctl` and `adb`.
final class SimulatorScenarioControlTests: XCTestCase {
    private static let phone = SimulatorDeviceID("AAAAAAAA-1111-2222-3333-444444444444")!
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenario-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: temporary) }

    /// A data container laid out as CoreSimulator lays them out for that device.
    private func container(for device: SimulatorDeviceID) throws -> URL {
        let url = temporary.appendingPathComponent(
            "Devices/\(device.rawValue)/data/Containers/Data/Application/\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        return url
    }

    // MARK: - iOS

    func testAnIOSLaunchChecksTheAppIsInstalledThenStartsItWithItsArguments() async throws {
        let simctl = ScriptedRunner([
            (["get_app_container"], "/Users/x/Bundle/Application/1/App.app\n", 0),
            (["launch"], "com.example.app: 4242\n", 0),
        ])
        let receipt = try await SimctlSimulatorControl(runner: simctl).launchApp(
            .iOS(bundleIdentifier: "com.example.app", arguments: ["-scene", "home"]), on: Self.phone
        )
        XCTAssertEqual(receipt.processIdentifier, 4242)
        XCTAssertEqual(simctl.commands, [
            ["get_app_container", Self.phone.rawValue, "com.example.app", "app"],
            ["launch", "--terminate-running-process", Self.phone.rawValue, "com.example.app", "-scene", "home"],
        ])
    }

    func testAnIOSLaunchOfAMissingAppSaysItIsNotInstalled() async {
        let simctl = ScriptedRunner([(["get_app_container"], "No such file or directory", 2)])
        do {
            _ = try await SimctlSimulatorControl(runner: simctl).launchApp(
                .iOS(bundleIdentifier: "com.example.app", arguments: []), on: Self.phone
            )
            XCTFail("a missing app cannot launch")
        } catch let error as SimulatorControlError {
            XCTAssertEqual(error, .applicationNotInstalled("com.example.app"))
            XCTAssertEqual(simctl.commands.count, 1, "no launch is attempted")
        } catch { XCTFail("\(error)") }
    }

    func testAnIOSLinkIsDroppedInTheAppsTemporaryDirectoryAndRung() async throws {
        let data = try container(for: Self.phone)
        let simctl = ScriptedRunner([(["get_app_container"], data.path + "\n", 0), (["spawn"], "", 0)])
        let url = URL(string: "example://debug/step?n=2")!
        try await SimctlSimulatorControl(runner: simctl).openAppLink(
            .iOS(bundleIdentifier: "com.example.app", url: url), on: Self.phone
        )
        let dropped = try String(contentsOf: data.appendingPathComponent("tmp/\(SimulatorAppLinkDrop.fileName)"), encoding: .utf8)
        XCTAssertEqual(dropped, url.absoluteString)
        XCTAssertEqual(simctl.commands, [
            ["get_app_container", Self.phone.rawValue, "com.example.app", "data"],
            ["spawn", Self.phone.rawValue, "notifyutil", "-p", SimulatorAppLinkDrop.notificationName],
        ], "no openurl: iOS would ask “Open in …?” for every step")
    }

    func testAnIOSLinkIsNotWrittenIntoAnotherDevicesContainer() async throws {
        let other = try container(for: SimulatorDeviceID("BBBBBBBB-1111-2222-3333-444444444444")!)
        let simctl = ScriptedRunner([(["get_app_container"], other.path + "\n", 0)])
        do {
            try await SimctlSimulatorControl(runner: simctl).openAppLink(
                .iOS(bundleIdentifier: "com.example.app", url: URL(string: "example://a")!), on: Self.phone
            )
            XCTFail("a container outside the device is refused")
        } catch SimulatorControlError.invalidAppLink {
            XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("tmp/\(SimulatorAppLinkDrop.fileName)").path))
            XCTAssertEqual(simctl.commands.count, 1, "nothing is rung")
        }
    }

    func testAnIOSLinkIsNotWrittenThroughATemporaryDirectoryLinkedOutOfTheApp() async throws {
        let data = try container(for: Self.phone)
        let elsewhere = temporary.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: data.appendingPathComponent("tmp"))
        try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("tmp"), withDestinationURL: elsewhere)
        let simctl = ScriptedRunner([(["get_app_container"], data.path + "\n", 0)])
        do {
            try await SimctlSimulatorControl(runner: simctl).openAppLink(
                .iOS(bundleIdentifier: "com.example.app", url: URL(string: "example://a")!), on: Self.phone
            )
            XCTFail("a linked tmp is refused")
        } catch SimulatorControlError.invalidAppLink {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
        }
    }

    // MARK: - Android

    private static let usbOutput = "List of devices attached\n0A141FDD4003NN device usb:2-1 model:Pixel_8_Pro transport_id:3\n"
    private static let usbPhone = SimulatorDeviceID.androidDevice(serial: "0A141FDD4003NN")!

    private func android(_ adb: ScriptedRunner) -> AndroidDeviceControl {
        let sdk = AndroidSDK(root: temporary, adb: URL(fileURLWithPath: "/usr/bin/true"),
                             emulator: URL(fileURLWithPath: "/usr/bin/true"), avdHome: temporary.appendingPathComponent("avd"))
        return AndroidDeviceControl(sdk: sdk, adb: adb, directory: AndroidDeviceDirectory(sdk: sdk), runningRecords: { [:] })
    }

    func testAnAndroidLaunchStartsTheNamedActivityWithTypedQuotedExtras() async throws {
        let adb = ScriptedRunner([
            (["devices", "-l"], Self.usbOutput, 0),
            (["-s", "0A141FDD4003NN", "shell", "pm", "path"], "package:/data/app/base.apk\n", 0),
            (["-s", "0A141FDD4003NN", "shell", "am", "start"], "Status: ok\n", 0),
            (["-s", "0A141FDD4003NN", "shell", "pidof"], "777\n", 0),
        ])
        let receipt = try await android(adb).launchApp(.android(
            package: "com.example.app", activity: ".Scenes",
            extras: [
                SimulatorLaunchExtra(key: "scene", value: .string("it's home")),
                SimulatorLaunchExtra(key: "step", value: .integer(2)),
                SimulatorLaunchExtra(key: "big", value: .integer(5_000_000_000)),
                SimulatorLaunchExtra(key: "debug", value: .boolean(true)),
            ]
        ), on: Self.usbPhone)
        XCTAssertEqual(receipt.processIdentifier, 777)
        let start = try XCTUnwrap(adb.commands.first { $0.contains("am") })
        XCTAssertEqual(start, [
            "-s", "0A141FDD4003NN", "shell", "am", "start", "-W", "-S", "-n", "'com.example.app/.Scenes'",
            "--es", "'scene'", "'it'\\''s home'",
            "--ei", "'step'", "2",
            "--el", "'big'", "5000000000",
            "--ez", "'debug'", "true",
        ])
    }

    func testAnAndroidLaunchOfAMissingPackageSaysItIsNotInstalled() async {
        let adb = ScriptedRunner([
            (["devices", "-l"], Self.usbOutput, 0),
            (["-s", "0A141FDD4003NN", "shell", "pm", "path"], "", 1),
        ])
        do {
            _ = try await android(adb).launchApp(.android(package: "com.example.app", activity: nil, extras: []), on: Self.usbPhone)
            XCTFail("a missing package cannot launch")
        } catch let error as SimulatorControlError {
            XCTAssertEqual(error, .applicationNotInstalled("com.example.app"))
            XCTAssertFalse(adb.commands.contains { $0.contains("am") })
        } catch { XCTFail("\(error)") }
    }

    func testAnAndroidLinkReachesTheRunningActivityWithoutRestartingIt() async throws {
        let adb = ScriptedRunner([
            (["devices", "-l"], Self.usbOutput, 0),
            (["-s", "0A141FDD4003NN", "shell", "am", "start"],
             "Warning: Activity not started, intent has been delivered to currently running top-most instance.\n", 0),
        ])
        try await android(adb).openAppLink(.android(
            package: "com.example.app", activity: ".Scenes", url: URL(string: "example://debug/step?n=1")!
        ), on: Self.usbPhone)
        let start = try XCTUnwrap(adb.commands.last)
        XCTAssertEqual(start, [
            "-s", "0A141FDD4003NN", "shell", "am", "start", "-W", "-a", "android.intent.action.VIEW",
            "-d", "'example://debug/step?n=1'", "-f", "0x20000000", "-n", "'com.example.app/.Scenes'",
        ])
        XCTAssertFalse(start.contains("-S"), "a step never force-stops the app")
    }

    func testAnActivityManagerRefusalIsAFailure() async {
        let adb = ScriptedRunner([
            (["devices", "-l"], Self.usbOutput, 0),
            (["-s", "0A141FDD4003NN", "shell", "am", "start"], "Error: Activity class {com.example.app/.Scenes} does not exist.\n", 0),
        ])
        do {
            try await android(adb).openAppLink(.android(package: "com.example.app", activity: ".Scenes",
                                                         url: URL(string: "example://a")!), on: Self.usbPhone)
            XCTFail("am's refusal is reported")
        } catch let error as SimulatorControlError {
            guard case .commandFailed(_, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("does not exist"))
        } catch { XCTFail("\(error)") }
    }

    // MARK: - Routing

    func testEachRequestGoesToItsOwnPlatformsControl() async throws {
        let simctl = ScriptedRunner([(["get_app_container"], "/x/App.app\n", 0), (["launch"], "a: 1\n", 0)])
        let adb = ScriptedRunner([
            (["devices", "-l"], Self.usbOutput, 0),
            (["-s", "0A141FDD4003NN", "shell", "pm", "path"], "package:/x\n", 0),
            (["-s", "0A141FDD4003NN", "shell", "am", "start"], "Status: ok\n", 0),
        ])
        let routing = PlatformRoutingSimulatorControl(iOS: SimctlSimulatorControl(runner: simctl), android: android(adb))
        _ = try await routing.launchApp(.iOS(bundleIdentifier: "com.example.app", arguments: []), on: Self.phone)
        _ = try await routing.launchApp(.android(package: "com.example.app", activity: ".Scenes", extras: []), on: Self.usbPhone)
        XCTAssertEqual(simctl.commands.count, 2)
        XCTAssertTrue(adb.commands.contains { $0.contains("am") })
        do {
            _ = try await routing.launchApp(.android(package: "com.example.app", activity: nil, extras: []), on: Self.phone)
            XCTFail("an iOS Simulator does not take an Android launch")
        } catch let error as SimulatorControlError {
            XCTAssertEqual(error, .unsupportedPlatformRequest)
        }
    }
}

/// Answers each command with the first response whose arguments it starts with.
private final class ScriptedRunner: SimulatorCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [(prefix: [String], output: String, status: Int32)]
    private var recorded: [[String]] = []

    init(_ responses: [(prefix: [String], output: String, status: Int32)]) { self.responses = responses }

    var commands: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int,
             capture: SimulatorCommandCapture, cancellation: SimulatorCommandCancellation) throws -> SimulatorCommandResult {
        lock.withLock {
            recorded.append(arguments)
            let match = responses.first { arguments.starts(with: $0.prefix) }
            return SimulatorCommandResult(output: Data((match?.output ?? "").utf8), outputWasTruncated: false,
                                          termination: .exited(match?.status ?? 0))
        }
    }
}
