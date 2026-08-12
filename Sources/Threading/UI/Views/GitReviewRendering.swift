import AppKit

// MARK: - Rendering

private struct GitReviewFileScrollAnchor {
    let path: String
    let offsetWithinRow: CGFloat
}

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

        // A local re-render (word wrap or an inline notice) must not turn already hydrated rows
        // back into pending placeholders. `resetRenderedFiles` below clears these sets as part of
        // detaching the table, so carry the generation-owned state across that lifecycle step.
        let carriedPendingPaths = progressiveDiffGeneration == generation
            ? pendingDiffIndexPaths
            : nil
        let carriedFailedPaths = progressiveDiffGeneration == generation
            ? failedDiffHydrationPaths
            : nil

        // Filesystem results can arrive while AppKit is carrying trackpad momentum. Mutating
        // the table at that point interrupts the live-scroll transaction and feels like the
        // diff grabbed the wheel. Coalesce to the newest result and reconcile once momentum
        // ends; an explicit mode change is a different surface and still happens immediately.
        if isFileLiveScrolling,
           renderedMode == mode,
           renderedTurnID == selectedTurnID,
           scrollView.documentView === fileTableView,
           case .files = phase {
            deferredPhaseDuringLiveScroll = phase
            return
        }
        deferredPhaseDuringLiveScroll = nil

        let performanceSpan = PerformanceRecorder.shared.begin(
            "git.review.render",
            category: "git.review.ui",
            metadata: Self.performanceMetadata(for: phase)
        )
        defer {
            let isFileSurface = scrollView.documentView === fileTableView
            let isHistorySurface = (scrollView.documentView as? NSTableView)?.isGitReviewHistory
                == true
            performanceSpan.end(metadata: [
                "model_rows": String(
                    isFileSurface
                        ? filePreludeViews.count + renderedFiles.count
                        : isHistorySurface
                            ? historyTableView.numberOfRows
                            : stack.arrangedSubviews.count
                ),
                "instantiated_file_rows": String(instantiatedFileRowCount),
                "instantiated_commit_rows": String(instantiatedCommitRowCount)
            ])
        }

        // A watched checkout redraws itself under the reader. Keeping the offset across a
        // reload of the *same* surface is what makes that tolerable; a mode switch or a commit
        // opening is a different page and starts at the top.
        let previousPhase = self.phase
        let keepsPlace = renderedMode == mode
            && renderedTurnID == selectedTurnID
            && Self.isSameSurface(previousPhase, phase)
        let offset = scrollView.documentVisibleRect.origin
        let fileAnchor = keepsPlace ? currentFileScrollAnchor() : nil
        let composerWasFocused = isFocused(commitComposer)

        self.phase = phase
        renderedMode = mode
        renderedTurnID = selectedTurnID
        if !keepsPlace {
            bulkExpansionOverride = nil
        }

        let pendingNotice = notice
        notice = nil

        // A watched working tree can refresh every couple of seconds while a build is writing
        // files. Replacing the document view here used to destroy and reconstruct every visible
        // TextKit diff even when only one of thousands of models changed; the real 8,984-file
        // trace measured 45–295 ms on main for each refresh. Keep the table and its unchanged
        // viewport rows alive, and mutate only the stable file identities that differ.
        if keepsPlace,
           pendingNotice == nil,
           mode != .staged,
           scrollView.documentView === fileTableView,
           case .files(let files) = phase,
           Self.isFileSurface(previousPhase) {
            pendingDiffIndexPaths.removeAll()
            renderCounter(files)
            refreshFilesInPlace(files)
            restoreScroll(to: fileAnchor, fallbackY: offset.y)
            DispatchQueue.main.async { [weak self] in self?.updateScrollControls() }
            return
        }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Detach a table before emptying its render model. Reloading the current document view
        // asks for replacement viewport rows immediately, which would construct the old surface
        // once more only to remove it on the following line.
        scrollView.documentView = stack
        resetRenderedFiles()
        resetRenderedCommits()
        placeholderLabel.isHidden = true
        setBackVisible(false)
        counterLabel.isHidden = true
        // Everything under the arrow is being replaced, so there is nothing for it to travel
        // out of: it goes with the content it belonged to.
        jumpToEndButton.setFloatingPresence(false, animated: false)

        switch phase {
        case .message(let text):
            if let pendingNotice {
                addRow(makeNotice(pendingNotice.text, isError: pendingNotice.isError))
            }
            placeholderLabel.stringValue = text
            placeholderLabel.isHidden = false

        case .fileIndex(let files):
            pendingDiffIndexPaths = carriedPendingPaths ?? Set(files.map(\.path))
            failedDiffHydrationPaths = carriedFailedPaths ?? []
            renderFileIndexCounter(files.count)
            var prelude: [NSView] = []
            if let pendingNotice {
                prelude.append(makeNotice(pendingNotice.text, isError: pendingNotice.isError))
            }
            renderFiles(files, prelude: prelude)

        case .files(let files):
            pendingDiffIndexPaths.removeAll()
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
            let prelude = pendingNotice.map {
                [makeNotice($0.text, isError: $0.isError)]
            } ?? []
            renderCommits(canLoadMore: canLoadMore, prelude: prelude)

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

        if keepsPlace {
            restoreScroll(to: fileAnchor, fallbackY: offset.y)
        } else {
            restoreScroll(to: 0)
        }
        DispatchQueue.main.async { [weak self] in
            self?.updateScrollControls()
        }
    }

    /// Two phases showing the same kind of page — the test for whether a scroll offset taken
    /// before a re-render still means anything after it.
    static func isSameSurface(_ lhs: Phase, _ rhs: Phase) -> Bool {
        switch (lhs, rhs) {
        case (.message, .message),
             (.fileIndex, .fileIndex),
             (.fileIndex, .files),
             (.files, .fileIndex),
             (.files, .files),
             (.commits, .commits),
             (.commitDetail, .commitDetail):
            return true
        default:
            return false
        }
    }

    private static func isFileSurface(_ phase: Phase) -> Bool {
        switch phase {
        case .fileIndex, .files: true
        case .message, .commits, .commitDetail: false
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

    /// A pixel offset is only stable while every row above it remains the same. Watched build
    /// output violates that constantly, so preserve the first visible file and the reader's
    /// position within it; fall back to the old offset only if that file disappeared.
    private func restoreScroll(to anchor: GitReviewFileScrollAnchor?, fallbackY: CGFloat) {
        guard let anchor,
              let fileIndex = renderedFiles.firstIndex(where: { $0.path == anchor.path }) else {
            restoreScroll(to: fallbackY)
            return
        }
        view.layoutSubtreeIfNeeded()
        let row = filePreludeViews.count + fileIndex
        let targetY = fileTableView.rect(ofRow: row).minY + anchor.offsetWithinRow
        scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: min(max(targetY, 0), maximumScrollOffsetY())
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func currentFileScrollAnchor() -> GitReviewFileScrollAnchor? {
        guard scrollView.documentView === fileTableView else { return nil }
        let visibleY = scrollView.documentVisibleRect.minY
        let row = fileTableView.row(at: NSPoint(x: 1, y: visibleY + 0.5))
        let fileIndex = row - filePreludeViews.count
        guard renderedFiles.indices.contains(fileIndex) else { return nil }
        return GitReviewFileScrollAnchor(
            path: renderedFiles[fileIndex].path,
            offsetWithinRow: visibleY - fileTableView.rect(ofRow: row).minY
        )
    }

    /// Ends the scroll transaction in one place: apply the newest watched model, then replace
    /// cheap estimates only for rows that survived into the resting viewport. Exact TextKit
    /// height notifications are deliberately ignored during momentum so they cannot retile the
    /// table between wheel events.
    func finishFileLiveScrolling() {
        scrollerSeekSettleWork?.cancel()
        scrollerSeekSettleWork = nil
        let wasScrollerSeeking = isFileScrollerSeeking
        isFileLiveScrolling = false
        isFileScrollerSeeking = false
        if let deferredPhaseDuringLiveScroll {
            self.deferredPhaseDuringLiveScroll = nil
            show(deferredPhaseDuringLiveScroll)
        }

        if wasScrollerSeeking {
            rematerializeVisibleFilesAfterScrollerSeek()
        }

        applyDeferredDiffHydration()
        scheduleVisibleDiffHydration()

        guard scrollView.documentView === fileTableView else { return }
        let visible = fileTableView.rows(in: fileTableView.visibleRect)
        guard visible.location != NSNotFound else { return }
        for tableRow in visible.location..<NSMaxRange(visible) {
            let fileIndex = tableRow - filePreludeViews.count
            guard renderedFiles.indices.contains(fileIndex),
                  let host = fileTableView.view(
                    atColumn: 0,
                    row: tableRow,
                    makeIfNecessary: false
                  ) as? GitReviewVirtualRowHost,
                  let row = host.installedContent as? GitReviewFileRow else { continue }
            recordFileHeight(renderedFiles[fileIndex], row: row)
        }
    }

    /// Enters the scroller-thumb path. Wheel and trackpad scrolling keep fully rendered rows;
    /// their ordinary contiguous workload already fits inside a frame, while a knob can jump
    /// across the whole index on every pointer event.
    ///
    /// Every knob action also re-arms the settle clock: people scrub in drag–pause–look
    /// strokes, and the pause is where they are reading. A viewport that stays a ghost until
    /// mouse-up answers the pause with nothing.
    func beginFileScrollerSeek() {
        isFileLiveScrolling = true
        isFileScrollerSeeking = true

        scrollerSeekSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settleFileScrollerSeek() }
        scrollerSeekSettleWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + GitReviewDefaults.scrollerSeekSettleDelay,
            execute: work
        )
    }

    /// The thumb has paused without being released: materialize the visible rows for real, at
    /// the exact clip origin, while the drag transaction stays open.
    ///
    /// This is deliberately less than `finishFileLiveScrolling`. Height discovery and any
    /// deferred watched phase stay coalesced — mutating geometry under a held thumb would move
    /// the document beneath it — and `isFileLiveScrolling` stays true so both keep waiting for
    /// the release. Only `isFileScrollerSeeking` clears, which is what lets the next knob jump
    /// re-enter the cheap path with `beginFileScrollerSeek` re-arming this clock.
    func settleFileScrollerSeek() {
        scrollerSeekSettleWork?.cancel()
        scrollerSeekSettleWork = nil
        guard isFileLiveScrolling, isFileScrollerSeeking else { return }
        isFileScrollerSeeking = false
        rematerializeVisibleFilesAfterScrollerSeek()
    }

    private func rematerializeVisibleFilesAfterScrollerSeek() {
        guard scrollView.documentView === fileTableView else { return }
        let visible = fileTableView.rows(in: fileTableView.visibleRect)
        guard visible.location != NSNotFound else { return }
        let rows = IndexSet(integersIn: visible.location..<min(
            NSMaxRange(visible),
            fileTableView.numberOfRows
        ))
        guard !rows.isEmpty else { return }
        let origin = scrollView.contentView.bounds.origin
        fileTableView.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integer: 0)
        )
        scrollView.contentView.scroll(to: origin)
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
        renderCounter(files: files.count, added: added, removed: removed)
    }

    private func renderCounter(files: Int, added: Int, removed: Int) {
        let compactAdded = added.formatted(.number.notation(.compactName))
        let compactRemoved = removed.formatted(.number.notation(.compactName))
        let exactAdded = added.formatted(.number.grouping(.automatic))
        let exactRemoved = removed.formatted(.number.grouping(.automatic))

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "+\(compactAdded)", attributes: [
            .foregroundColor: Design.Diff.added,
            .font: Design.Typography.caption()
        ]))
        text.append(NSAttributedString(string: " −\(compactRemoved)", attributes: [
            .foregroundColor: Design.Diff.removed,
            .font: Design.Typography.caption()
        ]))
        // The plain value first, so the field re-measures; the attributed one then recolours
        // what was measured. Assigning only the attributed value leaves the old width.
        counterLabel.stringValue = text.string
        counterLabel.attributedStringValue = text
        counterLabel.toolTip = "+\(exactAdded) −\(exactRemoved)"
        counterLabel.setAccessibilityLabel(
            L10n.format(
                "%lld changed files, %lld additions, %lld deletions",
                Int64(files),
                Int64(added),
                Int64(removed)
            )
        )
        counterLabel.isHidden = false
    }

    func renderFileIndexCounter(_ count: Int, isLoading: Bool = true) {
        let text = L10n.format("%lld files", Int64(count))
            + (isLoading ? " · " + L10n.string("Loading…") : "")
        counterLabel.stringValue = text
        counterLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .foregroundColor: Design.Text.tertiary,
            .font: Design.Typography.caption()
        ])
        counterLabel.toolTip = text
        counterLabel.setAccessibilityLabel(text)
        counterLabel.isHidden = false
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

        // Once for the whole diff: `repositoryRoot` walks the tree looking for `.git`, and a
        // branch comparison can list hundreds of files.
        renderedFileRoot = loadedDiffRoot ?? repositoryRoot

        // `reloadData()` immediately asks for the first row views. Make the clip adopt the
        // pane's current frame first, otherwise those expanded rows still see the 240pt
        // bootstrap width left from `loadView` and AppKit caches that much taller answer.
        view.layoutSubtreeIfNeeded()
        fileRowHeightWidth = max(view.bounds.width - Design.Spacing.inset * 2, 0)
        fileTableView.reloadData()
        scrollView.documentView = fileTableView
    }

    /// Reconciles a watched `.files` refresh or progressive index enrichment without replacing
    /// the table or unchanged visible rows. Git's order is stable for common paths; insertions
    /// and removals shift those identities in one AppKit update, while content changes reload
    /// only their rows.
    private func refreshFilesInPlace(_ files: [GitFileDiff]) {
        let span = PerformanceRecorder.shared.begin(
            "git.review.refresh-files",
            category: "git.review.ui",
            metadata: ["old_files": String(renderedFiles.count), "files": String(files.count)]
        )
        let oldFiles = renderedFiles
        let oldIndexByPath = Dictionary(
            oldFiles.indices.map { (oldFiles[$0].path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let newIndexByPath = Dictionary(
            files.indices.map { (files[$0].path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let removed = IndexSet(oldFiles.indices.filter {
            newIndexByPath[oldFiles[$0].path] == nil
        })
        let inserted = IndexSet(files.indices.filter {
            oldIndexByPath[files[$0].path] == nil
        })

        var lastCommonNewIndex = -1
        var keepsCommonOrder = true
        for file in oldFiles {
            guard let newIndex = newIndexByPath[file.path] else { continue }
            if newIndex <= lastCommonNewIndex {
                keepsCommonOrder = false
                break
            }
            lastCommonNewIndex = newIndex
        }

        // Replacing the value model is enough for every offscreen path: its eventual row asks
        // `renderedFiles` for the new value. Deep-comparing all hunk text merely to discover
        // which nonexistent views to reload cost 47 ms for the 9k-file/80k-line fixture. Only
        // rows AppKit currently owns and paths with an exact cached height need comparison.
        var comparisonPaths = Set(measuredFileRowHeights.keys)
        fileTableView.enumerateAvailableRowViews { _, tableRow in
            let fileIndex = tableRow - filePreludeViews.count
            guard oldFiles.indices.contains(fileIndex) else { return }
            comparisonPaths.insert(oldFiles[fileIndex].path)
        }
        var changedPaths = Set<String>()
        for path in comparisonPaths {
            guard let oldIndex = oldIndexByPath[path],
                  let newIndex = newIndexByPath[path],
                  oldFiles[oldIndex] != files[newIndex] else { continue }
            changedPaths.insert(path)
        }
        let changedRows = IndexSet(changedPaths.compactMap { newIndexByPath[$0] })

        for index in removed {
            measuredFileRowHeights[oldFiles[index].path] = nil
        }
        for path in changedPaths {
            measuredFileRowHeights[path] = nil
        }

        if keepsCommonOrder {
            fileTableView.beginUpdates()
            renderedFiles = files
            if !removed.isEmpty {
                fileTableView.removeRows(
                    at: removed.offset(by: filePreludeViews.count),
                    withAnimation: []
                )
            }
            if !inserted.isEmpty {
                fileTableView.insertRows(
                    at: inserted.offset(by: filePreludeViews.count),
                    withAnimation: []
                )
            }
            fileTableView.endUpdates()
            if !changedRows.isEmpty {
                fileTableView.reloadData(
                    forRowIndexes: changedRows.offset(by: filePreludeViews.count),
                    columnIndexes: IndexSet(integer: 0)
                )
            }
        } else {
            // Renames and git mode changes can genuinely reorder common paths. They are rare and
            // correctness wins; the path anchor still restores the reader after this fallback.
            renderedFiles = files
            fileTableView.reloadData()
        }

        span.end(metadata: [
            "inserted": String(inserted.count),
            "removed": String(removed.count),
            "compared": String(comparisonPaths.count),
            "changed": String(changedPaths.count),
            "reordered": String(!keepsCommonOrder)
        ])
    }

    private func resetRenderedFiles() {
        renderedFiles = []
        pendingDiffIndexPaths.removeAll()
        failedDiffHydrationPaths.removeAll()
        deferredHydratedFiles.removeAll()
        deferredFailedHydrationPaths.removeAll()
        deferredProgressiveStats = nil
        filePreludeViews = []
        measuredFileRowHeights = [:]
        measuredPreludeRowHeights = [:]
        fileRowHeightWidth = 0
        renderedFileRoot = nil
        instantiatedFileRowCount = 0
        instantiatedDeferredFileRowCount = 0
        fileTableView.reloadData()
    }

    // MARK: - Progressive File Hydration

    /// Promotes a large path roster to the authoritative surface. The complete-patch command is
    /// cancelled as soon as the roster proves it crossed the product threshold; exact totals and
    /// exact visible bodies then travel on bounded reads of their own.
    func beginProgressiveDiffHydration(
        comparison: GitReviewReader.ProgressiveDiff,
        root: URL,
        generation expected: Int
    ) {
        guard expected == generation else { return }
        let files = comparison.files
        progressiveDiffGeneration = expected
        progressiveDiff = comparison
        progressiveDiffRoot = root
        progressiveHydrationInFlight = false
        progressiveHydrationSchedule += 1
        progressiveStatsStarted = false
        progressiveStatsScheduled = false
        progressiveStatsCancellation?.cancel()
        progressiveStatsCancellation = nil
        pendingDiffIndexPaths = Set(files.map(\.path))
        failedDiffHydrationPaths.removeAll()
        deferredHydratedFiles.removeAll()
        deferredFailedHydrationPaths.removeAll()
        loadedDiffRoot = root
        show(.fileIndex(files))

        // From here the full unified patch has no consumer. Stopping it is the performance gain,
        // not merely drawing placeholders in front of the same total work.
        activeDiffCancellation?.cancel()
        isLoading = false

        scheduleVisibleDiffHydration()
        reloadIfPending()
    }

    func stopProgressiveDiffHydration() {
        progressiveDiffGeneration = -1
        progressiveDiff = nil
        progressiveDiffRoot = nil
        progressiveHydrationInFlight = false
        progressiveHydrationSchedule += 1
        progressiveStatsStarted = false
        progressiveStatsScheduled = false
        progressiveStatsCancellation?.cancel()
        progressiveStatsCancellation = nil
        pendingDiffIndexPaths.removeAll()
        failedDiffHydrationPaths.removeAll()
        deferredHydratedFiles.removeAll()
        deferredFailedHydrationPaths.removeAll()
        deferredProgressiveStats = nil
    }

    /// Coalesces bounds events. A wheel gesture can move the viewport dozens of times before one
    /// child process answers; only the resting set is worth hydrating.
    func scheduleVisibleDiffHydration(after delay: TimeInterval = 0) {
        guard progressiveDiffGeneration == generation else { return }
        // A new viewport invalidates an optional totals start immediately. The resting hydration
        // below will arrange a fresh settle window if it finds no pending visible rows.
        progressiveStatsScheduled = false
        progressiveHydrationSchedule += 1
        let expectedSchedule = progressiveHydrationSchedule
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  expectedSchedule == self.progressiveHydrationSchedule else { return }
            self.hydrateVisibleDiffFiles()
        }
    }

    private func hydrateVisibleDiffFiles() {
        guard progressiveDiffGeneration == generation,
              !progressiveHydrationInFlight,
              !isFileLiveScrolling,
              scrollView.documentView === fileTableView,
              let comparison = progressiveDiff,
              let root = progressiveDiffRoot else { return }

        let visible = fileTableView.rows(in: fileTableView.visibleRect)
        guard visible.location != NSNotFound else { return }
        let first = max(visible.location - filePreludeViews.count, 0)
        let last = min(NSMaxRange(visible) - filePreludeViews.count, renderedFiles.count)
        guard first < last else { return }
        let batch = renderedFiles[first..<last]
            .filter { pendingDiffIndexPaths.contains($0.path) }
            .prefix(GitReviewDefaults.progressiveDiffHydrationBatch)
        guard !batch.isEmpty else {
            startProgressiveDiffStatsIfNeeded()
            return
        }

        let expectedGeneration = generation
        let requested = Array(batch)
        progressiveHydrationInFlight = true
        GitReviewReader.diffFiles(
            requested,
            using: comparison,
            in: root,
            ignoringWhitespace: ignoresWhitespace
        ) { [weak self] result in
            guard let self else { return }
            self.progressiveHydrationInFlight = false
            guard self.progressiveDiffGeneration == expectedGeneration else { return }

            let hydrated: [GitFileDiff]
            let failed: Set<String>
            switch result {
            case .success(let files):
                hydrated = files
                let returned = Set(files.map(\.path))
                failed = Set(requested.map(\.path)).subtracting(returned)
            case .failure:
                hydrated = []
                failed = Set(requested.map(\.path))
            }

            if self.isFileLiveScrolling {
                for file in hydrated { self.deferredHydratedFiles[file.path] = file }
                self.deferredFailedHydrationPaths.formUnion(failed)
            } else {
                self.applyDiffHydration(hydrated, failedPaths: failed)
            }
            self.scheduleVisibleDiffHydration()
        }
    }

    /// Exact totals touch every changed blob. Keep that work behind the first complete resting
    /// viewport and a second, longer settle window: someone who keeps reading should spend the
    /// machine on visible files, not an optional header. Bounds changes invalidate this scheduled
    /// start; the next resting viewport schedules a fresh one.
    private func startProgressiveDiffStatsIfNeeded() {
        guard !progressiveStatsStarted,
              !progressiveStatsScheduled,
              progressiveDiffGeneration == generation,
              progressiveDiff != nil,
              progressiveDiffRoot != nil else { return }
        progressiveStatsScheduled = true
        let expectedGeneration = generation
        let expectedHydrationSchedule = progressiveHydrationSchedule
        DispatchQueue.main.asyncAfter(
            deadline: .now() + GitReviewDefaults.progressiveDiffStatsSettleDelay
        ) { [weak self] in
            guard let self,
                  self.progressiveDiffGeneration == expectedGeneration,
                  self.progressiveHydrationSchedule == expectedHydrationSchedule,
                  !self.progressiveStatsStarted,
                  !self.isFileLiveScrolling,
                  let comparison = self.progressiveDiff,
                  let root = self.progressiveDiffRoot else { return }
            self.progressiveStatsScheduled = false
            self.progressiveStatsStarted = true
            self.progressiveStatsCancellation = GitReviewReader.diffStats(
                comparison,
                in: root,
                ignoringWhitespace: self.ignoresWhitespace
            ) { [weak self] result in
                guard let self, self.progressiveDiffGeneration == expectedGeneration else { return }
                self.progressiveStatsCancellation = nil
                if case .success(let stats) = result {
                    if self.isFileLiveScrolling {
                        self.deferredProgressiveStats = stats
                    } else {
                        self.applyProgressiveDiffStats(stats)
                    }
                }
            }
        }
    }

    func applyDeferredDiffHydration() {
        if let stats = deferredProgressiveStats {
            deferredProgressiveStats = nil
            applyProgressiveDiffStats(stats)
        }
        guard !deferredHydratedFiles.isEmpty || !deferredFailedHydrationPaths.isEmpty else {
            return
        }
        let files = Array(deferredHydratedFiles.values)
        let failed = deferredFailedHydrationPaths
        deferredHydratedFiles.removeAll()
        deferredFailedHydrationPaths.removeAll()
        applyDiffHydration(files, failedPaths: failed)
    }

    /// Replaces only returned path identities and preserves the reader's semantic position. It
    /// deliberately avoids `show`/`refreshFilesInPlace`: one viewport batch never changes order
    /// or row count. A raw pixel origin is not stable here because exact TextKit measurement can
    /// make the hydrated row taller than its numstat estimate.
    private func applyDiffHydration(_ files: [GitFileDiff], failedPaths: Set<String>) {
        guard case .fileIndex = phase else { return }
        let indexByPath = Dictionary(
            renderedFiles.indices.map { (renderedFiles[$0].path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows = IndexSet()
        for file in files {
            guard let index = indexByPath[file.path] else { continue }
            renderedFiles[index] = file
            pendingDiffIndexPaths.remove(file.path)
            failedDiffHydrationPaths.remove(file.path)
            measuredFileRowHeights[file.path] = nil
            rows.insert(filePreludeViews.count + index)
        }
        for path in failedPaths {
            guard let index = indexByPath[path] else { continue }
            pendingDiffIndexPaths.remove(path)
            failedDiffHydrationPaths.insert(path)
            measuredFileRowHeights[path] = nil
            rows.insert(filePreludeViews.count + index)
        }
        guard !rows.isEmpty else { return }

        let fallbackY = scrollView.contentView.bounds.origin.y
        let anchor = currentFileScrollAnchor()
        let wasAtEnd = maximumScrollOffsetY() - fallbackY <= 4
        fileTableView.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integer: 0)
        )
        if wasAtEnd {
            restoreScroll(to: maximumScrollOffsetY())
        } else {
            restoreScroll(to: anchor, fallbackY: fallbackY)
        }
        updateScrollControls()
    }

    /// Numstat is still far smaller than a patch, yet gives every pending row its exact line
    /// weight. Updating the value roster once makes the scrollbar approximate the final document
    /// rather than growing only as the reader discovers rows.
    private func applyProgressiveDiffStats(_ stats: [GitFileLineStats]) {
        guard case .fileIndex = phase else { return }
        let byPath = Dictionary(
            stats.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var changed = IndexSet()
        var added = 0
        var removed = 0
        let fallbackY = scrollView.contentView.bounds.origin.y
        let anchor = currentFileScrollAnchor()
        let wasAtEnd = maximumScrollOffsetY() - fallbackY <= 4
        for index in renderedFiles.indices {
            guard pendingDiffIndexPaths.contains(renderedFiles[index].path),
                  let value = byPath[renderedFiles[index].path] else {
                added += renderedFiles[index].added
                removed += renderedFiles[index].removed
                continue
            }
            let file = renderedFiles[index]
            renderedFiles[index] = GitFileDiff(
                path: file.path,
                change: file.change,
                hunks: [],
                added: value.added,
                removed: value.removed
            )
            added += value.added
            removed += value.removed
            measuredFileRowHeights[file.path] = nil
            changed.insert(filePreludeViews.count + index)
        }
        renderCounter(files: renderedFiles.count, added: added, removed: removed)
        guard !changed.isEmpty else { return }
        fileTableView.noteHeightOfRows(withIndexesChanged: changed)
        let visible = fileTableView.rows(in: fileTableView.visibleRect)
        if visible.location != NSNotFound {
            let visibleRows = IndexSet(integersIn: visible.location..<NSMaxRange(visible))
            let visibleChanged = changed.intersection(visibleRows)
            if !visibleChanged.isEmpty {
                fileTableView.reloadData(
                    forRowIndexes: visibleChanged,
                    columnIndexes: IndexSet(integer: 0)
                )
            }
        }
        if wasAtEnd {
            restoreScroll(to: maximumScrollOffsetY())
        } else {
            restoreScroll(to: anchor, fallbackY: fallbackY)
        }
        updateScrollControls()
    }

    private static func performanceMetadata(for phase: Phase) -> [String: String] {
        switch phase {
        case .message:
            return ["phase": "message"]
        case .fileIndex(let files):
            return ["phase": "file-index", "files": String(files.count)]
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

    func renderCommits(canLoadMore: Bool, prelude: [NSView] = []) {
        // The graph is laid out over the whole page at once — a lane exists because some other
        // commit is waiting for it, which is not knowable one row at a time. That computation
        // retains only small value rows; the table constructs the graph/text views on demand.
        renderedCommitGraph = GitCommitGraph.rows(for: commits)
        historyPreludeViews = prelude
        measuredHistoryPreludeRowHeights = [:]
        renderedCommitLaneCount = GitCommitGraph.laneCount(of: renderedCommitGraph)
        historyCanLoadMore = canLoadMore
        instantiatedCommitRowCount = 0

        view.layoutSubtreeIfNeeded()
        historyTableView.reloadData()
        scrollView.documentView = historyTableView
    }

    /// Replaces metadata-only values by hash and reloads just the visible/reusable cells whose
    /// counts changed. Parent/ref geometry is identical, so rebuilding the graph would be work
    /// proportional to the retained history for no visible benefit.
    @discardableResult
    func applyCommitStats(_ page: [GitCommitSummary]) -> Int {
        let enriched = Dictionary(uniqueKeysWithValues: page.map { ($0.hash, $0) })
        var rows = IndexSet()
        for index in commits.indices {
            guard !commits[index].hasStats,
                  let replacement = enriched[commits[index].hash] else { continue }
            commits[index] = replacement
            rows.insert(historyPreludeViews.count + index)
        }

        guard !rows.isEmpty,
              case .commits = phase,
              scrollView.documentView === historyTableView else { return rows.count }
        historyTableView.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integer: 0)
        )
        return rows.count
    }

    private func resetRenderedCommits() {
        guard !renderedCommitGraph.isEmpty
                || !historyPreludeViews.isEmpty
                || historyCanLoadMore else { return }
        renderedCommitGraph = []
        historyPreludeViews = []
        measuredHistoryPreludeRowHeights = [:]
        renderedCommitLaneCount = 1
        historyCanLoadMore = false
        instantiatedCommitRowCount = 0
        historyTableView.reloadData()
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

// MARK: - Virtual Review Tables

extension GitReviewViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView.isGitReviewHistory {
            return historyPreludeViews.count
                + renderedCommitGraph.count
                + (historyCanLoadMore ? 1 : 0)
        }
        return filePreludeViews.count + renderedFiles.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, heightOfRow tableRow: Int) -> CGFloat {
        if tableView.isGitReviewHistory {
            if historyPreludeViews.indices.contains(tableRow) {
                return measuredHistoryPreludeRowHeights[tableRow]
                    ?? max(
                        GitReviewCommitRowDefaults.tableRowHeight,
                        historyPreludeViews[tableRow].fittingSize.height + Design.Spacing.small
                    )
            }
            return GitReviewCommitRowDefaults.tableRowHeight
        }

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
                ?? (pendingDiffIndexPaths.contains(file.path)
                    ? true
                    : GitReviewFileRow.expandsByDefault(file))
            if pendingDiffIndexPaths.contains(file.path) {
                return GitReviewFileRow.estimatedPendingTableHeight(
                    for: file,
                    expanded: expanded
                )
            }
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
                ?? (pendingDiffIndexPaths.contains(file.path)
                    ? true
                    : GitReviewFileRow.expandsByDefault(file))
            if pendingDiffIndexPaths.contains(file.path) {
                return GitReviewFileRow.estimatedPendingTableHeight(
                    for: file,
                    expanded: expanded
                )
            }
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

        if tableView.isGitReviewHistory {
            return makeHistoryTableRow(tableRow, in: tableView)
        }

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
        host.install(makeFileRow(renderedFiles[fileIndex]))
        return host
    }

    private func makeHistoryTableRow(_ tableRow: Int, in tableView: NSTableView) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("GitReviewVirtualCommitRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? GitReviewVirtualRowHost ?? GitReviewVirtualRowHost()
        host.identifier = identifier

        if historyPreludeViews.indices.contains(tableRow) {
            let content = historyPreludeViews[tableRow]
            host.install(content)
            scheduleHistoryPreludeHeightMeasurement(content, host: host, tableRow: tableRow)
            return host
        }

        let commitIndex = tableRow - historyPreludeViews.count
        if renderedCommitGraph.indices.contains(commitIndex), commits.indices.contains(commitIndex) {
            let commit = commits[commitIndex]
            let row = GitReviewCommitRow(
                commit: commit,
                graph: renderedCommitGraph.indices.contains(commitIndex)
                    ? renderedCommitGraph[commitIndex]
                    : nil,
                laneCount: renderedCommitLaneCount
            )
            row.onOpen = { [weak self] in self?.openCommit(commit) }
            instantiatedCommitRowCount += 1
            host.install(row, bottomSpacing: 0)
            return host
        }

        guard historyCanLoadMore, commitIndex == renderedCommitGraph.count else { return nil }
        let more = ThemedButton(
            title: L10n.string("Show more…"),
            target: self,
            action: #selector(loadMoreCommits)
        )
        more.isBordered = false
        more.applyFont(.caption)
        more.contentTintColor = Design.Text.secondary
        host.install(more, bottomSpacing: 0)
        return host
    }

    private func scheduleHistoryPreludeHeightMeasurement(
        _ content: NSView,
        host: GitReviewVirtualRowHost,
        tableRow: Int
    ) {
        DispatchQueue.main.async { [weak self, weak content, weak host] in
            guard let self, let content, let host,
                  self.historyPreludeViews.indices.contains(tableRow),
                  self.historyPreludeViews[tableRow] === content,
                  self.historyTableView.row(for: host) == tableRow else { return }
            host.layoutSubtreeIfNeeded()
            let height = max(GitReviewCommitRowDefaults.tableRowHeight, host.fittingSize.height)
            guard abs((self.measuredHistoryPreludeRowHeights[tableRow] ?? 0) - height) > 0.5 else {
                return
            }
            self.measuredHistoryPreludeRowHeights[tableRow] = height
            self.historyTableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integer: tableRow)
            )
        }
    }

    private func makeFileRow(_ file: GitFileDiff) -> GitReviewFileRow {
        instantiatedFileRowCount += 1
        let contentIsPending = pendingDiffIndexPaths.contains(file.path)
        let contentLoadFailed = failedDiffHydrationPaths.contains(file.path)
        // The pending default mirrors `heightOfRow`'s: a pending file presents expanded, so
        // the ghost body occupies the numstat height the table already gave it. The two
        // deciding differently is how a giant empty card happens.
        let expanded = expansionOverrides[file.path]
            ?? bulkExpansionOverride
            ?? (contentIsPending ? true : GitReviewFileRow.expandsByDefault(file))
        let defersExpandedBody = isFileScrollerSeeking && expanded
        if defersExpandedBody {
            instantiatedDeferredFileRowCount += 1
        }

        // The row's "Open in" needs an absolute path, and a diff carries only a path
        // relative to the checkout — which is the pane's fact, not the row's.
        let row = GitReviewFileRow(
            file: file,
            expanded: expanded,
            defersExpandedBody: defersExpandedBody,
            contentIsPending: contentIsPending,
            contentLoadFailed: contentLoadFailed,
            staging: contentIsPending ? nil : staging,
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
        row.onWillToggle = { [weak self, weak row] expanded in
            guard let self, let row else { return }
            self.expansionOverrides[file.path] = expanded
            self.measuredFileRowHeights[file.path] = nil
            let tableRow = self.fileTableView.row(for: row)
            guard tableRow >= 0 else { return }
            guard tableRow < self.fileTableView.numberOfRows else { return }
            self.fileTableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integer: tableRow)
            )
        }
        row.onHeightChange = { [weak self, weak row] in
            self?.recordFileHeight(file, row: row)
        }
        row.onStageFile = { [weak self] in self?.stageFile(file) }
        row.onStageHunk = { [weak self] index in self?.stageHunk(at: index, of: file) }
        // Asked of the handoff rather than of the runtime's conversation cache: Git Review is a
        // pane, and a pane is open beside terminal sessions too. Resolved per row build so a
        // session that launches while the pane is up gains the actions on its next refresh.
        if SessionContextHandoff.canReceiveContext(for: sessionID) {
            let sessionID = sessionID
            row.onAddContextAttachment = { attachment in
                SessionContextHandoff.stage(attachment, for: sessionID)
            }
            row.onRequestContextComment = { attachment, preview in
                ContextCommentAlert.request(
                    on: attachment,
                    preview: preview,
                    for: sessionID
                )
            }
        }
        // The row knows it holds a picture; the pane knows which two endpoints the mode
        // measures between. `currentDiffRequest` already answers for an opened commit too.
        row.imagePairProvider = { [weak self] file, completion in
            guard let self, let root = self.loadedDiffRoot ?? self.repositoryRoot else {
                completion(.failure(.gitFailed("No comparison to read from.")))
                return
            }
            if let comparison = self.progressiveDiff,
               self.progressiveDiffGeneration == self.generation {
                GitReviewReader.endpointFilePair(
                    path: file.path,
                    comparison: comparison,
                    in: root,
                    completion: completion
                )
                return
            }
            guard let request = self.currentDiffRequest else {
                completion(.failure(.gitFailed("No comparison to read from.")))
                return
            }
            GitReviewReader.endpointFilePair(
                path: file.path, request: request, in: root, completion: completion
            )
        }
        scheduleFileHeightMeasurement(file, row: row)
        return row
    }

    private func scheduleFileHeightMeasurement(
        _ file: GitFileDiff,
        row: GitReviewFileRow?
    ) {
        DispatchQueue.main.async { [weak self, weak row] in
            self?.recordFileHeight(file, row: row)
        }
    }

    private func recordFileHeight(
        _ file: GitFileDiff,
        row: GitReviewFileRow?
    ) {
        guard !isFileLiveScrolling else { return }
        guard let row, !row.hasEstimatedGhostBody else { return }
        let tableRow = fileTableView.row(for: row)
        guard tableRow >= 0,
              tableRow < fileTableView.numberOfRows,
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

    private(set) weak var installedContent: NSView?

    func install(_ content: NSView, bottomSpacing: CGFloat = Design.Spacing.small) {
        subviews.forEach { $0.removeFromSuperview() }
        installedContent = content
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
                constant: -bottomSpacing
            )
        ])
    }
}

private extension IndexSet {
    func offset(by delta: Int) -> IndexSet {
        guard delta != 0 else { return self }
        return IndexSet(map { $0 + delta })
    }
}

private extension NSTableView {
    /// Do not identify the table by reading `historyTableView` from a data-source callback: that
    /// lazy getter sets its data source, which immediately calls back here before initialization
    /// has completed. The already-installed column identity is stable and non-reentrant.
    var isGitReviewHistory: Bool {
        tableColumns.first?.identifier == GitReviewUIDefaults.historyTableColumnIdentifier
    }
}
