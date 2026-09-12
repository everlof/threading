import Foundation

/// Package work and per-chat authority. The window only presents the requested review.
@MainActor
final class AgentExtensionInstallService {
    enum Review {
        case install(ExtensionInstallProposal)
        case update(name: String, plan: ExtensionUpdatePlan)
    }

    typealias Reviewer = @MainActor (
        Review, String, @escaping @MainActor (Int?) -> Void
    ) -> Void

    private let projects: ProjectStore
    private let extensions: ExtensionManager
    private let trust: AgentExtensionInstallTrustStore

    init(projects: ProjectStore, extensions: ExtensionManager, trust: AgentExtensionInstallTrustStore) {
        self.projects = projects
        self.extensions = extensions
        self.trust = trust
    }

    func propose(
        _ arguments: ExtensionProposeInstallArguments,
        for sessionID: SessionID,
        review: @escaping Reviewer,
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
        guard projects.session(withID: sessionID) != nil else {
            completion(.failure("The calling chat no longer exists."))
            return
        }
        let packageURL = URL(fileURLWithPath: directory, isDirectory: true)
        Task {
            let inspection = await Task.detached(priority: .userInitiated) {
                Result { try ExtensionBundleInspector.inspect(at: packageURL) }
            }.value
            switch inspection {
            case .failure(let error): completion(.failure(error.localizedDescription))
            case .success(let bundle):
                if extensions.installedExtensions.contains(where: {
                    $0.identifier == bundle.manifest.identifier
                }) {
                    proposeUpdate(bundle, from: packageURL, for: sessionID,
                                  review: review, completion: completion)
                    return
                }
                approve(for: sessionID, review: review, proposal: {
                    .install(ExtensionInstallProposal(bundle: bundle))
                }) { approved in
                    guard approved else {
                        completion(.success("The user declined the extension installation."))
                        return
                    }
                    self.extensions.install(from: packageURL) { result in
                        switch result {
                        case .failure(let error): completion(.failure(error.localizedDescription))
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

    private func proposeUpdate(
        _ bundle: ThreadingExtensionBundle,
        from packageURL: URL,
        for sessionID: SessionID,
        review: @escaping Reviewer,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        extensions.updatePlan(from: packageURL) { result in
            switch result {
            case .failure(let error): completion(.failure(error.localizedDescription))
            case .success(let plan):
                self.approve(for: sessionID, review: review, proposal: {
                    .update(name: bundle.manifest.name, plan: plan)
                }) { approved in
                    guard approved else {
                        completion(.success("The user declined the extension update."))
                        return
                    }
                    self.extensions.update(from: packageURL, approving: plan) { result in
                        switch result {
                        case .failure(let error): completion(.failure(error.localizedDescription))
                        case .success(let updated):
                            completion(.success(
                                "Updated \(updated.name) to version \(plan.candidateVersion). "
                                    + "Enablement was preserved: an extension that was running "
                                    + "is running again on the new code."
                            ))
                        }
                    }
                }
            }
        }
    }

    private func approve(
        for sessionID: SessionID,
        review: Reviewer,
        proposal: () -> Review,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let session = projects.session(withID: sessionID) else {
            completion(false)
            return
        }
        if trust.allows(sessionID) {
            completion(true)
            return
        }
        review(proposal(), session.displayTitle) { answer in
            guard self.projects.session(withID: sessionID) != nil,
                  let answer, (0...1).contains(answer) else {
                completion(false)
                return
            }
            if answer == 1 { self.trust.allow(sessionID, name: session.displayTitle) }
            completion(true)
        }
    }
}
