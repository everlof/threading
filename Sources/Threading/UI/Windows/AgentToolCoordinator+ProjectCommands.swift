import AppKit

@MainActor
extension AgentToolCoordinator {
    // MARK: Project Icon

    /// Async because the icon may arrive over the network; the file form answers at once.
    func setProjectIcon(
        _ arguments: SetProjectIconArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let project = dependencies.projects.project(forSessionID: sessionID) else {
            completion(.failure("This session belongs to no project."))
            return
        }

        if let path = arguments.path, !path.isEmpty {
            guard let url = resolve(path: path, for: sessionID) else {
                completion(.failure("No such file: \(path)"))
                return
            }
            guard let data = ProjectIconStore.candidateData(at: url) else {
                completion(.failure("Could not read \(url.lastPathComponent)."))
                return
            }
            completion(apply(iconData: data, to: project))
            return
        }

        if let address = arguments.url, !address.isEmpty {
            guard let url = URL(string: address), url.scheme == "https" else {
                completion(.failure("url must be an https image URL."))
                return
            }

            // Fetched off the main actor; everything that touches the store resumes here.
            Task { @MainActor [weak self] in
                let data = await Task.detached(priority: .userInitiated) {
                    ProjectIconDiscovery.fetchImage(url)
                }.value
                guard let self else { return }
                guard let data else {
                    completion(.failure("\(address) did not serve a usable image."))
                    return
                }
                completion(self.apply(iconData: data, to: project))
            }
            return
        }

        completion(.failure("Provide either path or url."))
    }

    func apply(iconData: Data, to project: Project) -> MCPToolResult {
        switch dependencies.projects.setIcon(
            imageData: iconData,
            source: .agent,
            for: project.id
        ) {
        case .success:
            return .success("Set \"\(project.name)\"'s sidebar icon.")
        case .failure(.unusableImage):
            return .failure("""
                That is not an image Threading can use as an icon — it needs to decode as \
                PNG, JPEG, GIF, HEIC or ICO at 16px or larger.
                """)
        case .failure(.projectNotFound):
            return .failure("That project no longer exists.")
        case .failure(.storageFailed), .failure(.persistenceRefused):
            return .failure("The project icon could not be saved.")
        }
    }

}
