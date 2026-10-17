import Foundation

/// Portable Codex command composition. Hosts resolve accounts, model metadata, hook installation
/// and policy before supplying these values; this type does not inspect settings or credentials.
enum CodexLaunchCommand {
    static func appServer(
        executable: String = AgentDefaults.codexExecutable,
        model: String?, conversationOverrides: ShellCommand = ShellCommand(),
        permissionMode: AgentPermissionMode?, hookFlags: ShellCommand = ShellCommand()
    ) -> ShellCommand {
        var command = invocation(executable: executable)
        if let model, !model.isEmpty {
            command.append(flag: AgentDefaults.codexModelFlag, value: model)
        }
        command.append(contentsOf: conversationOverrides)
        if let permissionMode {
            for flag in permissionMode.launchFlags(for: .codex) {
                command.append(flag: flag.name, value: flag.value)
            }
        } else {
            command.append(flag: AgentDefaults.codexSandboxFlag,
                           value: AgentDefaults.codexSandboxWorkspaceWrite)
        }
        command.append(contentsOf: hookFlags)
        command.append(word: "app-server")
        command.append(flag: "--listen", value: "stdio://")
        return command
    }

    static func invocation(executable: String = AgentDefaults.codexExecutable) -> ShellCommand {
        var command = ShellCommand(word: executable)
        command.append(flag: AgentDefaults.codexConfigFlag,
                       value: "\(AgentDefaults.codexCheckForUpdateOnStartupKey)=false")
        return command
    }

    static func terminal(
        executable: String = AgentDefaults.codexExecutable,
        model: String?,
        reasoningEffort: String? = nil,
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
        if let reasoningEffort, !reasoningEffort.isEmpty {
            command.append(flag: AgentDefaults.codexConfigFlag,
                value: "\(AgentDefaults.codexReasoningEffortKey)=\(tomlString(reasoningEffort))")
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

    private static func tomlString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0...0x1f, 0x7f: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
