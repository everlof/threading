import Foundation

// MARK: - Workroom Tunnel

/// How a Linked Workrooms portal reaches people outside this Mac. The tunnel publishes only the
/// participant portal's loopback port — never MCP, Remote Access or anything else — and its
/// provider terminates TLS, so it can read the traffic it carries. The approval sheet says so.
/// See `docs/decisions/workroom-participant-tunnel.md`.
enum WorkroomTunnelProvider: String, CaseIterable, Sendable {
    /// The user's own ngrok account: a stable address when they have a reserved domain.
    case ngrok
    /// A Cloudflare Quick Tunnel: free and accountless, with an address that changes every time
    /// Threading starts it — fine for trying, wrong for someone who answers days later.
    case cloudflare

    var displayName: String {
        switch self {
        case .ngrok: return "ngrok"
        case .cloudflare: return "Cloudflare Quick Tunnel" // localization-ignore: product name
        }
    }
}

enum WorkroomTunnelState: Equatable, Sendable {
    case stopped
    case starting
    case connected(URL)
    case unavailable(String)
}

/// What differs between providers: where the executable is, how it is started, and where its
/// output names the public address.
struct WorkroomTunnelRecipe: Sendable {
    let provider: WorkroomTunnelProvider
    let executableNames: [String]
    /// Arguments for the loopback port and a private 0700 directory the recipe may write to.
    let arguments: @Sendable (_ port: UInt16, _ privateDirectory: URL) throws -> [String]
    let publicURL: @Sendable (_ output: String) -> URL?

    static func cloudflare() -> WorkroomTunnelRecipe {
        WorkroomTunnelRecipe(
            provider: .cloudflare,
            executableNames: ["cloudflared"],
            arguments: { port, _ in
                ["tunnel", "--config", "/dev/null", "--no-autoupdate", "--loglevel", "info",
                 "--url", "http://127.0.0.1:\(port)"]
            },
            publicURL: { output in
                output.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression)
                    .flatMap { URL(string: String(output[$0])) }
            }
        )
    }

    /// The user's own ngrok configuration (and so their account), merged with an overlay that
    /// switches off the agent's local web API: with it on, any process of this user could ask
    /// the running agent to open more tunnels on the account. A domain, when given, is a reserved
    /// one; without it ngrok assigns the account's address.
    static func ngrok(domain: String?, userConfiguration: URL? = WorkroomTunnelRecipe.defaultNgrokConfiguration())
        -> WorkroomTunnelRecipe {
        WorkroomTunnelRecipe(
            provider: .ngrok,
            executableNames: ["ngrok"],
            arguments: { port, directory in
                let overlay = directory.appendingPathComponent("ngrok-overlay.yml")
                try Data("version: \"3\"\nagent:\n  web_addr: false\n".utf8).write(to: overlay, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: overlay.path)
                // One flag per file: ngrok merges them in order, and a path is never split on a comma.
                let configs = ([userConfiguration].compactMap { $0 } + [overlay]).flatMap { ["--config", $0.path] }
                var arguments = ["http", "127.0.0.1:\(port)", "--log", "stdout", "--log-format", "json"] + configs
                if let domain { arguments += ["--url", "https://\(domain)"] }
                return arguments
            },
            publicURL: { output in
                // Only the line announcing the tunnel: other log lines name other URLs.
                for line in output.split(separator: "\n") where line.contains(#""msg":"started tunnel""#) {
                    if let range = line.range(of: #""url":"https://[A-Za-z0-9.-]+""#, options: .regularExpression) {
                        return URL(string: String(line[range].dropFirst(7).dropLast()))
                    }
                }
                return nil
            }
        )
    }

    nonisolated static func defaultNgrokConfiguration(fileManager: FileManager = .default) -> URL? {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ngrok/ngrok.yml")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// A reserved domain is a hostname, nothing more: no scheme, path or port.
    static func isValidDomain(_ value: String) -> Bool {
        (4...253).contains(value.utf8.count) && value.contains(".")
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
            && !value.hasPrefix(".") && !value.hasPrefix("-") && !value.hasSuffix(".")
    }

    nonisolated func executableURL(fileManager: FileManager = .default,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = executableNames.flatMap { ["/opt/homebrew/bin/\($0)", "/usr/local/bin/\($0)"] }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates += executableNames.map { URL(fileURLWithPath: String(directory)).appendingPathComponent($0).path }
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// One supervised tunnel process. Spawned through the app's child-process ledger, so a crash
/// leaves nothing the next launch cannot find; its address is read from its own output.
@MainActor
final class WorkroomTunnel {

    private(set) var state: WorkroomTunnelState = .stopped
    let recipe: WorkroomTunnelRecipe
    private let childLedger: AgentChildLedger
    private let locateExecutable: () -> URL?
    private let startupTimeout: Duration
    private var process: SpawnedChildProcess?
    private var outputStream: ChildOutputStream?
    private var launchID: UUID?
    private var outputBuffer = Data()
    private var startupDeadline: Task<Void, Never>?
    private var privateDirectory: URL?
    private var shutdownEscalations: [pid_t: ChildProcessEscalation] = [:]
    private var onStateChange: (@MainActor @Sendable (WorkroomTunnelState) -> Void)?

    init(recipe: WorkroomTunnelRecipe, childLedger: AgentChildLedger = .shared,
         locateExecutable: (() -> URL?)? = nil,
         startupTimeout: Duration = .seconds(WorkroomTunnelDefaults.startupTimeoutSeconds)) {
        self.recipe = recipe
        self.childLedger = childLedger
        self.locateExecutable = locateExecutable ?? { recipe.executableURL() }
        self.startupTimeout = startupTimeout
    }

    func start(port: UInt16, onStateChange: @escaping @MainActor @Sendable (WorkroomTunnelState) -> Void) {
        stop()
        self.onStateChange = onStateChange
        guard let executable = locateExecutable() else {
            return fail(L10n.format("%@ is not installed. Install it with Homebrew, or choose another way in.",
                                    recipe.provider.displayName))
        }
        let launchID = UUID()
        self.launchID = launchID
        setState(.starting)
        let recipe = self.recipe
        // The private directory and any configuration file in it are written off the main actor.
        Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) { Self.prepare(recipe, port: port) }.value
            guard let self, self.launchID == launchID else {
                if let directory = prepared?.directory { Self.remove(directory) }
                return
            }
            guard let prepared else { return self.fail(L10n.string("The tunnel could not start.")) }
            self.privateDirectory = prepared.directory
            self.spawn(executable, arguments: prepared.arguments, launchID: launchID)
        }
    }

    private struct Prepared: Sendable {
        let directory: URL
        let arguments: [String]
    }

    nonisolated private static func prepare(_ recipe: WorkroomTunnelRecipe, port: UInt16) -> Prepared? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-workroom-tunnel-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            return Prepared(directory: directory, arguments: try recipe.arguments(port, directory))
        } catch {
            remove(directory)
            return nil
        }
    }

    nonisolated private static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func spawn(_ executable: URL, arguments: [String], launchID: UUID) {
        let pipe: ChildPipe
        do {
            pipe = try ChildPipe()
        } catch {
            removePrivateDirectory()
            return fail(L10n.string("The tunnel could not start."))
        }
        let process: SpawnedChildProcess
        do {
            process = try ChildProcessSpawn.spawn(
                executableURL: executable, arguments: arguments,
                environment: ProcessInfo.processInfo.environment, workingDirectory: nil,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor: .nullDevice,
                    AgentChildProcessDefaults.standardOutputDescriptor: .inherited(pipe.writeEnd),
                    AgentChildProcessDefaults.standardErrorDescriptor: .inherited(pipe.writeEnd)
                ])
            pipe.closeWriteEnd()
        } catch {
            pipe.closeBothEnds()
            removePrivateDirectory()
            return fail(L10n.string("The tunnel could not start."))
        }
        guard childLedger.recordSpawnedChild(process, sessionID: nil, executable: executable.path) == .recorded else {
            pipe.closeBothEnds()
            let escalation = ChildProcessEscalation(child: process)
            process.observeExit { _ in escalation.complete() }
            removePrivateDirectory()
            return fail(L10n.string("The tunnel could not start."))
        }
        self.process = process
        outputStream = ChildOutputStream(readEnd: pipe.takeReadDescriptor()) { [weak self, weak process] data in
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
                self.releaseChild()
                self.fail(L10n.format("The tunnel stopped (exit %d).", Int(status)))
            }
        }
        startupDeadline = Task { [weak self] in
            try? await Task.sleep(for: self?.startupTimeout ?? .seconds(WorkroomTunnelDefaults.startupTimeoutSeconds))
            guard !Task.isCancelled, let self, self.launchID == launchID, self.state == .starting else { return }
            // A tunnel nothing here tracks must not keep a public address pointed at the portal.
            self.fail(L10n.string("The tunnel did not publish an address in time."))
            self.releaseChild()
        }
    }

    func stop() {
        startupDeadline?.cancel()
        startupDeadline = nil
        releaseChild()
        onStateChange = nil
        state = .stopped
    }

    private func releaseChild() {
        outputStream?.cancel()
        outputStream = nil
        outputBuffer.removeAll(keepingCapacity: true)
        let old = process
        process = nil
        launchID = nil
        if let old, old.isRunning {
            shutdownEscalations[old.processIdentifier] = ChildProcessEscalation(child: old)
        }
        removePrivateDirectory()
    }

    private func removePrivateDirectory() {
        guard let directory = privateDirectory else { return }
        privateDirectory = nil
        Task.detached(priority: .utility) { Self.remove(directory) }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        if outputBuffer.count > WorkroomTunnelDefaults.maximumOutputBytes {
            outputBuffer = Data(outputBuffer.suffix(WorkroomTunnelDefaults.retainedOutputBytes))
        }
        guard state == .starting, let url = recipe.publicURL(String(decoding: outputBuffer, as: UTF8.self)) else { return }
        startupDeadline?.cancel()
        startupDeadline = nil
        setState(.connected(url))
    }

    private func fail(_ message: String) {
        startupDeadline?.cancel()
        startupDeadline = nil
        setState(.unavailable(message))
    }

    private func setState(_ state: WorkroomTunnelState) {
        guard self.state != state else { return }
        self.state = state
        onStateChange?(state)
    }
}

enum WorkroomTunnelDefaults {
    static let maximumOutputBytes = 64 * 1024
    static let retainedOutputBytes = 32 * 1024
    static let startupTimeoutSeconds = 45
}
