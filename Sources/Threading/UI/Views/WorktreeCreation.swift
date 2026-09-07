import AppKit

// MARK: - Constants

private enum WorktreeCreationDefaults {
    static let branchFieldWidth: CGFloat = 260
    static let branchFieldHeight: CGFloat = 24
}

/// Asking for a branch, making the worktree, and saying so when it could not be made.
///
/// Two surfaces offer `New Worktree…` — the composer's location menu, which is asking *where
/// this session should run*, and the repository root's `+` in the sidebar, which is asking the
/// repository to grow a checkout. They differ in what they do with the result and in nothing
/// else, so the prompt, the destination and the failure alert live here rather than being
/// written out twice and drifting into two different wordings for one act.
@MainActor
enum WorktreeCreation {

    /// Prompts for a branch and creates a worktree of `project`'s repository on it.
    ///
    /// Returns the created directory, or nil when the prompt was cancelled — cancelling is the
    /// ordinary answer and is not reported. A genuine failure is presented here and also
    /// returns nil, so a caller has one thing to check.
    ///
    /// `project` is only where git is *run*: a worktree is added to the repository, so any
    /// checkout of it reaches the same result, which is what lets a repository root hand this
    /// the checkout that stands for it.
    static func requestWorktree(from project: Project) -> URL? {
        let request = TextPromptRequest(
            title: L10n.string("New Worktree"),
            message: L10n.string(
                "A worktree lets a session run on its own branch without disturbing this checkout."
            ),
            confirmTitle: L10n.string("Create"),
            placeholder: L10n.string("branch name"),
            fieldSize: NSSize(
                width: WorktreeCreationDefaults.branchFieldWidth,
                height: WorktreeCreationDefaults.branchFieldHeight
            )
        )

        guard case .text(let branch)? = TextPromptAlert.ask(request) else { return nil }

        do {
            guard let destination = GitWorktree.suggestedLocation(
                forBranch: branch,
                in: project
            ) else {
                throw GitWorktree.Failure.notARepository
            }
            return try GitWorktree.create(branch: branch, at: destination, from: project)
        } catch {
            present(error)
            return nil
        }
    }

    /// The branch a created worktree stands on, read back from the checkout itself rather than
    /// carried from the prompt: `GitWorktree.create` is what decided, and a caller recording
    /// what was *typed* would record a branch git may have normalised.
    static func branch(of worktree: URL) -> String? {
        GitInfo.currentBranch(for: worktree.path)
    }

    private static func present(_ error: Error) {
        let alert = ThemedAlert()
        alert.messageText = L10n.string("Could not create worktree")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("OK"))
        alert.runModal()
    }
}
