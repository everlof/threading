import Darwin
import Foundation

// MARK: - Arguments

/// The bridge's entire configuration, and all of it comes from the app.
///
/// **The bridge has no path policy of its own.** The socket, the token and the cache file are one
/// decision, made in `MCPSessionRegistry` beside the session's other per-session files; a helper
/// that derived any of them itself would be a second place for that decision to live and a second
/// place for it to be wrong. So a malformed command line is refused rather than defaulted: the
/// app builds it, so getting it wrong is a bug in the app, and a bridge pointed at nothing would
/// look to the user exactly like an app that was closed.
struct BridgeArguments: Sendable {
    let socketPath: String
    let token: String
    let cachePath: String

    /// `POST` and `GET` both address the session's endpoint. Built once, since the token is
    /// fixed for the process's life.
    var endpointPath: String { BridgeDefaults.pathPrefix + token }

    static let usage =
        "usage: threading-mcp-bridge --socket <path> --token <token> --cache <path>"

    private enum Flag {
        static let socket = "--socket"
        static let token = "--token"
        static let cache = "--cache"
    }

    /// Parses the arguments after `argv[0]`. Flags may appear in any order; each is required,
    /// may appear once, and must carry a non-empty value. Anything else answers `nil`.
    static func parse(_ arguments: [String]) -> BridgeArguments? {
        var socketPath: String?
        var token: String?
        var cachePath: String?

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
            case Flag.token:
                guard token == nil else { return nil }
                token = value
            case Flag.cache:
                guard cachePath == nil else { return nil }
                cachePath = value
            default:
                return nil
            }
            index = arguments.index(after: valueIndex)
        }

        guard let socketPath, let token, let cachePath else { return nil }
        return BridgeArguments(socketPath: socketPath, token: token, cachePath: cachePath)
    }
}

// MARK: - Entry point

/// The process. Kept in a type with a `main()` rather than written as top-level statements so the
/// bridge's state is local variables instead of module globals.
enum ThreadingMCPBridge {
    static func main() -> Never {
        // The bridge writes to two pipes it does not own, either of which the client may close
        // first. Without this, that write kills the process with `SIGPIPE`, which reads to the
        // CLI as the server having crashed. Sockets are covered separately by `SO_NOSIGPIPE`.
        signal(SIGPIPE, SIG_IGN)

        guard let arguments = BridgeArguments.parse(Array(CommandLine.arguments.dropFirst())) else {
            FileHandle.standardError.write(Data((BridgeArguments.usage + "\n").utf8))
            exit(BridgeExitCode.usage)
        }

        MCPBridge(arguments: arguments).run()
    }
}

ThreadingMCPBridge.main()
