import Foundation

// MARK: - Public capability

protocol SimulatorControlling: Sendable {
    func availableDevices() async throws -> [SimulatorDevice]
    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease
    func installAndLaunch(
        applicationURL: URL,
        bundleIdentifier: String,
        on deviceID: SimulatorDeviceID,
        arguments: [String]
    ) async throws -> SimulatorLaunchReceipt
    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data
    func setAppearance(dark: Bool, on deviceID: SimulatorDeviceID) async throws
    func release(_ lease: SimulatorDeviceLease) async throws
}

extension SimulatorControlling {
    // Default no-op keeps test doubles that only exercise the lease/stream paths simple; the real
    // simctl control overrides it.
    func setAppearance(dark: Bool, on deviceID: SimulatorDeviceID) async throws {}
}

enum SimulatorDeviceBootOwnership: String, Equatable, Codable, Sendable {
    /// The device was already running before Threading adopted it. Threading must not shut it down.
    case user
    /// Threading booted the device for this lease and may shut it down when the lease is released.
    case threading
}

struct SimulatorDeviceLease: Equatable, Sendable {
    let device: SimulatorDevice
    let bootOwnership: SimulatorDeviceBootOwnership
    /// Opaque identity issued by the control plane. A refreshed lease can replace its device
    /// snapshot without making releases from another pane's older snapshot unrecognisable.
    let capabilityID: UUID

    init(
        device: SimulatorDevice,
        bootOwnership: SimulatorDeviceBootOwnership,
        capabilityID: UUID = UUID()
    ) {
        self.device = device
        self.bootOwnership = bootOwnership
        self.capabilityID = capabilityID
    }
}

struct SimulatorLaunchReceipt: Equatable, Sendable {
    let deviceID: SimulatorDeviceID
    let bundleIdentifier: String
    let processIdentifier: Int32?
}

enum SimulatorControlError: LocalizedError, Equatable, Sendable {
    case launchFailed(String)
    case commandFailed(operation: String, detail: String)
    case timedOut(operation: String)
    case cancelled
    case outputTooLarge(operation: String)
    case invalidResponse(String)
    case tooManyDevices(maximum: Int)
    case noAvailableIOSDevices
    case deviceNotFound(SimulatorDeviceID)
    case invalidApplication(String)
    case invalidBundleIdentifier
    case tooManyLaunchArguments(maximum: Int)
    case launchArgumentTooLong(maximum: Int)
    case invalidScreenshot

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): return detail
        case .commandFailed(_, let detail): return detail
        case .timedOut(let operation): return "Simulator \(operation) took too long."
        case .cancelled: return "The Simulator operation was cancelled."
        case .outputTooLarge(let operation):
            return "Simulator \(operation) returned more data than Threading can safely read."
        case .invalidResponse(let detail): return detail
        case .tooManyDevices(let maximum):
            return "More than \(maximum) iOS Simulator devices are installed."
        case .noAvailableIOSDevices:
            return "No available iOS Simulator device is installed in Xcode."
        case .deviceNotFound(let id):
            return "The iOS Simulator device \(id.rawValue) is no longer available."
        case .invalidApplication(let detail): return detail
        case .invalidBundleIdentifier: return "The application bundle identifier is invalid."
        case .tooManyLaunchArguments(let maximum):
            return "A Simulator app can receive at most \(maximum) launch arguments here."
        case .launchArgumentTooLong(let maximum):
            return "A Simulator launch argument exceeds \(maximum) characters."
        case .invalidScreenshot:
            return "CoreSimulator did not return a valid PNG screenshot."
        }
    }
}

// MARK: - simctl implementation

/// The public CoreSimulator control plane. All blocking child work is serialized on `commandQueue`;
/// AppKit and agent-command callers await this capability without ever running `simctl` on main.
final class SimctlSimulatorControl: SimulatorControlling, @unchecked Sendable {
    private let runner: any SimulatorCommandRunning
    private let commandQueue: SimulatorCommandQueue
    private let screenshotTemporaryDirectory: URL
    private let maximumScreenshotBytes: Int

    init(
        runner: any SimulatorCommandRunning = XcrunSimulatorCommandRunner(),
        queue: DispatchQueue = DispatchQueue(
            label: SimulatorControlDefaults.commandQueueLabel,
            qos: .userInitiated
        ),
        screenshotTemporaryDirectory: URL = FileManager.default.temporaryDirectory,
        maximumScreenshotBytes: Int = SimulatorControlDefaults.maximumScreenshotBytes
    ) {
        precondition(maximumScreenshotBytes >= SimulatorControlDefaults.pngSignature.count)
        self.runner = runner
        self.commandQueue = SimulatorCommandQueue(queue: queue)
        self.screenshotTemporaryDirectory = screenshotTemporaryDirectory
        self.maximumScreenshotBytes = maximumScreenshotBytes
    }

    func availableDevices() async throws -> [SimulatorDevice] {
        try await perform { runner, cancellation in
            try Self.availableDevices(using: runner, cancellation: cancellation)
        }
    }

    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        try await perform { runner, cancellation in
            let devices = try Self.availableDevices(using: runner, cancellation: cancellation)
            guard !devices.isEmpty else { throw SimulatorControlError.noAvailableIOSDevices }

            let device: SimulatorDevice
            if let deviceID {
                guard let requested = devices.first(where: { $0.id == deviceID }) else {
                    throw SimulatorControlError.deviceNotFound(deviceID)
                }
                device = requested
            } else {
                device = devices[0]
            }

            guard !device.state.isBooted else {
                return SimulatorDeviceLease(device: device, bootOwnership: .user)
            }

            _ = try Self.run(
                ["bootstatus", device.id.rawValue, "-b"],
                operation: "boot",
                timeout: SimulatorControlDefaults.bootTimeout,
                maximumOutputBytes: SimulatorControlDefaults.maximumCommandOutputBytes,
                capture: .combined,
                using: runner,
                cancellation: cancellation
            )
            return SimulatorDeviceLease(
                device: device.withState(.booted),
                bootOwnership: .threading
            )
        }
    }

    func installAndLaunch(
        applicationURL: URL,
        bundleIdentifier: String,
        on deviceID: SimulatorDeviceID,
        arguments: [String] = []
    ) async throws -> SimulatorLaunchReceipt {
        try await perform { runner, cancellation in
            try Self.validateApplication(applicationURL)
            let bundleIdentifier = try Self.validatedBundleIdentifier(bundleIdentifier)
            try Self.validateLaunchArguments(arguments)

            _ = try Self.run(
                ["install", deviceID.rawValue, applicationURL.path],
                operation: "install",
                timeout: SimulatorControlDefaults.installTimeout,
                maximumOutputBytes: SimulatorControlDefaults.maximumCommandOutputBytes,
                capture: .combined,
                using: runner,
                cancellation: cancellation
            )
            let output = try Self.run(
                [
                    "launch",
                    "--terminate-running-process",
                    deviceID.rawValue,
                    bundleIdentifier
                ] + arguments,
                operation: "launch",
                timeout: SimulatorControlDefaults.launchTimeout,
                maximumOutputBytes: SimulatorControlDefaults.maximumCommandOutputBytes,
                capture: .combined,
                using: runner,
                cancellation: cancellation
            )
            return SimulatorLaunchReceipt(
                deviceID: deviceID,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: Self.processIdentifier(fromLaunchOutput: output)
            )
        }
    }

    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data {
        let screenshotTemporaryDirectory = screenshotTemporaryDirectory
        let maximumScreenshotBytes = maximumScreenshotBytes
        return try await perform { runner, cancellation in
            let capture = try Self.makeScreenshotCapture(
                in: screenshotTemporaryDirectory
            )
            defer { try? FileManager.default.removeItem(at: capture.directoryURL) }

            _ = try Self.run(
                [
                    "io", deviceID.rawValue, "screenshot", "--type=png",
                    capture.outputURL.path
                ],
                operation: "screenshot",
                timeout: SimulatorControlDefaults.screenshotTimeout,
                maximumOutputBytes: SimulatorControlDefaults.maximumCommandOutputBytes,
                capture: .combined,
                using: runner,
                cancellation: cancellation
            )
            let data: Data
            do {
                data = try BoundedFileReader.read(
                    capture.outputURL,
                    maximumBytes: maximumScreenshotBytes
                )
            } catch let error as BoundedFileReadError {
                switch error {
                case .exceedsLimit:
                    throw SimulatorControlError.outputTooLarge(operation: "screenshot")
                case .notRegularFile:
                    throw SimulatorControlError.invalidScreenshot
                }
            } catch {
                throw SimulatorControlError.invalidResponse(
                    "Threading could not read the Simulator screenshot: \(error.localizedDescription)"
                )
            }
            guard data.starts(with: SimulatorControlDefaults.pngSignature) else {
                throw SimulatorControlError.invalidScreenshot
            }
            return data
        }
    }

    func setAppearance(dark: Bool, on deviceID: SimulatorDeviceID) async throws {
        try await perform { runner, cancellation in
            _ = try Self.run(
                ["ui", deviceID.rawValue, "appearance", dark ? "dark" : "light"],
                operation: "appearance",
                timeout: SimulatorControlDefaults.shutdownTimeout,
                maximumOutputBytes: SimulatorControlDefaults.maximumCommandOutputBytes,
                capture: .combined,
                using: runner,
                cancellation: cancellation
            )
        }
    }

    func release(_ lease: SimulatorDeviceLease) async throws {
        guard lease.bootOwnership == .threading else { return }
        try await perform { runner, cancellation in
            _ = try Self.run(
                ["shutdown", lease.device.id.rawValue],
                operation: "shutdown",
                timeout: SimulatorControlDefaults.shutdownTimeout,
                maximumOutputBytes: SimulatorControlDefaults.maximumCommandOutputBytes,
                capture: .combined,
                using: runner,
                cancellation: cancellation
            )
        }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (
            any SimulatorCommandRunning,
            SimulatorCommandCancellation
        ) throws -> Value
    ) async throws -> Value {
        let cancellation = SimulatorCommandCancellation()
        return try await withTaskCancellationHandler {
            try await commandQueue.perform { [runner] in
                guard !cancellation.isCancelled else { throw SimulatorControlError.cancelled }
                return try operation(runner, cancellation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func availableDevices(
        using runner: any SimulatorCommandRunning,
        cancellation: SimulatorCommandCancellation
    ) throws -> [SimulatorDevice] {
        let output = try run(
            ["list", "devices", "available", "--json"],
            operation: "device discovery",
            timeout: SimulatorControlDefaults.listTimeout,
            maximumOutputBytes: SimulatorControlDefaults.maximumDeviceListBytes,
            capture: .standardOutput,
            using: runner,
            cancellation: cancellation
        )
        return try SimulatorDeviceCatalog.decodeAvailableIOSDevices(from: output)
    }

    private static func makeScreenshotCapture(
        in temporaryDirectory: URL
    ) throws -> (directoryURL: URL, outputURL: URL) {
        guard temporaryDirectory.isFileURL else {
            throw SimulatorControlError.invalidResponse(
                "Threading's Simulator screenshot location is not a local directory."
            )
        }
        let directoryURL = temporaryDirectory.appendingPathComponent(
            "codes.threading.simulator-capture-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SimulatorControlError.invalidResponse(
                "Threading could not prepare a private Simulator screenshot location: "
                    + error.localizedDescription
            )
        }
        return (
            directoryURL: directoryURL,
            outputURL: directoryURL.appendingPathComponent("frame.png", isDirectory: false)
        )
    }

    private static func run(
        _ arguments: [String],
        operation: String,
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        capture: SimulatorCommandCapture,
        using runner: any SimulatorCommandRunning,
        cancellation: SimulatorCommandCancellation
    ) throws -> Data {
        let result: SimulatorCommandResult
        do {
            result = try runner.run(
                arguments,
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes,
                capture: capture,
                cancellation: cancellation
            )
        } catch let error as SimulatorControlError {
            throw error
        } catch {
            throw SimulatorControlError.launchFailed(error.localizedDescription)
        }

        if cancellation.isCancelled { throw SimulatorControlError.cancelled }
        if result.outputWasTruncated {
            throw SimulatorControlError.outputTooLarge(operation: operation)
        }
        switch result.termination {
        case .timedOut:
            throw SimulatorControlError.timedOut(operation: operation)
        case .exited(let status) where status != 0:
            let detail = String(data: result.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let failureDescription: String
            if let detail, !detail.isEmpty {
                failureDescription = detail
            } else {
                failureDescription = "Simulator \(operation) failed with status \(status)."
            }
            throw SimulatorControlError.commandFailed(
                operation: operation,
                detail: failureDescription
            )
        case .exited:
            return result.output
        }
    }

    private static func validateApplication(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SimulatorControlError.invalidApplication(
                "Choose a built .app bundle to install in the iOS Simulator."
            )
        }
    }

    private static func validatedBundleIdentifier(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty,
              result.count <= SimulatorControlDefaults.maximumBundleIdentifierCharacters,
              !result.contains("\0") else {
            throw SimulatorControlError.invalidBundleIdentifier
        }
        return result
    }

    private static func validateLaunchArguments(_ arguments: [String]) throws {
        guard arguments.count <= SimulatorControlDefaults.maximumLaunchArgumentCount else {
            throw SimulatorControlError.tooManyLaunchArguments(
                maximum: SimulatorControlDefaults.maximumLaunchArgumentCount
            )
        }
        guard arguments.allSatisfy({
            $0.count <= SimulatorControlDefaults.maximumLaunchArgumentCharacters
                && !$0.contains("\0")
        }) else {
            throw SimulatorControlError.launchArgumentTooLong(
                maximum: SimulatorControlDefaults.maximumLaunchArgumentCharacters
            )
        }
    }

    private static func processIdentifier(fromLaunchOutput data: Data) -> Int32? {
        guard let output = String(data: data, encoding: .utf8),
              let suffix = output.split(separator: ":").last,
              let processIdentifier = Int32(suffix.trimmingCharacters(in: .whitespacesAndNewlines)),
              processIdentifier > 0 else { return nil }
        return processIdentifier
    }
}

enum SimulatorControlDefaults {
    static let commandQueueLabel = "codes.threading.simulator-command"
    static let iosRuntimePrefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
    static let maximumDeviceCount = 512
    static let maximumDeviceListBytes = 4 * 1024 * 1024
    static let maximumCommandOutputBytes = 256 * 1024
    static let maximumScreenshotBytes = 64 * 1024 * 1024
    static let maximumBundleIdentifierCharacters = 255
    static let maximumLaunchArgumentCount = 64
    static let maximumLaunchArgumentCharacters = 4_096
    static let listTimeout: TimeInterval = 15
    static let bootTimeout: TimeInterval = 120
    static let installTimeout: TimeInterval = 120
    static let launchTimeout: TimeInterval = 30
    static let screenshotTimeout: TimeInterval = 15
    static let shutdownTimeout: TimeInterval = 30
    static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}
