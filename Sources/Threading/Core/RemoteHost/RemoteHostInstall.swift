import CryptoKit
import Foundation

// MARK: - The binary

/// One static daemon on this Mac, named by its content.
///
/// The install directory on the host is the first bytes of the binary's SHA-256, and so is the
/// systemd instance name. A generation string cannot be either — it has spaces and parentheses —
/// and content says exactly which bytes a host runs, which a version string only claims.
struct RemoteHostBinary: Equatable, Sendable {
    let url: URL
    let architecture: RemoteHostArchitecture
    /// The whole SHA-256, hex, for verifying an upload.
    let sha256: String
    var kind: RemoteHostBinaryKind = .daemon

    var installIdentifier: String {
        String(sha256.prefix(RemoteHostDefaults.identifierHexLength))
    }

    /// Where the binary lives on the host, relative to its home.
    var remotePath: String {
        "\(kind.remoteLibraryDirectory)/\(installIdentifier)/\(kind.executableName)"
    }

    /// Hashes the file in chunks, off the main actor, bounded by the file's own size.
    static func load(
        _ kind: RemoteHostBinaryKind = .daemon,
        architecture: RemoteHostArchitecture,
        fromDirectory directory: URL
    ) throws -> RemoteHostBinary {
        guard let subdirectory = RemoteHostDefaults.binaryArchitectureDirectories[architecture] else {
            throw RemoteHostInstallError.noBinary(architecture)
        }
        let url = directory
            .appendingPathComponent(subdirectory, isDirectory: true)
            .appendingPathComponent(kind.executableName, isDirectory: false)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw RemoteHostInstallError.noBinary(architecture)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: RemoteHostInstallDefaults.hashChunkBytes),
              !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return RemoteHostBinary(url: url, architecture: architecture, sha256: digest, kind: kind)
    }
}

/// The two static binaries a host is given.
enum RemoteHostBinaryKind: Equatable, Sendable {
    /// `threading-ptyd`, run by the host's systemd user unit.
    case daemon
    /// `threading-mcp-bridge`, spawned by each remote agent as its MCP server.
    case bridge

    var executableName: String {
        switch self {
        case .daemon: return RemoteHostDefaults.daemonExecutableName
        case .bridge: return RemoteHostDefaults.bridgeExecutableName
        }
    }

    var remoteLibraryDirectory: String {
        switch self {
        case .daemon: return RemoteHostDefaults.remoteLibraryDirectory
        case .bridge: return RemoteHostDefaults.remoteBridgeLibraryDirectory
        }
    }
}

enum RemoteHostInstallDefaults {
    static let hashChunkBytes = 1024 * 1024
}

enum RemoteHostInstallError: LocalizedError, Equatable {
    case noBinary(RemoteHostArchitecture)
    case uploadFailed(String)
    case verificationFailed
    case unitFailed(String)
    case lingerRefused
    case retireTimedOut

    var errorDescription: String? {
        switch self {
        case .noBinary(let architecture):
            return "No threading-ptyd binary for \(architecture.rawValue) is configured."
        case .uploadFailed(let detail):
            return "Copying threading-ptyd to the host failed: \(detail)"
        case .verificationFailed:
            return "The copied threading-ptyd does not match the one on this Mac."
        case .unitFailed(let detail):
            return "The host's systemd user unit could not be started: \(detail)"
        case .lingerRefused:
            return "Lingering could not be enabled, so the host would stop every agent at logout."
        case .retireTimedOut:
            return "The host's older background host did not exit after being retired."
        }
    }
}

// MARK: - The plan

/// What preparing a host has to do, decided from its facts and the binary this Mac has. Pure, so
/// every combination is a unit test rather than a machine.
struct RemoteHostInstallPlan: Equatable, Sendable {
    /// Copy the binary; it is not already installed under its identifier.
    let uploadsBinary: Bool
    /// Turn lingering on. Required: without it the host ends every agent when its person logs out.
    let enablesLinger: Bool
    /// Active instances of another build, which have to be retired before this one can own the
    /// state directory — and only when they hold no sessions, which is asked through the tunnel.
    let otherActiveInstances: [String]
    /// Whether this build's own instance is already running.
    let isRunning: Bool
    /// Other instances still enabled to start at boot. Disabled — never stopped — once this
    /// build's instance runs, because the unit template is shared: an old instance left enabled
    /// comes back at the next boot on *this* build's paths, and a binary older than the
    /// state-directory lock would then take the rendezvous from the running daemon (measured on
    /// the spike's VM).
    let otherEnabledInstances: [String]

    static func make(facts: RemoteHostFacts, binary: RemoteHostBinary) -> RemoteHostInstallPlan {
        let identifier = binary.installIdentifier
        return RemoteHostInstallPlan(
            uploadsBinary: !facts.installedBinaries.contains(identifier),
            enablesLinger: facts.lingerEnabled != true,
            otherActiveInstances: facts.activeInstances.filter { $0 != identifier },
            isRunning: facts.activeInstances.contains(identifier),
            otherEnabledInstances: facts.enabledInstances.filter { $0 != identifier }
        )
    }
}

// MARK: - The remote text

enum RemoteHostInstallScripts {

    /// The templated user unit, one instance per install identifier.
    ///
    /// `Restart=on-failure` with a ten-second delay is launchd's `KeepAlive` plus `ThrottleInterval`
    /// in systemd's words, with one difference that matters: a daemon that **retires** exits 0,
    /// and that exit is not restarted, which is what lets an upgrade stop the old instance
    /// without racing it. A refused start — another daemon owns the state directory, exit 75 —
    /// is a failure and is retried. `KillMode` is left at `control-group`: stopping the unit ends
    /// its agents, exactly as a logout does on macOS, which is why nothing here ever restarts it.
    ///
    /// The socket and state paths are named rather than derived by the daemon, so the Mac knows
    /// the exact path it forwards.
    static let unitTemplate = """
        [Unit]
        Description=Threading background session host (%i)

        [Service]
        Type=simple
        ExecStart=%h/\(RemoteHostDefaults.remoteLibraryDirectory)/%i/\(RemoteHostDefaults.daemonExecutableName) --socket %h/\(RemoteHostDefaults.remoteStateDirectory)/\(RemoteHostDefaults.remoteSocketFileName) --state %h/\(RemoteHostDefaults.remoteStateDirectory)
        Restart=on-failure
        RestartSec=10

        [Install]
        WantedBy=default.target

        """

    /// Receives the binary on stdin into its content-named directory, atomically. The identifier is
    /// hex and every path is relative to the login directory, so the command line needs no quoting
    /// in any shell `ssh` hands it to.
    static func uploadCommand(for binary: RemoteHostBinary) -> String {
        let directory = "\(binary.kind.remoteLibraryDirectory)/\(binary.installIdentifier)"
        let target = binary.remotePath
        return "mkdir -p \(directory) && cat > \(target).partial && chmod 700 \(target).partial"
            + " && mv \(target).partial \(target) && sha256sum \(target)"
    }

    /// Writes the unit template from stdin.
    static let unitCommand = "mkdir -p \(RemoteHostDefaults.remoteUnitDirectory) && cat > "
        + "\(RemoteHostDefaults.remoteUnitDirectory)/\(RemoteHostDefaults.remoteUnitTemplateName)"
        + " && systemctl --user daemon-reload"

    /// Turns lingering on for the connecting user. `loginctl enable-linger` for oneself needs no
    /// privilege on Debian 12 (measured in the spike); a host that refuses it is reported.
    static let enableLingerScript = """
        set -e
        loginctl enable-linger "$(id -un)"
        [ "$(loginctl show-user "$(id -un)" -p Linger --value)" = yes ]
        """

    static func startScript(identifier: String) -> String {
        """
        set -e
        systemctl --user enable --now \(RemoteHostDefaults.remoteUnitPrefix)\(identifier)\(RemoteHostDefaults.remoteUnitSuffix)
        """
    }

    /// Disables an instance that has already exited after `retire`. Never `stop` on a running one:
    /// stopping ends its control group, agents included.
    static func disableScript(identifier: String) -> String {
        """
        set -e
        unit=\(RemoteHostDefaults.remoteUnitPrefix)\(identifier)\(RemoteHostDefaults.remoteUnitSuffix)
        if systemctl --user is-active --quiet "$unit"; then exit 3; fi
        systemctl --user disable "$unit"
        """
    }

    /// Stops an instance from starting at boot, and nothing else. `disable` without `--now` leaves
    /// a running instance running, so no agent under it is touched.
    static func disableAtBootScript(identifier: String) -> String {
        "systemctl --user disable \(RemoteHostDefaults.remoteUnitPrefix)\(identifier)\(RemoteHostDefaults.remoteUnitSuffix)"
    }

    /// Readies the host end of the socket forwarded back to this Mac: an owner-only directory, and
    /// no file where the forward will bind.
    ///
    /// The removal is what lets a new tunnel bind at all. `StreamLocalBindUnlink` is the *server's*
    /// setting for a remote forward and defaults to no, so a socket file a dropped tunnel left
    /// behind would refuse the bind, and `ExitOnForwardFailure` would end the new tunnel with it. A
    /// tunnel still bound to the old file keeps its unlinked socket and hands it no connections.
    static let prepareBridgeRendezvousScript = """
        set -e
        umask 077
        mkdir -p "$HOME/\(RemoteHostDefaults.remoteBridgeDirectory)"
        chmod 700 "$HOME/\(RemoteHostDefaults.remoteBridgeDirectory)"
        rm -f "$HOME/\(RemoteHostDefaults.remoteBridgeDirectory)/\(RemoteHostDefaults.remoteBridgeSocketFileName)"
        """

    /// Removes every install directory but the ones named, for both the daemon and the bridge.
    ///
    /// The names are hex identifiers this Mac computed, so the command needs no quoting; a directory
    /// whose name is not one of them is a build nothing runs any more. `rm -rf` reaches only inside
    /// the two install roots, and the `case` guard keeps a name that is not hex from being removed
    /// at all — a directory a person put there by hand stays.
    static func pruneScript(keeping identifiers: [String]) -> String {
        let keep = identifiers.joined(separator: " ")
        return """
            set -e
            keep="\(keep)"
            for root in "$HOME/\(RemoteHostDefaults.remoteLibraryDirectory)" \
              "$HOME/\(RemoteHostDefaults.remoteBridgeLibraryDirectory)"; do
              [ -d "$root" ] || continue
              for directory in "$root"/*; do
                [ -d "$directory" ] || continue
                name="$(basename "$directory")"
                case "$name" in
                  bridge) continue ;;
                  *[!0-9a-f]*) continue ;;
                esac
                case " $keep " in
                  *" $name "*) continue ;;
                esac
                rm -rf "$directory"
              done
            done
            """
    }

    static func isActiveScript(identifier: String) -> String {
        "systemctl --user is-active --quiet \(RemoteHostDefaults.remoteUnitPrefix)\(identifier)\(RemoteHostDefaults.remoteUnitSuffix)"
    }

    /// The hex digest `sha256sum` printed, which starts its line.
    static func reportedDigest(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let word = line.split(separator: " ").first.map(String.init) ?? ""
            if word.count == 64, word.allSatisfy(\.isHexDigit) { return word }
        }
        return nil
    }
}
