import Foundation

/// The environment prefix that sends one CLI invocation to one discovered account.
///
/// The default account is an explicit `env -u`, not an omitted assignment: Threading itself may
/// have been opened from a shell exporting an alternate home, and inheriting it would make a
/// command act on a different login from the session whose row was clicked. Agent launches and
/// provider archive commands share this construction so that lifecycle operations cannot drift
/// from resume routing.
enum AgentAccountRouting {
    static func prefix(for kind: AgentKind, account: AgentAccount) -> ShellCommand {
        AgentAccountRoute.prefix(for: kind, handle: account.handle, configPath: account.configPath)
    }
}
