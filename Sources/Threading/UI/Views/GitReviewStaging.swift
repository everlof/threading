import AppKit

/// The Review pane's write half, kept out of the controller's own body: staging a file, staging
/// a hunk, committing what is staged, and the one line of feedback each of those leaves behind.
///
/// An extension rather than another controller — these are three verbs on the view that is
/// already showing the diff they act on, and splitting them into a type of their own would only
/// move the wiring somewhere else.
extension GitReviewViewController {

    func stageFile(_ file: GitFileDiff) {
        guard let staging, let root = repositoryRoot else { return }

        // A rename is two paths to the index, and staging only the new one leaves the old
        // file staged for nothing.
        var paths = [file.path]
        if case .renamed(let from) = file.change { paths.append(from) }

        let finish: @MainActor (Result<Void, GitFailure>) -> Void = { [weak self] result in
            self?.finishWrite(result)
        }
        switch staging.action {
        case .stage: GitIndexWriter.stage(paths: paths, in: root, completion: finish)
        case .unstage: GitIndexWriter.unstage(paths: paths, in: root, completion: finish)
        }
    }

    func stageHunk(at index: Int, of file: GitFileDiff) {
        guard let staging, let root = repositoryRoot, file.hunks.indices.contains(index) else { return }

        GitIndexWriter.apply(
            patch: GitPatch.patch(for: file.hunks[index], path: file.path),
            reverse: staging.action.isReverse,
            in: root
        ) { [weak self] result in
            self?.finishWrite(result)
        }
    }

    func commit(_ message: String) {
        guard let root = repositoryRoot else { return }

        GitIndexWriter.commit(message: message, in: root) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let subject):
                // The message is only forgotten once it is safely a commit.
                self.commitMessage = ""
                self.notice = ("Committed: \(subject)", false)
                self.refresh(force: true)
            case .failure(let failure):
                self.notice = (failure.errorDescription ?? L10n.string("git failed."), true)
                self.refresh(force: true)
            }
        }
    }

    /// Every write ends the same way: say what went wrong if anything did, then re-read —
    /// the index has moved, and the pane is a picture of the index.
    func finishWrite(_ result: Result<Void, GitFailure>) {
        if case .failure(let failure) = result {
            notice = (failure.errorDescription ?? L10n.string("git failed."), true)
        }
        refresh(force: true)
    }

    /// The commit composer, rebuilt with the file list and restored from `commitMessage` —
    /// a watched checkout re-reads itself after every stage, and a message typed into a view
    /// that is about to be thrown away has to outlive it.
    func makeCommitComposer(focused: Bool) -> NSView {
        let composer = PromptView()
        composer.placeholder = GitReviewUIDefaults.commitPlaceholder
        composer.stringValue = commitMessage
        composer.onChange = { [weak self] text in self?.commitMessage = text }
        composer.onSubmit = { [weak self] text in self?.commit(text) }
        commitComposer = composer

        if focused {
            // After the stack has taken it: focusing a view that is not yet in the window
            // does nothing.
            DispatchQueue.main.async { [weak composer] in composer?.focus() }
        }

        // The draft button rides beside the composer only where a Codex login exists to run
        // it — the same gate as icon research, for the same reason: the run spends the
        // user's usage, on the default account.
        guard !AgentAccountDiscovery.accounts(for: .codex).isEmpty else { return composer }

        let draft = ThemedButton(
            symbol: "sparkles",
            accessibility: L10n.string("Draft commit message"),
            target: self,
            action: #selector(draftCommitMessage)
        )
        draft.isBordered = false
        draft.toolTip = L10n.string("Draft a message from the staged changes")
        draft.isEnabled = !isDraftingCommitMessage
        draftButton = draft

        composer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [composer, draft])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        return row
    }

    /// One draft per click, and never two at once. The diff is fetched fresh — what is
    /// staged is what will be committed, and the pane may have staged more since the last
    /// render — with the recent subjects riding along as the voice sample.
    @objc func draftCommitMessage() {
        guard !isDraftingCommitMessage, let root = repositoryRoot else { return }
        isDraftingCommitMessage = true
        draftButton?.isEnabled = false

        GitReviewReader.rawDiff(.staged, in: root) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                self.draftFailed(failure.errorDescription ?? "git failed.")
            case .success(let diff):
                guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.draftFailed("Nothing staged to describe.")
                    return
                }
                self.draftMessage(from: diff, in: root)
            }
        }
    }

    private func draftMessage(from diff: String, in root: URL) {
        GitReviewReader.recentSubjects(
            count: CommitDraftDefaults.subjectSampleCount,
            in: root
        ) { [weak self] subjects in
            guard let self else { return }

            // A missing voice sample is not a reason to refuse the draft.
            let sample = (try? subjects.get()) ?? []
            CommitMessageComposer.run(
                stagedDiff: diff,
                recentSubjects: sample,
                in: root
            ) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .success(let message):
                    self.isDraftingCommitMessage = false
                    self.draftButton?.isEnabled = true
                    self.commitMessage = message
                    self.commitComposer?.stringValue = message
                case .failure(let error):
                    self.draftFailed(error.message)
                }
            }
        }
    }

    private func draftFailed(_ text: String) {
        isDraftingCommitMessage = false
        draftButton?.isEnabled = true
        notice = (text, true)
        show(phase)
    }

    func isFocused(_ candidate: NSView?) -> Bool {
        guard let candidate, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: candidate)
    }
}
