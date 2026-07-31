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
        let performanceSpan = PerformanceRecorder.shared.begin(
            "git.review.render",
            category: "git.review.ui",
            metadata: Self.performanceMetadata(for: phase)
        )
        defer {
            performanceSpan.end(metadata: [
                "rendered_rows": String(stack.arrangedSubviews.count)
            ])
        }

        // A watched checkout redraws itself under the reader. Keeping the offset across a
        // reload of the *same* surface is what makes that tolerable; a mode switch or a commit
        // opening is a different page and starts at the top.
        let keepsPlace = renderedMode == mode && Self.isSameSurface(self.phase, phase)
        let offset = scrollView.documentVisibleRect.origin
        let composerWasFocused = isFocused(commitComposer)

        self.phase = phase
        renderedMode = mode
        if !keepsPlace {
            materializedFileLimit = GitReviewUIDefaults.fileRowBatchSize
            bulkExpansionOverride = nil
        }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resetRenderedFiles()
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

    /// Small files open ready to read; everything else opens on click. A large file index is
    /// also materialized in batches: collapsed bodies are cheap, but AppKit still solves every
    /// header's constraints before it can display the first one.
    func renderFiles(_ files: [GitFileDiff]) {
        let performanceSpan = PerformanceRecorder.shared.begin(
            "git.review.render-files",
            category: "git.review.ui",
            metadata: [
                "files": String(files.count),
                "changed_lines": String(files.reduce(0) { $0 + $1.added + $1.removed })
            ]
        )
        defer {
            performanceSpan.end(metadata: [
                "materialized_files": String(nextFileIndex)
            ])
        }

        renderedFiles = files
        remainingExpandBudget = Self.initialExpandBudget(for: files)
        // Once for the whole diff: `repositoryRoot` walks the tree looking for `.git`, and a
        // branch comparison can list hundreds of files.
        renderedFileRoot = repositoryRoot
        appendFileRows(upTo: min(materializedFileLimit, files.count))
    }

    /// Adds only the next slice to the existing stack. Rebuilding the previous rows on every
    /// click would make traversing the index quadratic even though opening it was bounded.
    private func appendFileRows(upTo requestedLimit: Int) {
        moreFilesButton?.removeFromSuperview()
        moreFilesButton = nil

        let limit = min(max(requestedLimit, nextFileIndex), renderedFiles.count)
        guard nextFileIndex < limit else {
            addMoreFilesButtonIfNeeded()
            return
        }

        for file in renderedFiles[nextFileIndex..<limit] {
            let lineCount = file.hunks.reduce(0) { $0 + $1.lines.count }
            let fitsBudget = lineCount > 0
                && lineCount <= GitReviewDefaults.autoExpandFileLineLimit
                && lineCount <= remainingExpandBudget

            // A file the user opened stays open however large it is; one they closed stays
            // closed however small. The budget only decides what they have not said.
            let expand = expansionOverrides[file.path] ?? bulkExpansionOverride ?? fitsBudget
            if expand { remainingExpandBudget -= lineCount }

            // The row's "Open in" needs an absolute path, and a diff carries only a path
            // relative to the checkout — which is the pane's fact, not the row's.
            let row = GitReviewFileRow(
                file: file,
                expanded: expand,
                staging: staging,
                wraps: wrapsDiffLines,
                fileURL: renderedFileRoot?.appendingPathComponent(file.path)
            )
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

        nextFileIndex = limit
        materializedFileLimit = max(materializedFileLimit, limit)
        addMoreFilesButtonIfNeeded()
    }

    private func addMoreFilesButtonIfNeeded() {
        guard nextFileIndex < renderedFiles.count else { return }

        let more = ThemedButton(
            title: L10n.string("Show more…"),
            target: self,
            action: #selector(loadMoreFiles)
        )
        more.isBordered = false
        more.applyFont(.caption)
        more.contentTintColor = Design.Text.secondary
        more.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(more)
        moreFilesButton = more
    }

    @objc func loadMoreFiles() {
        let performanceSpan = PerformanceRecorder.shared.begin(
            "git.review.materialize-file-batch",
            category: "git.review.ui",
            metadata: [
                "start": String(nextFileIndex),
                "files": String(renderedFiles.count)
            ]
        )
        appendFileRows(
            upTo: nextFileIndex + GitReviewUIDefaults.fileRowBatchSize
        )
        view.layoutSubtreeIfNeeded()
        updateScrollControls()
        performanceSpan.end(metadata: ["end": String(nextFileIndex)])
    }

    private func resetRenderedFiles() {
        renderedFiles = []
        nextFileIndex = 0
        remainingExpandBudget = 0
        renderedFileRoot = nil
        moreFilesButton = nil
    }

    static func initialExpandBudget(for files: [GitFileDiff]) -> Int {
        let changedLines = files.reduce(0) { $0 + $1.added + $1.removed }
        let isLargeComparison = files.count > GitReviewDefaults.largeDiffFileThreshold
            || changedLines > GitReviewDefaults.largeDiffChangedLineThreshold
        return isLargeComparison ? 0 : GitReviewDefaults.autoExpandTotalLineLimit
    }

    private static func performanceMetadata(for phase: Phase) -> [String: String] {
        switch phase {
        case .message:
            return ["phase": "message"]
        case .files(let files):
            return ["phase": "files", "files": String(files.count)]
        case .commits:
            return ["phase": "commits"]
        case .commitDetail(_, let files):
            return ["phase": "commit-detail", "files": String(files.count)]
        }
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
            let more = ThemedButton(
                title: L10n.string("Show more…"),
                target: self,
                action: #selector(loadMoreCommits)
            )
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
