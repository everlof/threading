import Foundation

/// Owns the short-lived HTTPS relay process used by browsers and the iOS app away from the Mac.
///
/// The origin remains loopback-only. `cloudflared` makes an outbound connection and publishes
/// only the dedicated remote-access server; MCP, extension hosting, and every other listener
/// stay unreachable. Quick Tunnels remain launch-scoped: public guest shares disappear with this
/// process, while a durable owner credential needs a stable relay origin before it can reconnect.
@MainActor
final class RemoteTunnel: RemoteRelayTransport {

    typealias State = RemoteTransportState

    private(set) var state: State = .stopped
    /// The content-free code behind the current `.unavailable` sentence, for diagnostics.
    private(set) var lastFailure: RemoteRelayFailure?
    private let childLedger: AgentChildLedger
    private var process: SpawnedChildProcess?
    private var outputStream: ChildOutputStream?
    private var launchID: UUID?
    private var outputBuffer = Data()
    private var didReportOutputTruncation = false
    /// Fires if the relay never publishes an address. Without it `.starting` is a terminal state
    /// with no timeout, no reason and no journal entry — see `startupTimeoutSeconds`.
    private var startupDeadline: Task<Void, Never>?
    /// Old relays can still be winding down when a fast off/on starts their successor. Retain
    /// each escalation until reap so its delayed KILL cannot target a recycled process-group id.
    private var shutdownEscalations: [pid_t: ChildProcessEscalation] = [:]
    private var onStateChange: (@MainActor @Sendable (State) -> Void)?

    /// Both injectable for the same reason `TailscaleRemoteTransport` injects its locator: a test
    /// must not depend on whether the machine running it has `cloudflared`, and the startup
    /// deadline cannot be asserted at its shipping length.
    private let locateExecutable: () -> URL?
    private let startupTimeout: Duration

    init(
        childLedger: AgentChildLedger = .shared,
        locateExecutable: @escaping () -> URL? = { RemoteTunnel.executableURL() },
        startupTimeout: Duration = .seconds(RemoteTunnelDefaults.startupTimeoutSeconds)
    ) {
        self.childLedger = childLedger
        self.locateExecutable = locateExecutable
        self.startupTimeout = startupTimeout
    }

    func start(
        port: UInt16,
        onStateChange: @escaping @MainActor @Sendable (State) -> Void
    ) {
        stop()
        self.onStateChange = onStateChange

        guard let executable = locateExecutable() else {
            ThreadingLogger.remote.notice("Cloudflare relay is unavailable because cloudflared is not installed")
            fail(.notInstalled, "Install cloudflared to connect away from this Mac.")
            return
        }

        let pipe: ChildPipe
        do {
            pipe = try ChildPipe()
        } catch {
            ThreadingLogger.remote.error(
                "Cloudflare relay pipe creation failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            fail(.launchFailed, "The secure relay could not launch.")
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
            ThreadingLogger.remote.error(
                "Cloudflare relay process launch failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            fail(.launchFailed, "The secure relay could not launch.")
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
            ThreadingLogger.remote.error(
                "Cloudflare relay launch refused because the child-process ledger could not record it"
            )
            fail(.launchFailed, "The secure relay could not launch.")
            return
        }

        self.launchID = launchID
        self.process = process
        // Not a hand-rolled read of this pipe: the primitive that reads as "at most this much"
        // blocks until it can fill the count, and `cloudflared` prints its banner and then goes
        // quiet, so the address in it was never read. `ChildOutputStream` carries that account,
        // and owns the descriptor so nothing here can close it out from under a read.
        outputStream = ChildOutputStream(
            readEnd: pipe.takeReadDescriptor()
        ) { [weak self, weak process] data in
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
                self.outputStream?.cancel()
                self.process = nil
                self.outputStream = nil
                self.launchID = nil
                if case .connected = self.state {
                    ThreadingLogger.remote.warning(
                        "Cloudflare relay exited after connecting status=\(status, privacy: .public)"
                    )
                    self.fail(
                        .exitedAfterConnecting,
                        "The secure relay stopped. Turn access off and on to reconnect."
                    )
                } else if case .starting = self.state {
                    ThreadingLogger.remote.warning(
                        "Cloudflare relay exited during startup status=\(status, privacy: .public)"
                    )
                    self.fail(
                        .exitedDuringStartup,
                        "The secure relay could not start (exit \(status))."
                    )
                }
            }
        }

        lastFailure = nil
        startupDeadline = Task { [weak self] in
            try? await Task.sleep(for: startupTimeout)
            guard !Task.isCancelled, let self, self.launchID == launchID else { return }
            self.startupDeadline = nil
            guard case .starting = self.state else { return }
            ThreadingLogger.remote.warning("Cloudflare relay published no address in time")
            // Report first, so the state and its code reach the coordinator, then end the child.
            // A relay this app has given up tracking must not keep a public endpoint pointed at
            // the loopback listener: that is the exact shape of the bug being fixed here, an
            // address serving real traffic that nothing in the app knew about. Retrying is the
            // user's call, and `releaseChild` makes the next one a genuine restart.
            self.fail(
                .startupTimedOut,
                "The secure relay did not answer in time. Try connecting again."
            )
            self.releaseChild()
        }
        setState(.starting)
    }

    func stop() {
        startupDeadline?.cancel()
        startupDeadline = nil
        releaseChild()
        onStateChange = nil
        state = .stopped
    }

    /// Ends the relay process and its reader without touching the reported state.
    ///
    /// Clearing `launchID` is what makes this safe against work already in flight: the reader's
    /// and the exit observer's main-actor continuations both check it, so neither can report on
    /// behalf of a child this has already let go.
    private func releaseChild() {
        outputStream?.cancel()
        outputStream = nil
        outputBuffer.removeAll(keepingCapacity: true)
        didReportOutputTruncation = false

        let oldProcess = process
        process = nil
        launchID = nil
        if let oldProcess, oldProcess.isRunning {
            shutdownEscalations[oldProcess.processIdentifier] = ChildProcessEscalation(
                child: oldProcess
            )
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        if outputBuffer.count > RemoteTunnelDefaults.maximumOutputBytes {
            if !didReportOutputTruncation {
                didReportOutputTruncation = true
                ThreadingLogger.remote.warning(
                    "Cloudflare relay output exceeded the diagnostic cap bytes=\(RemoteTunnelDefaults.maximumOutputBytes, privacy: .public)"
                )
            }
            outputBuffer = Data(outputBuffer.suffix(RemoteTunnelDefaults.retainedOutputBytes))
        }

        if let url = Self.publicURL(in: String(decoding: outputBuffer, as: UTF8.self)) {
            ThreadingLogger.remote.info("Cloudflare relay published an HTTPS endpoint")
            startupDeadline?.cancel()
            startupDeadline = nil
            lastFailure = nil
            setState(.connected(url))
        }
    }

    /// Records the content-free code beside the sentence, so the two can never disagree about
    /// which failure the state is currently reporting.
    private func fail(_ failure: RemoteRelayFailure, _ message: String) {
        startupDeadline?.cancel()
        startupDeadline = nil
        lastFailure = failure
        setState(.unavailable(message))
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

enum RemoteTunnelDefaults {
    static let maximumOutputBytes = 64 * 1024
    static let retainedOutputBytes = 32 * 1024
    /// A quick Tunnel publishes its address in five to ten seconds on a healthy network. This is
    /// long enough that a slow one is not called a failure, and short enough that a relay which
    /// never answers becomes a stated reason with a retry rather than an endless spinner.
    static let startupTimeoutSeconds = 45
}
