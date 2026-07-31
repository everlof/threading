import Foundation

/// Owns the short-lived HTTPS relay process used by browsers and the iOS app away from the Mac.
///
/// The origin remains loopback-only. `cloudflared` makes an outbound connection and publishes
/// only the dedicated remote-access server; MCP, extension hosting, and every other listener
/// stay unreachable. Quick Tunnels deliberately match the launch-scoped share token: both URL
/// and capability disappear with this process.
@MainActor
final class RemoteTunnel {

    enum State: Equatable, Sendable {
        case stopped
        case starting
        case connected(URL)
        case unavailable(String)
    }

    private(set) var state: State = .stopped
    private var process: Process?
    private var outputPipe: Pipe?
    private var launchID: UUID?
    private var outputBuffer = ""
    private var onStateChange: (@MainActor @Sendable (State) -> Void)?

    func start(
        port: UInt16,
        onStateChange: @escaping @MainActor @Sendable (State) -> Void
    ) {
        stop()
        self.onStateChange = onStateChange

        guard let executable = Self.executableURL() else {
            setState(.unavailable("Install cloudflared to connect away from this Mac."))
            return
        }

        let process = Process()
        let pipe = Pipe()
        let launchID = UUID()
        self.launchID = launchID
        process.executableURL = executable
        process.arguments = [
            "tunnel",
            "--config", "/dev/null",
            "--no-autoupdate",
            "--loglevel", "info",
            "--url", "http://127.0.0.1:\(port)"
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [self, launchID] terminated in
            Task { @MainActor in
                guard self.launchID == launchID else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.outputPipe = nil
                self.launchID = nil
                if case .connected = self.state {
                    self.setState(.unavailable("The secure relay stopped. Turn access off and on to reconnect."))
                } else if case .starting = self.state {
                    self.setState(.unavailable(
                        "The secure relay could not start (exit \(terminated.terminationStatus))."
                    ))
                }
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { [self, launchID] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard self.launchID == launchID else { return }
                self.consume(text)
            }
        }

        do {
            try process.run()
            self.process = process
            outputPipe = pipe
            setState(.starting)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            setState(.unavailable("The secure relay could not launch."))
        }
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        outputBuffer = ""

        let oldProcess = process
        oldProcess?.terminationHandler = nil
        process = nil
        launchID = nil
        if oldProcess?.isRunning == true {
            oldProcess?.terminate()
        }

        onStateChange = nil
        state = .stopped
    }

    private func consume(_ text: String) {
        outputBuffer += text
        if outputBuffer.count > 64 * 1024 {
            outputBuffer = String(outputBuffer.suffix(32 * 1024))
        }

        if let url = Self.publicURL(in: outputBuffer) {
            setState(.connected(url))
        }
    }

    private func setState(_ state: State) {
        guard self.state != state else { return }
        self.state = state
        onStateChange?(state)
    }

    nonisolated static func publicURL(in output: String) -> URL? {
        let pattern = #"https://[a-z0-9-]+\.trycloudflare\.com"#
        guard let range = output.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(output[range]))
    }

    nonisolated static func executableURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared"
        ]
        candidates += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("cloudflared").path }

        return candidates
            .first(where: { fileManager.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }
}
