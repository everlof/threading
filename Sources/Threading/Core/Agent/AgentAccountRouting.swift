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
        var prefix = ShellCommand(word: "env")
        // A runtime whose login is not a directory has nothing to point at, and callers reach
        // here only after asking for `.accounts`. The bare `env` still carries whatever the
        // caller appends after it.
        guard let accountKey = kind.accountEnvironmentKey else { return prefix }
        if account.isDefault {
            prefix.append(flag: "-u", value: accountKey)
        } else {
            prefix.append(word: "\(accountKey)=\(account.configPath)")
        }
        return prefix
    }
}
