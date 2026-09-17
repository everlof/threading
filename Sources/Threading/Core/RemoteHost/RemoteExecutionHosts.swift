import Foundation
import ThreadingPTYHostKit

// MARK: - Phase

/// Why a host cannot take a launch, as a stable token for launch failures and the event log.
struct RemoteHostFailure: Error, Equatable, Sendable {
    let token: String
    let detail: String
}

/// Everything a launch needs from a prepared host.
struct RemoteHostLaunchContext: Equatable, Sendable {
    let destination: RemoteHostDestination
    let facts: RemoteHostFacts
    /// The Mac-side end of the forwarded rendezvous.
    let localSocketPath: String
}

enum RemoteHostPhase: Equatable, Sendable {
    case idle
    case preparing
    case ready(RemoteHostLaunchContext)
    case failed(RemoteHostFailure)
}

// MARK: - Tunnel

/// One `ssh -N -L <local>:<remote>` for one host, supervised.
///
/// The app's `PTYHostClient` connects to the local end and never learns the daemon is remote. The
/// tunnel's exit is the host becoming unreachable: a watcher's own writes into the local socket
/// keep succeeding for a while after the far side is gone, so the process exit is the signal.
final class RemoteHostTunnel: @unchecked Sendable {

    let localSocketPath: String
    private let child: SpawnedChildProcess
    private let diagnostics: RemoteHostDiagnosticsBuffer

    private init(localSocketPath: String, child: SpawnedChildProcess, diagnostics: RemoteHostDiagnosticsBuffer) {
        self.localSocketPath = localSocketPath
        self.child = child
        self.diagnostics = diagnostics
    }

    var isRunning: Bool { child.isRunning }
    var diagnosticText: String { diagnostics.text }

    static func open(
        destination: RemoteHostDestination,
        localSocketPath: String,
        remoteSocketPath: String,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RemoteHostTunnel {
        RemoteHostTunnelRecord.endStale(forSocketPath: localSocketPath)
        let pipe = try ChildPipe()
        let forward = "\(localSocketPath):\(remoteSocketPath)"
        let child: SpawnedChildProcess
        do {
            child = try ChildProcessSpawn.spawn(
                executableURL: URL(fileURLWithPath: RemoteHostDefaults.sshExecutable),
                arguments: destination.sshArguments(
                    extraOptions: RemoteHostDefaults.tunnelOptions + ["-L", forward]
                ),
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor: .nullDevice,
                    AgentChildProcessDefaults.standardOutputDescriptor: .inherited(pipe.writeEnd),
                    AgentChildProcessDefaults.standardErrorDescriptor: .inherited(pipe.writeEnd)
                ]
            )
        } catch {
            pipe.closeBothEnds()
            throw error
        }
        pipe.closeWriteEnd()
        RemoteHostTunnelRecord.write(pid: child.processIdentifier, forSocketPath: localSocketPath)
        let diagnostics = RemoteHostDiagnosticsBuffer(handle: pipe.takeReadHandle())
        child.observeExit { status in
            RemoteHostTunnelRecord.remove(pid: child.processIdentifier, forSocketPath: localSocketPath)
            onExit(status)
        }
        return RemoteHostTunnel(localSocketPath: localSocketPath, child: child, diagnostics: diagnostics)
    }

    /// Ends the tunnel. Sessions on the host keep running; only this Mac's path to them closes.
    func close() {
        child.terminate()
    }
}

/// Which `ssh` owns a forwarded socket, written beside it so a launch after a crash can end the
/// tunnel the crashed app left.
///
/// Without it a crash strands an `ssh -N` that keeps its keep-alives answered forever, and every
/// crash adds one. The record is a pid *and* its kernel start time, because a pid alone is a
/// number macOS hands out again: only a process that is still the one recorded is signalled.
enum RemoteHostTunnelRecord {

    private struct Record: Codable {
        let pid: Int32
        let startTime: ProcessStartTime
    }

    static let fileSuffix = ".tunnel"

    static func write(pid: pid_t, forSocketPath socketPath: String) {
        guard let startTime = ProcessUtility.startTime(forPid: pid),
              let data = try? JSONEncoder().encode(Record(pid: pid, startTime: startTime)) else { return }
        try? data.write(to: url(forSocketPath: socketPath), options: .atomic)
    }

    static func remove(pid: pid_t, forSocketPath socketPath: String) {
        let url = url(forSocketPath: socketPath)
        guard let record = read(url), record.pid == pid else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Ends the recorded tunnel if it is still the process that was recorded.
    static func endStale(forSocketPath socketPath: String) {
        let url = url(forSocketPath: socketPath)
        guard let record = read(url) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        guard ProcessUtility.startTime(forPid: record.pid) == record.startTime else { return }
        // The tunnel was spawned leading its own process group.
        kill(-record.pid, SIGTERM)
        EventLog.shared.record(.session, "Ended a remote host tunnel a previous launch left", [:])
    }

    private static func read(_ url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func url(forSocketPath socketPath: String) -> URL {
        URL(fileURLWithPath: socketPath + fileSuffix)
    }
}

/// The newest bytes a long-lived `ssh` wrote, drained on its own thread so the pipe never fills.
final class RemoteHostDiagnosticsBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    init(handle: FileHandle) {
        Thread.detachNewThread { [weak self] in
            while let chunk = try? handle.read(upToCount: RemoteHostDefaults.maximumOutputBytes),
                  !chunk.isEmpty {
                self?.append(chunk)
            }
            try? handle.close()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    private func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > RemoteHostDefaults.maximumOutputBytes {
            data.removeFirst(data.count - RemoteHostDefaults.maximumOutputBytes)
        }
        lock.unlock()
    }
}

// MARK: - Coordinator

/// Prepares hosts and keeps their tunnels, off the main actor.
///
/// A launch asks `readiness(for:binaryDirectory:)`, which never blocks: it answers the current
/// phase and starts preparation when there is none. Preparation is the whole of slice 2 as one
/// serial job per host — facts, upload, unit, linger, zero-session upgrade, start, tunnel,
/// `hello` — and every step is a bounded `ssh` command. `didChangeNotification` is posted on the
/// main queue whenever a phase changes, which is how a waiting launch retries.
final class RemoteExecutionHosts: @unchecked Sendable {

    static let shared = RemoteExecutionHosts()
    static let didChangeNotification = Notification.Name("RemoteExecutionHostsDidChange")

    private let runner: RemoteHostCommandRunning
    private let queue = DispatchQueue(label: "codes.threading.remote-hosts", qos: .userInitiated)
    /// Launch-time surveys, apart from preparation so a slow upload to one host never delays a
    /// session on a host that is already prepared.
    private let surveyQueue = DispatchQueue(
        label: "codes.threading.remote-hosts.survey",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var phases: [RemoteHostDestination: RemoteHostPhase] = [:]
    private var tunnels: [RemoteHostDestination: RemoteHostTunnel] = [:]
    private let build: String
    /// The `0700` directory holding the forwarded sockets. Injectable because a unix socket path is
    /// bounded (`PTYHostDefaults.maximumSocketPathBytes`) and a hosted test's scratch root alone is
    /// most of that.
    private let localDirectory: URL

    init(
        runner: RemoteHostCommandRunning = SystemSSHCommandRunner(),
        build: String = PTYHostBuild.string(),
        localDirectory: URL = PTYHostLocation.supportRoot
            .appendingPathComponent(RemoteHostDefaults.localDirectoryName, isDirectory: true)
    ) {
        self.runner = runner
        self.build = build
        self.localDirectory = localDirectory
    }

    // MARK: - Public Methods

    /// Whether this coordinator's tunnel to a host is running. For tests and diagnostics.
    func tunnelIsRunning(for destination: RemoteHostDestination) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tunnels[destination]?.isRunning == true
    }

    func phase(for destination: RemoteHostDestination) -> RemoteHostPhase {
        lock.lock()
        defer { lock.unlock() }
        return phases[destination] ?? .idle
    }

    /// The host's phase now, starting preparation if it is idle or failed. Never blocks.
    ///
    /// A failed host is retried when a launch asks again, not on a timer: the failure is shown on
    /// the session that asked, and the person's next attempt is the retry.
    func readiness(
        for destination: RemoteHostDestination,
        binaryDirectory: URL?
    ) -> RemoteHostPhase {
        lock.lock()
        let current = phases[destination] ?? .idle
        let startsPreparation: Bool
        switch current {
        case .idle, .failed:
            phases[destination] = .preparing
            startsPreparation = true
        case .ready(let context):
            // A tunnel that died since is a host that needs preparing again.
            if tunnels[destination]?.isRunning != true || context.localSocketPath.isEmpty {
                phases[destination] = .preparing
                startsPreparation = true
            } else {
                startsPreparation = false
            }
        case .preparing:
            startsPreparation = false
        }
        let answer = phases[destination] ?? .idle
        lock.unlock()

        if startsPreparation {
            postChange()
            queue.async { [weak self] in
                self?.prepare(destination, binaryDirectory: binaryDirectory)
            }
        }
        return answer
    }

    /// What a prepared host's daemon holds, asked off the main actor and answered on it — nil when
    /// the daemon could not be asked.
    ///
    /// A launch asks this before spawning, because a session the daemon is still running is one to
    /// reattach to: spawning would replace it, ending an agent that has been working since the app
    /// last quit.
    func holdings(
        socketPath: String,
        completion: @escaping @MainActor @Sendable ([PTYHostSessionSummary]?) -> Void
    ) {
        let build = self.build
        surveyQueue.async {
            let sessions = RemoteHostDaemonAdmin.sessions(socketPath: socketPath, build: build)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(sessions) }
            }
        }
    }

    /// Closes every tunnel. At app termination; sessions on the hosts keep running.
    func closeAllTunnels() {
        lock.lock()
        let open = Array(tunnels.values)
        tunnels.removeAll()
        phases.removeAll()
        lock.unlock()
        open.forEach { $0.close() }
    }

    // MARK: - Private Methods — preparation

    private func prepare(_ destination: RemoteHostDestination, binaryDirectory: URL?) {
        let outcome: RemoteHostPhase
        do {
            outcome = .ready(try prepareOrThrow(destination, binaryDirectory: binaryDirectory))
        } catch let failure as RemoteHostFailure {
            outcome = .failed(failure)
        } catch {
            outcome = .failed(RemoteHostFailure(token: "unexpected", detail: error.localizedDescription))
        }
        if case .failed(let failure) = outcome {
            EventLog.shared.record(.session, "Remote host could not be prepared", [
                "host": destination.identifier,
                "cause": failure.token
            ])
            ThreadingLogger.ptyHost.error(
                "Remote host \(destination.identifier, privacy: .private(mask: .hash)) failed: \(failure.token, privacy: .public) \(failure.detail, privacy: .private(mask: .hash))"
            )
        }
        lock.lock()
        phases[destination] = outcome
        lock.unlock()
        postChange()
    }

    private func prepareOrThrow(
        _ destination: RemoteHostDestination,
        binaryDirectory: URL?
    ) throws -> RemoteHostLaunchContext {
        guard destination.isValid else {
            throw RemoteHostFailure(token: "invalidDestination", detail: destination.alias)
        }
        let facts = try readFacts(destination)
        guard let architecture = facts.architecture else {
            throw RemoteHostFailure(token: "unsupportedArchitecture", detail: facts.machine)
        }
        guard facts.hasSystemd else {
            throw RemoteHostFailure(token: "noSystemd", detail: "systemctl was not found")
        }
        guard let binaryDirectory else {
            throw RemoteHostFailure(token: "noBinaryDirectory", detail: "no binary directory is configured")
        }
        let binary: RemoteHostBinary
        do {
            binary = try RemoteHostBinary.load(architecture: architecture, fromDirectory: binaryDirectory)
        } catch {
            throw RemoteHostFailure(token: "noBinary", detail: error.localizedDescription)
        }
        let plan = RemoteHostInstallPlan.make(facts: facts, binary: binary)

        if plan.uploadsBinary { try upload(binary, to: destination) }
        try run(destination, RemoteHostInstallScripts.unitCommand,
                input: .data(Data(RemoteHostInstallScripts.unitTemplate.utf8)), token: "unitWriteFailed")
        if plan.enablesLinger {
            try runScript(destination, RemoteHostInstallScripts.enableLingerScript, token: "lingerRefused")
        }

        let localSocketPath = try localSocketPath(for: destination)
        let tunnel = try openTunnel(destination, localSocketPath: localSocketPath, remoteSocketPath: facts.remoteSocketPath)

        var runsOwnInstance = plan.isRunning
        if !plan.isRunning {
            // Another build may own the state directory. It is retired only when it holds nothing;
            // otherwise it keeps serving — a compatible older host is still a durable one — and the
            // upgrade waits for a later preparation. An instance that does not answer at this
            // rendezvous was started with other paths, shares no state directory with ours, and is
            // left exactly as it is: it may hold somebody's agents.
            var otherStillServing = false
            for instance in plan.otherActiveInstances {
                switch try retireIfIdle(instance, on: destination, localSocketPath: localSocketPath) {
                case .retired, .elsewhere:
                    continue
                case .stillServing:
                    otherStillServing = true
                }
            }
            if !otherStillServing {
                try runScript(destination, RemoteHostInstallScripts.startScript(identifier: binary.installIdentifier),
                              token: "unitStartFailed")
                runsOwnInstance = true
            }
        }

        try waitUntilAnswering(localSocketPath: localSocketPath, tunnel: tunnel)
        ThreadingLogger.ptyHost.info(
            "Remote host \(destination.identifier, privacy: .private(mask: .hash)) ready (own instance: \(runsOwnInstance, privacy: .public))"
        )
        return RemoteHostLaunchContext(destination: destination, facts: facts, localSocketPath: localSocketPath)
    }

    private func readFacts(_ destination: RemoteHostDestination) throws -> RemoteHostFacts {
        let result = try runCommand(destination, "sh -s", input: .data(Data(RemoteHostFacts.probeScript.utf8)),
                                    timeout: RemoteHostDefaults.factsTimeout)
        guard result.succeeded else {
            throw RemoteHostFailure(token: result.termination == .timedOut ? "unreachable.timeout" : "unreachable",
                                    detail: result.output)
        }
        do {
            return try RemoteHostFacts.parse(result.output)
        } catch {
            throw RemoteHostFailure(token: "factsUnreadable", detail: error.localizedDescription)
        }
    }

    private func upload(_ binary: RemoteHostBinary, to destination: RemoteHostDestination) throws {
        let result = try runCommand(
            destination,
            RemoteHostInstallScripts.uploadCommand(for: binary),
            input: .file(binary.url),
            extraOptions: RemoteHostDefaults.compressionOptions,
            timeout: RemoteHostDefaults.uploadTimeout
        )
        guard result.succeeded else {
            throw RemoteHostFailure(token: "uploadFailed", detail: result.output)
        }
        guard RemoteHostInstallScripts.reportedDigest(in: result.output) == binary.sha256 else {
            throw RemoteHostFailure(token: "uploadVerificationFailed", detail: result.output)
        }
    }

    private enum OtherInstanceDisposition {
        case retired
        case stillServing
        /// Nothing answers at this rendezvous, so the instance lives on other paths.
        case elsewhere
    }

    /// Retires an instance holding no active sessions and disables it once it has exited. Touches
    /// nothing when it holds sessions, or when it is not the daemon at this rendezvous.
    private func retireIfIdle(
        _ instance: String,
        on destination: RemoteHostDestination,
        localSocketPath: String
    ) throws -> OtherInstanceDisposition {
        switch PTYHostClient.probe(socketPath: localSocketPath, build: build) {
        case .notRunning:
            ThreadingLogger.ptyHost.info(
                "Remote host instance \(instance, privacy: .private(mask: .hash)) is not at this rendezvous; left running"
            )
            return .elsewhere
        case .mismatched(let compatibility):
            throw RemoteHostFailure(token: "daemonIncompatible", detail: "\(instance): \(compatibility)")
        case .ready:
            break
        }
        guard let held = RemoteHostDaemonAdmin.activeSessionCount(socketPath: localSocketPath, build: build) else {
            throw RemoteHostFailure(token: "upgradeSurveyFailed", detail: instance)
        }
        guard held == 0 else { return .stillServing }
        guard RemoteHostDaemonAdmin.retire(socketPath: localSocketPath, build: build) else {
            throw RemoteHostFailure(token: "retireFailed", detail: instance)
        }
        let deadline = Date().addingTimeInterval(RemoteHostDefaults.retireExitTimeout)
        while Date() < deadline {
            let active = try runCommand(destination, RemoteHostInstallScripts.isActiveScript(identifier: instance),
                                        input: .none, timeout: RemoteHostDefaults.commandTimeout)
            if active.termination == .exited(0) {
                Thread.sleep(forTimeInterval: RemoteHostDefaults.tunnelReadyPollInterval)
                continue
            }
            try runScript(destination, RemoteHostInstallScripts.disableScript(identifier: instance),
                          token: "disableFailed")
            return .retired
        }
        throw RemoteHostFailure(token: "retireTimedOut", detail: instance)
    }

    private func openTunnel(
        _ destination: RemoteHostDestination,
        localSocketPath: String,
        remoteSocketPath: String
    ) throws -> RemoteHostTunnel {
        lock.lock()
        let previous = tunnels.removeValue(forKey: destination)
        lock.unlock()
        previous?.close()

        let tunnel: RemoteHostTunnel
        do {
            tunnel = try RemoteHostTunnel.open(
                destination: destination,
                localSocketPath: localSocketPath,
                remoteSocketPath: remoteSocketPath,
                onExit: { [weak self] status in self?.tunnelExited(destination, status: status) }
            )
        } catch {
            throw RemoteHostFailure(token: "tunnelSpawnFailed", detail: error.localizedDescription)
        }
        lock.lock()
        tunnels[destination] = tunnel
        lock.unlock()
        return tunnel
    }

    private func tunnelExited(_ destination: RemoteHostDestination, status: Int32) {
        lock.lock()
        let wasReady: Bool
        if case .ready = phases[destination] { wasReady = true } else { wasReady = false }
        if wasReady {
            phases[destination] = .failed(RemoteHostFailure(token: "tunnelExited", detail: "ssh exited \(status)"))
        }
        lock.unlock()
        if wasReady {
            EventLog.shared.record(.session, "Remote host tunnel closed", [
                "host": destination.identifier,
                "status": String(status)
            ])
            postChange()
        }
    }

    private func waitUntilAnswering(localSocketPath: String, tunnel: RemoteHostTunnel) throws {
        let deadline = Date().addingTimeInterval(RemoteHostDefaults.tunnelReadyTimeout)
        var lastOutcome = PTYHostProbeOutcome.notRunning
        while Date() < deadline {
            guard tunnel.isRunning else {
                throw RemoteHostFailure(token: "tunnelExited", detail: tunnel.diagnosticText)
            }
            if FileManager.default.fileExists(atPath: localSocketPath) {
                lastOutcome = PTYHostClient.probe(socketPath: localSocketPath, build: build)
                if lastOutcome == .ready { return }
                if case .mismatched = lastOutcome {
                    throw RemoteHostFailure(token: "daemonIncompatible", detail: "\(lastOutcome)")
                }
            }
            Thread.sleep(forTimeInterval: RemoteHostDefaults.tunnelReadyPollInterval)
        }
        throw RemoteHostFailure(token: "daemonNotAnswering", detail: tunnel.diagnosticText)
    }

    private func localSocketPath(for destination: RemoteHostDestination) throws -> String {
        let directory = localDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: RemoteHostDefaults.localDirectoryPermissions]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: RemoteHostDefaults.localDirectoryPermissions],
                ofItemAtPath: directory.path
            )
        } catch {
            throw RemoteHostFailure(token: "localDirectoryFailed", detail: error.localizedDescription)
        }
        let path = directory
            .appendingPathComponent(destination.identifier + RemoteHostDefaults.localSocketSuffix)
            .path
        guard let addressable = PTYHostLocation.addressableSocketPath(path) else {
            throw RemoteHostFailure(token: "socketPathTooLong", detail: path)
        }
        return addressable
    }

    // MARK: - Private Methods — commands

    private func runCommand(
        _ destination: RemoteHostDestination,
        _ command: String,
        input: RemoteHostCommandInput,
        extraOptions: [String] = [],
        timeout: TimeInterval
    ) throws -> RemoteHostCommandResult {
        do {
            return try runner.run(on: destination, command: command, input: input,
                                  extraOptions: extraOptions, timeout: timeout)
        } catch {
            throw RemoteHostFailure(token: "sshSpawnFailed", detail: error.localizedDescription)
        }
    }

    private func run(
        _ destination: RemoteHostDestination,
        _ command: String,
        input: RemoteHostCommandInput,
        token: String
    ) throws {
        let result = try runCommand(destination, command, input: input, timeout: RemoteHostDefaults.commandTimeout)
        guard result.succeeded else { throw RemoteHostFailure(token: token, detail: result.output) }
    }

    private func runScript(_ destination: RemoteHostDestination, _ script: String, token: String) throws {
        try run(destination, "sh -s", input: .data(Data(script.utf8)), token: token)
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

// MARK: - Daemon administration

/// The two questions preparation asks a remote daemon through its tunnel, synchronously and
/// bounded: how many sessions it holds, and — only when that is zero — retire.
enum RemoteHostDaemonAdmin {

    static func activeSessionCount(socketPath: String, build: String) -> Int? {
        sessions(socketPath: socketPath, build: build)?.filter { $0.exit == nil }.count
    }

    /// Everything the daemon at `socketPath` holds, or nil when it could not be asked.
    /// **Blocking**; never on the main actor.
    static func sessions(socketPath: String, build: String) -> [PTYHostSessionSummary]? {
        let answer = PTYHostLatch<[PTYHostSessionSummary]>()
        let client = PTYHostClient(
            socketPath: socketPath,
            build: build,
            events: PTYHostClient.Events(
                frame: { frame in
                    guard case .sessions(let sessions) = frame else { return }
                    answer.complete(sessions)
                },
                closed: { _ in answer.abandon() }
            )
        )
        defer { client.close() }
        guard (try? client.connect()) != nil, (try? client.list()) != nil else { return nil }
        return answer.wait(PTYHostDefaults.helloTimeout)
    }

    static func retire(socketPath: String, build: String) -> Bool {
        let client = PTYHostClient(socketPath: socketPath, build: build, events: .ignored)
        defer { client.close() }
        guard (try? client.connect()) != nil, (try? client.retire()) != nil else { return false }
        return client.drainWrites(until: Date().addingTimeInterval(PTYHostDefaults.helloTimeout))
    }
}
