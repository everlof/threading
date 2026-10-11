import Foundation
import ThreadingAndroidKit

/// Starts an emulator process Threading will own. A seam so the lifecycle can be tested without
/// booting a virtual machine.
protocol AndroidEmulatorLaunching: Sendable {
    func launch(executable: URL, arguments: [String], logURL: URL) throws -> SpawnedChildProcess
}

struct AndroidEmulatorLauncher: AndroidEmulatorLaunching {
    func launch(executable: URL, arguments: [String], logURL: URL) throws -> SpawnedChildProcess {
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        // Its own process group, stdin closed, output to a private log so a failed boot can say why.
        return try ChildProcessSpawn.spawn(
            executableURL: executable,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil,
            descriptors: [
                AgentChildProcessDefaults.standardInputDescriptor: .nullDevice,
                AgentChildProcessDefaults.standardOutputDescriptor: .inherited(log.fileDescriptor),
                AgentChildProcessDefaults.standardErrorDescriptor: .inherited(log.fileDescriptor),
            ]
        )
    }
}

/// The Android half of the Simulator workspace's lifecycle plane: emulators (AVDs) and USB devices
/// reached through the SDK's own `adb` and `emulator`, with the same lease rule as CoreSimulator —
/// a device Threading found running is the user's and is never stopped; an emulator Threading
/// started may be stopped when its lease is released. A phone is never rebooted or shut down.
///
/// Every command runs on one serial queue off main, in its own process group, under a deadline and
/// cancellation, with bounded output, exactly as `SimctlSimulatorControl` does.
final class AndroidDeviceControl: SimulatorControlling, @unchecked Sendable {
    private let sdk: AndroidSDK
    private let adb: any SimulatorCommandRunning
    private let launcher: any AndroidEmulatorLaunching
    private let directory: AndroidDeviceDirectory
    private let runningRecords: @Sendable () -> [String: RunningEmulatorRecord]
    private let commandQueue: SimulatorCommandQueue
    private let temporaryDirectory: URL

    /// The one production instance, shared by the routing control and the stream coordinator so
    /// both serialize on the same command queue.
    static let shared = makeIfInstalled()

    /// The production control, or nil on a Mac without the Android SDK — in which case the
    /// workspace simply offers no Android devices.
    static func makeIfInstalled(directory: AndroidDeviceDirectory = .shared) -> AndroidDeviceControl? {
        guard let sdk = directory.sdk else { return nil }
        return AndroidDeviceControl(sdk: sdk, directory: directory)
    }

    init(
        sdk: AndroidSDK,
        adb: (any SimulatorCommandRunning)? = nil,
        launcher: any AndroidEmulatorLaunching = AndroidEmulatorLauncher(),
        directory: AndroidDeviceDirectory = .shared,
        runningRecords: (@Sendable () -> [String: RunningEmulatorRecord])? = nil,
        queue: DispatchQueue = DispatchQueue(label: AndroidControlDefaults.commandQueueLabel, qos: .userInitiated),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.sdk = sdk
        self.adb = adb ?? XcrunSimulatorCommandRunner(executable: sdk.adb.path, prefixArguments: [])
        self.launcher = launcher
        self.directory = directory
        self.runningRecords = runningRecords ?? { [directory] in directory.runningEmulatorRecords() }
        self.commandQueue = SimulatorCommandQueue(queue: queue)
        self.temporaryDirectory = temporaryDirectory
    }

    // MARK: - SimulatorControlling

    func availableDevices() async throws -> [SimulatorDevice] {
        try await perform { [self] cancellation in try catalogue(cancellation: cancellation).devices }
    }

    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        try await perform { [self] cancellation in
            let catalogue = try catalogue(cancellation: cancellation)
            let device: SimulatorDevice
            if let deviceID {
                guard let found = catalogue.devices.first(where: { $0.id == deviceID }) else {
                    throw SimulatorControlError.deviceNotFound(deviceID)
                }
                device = found
            } else {
                guard let first = catalogue.devices.first(where: \.isAdoptable) else {
                    throw SimulatorControlError.noAvailableIOSDevices
                }
                device = first
            }
            if let reason = device.unavailableReason {
                throw SimulatorControlError.deviceUnavailable(device.id, detail: reason)
            }
            if device.state.isBooted { return SimulatorDeviceLease(device: device, bootOwnership: .user) }
            guard case .androidEmulator = device.platform, let avdName = device.id.androidName else {
                throw SimulatorControlError.deviceUnavailable(device.id, detail: "The device is not connected.")
            }
            try boot(avdName: avdName, device: device, cancellation: cancellation)
            return SimulatorDeviceLease(device: device.withState(.booted), bootOwnership: .threading)
        }
    }

    func installAndLaunch(
        applicationURL: URL, bundleIdentifier: String, on deviceID: SimulatorDeviceID, arguments: [String]
    ) async throws -> SimulatorLaunchReceipt {
        try await perform { [self] cancellation in
            try Self.validatePackage(applicationURL)
            let package = try Self.validatedPackageName(bundleIdentifier)
            try Self.validateLaunchArguments(arguments)
            let serial = try target(for: deviceID, cancellation: cancellation).serial
            _ = try run(["-s", serial, "install", "-r", "-t", applicationURL.path], operation: "install",
                        deviceID: deviceID, timeout: AndroidControlDefaults.installTimeout, cancellation: cancellation)
            let resolved = try run(
                ["-s", serial, "shell", "cmd", "package", "resolve-activity", "--brief",
                 "-c", "android.intent.category.LAUNCHER", AndroidShellQuoting.quote(package)],
                operation: "launch", deviceID: deviceID, timeout: AndroidControlDefaults.launchTimeout,
                cancellation: cancellation
            )
            guard let component = Self.launchComponent(from: resolved, package: package) else {
                throw SimulatorControlError.invalidApplication("\(package) has no launcher activity to start.")
            }
            var start = ["-s", serial, "shell", "am", "start", "-W", "-S", "-n", AndroidShellQuoting.quote(component)]
            for (index, argument) in arguments.enumerated() {
                start += ["--es", AndroidShellQuoting.quote(AndroidControlDefaults.launchArgumentExtraPrefix + "\(index)"),
                          AndroidShellQuoting.quote(argument)]
            }
            let output = try run(start, operation: "launch", deviceID: deviceID,
                                 timeout: AndroidControlDefaults.launchTimeout, cancellation: cancellation)
            let text = String(decoding: output, as: UTF8.self)
            if text.contains("Error:") {
                throw SimulatorControlError.commandFailed(operation: "launch", detail: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let pid = try? run(["-s", serial, "shell", "pidof", AndroidShellQuoting.quote(package)], operation: "launch",
                               deviceID: deviceID, timeout: AndroidControlDefaults.propertyTimeout, cancellation: cancellation)
            return SimulatorLaunchReceipt(
                deviceID: deviceID, bundleIdentifier: package,
                processIdentifier: pid.flatMap { output in
                    String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.flatMap { Int32($0) }
                }
            )
        }
    }

    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data {
        try await perform { [self] cancellation in
            let serial = try target(for: deviceID, cancellation: cancellation).serial
            let data = try run(["-s", serial, "exec-out", "screencap", "-p"], operation: "screenshot", deviceID: deviceID,
                               timeout: AndroidControlDefaults.screenshotTimeout,
                               maximumOutputBytes: AndroidControlDefaults.maximumScreenshotBytes,
                               capture: .standardOutput, cancellation: cancellation)
            guard data.starts(with: SimulatorControlDefaults.pngSignature) else { throw SimulatorControlError.invalidScreenshot }
            return data
        }
    }

    func setAppearance(dark: Bool, on deviceID: SimulatorDeviceID) async throws {
        try await perform { [self] cancellation in
            let serial = try target(for: deviceID, cancellation: cancellation).serial
            _ = try run(["-s", serial, "shell", "cmd", "uimode", "night", dark ? "yes" : "no"], operation: "appearance",
                        deviceID: deviceID, timeout: AndroidControlDefaults.propertyTimeout, cancellation: cancellation)
        }
    }

    func release(_ lease: SimulatorDeviceLease) async throws {
        // Only an emulator Threading started is ever stopped; a phone or an adopted emulator is
        // left exactly as it was found.
        guard lease.bootOwnership == .threading, case .androidEmulator = lease.device.platform,
              let avdName = lease.device.id.androidName else { return }
        try await perform { [self] cancellation in
            if let serial = try? target(for: lease.device.id, cancellation: cancellation).serial {
                _ = try? run(["-s", serial, "emu", "kill"], operation: "shutdown", deviceID: lease.device.id,
                             timeout: AndroidControlDefaults.shutdownTimeout, cancellation: cancellation)
            }
            directory.bootedEmulator(avdName)?.process.terminate()
        }
    }

    /// The running device behind an identity, for the stream coordinator.
    func target(for deviceID: SimulatorDeviceID) async throws -> AndroidTarget {
        try await perform { [self] cancellation in try target(for: deviceID, cancellation: cancellation) }
    }

    // MARK: - Catalogue

    private struct Catalogue {
        var devices: [SimulatorDevice]
        var targets: [SimulatorDeviceID: AndroidTarget]
    }

    private func catalogue(cancellation: SimulatorCommandCancellation) throws -> Catalogue {
        let records = runningRecords()
        let adbDevices = try listADBDevices(cancellation: cancellation)
        var targets: [SimulatorDeviceID: AndroidTarget] = [:]
        // Emulators: by discovery record first, then by asking each unexplained emulator its AVD.
        var emulatorSerials: [String: String] = [:]
        for record in records.values { emulatorSerials[record.avdName] = record.adbSerial }
        let known = Set(emulatorSerials.values)
        for device in adbDevices where device.isEmulator && device.state == .device && !known.contains(device.serial) {
            if let id = try? avdIdentifier(serial: device.serial, cancellation: cancellation) {
                emulatorSerials[id] = device.serial
            }
        }
        let onlineSerials = Set(adbDevices.filter { $0.state == .device }.map(\.serial))

        var devices: [SimulatorDevice] = []
        for configuration in installedAVDs() {
            guard let id = SimulatorDeviceID.androidEmulator(avdName: configuration.name) else { continue }
            let serial = emulatorSerials[configuration.name]
            let running = serial.map(onlineSerials.contains) ?? false
            if let serial, running {
                targets[id] = AndroidTarget(
                    deviceID: id, serial: serial, emulator: records[configuration.name],
                    usesThreadingAllowlist: directory.bootedEmulator(configuration.name) != nil
                )
            }
            devices.append(SimulatorDevice(
                id: id, name: configuration.displayName,
                runtimeIdentifier: configuration.apiLevel.map { "android-\($0)" } ?? "android",
                runtimeName: configuration.apiLevel.map(AVDConfiguration.releaseName(apiLevel:)) ?? "Android",
                deviceTypeIdentifier: "android.avd",
                family: configuration.isTablet ? .androidTablet : .androidPhone,
                state: running ? .booted : .shutdown, lastBootedAt: nil,
                unavailableReason: running || sdk.hasEmulator && systemImageInstalled(configuration)
                    ? nil : L10n.string("Its system image is not installed")
            ))
        }

        for device in adbDevices where !device.isEmulator {
            guard let id = SimulatorDeviceID.androidDevice(serial: device.serial) else { continue }
            var runtime = "Android"
            var reason: String?
            switch device.state {
            case .device:
                targets[id] = AndroidTarget(deviceID: id, serial: device.serial, emulator: nil, usesThreadingAllowlist: false)
                if let api = try? apiLevel(serial: device.serial, cancellation: cancellation) {
                    runtime = AVDConfiguration.releaseName(apiLevel: api)
                }
            case .unauthorized: reason = L10n.string("Allow USB debugging on the device")
            case .offline: reason = L10n.string("The device is offline")
            case .other(let state): reason = state
            }
            devices.append(SimulatorDevice(
                id: id, name: device.displayName, runtimeIdentifier: "android-device", runtimeName: runtime,
                deviceTypeIdentifier: "android.usb", family: .androidPhone,
                state: device.state == .device ? .booted : .shutdown, lastBootedAt: nil, unavailableReason: reason
            ))
        }
        devices.sort { lhs, rhs in
            if lhs.state.isBooted != rhs.state.isBooted { return lhs.state.isBooted }
            if lhs.platform != rhs.platform { return lhs.platform == .androidEmulator }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return Catalogue(devices: devices, targets: targets)
    }

    private func target(for deviceID: SimulatorDeviceID, cancellation: SimulatorCommandCancellation) throws -> AndroidTarget {
        if case .androidDevice = deviceID.platform, let serial = deviceID.androidName {
            // A phone's identity is its serial; only its connection needs checking.
            let device = try listADBDevices(cancellation: cancellation).first { $0.serial == serial }
            guard device?.state == .device else {
                throw SimulatorControlError.deviceUnavailable(deviceID, detail: "\(serial) is not connected.")
            }
            return AndroidTarget(deviceID: deviceID, serial: serial, emulator: nil, usesThreadingAllowlist: false)
        }
        guard let target = try catalogue(cancellation: cancellation).targets[deviceID] else {
            throw SimulatorControlError.deviceUnavailable(deviceID, detail: "The emulator is not running.")
        }
        return target
    }

    private func installedAVDs() -> [AVDConfiguration] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sdk.avdHome.path) else { return [] }
        var result: [AVDConfiguration] = []
        for name in names.sorted() where name.hasSuffix(".ini") {
            guard result.count < AndroidControlDefaults.maximumAVDCount else { break }
            let avdName = String(name.dropLast(4))
            let pointer = readBounded(sdk.avdHome.appendingPathComponent(name))
            let path = pointer.flatMap { text in
                text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("path=") }.map { String($0.dropFirst(5)) }
            } ?? sdk.avdHome.appendingPathComponent("\(avdName).avd").path
            guard let config = readBounded(URL(fileURLWithPath: path).appendingPathComponent("config.ini")) else { continue }
            result.append(AVDConfiguration.parse(name: avdName, config: config))
        }
        return result
    }

    private func systemImageInstalled(_ configuration: AVDConfiguration) -> Bool {
        guard let path = configuration.systemImagePath else { return true }
        return FileManager.default.fileExists(atPath: sdk.root.appendingPathComponent(path).path)
    }

    private func readBounded(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: AndroidControlDefaults.maximumConfigBytes)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func listADBDevices(cancellation: SimulatorCommandCancellation) throws -> [ADBDeviceRecord] {
        let output = try run(["devices", "-l"], operation: "device discovery", timeout: AndroidControlDefaults.listTimeout,
                             capture: .standardOutput, cancellation: cancellation)
        do {
            return try ADBDeviceRecord.parse(String(decoding: output, as: UTF8.self),
                                            maximumDevices: AndroidControlDefaults.maximumADBDevices)
        } catch {
            throw SimulatorControlError.tooManyDevices(maximum: AndroidControlDefaults.maximumADBDevices)
        }
    }

    private func avdIdentifier(serial: String, cancellation: SimulatorCommandCancellation) throws -> String? {
        let output = try run(["-s", serial, "emu", "avd", "id"], operation: "device discovery",
                             timeout: AndroidControlDefaults.propertyTimeout, capture: .standardOutput, cancellation: cancellation)
        let first = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return first.flatMap { $0.isEmpty || $0 == "OK" ? nil : $0 }
    }

    private func apiLevel(serial: String, cancellation: SimulatorCommandCancellation) throws -> Int? {
        let output = try run(["-s", serial, "shell", "getprop", "ro.build.version.sdk"], operation: "device discovery",
                             timeout: AndroidControlDefaults.propertyTimeout, capture: .standardOutput, cancellation: cancellation)
        return Int(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Boot

    private func boot(avdName: String, device: SimulatorDevice, cancellation: SimulatorCommandCancellation) throws {
        guard sdk.hasEmulator else {
            throw SimulatorControlError.bootFailed(deviceName: device.name, detail: "The Android Emulator is not installed.")
        }
        guard let port = LoopbackPort.unused() else {
            throw SimulatorControlError.bootFailed(deviceName: device.name, detail: "No free loopback port for gRPC.")
        }
        let allowlist: URL
        do { allowlist = try directory.ensureAllowlist() } catch {
            throw SimulatorControlError.bootFailed(deviceName: device.name, detail: error.localizedDescription)
        }
        let logURL = temporaryDirectory.appendingPathComponent("codes.threading.android-\(UUID().uuidString).log")
        let process: SpawnedChildProcess
        do {
            process = try launcher.launch(executable: sdk.emulator, arguments: [
                "-avd", avdName, "-no-window", "-no-audio", "-no-boot-anim",
                // Never write to the person's AVD: no snapshot save, and a second instance allowed.
                "-read-only",
                "-grpc", String(port), "-grpc-use-jwt", "-grpc-allowlist", allowlist.path,
            ], logURL: logURL)
        } catch {
            throw SimulatorControlError.bootFailed(deviceName: device.name, detail: error.localizedDescription)
        }
        directory.recordBoot(avdName: avdName, process: process, grpcPort: port)

        func failure(_ detail: String) -> SimulatorControlError {
            process.terminate()
            let log = (try? FileHandle(forReadingFrom: logURL)).flatMap { handle -> String? in
                defer { try? handle.close() }
                return (try? handle.readToEnd()).map { String(decoding: $0.suffix(2_048), as: UTF8.self) }
            } ?? ""
            return .bootFailed(deviceName: device.name, detail: [detail, log].filter { !$0.isEmpty }.joined(separator: "\n"))
        }

        // The discovery record names the serial; boot completion is the guest's own property.
        let deadline = Date().addingTimeInterval(AndroidControlDefaults.bootTimeout)
        var serial: String?
        while Date() < deadline {
            if cancellation.isCancelled { process.terminate(); throw SimulatorControlError.cancelled }
            guard process.isRunning else { throw failure("The emulator exited during start-up.") }
            if serial == nil { serial = runningRecords().values.first { $0.processID == process.processIdentifier }?.adbSerial }
            if let serial,
               let value = try? run(["-s", serial, "shell", "getprop", "sys.boot_completed"], operation: "boot",
                                    timeout: AndroidControlDefaults.propertyTimeout, capture: .standardOutput,
                                    cancellation: cancellation),
               String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                try? FileManager.default.removeItem(at: logURL)
                return
            }
            Thread.sleep(forTimeInterval: AndroidControlDefaults.pollInterval)
        }
        throw failure("The emulator did not finish starting within \(Int(AndroidControlDefaults.bootTimeout)) seconds.")
    }

    // MARK: - Commands

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (SimulatorCommandCancellation) throws -> Value
    ) async throws -> Value {
        let cancellation = SimulatorCommandCancellation()
        return try await withTaskCancellationHandler {
            try await commandQueue.perform {
                guard !cancellation.isCancelled else { throw SimulatorControlError.cancelled }
                return try operation(cancellation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func run(
        _ arguments: [String], operation: String, deviceID: SimulatorDeviceID? = nil, timeout: TimeInterval,
        maximumOutputBytes: Int = AndroidControlDefaults.maximumCommandOutputBytes,
        capture: SimulatorCommandCapture = .combined, cancellation: SimulatorCommandCancellation
    ) throws -> Data {
        let result: SimulatorCommandResult
        do {
            result = try adb.run(arguments, timeout: timeout, maximumOutputBytes: maximumOutputBytes,
                                 capture: capture, cancellation: cancellation)
        } catch {
            throw SimulatorControlError.launchFailed(error.localizedDescription)
        }
        if cancellation.isCancelled { throw SimulatorControlError.cancelled }
        if result.outputWasTruncated { throw SimulatorControlError.outputTooLarge(operation: operation) }
        switch result.termination {
        case .timedOut:
            throw SimulatorControlError.timedOut(operation: operation)
        case .exited(let status) where status != 0:
            let detail = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let description = detail.isEmpty ? "adb \(operation) failed with status \(status)." : detail
            // adb's own "device not found" is the one proof the device went away.
            if let deviceID, description.contains("not found") || description.contains("device offline") {
                throw SimulatorControlError.deviceUnavailable(deviceID, detail: description)
            }
            throw SimulatorControlError.commandFailed(operation: operation, detail: description)
        case .exited:
            return result.output
        }
    }

    // MARK: - Validation

    private static func validatePackage(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, url.pathExtension.lowercased() == "apk",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw SimulatorControlError.invalidApplication("Choose a built .apk to install on the Android device.")
        }
    }

    /// An applicationId: dot-separated Java identifiers.
    static func validatedPackageName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.count <= AndroidControlDefaults.maximumPackageNameCharacters, segments.count >= 2,
              segments.allSatisfy({ segment in
                  guard let first = segment.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" else { return false }
                  return segment.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
              }) else {
            throw SimulatorControlError.invalidBundleIdentifier
        }
        return name
    }

    private static func validateLaunchArguments(_ arguments: [String]) throws {
        guard arguments.count <= AndroidControlDefaults.maximumLaunchArgumentCount else {
            throw SimulatorControlError.tooManyLaunchArguments(maximum: AndroidControlDefaults.maximumLaunchArgumentCount)
        }
        guard arguments.allSatisfy({ $0.count <= AndroidControlDefaults.maximumLaunchArgumentCharacters && !$0.contains("\0") }) else {
            throw SimulatorControlError.launchArgumentTooLong(maximum: AndroidControlDefaults.maximumLaunchArgumentCharacters)
        }
    }

    /// `resolve-activity --brief` prints the resolution and then `package/activity` on its last line.
    static func launchComponent(from output: Data, package: String) -> String? {
        String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix(package + "/") }
    }
}
