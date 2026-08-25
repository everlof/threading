import XCTest
@testable import Threading

final class SimulatorControlTests: XCTestCase {
    func testCatalogKeepsOnlyAvailableIOSDevicesAndOrdersActivePhonesFirst() throws {
        let devices = try SimulatorDeviceCatalog.decodeAvailableIOSDevices(
            from: Data(Self.deviceFixture.utf8)
        )

        XCTAssertEqual(devices.map(\.name), ["Work Phone", "Recent Phone", "Tablet"])
        XCTAssertEqual(devices.map(\.runtimeName), ["iOS 26.5", "iOS 26.5", "iOS 26.5"])
        XCTAssertEqual(devices.map(\.family), [.iPhone, .iPhone, .iPad])
        XCTAssertEqual(devices.first?.state, .booted)
        XCTAssertFalse(devices.contains(where: { $0.name == "Unavailable Phone" }))
        XCTAssertFalse(devices.contains(where: { $0.name == "Television" }))
    }

    func testDeviceIdentityDecodingCannotBypassUUIDValidation() throws {
        let valid = try JSONDecoder().decode(
            SimulatorDeviceID.self,
            from: Data("\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\"".utf8)
        )
        XCTAssertEqual(valid.rawValue, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        XCTAssertThrowsError(try JSONDecoder().decode(
            SimulatorDeviceID.self,
            from: Data("\"not-a-device\"".utf8)
        ))
    }

    func testPrepareAdoptsAnAlreadyBootedDeviceWithoutChangingItsLifecycle() async throws {
        let runner = RecordingSimulatorCommandRunner(outputs: [Data(Self.deviceFixture.utf8)])
        let control = SimctlSimulatorControl(runner: runner)

        let lease = try await control.prepare(deviceID: Self.workPhoneID)

        XCTAssertEqual(lease.device.name, "Work Phone")
        XCTAssertEqual(lease.bootOwnership, .user)
        XCTAssertEqual(runner.recordedArguments, [["list", "devices", "available", "--json"]])

        try await control.release(lease)
        XCTAssertEqual(runner.recordedArguments.count, 1)
    }

    func testPrepareBootsAndReleaseStopsOnlyAThreadingOwnedDevice() async throws {
        let runner = RecordingSimulatorCommandRunner(outputs: [
            Data(Self.deviceFixture.utf8),
            Data("boot complete\n".utf8),
            Data()
        ])
        let control = SimctlSimulatorControl(runner: runner)

        let lease = try await control.prepare(deviceID: Self.recentPhoneID)
        XCTAssertEqual(lease.bootOwnership, .threading)
        XCTAssertEqual(lease.device.state, .booted)
        XCTAssertEqual(runner.recordedArguments[1], [
            "bootstatus", Self.recentPhoneID.rawValue, "-b"
        ])

        try await control.release(lease)
        XCTAssertEqual(runner.recordedArguments.last, [
            "shutdown", Self.recentPhoneID.rawValue
        ])
    }

    func testInstallAndLaunchUsesTheSelectedUDIDAndReturnsThePID() async throws {
        let runner = RecordingSimulatorCommandRunner(outputs: [
            Data(),
            Data("codes.threading.fixture: 4321\n".utf8)
        ])
        let control = SimctlSimulatorControl(runner: runner)
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        try FileManager.default.createDirectory(
            at: applicationURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: applicationURL) }

        let receipt = try await control.installAndLaunch(
            applicationURL: applicationURL,
            bundleIdentifier: "codes.threading.fixture",
            on: Self.workPhoneID,
            arguments: ["--fixture", "one"]
        )

        XCTAssertEqual(receipt.processIdentifier, 4321)
        XCTAssertEqual(runner.recordedArguments, [
            ["install", Self.workPhoneID.rawValue, applicationURL.path],
            [
                "launch", "--terminate-running-process", Self.workPhoneID.rawValue,
                "codes.threading.fixture", "--fixture", "one"
            ]
        ])
    }

    func testScreenshotUsesAPrivateBoundedFileAndRemovesIt() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let png = SimulatorControlDefaults.pngSignature + Data([0x00, 0x01])
        let runner = RecordingSimulatorCommandRunner(
            outputs: [Data()],
            screenshotPayloads: [png]
        )
        let control = SimctlSimulatorControl(
            runner: runner,
            screenshotTemporaryDirectory: temporaryDirectory,
            maximumScreenshotBytes: png.count
        )

        let captured = try await control.screenshot(of: Self.workPhoneID)

        XCTAssertEqual(captured, png)
        let command = try XCTUnwrap(runner.recordedArguments.first)
        XCTAssertEqual(Array(command.dropLast()), [
            "io", Self.workPhoneID.rawValue, "screenshot", "--type=png"
        ])
        let outputPath = try XCTUnwrap(command.last)
        XCTAssertNotEqual(outputPath, "-")
        XCTAssertTrue(outputPath.hasPrefix(temporaryDirectory.path + "/"))
        XCTAssertEqual(URL(fileURLWithPath: outputPath).pathExtension, "png")
        XCTAssertEqual(runner.recordedCaptures, [.combined])
        XCTAssertEqual(
            runner.recordedMaximumOutputBytes,
            [SimulatorControlDefaults.maximumCommandOutputBytes]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path),
            []
        )
    }

    func testScreenshotRejectsInvalidPNGAndRemovesItsCapture() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = RecordingSimulatorCommandRunner(
            outputs: [Data()],
            screenshotPayloads: [Data("not png".utf8)]
        )
        let invalid = SimctlSimulatorControl(
            runner: runner,
            screenshotTemporaryDirectory: temporaryDirectory
        )
        do {
            _ = try await invalid.screenshot(of: Self.workPhoneID)
            XCTFail("An invalid framebuffer capture should be refused.")
        } catch {
            XCTAssertEqual(error as? SimulatorControlError, .invalidScreenshot)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path),
            []
        )
    }

    func testScreenshotRejectsAnOversizedFileAndRemovesItsCapture() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let oversized = SimulatorControlDefaults.pngSignature + Data([0x00])
        let control = SimctlSimulatorControl(
            runner: RecordingSimulatorCommandRunner(
                outputs: [Data()],
                screenshotPayloads: [oversized]
            ),
            screenshotTemporaryDirectory: temporaryDirectory,
            maximumScreenshotBytes: SimulatorControlDefaults.pngSignature.count
        )

        do {
            _ = try await control.screenshot(of: Self.workPhoneID)
            XCTFail("An oversized framebuffer capture should be refused.")
        } catch {
            XCTAssertEqual(
                error as? SimulatorControlError,
                .outputTooLarge(operation: "screenshot")
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path),
            []
        )
    }

    func testScreenshotPreservesSimctlFailureDetailAndRemovesPartialCapture() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let detail = "CoreSimulator capture failed"
        let runner = RecordingSimulatorCommandRunner(
            outputs: [Data(detail.utf8)],
            screenshotPayloads: [SimulatorControlDefaults.pngSignature],
            exitStatuses: [72]
        )
        let control = SimctlSimulatorControl(
            runner: runner,
            screenshotTemporaryDirectory: temporaryDirectory
        )

        do {
            _ = try await control.screenshot(of: Self.workPhoneID)
            XCTFail("A failed simctl capture should be reported.")
        } catch {
            XCTAssertEqual(
                error as? SimulatorControlError,
                .commandFailed(operation: "screenshot", detail: detail)
            )
        }
        XCTAssertEqual(runner.recordedCaptures, [.combined])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path),
            []
        )
    }

    func testRunnerCancellationTerminatesTheOwnedProcessGroup() async throws {
        let runner = XcrunSimulatorCommandRunner(
            executable: "/bin/sleep",
            prefixArguments: []
        )
        let cancellation = SimulatorCommandCancellation()
        let started = Date()
        let task = Task.detached {
            try runner.run(
                ["10"],
                timeout: 20,
                maximumOutputBytes: 1_024,
                capture: .combined,
                cancellation: cancellation
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        cancellation.cancel()
        _ = try await task.value

        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertLessThan(-started.timeIntervalSinceNow, 3)
    }

    private static let workPhoneID = SimulatorDeviceID(
        "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    )!
    private static let recentPhoneID = SimulatorDeviceID(
        "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    )!

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SimulatorControlTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private static let deviceFixture = #"""
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
          {
            "udid": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "isAvailable": true,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            "state": "Booted",
            "name": "Work Phone",
            "lastBootedAt": "2026-08-20T18:57:26Z"
          },
          {
            "udid": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            "isAvailable": true,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
            "state": "Shutdown",
            "name": "Recent Phone",
            "lastBootedAt": "2026-08-18T19:52:12Z"
          },
          {
            "udid": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            "isAvailable": true,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-A16",
            "state": "Shutdown",
            "name": "Tablet",
            "lastBootedAt": "2026-08-19T19:52:12Z"
          },
          {
            "udid": "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            "isAvailable": false,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-8",
            "state": "Shutdown",
            "name": "Unavailable Phone"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-26-5": [
          {
            "udid": "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
            "isAvailable": true,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K",
            "state": "Shutdown",
            "name": "Television"
          }
        ]
      }
    }
    """#
}

private final class RecordingSimulatorCommandRunner: SimulatorCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [Data]
    private var screenshotPayloads: [Data]
    private var exitStatuses: [Int32]
    private var arguments: [[String]] = []
    private var captures: [SimulatorCommandCapture] = []
    private var maximumOutputBytes: [Int] = []

    init(
        outputs: [Data],
        screenshotPayloads: [Data] = [],
        exitStatuses: [Int32] = []
    ) {
        self.outputs = outputs
        self.screenshotPayloads = screenshotPayloads
        self.exitStatuses = exitStatuses
    }

    var recordedArguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return arguments
    }

    var recordedCaptures: [SimulatorCommandCapture] {
        lock.lock()
        defer { lock.unlock() }
        return captures
    }

    var recordedMaximumOutputBytes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return maximumOutputBytes
    }

    func run(
        _ arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        capture: SimulatorCommandCapture,
        cancellation: SimulatorCommandCancellation
    ) throws -> SimulatorCommandResult {
        lock.lock()
        defer { lock.unlock() }
        self.arguments.append(arguments)
        captures.append(capture)
        self.maximumOutputBytes.append(maximumOutputBytes)
        guard !outputs.isEmpty else {
            return SimulatorCommandResult(
                output: Data("No fixture response".utf8),
                outputWasTruncated: false,
                termination: .exited(1)
            )
        }
        if arguments.dropFirst(2).starts(with: ["screenshot", "--type=png"]),
           let outputPath = arguments.last,
           !screenshotPayloads.isEmpty {
            try screenshotPayloads.removeFirst().write(
                to: URL(fileURLWithPath: outputPath),
                options: .atomic
            )
        }
        return SimulatorCommandResult(
            output: outputs.removeFirst(),
            outputWasTruncated: false,
            termination: .exited(exitStatuses.isEmpty ? 0 : exitStatuses.removeFirst())
        )
    }
}
