import AppKit

// MARK: - Review Text Size

/// The durable, pane-scoped code-size choice. It is global rather than session-scoped because
/// this is a reading preference: opening another checkout should not make the type jump back.
enum GitReviewTextSizePreference {
    static let key = "ThreadingGitReviewCodeTextScale"

    static var current: Design.CodeTextScale {
        PreferenceStore.shared.string(forKey: key)
            .flatMap(Design.CodeTextScale.init(rawValue:))
            ?? .standard
    }

    static func set(_ size: Design.CodeTextScale) {
        PreferenceStore.shared.set(size.rawValue, forKey: key)
    }
}

struct GitReviewTextSizeDidChange: AppEvent {
    static let name = Notification.Name("GitReviewTextSizeDidChange")
    let size: Design.CodeTextScale
}

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

    // MARK: - Text Size

    /// Moves one bounded step and tells every retained Review pane about the reading choice.
    /// The receiver decides whether to rebuild now or when its tab next reaches a window.
    func stepReviewTextSize(by offset: Int) {
        let sizes = Design.CodeTextScale.allCases
        guard let current = sizes.firstIndex(of: reviewTextSize) else { return }
        let target = min(max(current + offset, sizes.startIndex), sizes.index(before: sizes.endIndex))
        guard target != current else { return }
        let size = sizes[target]
        GitReviewTextSizePreference.set(size)
        NotificationCenter.default.post(GitReviewTextSizeDidChange(size: size))
    }

    // MARK: - Menu

    @objc func showOverflowMenu(_ sender: NSView) {
        overflowMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: overflowMenuEntries(),
                minimumWidth: GitReviewUIDefaults.overflowMenuWidth
            ),
            from: sender,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.overflowMenuSession = nil }
        )
    }

    /// The dropdown's rows, built fresh per open. Internal so a test can hold the titles and
    /// the one disabled item to the pane's actual state — a presented menu is unreachable
    /// from a script.
    func overflowMenuEntries() -> [ThemedMenuEntry] {
        var entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: L10n.string("Refresh"),
                onChoose: { [weak self] in self?.refreshFromMenu() }
            ))
        ]
        entries.append(contentsOf: foldedControlEntries())

        // Everything below speaks about a diff, so it appears only when one is on screen — the
        // history list has no lines to wrap, collapse or copy.
        guard showsDiff else { return entries }
        entries.append(contentsOf: collapseEntries())
        entries.append(contentsOf: renderingEntries())
        entries.append(contentsOf: copyEntries())
        return entries
    }

    /// Offered only when something can actually open, so a diff of binaries alone does not carry
    /// a control that would do nothing.
    private func collapseEntries() -> [ThemedMenuEntry] {
        let expandable = renderedFiles.filter {
            GitReviewFileRow.isExpandable($0, showsRichPreviews: showsRichPreviews)
        }
        guard !expandable.isEmpty else { return [] }

        return [
            .separator,
            .item(ThemedMenuItem(
                title: expandable.contains(where: isFileExpanded)
                    ? L10n.string("Collapse all diffs")
                    : L10n.string("Expand all diffs"),
                onChoose: { [weak self] in self?.toggleAllExpansion() }
            ))
        ]
    }

    /// The header's glyph runs, offered here while a narrow pane has folded them away. The
    /// entries press the same buttons, so the two routes cannot drift.
    private func foldedControlEntries() -> [ThemedMenuEntry] {
        var entries: [ThemedMenuEntry] = []
        if navigationButtonGroup.isHidden {
            entries.append(.separator)
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Jump to file"),
                shortcut: KeyboardShortcut(key: "j", modifiers: .command),
                isEnabled: jumpToFileButton.isEnabled,
                onChoose: { [weak self] in self?.jumpToFileButton.onPress?() }
            )))
            entries.append(.item(ThemedMenuItem(
                title: diffLayout == .unified
                    ? L10n.string("Switch to split diff")
                    : L10n.string("Switch to unified diff"),
                onChoose: { [weak self] in self?.diffLayoutButton.onPress?() }
            )))
            entries.append(.item(ThemedMenuItem(
                title: fileNavigatorVisibleForTesting
                    ? L10n.string("Hide changed files")
                    : L10n.string("Show changed files"),
                isEnabled: fileNavigatorButton.isEnabled,
                onChoose: { [weak self] in self?.fileNavigatorButton.onPress?() }
            )))
        }
        if textSizeButtonGroup.isHidden {
            entries.append(.separator)
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Increase diff text size"),
                isEnabled: increaseTextSizeButton.isEnabled,
                onChoose: { [weak self] in self?.increaseTextSizeButton.onPress?() }
            )))
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Decrease diff text size"),
                isEnabled: decreaseTextSizeButton.isEnabled,
                onChoose: { [weak self] in self?.decreaseTextSizeButton.onPress?() }
            )))
        }
        return entries
    }

    /// Five switches, one convention: each names its state and carries a check while it is on.
    /// Four of them used to rename themselves to their opposite verb ("Disable word wrap")
    /// beside one that was checked, which read as two kinds of control.
    private func renderingEntries() -> [ThemedMenuEntry] {
        [
            .separator,
            .item(ThemedMenuItem(
                title: L10n.string("Word wrap"),
                isSelected: wrapsDiffLines,
                isEnabled: diffLayout == .unified,
                onChoose: { [weak self] in self?.toggleWordWrap() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Full files"),
                isSelected: loadsFullFiles,
                onChoose: { [weak self] in self?.toggleFullFiles() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Rich previews"),
                isSelected: showsRichPreviews,
                onChoose: { [weak self] in self?.toggleRichPreviews() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Word diffs"),
                isSelected: showsWordDiffs,
                onChoose: { [weak self] in self?.toggleWordDiffs() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Hide whitespace"),
                isSelected: ignoresWhitespace,
                onChoose: { [weak self] in self?.toggleWhitespace() }
            ))
        ]
    }

    private func copyEntries() -> [ThemedMenuEntry] {
        [
            .separator,
            .item(ThemedMenuItem(
                title: L10n.string("Copy git apply command"),
                // The history list is the one surface with no single patch to speak for.
                isEnabled: currentDiffRequest != nil,
                onChoose: { [weak self] in self?.copyGitApplyCommand() }
            ))
        ]
    }

    // MARK: - State

    private var showsDiff: Bool {
        switch phase {
        case .fileIndex, .files, .commitDetail: return true
        case .message, .commits: return false
        }
    }

    private func isFileExpanded(_ file: GitFileDiff) -> Bool {
        expansionOverrides[file.path]
            ?? bulkExpansionOverride
            ?? GitReviewFileRow.expandsByDefault(file)
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
            return selectedTurnID
                .flatMap(GitTurnBaselineStore.shared.checkpoint(id:))
                .map { GitReviewReader.DiffRequest.turnCheckpoint($0) }
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
        let expandable = renderedFiles.filter {
            GitReviewFileRow.isExpandable($0, showsRichPreviews: showsRichPreviews)
        }
        guard !expandable.isEmpty else { return }
        let expand = !expandable.contains(where: isFileExpanded)
        bulkExpansionOverride = expand
        for file in expandable {
            expansionOverrides[file.path] = expand
        }
        // Every exact height describes the state being left. Reloading with them in place laid
        // collapsed headers out in 300pt slots and expanded bodies in 48pt ones until each row's
        // measurement caught up, and the rows overprinted each other meanwhile.
        measuredFileRowHeights.removeAll(keepingCapacity: true)
        fileTableView.reloadData()
        updateScrollControls()
    }

    /// The rows carry the wrap setting, so this rebuilds the diff on screen rather than
    /// re-reading it — the files are already loaded and git has nothing new to say.
    @objc private func toggleWordWrap() {
        wrapsDiffLines.toggle()
        show(phase)
    }

    @objc private func toggleFullFiles() {
        loadsFullFiles.toggle()
        contextLinesByPath.removeAll(keepingCapacity: false)
        contextExpansionExhaustedPaths.removeAll(keepingCapacity: false)
        refresh(force: true)
    }

    @objc private func toggleRichPreviews() {
        showsRichPreviews.toggle()
        measuredFileRowHeights.removeAll(keepingCapacity: true)
        show(phase, forceRebuild: true)
    }

    @objc private func toggleWordDiffs() {
        showsWordDiffs.toggle()
        measuredFileRowHeights.removeAll(keepingCapacity: true)
        show(phase, forceRebuild: true)
    }

    /// A re-read, not a display filter: which lines count as changed is git's judgement, and
    /// folding whitespace away changes the hunks themselves.
    @objc private func toggleWhitespace() {
        ignoresWhitespace.toggle()
        refresh(force: true)
    }

    @objc private func copyGitApplyCommand() {
        guard let root = loadedDiffRoot ?? repositoryRoot,
              let request = currentDiffRequest else { return }

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
