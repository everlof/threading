import Foundation

/// Portable Codex command composition. Hosts resolve accounts, model metadata, hook installation
/// and policy before supplying these values; this type does not inspect settings or credentials.
enum CodexLaunchCommand {
    static func invocation(executable: String = AgentDefaults.codexExecutable) -> ShellCommand {
        var command = ShellCommand(word: executable)
        command.append(flag: AgentDefaults.codexConfigFlag,
                       value: "\(AgentDefaults.codexCheckForUpdateOnStartupKey)=false")
        return command
    }

    static func terminal(
        executable: String = AgentDefaults.codexExecutable,
        model: String?,
        conversationOverrides: ShellCommand = ShellCommand(),
        permissionMode: AgentPermissionMode?,
        hookFlags: ShellCommand = ShellCommand(),
        resumeState: ResumeState,
        prompt: String?
    ) -> (ShellCommand, ResumeState) {
        var command = invocation(executable: executable)
        // Inline mode gives terminal scrollback one owner instead of using Codex's alternate screen.
        command.append(flag: AgentDefaults.codexNoAlternateScreenFlag)
        if let model, !model.isEmpty {
            command.append(flag: AgentDefaults.codexModelFlag, value: model)
        }
        command.append(contentsOf: conversationOverrides)
        if let permissionMode {
            for flag in permissionMode.launchFlags(for: .codex) {
                command.append(flag: flag.name, value: flag.value)
            }
        }
        command.append(contentsOf: hookFlags)
        // Resume preflight remains the host's responsibility. Never fall back to a fresh chat.
        if let existingID = resumeState.transcriptID {
            command.append(word: "resume")
            command.append(word: existingID.rawValue)
            return (command, .resumable(existingID))
        }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command.append(operand: prompt)
        }
        return (command, .awaitingIdentifier)
    }
}
