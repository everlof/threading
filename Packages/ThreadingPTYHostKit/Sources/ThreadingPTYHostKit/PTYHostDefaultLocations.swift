import Foundation

/// Where the rendezvous and the daemon's state live when nobody names them, and the flag that
/// asks for exactly that.
///
/// **This exists because launchd does not expand `~`.** The daemon's command line is
/// `--socket <path> --state <dir>` and both are required, because where those live is one
/// decision the app makes beside its other owner-only directories; a daemon that derived them
/// would be a second place for that decision to be wrong. The plist, though, is a *file inside
/// the signed app bundle*: one copy, shared by every account on the machine, and unwritable at
/// runtime without breaking the bundle seal. It cannot carry `/Users/<someone>/Library/…`, and
/// launchd will not turn `~/Library/…` into one either — a `ProgramArguments` entry is passed to
/// `execvp` verbatim.
///
/// So there are two ways to name a home-relative path in a `LaunchAgents` plist: write the plist
/// per user, outside the bundle, at registration time — which forfeits `SMAppService`, whose
/// whole contract is a plist the *bundle* ships and the system reads — or let the program derive
/// the paths when it is asked to. This is the second, and the ask is explicit:
/// `--default-locations`, used by the plist and by nothing else. Every explicit-path behaviour is
/// unchanged, which is what keeps a test able to start a daemon on a scratch rendezvous rather
/// than on the one the developer's running app is listening on.
///
/// The names live here, in the package both ends link, rather than in either process: the app
/// composes its paths from them through `PTYHostLocation` and the daemon derives the same ones
/// from them, so "where is the socket" has one answer even though two processes ask it.
public enum PTYHostDefaultLocations {

    // MARK: - Names

    /// The application's directory under `Application Support`.
    ///
    /// The app spells this `ProjectIconDefaults.applicationDirectoryName`; this is deliberately a
    /// second declaration rather than a dependency, because a Foundation-only package that could
    /// see that enum could see the rest of the app with it — the same reason
    /// `PTYHostProcessStartTime` restates `ProcessStartTime` instead of importing it. The two are
    /// pinned to each other by a test (`PTYHostRegistrationTests`), which is where a divergence
    /// fails rather than at the first launch nobody could connect.
    public static let applicationDirectoryName = "Threading"

    /// The `0700` directory holding the rendezvous, the daemon's journal and `sessions.jsonl`.
    public static let directoryName = "pty"

    /// The rendezvous file inside it.
    public static let socketFileName = "ptyd.sock"

    // MARK: - The flag

    /// The one flag that asks the daemon to derive its own paths, for the one caller that cannot
    /// name them: the launchd plist.
    ///
    /// It is mutually exclusive with `--socket`/`--state` rather than a default, so a command
    /// line that half-names the locations is refused instead of silently listening somewhere
    /// nobody is looking — which is indistinguishable from a daemon that never started.
    public static let defaultLocationsArgument = "--default-locations"

    // MARK: - Derivation

    /// `~/Library/Application Support/Threading/pty`, for this user.
    ///
    /// `FileManager` rather than `$HOME`: a launchd agent's environment is whatever launchd chose
    /// to hand it, and the answer must be the account's real home whether or not the variable
    /// survived. (Measured 2026-08-23 on a registered agent: `HOME=/Users/david` was in fact
    /// present and `applicationSupport` derived correctly, `ppid=1`, `cwd=/` — but relying on the
    /// variable would be relying on a courtesy.)
    ///
    /// Returns nil rather than a fabricated path when the directory cannot be located at all, so
    /// a caller refuses rather than binding a socket somewhere arbitrary.
    public static func directory(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return support
            .appendingPathComponent(applicationDirectoryName, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The rendezvous path inside `directory(fileManager:)`.
    public static func socketPath(fileManager: FileManager = .default) -> String? {
        directory(fileManager: fileManager)?
            .appendingPathComponent(socketFileName, isDirectory: false)
            .path
    }
}
