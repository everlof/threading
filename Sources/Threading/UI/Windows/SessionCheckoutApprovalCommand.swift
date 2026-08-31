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

/// The same approval hop for a checkout the tool call itself creates.
///
/// It reuses `approveSessionCheckoutMove` rather than earning a prompt of its own. The act being
/// confirmed is identical — this conversation resumes somewhere else — and a second switch for it
/// would let someone silence one and not the other, which is a trap rather than a choice.
@MainActor
enum SessionWorktreeCommand {
    static func execute(
        _ arguments: CreateSessionWorktreeArguments,
        for sessionID: SessionID,
        service: AgentSessionCommandService,
        window: NSWindow?,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        switch service.createSessionWorktree(arguments, for: sessionID) {
        case .refused(let message):
            completion(.failure(message))
        case .created(let path, let move):
            finish(move, path: path)
        }

        func finish(_ result: SessionCheckoutMoveRequestResult, path: String) {
            switch result {
            case .queued:
                completion(.success(
                    "Created \(path) and queued this conversation's move into it. End this turn now; the next turn resumes there."
                ))
            case .approvalRequired(let move):
                let request = ConfirmationRequest(
                    prompt: .approveSessionCheckoutMove,
                    title: L10n.string("Move this chat to the new worktree?"),
                    message: L10n.format(
                        "The agent created %@ and wants to continue this conversation there. Reason: %@",
                        move.checkoutPath,
                        move.reason
                    ),
                    confirmTitle: L10n.string("Move Chat"),
                    style: .informational
                )
                ConfirmationAlert.ask(request, in: window) { approved in
                    // The answer is spent on a *move*, never by calling back into creation. The
                    // worktree exists by now, so a second create refuses on `destinationExists`
                    // — which would have turned every approval into a failure while the
                    // checkout sat there unused. The checkout is the argument now.
                    finish(
                        service.setSessionCheckout(
                            SetSessionCheckoutArguments(
                                checkoutPath: path,
                                authorityBasis: arguments.authorityBasis,
                                reason: arguments.reason
                            ),
                            for: sessionID,
                            approval: approved
                        ),
                        path: path
                    )
                }
            case .denied:
                completion(.failure(
                    "The user declined the move. The worktree at \(path) was kept."
                ))
            case .failed(let message):
                completion(.failure("Created \(path), but the move was refused: \(message)"))
            }
        }
    }
}

/// The protocol witness stays an adapter: policy and UI live in the command above, while the
/// broad MCP coordinator does not acquire another application-service responsibility.
@MainActor
extension MCPBuiltInToolExecuting {

    func createSessionWorktree(
        _ arguments: CreateSessionWorktreeArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let coordinator = self as? AgentToolCoordinator else {
            completion(.failure("Worktrees are unavailable in this host."))
            return
        }
        SessionWorktreeCommand.execute(
            arguments,
            for: sessionID,
            service: coordinator.dependencies.sessionCommands,
            window: coordinator.windowProvider(),
            completion: completion
        )
    }

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
