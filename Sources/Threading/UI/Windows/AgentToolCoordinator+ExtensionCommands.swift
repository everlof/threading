import AppKit

@MainActor
extension AgentToolCoordinator {
    // MARK: Tools

    func extensionListComponents() -> MCPToolResult {
        do {
            return .success(try ExtensionComponentAuthoringService.listJSON())
        } catch {
            return .failure(
                ExtensionComponentAuthoringService.validationMessage(for: error)
            )
        }
    }

    func extensionScaffoldProject(
        _ arguments: ExtensionScaffoldProjectArguments
    ) -> MCPToolResult {
        guard let name = arguments.name?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !name.isEmpty else {
            return .failure("Missing required argument: name")
        }
        guard let identifier = arguments.identifier, !identifier.isEmpty else {
            return .failure("Missing required argument: identifier")
        }
        guard let directory = arguments.directory, !directory.isEmpty else {
            return .failure("Missing required argument: directory")
        }
        guard NSString(string: directory).isAbsolutePath else {
            return .failure("directory must be an absolute path")
        }
        guard let sdk = Bundle.main.resourceURL?.appendingPathComponent(
            "ExtensionSDK/ThreadingExtensionKit",
            isDirectory: true
        ) else {
            return .failure("This Threading build does not contain its extension SDK snapshot.")
        }

        do {
            let project = try ExtensionProjectScaffolder.scaffold(
                name: name,
                identifier: identifier,
                at: URL(fileURLWithPath: directory, isDirectory: true),
                sdkSnapshotURL: sdk
            )
            _ = dependencies.projects.addProject(folderURL: project.directoryURL)
            return .success(
                "Created \(project.manifest.name) at \(project.directoryURL.path), vendored "
                    + "ThreadingExtensionKit SDK \(project.sdkVersion) with its offline authoring "
                    + "contract, and added it as a Threading project. Start with "
                    + "Vendor/docs/extensions/AGENT_AUTHORING.md. It is source only: build its "
                    + "WebAssembly module, assemble a .threadingextension, then propose "
                    + "installation for capability approval."
            )
        } catch {
            return .failure(error.localizedDescription)
        }
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
                let request = ConfirmationRequest(
                    prompt: .approveAgentExtensionInstall,
                    title: proposal.title,
                    message: proposal.message,
                    confirmTitle: proposal.acceptTitle,
                    style: .informational
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
        guard let component = arguments.component, !component.isEmpty else {
            return .failure("Missing required argument: component")
        }
        do {
            return .success(
                try ExtensionComponentAuthoringService.describeJSON(
                    componentID: component,
                    version: arguments.version
                )
            )
        } catch {
            return .failure(
                ExtensionComponentAuthoringService.validationMessage(for: error)
            )
        }
    }

    func extensionValidateComponentPatch(
        _ arguments: ExtensionComponentPatchArguments
    ) -> MCPToolResult {
        guard let patch = arguments.patch, !patch.isEmpty else {
            return .failure("Missing required argument: patch")
        }
        do {
            return .success(
                try ExtensionComponentAuthoringService.validateJSON(patch)
            )
        } catch {
            return .failure(
                ExtensionComponentAuthoringService.validationMessage(for: error)
            )
        }
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
