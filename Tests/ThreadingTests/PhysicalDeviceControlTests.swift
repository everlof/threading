import Foundation
import XCTest
@testable import Threading

final class PhysicalDeviceControlTests: XCTestCase {
    func testScreenshotPreparesDeveloperServicesOnceAndTargetsExactNetworkUDID() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingPhysicalDeviceControlTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = PhysicalDeviceCommandRunnerFake()
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-control-tests"),
            temporaryDirectory: temporaryDirectory,
            screenshotExecutable: URL(fileURLWithPath: "/mock/idevicescreenshot")
        )
        let device = Self.device(connection: .localNetwork)

        _ = try await control.screenshot(of: device)
        _ = try await control.screenshot(of: device)

        let calls = runner.recordedCalls()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].executable.path, "/usr/bin/xcrun")
        XCTAssertEqual(
            Array(calls[0].arguments.prefix(4)),
            ["devicectl", "device", "info", "ddiServices"]
        )
        XCTAssertTrue(calls[0].arguments.contains("--auto-mount-ddis"))
        XCTAssertEqual(
            calls[0].arguments.value(after: "--device"),
            device.id.rawValue
        )

        for call in calls.dropFirst() {
            XCTAssertEqual(call.executable.path, "/mock/idevicescreenshot")
            XCTAssertEqual(call.arguments.value(after: "--udid"), device.id.rawValue)
            XCTAssertTrue(call.arguments.contains("--network"))
        }
    }

    func testScreenshotToolIsRequiredBeforeAnyDeviceCommandRuns() async {
        let runner = PhysicalDeviceCommandRunnerFake()
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-control-missing-tool-tests"),
            screenshotExecutable: nil,
            capabilityProbeExecutable: { nil }
        )

        do {
            _ = try await control.screenshot(of: Self.device(connection: .usb))
            XCTFail("A missing screenshot backend must fail closed.")
        } catch {
            XCTAssertEqual(error as? PhysicalDeviceControlError, .screenshotToolUnavailable)
        }
        XCTAssertTrue(runner.recordedCalls().isEmpty)
    }

    func testIOS27ScreenshotUsesModernDVTBackendAndCachesIt() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = PhysicalDeviceCommandRunnerFake { call in
            call.arguments.last == "version"
                ? Self.success(Data("11.19.4\n".utf8))
                : Self.success(Data())
        }
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-modern-screenshot-tests"),
            temporaryDirectory: temporaryDirectory,
            environment: [
                "PYMOBILEDEVICE3_TUNNEL": "stale-tunnel",
                "PYMOBILEDEVICE3_USERSPACE": "1",
            ],
            screenshotExecutable: URL(fileURLWithPath: "/mock/idevicescreenshot"),
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )
        let device = Self.device(connection: .usb, osVersion: "27.0.1")

        _ = try await control.screenshot(of: device)
        _ = try await control.screenshot(of: device)

        let calls = runner.recordedCalls()
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[1].arguments, ["--no-color", "version"])
        for call in calls.suffix(2) {
            XCTAssertEqual(call.executable.path, "/mock/pymobiledevice3")
            XCTAssertEqual(
                Array(call.arguments.dropLast()),
                ["--no-color", "developer", "dvt", "screenshot", "--native"]
            )
            XCTAssertEqual(call.environment["PYMOBILEDEVICE3_UDID"], device.id.rawValue)
            XCTAssertNil(call.environment["PYMOBILEDEVICE3_TUNNEL"])
            XCTAssertNil(call.environment["PYMOBILEDEVICE3_USERSPACE"])
        }
    }

    func testIOS27ScreenshotRequiresSupportedModernTool() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = PhysicalDeviceCommandRunnerFake { call in
            call.arguments.last == "version"
                ? Self.success(Data("3.0.1\n".utf8))
                : Self.success(Data())
        }
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-modern-fallback-tests"),
            temporaryDirectory: temporaryDirectory,
            screenshotExecutable: URL(fileURLWithPath: "/mock/idevicescreenshot"),
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )

        do {
            _ = try await control.screenshot(
                of: Self.device(connection: .usb, osVersion: "27.0.1")
            )
            XCTFail("iOS 27 must not try the removed screenshotr service.")
        } catch {
            XCTAssertEqual(error as? PhysicalDeviceControlError, .screenshotToolUnavailable)
        }

        let calls = runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].arguments, ["--no-color", "version"])
        XCTAssertFalse(calls.contains { $0.executable.lastPathComponent == "idevicescreenshot" })
    }

    func testIOS27UpgradeDoesNotReuseCachedLegacyBackend() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = PhysicalDeviceCommandRunnerFake { call in
            call.arguments.last == "version"
                ? Self.success(Data("11.19.4\n".utf8))
                : Self.success(Data())
        }
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-upgrade-screenshot-tests"),
            temporaryDirectory: temporaryDirectory,
            screenshotExecutable: URL(fileURLWithPath: "/mock/idevicescreenshot"),
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )

        _ = try await control.screenshot(
            of: Self.device(connection: .usb, osVersion: "26.6.2")
        )
        _ = try await control.screenshot(
            of: Self.device(connection: .usb, osVersion: "27.0.1")
        )

        let captureCalls = runner.recordedCalls().filter { call in
            call.executable.lastPathComponent == "idevicescreenshot"
                || call.arguments.contains("screenshot")
        }
        XCTAssertEqual(captureCalls.count, 2)
        XCTAssertEqual(captureCalls[0].executable.path, "/mock/idevicescreenshot")
        XCTAssertEqual(captureCalls[1].executable.path, "/mock/pymobiledevice3")
    }

    func testControlSupportCallsDisplayServiceDirectlyAndTargetsExactUDID() async throws {
        let runner = PhysicalDeviceCommandRunnerFake { call in
            let output: Data
            if call.arguments.last == "version" {
                output = Data("11.13.1\n".utf8)
            } else {
                output = Data(#"{"supportedFeatures":0}"#.utf8)
            }
            return Self.success(output)
        }
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-capability-tests"),
            environment: [
                "PYMOBILEDEVICE3_TUNNEL": "stale-tunnel",
                "PYMOBILEDEVICE3_USERSPACE": "1",
            ],
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )
        let device = Self.device(connection: .usb)

        let support = try await control.controlSupport(of: device)

        XCTAssertEqual(support, .unavailable(.mediaStreamingUnavailable))
        let calls = runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(
            calls[1].arguments,
            [
                "--no-color", "developer", "core-device", "display",
                "get-media-support-info", "--native",
            ]
        )
        XCTAssertEqual(calls[1].environment["PYMOBILEDEVICE3_UDID"], device.id.rawValue)
        XCTAssertNil(calls[1].environment["PYMOBILEDEVICE3_TUNNEL"])
        XCTAssertNil(calls[1].environment["PYMOBILEDEVICE3_USERSPACE"])
    }

    func testControlSupportDetectsZeroMediaFeaturesWithoutOpeningHID() async throws {
        let runner = PhysicalDeviceCommandRunnerFake { call in
            if call.arguments.last == "version" {
                return Self.success(Data("11.13.1\n".utf8))
            }
            return Self.success(Data(#"{"supportedFeatures":0}"#.utf8))
        }
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-zero-media-tests"),
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )

        let support = try await control.controlSupport(of: Self.device(connection: .usb))

        XCTAssertEqual(support, .unavailable(.mediaStreamingUnavailable))
        XCTAssertEqual(runner.recordedCalls().count, 2)
        XCTAssertFalse(
            runner.recordedCalls().contains { $0.arguments.contains("list-connected") }
        )
    }

    func testControlSupportRequiresMainTouchscreenAfterMediaSupport() async throws {
        let runner = PhysicalDeviceCommandRunnerFake { call in
            if call.arguments.last == "version" {
                return Self.success(Data("11.13.1\n".utf8))
            }
            if call.arguments.contains("get-media-support-info") {
                return Self.success(Data(#"{"supportedFeatures":140}"#.utf8))
            }
            return Self.success(Data(#"{"payload":{"services":[{"_ServiceID":1280}]}}"#.utf8))
        }
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-touch-surface-tests"),
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )

        let support = try await control.controlSupport(of: Self.device(connection: .usb))

        XCTAssertEqual(support, .unavailable(.mainTouchscreenUnavailable))
        XCTAssertEqual(runner.recordedCalls().count, 3)
    }

    func testControlSupportReportsReadyOnlyWithMediaAndMainTouchscreen() async throws {
        let runner = PhysicalDeviceCommandRunnerFake { call in
            if call.arguments.last == "version" {
                return Self.success(Data("11.14.0\n".utf8))
            }
            if call.arguments.contains("get-media-support-info") {
                return Self.success(Data(#"{"supportedFeatures":140}"#.utf8))
            }
            return Self.success(Data(#"{"payload":{"services":[{"_ServiceID":257}]}}"#.utf8))
        }
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-control-ready-tests"),
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )

        let support = try await control.controlSupport(of: Self.device(connection: .usb))

        XCTAssertEqual(support, .available(supportedMediaFeatures: 140))
    }

    func testControlPreparationUsesLatestMounterRouteForExactUDID() async throws {
        let runner = PhysicalDeviceCommandRunnerFake()
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-control-preparation-tests"),
            environment: [
                "PYMOBILEDEVICE3_TUNNEL": "stale-tunnel",
                "PYMOBILEDEVICE3_USERSPACE": "1",
            ],
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )
        let device = Self.device(connection: .usb, osVersion: "27.0.1")

        try await control.prepareControl(of: device)

        let call = try XCTUnwrap(runner.recordedCalls().first)
        XCTAssertEqual(
            call.arguments,
            ["--no-color", "mounter", "auto-mount", "--native"]
        )
        XCTAssertEqual(call.environment["PYMOBILEDEVICE3_UDID"], device.id.rawValue)
        XCTAssertNil(call.environment["PYMOBILEDEVICE3_TUNNEL"])
        XCTAssertNil(call.environment["PYMOBILEDEVICE3_USERSPACE"])
    }

    func testControlPreparationRequiresUSBBeforeLaunchingMounter() async throws {
        let runner = PhysicalDeviceCommandRunnerFake()
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-control-usb-preparation-tests"),
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )
        let device = Self.device(connection: .localNetwork, osVersion: "27.0.1")

        do {
            try await control.prepareControl(of: device)
            XCTFail("Wi-Fi-only control preparation should fail closed")
        } catch let error as PhysicalDeviceControlError {
            XCTAssertEqual(error, .controlPreparationRequiresUSB)
        }
        XCTAssertTrue(runner.recordedCalls().isEmpty)
    }

    func testTapAndDragUseNormalizedHIDCoordinatesForExactUDID() async throws {
        let runner = PhysicalDeviceCommandRunnerFake()
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-input-tests"),
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )
        let device = Self.device(connection: .usb, osVersion: "27.0.1")

        try await control.sendInput(.tap(x: 0.5, y: 0.25), to: device)
        try await control.sendInput(
            .drag(fromX: 0, fromY: 1, toX: 1, toY: 0),
            to: device
        )

        let calls = runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(
            calls[0].arguments,
            [
                "--no-color", "developer", "core-device", "universal-hid-service",
                "tap", "32768", "16384", "--native",
            ]
        )
        XCTAssertEqual(
            calls[1].arguments,
            [
                "--no-color", "developer", "core-device", "universal-hid-service",
                "drag", "0", "65535", "65535", "0",
                "--steps", "18", "--duration", "0.3", "--native",
            ]
        )
        XCTAssertTrue(calls.allSatisfy {
            $0.environment["PYMOBILEDEVICE3_UDID"] == device.id.rawValue
        })
    }

    func testInvalidInputCoordinatesFailBeforeStartingACommand() async {
        let runner = PhysicalDeviceCommandRunnerFake()
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-invalid-input-tests"),
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )

        do {
            try await control.sendInput(
                .tap(x: .nan, y: 0.5),
                to: Self.device(connection: .usb)
            )
            XCTFail("Invalid coordinates must fail closed.")
        } catch {
            XCTAssertEqual(error as? PhysicalDeviceControlError, .invalidInput)
        }
        XCTAssertTrue(runner.recordedCalls().isEmpty)
    }

    func testControlSupportRefusesOutdatedProbeBeforeDeviceWork() async throws {
        let runner = PhysicalDeviceCommandRunnerFake { _ in
            Self.success(Data("3.0.1\n".utf8))
        }
        let control = DevicectlPhysicalDeviceControl(
            runner: runner,
            queue: DispatchQueue(label: "physical-device-old-probe-tests"),
            capabilityProbeExecutable: { URL(fileURLWithPath: "/mock/pymobiledevice3") }
        )

        let support = try await control.controlSupport(of: Self.device(connection: .usb))

        XCTAssertEqual(support, .unknown(.probeVersionUnsupported))
        XCTAssertEqual(runner.recordedCalls().count, 1)
    }

    func testCapabilityRunnerKeepsDiagnosticsOutOfProtocolOutput() throws {
        let result = try BoundedPhysicalDeviceCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf 'LibreSSL warning\\n' >&2; printf '11.19.4\\n'",
            ],
            timeout: 2,
            maximumOutputBytes: 4096,
            environment: ProcessInfo.processInfo.environment,
            cancellation: SimulatorCommandCancellation()
        )

        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "11.19.4\n")
    }

    func testLiveControlSupportWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawDeviceID = environment["THREADING_LIVE_PHYSICAL_DEVICE_UDID"],
              let deviceID = PhysicalDeviceID(rawDeviceID),
              let probePath = environment["THREADING_PHYSICAL_DEVICE_PROBE_PATH"],
              FileManager.default.isExecutableFile(atPath: probePath) else {
            throw XCTSkip("Set the live physical-device UDID and capability-probe path to opt in.")
        }

        let control = DevicectlPhysicalDeviceControl(
            environment: environment,
            capabilityProbeExecutable: { URL(fileURLWithPath: probePath) }
        )
        let devices = try await control.availableDevices()
        let device = try XCTUnwrap(devices.first(where: { $0.id == deviceID }))
        let support = try await control.controlSupport(of: device)

        print("Live physical-device control support: \(support)")
        if case .unknown(let reason) = support {
            XCTFail("The configured live capability probe returned unknown: \(reason)")
        }
    }

    func testLiveScreenshotWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawDeviceID = environment["THREADING_LIVE_PHYSICAL_DEVICE_UDID"],
              let deviceID = PhysicalDeviceID(rawDeviceID),
              let probePath = environment["THREADING_PHYSICAL_DEVICE_PROBE_PATH"],
              FileManager.default.isExecutableFile(atPath: probePath) else {
            throw XCTSkip("Set the live physical-device UDID and probe path to opt in.")
        }

        let control = DevicectlPhysicalDeviceControl(
            environment: environment,
            capabilityProbeExecutable: { URL(fileURLWithPath: probePath) }
        )
        let devices = try await control.availableDevices()
        let device = try XCTUnwrap(devices.first(where: { $0.id == deviceID }))
        let screenshot = try await control.screenshot(of: device)

        XCTAssertTrue(screenshot.starts(with: PhysicalDeviceDefaults.pngSignature))
        XCTAssertLessThanOrEqual(screenshot.count, PhysicalDeviceDefaults.maximumScreenshotBytes)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingPhysicalDeviceControlTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private static func success(_ output: Data) -> PhysicalDeviceCommandResult {
        PhysicalDeviceCommandResult(
            output: output,
            outputWasTruncated: false,
            termination: .exited(0)
        )
    }

    private static func device(
        connection: PhysicalDeviceConnection,
        osVersion: String = "26.6.2"
    ) -> PhysicalDevice {
        PhysicalDevice(
            id: PhysicalDeviceID("00008140-000C208C1108801C")!,
            coreDeviceIdentifier: UUID(
                uuidString: "ECE91967-105E-5BAE-9110-E49CBB0DEBD3"
            )!,
            name: "Test iPhone",
            productType: "iPhone17,1",
            osVersion: osVersion,
            connection: connection,
            developerModeEnabled: true,
            developerServicesAvailable: false
        )
    }
}

private final class PhysicalDeviceCommandRunnerFake:
    PhysicalDeviceCommandRunning,
    @unchecked Sendable
{
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private let response: @Sendable (Call) throws -> PhysicalDeviceCommandResult

    init(
        response: @escaping @Sendable (Call) throws -> PhysicalDeviceCommandResult = { _ in
            PhysicalDeviceCommandResult(
                output: Data(),
                outputWasTruncated: false,
                termination: .exited(0)
            )
        }
    ) {
        self.response = response
    }

    func recordedCalls() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        environment: [String: String],
        cancellation: SimulatorCommandCancellation
    ) throws -> PhysicalDeviceCommandResult {
        let call = Call(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        lock.lock()
        calls.append(call)
        lock.unlock()

        if (executable.lastPathComponent == "idevicescreenshot"
                || arguments.contains("screenshot")),
           let outputPath = arguments.last {
            try Data(base64Encoded: Self.onePixelPNG)!.write(
                to: URL(fileURLWithPath: outputPath),
                options: .atomic
            )
        }
        return try response(call)
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/"
        + "ScLhWQAAAABJRU5ErkJggg=="
}

private extension Array where Element == String {
    func value(after option: String) -> String? {
        guard let index = firstIndex(of: option) else { return nil }
        let valueIndex = index + 1
        return indices.contains(valueIndex) ? self[valueIndex] : nil
    }
}
