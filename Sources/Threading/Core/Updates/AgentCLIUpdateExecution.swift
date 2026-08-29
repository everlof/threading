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
        shellCommand.source
    }

    /// Kept as words until the terminal process is launched. The complete source can exceed a
    /// tty's input queue even when every physical line is short, so it must travel in argv rather
    /// than being typed after the shell starts.
    var shellCommand: ShellCommand {
        AgentCLIUpdateShellCommand.command(for: updates)
    }
}

struct AgentCLIUpdateExecutionReceipt: Equatable, Sendable {
    let terminalID: TerminalID
    let toolIDs: [String]
}

/// One shell command for the interactive terminal, with every provider command already inside a
/// quoted child-shell argument. This matters when an updater asks a question: launching several
/// independent commands would leave the later ones in the PTY as accidental prompt input.
///
/// The complete command is passed as one process argument before the PTY starts. It must not be
/// typed into the shell: macOS bounds the whole terminal input queue at 1024 bytes, and this plan
/// exceeds that with several tools even though no individual physical line does. The nested
/// provider shells inherit the visible PTY for prompts, while the outer script alone owns the
/// sequencing and receipts.
enum AgentCLIUpdateShellCommand {
    static func command(for updates: [AgentCLIUpdate]) -> ShellCommand {
        var wrapper = ShellCommand(word: "/bin/sh")
        wrapper.append(word: "-l")
        wrapper.append(word: "-c")
        wrapper.append(word: script(for: updates))
        return wrapper
    }

    /// Exposed beside `command` so tests can assert the sequencing contract without trying to
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
