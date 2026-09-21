import CryptoKit
import Foundation

// MARK: - Defaults

/// Every constant the remote execution host path has, in one namespace.
///
/// The plan and the measurements behind these numbers are
/// `docs/feature-drafts/remote-execution-hosts.md` (the remote-session spike).
enum RemoteHostDefaults {

    // MARK: - ssh

    /// The system OpenSSH client. The first release reuses the person's own keys, agent,
    /// `known_hosts` and `~/.ssh/config` rather than carrying an SSH implementation.
    static let sshExecutable = "/usr/bin/ssh"

    /// Options every invocation carries. `BatchMode` because nothing here can answer a password or
    /// host-key prompt, and a prompt nobody sees is a hang; the keep-alives are the spike's, so a
    /// dead path is noticed in about fifteen seconds rather than at the next write.
    static let commonOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=3"
    ]

    /// The tunnel's own options. `ExitOnForwardFailure` turns a forward that could not be set up
    /// into a process exit the supervisor sees; `StreamLocalBindUnlink` lets a restarted tunnel
    /// replace the socket file a previous one left behind.
    ///
    /// **Never multiplexed.** With `ControlMaster`/`ControlPersist` in the person's config — Lima
    /// writes both, and many hand-written configs have them — `ssh -N -L` hands the forward to the
    /// shared master and exits 0 at once (measured), so the supervisor would read a live tunnel as
    /// a dead one, and a dead master as nothing at all. A dedicated connection makes the process's
    /// life the tunnel's life, which is the signal the supervisor depends on.
    static let tunnelOptions = [
        "-N",
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "StreamLocalBindUnlink=yes"
    ]

    /// Compression for the binary upload: a stripped static daemon is ~57 MB and compresses to
    /// ~22 MB (measured).
    static let compressionOptions = ["-o", "Compression=yes"]

    // MARK: - Bounds

    static let factsTimeout: TimeInterval = 30
    static let commandTimeout: TimeInterval = 30
    static let uploadTimeout: TimeInterval = 15 * 60
    static let maximumOutputBytes = 64 * 1024
    /// How long a new tunnel has to answer `hello` before the host is reported unreachable.
    static let tunnelReadyTimeout: TimeInterval = 20
    static let tunnelReadyPollInterval: TimeInterval = 0.2
    /// How long a retired daemon of another build is given to exit before the upgrade is abandoned
    /// for this attempt.
    static let retireExitTimeout: TimeInterval = 15

    // MARK: - Remote layout (relative to the remote home)

    static let remoteLibraryDirectory = ".local/lib/threading"
    static let remoteStateDirectory = ".local/state/threading/pty"
    static let remoteSocketFileName = "ptyd.sock"
    static let remoteUnitDirectory = ".config/systemd/user"
    static let remoteUnitTemplateName = "threading-ptyd@.service"
    static let remoteUnitPrefix = "threading-ptyd@"
    static let remoteUnitSuffix = ".service"
    static let daemonExecutableName = "threading-ptyd"

    // MARK: - Remote layout of the tool bridge (relative to the remote home)

    /// Content-named like the daemon's, in its own directory, because the two upgrade apart: a
    /// new bridge needs no daemon retired, and a new daemon strands no running bridge.
    static let remoteBridgeLibraryDirectory = ".local/lib/threading/bridge"
    static let bridgeExecutableName = "threading-mcp-bridge"
    /// The `0700` directory holding the socket forwarded *back* to this Mac's MCP rendezvous.
    static let remoteBridgeDirectory = ".local/state/threading/bridge"
    static let remoteBridgeSocketFileName = "mcp.sock"
    /// One catalogue cache per session, as `MCPSessionRegistry` names them on the Mac.
    static let remoteBridgeCacheDirectory = ".local/state/threading/bridge/catalogues"
    /// Per-session `--settings` and `--mcp-config` files, written by the launch itself, `0600`.
    static let remoteSessionFilesDirectory = ".local/state/threading/sessions"

    // MARK: - Local layout

    /// The `0700` directory under `Application Support/Threading` holding one forwarded socket per
    /// host. Its permissions are the boundary, exactly as for the local rendezvous.
    static let localDirectoryName = "remote-hosts"
    static let localDirectoryPermissions = 0o700
    static let localSocketSuffix = ".sock"
    /// Hex characters of a SHA-256 used in a local socket name or a remote install directory.
    /// Sixteen keeps a forwarded socket path well inside `sun_path`'s 104 bytes.
    static let identifierHexLength = 16

    // MARK: - Hidden settings

    /// Where the developer setting says the Linux binaries are: `<dir>/arm64/threading-ptyd`,
    /// `<dir>/amd64/threading-mcp-bridge` and so on, as `scripts/test-ptyd-linux.sh` writes them.
    static let binaryArchitectureDirectories: [RemoteHostArchitecture: String] = [
        .arm64: "arm64",
        .amd64: "amd64"
    ]
}

// MARK: - Destination

/// One host, as `ssh` names it: an alias or `user@host`, and optionally the config file that
/// defines it (a Lima VM's generated `ssh.config`, for example).
struct RemoteHostDestination: Hashable, Codable, Sendable {
    let alias: String
    let configFile: String?

    /// Refuses a name `ssh` would read as an option or split into words.
    ///
    /// `-oProxyCommand=…` as a "host" is the classic argument injection against a tool that
    /// shells out to `ssh`; a destination here is data, so anything but a plain host token is
    /// refused rather than escaped.
    var isValid: Bool {
        guard !alias.isEmpty, !alias.hasPrefix("-") else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard alias.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return false }
        if let configFile {
            guard configFile.hasPrefix("/"), !configFile.contains("\0") else { return false }
        }
        return true
    }

    /// A stable, short, filesystem-safe name for this destination.
    var identifier: String {
        let material = alias + "\u{0}" + (configFile ?? "")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(RemoteHostDefaults.identifierHexLength)
            .description
    }

    /// `ssh` arguments up to and including the destination. The remote command, if any, follows.
    func sshArguments(extraOptions: [String] = []) -> [String] {
        var arguments: [String] = []
        if let configFile { arguments += ["-F", configFile] }
        arguments += RemoteHostDefaults.commonOptions
        arguments += extraOptions
        // `--` so nothing after it is parsed as an option even if validation were bypassed.
        arguments += ["--", alias]
        return arguments
    }
}

// MARK: - Commands

/// What one bounded `ssh` command came to.
struct RemoteHostCommandResult: Equatable, Sendable {
    let output: String
    let termination: BoundedChildTermination

    var succeeded: Bool { termination == .exited(0) }
}

/// Where a remote command's standard input comes from.
enum RemoteHostCommandInput: Sendable {
    case none
    /// Bytes written to the command's stdin, then end of file. For scripts, which are fed to
    /// `sh -s` rather than passed as an argument, so the remote login shell — which parses a
    /// command-line argument — never has to understand POSIX quoting.
    case data(Data)
    /// A local file, read by the child directly. For the daemon binary.
    case file(URL)
}

/// Runs one finite command on a host.
protocol RemoteHostCommandRunning: Sendable {
    func run(
        on destination: RemoteHostDestination,
        command: String,
        input: RemoteHostCommandInput,
        extraOptions: [String],
        timeout: TimeInterval
    ) throws -> RemoteHostCommandResult
}

enum RemoteHostCommandError: LocalizedError, Equatable {
    case inputUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .inputUnreadable(let path):
            return "Could not read \(path)"
        }
    }
}

/// The system `ssh`, in its own process group, with a deadline, a bounded capture and stdin.
///
/// Blocking; called only from `RemoteExecutionHosts`' worker queue, never from the main actor.
struct SystemSSHCommandRunner: RemoteHostCommandRunning {

    func run(
        on destination: RemoteHostDestination,
        command: String,
        input: RemoteHostCommandInput,
        extraOptions: [String] = [],
        timeout: TimeInterval
    ) throws -> RemoteHostCommandResult {
        let outputPipe = try ChildPipe()
        var inputPipe: ChildPipe?
        var inputFile: Int32 = -1
        let standardInput: ChildDescriptorSource
        switch input {
        case .none:
            standardInput = .nullDevice
        case .data:
            let pipe = try ChildPipe(closingOnFailure: [outputPipe])
            inputPipe = pipe
            standardInput = .inherited(pipe.readEnd)
        case .file(let url):
            inputFile = open(url.path, O_RDONLY | O_CLOEXEC)
            guard inputFile >= 0 else {
                outputPipe.closeBothEnds()
                throw RemoteHostCommandError.inputUnreadable(url.path)
            }
            standardInput = .inherited(inputFile)
        }

        let child: SpawnedChildProcess
        do {
            child = try ChildProcessSpawn.spawn(
                executableURL: URL(fileURLWithPath: RemoteHostDefaults.sshExecutable),
                arguments: destination.sshArguments(extraOptions: extraOptions) + [command],
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: nil,
                descriptors: [
                    AgentChildProcessDefaults.standardInputDescriptor: standardInput,
                    AgentChildProcessDefaults.standardOutputDescriptor:
                        .inherited(outputPipe.writeEnd),
                    AgentChildProcessDefaults.standardErrorDescriptor:
                        .inherited(outputPipe.writeEnd)
                ]
            )
        } catch {
            outputPipe.closeBothEnds()
            inputPipe?.closeBothEnds()
            if inputFile >= 0 { close(inputFile) }
            throw error
        }

        outputPipe.closeWriteEnd()
        if inputFile >= 0 { close(inputFile) }
        if let inputPipe, case .data(let bytes) = input {
            inputPipe.closeReadEnd()
            let writer = inputPipe.takeWriteHandle()
            // Written on its own thread: a script larger than the pipe buffer would otherwise
            // block here while the child blocks writing output nobody is reading yet.
            Thread.detachNewThread {
                try? writer.write(contentsOf: bytes)
                try? writer.close()
            }
        }

        let output = outputPipe.takeReadHandle()
        let deadline = ChildProcessDeadline(
            child: child,
            timeout: timeout,
            terminationGrace: BoundedChildDefaults.terminationGrace
        )
        let capture = BoundedChildProcess.captureSuffix(
            from: output,
            maximumBytes: RemoteHostDefaults.maximumOutputBytes
        )
        child.waitUntilExit()
        let timedOut = deadline.complete()
        try? output.close()

        return RemoteHostCommandResult(
            output: String(decoding: capture.data, as: UTF8.self),
            termination: timedOut ? .timedOut : .exited(child.terminationStatus)
        )
    }
}

extension RemoteHostRecord {
    var sshDestination: RemoteHostDestination {
        RemoteHostDestination(alias: destination, configFile: sshConfigFile)
    }
}
