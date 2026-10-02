import Foundation

/// The command prefix that binds one launch to the account named by its stored handle.
/// Both graphical hosts resolve the account path; this value only assembles shell words.
enum AgentAccountRoute {
    static func prefix(for kind: AgentKind, handle: AccountHandle, configPath: String) -> ShellCommand {
        var prefix = ShellCommand(word: "env")
        guard let key = kind.accountEnvironmentKey else { return prefix }
        if handle.isStandard {
            prefix.append(flag: "-u", value: key)
        } else {
            prefix.append(word: "\(key)=\(configPath)")
        }
        return prefix
    }
}
