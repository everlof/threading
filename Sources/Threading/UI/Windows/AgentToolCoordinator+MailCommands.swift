import Foundation

// MARK: - Mail Commands

/// The mail tools' entry points. Policy and wording live in `MailAgentCommandService`; the hub
/// only forwards, so the tool family adds no authority here.
@MainActor
extension AgentToolCoordinator {
    private var mailCommands: MailAgentCommandService {
        MailAgentCommandService(control: dependencies.control, projects: dependencies.projects, mailbox: dependencies.mail)
    }

    func mailSend(
        _ arguments: MailSendArguments, for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) { mailCommands.send(arguments, for: sessionID, completion: completion) }

    func mailInbox(
        _ arguments: MailInboxArguments, for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) { mailCommands.inbox(arguments, for: sessionID, completion: completion) }

    func mailAck(
        _ arguments: MailAckArguments, for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) { mailCommands.acknowledge(arguments, for: sessionID, completion: completion) }

    func mailDirectory(
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) { mailCommands.directory(for: sessionID, completion: completion) }
}
