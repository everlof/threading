import AppKit

@MainActor
extension AgentToolCoordinator {
    // MARK: Tools

    func extensionListComponents() -> MCPToolResult {
        dependencies.extensionAuthoring.listComponents()
    }

    func extensionScaffoldProject(
        _ arguments: ExtensionScaffoldProjectArguments
    ) -> MCPToolResult {
        dependencies.extensionAuthoring.scaffoldProject(arguments)
    }

    func extensionProposeInstall(
        _ arguments: ExtensionProposeInstallArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        dependencies.extensionInstallation.propose(arguments, for: sessionID, review: { [weak self] review, name, decided in
            guard let self else { decided(nil); return }
            let request: ConfirmationRequest
            switch review {
            case .install(let proposal):
                request = ExtensionInstallConfirmation.request(
                    for: proposal, prompt: .approveAgentExtensionInstall
                )
            case .update(let name, let plan):
                let confirmation = plan.confirmation(name: name)
                request = ConfirmationRequest(
                    prompt: .updateExtensionCapabilities,
                    title: confirmation.title,
                    message: confirmation.message,
                    confirmTitle: confirmation.acceptTitle,
                    style: plan.requiresApproval ? .warning : .informational
                )
            }
            let choice = AgentExtensionInstallConfirmation.request(from: request, agentName: name)
            if let extensionInstallDecision {
                extensionInstallDecision(choice, decided)
            } else {
                ConfirmationAlert.choose(choice, in: windowProvider(), completion: decided)
            }
        }, completion: completion)
    }

    func extensionDescribeComponent(
        _ arguments: ExtensionComponentReferenceArguments
    ) -> MCPToolResult {
        dependencies.extensionAuthoring.describeComponent(arguments)
    }

    func extensionValidateComponentPatch(
        _ arguments: ExtensionComponentPatchArguments
    ) -> MCPToolResult {
        dependencies.extensionAuthoring.validateComponentPatch(arguments)
    }

    func extensionPreviewComponentPatch(
        _ arguments: ExtensionComponentPatchArguments,
        for sessionID: SessionID
    ) -> MCPToolResult {
        guard let patch = arguments.patch, !patch.isEmpty else {
            return .failure("Missing required argument: patch")
        }
        do {
            let preview = try ExtensionComponentAuthoringService.preview(patch)
            return present(
                DisplayContent(
                    body: .image(preview.image, url: preview.url),
                    title: L10n.format("%@ preview", preview.componentID),
                    subtitle: L10n.string(
                        "Extension component · native semantic renderer"
                    )
                ),
                for: sessionID,
                describedAs: "the \(preview.componentID) extension preview"
            )
        } catch {
            return .failure(
                ExtensionComponentAuthoringService.validationMessage(for: error)
            )
        }
    }

}
