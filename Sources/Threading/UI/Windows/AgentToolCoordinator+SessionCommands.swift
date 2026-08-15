@MainActor
extension AgentToolCoordinator {
    func archiveSession(
        _ arguments: ArchiveSessionArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        dependencies.sessionCommands.archiveSession(arguments, for: sessionID)
    }

    func setSessionName(
        _ arguments: SetSessionNameArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        dependencies.sessionCommands.setSessionName(arguments, for: sessionID)
    }

    func cancelSessionArchive(for sessionID: SessionID) -> MCPToolResult {
        dependencies.sessionCommands.cancelSessionArchive(for: sessionID)
    }
}
