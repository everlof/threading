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
    private var command: Process?
    private var cleanupCommand: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
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
            setState(.unavailable("Install Tailscale on this Mac to use private access."))
            return
        }

        let launchID = UUID()
        self.launchID = launchID
        setState(.starting)
        run(
            executable: executable,
            arguments: Self.statusArguments,
            launchID: launchID
        ) { [weak self] status, data in
            guard let self, self.launchID == launchID else { return }
            guard status == 0,
                  let origin = Self.origin(fromStatusJSON: data) else {
                self.finishUnavailable(Self.statusFailureReason(from: data))
                return
            }
            self.run(
                executable: executable,
                arguments: Self.serveArguments(localPort: port),
                launchID: launchID
            ) { [weak self] serveStatus, serveData in
                guard let self, self.launchID == launchID else { return }
                if serveStatus == 0 {
                    self.finish(.connected(origin))
                } else {
                    self.finishUnavailable(Self.serveFailureReason(from: serveData))
                }
            }
        }
    }

    func stop() {
        let executable = Self.executableURL()
        cancelCommands()
        onStateChange = nil
        state = .stopped

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
        outputBuffer.removeAll(keepingCapacity: true)
        outputPipe = pipe
        command = process
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard let self,
                      self.launchID == launchID,
                      self.command === process else { return }
                self.outputBuffer.append(data)
                if self.outputBuffer.count > RemoteTailscaleDefaults.maximumCommandOutputBytes {
                    self.outputBuffer = self.outputBuffer.suffix(
                        RemoteTailscaleDefaults.retainedCommandOutputBytes
                    )
                }
            }
        }
        process.terminationHandler = { [weak self, weak process] terminated in
            Task { @MainActor in
                guard let self,
                      self.launchID == launchID,
                      self.command === process else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                self.command = nil
                completion(terminated.terminationStatus, self.outputBuffer)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            outputPipe = nil
            command = nil
            finishUnavailable("Tailscale could not be started from Threading.")
        }
    }

    private func cancelActiveCommand() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
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
        launchID = nil
        outputPipe = nil
        command = nil
        setState(state)
    }

    private func finishUnavailable(_ reason: String) {
        finish(.unavailable(reason))
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

    nonisolated static func serveArguments(localPort: UInt16) -> [String] {
        [
            "serve", "--bg",
            "--https=\(RemoteTailscaleDefaults.httpsPort)",
            "http://127.0.0.1:\(localPort)"
        ]
    }

    nonisolated static let stopArguments = [
        "serve", "--https=\(RemoteTailscaleDefaults.httpsPort)", "off"
    ]

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

    private nonisolated static func statusFailureReason(from data: Data) -> String {
        let output = String(decoding: data, as: UTF8.self).lowercased()
        if output.contains("logged out") || output.contains("needs login") {
            return "Sign in to Tailscale on this Mac, then retry."
        }
        return "Turn on Tailscale on this Mac, then retry."
    }

    private nonisolated static func serveFailureReason(from data: Data) -> String {
        let output = String(decoding: data, as: UTF8.self).lowercased()
        if output.contains("https") || output.contains("certificate") {
            return "Enable Tailscale HTTPS for this tailnet, then retry."
        }
        if output.contains("permission") || output.contains("access denied") {
            return "Tailscale did not allow Threading to publish this private service."
        }
        return "Tailscale Serve could not publish Threading on this tailnet."
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
}
