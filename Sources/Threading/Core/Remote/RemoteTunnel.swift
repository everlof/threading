import Foundation

/// Owns the short-lived HTTPS relay process used by browsers and the iOS app away from the Mac.
///
/// The origin remains loopback-only. `cloudflared` makes an outbound connection and publishes
/// only the dedicated remote-access server; MCP, extension hosting, and every other listener
/// stay unreachable. Quick Tunnels remain launch-scoped: public guest shares disappear with this
/// process, while a durable owner credential needs a stable relay origin before it can reconnect.
@MainActor
final class RemoteTunnel: RemoteAccessTransport {

    typealias State = RemoteTransportState

    private(set) var state: State = .stopped
    private let childLedger: AgentChildLedger
    private var process: SpawnedChildProcess?
    private var outputHandle: FileHandle?
    private var launchID: UUID?
    private var outputBuffer = Data()
    /// Old relays can still be winding down when a fast off/on starts their successor. Retain
    /// each escalation until reap so its delayed KILL cannot target a recycled process-group id.
    private var shutdownEscalations: [pid_t: ChildProcessEscalation] = [:]
    private var onStateChange: (@MainActor @Sendable (State) -> Void)?

    init(childLedger: AgentChildLedger = .shared) {
        self.childLedger = childLedger
    }

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

        let pipe: ChildPipe
        do {
            pipe = try ChildPipe()
        } catch {
            setState(.unavailable("The secure relay could not launch."))
            return
        }
        let launchID = UUID()
        let arguments = [
            "tunnel",
            "--config", "/dev/null",
            "--no-autoupdate",
            "--loglevel", "info",
            "--url", "http://127.0.0.1:\(port)"
        ]
        let process: SpawnedChildProcess
        do {
            process = try ChildProcessSpawn.spawn(
                executableURL: executable,
                arguments: arguments,
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor: .nullDevice,
                    AgentChildProcessDefaults.standardOutputDescriptor: .inherited(pipe.writeEnd),
                    AgentChildProcessDefaults.standardErrorDescriptor: .inherited(pipe.writeEnd)
                ]
            )
            pipe.closeWriteEnd()
        } catch {
            pipe.closeBothEnds()
            setState(.unavailable("The secure relay could not launch."))
            return
        }

        guard childLedger.recordSpawnedChild(
            process,
            sessionID: nil,
            executable: executable.path
        ) == .recorded else {
            pipe.closeBothEnds()
            let escalation = ChildProcessEscalation(child: process)
            process.observeExit { _ in escalation.complete() }
            setState(.unavailable("The secure relay could not launch."))
            return
        }

        let output = pipe.takeReadHandle()
        self.launchID = launchID
        self.process = process
        outputHandle = output
        output.readabilityHandler = { [weak self, weak process] handle in
            guard let data = try? handle.read(
                upToCount: RemoteTunnelDefaults.outputReadChunkBytes
            ), !data.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.launchID == launchID, self.process === process else { return }
                self.consume(data)
            }
        }
        let pid = process.processIdentifier
        let ledger = childLedger
        process.observeExit { [weak self, weak process] status in
            ledger.clear(pid: pid)
            Task { @MainActor in
                guard let self else { return }
                self.shutdownEscalations.removeValue(forKey: pid)?.complete()
                guard self.launchID == launchID, self.process === process else { return }
                self.outputHandle?.readabilityHandler = nil
                try? self.outputHandle?.close()
                self.process = nil
                self.outputHandle = nil
                self.launchID = nil
                if case .connected = self.state {
                    self.setState(.unavailable(
                        "The secure relay stopped. Turn access off and on to reconnect."
                    ))
                } else if case .starting = self.state {
                    self.setState(.unavailable(
                        "The secure relay could not start (exit \(status))."
                    ))
                }
            }
        }

        setState(.starting)
    }

    func stop() {
        outputHandle?.readabilityHandler = nil
        try? outputHandle?.close()
        outputHandle = nil
        outputBuffer.removeAll(keepingCapacity: true)

        let oldProcess = process
        process = nil
        launchID = nil
        if let oldProcess, oldProcess.isRunning {
            shutdownEscalations[oldProcess.processIdentifier] = ChildProcessEscalation(
                child: oldProcess
            )
        }

        onStateChange = nil
        state = .stopped
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        if outputBuffer.count > RemoteTunnelDefaults.maximumOutputBytes {
            outputBuffer = Data(outputBuffer.suffix(RemoteTunnelDefaults.retainedOutputBytes))
        }

        if let url = Self.publicURL(in: String(decoding: outputBuffer, as: UTF8.self)) {
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

private enum RemoteTunnelDefaults {
    static let outputReadChunkBytes = 16 * 1024
    static let maximumOutputBytes = 64 * 1024
    static let retainedOutputBytes = 32 * 1024
}
