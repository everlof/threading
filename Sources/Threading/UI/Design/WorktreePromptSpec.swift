import AppKit

private enum WorktreePromptDefaults {
    static let branchFieldWidth: CGFloat = 260
    static let branchFieldHeight: CGFloat = 24
}

/// The branch prompt used by every desktop host before it creates a worktree.
@MainActor
enum WorktreePromptSpec {
    static var request: TextPromptRequest {
        TextPromptRequest(
            title: L10n.string("New Worktree"),
            message: L10n.string(
                "A worktree lets a session run on its own branch without disturbing this checkout."
            ),
            confirmTitle: L10n.string("Create"),
            placeholder: L10n.string("branch name"),
            fieldSize: NSSize(
                width: WorktreePromptDefaults.branchFieldWidth,
                height: WorktreePromptDefaults.branchFieldHeight
            )
        )
    }
}
