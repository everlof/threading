import Foundation

/// One explicit, visible run of the provider-authored commands behind an update notice.
///
/// The release check never constructs this plan. It is created only after the toast action is
/// pressed, then handed to a standalone terminal whose output and prompts remain visible. The
/// provider commands are still treated as shell source because that is their published contract,
/// but each is a quoted argument to its own login-shell child; none can splice into Threading's
/// status receipts or the following provider's command.
struct AgentCLIUpdateExecutionPlan: Equatable, Sendable {
    let updates: [AgentCLIUpdate]

    init(updates: [AgentCLIUpdate]) {
        precondition(!updates.isEmpty, "An update run requires at least one tool")
        precondition(
            updates.count <= AgentCLIUpdateCatalog.all.count,
            "An update run cannot exceed the fixed provider catalog"
        )
        self.updates = updates
    }

    var shellSource: String {
        AgentCLIUpdateShellCommand.source(for: updates)
    }
}

struct AgentCLIUpdateExecutionReceipt: Equatable, Sendable {
    let terminalID: TerminalID
    let toolIDs: [String]
}

/// A single line for the interactive terminal, with all future commands already inside one
/// quoted child-shell argument. This matters when an updater asks a question: sending several
/// terminal lines up front could leave the later commands in the PTY as accidental prompt input.
enum AgentCLIUpdateShellCommand {
    static func source(for updates: [AgentCLIUpdate]) -> String {
        var wrapper = ShellCommand(word: "/bin/sh")
        wrapper.append(word: "-l")
        wrapper.append(word: "-c")
        wrapper.append(word: script(for: updates))
        return wrapper.source
    }

    /// Exposed beside `source` so tests can assert the sequencing contract without trying to
    /// decode the outer command's shell quoting.
    static func script(for updates: [AgentCLIUpdate]) -> String {
        precondition(!updates.isEmpty, "An update command requires at least one tool")

        var steps: [String] = []
        for update in updates {
            var heading = ShellCommand(word: "printf")
            heading.append(word: "\n[Threading] Updating %s from %s to %s.\n")
            heading.append(word: update.displayName)
            heading.append(word: update.installedVersion)
            heading.append(word: update.latestVersion)
            steps.append(heading.source)

            var launch = ShellCommand(word: "/bin/sh")
            launch.append(word: "-l")
            launch.append(word: "-c")
            launch.append(word: update.updateCommand)
            steps.append(launch.source)
            steps.append("__threading_agent_update_status=$?")

            var receipt = ShellCommand(word: "printf")
            receipt.append(word: "[Threading] %s updater finished with exit code %d.\n")
            receipt.append(word: update.displayName)
            steps.append(receipt.source + " \"$__threading_agent_update_status\"")
        }

        var completion = ShellCommand(word: "printf")
        completion.append(word: "\n[Threading] Agent tool update run finished.\n")
        steps.append(completion.source)
        return steps.joined(separator: "; ")
    }
}
