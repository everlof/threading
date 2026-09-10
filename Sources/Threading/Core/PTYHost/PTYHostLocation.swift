import Dispatch
import Foundation
import ThreadingPTYHostKit

// MARK: - PTY Host Defaults

/// Names, permissions, bounds and deadlines for the app's side of the `threading-ptyd` link.
///
/// One namespace, so neither the location, the availability decision nor the client can pick a
/// different number and discover it three frames later. The wire's own constants are
/// `PTYHostFramingDefaults` in `ThreadingPTYHostKit`; nothing here restates them.
///
/// **The directory's permissions are the boundary, not the endpoint's.** The daemon holds every
/// user's PTY master descriptors and takes spawn requests carrying a whole environment, so what
/// stops another user's process reaching it is that `pty/` is `0700` and a unix socket inside it
/// is reachable only by processes running as this user. That is exactly `MCPBridgeDefaults`'
/// argument for `bridge/`, and this directory is deliberately its sibling rather than its
/// room-mate: the two are owned by different processes with different lifetimes, and a daemon
/// that could write over `session-tokens.json` would be a daemon holding an authorization.
enum PTYHostDefaults {

    /// The directory holding the rendezvous socket, the daemon's own journal and its
    /// `sessions.jsonl` state. A sibling of `bridge/`, created `0700`.
    ///
    /// Taken from the package both processes link rather than spelled again here: the launchd
    /// plist cannot name a home-relative path, so the daemon derives this same directory from
    /// `PTYHostDefaultLocations` when it is started with `--default-locations`, and two copies of
    /// the name would be two places for "where is the socket" to disagree.
    static let directoryName = PTYHostDefaultLocations.directoryName

    /// Owner-only. See the type's note: this is the boundary itself.
    static let directoryPermissions = 0o700

    /// Owner-only as well. Defence in depth rather than the boundary — the enclosing directory
    /// already excludes everyone else.
    static let filePermissions = 0o600

    /// The rendezvous. One per user, byte-identical across launches, which is what lets the app
    /// find a daemon it did not start — and shared with the daemon through
    /// `PTYHostDefaultLocations` for the reason `directoryName` gives.
    static let socketFileName = PTYHostDefaultLocations.socketFileName

    /// The app's receipt for the exact bundle generation last handed to `SMAppService`.
    ///
    /// `SMAppService.status == enabled` says only that launchd has a job with this label. It does
    /// not say which copy of Threading registered it, and an enabled job can therefore still
    /// resolve through a deleted DerivedData bundle after `/Applications/Threading.app` is
    /// installed. The receipt is app-owned (the daemon never reads it) and lets the next launch
    /// distinguish that stale association from an ordinary idempotent registration.
    static let registrationReceiptFileName = "registration.json"

    /// The `product-type.tool` daemon, shipped in the app bundle beside the other helpers.
    ///
    /// It does not exist yet — `Targets/PTYHost` is a later slice. Naming it here is what lets
    /// `PTYHostAvailability` answer `.helperMissing` today instead of failing to connect and
    /// blaming the daemon for not running.
    static let helperName = "threading-ptyd"

    /// Where the app bundle keeps its `product-type.tool` helpers, this one included.
    static let helpersDirectoryPath = "Contents/Helpers"

    /// The daemon's command line. Both are required and it exits `64` without them: the daemon
    /// has no path policy of its own, because where the rendezvous and the state live is one
    /// decision made here beside the other owner-only directories. A daemon that derived either
    /// would be a second place for that decision to be wrong — and a daemon listening somewhere
    /// nobody is looking is indistinguishable from one that never started.
    static let socketArgument = "--socket"
    static let stateArgument = "--state"

    /// `sockaddr_un.sun_path` is a 104-byte array on Darwin and the path inside it is
    /// NUL-terminated, so 103 bytes is the most a bound path may carry.
    ///
    /// Reused from `MCPBridgeDefaults` rather than restated: it is a property of the platform,
    /// not of either feature, and two copies would be two places to get the off-by-one wrong.
    /// `pty/ptyd.sock` is shorter than `bridge/mcp.sock`, so a home directory that fits the MCP
    /// socket today fits this one — and a home directory long enough to fail must cost the
    /// daemon and nothing else, which is what `.socketPathTooLong` refusing only a selected
    /// background launch means.
    static let maximumSocketPathBytes = MCPBridgeDefaults.maximumSocketPathBytes

    /// How long a `connect()` to the rendezvous may take before the daemon counts as absent.
    ///
    /// Bounded because this runs on a session launch: a socket file left behind by a daemon that
    /// is gone, or one whose backlog is full, must refuse promptly rather than hold a launch
    /// open. A unix connect to a listening peer is immediate; anything else is already the
    /// unavailable case.
    static let connectTimeout: TimeInterval = 2

    /// How long the daemon has to answer `hello` before the link is abandoned.
    ///
    /// Longer than the connect deadline on purpose: a daemon that has just been started by
    /// `KeepAlive` may still be reading its `sessions.jsonl` and probing pids, which is bounded
    /// work but not instant work.
    static let helloTimeout: TimeInterval = 5

    /// The most unwritten bytes the client will hold for a daemon that has stopped reading.
    ///
    /// A queue that grows is the failure this bound exists to refuse. Input is small, but a
    /// `detach` carries a screen seed and a wedged daemon takes none of it, so "buffer whatever
    /// the caller hands over" is an unbounded allocation driven by an unresponsive peer. Four
    /// frames' worth of the 1 MiB wire maximum: large enough that no ordinary burst trips it,
    /// small enough that tripping it is a bug rather than a slow afternoon. Exceeding it closes
    /// the connection with `PTYHostClientError.writeQueueOverflow`; a selected background
    /// session reports that failure without changing process ownership.
    static let maximumQueuedWriteBytes = 4 * PTYHostFramingDefaults.maximumPayloadBytes

    /// One blocking read during the handshake, before the `DispatchIO` pump owns the descriptor.
    static let handshakeReadChunkBytes = 64 * 1024

    /// The client's serial queue. Every frame is decoded and delivered on it and never on main.
    static let clientQueueLabel = "codes.threading.ptyhost.client"

    /// A connected terminal is part of the visible interaction loop even though its bytes do
    /// not belong on main. In particular, a typed key is not visible until the child echoes it
    /// through this queue, so leaving the queue's QoS unspecified turns an explicit UI edge into
    /// work whose urgency depends on whichever thread happened to wake `DispatchIO`.
    static let clientQueueQoS = DispatchQoS.userInteractive
}

// MARK: - PTY Host Location

/// Where the daemon's rendezvous and state live, and whether the socket can live there at all.
///
/// Resolved through the same hosted-test redirect the rest of the app's state uses, and for a
/// sharper reason than tidiness: a hosted test bundle runs *inside* the shipping app, so without
/// the redirect a test that started a daemon would bind the socket the developer's running app is
/// listening on, and the two would then be fighting over the same PTY children.
///
/// **The app only resolves paths.** Unlinking a stale socket and binding a new one are the
/// daemon's, because the daemon is the only process that may ever be listening there — the app
/// removing that file is the app deciding a working daemon is dead. The one filesystem write here
/// is `prepareDirectory`, which is idempotent and produces the same `0700` directory whichever
/// process reaches it first.
enum PTYHostLocation {

    // MARK: - Public Methods

    /// `~/Library/Application Support/Threading`, or this test process's scratch root.
    static var supportRoot: URL {
        StateManager.isHostedTest
            ? StateManager.hostedTestDirectory()
            : AppDataLocations.supportDirectory
    }

    /// The `0700` directory holding the socket, the daemon's journal and its session state.
    static var directory: URL {
        supportRoot.appendingPathComponent(
            PTYHostDefaults.directoryName,
            isDirectory: true
        )
    }

    /// The rendezvous path, knowable before any daemon exists — which is what lets the
    /// availability decision answer `.notRunning` rather than having to ask launchd.
    static var socketPath: String {
        directory.appendingPathComponent(PTYHostDefaults.socketFileName).path
    }

    /// Where the daemon keeps `sessions.jsonl` and its own dated journal.
    ///
    /// Deliberately the same directory rather than a nested one. It is named separately because
    /// the two facts are separate — the app addresses the *socket* and never reads the state —
    /// and because the daemon's journal must never move into `Logs/`, where `EventLog` prunes
    /// any `.jsonl` past the retention window and where a second writer has already interleaved
    /// one file into 23 unparseable lines.
    static var stateDirectory: URL { directory }

    /// The app-owned identity of the bundle generation most recently registered with launchd.
    /// Kept beside the rendezvous because both have the same per-user lifetime and owner-only
    /// boundary; the daemon does not read or write it.
    static var registrationReceiptURL: URL {
        directory.appendingPathComponent(PTYHostDefaults.registrationReceiptFileName)
    }

    /// Creates the directory if it is missing and tightens it to `0700` either way.
    ///
    /// The permissions are re-applied rather than only set at creation, because the directory may
    /// already exist from a build that created it with the default mask — the same correction
    /// `MCPBridgeLocation.prepareDirectory` makes, for the same reason.
    @discardableResult
    static func prepareDirectory(_ directory: URL = PTYHostLocation.directory) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: PTYHostDefaults.directoryPermissions]
            )
            try fileManager.setAttributes(
                [.posixPermissions: PTYHostDefaults.directoryPermissions],
                ofItemAtPath: directory.path
            )
            return true
        } catch {
            ThreadingLogger.ptyHost.error(
                """
                Could not prepare the PTY host directory: \
                \(error.localizedDescription, privacy: .private(mask: .hash))
                """
            )
            return false
        }
    }

    /// The path if a unix socket can be addressed at it, or nil having said why.
    ///
    /// The caller reports `.socketPathTooLong`; policy keeps an unselected session local and
    /// refuses a selected background launch.
    static func addressableSocketPath(_ path: String = PTYHostLocation.socketPath) -> String? {
        guard path.utf8.count <= PTYHostDefaults.maximumSocketPathBytes else {
            ThreadingLogger.ptyHost.error(
                """
                PTY host socket path is \(path.utf8.count, privacy: .public) bytes, over the \
                \(PTYHostDefaults.maximumSocketPathBytes, privacy: .public)-byte limit
                """
            )
            return nil
        }
        return path
    }

    /// Where the daemon would be, whether or not it is there.
    ///
    /// Deliberately a *candidate*, exactly as `MCPBridgeLocation.helperURL(in:)` is: existence is
    /// checked by the availability decision, so one place answers "can this launch use the host"
    /// rather than two that can disagree. `bundle` is injectable so a test can point at a
    /// directory holding no helper and prove the app preserves that unavailability reason.
    static func helperURL(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent(PTYHostDefaults.helpersDirectoryPath, isDirectory: true)
            .appendingPathComponent(PTYHostDefaults.helperName, isDirectory: false)
    }
}
