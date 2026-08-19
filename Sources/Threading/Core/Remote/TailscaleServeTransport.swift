import Foundation

/// The `tailscale` CLI, as Remote Access uses it: what this Mac's tailnet membership is, and the
/// browser convenience that publishes Threading at the `*.ts.net` name.
///
/// **This is no longer how a phone reaches this Mac.** The `tailscale` door is a listener bound to
/// this Mac's own tailnet address, presenting the same pinned certificate as every other routable
/// door, so the iOS app takes one code path everywhere (§8 of the transport plan). What Serve
/// still provides is the one thing a raw bind cannot: a publicly trusted certificate for the
/// tailnet DNS name, which is what stops a *browser* on the tailnet meeting a full-page
/// certificate interstitial. That is a convenience, off by default, and nothing depends on it.
///
/// Serve keeps the backend on `127.0.0.1`, preserves the separation from MCP and extension
/// listeners, and supplies HTTPS/WSS at a stable tailnet DNS name. The front-end port is owned by
/// Threading so stopping it can remove exactly its handler; `tailscale serve reset` is
/// intentionally never used because it would erase unrelated services the user configured.
///
/// The status probe is the second half. `tailscale status --json` is the only way to tell "not
/// installed" from "signed out" from "stopped", and it is also where this Mac's MagicDNS name
/// comes from, which the tailnet door advertises beside its numeric address. It runs when the
/// door is switched on, whether or not Serve is.
@MainActor
final class TailscaleServeTransport: RemoteTailnetTransport {

    private(set) var state: RemoteTransportState = .stopped

    /// Setup progress is finer-grained than `state`: the readiness steps advance while the
    /// transport state sits on `.starting` for the whole of three sequential CLI commands, so a
    /// state observer alone shows the *first* step's copy until the outcome. The readiness card
    /// froze on "Checked when Remote Access turns on." for up to half a minute this way.
    private(set) var readiness: TailscaleReadiness = .notChecked {
        didSet {
            guard readiness != oldValue else { return }
            onReadinessChange?()
        }
    }

    /// What the last `tailscale status` said about this Mac. `.unknown` until one has run.
    private(set) var hostFacts: TailscaleHostFacts = .unknown {
        didSet {
            guard hostFacts != oldValue else { return }
            onReadinessChange?()
        }
    }

    var onReadinessChange: (@MainActor () -> Void)?

    /// Injectable for tests, which must not depend on whether the machine running them has the
    /// Tailscale CLI installed.
    private let locateExecutable: () -> URL?

    private var command: SpawnedChildProcess?
    private var cleanupCommand: SpawnedChildProcess?
    private var outputStream: ChildOutputStream?
    private var outputCollector: CommandOutputCollector?
    private var commandDeadline: ChildProcessDeadline?
    private var cleanupDeadline: ChildProcessDeadline?
    /// Cancellation can overlap a replacement command. Retaining each escalation until reap
    /// prevents its delayed KILL from ever reaching a recycled process-group id.
    private var shutdownEscalations: [pid_t: ChildProcessEscalation] = [:]
    private var launchID: UUID?
    private var onStateChange: (@MainActor @Sendable (RemoteTransportState) -> Void)?
    private var pendingStart: (
        port: UInt16,
        onStateChange: @MainActor @Sendable (RemoteTransportState) -> Void
    )?

    init(locateExecutable: @escaping () -> URL? = { TailscaleServeTransport.executableURL() }) {
        self.locateExecutable = locateExecutable
    }

    // MARK: - The facts behind the door

    /// Reads `tailscale status` once and publishes what it said, without publishing anything on
    /// the tailnet.
    ///
    /// The tailnet door binds an address whether or not this runs; what this adds is the
    /// difference between "Tailscale is not connected" and "Tailscale is not installed", plus
    /// the MagicDNS name the door advertises beside its numeric address. One short-lived child
    /// process with a deadline, off the main actor, called when the door is switched on and when
    /// the page that renders it appears — never on a timer.
    func refreshHostFacts() {
        // A publish is already running its own status stage, and both would want the one command
        // slot. Its completion updates the same value, so skipping here loses nothing.
        guard command == nil else { return }
        guard let executable = locateExecutable() else {
            hostFacts = TailscaleHostFacts(state: .notInstalled, magicDNSName: nil)
            return
        }
        let launchID = UUID()
        self.launchID = launchID
        run(
            executable: executable,
            arguments: Self.statusArguments,
            stage: "facts",
            launchID: launchID,
            // A probe that could not be launched says the facts are unknown. It must not report
            // Serve unavailable: Serve may not even be switched on.
            onLaunchFailure: { [weak self] in self?.hostFacts = .unknown }
        ) { [weak self] status, data in
            guard let self, self.launchID == launchID else { return }
            self.launchID = nil
            self.hostFacts = Self.hostFacts(exitStatus: status, output: data)
        }
    }

    func start(
        port: UInt16,
        onStateChange: @escaping @MainActor @Sendable (RemoteTransportState) -> Void
    ) {
        cancelActiveCommand()
        self.onStateChange = onStateChange
        pendingStart = nil
        // The check begins with the request, not with the first command: a start deferred
        // behind cleanup would otherwise still read "checked when Remote Access turns on"
        // while Remote Access is on.
        readiness = .checking

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

        guard let executable = locateExecutable() else {
            ThreadingLogger.remote.notice("Tailscale transport is unavailable because the CLI is not installed")
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
            stage: "status",
            launchID: launchID
        ) { [weak self] status, data in
            guard let self, self.launchID == launchID else { return }
            // Serve's first command is the probe's command, so the facts behind the door are
            // learned here too rather than needing a second child process.
            self.hostFacts = Self.hostFacts(exitStatus: status, output: data)
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
                stage: "serve_status",
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
                    stage: "publish",
                    launchID: launchID,
                    timeout: RemoteTailscaleDefaults.publishTimeoutSeconds
                ) { [weak self] serveStatus, serveData in
                    guard let self, self.launchID == launchID else { return }
                    if serveStatus == 0 {
                        self.readiness = .ready(origin)
                        self.finish(.connected(origin))
                    } else {
                        let failure = Self.serveFailureIssue(from: serveData)
                        self.finishUnavailable(failure.issue, actionURL: failure.actionURL)
                    }
                }
            }
        }
    }

    func stop() {
        let executable = locateExecutable()
        cancelCommands()
        onStateChange = nil
        state = .stopped
        readiness = .notChecked
        // `hostFacts` deliberately survives: it is what `tailscale status` said about this Mac,
        // and the tailnet door still renders it after the browser convenience is switched off.

        guard let executable else { return }
        let cleanup: SpawnedChildProcess
        do {
            cleanup = try ChildProcessSpawn.spawn(
                executableURL: executable,
                arguments: Self.stopArguments,
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor: .nullDevice,
                    AgentChildProcessDefaults.standardOutputDescriptor: .nullDevice,
                    AgentChildProcessDefaults.standardErrorDescriptor: .nullDevice
                ]
            )
        } catch {
            // The backend listener has already closed, so a stale Serve handler reaches nothing.
            // The next start retries removal before publishing this exact port.
            ThreadingLogger.remote.warning(
                "Tailscale cleanup launch failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return
        }
        cleanupCommand = cleanup
        cleanupDeadline = ChildProcessDeadline(
            child: cleanup,
            timeout: RemoteTailscaleDefaults.commandTimeoutSeconds,
            terminationGrace: BoundedChildDefaults.terminationGrace
        )
        let pid = cleanup.processIdentifier
        cleanup.observeExit { [weak self, weak cleanup] status in
            Task { @MainActor in
                guard let self else { return }
                self.shutdownEscalations.removeValue(forKey: pid)?.complete()
                guard self.cleanupCommand === cleanup else { return }
                let timedOut = self.cleanupDeadline?.complete() == true
                self.cleanupDeadline = nil
                self.cleanupCommand = nil
                if timedOut {
                    ThreadingLogger.remote.warning("Tailscale cleanup timed out")
                } else if status != 0 {
                    ThreadingLogger.remote.warning(
                        "Tailscale cleanup exited status=\(status, privacy: .public)"
                    )
                } else {
                    ThreadingLogger.remote.debug("Tailscale cleanup completed")
                }
                guard let pending = self.pendingStart else { return }
                self.pendingStart = nil
                self.onStateChange = pending.onStateChange
                self.beginStart(port: pending.port)
            }
        }
    }

    // MARK: - Commands

    /// `onLaunchFailure` is what a command that never started reports. It defaults to Serve's
    /// answer because Serve is what most of these commands are for; the status probe passes its
    /// own, because a probe that could not run says nothing about whether Serve is publishing.
    private func run(
        executable: URL,
        arguments: [String],
        stage: String,
        launchID: UUID,
        timeout: TimeInterval = RemoteTailscaleDefaults.commandTimeoutSeconds,
        onLaunchFailure: (@MainActor () -> Void)? = nil,
        completion: @escaping @MainActor @Sendable (Int32, Data) -> Void
    ) {
        let failed: @MainActor () -> Void = onLaunchFailure
            ?? { [weak self] in self?.finishUnavailable(.statusUnavailable) }
        let pipe: ChildPipe
        do {
            pipe = try ChildPipe()
        } catch {
            ThreadingLogger.remote.error(
                "Tailscale command pipe creation failed stage=\(stage, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            failed()
            return
        }
        let collector = CommandOutputCollector()
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
                "Tailscale command launch failed stage=\(stage, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            failed()
            return
        }

        outputCollector = collector
        command = process
        // These commands print a line or two and exit, so a read that waits to fill a buffer only
        // ever returned at exit, and the exit callback then closed this descriptor out from under
        // it. `ChildOutputStream` explains why the primitive matters, and owns the descriptor so
        // that close can only happen once the reader has finished.
        outputStream = ChildOutputStream(
            readEnd: pipe.takeReadDescriptor()
        ) { [weak self, weak process] data in
            guard self != nil, process != nil else { return }
            collector.append(data)
        }
        commandDeadline = ChildProcessDeadline(
            child: process,
            timeout: timeout,
            terminationGrace: BoundedChildDefaults.terminationGrace
        )
        let pid = process.processIdentifier
        process.observeExit { [weak self, weak process] status in
            Task { @MainActor in
                guard let self else { return }
                self.shutdownEscalations.removeValue(forKey: pid)?.complete()
                guard
                      self.launchID == launchID,
                      self.command === process else { return }
                let timedOut = self.commandDeadline?.complete() == true
                self.commandDeadline = nil
                if timedOut {
                    collector.append(Data("\nThreading command timeout".utf8))
                }
                let capturedOutput = collector.snapshot()
                // Ended here rather than left to reach end of file on its own: `serve --bg` can
                // leave a descendant holding the write end, and waiting for that would hold a
                // descriptor and a live read source for as long as the daemon runs. Output now
                // arrives as the child writes it, so what this gives up is at most a final line
                // racing the exit, and losing one degrades to `.statusUnavailable`, which is the
                // safe answer.
                self.outputStream?.cancel()
                self.outputStream = nil
                self.outputCollector = nil
                self.command = nil
                if timedOut {
                    ThreadingLogger.remote.warning(
                        "Tailscale command timed out stage=\(stage, privacy: .public)"
                    )
                } else if status != 0 {
                    ThreadingLogger.remote.warning(
                        "Tailscale command exited stage=\(stage, privacy: .public) status=\(status, privacy: .public) output_bytes=\(capturedOutput.count, privacy: .public)"
                    )
                } else {
                    ThreadingLogger.remote.debug(
                        "Tailscale command completed stage=\(stage, privacy: .public) output_bytes=\(capturedOutput.count, privacy: .public)"
                    )
                }
                completion(status, capturedOutput)
            }
        }
    }

    private func cancelActiveCommand() {
        outputStream?.cancel()
        outputStream = nil
        outputCollector = nil
        _ = commandDeadline?.complete()
        commandDeadline = nil
        launchID = nil

        if let command, command.isRunning {
            shutdownEscalations[command.processIdentifier] = ChildProcessEscalation(
                child: command
            )
        }
        command = nil
    }

    private func cancelCommands() {
        cancelActiveCommand()
        pendingStart = nil

        _ = cleanupDeadline?.complete()
        cleanupDeadline = nil
        if let cleanupCommand, cleanupCommand.isRunning {
            shutdownEscalations[cleanupCommand.processIdentifier] = ChildProcessEscalation(
                child: cleanupCommand
            )
        }
        cleanupCommand = nil
    }

    private func finish(_ state: RemoteTransportState) {
        _ = commandDeadline?.complete()
        commandDeadline = nil
        launchID = nil
        outputStream?.cancel()
        outputStream = nil
        outputCollector = nil
        command = nil
        setState(state)
    }

    private func finishUnavailable(_ issue: TailscaleReadinessIssue, actionURL: URL? = nil) {
        readiness = .actionRequired(issue, actionURL: actionURL)
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

    /// Serve's own origin: the `*.ts.net` name on Serve's dedicated HTTPS port.
    ///
    /// **Never advertised to a phone.** Serve presents a publicly trusted certificate, so a phone
    /// told to pin it would fail at the next renewal, and a phone told to stock-trust it would be
    /// the one endpoint in the list that no fingerprint covers. The tailnet door advertises this
    /// Mac's own tailnet address and MagicDNS name on the sticky port instead, with the pin.
    nonisolated static func origin(fromStatusJSON data: Data) -> URL? {
        guard let status = try? JSONDecoder().decode(TailscaleStatus.self, from: data),
              status.backendState.lowercased() == "running",
              let name = magicDNSName(status.local?.dnsName) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = name
        components.port = RemoteTailscaleDefaults.httpsPort
        components.path = "/"
        return components.url
    }

    /// What one `tailscale status` run says about this Mac, whatever it exited with.
    ///
    /// Pure, because this is the one place two different questions are answered from the same
    /// bytes: whether the tailnet door can ever come up, and what this Mac is called on the
    /// tailnet. A failed command still carries an answer often enough to be worth reading — the
    /// CLI prints "logged out" and exits non-zero — and anything it does not recognise stays
    /// `.unknown` rather than becoming a claim.
    nonisolated static func hostFacts(exitStatus: Int32, output: Data) -> TailscaleHostFacts {
        guard exitStatus == 0 else {
            switch statusFailureIssue(from: output) {
            case .signedOut: return TailscaleHostFacts(state: .signedOut, magicDNSName: nil)
            case .stopped: return TailscaleHostFacts(state: .stopped, magicDNSName: nil)
            default: return .unknown
            }
        }
        guard let status = try? JSONDecoder().decode(TailscaleStatus.self, from: output) else {
            return .unknown
        }
        switch status.backendState.lowercased() {
        case "running":
            return TailscaleHostFacts(
                state: .running,
                magicDNSName: magicDNSName(status.local?.dnsName)
            )
        case "needslogin", "needsmachineauth", "loggedout":
            return TailscaleHostFacts(state: .signedOut, magicDNSName: nil)
        case "stopped", "starting", "nomap":
            return TailscaleHostFacts(state: .stopped, magicDNSName: nil)
        default:
            return .unknown
        }
    }

    /// The MagicDNS name without its trailing root label, or nil when the status carried none.
    ///
    /// `Self.DNSName` arrives fully qualified (`mac.tail1234.ts.net.`), and a trailing dot is a
    /// valid host in a URL that no certificate, ACL or person writes that way.
    nonisolated static func magicDNSName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let name = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
        return name.isEmpty ? nil : name
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

    /// When the tailnet has not approved Serve (or HTTPS certificates), the CLI does not fail:
    /// it prints an approval URL and polls until an admin visits it, so this output usually
    /// arrives through the command deadline killing the poll. The URL check must come first —
    /// every approval URL contains the substring "https", so the certificate wording check
    /// would otherwise swallow it and discard the one actionable thing in the output.
    nonisolated static func serveFailureIssue(
        from data: Data
    ) -> (issue: TailscaleReadinessIssue, actionURL: URL?) {
        let output = String(decoding: data, as: UTF8.self)
        let lowered = output.lowercased()
        if let url = approvalURL(in: output) {
            let issue: TailscaleReadinessIssue = url.path.lowercased().contains("https")
                ? .httpsRequired
                : .serveNotEnabled
            return (issue, url)
        }
        if lowered.contains("not enabled on your tailnet") {
            return (.serveNotEnabled, nil)
        }
        if lowered.contains("https") || lowered.contains("certificate") {
            return (.httpsRequired, nil)
        }
        if lowered.contains("permission") || lowered.contains("access denied") {
            return (.permissionDenied, nil)
        }
        return (.serveFailed, nil)
    }

    /// The admin-console approval page the CLI asks the user to visit, e.g.
    /// `https://login.tailscale.com/f/serve?node=…`. Only that host is ever offered to open,
    /// so arbitrary text in command output cannot steer the user's browser anywhere else.
    nonisolated static func approvalURL(in output: String) -> URL? {
        guard let range = output.range(
            of: #"https://login\.tailscale\.com/\S+"#,
            options: .regularExpression
        ) else { return nil }
        var candidate = String(output[range])
        while let last = candidate.last, ".,;:)]".contains(last) {
            candidate.removeLast()
        }
        return URL(string: candidate)
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

    /// `tailscale serve` blocks on the tailnet's **first** certificate issuance, which was
    /// measured at close to a minute on 2026-08-18. At the twelve seconds every other command
    /// gets, the app terminated the publish and reported a failure while Serve was still coming
    /// up — the handler landed anyway, so the door opened a minute after the page said it could
    /// not. This is the ceiling on that wait, not an expected duration; the settings page states
    /// what it is waiting for for the whole of it.
    static let publishTimeoutSeconds: TimeInterval = 90
}
