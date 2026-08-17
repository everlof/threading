import Foundation

/// Asks the macOS Application Firewall what it would do with an incoming connection.
///
/// This is a hint and nothing here may be turned into a claim that a door is reachable. Binding a
/// routable port makes Threading an app that accepts incoming connections, and with a stricter
/// firewall setting the user gets a prompt or a silent block. The Mac cannot find that out by
/// probing itself: a connection from this Mac to its own LAN address is local traffic the
/// Application Firewall does not filter, so a successful self-probe proves nothing. The real
/// signal is a phone reporting whether it connected. `socketfilterfw` is the best available
/// second-hand evidence and is treated as such.
enum RemoteFirewallProbe {

    /// The tool Apple ships for this. It is not on `PATH`, and it is deliberately named as an
    /// absolute path rather than looked up: a `socketfilterfw` found somewhere else is not the
    /// firewall's answer.
    static let executablePath = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    private static let globalStateArgument = "--getglobalstate"
    private static let applicationBlockedArgument = "--getappblocked"

    /// The sentences the tool prints. It has no machine-readable mode, so the match stays as
    /// narrow as it can be: an unrecognised answer becomes `unknown` rather than a guess.
    private static let enabledMarker = "(State = 1)"
    private static let disabledMarker = "(State = 0)"
    private static let blockedMarker = "is blocked"
    private static let permittedMarker = "is permitted"

    /// Reads both answers. Blocking, so callers run it off the main actor.
    ///
    /// - Parameter executableURL: the binary the firewall has a rule for, which is the app's own
    ///   executable rather than its bundle directory.
    static func read(
        executableURL: URL?,
        runner: (String, [String]) -> String? = runSynchronously
    ) -> RemoteFirewallHint {
        let global = globalState(from: runner(executablePath, [globalStateArgument]))
        guard global == .on, let executableURL else {
            // With the firewall off there is no per-app verdict worth reading, and one fewer
            // child process on a status path.
            return RemoteFirewallHint(
                globalState: global,
                applicationState: global == .on ? .unknown : .allowed
            )
        }
        let application = applicationState(
            from: runner(executablePath, [applicationBlockedArgument, executableURL.path])
        )
        return RemoteFirewallHint(globalState: global, applicationState: application)
    }

    static func globalState(from output: String?) -> RemoteFirewallHint.GlobalState {
        guard let output else { return .unknown }
        if output.contains(enabledMarker) { return .on }
        if output.contains(disabledMarker) { return .off }
        return .unknown
    }

    static func applicationState(from output: String?) -> RemoteFirewallHint.ApplicationState {
        guard let output else { return .unknown }
        if output.contains(blockedMarker) { return .blocked }
        if output.contains(permittedMarker) { return .allowed }
        return .unknown
    }

    private static func runSynchronously(_ executable: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        guard let result = try? BoundedChildProcess.run(
            executable: executable,
            arguments: arguments,
            timeout: RemoteAccessDefaults.firewallProbeTimeout,
            maximumOutputBytes: RemoteAccessDefaults.firewallProbeOutputBytes,
            output: .standardOutput
        ), case .exited(let status) = result.termination, status == 0 else { return nil }
        return String(data: result.output, encoding: .utf8)
    }
}
