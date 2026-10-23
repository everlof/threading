import Darwin
import Foundation
import Security
import ThreadingPluginKit

/// The same finite iPhone operations for every loaded native pane plugin. Verification and the user's
/// approval happen before a pane receives this service; no caller receives a tool path or a
/// generic command runner. All methods do file/process work on their caller's worker.
final class NativePluginDeviceServices: PluginDeviceServices, @unchecked Sendable {
    static let shared = NativePluginDeviceServices()

    private static let profileLimit = 1_048_576
    private static let profileTransferLock = NSLock()
    private let resolveTool: @Sendable () -> URL?

    init(resolveTool: @escaping @Sendable () -> URL? = {
        NativePluginDeviceServices.resolveValidatedTool()
    }) {
        self.resolveTool = resolveTool
    }

    func hasStructuredSystemLog() -> Bool { resolveTool() != nil }

    func startStructuredSystemLog(
        deviceID: String,
        minimumSeverity: Int,
        onLine: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (String) -> Void
    ) -> (any PluginDeviceLogStream)? {
        guard PhysicalDeviceID(deviceID) != nil,
              (0...4).contains(minimumSeverity),
              let tool = resolveTool(),
              let environment = runtimeEnvironment(for: tool, deviceID: deviceID)
        else { return nil }

        let arguments = ["--no-color", "syslog", "live", "--native", "--format", "json"]
            + (minimumSeverity >= 1 ? ["--no-debug"] : [])
            + (minimumSeverity >= 2 ? ["--no-info"] : [])
        let stream = NativePluginStructuredLogStream(onLine: onLine, onEnd: onEnd)
        guard stream.start(executable: tool, arguments: arguments, environment: environment)
        else { return nil }
        return stream
    }

    func installBluetoothLoggingProfile(
        _ profile: Data,
        deviceID: String
    ) -> PluginDeviceOperationResult {
        guard Self.profileTransferLock.try() else { return .busy }
        defer { Self.profileTransferLock.unlock() }
        guard PhysicalDeviceID(deviceID) != nil else { return .invalidDevice }
        let validation = Self.validateProfile(profile)
        guard validation == .sent else { return validation }
        guard let tool = resolveTool(),
              let environment = runtimeEnvironment(for: tool, deviceID: deviceID)
        else { return .toolUnavailable }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-profile-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let staged = directory.appendingPathComponent("Bluetooth.mobileconfig")
            try profile.write(to: staged)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: staged.path
            )
            let result = try BoundedChildProcess.run(
                executable: tool.path,
                arguments: ["--no-color", "profile", "install", "--udid", deviceID, "--", staged.path],
                environment: environment,
                timeout: 90,
                maximumOutputBytes: 8_192,
                output: .merged
            )
            guard case .exited(let status) = result.termination else { return .incomplete }
            guard status == 0 else {
                let detail = String(decoding: result.output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .rejected(String(detail.suffix(1_024)))
            }
            // iOS still asks the user to finish and approve the profile installation.
            return .sent
        } catch {
            return .incomplete
        }
    }

    private static func resolveValidatedTool() -> URL? {
        if case .installed(_, let executable) = Pymobiledevice3Installation().status() {
            return executable
        }
        guard let candidate = PhysicalDeviceToolLocator.pymobiledevice3(
            managedExecutable: URL(fileURLWithPath: "/nonexistent/pymobiledevice3")
        ), let result = try? BoundedChildProcess.run(
            executable: candidate.path, arguments: ["--no-color", "version"],
            timeout: 3, maximumOutputBytes: 256, output: .standardOutput
        ), result.termination == .exited(0), !result.outputWasTruncated,
           PhysicalDeviceCapabilityProbe.toolVersionIsSupported(result.output) == true
        else { return nil }
        return candidate
    }

    private func runtimeEnvironment(for tool: URL, deviceID: String) -> [String: String]? {
        var environment = ProcessInfo.processInfo.environment
        if tool.standardizedFileURL == Pymobiledevice3ManagedTool.executable().standardizedFileURL {
            guard let prepared = try? Pymobiledevice3RuntimeEnvironment.prepare(
                inherited: environment
            ) else { return nil }
            environment = prepared
        }
        environment["PYMOBILEDEVICE3_UDID"] = deviceID
        environment.removeValue(forKey: "PYMOBILEDEVICE3_TUNNEL")
        return environment
    }

    /// The host checks the payload itself even if a plugin says it already did. A signed CMS
    /// envelope is decoded only to inspect its type and expiry; iOS checks its signature and asks
    /// for the user's installation approval.
    private static func validateProfile(_ data: Data, now: Date = Date()) -> PluginDeviceOperationResult {
        guard !data.isEmpty, data.count <= profileLimit else { return .invalidProfile }
        if let plain = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return validatePayload(plain, now: now)
        }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return .invalidProfile }
        let updated = data.withUnsafeBytes {
            CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count)
        }
        guard updated == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess
        else { return .invalidProfile }
        var decoded: CFData?
        guard CMSDecoderCopyContent(decoder, &decoded) == errSecSuccess,
              let decoded,
              let payload = try? PropertyListSerialization.propertyList(
                from: decoded as Data, format: nil
              ) as? [String: Any]
        else { return .invalidProfile }
        return validatePayload(payload, now: now)
    }

    private static func validatePayload(
        _ payload: [String: Any], now: Date
    ) -> PluginDeviceOperationResult {
        guard payload["PayloadType"] as? String == "Configuration",
              payload["PayloadIdentifier"] as? String == "com.apple.bluetooth.logging",
              let content = payload["PayloadContent"] as? [[String: Any]], !content.isEmpty
        else { return .invalidProfile }
        if let removal = payload["RemovalDate"] as? Date, removal <= now { return .expiredProfile }
        return .sent
    }
}

/// Owns one host-started reader and closes it when the plugin releases its stream token.
private final class NativePluginStructuredLogStream: PluginDeviceLogStream, @unchecked Sendable {
    private static let maximumLineBytes = 1_048_576
    private static let retainedErrorBytes = 4_096
    private let queue = DispatchQueue(label: "codes.threading.plugin-device-log", qos: .userInitiated)
    private let lock = NSLock()
    private let onLine: @Sendable (Data) -> Void
    private let onEnd: @Sendable (String) -> Void
    private var process: Process?
    private var tether: FileHandle?

    init(onLine: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
        self.onEnd = onEnd
    }

    func start(executable: URL, arguments: [String], environment: [String: String]) -> Bool {
        let task = Process()
        // A child left by an app crash holds the device relay indefinitely. The shell watcher
        // notices the parent's pipe closing even if Threading cannot perform normal teardown.
        let tetherPipe = Pipe()
        let writeEnd = tetherPipe.fileHandleForWriting
        _ = fcntl(writeEnd.fileDescriptor, F_SETFD, FD_CLOEXEC)
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", Self.tetherScript, "threading-reader", executable.path] + arguments
        task.standardInput = tetherPipe
        task.environment = environment
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        let diagnostics = NativePluginLogDiagnostics()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            else { diagnostics.append(bytes, limit: Self.retainedErrorBytes) }
        }
        task.terminationHandler = { [weak self] finished in
            errors.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            let detail = diagnostics.lastLine()
            let reason = detail.isEmpty
                ? "the reader exited with status \(finished.terminationStatus)"
                : detail
            self.queue.async { [weak self] in self?.onEnd(reason) }
        }
        do {
            try task.run()
        } catch {
            task.terminationHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? writeEnd.close()
            return false
        }
        lock.lock()
        process = task
        tether = writeEnd
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            var pending = Data()
            var discardingOversizedLine = false
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                var next = chunk.startIndex
                while next < chunk.endIndex {
                    let newline = chunk[next...].firstIndex(of: 0x0A)
                    let end = newline ?? chunk.endIndex
                    let fragment = chunk[next..<end]
                    if !discardingOversizedLine,
                       fragment.count <= Self.maximumLineBytes - pending.count {
                        pending.append(fragment)
                    } else {
                        pending.removeAll(keepingCapacity: true)
                        discardingOversizedLine = true
                    }
                    guard let newline else { break }
                    if !discardingOversizedLine { self.onLine(pending) }
                    pending.removeAll(keepingCapacity: true)
                    discardingOversizedLine = false
                    next = chunk.index(after: newline)
                }
            }
        }
        return true
    }

    func stop() {
        lock.lock()
        let task = process
        let handle = tether
        process = nil
        tether = nil
        task?.terminationHandler = nil
        lock.unlock()
        if task?.isRunning == true { task?.terminate() }
        try? handle?.close()
    }

    deinit { stop() }

    private static let tetherScript = #"""
        exec 3<&0
        "$@" </dev/null 3<&- &
        reader=$!
        ( read -r _ <&3; kill "$reader" 2>/dev/null; sleep 1; kill -9 "$reader" 2>/dev/null ) </dev/null &
        watcher=$!
        exec 3<&-
        trap 'kill "$reader" 2>/dev/null; kill "$watcher" 2>/dev/null; wait "$reader"; exit 143' TERM INT HUP
        wait "$reader"
        status=$?
        kill "$watcher" 2>/dev/null
        exit "$status"
        """#
}

private final class NativePluginLogDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data, limit: Int) {
        lock.lock()
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
        lock.unlock()
    }

    func lastLine() -> String {
        lock.lock()
        let copy = data
        lock.unlock()
        return String(decoding: copy, as: UTF8.self)
            .split(separator: "\n")
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
    }
}
