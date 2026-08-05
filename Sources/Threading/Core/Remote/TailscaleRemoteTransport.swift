import Foundation

/// Publishes the remote-access loopback listener inside the user's tailnet with Tailscale Serve.
///
/// Serve keeps the backend on `127.0.0.1`, preserves the separation from MCP and extension
/// listeners, and supplies HTTPS/WSS at a stable tailnet DNS name. The front-end port is owned by
/// Threading so stopping this transport can remove exactly its handler; `tailscale serve reset`
/// is intentionally never used because it would erase unrelated services the user configured.
@MainActor
final class TailscaleRemoteTransport: RemoteAccessTransport {

    private(set) var state: RemoteTransportState = .stopped
    private(set) var readiness: TailscaleReadiness = .notChecked
    private var command: Process?
    private var cleanupCommand: Process?
    private var outputPipe: Pipe?
    private var outputCollector: CommandOutputCollector?
    private var commandTimeoutTask: Task<Void, Never>?
    private var launchID: UUID?
    private var onStateChange: (@MainActor @Sendable (RemoteTransportState) -> Void)?
    private var pendingStart: (
        port: UInt16,
        onStateChange: @MainActor @Sendable (RemoteTransportState) -> Void
    )?

    func start(
        port: UInt16,
        onStateChange: @escaping @MainActor @Sendable (RemoteTransportState) -> Void
    ) {
        cancelActiveCommand()
        self.onStateChange = onStateChange
        pendingStart = nil

        // `serve ... off` and a new `serve --bg` must not race: a rapid off/on could otherwise
        // let the older cleanup arrive last and erase the handler that was just installed.
        if cleanupCommand != nil {
            pendingStart = (port, onStateChange)
            setState(.starting)
            return
        }
        beginStart(port: port)
    }

    private func beginStart(port: UInt16) {

        guard let executable = Self.executableURL() else {
            finishUnavailable(.notInstalled)
            return
        }

        let launchID = UUID()
        self.launchID = launchID
        readiness = .checking
        setState(.starting)
        run(
            executable: executable,
            arguments: Self.statusArguments,
            launchID: launchID
        ) { [weak self] status, data in
            guard let self, self.launchID == launchID else { return }
            guard status == 0 else {
                self.finishUnavailable(Self.statusFailureIssue(from: data))
                return
            }
            if let issue = Self.readinessIssue(fromStatusJSON: data) {
                self.finishUnavailable(issue)
                return
            }
            guard let origin = Self.origin(fromStatusJSON: data) else {
                self.finishUnavailable(.statusUnavailable)
                return
            }
            self.run(
                executable: executable,
                arguments: Self.serveStatusArguments,
                launchID: launchID
            ) { [weak self] configStatus, configData in
                guard let self, self.launchID == launchID else { return }
                guard configStatus == 0,
                      Self.isValidServeStatus(configData) else {
                    self.finishUnavailable(.statusUnavailable)
                    return
                }
                guard !Self.serveStatus(
                    configData,
                    containsHTTPSPort: RemoteTailscaleDefaults.httpsPort
                ) else {
                    self.finishUnavailable(.portInUse)
                    return
                }
                self.readiness = .publishing
                self.run(
                    executable: executable,
                    arguments: Self.serveArguments(localPort: port),
                    launchID: launchID
                ) { [weak self] serveStatus, serveData in
                    guard let self, self.launchID == launchID else { return }
                    if serveStatus == 0 {
                        self.readiness = .ready(origin)
                        self.finish(.connected(origin))
                    } else {
                        self.finishUnavailable(Self.serveFailureIssue(from: serveData))
                    }
                }
            }
        }
    }

    func stop() {
        let executable = Self.executableURL()
        cancelCommands()
        onStateChange = nil
        state = .stopped
        readiness = .notChecked

        guard let executable else { return }
        let cleanup = Process()
        cleanup.executableURL = executable
        cleanup.arguments = Self.stopArguments
        cleanup.standardOutput = FileHandle.nullDevice
        cleanup.standardError = FileHandle.nullDevice
        cleanup.terminationHandler = { [weak self, weak cleanup] _ in
            Task { @MainActor in
                guard let self, self.cleanupCommand === cleanup else { return }
                self.cleanupCommand = nil
                guard let pending = self.pendingStart else { return }
                self.pendingStart = nil
                self.onStateChange = pending.onStateChange
                self.beginStart(port: pending.port)
            }
        }
        do {
            try cleanup.run()
            cleanupCommand = cleanup
        } catch {
            // The backend listener has already closed, so a stale Serve handler reaches nothing.
            // The next start overwrites this exact port and is the recovery path.
        }
    }

    // MARK: - Commands

    private func run(
        executable: URL,
        arguments: [String],
        launchID: UUID,
        completion: @escaping @MainActor @Sendable (Int32, Data) -> Void
    ) {
        let process = Process()
        let pipe = Pipe()
        let collector = CommandOutputCollector()
        outputCollector = collector
        outputPipe = pipe
        command = process
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard self != nil, process != nil else { return }
            collector.append(data)
        }
        process.terminationHandler = { [weak self, weak process] terminated in
            // Process termination can race the final readability callback. Stop installing new
            // callbacks, synchronously drain the pipe, then take a lock-protected snapshot so a
            // short error written immediately before exit is not lost.
            pipe.fileHandleForReading.readabilityHandler = nil
            collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
            let output = collector.snapshot()
            Task { @MainActor in
                guard let self,
                      self.launchID == launchID,
                      self.command === process else { return }
                self.outputPipe = nil
                self.outputCollector = nil
                self.command = nil
                completion(terminated.terminationStatus, output)
            }
        }

        do {
            try process.run()
            commandTimeoutTask?.cancel()
            commandTimeoutTask = Task { [weak self, weak process] in
                try? await Task.sleep(for: .seconds(
                    RemoteTailscaleDefaults.commandTimeoutSeconds
                ))
                guard !Task.isCancelled, let self,
                      self.launchID == launchID,
                      self.command === process else { return }
                collector.append(Data("\nThreading command timeout".utf8))
                process?.terminate()
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            outputPipe = nil
            outputCollector = nil
            command = nil
            finishUnavailable(.statusUnavailable)
        }
    }

    private func cancelActiveCommand() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        outputCollector = nil
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        launchID = nil

        command?.terminationHandler = nil
        if command?.isRunning == true { command?.terminate() }
        command = nil
    }

    private func cancelCommands() {
        cancelActiveCommand()
        pendingStart = nil

        cleanupCommand?.terminationHandler = nil
        if cleanupCommand?.isRunning == true { cleanupCommand?.terminate() }
        cleanupCommand = nil
    }

    private func finish(_ state: RemoteTransportState) {
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        launchID = nil
        outputPipe = nil
        outputCollector = nil
        command = nil
        setState(state)
    }

    private func finishUnavailable(_ issue: TailscaleReadinessIssue) {
        readiness = .actionRequired(issue)
        finish(.unavailable(issue.message))
    }

    private func setState(_ state: RemoteTransportState) {
        guard self.state != state else { return }
        self.state = state
        onStateChange?(state)
    }

    // MARK: - Pure command policy

    nonisolated static let statusArguments = [
        "status", "--json", "--peers=false"
    ]

    nonisolated static let serveStatusArguments = ["serve", "status", "--json"]

    nonisolated static func serveArguments(localPort: UInt16) -> [String] {
        [
            "serve", "--yes", "--bg",
            "--https=\(RemoteTailscaleDefaults.httpsPort)",
            "http://127.0.0.1:\(localPort)"
        ]
    }

    nonisolated static let stopArguments = [
        "serve", "--https=\(RemoteTailscaleDefaults.httpsPort)", "off"
    ]

    nonisolated static func isValidServeStatus(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    nonisolated static func serveStatus(_ data: Data, containsHTTPSPort port: Int) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return true }
        return containsPort(object, port: port)
    }

    nonisolated private static func containsPort(_ value: Any, port: Int) -> Bool {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.contains { key, nested in
                key == String(port) || key.hasSuffix(":\(port)")
                    || containsPort(nested, port: port)
            }
        case let array as [Any]:
            return array.contains { containsPort($0, port: port) }
        case let number as NSNumber:
            return number.intValue == port
        case let string as String:
            return string == String(port)
                || string.contains(":\(port)")
                || string.contains("=\(port)")
        default:
            return false
        }
    }

    nonisolated static func origin(fromStatusJSON data: Data) -> URL? {
        guard let status = try? JSONDecoder().decode(TailscaleStatus.self, from: data),
              status.backendState.lowercased() == "running",
              let rawName = status.local?.dnsName.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            return nil
        }
        let name = rawName.hasSuffix(".") ? String(rawName.dropLast()) : rawName
        var components = URLComponents()
        components.scheme = "https"
        components.host = name
        components.port = RemoteTailscaleDefaults.httpsPort
        components.path = "/"
        return components.url
    }

    nonisolated static func readinessIssue(
        fromStatusJSON data: Data
    ) -> TailscaleReadinessIssue? {
        guard let status = try? JSONDecoder().decode(TailscaleStatus.self, from: data) else {
            return .statusUnavailable
        }
        switch status.backendState.lowercased() {
        case "running":
            guard let name = status.local?.dnsName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !name.isEmpty else {
                return .statusUnavailable
            }
            return nil
        case "needslogin", "needsmachineauth", "loggedout":
            return .signedOut
        case "stopped", "starting", "nomap":
            return .stopped
        default:
            return .statusUnavailable
        }
    }

    nonisolated static func executableURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        candidates += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("tailscale").path }
        return candidates
            .first(where: { fileManager.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private nonisolated static func statusFailureIssue(
        from data: Data
    ) -> TailscaleReadinessIssue {
        let output = String(decoding: data, as: UTF8.self).lowercased()
        if output.contains("logged out") || output.contains("needs login") {
            return .signedOut
        }
        if output.contains("stopped") || output.contains("not running") {
            return .stopped
        }
        return .statusUnavailable
    }

    nonisolated static func serveFailureIssue(
        from data: Data
    ) -> TailscaleReadinessIssue {
        let output = String(decoding: data, as: UTF8.self).lowercased()
        if output.contains("https") || output.contains("certificate") {
            return .httpsRequired
        }
        if output.contains("permission") || output.contains("access denied") {
            return .permissionDenied
        }
        return .serveFailed
    }
}

private final class CommandOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > RemoteTailscaleDefaults.maximumCommandOutputBytes {
            data = Data(data.suffix(RemoteTailscaleDefaults.retainedCommandOutputBytes))
        }
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

private struct TailscaleStatus: Decodable {
    let backendState: String
    let local: Local?

    struct Local: Decodable {
        let dnsName: String

        private enum CodingKeys: String, CodingKey {
            case dnsName = "DNSName"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case local = "Self"
    }
}

private enum RemoteTailscaleDefaults {
    /// A dedicated front-end avoids replacing an existing HTTPS service on the conventional port.
    static let httpsPort = 8443
    static let maximumCommandOutputBytes = 64 * 1024
    static let retainedCommandOutputBytes = 32 * 1024
    static let commandTimeoutSeconds: TimeInterval = 12
}
