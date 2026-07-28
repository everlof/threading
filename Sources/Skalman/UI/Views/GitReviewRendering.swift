import AppKit

// MARK: - Rendering

/// Turning a loaded phase into the pane's view tree, split from the controller that drives it.
/// Same type, separate file for length — `ConversationRendering`'s arrangement, for the same
/// reason.
///
/// The one thing here that is not placement is *keeping the reader's place*: this pane redraws
/// itself whenever the checkout changes, so a re-render of the same surface restores the scroll
/// offset and honours what the user opened by hand.
extension GitReviewViewController {

    func show(_ phase: Phase) {
        if !isViewLoaded { loadView() }

        // A watched checkout redraws itself under the reader. Keeping the offset across a
        // reload of the *same* surface is what makes that tolerable; a mode switch or a commit
        // opening is a different page and starts at the top.
        let keepsPlace = renderedMode == mode && Self.isSameSurface(self.phase, phase)
        let offset = scrollView.documentVisibleRect.origin
        let composerWasFocused = isFocused(commitComposer)

        self.phase = phase
        renderedMode = mode

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        placeholderLabel.isHidden = true
        backButton.isHidden = true
        counterLabel.isHidden = true
        summaryPill.isHidden = true
        jumpToEndButton.isHidden = true
        scrollView.contentInsets.bottom = 0

        if let notice {
            addRow(makeNotice(notice.text, isError: notice.isError))
            self.notice = nil
        }

        switch phase {
        case .message(let text):
            placeholderLabel.stringValue = text
            placeholderLabel.isHidden = false

        case .files(let files):
            renderCounter(files)
            // The composer belongs to Staged mode, which is the one place where what is about
            // to be committed is exactly what is on screen.
            if mode == .staged {
                addRow(makeCommitComposer(focused: composerWasFocused))
            }
            renderFiles(files)

        case .commits(let canLoadMore):
            renderCommits(canLoadMore: canLoadMore)

        case .commitDetail(let commit, let files):
            backButton.isHidden = false
            renderCounter(files)
            renderDetailHeader(commit)
            renderFiles(files)
        }

        restoreScroll(to: keepsPlace ? offset.y : 0)
        DispatchQueue.main.async { [weak self] in
            self?.updateScrollControls()
        }
    }

    /// Two phases showing the same kind of page — the test for whether a scroll offset taken
    /// before a re-render still means anything after it.
    static func isSameSurface(_ lhs: Phase, _ rhs: Phase) -> Bool {
        switch (lhs, rhs) {
        case (.message, .message), (.files, .files), (.commits, .commits), (.commitDetail, .commitDetail):
            return true
        default:
            return false
        }
    }

    /// The offset is only meaningful once the rebuilt rows have a height, and only up to what
    /// the new content can actually scroll to — a reload that removed files is shorter.
    func restoreScroll(to offsetY: CGFloat) {
        guard offsetY > 0 else {
            scrollView.contentView.scroll(to: .zero)
            return
        }

        view.layoutSubtreeIfNeeded()
        let overflow = (scrollView.documentView?.frame.height ?? 0) - scrollView.contentSize.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(offsetY, max(overflow, 0))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// One line about the write that just happened — an index another git had locked, or the
    /// commit that landed. In the list rather than in an alert: it is about what the pane is
    /// showing, and a sheet for "try again" would be worse than the problem.
    func makeNotice(_ text: String, isError: Bool) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.applyFont(.caption)
        label.textColor = isError ? Design.Status.negative : Design.Text.secondary
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    func renderCounter(_ files: [GitFileDiff]) {
        let added = files.reduce(0) { $0 + $1.added }
        let removed = files.reduce(0) { $0 + $1.removed }

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "+\(added)", attributes: [
            .foregroundColor: Design.Diff.added,
            .font: Design.Typography.caption()
        ]))
        text.append(NSAttributedString(string: " −\(removed)", attributes: [
            .foregroundColor: Design.Diff.removed,
            .font: Design.Typography.caption()
        ]))
        // The plain value first, so the field re-measures; the attributed one then recolours
        // what was measured. Assigning only the attributed value leaves the old width.
        counterLabel.stringValue = text.string
        counterLabel.attributedStringValue = text
        counterLabel.isHidden = false
        summaryPill.configure(files: files.count, added: added, removed: removed)
        summaryPill.isHidden = false
        scrollView.contentInsets.bottom = 54
    }

    /// Small files open ready to read; everything else opens on click. Both limits exist to
    /// bound the view count a huge diff builds, which is what keeps the pane responsive.
    func renderFiles(_ files: [GitFileDiff]) {
        var expandBudget = Self.initialExpandBudget(for: files)

        for file in files {
            let lineCount = file.hunks.reduce(0) { $0 + $1.lines.count }
            let fitsBudget = lineCount > 0
                && lineCount <= GitReviewDefaults.autoExpandFileLineLimit
                && lineCount <= expandBudget

            // A file the user opened stays open however large it is; one they closed stays
            // closed however small. The budget only decides what they have not said.
            let expand = expansionOverrides[file.path] ?? fitsBudget
            if expand { expandBudget -= lineCount }

            let row = GitReviewFileRow(file: file, expanded: expand, staging: staging, wraps: wrapsDiffLines)
            row.onToggle = { [weak self] expanded in
                self?.expansionOverrides[file.path] = expanded
            }
            row.onStageFile = { [weak self] in self?.stageFile(file) }
            row.onStageHunk = { [weak self] index in self?.stageHunk(at: index, of: file) }
            // The row knows it holds a picture; the pane knows which two endpoints the mode
            // measures between. `currentDiffRequest` already answers for an opened commit too.
            row.imagePairProvider = { [weak self] file, completion in
                guard let self, let root = self.repositoryRoot,
                      let request = self.currentDiffRequest else {
                    completion(.failure(.gitFailed("No comparison to read from.")))
                    return
                }
                GitReviewReader.endpointFilePair(
                    path: file.path, request: request, in: root, completion: completion
                )
            }
            addRow(row)
        }
    }

    static func initialExpandBudget(for files: [GitFileDiff]) -> Int {
        let changedLines = files.reduce(0) { $0 + $1.added + $1.removed }
        let isLargeComparison = files.count > GitReviewDefaults.largeDiffFileThreshold
            || changedLines > GitReviewDefaults.largeDiffChangedLineThreshold
        return isLargeComparison ? 0 : GitReviewDefaults.autoExpandTotalLineLimit
    }

    /// What this mode's diff can do to the index, which is nothing in most of them.
    var staging: GitStaging? {
        GitStaging.capability(for: mode)
    }

    func renderCommits(canLoadMore: Bool) {
        // The graph is laid out over the whole page at once — a lane exists because some other
        // commit is waiting for it, which is not knowable one row at a time.
        let graph = GitCommitGraph.rows(for: commits)
        let laneCount = GitCommitGraph.laneCount(of: graph)

        for (index, commit) in commits.enumerated() {
            let row = GitReviewCommitRow(
                commit: commit,
                graph: graph.indices.contains(index) ? graph[index] : nil,
                laneCount: laneCount
            )
            row.onOpen = { [weak self] in self?.openCommit(commit) }
            addRow(row)
            // No gap, so the rail runs unbroken from one row into the next.
            stack.setCustomSpacing(0, after: row)
        }

        if canLoadMore {
            let more = ThemedButton(title: "Show more…", target: self, action: #selector(loadMoreCommits))
            more.isBordered = false
            more.applyFont(.caption)
            more.contentTintColor = Design.Text.secondary
            more.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(more)
        }
    }

    func renderDetailHeader(_ commit: GitCommitSummary) {
        let label = NSTextField(labelWithString: "\(commit.shortHash)  \(commit.subject)")
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.toolTip = "\(commit.subject) — \(commit.author)"
        label.translatesAutoresizingMaskIntoConstraints = false
        addRow(label)
    }

    func addRow(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.leadingAnchor.constraint(
            equalTo: stack.leadingAnchor,
            constant: Design.Spacing.inset
        ).isActive = true
        view.trailingAnchor.constraint(
            equalTo: stack.trailingAnchor,
            constant: -Design.Spacing.inset
        ).isActive = true
    }
}
