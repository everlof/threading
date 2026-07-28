import AppKit

// MARK: - Diff Options Menu

/// The `···` overflow behind the Review header: the handful of things asked of a diff
/// occasionally — refreshing it, closing it all up, letting long lines run off the pane,
/// folding whitespace away, and taking the patch somewhere else.
///
/// One overflow rather than a row of glyphs, because the mode chip is the control this header
/// exists for and five icons beside it would compete with it for the same glance.
///
/// The menu is built fresh on every open rather than kept, since every item states current
/// state: the collapse item names the direction it would move, the wrap item names what it
/// would switch to, and the whitespace item carries a checkmark.
extension GitReviewViewController {

    // MARK: - Menu

    @objc func showOverflowMenu(_ sender: NSView) {
        let menu = NSMenu()
        // Items here say whether they apply; left to auto-enable, AppKit would answer that
        // question from the responder chain instead and re-enable the one disabled item.
        menu.autoenablesItems = false

        menu.addItem(
            withTitle: L10n.string("Refresh"),
            action: #selector(refreshFromMenu),
            keyEquivalent: ""
        )

        // Everything below speaks about a diff, so it appears only when one is on screen — the
        // history list has no lines to wrap, collapse or copy.
        if showsDiff {
            addCollapseItem(to: menu)
            addRenderingItems(to: menu)
            addCopyItem(to: menu)
        }

        for item in menu.items { item.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    /// Offered only when something can actually open, so a diff of binaries alone does not carry
    /// a control that would do nothing.
    private func addCollapseItem(to menu: NSMenu) {
        let expandable = fileRows.filter(\.canOpen)
        guard !expandable.isEmpty else { return }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: expandable.contains(where: \.isOpen)
                ? L10n.string("Collapse all diffs")
                : L10n.string("Expand all diffs"),
            action: #selector(toggleAllExpansion),
            keyEquivalent: ""
        )
    }

    private func addRenderingItems(to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(
            withTitle: wrapsDiffLines
                ? L10n.string("Disable word wrap")
                : L10n.string("Enable word wrap"),
            action: #selector(toggleWordWrap),
            keyEquivalent: ""
        )

        let whitespace = menu.addItem(
            withTitle: L10n.string("Hide whitespace"),
            action: #selector(toggleWhitespace),
            keyEquivalent: ""
        )
        whitespace.state = ignoresWhitespace ? .on : .off
    }

    private func addCopyItem(to menu: NSMenu) {
        menu.addItem(.separator())
        let copy = menu.addItem(
            withTitle: L10n.string("Copy git apply command"),
            action: #selector(copyGitApplyCommand),
            keyEquivalent: ""
        )
        // The history list is the one surface with no single patch to speak for.
        copy.isEnabled = currentDiffRequest != nil
    }

    // MARK: - State

    private var showsDiff: Bool {
        switch phase {
        case .files, .commitDetail: return true
        case .message, .commits: return false
        }
    }

    private var fileRows: [GitReviewFileRow] {
        stack.arrangedSubviews.compactMap { $0 as? GitReviewFileRow }
    }

    /// What the pane is showing, as a request the reader can run again — which is what copying
    /// the patch needs, since the pane parsed the diff into a model and no longer holds the text.
    var currentDiffRequest: GitReviewReader.DiffRequest? {
        // An opened commit is its own diff, whichever mode the chip is left on.
        if case .commitDetail(let commit, _) = phase {
            return .commit(hash: commit.hash)
        }

        switch mode {
        case .uncommitted: return .uncommitted
        case .unstaged: return .unstaged
        case .staged: return .staged
        case .branch: return .branch
        case .lastTurn:
            return GitTurnBaselineStore.shared
                .baseline(forSessionID: sessionID)
                .map { GitReviewReader.DiffRequest.lastTurn($0) }
        case .commit: return nil
        }
    }

    // MARK: - Actions

    @objc private func refreshFromMenu() {
        refresh(force: true)
    }

    /// One action rather than two items: if anything is open it closes everything, otherwise it
    /// opens everything. Each row reports the change as though it had been clicked, so what the
    /// user chose here survives the next re-read exactly as a hand-collapsed file does.
    @objc private func toggleAllExpansion() {
        let expandable = fileRows.filter(\.canOpen)
        let expand = !expandable.contains(where: \.isOpen)
        expandable.forEach { $0.setExpanded(expand) }
    }

    /// The rows carry the wrap setting, so this rebuilds the diff on screen rather than
    /// re-reading it — the files are already loaded and git has nothing new to say.
    @objc private func toggleWordWrap() {
        wrapsDiffLines.toggle()
        show(phase)
    }

    /// A re-read, not a display filter: which lines count as changed is git's judgement, and
    /// folding whitespace away changes the hunks themselves.
    @objc private func toggleWhitespace() {
        ignoresWhitespace.toggle()
        refresh(force: true)
    }

    @objc private func copyGitApplyCommand() {
        guard let root = repositoryRoot, let request = currentDiffRequest else { return }

        GitReviewReader.rawDiff(request, in: root, ignoringWhitespace: ignoresWhitespace) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let patch) where patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                self.report(
                    L10n.string("Nothing to copy — this diff has no tracked changes."),
                    isError: false
                )

            case .success(let patch):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.applyCommand(for: patch), forType: .string)

            case .failure(let failure):
                self.report(
                    failure.errorDescription ?? L10n.string("git failed."),
                    isError: true
                )
            }
        }
    }

    /// The patch inside a quoted heredoc, so what lands on the pasteboard is a command that can
    /// be pasted into a shell and run rather than a patch the reader has to arrange around. The
    /// delimiter is quoted, so nothing in the diff is expanded on the way in.
    private static func applyCommand(for patch: String) -> String {
        let delimiter = GitReviewUIDefaults.patchHeredocDelimiter
        let body = patch.hasSuffix("\n") ? patch : patch + "\n"
        return "git apply <<'\(delimiter)'\n" + body + delimiter + "\n"
    }

    /// A failed or empty copy is worth a line above the diff; a successful one is not, since the
    /// pasteboard is the result and re-rendering a whole diff to say so costs more than it says.
    private func report(_ text: String, isError: Bool) {
        notice = (text, isError)
        show(phase)
    }
}
