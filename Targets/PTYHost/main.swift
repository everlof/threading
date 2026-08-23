import Darwin
import Dispatch
import Foundation

// MARK: - Arguments

/// The daemon's entire configuration, and both halves of it come from the caller.
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
struct PTYHostArguments {
    let socketPath: String
    let stateDirectory: String

    static let usage = "usage: threading-ptyd --socket <path> --state <dir>"

    private enum Flag {
        static let socket = "--socket"
        static let state = "--state"
    }

    /// Parses the arguments after `argv[0]`. Both flags are required, may appear once, and must
    /// carry a non-empty value; anything else answers nil.
    static func parse(_ arguments: [String]) -> PTYHostArguments? {
        var socketPath: String?
        var stateDirectory: String?

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
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
        // would kill a process holding every hosted agent on the machine. `SO_NOSIGPIPE` covers
        // each socket as well; both are here because either one alone is a line's edit away from
        // being removed by somebody who saw only the other.
        signal(SIGPIPE, SIG_IGN)

        guard let arguments = PTYHostArguments.parse(Array(CommandLine.arguments.dropFirst())) else {
            FileHandle.standardError.write(Data((PTYHostArguments.usage + "\n").utf8))
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
    /// Read from the embedded `Info.plist` section rather than compiled in, so the string tracks
    /// the bundle the daemon shipped inside. A tool's plist is a `__TEXT` section rather than a
    /// file, so this is best-effort by construction — and it may be, because nothing gates on it.
    private static var buildString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return version ?? "unknown"
    }
}

ThreadingPTYHost.main()
