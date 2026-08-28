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
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let directory = arguments.directory, !directory.isEmpty else {
            completion(.failure("Missing required argument: directory"))
            return
        }
        guard NSString(string: directory).isAbsolutePath else {
            completion(.failure("directory must be an absolute path"))
            return
        }

        let packageURL = URL(fileURLWithPath: directory, isDirectory: true)
        Task { @MainActor [weak self] in
            let inspection = await Task.detached(priority: .userInitiated) {
                Result {
                    try ExtensionBundleInspector.inspect(at: packageURL)
                }
            }.value
            guard let self else {
                completion(.failure("Threading’s window closed before the package was reviewed."))
                return
            }
            switch inspection {
            case .failure(let error):
                completion(.failure(error.localizedDescription))
            case .success(let bundle):
                // A package whose identifier is already installed is an *update*, and it goes
                // through the same plan and wording as Settings ▸ Extensions ▸ Update… — the
                // capability delta is what the user approves, not merely "a newer file". This
                // is the dogfood round trip: build, propose, approve, iterate, without a file
                // picker in the middle.
                let isInstalled = dependencies.extensions.installedExtensions
                    .contains { $0.identifier == bundle.manifest.identifier }
                if isInstalled {
                    self.proposeUpdate(
                        of: bundle,
                        from: packageURL,
                        completion: completion
                    )
                    return
                }
                let proposal = ExtensionInstallProposal(bundle: bundle)
                let request = ExtensionInstallConfirmation.request(
                    for: proposal,
                    prompt: .approveAgentExtensionInstall
                )

                ConfirmationAlert.ask(request, in: self.windowProvider()) { approved in
                    guard approved else {
                        completion(.success("The user declined the extension installation."))
                        return
                    }
                    self.dependencies.extensions.install(from: packageURL) { result in
                        switch result {
                        case .failure(let error):
                            completion(.failure(error.localizedDescription))
                        case .success(let installed):
                            completion(.success(
                                "Installed \(installed.name) \(installed.version ?? "") "
                                    + "as a disabled extension. The user can enable it in "
                                    + "Settings → Extensions."
                            ))
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func proposeUpdate(
        of bundle: ThreadingExtensionBundle,
        from packageURL: URL,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let name = bundle.manifest.name
        dependencies.extensions.updatePlan(from: packageURL) { [weak self] result in
            guard let self else {
                completion(.failure("Threading’s window closed before the update was reviewed."))
                return
            }
            switch result {
            case .failure(let error):
                completion(.failure(error.localizedDescription))
            case .success(let plan):
                let confirmation = plan.confirmation(name: name)
                let request = ConfirmationRequest(
                    prompt: .updateExtensionCapabilities,
                    title: confirmation.title,
                    message: confirmation.message,
                    confirmTitle: confirmation.acceptTitle,
                    style: plan.requiresApproval ? .warning : .informational
                )
                ConfirmationAlert.ask(request, in: self.windowProvider()) { approved in
                    guard approved else {
                        completion(.success("The user declined the extension update."))
                        return
                    }
                    self.dependencies.extensions.update(
                        from: packageURL,
                        approving: plan
                    ) { result in
                        switch result {
                        case .failure(let error):
                            completion(.failure(error.localizedDescription))
                        case .success(let updated):
                            completion(.success(
                                "Updated \(updated.name) to version "
                                    + "\(plan.candidateVersion). Enablement was preserved: "
                                    + "an extension that was running is running again on "
                                    + "the new code."
                            ))
                        }
                    }
                }
            }
        }
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
