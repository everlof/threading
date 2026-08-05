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
            let isFileSurface = scrollView.documentView === fileTableView
            performanceSpan.end(metadata: [
                "model_rows": String(
                    isFileSurface
                        ? filePreludeViews.count + renderedFiles.count
                        : stack.arrangedSubviews.count
                ),
                "instantiated_file_rows": String(instantiatedFileRowCount)
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
            bulkExpansionOverride = nil
        }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resetRenderedFiles()
        scrollView.documentView = stack
        placeholderLabel.isHidden = true
        setBackVisible(false)
        counterLabel.isHidden = true
        summaryPill.isHidden = true
        jumpToEndButton.isHidden = true
        scrollView.contentInsets.bottom = 0

        let pendingNotice = notice
        notice = nil

        switch phase {
        case .message(let text):
            if let pendingNotice {
                addRow(makeNotice(pendingNotice.text, isError: pendingNotice.isError))
            }
            placeholderLabel.stringValue = text
            placeholderLabel.isHidden = false

        case .files(let files):
            renderCounter(files)
            var prelude: [NSView] = []
            if let pendingNotice {
                prelude.append(makeNotice(pendingNotice.text, isError: pendingNotice.isError))
            }
            // The composer belongs to Staged mode, which is the one place where what is about
            // to be committed is exactly what is on screen.
            if mode == .staged {
                prelude.append(makeCommitComposer(focused: composerWasFocused))
            }
            renderFiles(files, prelude: prelude)

        case .commits(let canLoadMore):
            if let pendingNotice {
                addRow(makeNotice(pendingNotice.text, isError: pendingNotice.isError))
            }
            renderCommits(canLoadMore: canLoadMore)

        case .commitDetail(let commit, let files):
            setBackVisible(true)
            renderCounter(files)
            var prelude: [NSView] = []
            if let pendingNotice {
                prelude.append(makeNotice(pendingNotice.text, isError: pendingNotice.isError))
            }
            prelude.append(makeDetailHeader(commit))
            renderFiles(files, prelude: prelude)
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
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(offsetY, maximumScrollOffsetY())))
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

    /// Files open ready to read. The model is complete immediately, while AppKit asks for views
    /// only around the table's viewport; an expanded offscreen file is therefore state, not a
    /// constructed body. A user's explicit close in `expansionOverrides` still wins on refresh.
    func renderFiles(_ files: [GitFileDiff], prelude: [NSView] = []) {
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
                "model_files": String(renderedFiles.count),
                "instantiated_files": String(instantiatedFileRowCount)
            ])
        }

        renderedFiles = files
        filePreludeViews = prelude
        for file in files {
            defaultFileExpansion[file.path] = GitReviewFileRow.expandsByDefault(file)
        }

        // Once for the whole diff: `repositoryRoot` walks the tree looking for `.git`, and a
        // branch comparison can list hundreds of files.
        renderedFileRoot = repositoryRoot

        // `reloadData()` immediately asks for the first row views. Make the clip adopt the
        // pane's current frame first, otherwise those expanded rows still see the 240pt
        // bootstrap width left from `loadView` and AppKit caches that much taller answer.
        view.layoutSubtreeIfNeeded()
        fileRowHeightWidth = max(view.bounds.width - Design.Spacing.inset * 2, 0)
        fileTableView.reloadData()
        scrollView.documentView = fileTableView
    }

    private func resetRenderedFiles() {
        renderedFiles = []
        filePreludeViews = []
        defaultFileExpansion = [:]
        measuredFileRowHeights = [:]
        measuredPreludeRowHeights = [:]
        fileRowHeightWidth = 0
        renderedFileRoot = nil
        instantiatedFileRowCount = 0
        fileTableView.reloadData()
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

    func makeDetailHeader(_ commit: GitCommitSummary) -> NSView {
        let label = NSTextField(labelWithString: "\(commit.shortHash)  \(commit.subject)")
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.toolTip = "\(commit.subject) — \(commit.author)"
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
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

// MARK: - Virtual File Index

extension GitReviewViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        filePreludeViews.count + renderedFiles.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, heightOfRow tableRow: Int) -> CGFloat {
        // `reloadData()` asks for heights before the table becomes the document view, when its
        // own width is still zero. The clip/root already state the pane's final width; using
        // zero here makes every character look wrapped onto its own line and invents an enormous
        // offscreen document tail before the first row is even materialized.
        let paneWidth = max(
            tableView.bounds.width,
            scrollView.contentView.bounds.width,
            view.bounds.width
        )
        let cardWidth = max(paneWidth - Design.Spacing.inset * 2, 0)
        if filePreludeViews.indices.contains(tableRow) {
            guard let measured = measuredPreludeRowHeights[tableRow],
                  abs(measured.width - cardWidth) <= 0.5 else {
                return max(
                    tableView.rowHeight,
                    filePreludeViews[tableRow].fittingSize.height + Design.Spacing.small
                )
            }
            return measured.height
        }

        let fileIndex = tableRow - filePreludeViews.count
        guard renderedFiles.indices.contains(fileIndex) else {
            return tableView.rowHeight
        }
        let file = renderedFiles[fileIndex]
        guard let measured = measuredFileRowHeights[file.path] else {
            let expanded = expansionOverrides[file.path]
                ?? bulkExpansionOverride
                ?? defaultFileExpansion[file.path]
                ?? false
            return GitReviewFileRow.estimatedTableHeight(
                for: file,
                expanded: expanded,
                wraps: wrapsDiffLines,
                width: cardWidth
            )
        }
        guard abs(measured.width - cardWidth) <= 0.5 else {
            let expanded = expansionOverrides[file.path]
                ?? bulkExpansionOverride
                ?? defaultFileExpansion[file.path]
                ?? false
            return GitReviewFileRow.estimatedTableHeight(
                for: file,
                expanded: expanded,
                wraps: wrapsDiffLines,
                width: cardWidth
            )
        }
        return measured.height
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard tableRow >= 0, tableRow < numberOfRows(in: tableView) else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("GitReviewVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? GitReviewVirtualRowHost ?? GitReviewVirtualRowHost()
        host.identifier = identifier

        if filePreludeViews.indices.contains(tableRow) {
            let content = filePreludeViews[tableRow]
            host.install(content)
            schedulePreludeHeightMeasurement(content, host: host, tableRow: tableRow)
            return host
        }

        let fileIndex = tableRow - filePreludeViews.count
        guard renderedFiles.indices.contains(fileIndex) else { return nil }
        host.install(makeFileRow(renderedFiles[fileIndex], tableRow: tableRow))
        return host
    }

    private func makeFileRow(_ file: GitFileDiff, tableRow: Int) -> GitReviewFileRow {
        instantiatedFileRowCount += 1
        let expanded = expansionOverrides[file.path]
            ?? bulkExpansionOverride
            ?? defaultFileExpansion[file.path]
            ?? false

        // The row's "Open in" needs an absolute path, and a diff carries only a path
        // relative to the checkout — which is the pane's fact, not the row's.
        let row = GitReviewFileRow(
            file: file,
            expanded: expanded,
            staging: staging,
            wraps: wrapsDiffLines,
            initialDiffWidth: {
                // `reloadData()` asks for the first views before this table becomes the scroll
                // view's document, so its own frame is still zero. A controller can also receive
                // its final frame before its unattached clip adopts it. The scroll view spans the
                // root edge-to-edge, so whichever has resolved first is the eventual width.
                let paneWidth = max(scrollView.contentView.bounds.width, view.bounds.width)
                let width = paneWidth - Design.Spacing.inset * 2
                return width > 1 ? width : nil
            }(),
            fileURL: renderedFileRoot?.appendingPathComponent(file.path)
        )
        row.onToggle = { [weak self] expanded in
            self?.expansionOverrides[file.path] = expanded
        }
        row.onWillToggle = { [weak self] expanded in
            guard let self else { return }
            self.expansionOverrides[file.path] = expanded
            self.measuredFileRowHeights[file.path] = nil
            guard tableRow < self.fileTableView.numberOfRows else { return }
            self.fileTableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integer: tableRow)
            )
        }
        row.onHeightChange = { [weak self, weak row] in
            self?.recordFileHeight(file, row: row, tableRow: tableRow)
        }
        row.onStageFile = { [weak self] in self?.stageFile(file) }
        row.onStageHunk = { [weak self] index in self?.stageHunk(at: index, of: file) }
        if let conversation = AgentRuntime.shared.conversation(for: sessionID) {
            row.onAddContextAttachment = { [weak conversation] attachment in
                conversation?.stageContextAttachment(attachment)
            }
            row.onRequestContextComment = { [weak conversation] attachment in
                conversation?.requestComment(on: attachment)
            }
        }
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
        scheduleFileHeightMeasurement(file, row: row, tableRow: tableRow)
        return row
    }

    private func scheduleFileHeightMeasurement(
        _ file: GitFileDiff,
        row: GitReviewFileRow?,
        tableRow: Int
    ) {
        DispatchQueue.main.async { [weak self, weak row] in
            self?.recordFileHeight(file, row: row, tableRow: tableRow)
        }
    }

    private func recordFileHeight(
        _ file: GitFileDiff,
        row: GitReviewFileRow?,
        tableRow: Int
    ) {
        guard let row,
              tableRow < fileTableView.numberOfRows,
              fileTableView.row(for: row) == tableRow,
              tableRow >= filePreludeViews.count,
              renderedFiles[tableRow - filePreludeViews.count].path == file.path else {
            return
        }
        let measured = (
            width: row.bounds.width,
            height: row.fittingSize.height + Design.Spacing.small
        )
        if let old = measuredFileRowHeights[file.path],
           abs(old.width - measured.width) <= 0.5,
           abs(old.height - measured.height) <= 0.5 {
            return
        }
        measuredFileRowHeights[file.path] = measured
        fileTableView.noteHeightOfRows(
            withIndexesChanged: IndexSet(integer: tableRow)
        )
        updateScrollControls()
    }

    private func schedulePreludeHeightMeasurement(
        _ content: NSView,
        host: GitReviewVirtualRowHost,
        tableRow: Int
    ) {
        DispatchQueue.main.async { [weak self, weak content, weak host] in
            guard let self, let content, let host,
                  self.filePreludeViews.indices.contains(tableRow),
                  self.filePreludeViews[tableRow] === content,
                  self.fileTableView.row(for: host) == tableRow else { return }
            host.layoutSubtreeIfNeeded()
            let measured = (
                width: content.bounds.width,
                height: host.fittingSize.height
            )
            self.measuredPreludeRowHeights[tableRow] = measured
            self.fileTableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integer: tableRow)
            )
        }
    }
}

/// A reusable table shell. The expensive diff row is replaced whenever the table reassigns
/// this host, so offscreen file views and their constraints are released.
private final class GitReviewVirtualRowHost: NSView {

    func install(_ content: NSView) {
        subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // The pane's one row inset, the same measure the header's chip starts on and the stack
        // path gives its rows — the table adds none of its own, being `.plain` with no intercell
        // spacing. The gap between cards hangs below each of them rather than around all of
        // them, so the first card starts on the margin and not half a gap under it.
        let inset = Design.Spacing.inset
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            content.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Design.Spacing.small
            )
        ])
    }
}
