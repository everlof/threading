import AppKit

/// The two ways a project folder is obtained: chosen from disk, or created fresh.
///
/// The sidebar's Add Project menu and the Project menu offer the same pair, so the panels
/// live here rather than in either presenter.
@MainActor
enum ProjectFolderPrompt {

    /// Asks for an existing folder to adopt as a project.
    static func chooseExistingFolder(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("Add Project")
        panel.message = L10n.string("Choose a folder to add as a project.")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    /// Asks where to create a new folder, creates it, and hands it back.
    ///
    /// The save panel is the system's own name-and-place question, so there is no custom
    /// sheet to build. A folder already at the chosen path is adopted rather than replaced —
    /// `createDirectory` with intermediates succeeds on an existing directory and deletes
    /// nothing.
    static func createNewFolder(completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = L10n.string("New Project")
        panel.prompt = L10n.string("Create")
        panel.nameFieldLabel = L10n.string("Name:")
        panel.nameFieldStringValue = L10n.string("New Project")
        panel.canCreateDirectories = true
        panel.showsTagField = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
                completion(url)
            } catch {
                ThreadingLogger.session.error(
                    "Project folder creation failed destination=\(url.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                presentCreationFailure(for: url, error: error)
            }
        }
    }

    private static func presentCreationFailure(for url: URL, error: Error) {
        let alert = ThemedAlert()
        alert.messageText = L10n.format(
            "Could not create “%@”",
            url.lastPathComponent
        )
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
