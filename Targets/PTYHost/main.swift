#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Dispatch
import Foundation
import ThreadingPTYHostKit

// MARK: - Arguments

/// The daemon's entire configuration, and both halves of it normally come from the caller.
///
/// **The daemon has no path policy of its own.** Where the rendezvous lives and where the state
/// directory is are one decision, made in the app beside the other owner-only directories under
/// `Application Support/Threading`; a daemon that derived either would be a second place for that
/// decision to live and a second place for it to be wrong. It is also what lets a test start a
/// daemon of its own without going anywhere near the socket the developer's running app is
/// listening on.
///
/// So a malformed command line is refused rather than defaulted: the app builds it, so getting it
/// wrong is a bug in the app, and a daemon listening somewhere nobody is looking would be
/// indistinguishable from one that never started.
///
/// **`--default-locations` is the one exception, and it exists for launchd.** The plist that
/// registers this daemon is a file inside the signed app bundle — one copy for every account on
/// the machine, unwritable at runtime without breaking the seal — and launchd passes
/// `ProgramArguments` to `execvp` verbatim, so it cannot carry a home-relative path and will not
/// expand `~`. The flag asks the daemon to derive the same two paths the app would have named,
/// from the names both ends share in `PTYHostDefaultLocations`. It takes no value, is refused
/// alongside `--socket`/`--state`, and is used by the plist and by nothing else: every test still
/// names its own scratch rendezvous explicitly.
struct PTYHostArguments {
    let socketPath: String
    let stateDirectory: String

    private enum Flag {
        static let socket = "--socket"
        static let state = "--state"
    }

    /// Parses the arguments after `argv[0]`.
    ///
    /// Either both value flags are present, once each and with a non-empty value, or
    /// `--default-locations` is present alone. Anything else — a half-named pair, both forms at
    /// once, an unknown flag — answers nil, because a daemon that guessed would listen somewhere
    /// nobody is looking.
    static func parse(_ arguments: [String]) -> PTYHostArguments? {
        var socketPath: String?
        var stateDirectory: String?
        var usesDefaultLocations = false

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]

            if flag == PTYHostDefaultLocations.defaultLocationsArgument {
                guard !usesDefaultLocations else { return nil }
                usesDefaultLocations = true
                index = arguments.index(after: index)
                continue
            }

            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { return nil }
            let value = arguments[valueIndex]
            guard !value.isEmpty else { return nil }

            switch flag {
            case Flag.socket:
                guard socketPath == nil else { return nil }
                socketPath = value
            case Flag.state:
                guard stateDirectory == nil else { return nil }
                stateDirectory = value
            default:
                return nil
            }
            index = arguments.index(after: valueIndex)
        }

        if usesDefaultLocations {
            // Not a fallback for a half-named command line: mixing the two would let a typo in
            // `--socket` quietly become "the default one", which is the failure the required
            // flags exist to prevent.
            guard socketPath == nil, stateDirectory == nil else { return nil }
            guard let directory = PTYHostDefaultLocations.directory() else { return nil }
            return PTYHostArguments(
                socketPath: directory
                    .appendingPathComponent(PTYHostDefaultLocations.socketFileName, isDirectory: false)
                    .path,
                stateDirectory: directory.path
            )
        }

        guard let socketPath, let stateDirectory else { return nil }
        return PTYHostArguments(socketPath: socketPath, stateDirectory: stateDirectory)
    }
}

// MARK: - Entry point

/// The process. Kept in a type with a `main()` rather than written as top-level statements so the
/// daemon's state is a local rather than a module global.
enum ThreadingPTYHost {

    static func main() -> Never {
        // The daemon writes to sockets whose peer may already be gone, and a `SIGPIPE` there
        // would kill a process holding every hosted agent on the machine. On Darwin `SO_NOSIGPIPE`
        // covers each socket as well; both are here because either one alone is a line's edit away
        // from being removed by somebody who saw only the other. **Linux has no per-socket option,
        // so there this line is the only guard.**
        signal(SIGPIPE, SIG_IGN)

        let command = Array(CommandLine.arguments.dropFirst())

        // A bare verb is somebody asking the *running* daemon a question, and it is answered by
        // this same binary acting as a client — one place for the framing, the frames and the
        // version gate rather than two that drift. `PTYHostCLI.parse` declines anything that
        // starts with a flag, so every daemon command line below reaches the daemon's own parser
        // exactly as it did before this existed.
        if let parsed = PTYHostCLI.parse(command) {
            exit(PTYHostCLI.run(parsed, build: buildString))
        }

        guard let arguments = PTYHostArguments.parse(command) else {
            FileHandle.standardError.write(Data((PTYHostCLI.usage + "\n").utf8))
            exit(PTYHostDefaults.usageExitCode)
        }

        let server = PTYHostServer(
            socketPath: arguments.socketPath,
            stateDirectory: URL(fileURLWithPath: arguments.stateDirectory, isDirectory: true),
            build: buildString
        )
        guard server.start() else { exit(PTYHostDefaults.startupFailureExitCode) }

        // Everything after this is a queue event: an accepted connection, a decoded frame, a
        // burst of a child's output, a timer. A daemon that has not been asked to retire never
        // exits on its own, however idle it is.
        dispatchMain()
    }

    /// Reported in `hello` and journalled; never compared for admission.
    ///
    /// Read from the processed `Info.plist` embedded in this executable. The app and helper use
    /// `PTYHostGeneration` over the same three build values, so an offline bundle replacement is
    /// visible even though this already-running process keeps executing its old text pages.
    private static var buildString: String {
        let info = Bundle.main.infoDictionary
        return PTYHostGeneration.string(
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            bundleVersion: info?["CFBundleVersion"] as? String,
            sourceRevision: info?["ThreadingSourceRevision"] as? String
        )
    }
}

ThreadingPTYHost.main()
