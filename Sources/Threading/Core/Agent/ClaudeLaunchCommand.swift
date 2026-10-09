import Foundation

/// Claude's portable interactive command pair. The host supplies an executable, resolved
/// permission mode and any host-owned integration flags; this value never discovers accounts,
/// writes settings or decides whether a transcript exists on its machine.
enum ClaudeLaunchCommand {
    /// The persistent bidirectional protocol, shared by native platform hosts. Hook settings,
    /// account routing and fresh/resume admission remain the host's responsibility.
    static func streamProtocolFlags() -> ShellCommand {
        var command = ShellCommand()
        command.append(flag: "--print")
        command.append(flag: "--input-format", value: "stream-json")
        command.append(flag: "--output-format", value: "stream-json")
        command.append(flag: "--include-partial-messages")
        command.append(flag: "--verbose")
        command.append(flag: "--forward-subagent-text")
        command.append(flag: "--include-hook-events")
        return command
    }

    static func terminalPair(
        for session: AgentSession,
        executable: String,
        permissionMode: AgentPermissionMode?,
        prompt: String?,
        integrationFlags: ShellCommand = ShellCommand()
    ) -> (resume: ShellCommand, fresh: ShellCommand, transcriptID: TranscriptID) {
        var base = ShellCommand(word: executable)
        if let model = session.model, !model.isEmpty {
            base.append(flag: AgentDefaults.claudeModelFlag, value: model)
        }
        if let effort = session.reasoningEffort,
           AgentDefaults.claudeReasoningEfforts.contains(effort) {
            base.append(flag: AgentDefaults.claudeEffortFlag, value: effort)
        }
        if let permissionMode {
            for flag in permissionMode.launchFlags(for: .claude) {
                base.append(flag: flag.name, value: flag.value)
            }
        }
        base.append(contentsOf: integrationFlags)

        let transcriptID = session.resumeState.transcriptID
            ?? TranscriptID(session.id.uuidString.lowercased())
        var resume = base
        resume.append(flag: "--resume", value: transcriptID.rawValue)
        var fresh = base
        fresh.append(flag: "--session-id", value: transcriptID.rawValue)
        if let name = session.launchName { fresh.append(flag: "--name", value: name) }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fresh.append(operand: prompt)
        }
        return (resume, fresh, transcriptID)
    }
}
