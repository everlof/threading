import Foundation

// MARK: - Architecture

/// The Linux architectures a static `threading-ptyd` is built for.
enum RemoteHostArchitecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case amd64

    /// `uname -m`'s spelling, or nil for a machine there is no binary for.
    init?(unameMachine: String) {
        switch unameMachine {
        case "aarch64", "arm64": self = .arm64
        case "x86_64", "amd64": self = .amd64
        default: return nil
        }
    }
}

// MARK: - Facts

/// What a host is, asked of the host itself before anything is installed or launched there.
///
/// The spike's decision 3: nothing Mac-side — paths, `/bin/zsh`, account directories — is sent to a
/// host. A launch is composed from these facts, so a Debian box gets its own login shell and its own
/// home rather than a Mac's.
struct RemoteHostFacts: Equatable, Sendable {
    /// `uname -m`, verbatim, so a refusal can name the machine it refused.
    let machine: String
    let home: String
    let user: String
    /// From the password database, not `$SHELL`, which a non-interactive `ssh` command may not set.
    let loginShell: String
    let hasSystemd: Bool
    /// `loginctl`'s answer, or nil when it could not be asked.
    let lingerEnabled: Bool?
    /// Install directories under `~/.local/lib/threading` holding an executable daemon.
    let installedBinaries: Set<String>
    /// Active `threading-ptyd@<id>.service` instances, by instance name.
    let activeInstances: [String]
    /// Instances enabled to start at boot, by instance name. Separate from `activeInstances`:
    /// an instance can be enabled and stopped, and it will still start at the next boot — on
    /// whatever paths the shared unit template names by then.
    var enabledInstances: [String] = []
    /// Where a login shell resolves `claude`, or nil when it does not.
    let claudePath: String?

    var architecture: RemoteHostArchitecture? { RemoteHostArchitecture(unameMachine: machine) }

    var remoteSocketPath: String {
        "\(home)/\(RemoteHostDefaults.remoteStateDirectory)/\(RemoteHostDefaults.remoteSocketFileName)"
    }

    /// Login shells whose `-l -c` accepts the POSIX command line `RemoteAgentLaunch` writes. A
    /// `fish` or `nu` login shell is refused rather than handed syntax it does not speak.
    var hasPOSIXLoginShell: Bool {
        let name = (loginShell as NSString).lastPathComponent
        return RemoteHostFactsDefaults.posixShellNames.contains(name)
    }
}

enum RemoteHostFactsDefaults {
    static let posixShellNames: Set<String> = ["bash", "zsh", "sh", "dash", "ksh", "mksh"]

    enum Key {
        static let machine = "machine"
        static let home = "home"
        static let user = "user"
        static let shell = "shell"
        static let systemctl = "systemctl"
        static let linger = "linger"
        static let installed = "installed"
        static let active = "active"
        static let enabled = "enabled"
        static let claude = "claude"
    }

    static let instanceNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    static let lingerYes = "yes"
    static let lingerNo = "no"
}

enum RemoteHostFactsError: LocalizedError, Equatable {
    case unreadable(missing: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let missing):
            return "The host did not report its \(missing)."
        }
    }
}

extension RemoteHostFacts {

    /// The probe, fed to `sh -s` on the host. One `key=value` line per fact; a fact reported more
    /// than once (`installed`, `active`) is a list. Every command that can be missing is guarded,
    /// so a host without systemd still answers the rest.
    static let probeScript = """
        set -u
        user="$(id -un)"
        shell="$(getent passwd "$user" 2>/dev/null | cut -d: -f7)"
        [ -n "$shell" ] || shell=/bin/sh
        printf 'machine=%s\\n' "$(uname -m)"
        printf 'home=%s\\n' "$HOME"
        printf 'user=%s\\n' "$user"
        printf 'shell=%s\\n' "$shell"
        printf 'systemctl=%s\\n' "$(command -v systemctl 2>/dev/null || true)"
        printf 'linger=%s\\n' "$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)"
        for binary in "$HOME"/\(RemoteHostDefaults.remoteLibraryDirectory)/*/\(RemoteHostDefaults.daemonExecutableName); do
          [ -x "$binary" ] && printf 'installed=%s\\n' "$(basename "$(dirname "$binary")")"
        done
        for unit in "$HOME"/\(RemoteHostDefaults.remoteUnitDirectory)/default.target.wants/\(RemoteHostDefaults.remoteUnitPrefix)*\(RemoteHostDefaults.remoteUnitSuffix); do
          [ -e "$unit" ] && printf 'enabled=%s\\n' "$(basename "$unit")"
        done
        if command -v systemctl >/dev/null 2>&1; then
          systemctl --user list-units '\(RemoteHostDefaults.remoteUnitPrefix)*' --state=active --plain --no-legend 2>/dev/null \\
            | awk '{print "active=" $1}'
        fi
        printf 'claude=%s\\n' "$("$shell" -lc 'command -v claude' </dev/null 2>/dev/null | tail -n 1)"
        """

    /// Reads the probe's output. Lines that are not `key=value`, such as a login shell's greeting,
    /// are ignored; a missing required fact is an error naming it.
    static func parse(_ output: String) throws -> RemoteHostFacts {
        typealias Key = RemoteHostFactsDefaults.Key
        var single: [String: String] = [:]
        var installed = Set<String>()
        var active: [String] = []
        var enabled: [String] = []

        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            switch key {
            case Key.installed:
                if !value.isEmpty { installed.insert(value) }
            case Key.active:
                if let instance = instanceName(fromUnit: value) { active.append(instance) }
            case Key.enabled:
                if let instance = instanceName(fromUnit: value) { enabled.append(instance) }
            case Key.machine, Key.home, Key.user, Key.shell, Key.systemctl, Key.linger, Key.claude:
                single[key] = value
            default:
                continue
            }
        }

        func required(_ key: String) throws -> String {
            guard let value = single[key], !value.isEmpty else {
                throw RemoteHostFactsError.unreadable(missing: key)
            }
            return value
        }

        let linger: Bool?
        switch single[Key.linger] {
        case RemoteHostFactsDefaults.lingerYes: linger = true
        case RemoteHostFactsDefaults.lingerNo: linger = false
        default: linger = nil
        }
        let claude = single[Key.claude].flatMap { $0.hasPrefix("/") ? $0 : nil }

        return RemoteHostFacts(
            machine: try required(Key.machine),
            home: try required(Key.home),
            user: try required(Key.user),
            loginShell: try required(Key.shell),
            hasSystemd: !(single[Key.systemctl] ?? "").isEmpty,
            lingerEnabled: linger,
            installedBinaries: installed,
            activeInstances: active,
            enabledInstances: enabled,
            claudePath: claude
        )
    }

    /// `threading-ptyd@<id>.service` → `<id>`.
    static func instanceName(fromUnit unit: String) -> String? {
        guard unit.hasPrefix(RemoteHostDefaults.remoteUnitPrefix),
              unit.hasSuffix(RemoteHostDefaults.remoteUnitSuffix) else { return nil }
        let instance = unit
            .dropFirst(RemoteHostDefaults.remoteUnitPrefix.count)
            .dropLast(RemoteHostDefaults.remoteUnitSuffix.count)
        // A name read off the host goes back into a command run there, so it is held to the
        // characters an instance name is made of rather than quoted.
        guard !instance.isEmpty,
              instance.unicodeScalars.allSatisfy({ RemoteHostFactsDefaults.instanceNameCharacters.contains($0) })
        else { return nil }
        return String(instance)
    }
}
