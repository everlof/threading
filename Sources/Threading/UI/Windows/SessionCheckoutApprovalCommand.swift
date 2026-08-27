import AppKit

/// Owns the interactive approval hop without making the MCP coordinator another policy surface.
@MainActor
enum SessionCheckoutApprovalCommand {
    static func execute(
        _ arguments: SetSessionCheckoutArguments,
        for sessionID: SessionID,
        service: AgentSessionCommandService,
        window: NSWindow?,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        func finish(_ result: SessionCheckoutMoveRequestResult) {
            switch result {
            case .queued(let move):
                completion(.success(
                    "Checkout move queued for \(move.checkoutPath). End this turn now; the next turn resumes in that checkout."
                ))
            case .approvalRequired(let move):
                let request = ConfirmationRequest(
                    prompt: .approveSessionCheckoutMove,
                    title: L10n.string("Move this chat to another checkout?"),
                    message: L10n.format(
                        "The agent wants to resume this conversation in %@. Reason: %@",
                        move.checkoutPath,
                        move.reason
                    ),
                    confirmTitle: L10n.string("Move Chat"),
                    style: .informational
                )
                ConfirmationAlert.ask(request, in: window) { approved in
                    finish(service.setSessionCheckout(
                        arguments,
                        for: sessionID,
                        approval: approved
                    ))
                }
            case .denied:
                completion(.failure("The user declined the checkout move."))
            case .failed(let message):
                completion(.failure(message))
            }
        }
        finish(service.setSessionCheckout(arguments, for: sessionID))
    }
}

/// The protocol witness stays an adapter: policy and UI live in the command above, while the
/// broad MCP coordinator does not acquire another application-service responsibility.
@MainActor
extension MCPBuiltInToolExecuting {
    func setSessionCheckout(
        _ arguments: SetSessionCheckoutArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let coordinator = self as? AgentToolCoordinator else {
            completion(.failure("Checkout moves are unavailable in this host."))
            return
        }
        SessionCheckoutApprovalCommand.execute(
            arguments,
            for: sessionID,
            service: coordinator.dependencies.sessionCommands,
            window: coordinator.windowProvider(),
            completion: completion
        )
    }

    func cancelSessionCheckoutMove(
        _ arguments: EmptyToolArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        guard let coordinator = self as? AgentToolCoordinator else {
            return .failure("Checkout moves are unavailable in this host.")
        }
        return coordinator.dependencies.sessionCommands.cancelSessionCheckoutMove(for: sessionID)
    }
}
