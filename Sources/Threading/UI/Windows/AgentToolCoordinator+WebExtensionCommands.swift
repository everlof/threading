import Foundation

@MainActor
extension AgentToolCoordinator {
    func webExtensionDevelopment(
        _ arguments: WebExtensionRequest, for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard !dependencies.projects.sessionRunsOnRemoteHost(sessionID),
              let directory = dependencies.projects.workingDirectory(forSessionID: sessionID) else {
            completion(.failure("This chat has no local checkout."))
            return
        }
        if !arguments.action.isRead {
            displayPaneController.activateWebExtensions(for: sessionID, service: dependencies.webExtensions)
            revealDisplayPane(for: sessionID)
        }
        Task {
            let reply = await dependencies.webExtensions.call(arguments, sessionID: sessionID,
                                                                         project: URL(fileURLWithPath: directory))
            completion(reply.toolResult(for: arguments))
        }
    }
}
