import Foundation
import os

protocol PhysicalDeviceControlling: Sendable {
    func availableDevices() async throws -> [PhysicalDevice]
    func controlSupport(of device: PhysicalDevice) async throws -> PhysicalDeviceControlSupport
    func prepareControl(of device: PhysicalDevice) async throws
    func sendInput(_ input: PhysicalDeviceInput, to device: PhysicalDevice) async throws
    func screenshot(of device: PhysicalDevice) async throws -> Data
}

enum PhysicalDeviceControlError: LocalizedError, Equatable, Sendable {
    case commandFailed(operation: String, detail: String)
    case timedOut(operation: String)
    case cancelled
    case outputTooLarge(operation: String)
    case invalidResponse(String)
    case tooManyDevices(maximum: Int)
    case noAvailableIPhones
    case deviceNotFound(PhysicalDeviceID)
    case screenshotToolUnavailable
    case invalidScreenshot
    case controlToolUnavailable
    case controlPreparationRequiresUSB
    case invalidInput

    var errorDescription: String? {
        switch self {
        case .commandFailed(_, let detail): return detail
        case .timedOut(let operation): return "The physical-device \(operation) took too long."
        case .cancelled: return "The physical-device operation was cancelled."
        case .outputTooLarge(let operation):
            return "The physical-device \(operation) returned more data than Threading can safely read."
        case .invalidResponse(let detail): return detail
        case .tooManyDevices(let maximum):
            return "CoreDevice returned more than \(maximum) devices."
        case .noAvailableIPhones:
            return "No paired iPhone is available. Connect and unlock an iPhone, then try again."
        case .deviceNotFound:
            return "The selected iPhone is no longer available. Choose another device."
        case .screenshotToolUnavailable:
            return "Install iPhone Tooling in Settings → Advanced to preview this iPhone."
        case .invalidScreenshot:
            return "The iPhone did not return a valid screenshot."
        case .controlToolUnavailable:
            return "Install iPhone Tooling in Settings → Advanced to control this iPhone."
        case .controlPreparationRequiresUSB:
            return L10n.string("Connect this iPhone with a cable, unlock it, then retry.")
        case .invalidInput:
            return "Threading refused invalid iPhone input coordinates."
        }
    }
}

enum PhysicalDeviceDefaults {
    static let maximumDeviceCount = 128
    static let maximumCommandOutputBytes = 64 * 1024
    static let maximumScreenshotBytes = 32 * 1024 * 1024
    static let discoveryTimeout: TimeInterval = 12
    static let screenshotTimeout: TimeInterval = 12
    static let developerServicesTimeout: TimeInterval = 30
    static let probeVersionTimeout: TimeInterval = 3
    static let capabilityProbeTimeout: TimeInterval = 12
    static let controlPreparationTimeout: TimeInterval = 5 * 60
    static let inputTimeout: TimeInterval = 20
    static let hidCoordinateMaximum = 65_535
    static let dragSteps = 18
    static let dragDuration = 0.3
    static let commandQueueLabel = "codes.threading.physical-device.control"
    static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}

struct PhysicalDeviceCommandResult: Sendable {
    let output: Data
    let outputWasTruncated: Bool
    let termination: BoundedChildTermination
}

protocol PhysicalDeviceCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        environment: [String: String],
        cancellation: SimulatorCommandCancellation
    ) throws -> PhysicalDeviceCommandResult
}

/// Finite device commands run in their own process group. Discovery and screenshots can both
/// wait on hardware, so neither is allowed onto the main actor or left alive after cancellation.
struct BoundedPhysicalDeviceCommandRunner: PhysicalDeviceCommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        environment: [String: String],
        cancellation: SimulatorCommandCancellation
    ) throws -> PhysicalDeviceCommandResult {
        let outputPipe = try ChildPipe()
        let child: SpawnedChildProcess
        do {
            child = try ChildProcessSpawn.spawn(
                executableURL: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: nil,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor: .nullDevice,
                    AgentChildProcessDefaults.standardOutputDescriptor: .inherited(outputPipe.writeEnd),
                    // Version and capability replies are stdout protocols. Python can emit an
                    // unrelated LibreSSL warning on stderr; merging it would corrupt both the
                    // semantic-version parser and the JSON decoder for an otherwise healthy tool.
                    AgentChildProcessDefaults.standardErrorDescriptor: .nullDevice,
                ]
            )
        } catch {
            outputPipe.closeBothEnds()
            throw error
        }
        cancellation.attach(child)

        outputPipe.closeWriteEnd()
        let output = outputPipe.takeReadHandle()
        let deadline = ChildProcessDeadline(
            child: child,
            timeout: timeout,
            terminationGrace: BoundedChildDefaults.terminationGrace
        )
        let capture = BoundedChildProcess.captureSuffix(
            from: output,
            maximumBytes: maximumOutputBytes
        )
        child.waitUntilExit()
        let timedOut = deadline.complete()
        cancellation.complete()
        try? output.close()

        return PhysicalDeviceCommandResult(
            output: capture.data,
            outputWasTruncated: capture.wasTruncated,
            termination: timedOut ? .timedOut : .exited(child.terminationStatus)
        )
    }
}

/// Apple owns discovery. Modern phones use pymobiledevice3's DVT screenshot route while older
/// phones retain the libimobiledevice fallback. Both are resolved explicitly because a GUI
/// application does not inherit an interactive shell PATH.
final class DevicectlPhysicalDeviceControl: PhysicalDeviceControlling, @unchecked Sendable {
    private let runner: any PhysicalDeviceCommandRunning
    private let queue: SimulatorCommandQueue
    private let temporaryDirectory: URL
    private let environment: [String: String]
    private let screenshotExecutable: URL?
    private let capabilityProbeExecutable: @Sendable () -> URL?
    private let preparedDeviceIDs = OSAllocatedUnfairLock(
        initialState: Set<PhysicalDeviceID>()
    )
    private let screenshotBackends = OSAllocatedUnfairLock(
        initialState: [PhysicalDeviceID: PhysicalDeviceScreenshotBackend]()
    )

    init(
        runner: any PhysicalDeviceCommandRunning = BoundedPhysicalDeviceCommandRunner(),
        queue: DispatchQueue = DispatchQueue(
            label: PhysicalDeviceDefaults.commandQueueLabel,
            qos: .userInitiated
        ),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        screenshotExecutable: URL? = PhysicalDeviceToolLocator.ideviceScreenshot(),
        capabilityProbeExecutable: @escaping @Sendable () -> URL? = {
            PhysicalDeviceToolLocator.pymobiledevice3()
        }
    ) {
        self.runner = runner
        self.queue = SimulatorCommandQueue(queue: queue)
        self.temporaryDirectory = temporaryDirectory
        self.environment = environment
        self.screenshotExecutable = screenshotExecutable
        self.capabilityProbeExecutable = capabilityProbeExecutable
    }

    func availableDevices() async throws -> [PhysicalDevice] {
        try await perform { [temporaryDirectory, environment] runner, cancellation in
            let directory = temporaryDirectory.appendingPathComponent(
                "threading-physical-devices-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            let jsonURL = directory.appendingPathComponent("devices.json")
            let result = try runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "devicectl", "list", "devices", "--quiet",
                    "--timeout", String(Int(PhysicalDeviceDefaults.discoveryTimeout)),
                    "--json-output", jsonURL.path,
                ],
                timeout: PhysicalDeviceDefaults.discoveryTimeout + 2,
                maximumOutputBytes: PhysicalDeviceDefaults.maximumCommandOutputBytes,
                environment: environment,
                cancellation: cancellation
            )
            try Self.requireSuccess(result, operation: "discovery")
            let data = try Self.boundedFileData(
                at: jsonURL,
                maximumBytes: PhysicalDeviceDefaults.maximumCommandOutputBytes * 8,
                operation: "discovery"
            )
            let devices = try PhysicalDeviceCatalog.decodeAvailableIPhones(from: data)
            guard !devices.isEmpty else { throw PhysicalDeviceControlError.noAvailableIPhones }
            return devices
        }
    }

    func controlSupport(of device: PhysicalDevice) async throws -> PhysicalDeviceControlSupport {
        try await perform {
            [environment, capabilityProbeExecutable] runner, cancellation in
            guard let capabilityProbeExecutable = capabilityProbeExecutable() else {
                return .unknown(.probeToolUnavailable)
            }
            do {
                let version = try runner.run(
                    executable: capabilityProbeExecutable,
                    arguments: ["--no-color", "version"],
                    timeout: PhysicalDeviceDefaults.probeVersionTimeout,
                    maximumOutputBytes: PhysicalDeviceDefaults.maximumCommandOutputBytes,
                    environment: environment,
                    cancellation: cancellation
                )
                guard let versionData = try Self.probeOutput(
                    version,
                    cancellation: cancellation
                ) else {
                    return .unknown(.probeFailed)
                }
                guard let versionIsSupported = PhysicalDeviceCapabilityProbe.toolVersionIsSupported(
                    versionData
                ) else {
                    return .unknown(.probeFailed)
                }
                guard versionIsSupported else {
                    return .unknown(.probeVersionUnsupported)
                }

                let probeEnvironment = try Self.capabilityProbeEnvironment(
                    inherited: environment,
                    deviceID: device.id
                )
                let mediaResult = try runner.run(
                    executable: capabilityProbeExecutable,
                    arguments: [
                        "--no-color", "developer", "core-device", "display",
                        "get-media-support-info", "--native",
                    ],
                    timeout: PhysicalDeviceDefaults.capabilityProbeTimeout,
                    maximumOutputBytes: PhysicalDeviceDefaults.maximumCommandOutputBytes,
                    environment: probeEnvironment,
                    cancellation: cancellation
                )
                guard let mediaData = try Self.probeOutput(
                    mediaResult,
                    cancellation: cancellation
                ) else {
                    return .unknown(.probeFailed)
                }
                let supportedMediaFeatures = try PhysicalDeviceCapabilityProbe
                    .supportedMediaFeatures(from: mediaData)
                guard supportedMediaFeatures > 0 else {
                    return .unavailable(.mediaStreamingUnavailable)
                }

                let touchResult = try runner.run(
                    executable: capabilityProbeExecutable,
                    arguments: [
                        "--no-color", "developer", "core-device",
                        "universal-hid-service", "list-connected", "--native",
                    ],
                    timeout: PhysicalDeviceDefaults.capabilityProbeTimeout,
                    maximumOutputBytes: PhysicalDeviceDefaults.maximumCommandOutputBytes,
                    environment: probeEnvironment,
                    cancellation: cancellation
                )
                guard let touchData = try Self.probeOutput(
                    touchResult,
                    cancellation: cancellation
                ) else {
                    return .unknown(.probeFailed)
                }
                guard try PhysicalDeviceCapabilityProbe.hasMainTouchscreen(from: touchData) else {
                    return .unavailable(.mainTouchscreenUnavailable)
                }
                return .available(supportedMediaFeatures: supportedMediaFeatures)
            } catch PhysicalDeviceControlError.cancelled {
                throw PhysicalDeviceControlError.cancelled
            } catch is CancellationError {
                throw PhysicalDeviceControlError.cancelled
            } catch {
                return .unknown(.probeFailed)
            }
        }
    }

    func prepareControl(of device: PhysicalDevice) async throws {
        guard device.connection == .usb else {
            throw PhysicalDeviceControlError.controlPreparationRequiresUSB
        }
        guard let executable = capabilityProbeExecutable() else {
            throw PhysicalDeviceControlError.controlToolUnavailable
        }
        try await perform { [environment] runner, cancellation in
            let result = try runner.run(
                executable: executable,
                arguments: ["--no-color", "mounter", "auto-mount", "--native"],
                timeout: PhysicalDeviceDefaults.controlPreparationTimeout,
                maximumOutputBytes: PhysicalDeviceDefaults.maximumCommandOutputBytes,
                environment: try Self.capabilityProbeEnvironment(
                    inherited: environment,
                    deviceID: device.id
                ),
                cancellation: cancellation
            )
            try Self.requireSuccess(result, operation: "control preparation")
        }
    }

    func sendInput(_ input: PhysicalDeviceInput, to device: PhysicalDevice) async throws {
        guard let executable = capabilityProbeExecutable() else {
            throw PhysicalDeviceControlError.controlToolUnavailable
        }
        let arguments = try Self.inputArguments(input)
        try await perform { [environment] runner, cancellation in
            let result = try runner.run(
                executable: executable,
                arguments: arguments,
                timeout: PhysicalDeviceDefaults.inputTimeout,
                maximumOutputBytes: PhysicalDeviceDefaults.maximumCommandOutputBytes,
                environment: try Self.capabilityProbeEnvironment(
                    inherited: environment,
                    deviceID: device.id
                ),
                cancellation: cancellation
            )
            try Self.requireSuccess(result, operation: "input")
        }
    }

    func screenshot(of device: PhysicalDevice) async throws -> Data {
        let modernExecutable = capabilityProbeExecutable()
        guard screenshotExecutable != nil || modernExecutable != nil else {
            throw PhysicalDeviceControlError.screenshotToolUnavailable
        }
        return try await perform {
            [
                temporaryDirectory,
                preparedDeviceIDs,
                screenshotBackends,
                environment,
                screenshotExecutable,
                modernExecutable,
            ] runner, cancellation in
            let directory = temporaryDirectory.appendingPathComponent(
                "threading-physical-screenshot-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            do {
                try Self.prepareDeveloperServicesIfNeeded(
                    for: device.id,
                    preparedDeviceIDs: preparedDeviceIDs,
                    runner: runner,
                    environment: environment,
                    cancellation: cancellation
                )

                let imageURL = directory.appendingPathComponent("screen.png")
                let cachedBackend = screenshotBackends.withLock { $0[device.id] }
                let candidates = Self.screenshotBackendCandidates(
                    for: device,
                    cached: cachedBackend,
                    legacyExecutable: screenshotExecutable,
                    modernExecutable: modernExecutable
                )
                var lastFailure: Error?
                var attemptedBackend = false
                for backend in candidates {
                    do {
                        if case .dvt(let executable) = backend,
                           backend != cachedBackend,
                           try !Self.isSupportedPymobiledevice3(
                               executable,
                               runner: runner,
                               environment: environment,
                               cancellation: cancellation
                           ) {
                            continue
                        }
                        attemptedBackend = true
                        let data = try Self.captureScreenshot(
                            with: backend,
                            of: device,
                            at: imageURL,
                            runner: runner,
                            environment: environment,
                            cancellation: cancellation
                        )
                        screenshotBackends.withLock { $0[device.id] = backend }
                        return data
                    } catch PhysicalDeviceControlError.cancelled {
                        throw PhysicalDeviceControlError.cancelled
                    } catch is CancellationError {
                        throw PhysicalDeviceControlError.cancelled
                    } catch {
                        lastFailure = error
                    }
                }
                if attemptedBackend, let lastFailure { throw lastFailure }
                throw PhysicalDeviceControlError.screenshotToolUnavailable
            } catch {
                // A disconnect can unmount the DDI. The next explicit retry must re-establish
                // developer services instead of trusting a stale process-local success.
                _ = preparedDeviceIDs.withLock { $0.remove(device.id) }
                _ = screenshotBackends.withLock { $0.removeValue(forKey: device.id) }
                throw error
            }
        }
    }

    private static func screenshotBackendCandidates(
        for device: PhysicalDevice,
        cached: PhysicalDeviceScreenshotBackend?,
        legacyExecutable: URL?,
        modernExecutable: URL?
    ) -> [PhysicalDeviceScreenshotBackend] {
        let legacy = legacyExecutable.map(PhysicalDeviceScreenshotBackend.legacy)
        let modern = modernExecutable.map(PhysicalDeviceScreenshotBackend.dvt)
        let majorVersion = Int(device.osVersion.split(separator: ".", maxSplits: 1).first ?? "")
        let available = (majorVersion.map { $0 >= 27 } == true
            ? [modern]
            : [legacy, modern])
            .compactMap { $0 }
        let reusableCachedBackend = cached.flatMap { backend in
            available.contains(backend) ? backend : nil
        }
        let prioritized = reusableCachedBackend.map { [$0] + available } ?? available
        return prioritized.reduce(into: []) { result, backend in
            if !result.contains(backend) { result.append(backend) }
        }
    }

    private static func isSupportedPymobiledevice3(
        _ executable: URL,
        runner: any PhysicalDeviceCommandRunning,
        environment: [String: String],
        cancellation: SimulatorCommandCancellation
    ) throws -> Bool {
        let result = try runner.run(
            executable: executable,
            arguments: ["--no-color", "version"],
            timeout: PhysicalDeviceDefaults.probeVersionTimeout,
            maximumOutputBytes: PhysicalDeviceDefaults.maximumCommandOutputBytes,
            environment: environment,
            cancellation: cancellation
        )
        guard let data = try probeOutput(result, cancellation: cancellation) else { return false }
        return PhysicalDeviceCapabilityProbe.toolVersionIsSupported(data) == true
    }

    private static func captureScreenshot(
        with backend: PhysicalDeviceScreenshotBackend,
        of device: PhysicalDevice,
        at imageURL: URL,
        runner: any PhysicalDeviceCommandRunning,
        environment: [String: String],
        cancellation: SimulatorCommandCancellation
    ) throws -> Data {
        try? FileManager.default.removeItem(at: imageURL)

        let command: (executable: URL, arguments: [String], environment: [String: String])
        switch backend {
        case .legacy(let executable):
            var arguments = ["--udid", device.id.rawValue]
            if device.connection == .localNetwork { arguments.append("--network") }
            arguments.append(imageURL.path)
            command = (executable, arguments, environment)
        case .dvt(let executable):
            command = (
                executable,
                ["--no-color", "developer", "dvt", "screenshot", "--native", imageURL.path],
                try capabilityProbeEnvironment(inherited: environment, deviceID: device.id)
            )
        }

        let result = try runner.run(
            executable: command.executable,
            arguments: command.arguments,
            timeout: PhysicalDeviceDefaults.screenshotTimeout,
            maximumOutputBytes: PhysicalDeviceDefaults.maximumCommandOutputBytes,
            environment: command.environment,
            cancellation: cancellation
        )
        try requireSuccess(result, operation: "screenshot")
        let data = try boundedFileData(
            at: imageURL,
            maximumBytes: PhysicalDeviceDefaults.maximumScreenshotBytes,
            operation: "screenshot"
        )
        guard data.starts(with: PhysicalDeviceDefaults.pngSignature) else {
            throw PhysicalDeviceControlError.invalidScreenshot
        }
        return data
    }

    private static func prepareDeveloperServicesIfNeeded(
        for deviceID: PhysicalDeviceID,
        preparedDeviceIDs: OSAllocatedUnfairLock<Set<PhysicalDeviceID>>,
        runner: any PhysicalDeviceCommandRunning,
        environment: [String: String],
        cancellation: SimulatorCommandCancellation
    ) throws {
        let alreadyPrepared = preparedDeviceIDs.withLock { $0.contains(deviceID) }
        guard !alreadyPrepared else { return }

        let result = try runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl", "device", "info", "ddiServices",
                "--device", deviceID.rawValue,
                "--auto-mount-ddis", "--quiet",
                "--timeout", String(Int(PhysicalDeviceDefaults.developerServicesTimeout)),
            ],
            timeout: PhysicalDeviceDefaults.developerServicesTimeout + 2,
            maximumOutputBytes: PhysicalDeviceDefaults.maximumCommandOutputBytes,
            environment: environment,
            cancellation: cancellation
        )
        try requireSuccess(result, operation: "developer-services preparation")
        _ = preparedDeviceIDs.withLock { $0.insert(deviceID) }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (
            any PhysicalDeviceCommandRunning,
            SimulatorCommandCancellation
        ) throws -> Value
    ) async throws -> Value {
        let cancellation = SimulatorCommandCancellation()
        return try await withTaskCancellationHandler {
            try await queue.perform { [runner] in
                guard !cancellation.isCancelled else {
                    throw PhysicalDeviceControlError.cancelled
                }
                return try operation(runner, cancellation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func requireSuccess(
        _ result: PhysicalDeviceCommandResult,
        operation: String
    ) throws {
        if result.outputWasTruncated {
            throw PhysicalDeviceControlError.outputTooLarge(operation: operation)
        }
        switch result.termination {
        case .timedOut:
            throw PhysicalDeviceControlError.timedOut(operation: operation)
        case .exited(0):
            return
        case .exited:
            let detail = String(decoding: result.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PhysicalDeviceControlError.commandFailed(
                operation: operation,
                detail: detail.isEmpty ? "The physical-device \(operation) failed." : detail
            )
        }
    }

    private static func probeOutput(
        _ result: PhysicalDeviceCommandResult,
        cancellation: SimulatorCommandCancellation
    ) throws -> Data? {
        guard !cancellation.isCancelled else {
            throw PhysicalDeviceControlError.cancelled
        }
        guard !result.outputWasTruncated else { return nil }
        guard case .exited(0) = result.termination else { return nil }
        return result.output
    }

    private static func capabilityProbeEnvironment(
        inherited: [String: String],
        deviceID: PhysicalDeviceID
    ) throws -> [String: String] {
        var result = try Pymobiledevice3RuntimeEnvironment.prepare(inherited: inherited)
        result["PYMOBILEDEVICE3_UDID"] = deviceID.rawValue
        result.removeValue(forKey: "PYMOBILEDEVICE3_TUNNEL")
        result.removeValue(forKey: "PYMOBILEDEVICE3_USERSPACE")
        result.removeValue(forKey: "PYMOBILEDEVICE3_NATIVE")
        return result
    }

    private static func inputArguments(_ input: PhysicalDeviceInput) throws -> [String] {
        let prefix = [
            "--no-color", "developer", "core-device", "universal-hid-service",
        ]
        switch input {
        case .tap(let x, let y):
            return prefix + [
                "tap", try hidCoordinate(x), try hidCoordinate(y), "--native",
            ]
        case .drag(let fromX, let fromY, let toX, let toY):
            return prefix + [
                "drag",
                try hidCoordinate(fromX), try hidCoordinate(fromY),
                try hidCoordinate(toX), try hidCoordinate(toY),
                "--steps", String(PhysicalDeviceDefaults.dragSteps),
                "--duration", String(PhysicalDeviceDefaults.dragDuration),
                "--native",
            ]
        }
    }

    private static func hidCoordinate(_ normalized: Double) throws -> String {
        guard normalized.isFinite, (0...1).contains(normalized) else {
            throw PhysicalDeviceControlError.invalidInput
        }
        return String(Int((normalized * Double(PhysicalDeviceDefaults.hidCoordinateMaximum)).rounded()))
    }

    private static func boundedFileData(
        at url: URL,
        maximumBytes: Int,
        operation: String
    ) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw PhysicalDeviceControlError.invalidResponse(
                "The physical-device \(operation) produced no readable file."
            )
        }
        guard size.intValue <= maximumBytes else {
            throw PhysicalDeviceControlError.outputTooLarge(operation: operation)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}

private enum PhysicalDeviceScreenshotBackend: Equatable, Sendable {
    case legacy(URL)
    case dvt(URL)
}

enum PhysicalDeviceToolLocator {
    private static let capabilityProbeOverride = "THREADING_PHYSICAL_DEVICE_PROBE_PATH"

    static func ideviceScreenshot(
        fileManager: FileManager = .default
    ) -> URL? {
        [
            "/opt/homebrew/bin/idevicescreenshot",
            "/usr/local/bin/idevicescreenshot",
            "/usr/bin/idevicescreenshot",
        ]
        .map(URL.init(fileURLWithPath:))
        .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    static func pymobiledevice3(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        managedExecutable: URL = Pymobiledevice3ManagedTool.executable(),
        fileManager: FileManager = .default
    ) -> URL? {
        if let configuredPath = environment[capabilityProbeOverride],
           configuredPath.hasPrefix("/") {
            let configured = URL(fileURLWithPath: configuredPath)
            if fileManager.isExecutableFile(atPath: configured.path) { return configured }
        }

        return ([managedExecutable.path] + [
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3",
            "/usr/bin/pymobiledevice3",
        ])
        .map(URL.init(fileURLWithPath:))
        .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }
}
