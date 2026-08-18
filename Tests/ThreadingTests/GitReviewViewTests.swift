import XCTest
@testable import Threading

/// Builds the review pane's views from parsed fixtures — no git process, just the rendering
/// path that a live diff would take.
@MainActor
final class GitReviewViewTests: XCTestCase {

    private let fixture = """
    diff --git a/Sources/Foo.swift b/Sources/Foo.swift
    index 1111111..2222222 100644
    --- a/Sources/Foo.swift
    +++ b/Sources/Foo.swift
    @@ -1,3 +1,3 @@
     context
    -old line
    +new line
    @@ -10,2 +10,2 @@
    -older
    +newer
    """

    func testNumberedDiffViewBuildsOneRowPerLine() {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let lines = files[0].hunks.flatMap(\.lines)

        let view = DiffView(gitLines: lines, displayCap: 100)
        XCTAssertEqual(view.arrangedSubviews.count, lines.count)

        // Numbered rows carry three labels: number, gutter sign, text.
        XCTAssertEqual(view.arrangedSubviews[0].subviews.count, 3)
    }

    func testNumberedDiffViewTruncatesAtCap() {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let lines = files[0].hunks.flatMap(\.lines)

        let view = DiffView(gitLines: lines, displayCap: 2)
        // Two line rows plus the "… N more lines" note.
        XCTAssertEqual(view.arrangedSubviews.count, 3)
    }

    func testCompactDiffUsesNeutralChangedCodeInk() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let lines = files[0].hunks.flatMap(\.lines)
        let addedIndex = try XCTUnwrap(lines.firstIndex { $0.kind == .added })
        let view = DiffView(gitLines: lines, displayCap: 100)
        let code = try XCTUnwrap(
            view.arrangedSubviews[addedIndex].subviews
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == lines[addedIndex].text }
        )
        let expected = Design.Diff.on(Design.Surface.ground).addedText

        XCTAssertEqual(
            code.textColor?.usingColorSpace(.sRGB),
            expected.usingColorSpace(.sRGB)
        )
    }

    func testDiffLineContextKeepsProjectPathNumberAndExcerpt() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let lines = file.hunks.flatMap(\.lines)
        let view = DiffView(
            gitLines: lines,
            displayCap: 100,
            path: "Sources/Foo.swift"
        )
        let addedIndex = try XCTUnwrap(lines.firstIndex { $0.text == "new line" })

        let reference = try XCTUnwrap(view.contextAttachment(atDisplayedLine: addedIndex))
        XCTAssertEqual(reference.source, .code)
        XCTAssertEqual(reference.title, "Sources/Foo.swift:2")
        XCTAssertEqual(reference.locator, "Sources/Foo.swift")
        XCTAssertEqual(reference.lineStart, 2)
        XCTAssertEqual(reference.lineEnd, 2)
        XCTAssertEqual(reference.excerpt, "new line")
    }

    func testCompactReviewDiffKeepsExactLineContextWithoutPerLineViews() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let lines = file.hunks.flatMap(\.lines)
        let view = GitReviewDiffTextView(
            gitLines: lines,
            displayCap: 100,
            path: "Sources/Foo.swift"
        )
        let addedIndex = try XCTUnwrap(lines.firstIndex { $0.text == "new line" })

        let reference = try XCTUnwrap(view.contextAttachment(atDisplayedLine: addedIndex))
        XCTAssertEqual(reference.title, "Sources/Foo.swift:2")
        XCTAssertEqual(reference.locator, "Sources/Foo.swift")
        XCTAssertEqual(reference.lineStart, 2)
        XCTAssertEqual(reference.excerpt, "new line")
        XCTAssertLessThan(
            view.subviews.count,
            lines.count,
            "the review renderer regressed to an AppKit view per diff line"
        )
    }

    func testReviewDiffUsesNeutralBodyInkAndSemanticGutterInk() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let lines = file.hunks.flatMap(\.lines)
        let view = GitReviewDiffTextView(
            gitLines: lines,
            displayCap: 100,
            path: "Sources/Foo.swift"
        )
        let storage = try XCTUnwrap(view.textStorage)
        let text = storage.string as NSString
        let removed = text.range(of: "old line")
        let added = text.range(of: "new line")
        let colors = view.inkColorsForTesting

        XCTAssertEqual(
            (storage.attribute(.foregroundColor, at: removed.location, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.sRGB),
            colors.removedText.usingColorSpace(.sRGB)
        )
        XCTAssertEqual(
            (storage.attribute(.foregroundColor, at: added.location, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.sRGB),
            colors.addedText.usingColorSpace(.sRGB)
        )
        XCTAssertGreaterThan(colors.removedMarker.oklab.chroma, colors.removedText.oklab.chroma)
        XCTAssertGreaterThan(colors.addedMarker.oklab.chroma, colors.addedText.oklab.chroma)

        let removedIndex = try XCTUnwrap(lines.firstIndex { $0.kind == .removed })
        let addedIndex = try XCTUnwrap(lines.firstIndex { $0.kind == .added })
        XCTAssertEqual(
            view.lineNumberColorForTesting(atDisplayedLine: removedIndex)?.usingColorSpace(.sRGB),
            colors.removedMarker.usingColorSpace(.sRGB)
        )
        XCTAssertEqual(
            view.lineNumberColorForTesting(atDisplayedLine: addedIndex)?.usingColorSpace(.sRGB),
            colors.addedMarker.usingColorSpace(.sRGB)
        )
        view.setFrameSize(NSSize(width: 240, height: view.initialMeasuredSize.height))
        let action = try XCTUnwrap(
            view.lineActionRectForTesting(atDisplayedLine: addedIndex)
        )
        XCTAssertGreaterThanOrEqual(action.minX, 0)
        XCTAssertLessThanOrEqual(action.maxX, GitReviewDefaults.lineNumberWidth)
        let hover = try XCTUnwrap(
            view.lineHoverRectForTesting(atDisplayedLine: addedIndex)
        )
        XCTAssertEqual(hover.minX, view.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(hover.maxX, view.bounds.maxX, accuracy: 0.5)
        XCTAssertTrue(hover.contains(action), "the plus belongs to the whole-row hover cue")
    }

    func testWordDiffsEmphasizeOnlyTheChangedSubstring() throws {
        let view = GitReviewDiffTextView(
            gitLines: [
                GitDiffLine(
                    kind: .removed,
                    text: "let animal = cat",
                    oldNumber: 4,
                    newNumber: nil
                ),
                GitDiffLine(
                    kind: .added,
                    text: "let animal = dog",
                    oldNumber: nil,
                    newNumber: 4
                ),
            ],
            displayCap: 100,
            path: "Sources/Animal.swift",
            showsWordDiffs: true
        )
        let storage = try XCTUnwrap(view.textStorage)
        let text = storage.string as NSString
        let common = text.range(of: "animal")
        let removed = text.range(of: "cat")
        let added = text.range(of: "dog")

        XCTAssertNil(storage.attribute(.backgroundColor, at: common.location, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: removed.location, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: added.location, effectiveRange: nil))
    }

    func testReviewHeaderControlsPersistAndRebuildAtTheNextCodeSize() throws {
        let defaults = PreferenceStore.shared
        let previous = defaults.object(forKey: GitReviewTextSizePreference.key)
        defer {
            if let previous {
                defaults.set(previous, forKey: GitReviewTextSizePreference.key)
            } else {
                defaults.removeObject(forKey: GitReviewTextSizePreference.key)
            }
        }
        defaults.removeObject(forKey: GitReviewTextSizePreference.key)

        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        let initial = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewDiffTextView.self, in: controller.view)
        )
        let initialFont = try XCTUnwrap(
            initial.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )

        XCTAssertEqual(controller.reviewTextSize, .standard)
        XCTAssertTrue(controller.decreaseTextSizeButton.isEnabled)
        XCTAssertTrue(controller.increaseTextSizeButton.isEnabled)
        XCTAssertEqual(
            controller.decreaseTextSizeButton.accessibilityIdentifier(),
            "git-review.text-size.decrease"
        )

        XCTAssertTrue(controller.increaseTextSizeButton.performPrimaryAction())
        controller.applyPendingReviewTextSizeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let enlarged = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewDiffTextView.self, in: controller.view)
        )
        let enlargedFont = try XCTUnwrap(
            enlarged.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(controller.reviewTextSize, .large)
        XCTAssertEqual(GitReviewTextSizePreference.current, .large)
        XCTAssertGreaterThan(enlargedFont.pointSize, initialFont.pointSize)
        XCTAssertFalse(initial === enlarged, "the visible TextKit document was not rebuilt")
    }

    /// A right-click inside a selection speaks about the whole selection — that is how more
    /// than one line is commented on — and the anchor is the span's first and last numbered
    /// lines with every selected line quoted.
    func testSelectionSpanningLinesTargetsTheWholeSpan() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let lines = file.hunks.flatMap(\.lines)
        let view = GitReviewDiffTextView(
            gitLines: lines,
            displayCap: 100,
            path: "Sources/Foo.swift"
        )

        let text = view.string as NSString
        let start = text.range(of: "context").location
        let end = NSMaxRange(text.range(of: "new line"))
        view.setSelectedRange(NSRange(location: start, length: end - start))

        XCTAssertEqual(view.targetSpan(forClickedLine: 1), 0...2)
        let reference = try XCTUnwrap(view.contextAttachment(spanningDisplayedLines: 0...2))
        XCTAssertEqual(reference.title, "Sources/Foo.swift:1-2")
        XCTAssertEqual(reference.lineStart, 1)
        XCTAssertEqual(reference.lineEnd, 2)
        XCTAssertEqual(reference.excerpt, "context\nold line\nnew line")
    }

    func testSelectionPreviewKeepsDiffContextAndHighlightsTheWholeSpan() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let view = GitReviewDiffTextView(
            gitLines: file.hunks.flatMap(\.lines),
            displayCap: 100,
            path: "Sources/Foo.swift"
        )

        let preview = try XCTUnwrap(view.contextPreview(spanningDisplayedLines: 0...2))
        let rows = preview.rows.compactMap { row -> (CodeContextPreview.SourceLine, Bool)? in
            guard case .line(let line, let isTarget) = row else { return nil }
            return (line, isTarget)
        }

        XCTAssertEqual(rows.map { $0.0.text }, [
            "context", "old line", "new line", "older", "newer",
        ])
        XCTAssertEqual(rows.map { $0.0.change }, [
            .context, .removed, .added, .removed, .added,
        ])
        XCTAssertEqual(rows.map { $0.1 }, [true, true, true, false, false])
    }

    /// A right-click outside the selection is about the line under the pointer, exactly as if
    /// nothing were selected — macOS's own convention for contextual clicks.
    func testRightClickOutsideTheSelectionTargetsTheClickedLine() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let lines = file.hunks.flatMap(\.lines)
        let view = GitReviewDiffTextView(
            gitLines: lines,
            displayCap: 100,
            path: "Sources/Foo.swift"
        )

        let text = view.string as NSString
        let selected = text.range(of: "context")
        view.setSelectedRange(selected)

        XCTAssertEqual(view.targetSpan(forClickedLine: 4), 4...4)
    }

    /// The highlight is what says which lines a comment will quote, so it grows a partial
    /// selection to whole line boundaries and lights a bare right-click's single line.
    func testHighlightGrowsToWholeLineBoundaries() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let lines = file.hunks.flatMap(\.lines)
        let view = GitReviewDiffTextView(
            gitLines: lines,
            displayCap: 100,
            path: "Sources/Foo.swift"
        )

        view.highlightLines(0...1)
        let selected = (view.string as NSString).substring(with: view.selectedRange())
        XCTAssertTrue(selected.contains("context"))
        XCTAssertTrue(selected.contains("old line"))
        XCTAssertFalse(selected.contains("new line"))
    }

    /// A click inside the opened diff body must not fold the card: it is a selectable text
    /// surface with its own line actions, and the collapse re-laid the table out from under
    /// the pointer — reported as the whole pane jumping on click. The header keeps the toggle.
    func testClickInsideTheBodyDoesNotToggleTheFileCard() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let row = GitReviewFileRow(file: files[0], expanded: true)

        // Built, never shown — see the fixture-window rule in CLAUDE.md.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let recognizer = try XCTUnwrap(row.gestureRecognizers.first)
        let body = try XCTUnwrap(row.subviews.compactMap { $0 as? NSStackView }.first)
        XCTAssertFalse(body.isHidden)
        XCTAssertGreaterThan(body.frame.height, 1)

        func click(at rowPoint: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: row.convert(rowPoint, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
        }

        let inBody = NSPoint(x: body.frame.midX, y: body.frame.midY)
        XCTAssertFalse(
            row.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: try click(at: inBody)),
            "a click on the diff body must not collapse the card"
        )

        let inHeader = NSPoint(x: row.bounds.midX, y: (body.frame.maxY + row.bounds.maxY) / 2)
        XCTAssertTrue(
            row.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: try click(at: inHeader)),
            "the header row keeps the open/close toggle"
        )
    }

    /// The header's Copy Path / Finder pair answers the pointer on the whole line, and
    /// is hidden rather than merely transparent at rest — `hitTest` reads no alpha, so an
    /// invisible button would swallow the header's own toggle and copy paths nobody asked for.
    func testHeaderHoverRevealsTheFileActionsAndAStaleHoverConcealsThem() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let row = GitReviewFileRow(
            file: files[0],
            expanded: true,
            fileURL: URL(fileURLWithPath: "/tmp/Sources/Foo.swift")
        )

        // Built, never shown — see the fixture-window rule in CLAUDE.md.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let buttons = row.subviews.compactMap { $0 as? ThemedIconButton }
        XCTAssertEqual(buttons.count, 2, "copy path and Finder ride the header")
        XCTAssertTrue(buttons.allSatisfy(\.isHidden), "at rest the actions take no clicks")

        let headerPoint = NSPoint(x: row.bounds.midX, y: row.bounds.maxY - 4)
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: row.convert(headerPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        row.mouseEntered(with: enter)

        let copy = try XCTUnwrap(buttons.first {
            $0.accessibilityIdentifier() == "git-review.file.copy-path"
        })
        XCTAssertFalse(copy.isHidden, "hovering the header line reveals the actions")

        // A fixture window is never key, so the pointer cannot be on this header: the
        // tracking rebuild must sweep a stale reveal away without waiting for an exit event
        // nothing will deliver — the row scrolled or reloaded out from under the pointer.
        row.updateTrackingAreas()
        XCTAssertTrue(buttons.allSatisfy(\.isHidden))
    }

    func testFileHoverActionsDispatchTheExactWorkingCopyURL() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let url = URL(fileURLWithPath: "/tmp/Sources/Foo.swift")
        let row = GitReviewFileRow(file: file, expanded: false, fileURL: url)
        var copied: URL?
        var revealed: URL?
        row.copyPathHandler = { copied = $0 }
        row.revealInFinderHandler = { revealed = $0 }

        let buttons = row.subviews.compactMap { $0 as? ThemedIconButton }
        let copy = try XCTUnwrap(buttons.first {
            $0.accessibilityIdentifier() == "git-review.file.copy-path"
        })
        let reveal = try XCTUnwrap(buttons.first {
            $0.accessibilityIdentifier() == "git-review.file.reveal-in-finder"
        })

        XCTAssertTrue(copy.performPrimaryAction())
        XCTAssertTrue(reveal.performPrimaryAction())
        XCTAssertEqual(copied, url)
        XCTAssertEqual(revealed, url)
    }

    /// A click that lands on a revealed hover action belongs to that control; the row folding
    /// at the same moment would collapse the card out from under the press.
    func testClickOnARevealedHoverActionDoesNotToggleTheFileCard() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let row = GitReviewFileRow(
            file: files[0],
            expanded: false,
            fileURL: URL(fileURLWithPath: "/tmp/Sources/Foo.swift")
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let enter = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        row.mouseEntered(with: enter)
        host.layoutSubtreeIfNeeded()

        let copy = try XCTUnwrap(row.subviews.compactMap { $0 as? ThemedIconButton }.first {
            $0.accessibilityIdentifier() == "git-review.file.copy-path"
        })
        XCTAssertFalse(copy.isHidden)
        XCTAssertGreaterThan(copy.frame.width, 1)

        let recognizer = try XCTUnwrap(row.gestureRecognizers.first)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: row.convert(NSPoint(x: copy.frame.midX, y: copy.frame.midY), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertFalse(
            row.gestureRecognizer(recognizer, shouldAttemptToRecognizeWith: click),
            "the revealed action owns its click"
        )

        var copiedURL: URL?
        row.copyPathHandler = { copiedURL = $0 }
        let release = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: click.locationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))
        copy.mouseDown(with: click)
        copy.mouseUp(with: release)
        XCTAssertEqual(copiedURL?.path, "/tmp/Sources/Foo.swift")
    }

    /// Nothing on disk, nothing offered: a row without a URL and a file this comparison
    /// deletes both build headers with no hover actions. The gate is the model — never a
    /// `FileManager` check, which a virtual table row must not pay mid-scroll.
    func testFileRowsWithoutAWorkingCopyOfferNoHoverActions() {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let bare = GitReviewFileRow(file: files[0], expanded: false)
        XCTAssertTrue(bare.subviews.compactMap { $0 as? ThemedIconButton }.isEmpty)

        let deleted = GitFileDiff(
            path: "Sources/Gone.swift",
            change: .deleted,
            hunks: [],
            added: 0,
            removed: 12
        )
        let deletedRow = GitReviewFileRow(
            file: deleted,
            expanded: false,
            fileURL: URL(fileURLWithPath: "/tmp/Sources/Gone.swift")
        )
        XCTAssertTrue(deletedRow.subviews.compactMap { $0 as? ThemedIconButton }.isEmpty)
    }

    func testEditToolDiffViewKeepsTwoLabelRows() {
        let view = DiffView(lines: [
            DiffLine(kind: .removed, text: "a"),
            DiffLine(kind: .added, text: "b")
        ])
        XCTAssertEqual(view.arrangedSubviews.count, 2)

        // The tool-row path must not grow a number column: gutter sign and text only.
        XCTAssertEqual(view.arrangedSubviews[0].subviews.count, 2)
    }

    func testFileRowExpandsWithHunkHeaders() {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let row = GitReviewFileRow(file: files[0], expanded: true)
        var expansionRequests = 0
        var preservedAnchor: GitReviewSourceLineAnchor?
        row.onExpandContext = {
            expansionRequests += 1
            preservedAnchor = $0
        }

        // Force layout to surface any conflicting constraints as a crash/log here, not in the app.
        row.layoutSubtreeIfNeeded()

        let body = row.subviews.compactMap { $0 as? NSStackView }.first
        XCTAssertNotNil(body)
        // Two hunks: header + diff, the seven omitted lines, then header + diff.
        XCTAssertEqual(body?.arrangedSubviews.count, 5)
        let expand = Self.descendants(of: ThemedButton.self, in: row)
            .first { $0.title.contains("7") }
        XCTAssertNotNil(expand)
        XCTAssertEqual(
            expand?.hoverFill?.usingColorSpace(.sRGB),
            Design.Surface.controlHover.usingColorSpace(.sRGB),
            "a context control already resting on a fill must lift to the next hover step"
        )
        XCTAssertTrue(expand?.performPrimaryAction() == true)
        XCTAssertEqual(expansionRequests, 1)
        XCTAssertEqual(
            preservedAnchor,
            GitReviewSourceLineAnchor(files[0].hunks[1].lines[0])
        )
    }

    func testHunkHeadingDisclosesOnlyItsOwnBodyAndSurvivesRowRecycling() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 700)
        controller.show(.files([file]))
        controller.view.layoutSubtreeIfNeeded()

        func materializedRow() throws -> GitReviewFileRow {
            let host = try XCTUnwrap(controller.fileTableView.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            ))
            return try XCTUnwrap(Self.firstDescendant(of: GitReviewFileRow.self, in: host))
        }

        let row = try materializedRow()
        let body = try XCTUnwrap(row.subviews.compactMap { $0 as? NSStackView }.first)
        let disclosures = Self.descendants(of: ThemedDisclosureRow.self, in: row)
        XCTAssertEqual(disclosures.count, 2)
        XCTAssertEqual(disclosures[0].accessibilityValue() as? Bool, true)
        XCTAssertFalse(body.arrangedSubviews[1].isHidden)

        let hunkWindowY = disclosures[0].convert(.zero, to: nil).y
        XCTAssertTrue(disclosures[0].performPrimaryAction())
        XCTAssertEqual(disclosures[0].accessibilityValue() as? Bool, false)
        XCTAssertTrue(body.arrangedSubviews[1].isHidden)
        XCTAssertFalse(body.arrangedSubviews[4].isHidden, "the second hunk stays open")
        XCTAssertEqual(controller.collapsedHunksByPath[file.path]?.count, 1)
        XCTAssertFalse(row.needsLayout, "the clicked row settles in the action's layout pass")
        XCTAssertFalse(
            controller.fileTableView.needsLayout,
            "the virtual table has no second visible expansion frame pending"
        )
        XCTAssertEqual(
            disclosures[0].convert(.zero, to: nil).y,
            hunkWindowY,
            accuracy: 0.5,
            "collapsing a hunk keeps its disclosure at the same window coordinate"
        )

        controller.fileTableView.reloadData()
        controller.view.layoutSubtreeIfNeeded()
        let recycled = try materializedRow()
        let recycledBody = try XCTUnwrap(
            recycled.subviews.compactMap { $0 as? NSStackView }.first
        )
        let recycledDisclosures = Self.descendants(of: ThemedDisclosureRow.self, in: recycled)
        XCTAssertEqual(recycledDisclosures[0].accessibilityValue() as? Bool, false)
        XCTAssertTrue(recycledBody.arrangedSubviews[1].isHidden)
    }

    func testReviewCardsClipDiffContentAndStickyHeadingOccludesItsRoundedTop() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let row = GitReviewFileRow(file: file, expanded: true)
        XCTAssertTrue(try XCTUnwrap(row.layer).masksToBounds)
        XCTAssertEqual(row.layer?.maskedCorners.rawValue.nonzeroBitCount, 4)

        let viewport = GitReviewStickyHeaderViewport()
        XCTAssertTrue(
            try XCTUnwrap(viewport.layer).masksToBounds,
            "a pushed sticky heading must not escape upward into the Review toolbar"
        )

        let host = GitReviewStickyHeaderHost()
        let heading = GitReviewFileRow(file: file, expanded: false, headerOnly: true)
        host.install(heading)

        XCTAssertTrue(host.subviews.first === host.occlusionSurface)
        XCTAssertTrue(host.subviews.last === host.headingSurface)
        XCTAssertEqual(
            try XCTUnwrap(host.occlusionSurface.layer).cornerRadius,
            0,
            accuracy: 0.01,
            "the source background below the rounded heading must cover scrolling diff ink"
        )
        let headingSurfaceLayer = try XCTUnwrap(host.headingSurface.layer)
        XCTAssertTrue(headingSurfaceLayer.masksToBounds)
        XCTAssertEqual(
            headingSurfaceLayer.maskedCorners.rawValue.nonzeroBitCount,
            2,
            "only the retained heading's top turns"
        )
        XCTAssertEqual(try XCTUnwrap(heading.layer).cornerRadius, 0, accuracy: 0.01)
    }

    func testTwoLineFileHeaderCentersStatsAndStageActionOnTheWholeIdentity() throws {
        let file = GitFileDiff(
            path: "Sources/Threading/Core/Agent/UsageHistoryStore.swift",
            change: .modified,
            hunks: [],
            added: 28,
            removed: 4
        )
        let row = GitReviewFileRow(
            file: file,
            expanded: false,
            staging: GitStaging.capability(for: .uncommitted)
        )
        row.frame = NSRect(x: 0, y: 0, width: 900, height: 48)
        row.layoutSubtreeIfNeeded()

        let name = try XCTUnwrap(Self.descendants(of: NSTextField.self, in: row).first {
            $0.accessibilityIdentifier() == "git-review.file.name"
        })
        let directory = try XCTUnwrap(Self.descendants(of: NSTextField.self, in: row).first {
            $0.stringValue == "Sources/Threading/Core/Agent"
        })
        let stats = try XCTUnwrap(Self.descendants(of: NSTextField.self, in: row).first {
            $0.accessibilityIdentifier() == "git-review.file.stats"
        })
        let stage = try XCTUnwrap(Self.descendants(of: ThemedButton.self, in: row).first {
            $0.title == L10n.string("Stage File")
        })
        let identityCenter = NSUnionRect(name.frame, directory.frame).midY

        XCTAssertEqual(stage.frame.midY, identityCenter, accuracy: 1)
        XCTAssertEqual(stats.frame.midY, stage.frame.midY, accuracy: 0.5)
    }

    func testContextExpansionKeepsTheAdjacentChangedLineAtTheSameWindowPosition() throws {
        let original = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let sourceLine = GitReviewSourceLineAnchor(original.hunks[1].lines[0])
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 220)
        controller.show(.files([original]))
        controller.view.layoutSubtreeIfNeeded()

        let originalHost = try XCTUnwrap(controller.fileTableView.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        let originalRow = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewFileRow.self, in: originalHost)
        )
        let expand = try XCTUnwrap(Self.descendants(of: ThemedButton.self, in: originalRow).first {
            $0.title.contains("7")
        })
        _ = expand.scrollToVisible(expand.bounds)
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.view.layoutSubtreeIfNeeded()
        let oldY = try XCTUnwrap(originalRow.yPosition(of: sourceLine))
        let oldWindowY = originalRow.convert(NSPoint(x: 0, y: oldY), to: nil).y

        let bridge = (3...9).map { number in
            GitDiffLine(
                kind: .context,
                text: "unchanged line \(number)",
                oldNumber: number,
                newNumber: number
            )
        }
        let expanded = GitFileDiff(
            path: original.path,
            change: original.change,
            hunks: [GitHunk(
                header: "@@ -1,11 +1,11 @@",
                lines: original.hunks[0].lines + bridge + original.hunks[1].lines
            )],
            added: original.added,
            removed: original.removed
        )
        controller.renderedFiles[0] = expanded
        controller.reloadContextExpansionRow(
            path: original.path,
            preserving: sourceLine,
            expectedRow: originalRow
        )
        controller.view.layoutSubtreeIfNeeded()

        let replacementHost = try XCTUnwrap(controller.fileTableView.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: false
        ))
        let replacementRow = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewFileRow.self, in: replacementHost)
        )
        let newY = try XCTUnwrap(replacementRow.yPosition(of: sourceLine))
        let newWindowY = replacementRow.convert(NSPoint(x: 0, y: newY), to: nil).y

        XCTAssertEqual(newWindowY, oldWindowY, accuracy: 0.5)
    }

    func testContextExpansionDefersItsRowReplacementDuringLiveScrolling() throws {
        let original = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let sourceLine = GitReviewSourceLineAnchor(original.hunks[1].lines[0])
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 220)
        controller.show(.files([original]))
        controller.view.layoutSubtreeIfNeeded()

        let originalHost = try XCTUnwrap(controller.fileTableView.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        controller.isFileLiveScrolling = true
        controller.reloadContextExpansionRow(path: original.path, preserving: sourceLine)

        XCTAssertTrue(controller.fileTableView.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: false
        ) === originalHost)
        XCTAssertEqual(controller.deferredContextExpansionReloads.count, 1)

        controller.finishFileLiveScrolling()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.deferredContextExpansionReloads.isEmpty)
    }

    func testDirectDiffLayoutToggleBuildsTwoAlignedTextDocuments() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.diffLayout, .unified)
        XCTAssertFalse(controller.diffLayoutButton.isSelected)
        XCTAssertTrue(controller.diffLayoutButton.performPrimaryAction())
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.diffLayout, .split)
        XCTAssertTrue(controller.diffLayoutButton.isSelected)

        let split = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewSplitDiffView.self, in: controller.view)
        )
        let documents = Self.descendants(of: GitReviewDiffTextView.self, in: split)
        XCTAssertEqual(documents.count, 2)
        XCTAssertTrue(documents.contains { $0.string.contains("old line") })
        XCTAssertTrue(documents.contains { $0.string.contains("new line") })
        let lineCounts = documents.map { $0.string.components(separatedBy: "\n").count }
        XCTAssertEqual(lineCounts[0], lineCounts[1])

        XCTAssertTrue(controller.diffLayoutButton.performPrimaryAction())
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.diffLayout, .unified)
        XCTAssertFalse(controller.diffLayoutButton.isSelected)
        XCTAssertNil(Self.firstDescendant(of: GitReviewSplitDiffView.self, in: controller.view))
    }

    func testCollapsedFileRowBuildsNoBody() {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let row = GitReviewFileRow(file: files[0], expanded: false)

        let body = row.subviews.compactMap { $0 as? NSStackView }.first
        XCTAssertEqual(body?.arrangedSubviews.count, 0)
        XCTAssertEqual(body?.isHidden, true)
    }

    func testLargeComparisonDefaultsToExpandedState() throws {
        let file = GitDiffParser.files(fromUnifiedDiff: fixture)[0]
        let manyFiles = Array(
            repeating: file,
            count: 100
        )

        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(.files(manyFiles))
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertEqual((host.subviews.first as? GitReviewFileRow)?.isOpen, true)
        XCTAssertLessThan(
            controller.instantiatedFileRowCount,
            manyFiles.count,
            "expanded state must not construct offscreen file bodies"
        )
    }

    func testTextFilesDefaultOpenButImageComparisonsStayLazy() throws {
        let text = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let image = GitFileDiff(
            path: "Screenshots/comparison.png",
            change: .binary,
            hunks: [],
            added: 0,
            removed: 0
        )

        XCTAssertTrue(GitReviewFileRow.expandsByDefault(text))
        XCTAssertTrue(GitReviewFileRow.isExpandable(image))
        XCTAssertFalse(
            GitReviewFileRow.expandsByDefault(image),
            "initial rendering must not fetch and decode image endpoint blobs"
        )
    }

    func testLargeComparisonUsesVirtualFileRows() throws {
        let files = Self.stressFiles(count: 1_000)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)

        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.fileTableView.numberOfRows, files.count)
        XCTAssertGreaterThan(controller.fileTableView.tableColumns[0].width, 450)
        let firstHost = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(firstHost.subviews.first as? GitReviewFileRow).bounds.width,
            400,
            "the file card did not follow the review pane's width"
        )
        XCTAssertLessThan(
            controller.instantiatedFileRowCount,
            files.count,
            "the table must not construct every file row to show the first viewport"
        )

        controller.fileTableView.scrollRowToVisible(files.count - 1)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.fileTableView.numberOfRows, files.count)
        XCTAssertLessThan(controller.instantiatedFileRowCount, files.count)
    }

    func testChangedFileNavigatorBuildsAFilteredTreeAndSkipsIdenticalRebuilds() {
        let navigator = GitReviewPathNavigatorViewController(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        _ = navigator.view
        let files = [
            GitFileDiff(path: "Sources/UI/Review.swift", change: .modified, hunks: [], added: 4, removed: 2),
            GitFileDiff(path: "Sources/Git/Reader.swift", change: .modified, hunks: [], added: 1, removed: 0),
            GitFileDiff(path: "Tests/ReviewTests.swift", change: .added, hunks: [], added: 20, removed: 0),
        ]

        navigator.update(files: files)
        XCTAssertEqual(navigator.rootPathsForTesting, ["Sources", "Tests"])
        XCTAssertEqual(navigator.modelRebuildCountForTesting, 1)
        navigator.update(files: files)
        XCTAssertEqual(navigator.modelRebuildCountForTesting, 1)

        navigator.setFilterForTesting("Reader")
        XCTAssertEqual(navigator.visibleLeafPathsForTesting, ["Sources/Git/Reader.swift"])
        navigator.setFilterForTesting("")
        XCTAssertEqual(Set(navigator.visibleLeafPathsForTesting), Set(files.map(\.path)))
    }

    /// The popover hands the navigator its files while it is still an unloaded controller, so a
    /// pass that only ran for an already-loaded view left ⌘J opening on a column of collapsed
    /// directories. The model may arrive first; loading is where the view owes it a pass.
    func testChangedFileNavigatorShowsItsTreeWhenTheRosterArrivesBeforeTheViewLoads() {
        let navigator = GitReviewPathNavigatorViewController(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let files = [
            GitFileDiff(path: "Sources/UI/Review.swift", change: .modified, hunks: [], added: 4, removed: 2),
            GitFileDiff(path: "Sources/Git/Reader.swift", change: .modified, hunks: [], added: 1, removed: 0),
            GitFileDiff(path: "Tests/ReviewTests.swift", change: .added, hunks: [], added: 20, removed: 0),
        ]

        navigator.update(files: files)
        _ = navigator.view

        // Sources ▸ Git ▸ Reader.swift, Sources ▸ UI ▸ Review.swift, Tests ▸ ReviewTests.swift:
        // four directories and three files, every one of them disclosed.
        XCTAssertEqual(
            navigator.outlineRowCountForTesting,
            7,
            "every changed file must be showing, not waiting behind a collapsed directory"
        )
    }

    /// A jump raised by a chord has to be finishable without the pointer.
    func testFilteredNavigatorTakesTheTopMatchOnReturn() throws {
        let navigator = GitReviewPathNavigatorViewController(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let files = [
            GitFileDiff(path: "Sources/UI/Review.swift", change: .modified, hunks: [], added: 4, removed: 2),
            GitFileDiff(path: "Sources/Git/Reader.swift", change: .modified, hunks: [], added: 1, removed: 0),
        ]
        navigator.update(files: files)
        var chosen: [String] = []
        navigator.onChoosePath = { chosen.append($0) }

        let field = try XCTUnwrap(navigator.searchResponder as? NSTextField)
        let returnKey = #selector(NSResponder.insertNewline(_:))

        XCTAssertFalse(
            navigator.control(field, textView: NSTextView(), doCommandBy: returnKey),
            "Return with nothing typed picks nothing, and stays the field's own key"
        )
        XCTAssertTrue(chosen.isEmpty)

        navigator.setFilterForTesting("Reader")
        XCTAssertTrue(navigator.control(field, textView: NSTextView(), doCommandBy: returnKey))
        XCTAssertEqual(chosen, ["Sources/Git/Reader.swift"])
    }

    func testNavigatorToggleResizesTheDiffAndJumpKeepsTheChosenFileVisible() {
        let files = Self.stressSmallExpandedFiles(count: 100, linesPerFile: 4)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 360)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()
        let initialWidth = controller.scrollView.bounds.width

        XCTAssertTrue(controller.canJumpToFile)
        XCTAssertFalse(controller.fileNavigatorButton.isSelected)
        XCTAssertTrue(controller.fileNavigatorButton.performPrimaryAction())
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.fileNavigatorVisibleForTesting)
        XCTAssertTrue(controller.fileNavigatorButton.isSelected)
        XCTAssertEqual(controller.fileNavigatorWidthForTesting, 260)
        XCTAssertLessThan(controller.scrollView.bounds.width, initialWidth)

        let target = 80
        controller.jumpToFile(files[target].path)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            controller.scrollView.documentVisibleRect.intersects(
                controller.fileTableView.rect(ofRow: target)
            )
        )

        XCTAssertTrue(controller.fileNavigatorButton.performPrimaryAction())
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.fileNavigatorVisibleForTesting)
        XCTAssertFalse(controller.fileNavigatorButton.isSelected)
        XCTAssertEqual(controller.fileNavigatorWidthForTesting, 0)
    }

    func testFileHeadingSticksAfterItsRealHeaderScrollsAway() throws {
        let files = Self.stressDenseFiles(count: 2, linesPerFile: 100)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 240)
        controller.show(.files(files))
        controller.renderedFileRoot = URL(fileURLWithPath: "/tmp")
        controller.view.layoutSubtreeIfNeeded()

        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 80))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.updateScrollControls()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.stickyFileHeaderPathForTesting, files[0].path)
        XCTAssertGreaterThan(
            controller.stickyFileHeaderHeightForTesting,
            30,
            "a retained file heading must be visible, not merely update its model path"
        )
        let stickyRow = try XCTUnwrap(controller.stickyFileHeaderRowForTesting)
        let actions = stickyRow.subviews.compactMap { $0 as? ThemedIconButton }
        XCTAssertEqual(actions.count, 2, "the retained heading keeps Copy Path and Finder")
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: stickyRow.convert(
                NSPoint(x: stickyRow.bounds.midX, y: stickyRow.bounds.midY),
                to: nil
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        stickyRow.mouseEntered(with: enter)
        let copy = try XCTUnwrap(actions.first {
            $0.accessibilityIdentifier() == "git-review.file.copy-path"
        })
        XCTAssertFalse(copy.isHidden)
        XCTAssertEqual(copy.alphaValue, 1, accuracy: 0.01)
        controller.view.layoutSubtreeIfNeeded()
        let copyPoint = copy.convert(
            NSPoint(x: copy.bounds.midX, y: copy.bounds.midY),
            to: controller.view
        )
        let hit = controller.view.hitTest(copyPoint)
        XCTAssertTrue(hit === copy || hit?.isDescendant(of: copy) == true)

        var copiedURL: URL?
        stickyRow.copyPathHandler = { copiedURL = $0 }
        let press = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: copy.convert(
                NSPoint(x: copy.bounds.midX, y: copy.bounds.midY),
                to: nil
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))
        let release = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: press.locationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))
        copy.mouseDown(with: press)
        copy.mouseUp(with: release)
        XCTAssertEqual(copiedURL?.path, "/tmp/\(files[0].path)")

        let firstRowRect = controller.fileTableView.rect(ofRow: 0)
        let stickyHeight = controller.stickyFileHeaderHeightForTesting
        let requestedNextHeaderY = stickyHeight / 2 + Design.Spacing.small
        controller.scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: firstRowRect.maxY - requestedNextHeaderY
        ))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.updateScrollControls()

        let nextHeaderY = firstRowRect.maxY
            - controller.scrollView.documentVisibleRect.minY
        let retainedHeaderBottom = controller.stickyFileHeaderTopForTesting + stickyHeight
        XCTAssertLessThan(controller.stickyFileHeaderTopForTesting, 0)
        XCTAssertEqual(
            nextHeaderY - retainedHeaderBottom,
            Design.Spacing.small,
            accuracy: 0.5,
            "the retained heading must leave the ordinary inter-file gap before the next one"
        )

        let immediateFrame = controller.stickyFileHeaderFrameInViewForTesting
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            controller.stickyFileHeaderFrameInViewForTesting.origin.y,
            immediateFrame.origin.y,
            accuracy: 0.5,
            "the sticky heading must move in the scroll callback, not one layout frame later"
        )

        controller.scrollView.contentView.scroll(to: .zero)
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.updateScrollControls()
        XCTAssertNil(controller.stickyFileHeaderPathForTesting)
    }

    func testExpandedHeightInvalidationNeverStretchesTheCollapsedHeader() throws {
        let file = try XCTUnwrap(Self.stressDenseFiles(count: 1, linesPerFile: 120).first)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 360)
        controller.expansionOverrides[file.path] = false
        controller.show(.files([file]))
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let row = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        let name = try XCTUnwrap(
            Self.descendants(of: NSTextField.self, in: row).first {
                $0.accessibilityIdentifier() == "git-review.file.name"
            }
        )
        var nameHeightDuringInvalidation: CGFloat?
        row.onExpansionGeometryChange = { expanded in
            controller.expansionOverrides[file.path] = expanded
            controller.measuredFileRowHeights[file.path] = nil
            controller.fileTableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integer: 0)
            )
            controller.view.layoutSubtreeIfNeeded()
            nameHeightDuringInvalidation = name.frame.height
        }

        row.setExpanded(true)

        XCTAssertTrue(row.isOpen)
        XCTAssertLessThan(
            try XCTUnwrap(nameHeightDuringInvalidation),
            40,
            "the old header-only constraints must not span the expanded table estimate"
        )
        XCTAssertFalse(name.isHidden)
    }

    func testProgressiveFileIndexReconcilesIntoFullRowsInPlace() {
        let files = Self.stressFiles(count: 200)
        let index = files.map {
            GitFileDiff(
                path: $0.path,
                change: $0.change,
                hunks: [],
                added: 0,
                removed: 0
            )
        }
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .lastTurn
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)

        controller.show(.fileIndex(index))
        controller.view.layoutSubtreeIfNeeded()
        let table = controller.fileTableView
        XCTAssertTrue(controller.scrollView.documentView === table)
        XCTAssertEqual(table.numberOfRows, files.count)
        XCTAssertEqual(controller.pendingDiffIndexPaths.count, files.count)
        XCTAssertTrue(controller.counterLabel.stringValue.contains(L10n.string("Loading…")))

        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.scrollView.documentView === table)
        XCTAssertTrue(controller.pendingDiffIndexPaths.isEmpty)
        XCTAssertEqual(controller.renderedFiles, files)
        XCTAssertLessThan(controller.instantiatedFileRowCount, files.count)
    }

    /// History pages are only a transport bound, not a UI bound: every press of Show more keeps
    /// another page. The production surface therefore has to retain models while mounting only
    /// the graph rows that intersect the viewport.
    func testLargeHistoryUsesVirtualCommitRows() {
        let commits = (0..<1_000).map { index in
            let hash = String(format: "%040x", index + 1)
            return GitCommitSummary(
                hash: hash,
                shortHash: String(hash.prefix(7)),
                subject: "Commit \(index)",
                author: "Performance Fixture",
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                added: index % 20,
                removed: index % 7,
                parents: index + 1 < 1_000
                    ? [String(format: "%040x", index + 2)]
                    : [],
                refs: index == 0 ? ["HEAD", "main"] : []
            )
        }
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .commit
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.commits = commits
        controller.show(.commits(canLoadMore: true))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.scrollView.documentView === controller.historyTableView)
        XCTAssertEqual(controller.historyTableView.numberOfRows, commits.count + 1)
        XCTAssertLessThan(
            controller.instantiatedCommitRowCount,
            commits.count / 10,
            "opening history eagerly constructed offscreen commit rows"
        )

        controller.scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: controller.maximumScrollOffsetY()
        ))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            controller.instantiatedCommitRowCount,
            commits.count / 5,
            "seeking through history constructed rows between the two viewports"
        )
        XCTAssertGreaterThan(controller.historyTableView.visibleRect.minY, 0)
    }

    func testHistoryStatsEnrichRowsWithoutRebuildingGraph() {
        func commit(added: Int, removed: Int, hasStats: Bool) -> GitCommitSummary {
            GitCommitSummary(
                hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                shortHash: "aaaaaaa",
                subject: "Progressively measured",
                author: "Performance Fixture",
                date: Date(timeIntervalSince1970: 1_750_000_000),
                added: added,
                removed: removed,
                hasStats: hasStats,
                parents: [],
                refs: ["HEAD", "main"]
            )
        }

        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .commit
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.commits = [commit(added: 0, removed: 0, hasStats: false)]
        controller.show(.commits(canLoadMore: false))
        controller.view.layoutSubtreeIfNeeded()
        let graph = controller.renderedCommitGraph

        XCTAssertEqual(
            controller.applyCommitStats([commit(added: 12, removed: 4, hasStats: true)]),
            1
        )
        XCTAssertEqual(controller.commits.first?.added, 12)
        XCTAssertEqual(controller.commits.first?.removed, 4)
        XCTAssertTrue(controller.commits.first?.hasStats == true)
        XCTAssertEqual(controller.renderedCommitGraph, graph)
        XCTAssertTrue(controller.scrollView.documentView === controller.historyTableView)
    }

    /// The pane is one column: the mode chip, every file card and the overflow start and end on
    /// the same margin. They did not, and the reason is not visible in any of the three's own
    /// code — the file table's `.automatic` style resolves to `.inset`, which keeps 16pt of
    /// AppKit's own at each side, so cards sat 40pt in beneath a chip at 12. The overflow was
    /// the other half: pinned by its frame, a plain button hangs its glyph a further 4pt inside.
    func testHeaderChipFileCardsAndOverflowShareOneMargin() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let card = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        let cardFrame = card.convert(card.bounds, to: controller.view)
        let chip = controller.modeChip
        let chipFrame = chip.convert(chip.bounds, to: controller.view)

        XCTAssertEqual(
            cardFrame.minX, chipFrame.minX, accuracy: 0.5,
            "the mode chip's hover and focus plate should start where a file card does"
        )
        XCTAssertEqual(
            controller.view.bounds.maxX - cardFrame.maxX,
            chipFrame.minX,
            accuracy: 0.5,
            "a file card's margins should be equal on both sides"
        )
        let diff = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewDiffTextView.self, in: card)
        )
        let diffFrame = diff.convert(diff.bounds, to: controller.view)
        XCTAssertEqual(
            diffFrame.minX, cardFrame.minX, accuracy: 0.5,
            "the expanded diff should use the card's full leading edge"
        )
        XCTAssertEqual(
            diffFrame.maxX, cardFrame.maxX, accuracy: 0.5,
            "the expanded diff should use the card's full trailing edge"
        )

        // The complete hover/focus target stays on the card margin, not only its glyph.
        let overflow = controller.menuButton
        let overflowFrame = overflow.convert(overflow.bounds, to: controller.view)
        XCTAssertEqual(
            overflowFrame.maxX, cardFrame.maxX, accuracy: 0.5,
            "the overflow's interaction surface should end where a file card does"
        )

        // And the same margin vertically, so the header reads as the top of the list rather
        // than as a band above it: the row sat 6pt below the tab strip and 12pt above the
        // first card, which showed as the chip hugging the strip.
        let sideMargin = Design.Spacing.inset
        XCTAssertEqual(
            controller.view.bounds.maxY - chipFrame.maxY, sideMargin, accuracy: 0.5,
            "the header should sit the pane's own margin below the tab strip"
        )
        XCTAssertEqual(
            chipFrame.minY - cardFrame.maxY, sideMargin, accuracy: 0.5,
            "the gap under the header should match the pane's margin"
        )
    }

    /// The publish strip is optional, so its lower margin has to arrive and leave with it. A
    /// constant on the scroll view would either join a visible strip to the first file card or
    /// double the ordinary chip-to-card gap while the strip is collapsed.
    func testChangeRequestBarVisibilityKeepsPaneMarginsAroundFileList() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        // The GitHub read completes after the diff has already mounted in the running app.
        controller.setChangeRequestBarVisible(true)
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let card = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        let cardFrame = card.convert(card.bounds, to: controller.view)
        let barFrame = controller.changeRequestBar.convert(
            controller.changeRequestBar.bounds,
            to: controller.view
        )

        XCTAssertEqual(
            barFrame.minY - cardFrame.maxY,
            Design.Spacing.inset,
            accuracy: 0.5,
            "the publish strip should not touch the first file card"
        )

        controller.setChangeRequestBarVisible(false)
        controller.view.layoutSubtreeIfNeeded()

        let collapsedCardFrame = card.convert(card.bounds, to: controller.view)
        let chipFrame = controller.modeChip.convert(controller.modeChip.bounds, to: controller.view)
        XCTAssertEqual(
            chipFrame.minY - collapsedCardFrame.maxY,
            Design.Spacing.inset,
            accuracy: 0.5,
            "collapsing the publish strip should restore the ordinary header-to-card margin"
        )
    }

    /// The other half of moving the row gap out of `intercellSpacing` and into the row: cards
    /// still have to be separated by exactly one gap, not two and not none.
    func testCardsAreSeparatedByOneRowGap() throws {
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(.files(Self.stressFiles(count: 3)))
        controller.view.layoutSubtreeIfNeeded()

        let frames = try (0..<2).map { row -> NSRect in
            let host = try XCTUnwrap(
                controller.fileTableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            )
            let card = try XCTUnwrap(host.subviews.first)
            return card.convert(card.bounds, to: controller.view)
        }

        XCTAssertEqual(
            frames[0].minY - frames[1].maxY, Design.Spacing.small, accuracy: 0.5,
            "consecutive file cards should be one gap apart"
        )
    }

    func testVirtualFileRowExpansionPersistsAndInvalidatesHeight() throws {
        let source = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        let files = (0..<100).map { index in
            GitFileDiff(
                path: "Sources/Feature\(index)/Foo.swift",
                change: source.change,
                hunks: source.hunks,
                added: source.added,
                removed: source.removed
            )
        }
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.expansionOverrides[files[0].path] = false
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let fileRow = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        XCTAssertFalse(fileRow.isOpen)
        let collapsedHeight = controller.fileTableView.rect(ofRow: 0).height

        fileRow.setExpanded(true)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.expansionOverrides[files[0].path], true)
        XCTAssertGreaterThan(controller.fileTableView.rect(ofRow: 0).height, collapsedHeight)

        controller.fileTableView.reloadData()
        controller.view.layoutSubtreeIfNeeded()
        let reloadedHost = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertEqual((reloadedHost.subviews.first as? GitReviewFileRow)?.isOpen, true)
    }

    func testVirtualFileRowRetainsExactEditorDestination() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = "Sources/Threading/UI/Views/GitReviewRendering.swift"
        let file = GitFileDiff(
            path: path,
            change: .modified,
            hunks: [
                GitHunk(
                    header: "@@ -41,1 +41,2 @@",
                    lines: [
                        GitDiffLine(
                            kind: .context,
                            text: "let oldValue = 1",
                            oldNumber: 41,
                            newNumber: 41
                        ),
                        GitDiffLine(
                            kind: .added,
                            text: "let exactValue = 2",
                            oldNumber: nil,
                            newNumber: 42
                        )
                    ]
                )
            ],
            added: 1,
            removed: 0
        )
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: repository.path,
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(.files([file]))
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let fileRow = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        XCTAssertEqual(
            fileRow.openInTarget,
            .file(repository.appendingPathComponent(path), line: 42),
            "reconstructing a virtual row lost the exact new-file line from its diff"
        )

        controller.show(.files([
            GitFileDiff(path: path, change: .binary, hunks: [], added: 0, removed: 0)
        ]))
        controller.view.layoutSubtreeIfNeeded()
        let binaryHost = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertEqual(
            (binaryHost.subviews.first as? GitReviewFileRow)?.openInTarget,
            .file(repository.appendingPathComponent(path), line: nil),
            "a file without numbered diff lines invented an editor position"
        )
    }

    func testLongDiffShowsScrollToEndControl() {
        let lines = (1...80).map { number in
            GitDiffLine(
                kind: .context,
                text: "let value\(String(number)) = \(String(number))",
                oldNumber: number,
                newNumber: number
            )
        }
        let file = GitFileDiff(
            path: "Sources/Long.swift",
            change: .modified,
            hunks: [GitHunk(header: "@@ -1,80 +1,80 @@", lines: lines)],
            added: 0,
            removed: 0
        )
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .unstaged
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 280)
        controller.show(.files([file]))
        controller.view.layoutSubtreeIfNeeded()
        controller.updateScrollControls()

        XCTAssertTrue(controller.jumpToEndButton.isFloatingPresent)

        controller.scrollToDiffEnd()
        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            controller.maximumScrollOffsetY(),
            accuracy: 0.5,
            "jump-to-end should reach AppKit's inset-aware terminal scroll position"
        )
        XCTAssertFalse(
            controller.jumpToEndButton.isFloatingPresent,
            "document=\(controller.scrollView.documentView?.frame.height ?? -1), "
                + "viewport=\(controller.scrollView.contentView.bounds.height), "
                + "offset=\(controller.scrollView.contentView.bounds.origin.y)"
        )
    }

    func testHeaderUsesCompactDiffCountsAndExposesExactCountsOnHover() {
        let added = 79_738
        let removed = 8_486
        let file = GitFileDiff(
            path: "Sources/Large.swift",
            change: .modified,
            hunks: [],
            added: added,
            removed: removed
        )
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.show(.files([file]))

        XCTAssertEqual(
            controller.counterLabel.stringValue,
            "+\(added.formatted(.number.notation(.compactName))) "
                + "−\(removed.formatted(.number.notation(.compactName)))"
        )
        XCTAssertEqual(
            controller.counterLabel.toolTip,
            "+\(added.formatted(.number.grouping(.automatic))) "
                + "−\(removed.formatted(.number.grouping(.automatic)))"
        )
        XCTAssertEqual(
            controller.counterLabel.accessibilityLabel(),
            L10n.format(
                "%lld changed files, %lld additions, %lld deletions",
                Int64(1),
                Int64(added),
                Int64(removed)
            )
        )
    }

    /// Automatic table height is first queried before the card has its real width. The compact
    /// TextKit body must replace that fallback measurement once it reaches the pane; otherwise
    /// a narrow 240pt measurement survives under a 500pt card as a large blank scroll region.
    func testDenseExpandedDiffFitsItsActualWidthAndUsedHeight() async throws {
        let file = try XCTUnwrap(Self.stressDenseFiles(count: 1, linesPerFile: 400).first)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.show(.files([file]))
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let card = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        let diff = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewDiffTextView.self, in: card)
        )
        let usedHeight = try XCTUnwrap(diff.layoutManager).usedRect(
            for: try XCTUnwrap(diff.textContainer)
        ).height

        XCTAssertEqual(diff.bounds.width, card.bounds.width, accuracy: 0.5)
        XCTAssertEqual(diff.bounds.height, ceil(usedHeight), accuracy: 0.5)
        XCTAssertLessThan(
            card.bounds.height - diff.bounds.height,
            120,
            "the card retained false scrollable height below the laid-out glyphs; "
                + "card=\(card.bounds.height) intrinsic=\(card.intrinsicContentSize.height) "
                + "host=\(host.bounds.height) fitting=\(host.fittingSize.height) "
                + "tableRow=\(controller.fileTableView.rect(ofRow: 0).height) "
                + "tableLookup=\(controller.fileTableView.row(for: card)) "
                + "cached=\(String(describing: controller.measuredFileRowHeights[file.path])) "
                + "initial=\(diff.initialMeasuredSize) diff=\(diff.bounds.height) used=\(usedHeight)"
        )

        controller.scrollToDiffEnd()
        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            controller.maximumScrollOffsetY(),
            accuracy: 0.5,
            "a dense measured row should have no hidden document tail"
        )

        controller.view.frame.size.width = 460
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(diff.bounds.width, card.bounds.width, accuracy: 0.5)
        XCTAssertEqual(
            card.bounds.height - diff.bounds.height,
            110,
            accuracy: 4,
            "resizing should replace both height caches while retaining the context control; "
                + "card=\(card.bounds.height) diff=\(diff.bounds.height) "
                + "row=\(controller.fileTableView.rect(ofRow: 0).height) "
                + "cache=\(String(describing: controller.measuredFileRowHeights[file.path]))"
        )
    }

    /// A split divider may advance the pane every display frame. The viewport, virtual table,
    /// mounted card and TextKit document must advance by the same delta in that one layout pass;
    /// a fast second pass is still a visible trailing animation.
    func testVisibleDiffWidthSettlesWithEveryPaneResizeFrame() throws {
        let file = try XCTUnwrap(Self.stressDenseFiles(count: 1, linesPerFile: 120).first)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.show(.files([file]))
        controller.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            controller.fileTableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let card = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        let diff = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewDiffTextView.self, in: card)
        )

        func widths() -> (
            clip: CGFloat,
            table: CGFloat,
            column: CGFloat,
            host: CGFloat,
            card: CGFloat,
            diff: CGFloat
        ) {
            (
                controller.scrollView.contentView.bounds.width,
                controller.fileTableView.bounds.width,
                controller.fileTableView.tableColumns[0].width,
                host.bounds.width,
                card.bounds.width,
                diff.bounds.width
            )
        }

        var previous = widths()
        for width: CGFloat in [680, 760, 540, 700, 460, 620] {
            controller.view.setFrameSize(NSSize(width: width, height: 760))
            controller.view.layoutSubtreeIfNeeded()

            let current = widths()
            let viewportDelta = current.clip - previous.clip
            for (name, delta) in [
                ("table", current.table - previous.table),
                ("column", current.column - previous.column),
                ("row host", current.host - previous.host),
                ("file card", current.card - previous.card),
                ("diff document", current.diff - previous.diff)
            ] {
                XCTAssertEqual(
                    delta,
                    viewportDelta,
                    accuracy: 0.5,
                    "\(name) trailed the viewport at pane width \(width)"
                )
            }
            XCTAssertFalse(
                controller.fileTableView.needsLayout,
                "the table left a second visible layout pass pending at pane width \(width)"
            )
            XCTAssertFalse(
                card.needsLayout,
                "the visible card left its TextKit width for the next frame at pane width \(width)"
            )
            previous = current
        }
    }

    /// Offscreen files remain model rows, but their estimates must be close enough that the
    /// document and scrollbar do not acquire a new tail as the last viewport materializes.
    func testExpandedHeightEstimatesKeepTheDocumentExtentStable() async {
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        let files = Self.stressDenseFiles(count: 30, linesPerFile: 80)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()
        let initialHeight = controller.fileTableView.frame.height

        controller.fileTableView.scrollRowToVisible(29)
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()
        let discoveredHeight = controller.fileTableView.frame.height
        let firstEstimate = GitReviewFileRow.estimatedTableHeight(
            for: files[0],
            expanded: true,
            wraps: true,
            width: 596
        )

        XCTAssertLessThan(
            abs(discoveredHeight - initialHeight) / max(initialHeight, 1),
            0.01,
            "materializing the final viewport should not move the scrollbar's terminal extent; "
                + "initial=\(initialHeight) discovered=\(discoveredHeight) "
                + "measured=\(controller.measuredFileRowHeights.count) "
                + "estimate=\(firstEstimate) "
                + "first=\(String(describing: controller.measuredFileRowHeights[files[0].path])) "
                + "last=\(String(describing: controller.measuredFileRowHeights[files[29].path]))"
        )
        controller.scrollToDiffEnd()
        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            controller.maximumScrollOffsetY(),
            accuracy: 0.5
        )

        controller.view.frame.size.width = 460
        controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()
        controller.view.layoutSubtreeIfNeeded()
        let resizedHeight = controller.fileTableView.frame.height
        let resizedEstimate = GitReviewFileRow.estimatedTableHeight(
            for: files[0],
            expanded: true,
            wraps: true,
            width: 436
        )
        XCTAssertLessThan(
            abs(resizedHeight - resizedEstimate * CGFloat(files.count))
                / max(resizedHeight, 1),
            0.01,
            "resizing should replace offscreen wrapping estimates as one table-height update"
        )
    }

    /// A watched checkout is not the same immutable list with a repaint: generated files can be
    /// inserted ahead of the viewport while the reader is moving through it. A raw pixel offset
    /// then names a different file, which is the visible "jump" this pane promises to avoid.
    func testWatchedRefreshPreservesTheVisibleFileAnchorAcrossEarlierInsertions() throws {
        let original = Self.stressSmallExpandedFiles(count: 120, linesPerFile: 9)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.show(.files(original))
        controller.view.layoutSubtreeIfNeeded()

        let anchorIndex = 70
        let anchorOffset: CGFloat = 11
        controller.scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: controller.fileTableView.rect(ofRow: anchorIndex).minY + anchorOffset
        ))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)

        let inserted = Self.stressSmallExpandedFiles(
            count: 12,
            linesPerFile: 9,
            pathPrefix: "000-Earlier"
        )
        controller.show(.files(inserted + original))
        controller.view.layoutSubtreeIfNeeded()

        let visibleY = controller.scrollView.contentView.bounds.minY
        let visibleRow = controller.fileTableView.row(
            at: NSPoint(x: 1, y: visibleY + anchorOffset)
        )
        XCTAssertEqual(visibleRow, anchorIndex + inserted.count)
        XCTAssertEqual(
            visibleY - controller.fileTableView.rect(ofRow: visibleRow).minY,
            anchorOffset,
            accuracy: 0.5
        )

        // The fast path keeps an unchanged visible row alive, but a same-path content update
        // still has to replace that row rather than leaving the old TextKit document onscreen.
        let refreshedLine = "fresh watcher content at the anchored path"
        let refreshedFile = GitFileDiff(
            path: original[anchorIndex].path,
            change: .untracked,
            hunks: [GitHunk(
                header: "@@ -0,0 +1 @@",
                lines: [GitDiffLine(
                    kind: .added,
                    text: refreshedLine,
                    oldNumber: nil,
                    newNumber: 1
                )]
            )],
            added: 1,
            removed: 0
        )
        var refreshed = inserted + original
        refreshed[anchorIndex + inserted.count] = refreshedFile
        controller.show(.files(refreshed))
        controller.view.layoutSubtreeIfNeeded()

        let refreshedHost = try XCTUnwrap(controller.fileTableView.view(
            atColumn: 0,
            row: anchorIndex + inserted.count,
            makeIfNecessary: false
        ))
        let refreshedText = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewDiffTextView.self, in: refreshedHost)
        )
        XCTAssertTrue(refreshedText.string.contains(refreshedLine))
    }

    /// Applying a watcher result while AppKit is carrying trackpad momentum ends that scroll
    /// transaction abruptly. The pane keeps receiving models, but only the newest one should
    /// touch the table after live scrolling ends.
    func testWatchedRefreshCoalescesUntilLiveScrollingEnds() {
        let original = Self.stressSmallExpandedFiles(count: 30, linesPerFile: 9)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.show(.files(original))
        controller.view.layoutSubtreeIfNeeded()

        let anchorIndex = 15
        let anchorOffset: CGFloat = 13
        controller.scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: controller.fileTableView.rect(ofRow: anchorIndex).minY + anchorOffset
        ))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: controller.scrollView
        )
        let firstInsert = Self.stressSmallExpandedFiles(
            count: 1,
            linesPerFile: 9,
            pathPrefix: "000-Earlier-A"
        )
        let latestInsert = Self.stressSmallExpandedFiles(
            count: 2,
            linesPerFile: 9,
            pathPrefix: "000-Earlier-B"
        )
        controller.show(.files(firstInsert + original))
        controller.show(.files(latestInsert + original))

        XCTAssertEqual(controller.fileTableView.numberOfRows, original.count)
        XCTAssertNotNil(controller.deferredPhaseDuringLiveScroll)

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: controller.scrollView
        )
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.fileTableView.numberOfRows, original.count + latestInsert.count)
        XCTAssertNil(controller.deferredPhaseDuringLiveScroll)
        let visibleY = controller.scrollView.contentView.bounds.minY
        let visibleRow = controller.fileTableView.row(at: NSPoint(x: 1, y: visibleY + 0.5))
        XCTAssertEqual(visibleRow, anchorIndex + latestInsert.count)
        XCTAssertEqual(
            visibleY - controller.fileTableView.rect(ofRow: visibleRow).minY,
            anchorOffset,
            accuracy: 0.5
        )
    }

    /// Exact TextKit heights arrive one run-loop turn after a virtual row is mounted. Letting
    /// those notifications retile the table between momentum events is another source of a
    /// visible jump, independent of filesystem refreshes.
    func testExactHeightDiscoveryWaitsUntilLiveScrollingEnds() {
        let files = Self.stressSmallExpandedFiles(count: 80, linesPerFile: 9)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let measurementsBeforeScroll = controller.measuredFileRowHeights.count

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: controller.scrollView
        )
        controller.scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: controller.fileTableView.rect(ofRow: 60).minY
        ))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(controller.measuredFileRowHeights.count, measurementsBeforeScroll)

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: controller.scrollView
        )
        XCTAssertGreaterThan(controller.measuredFileRowHeights.count, measurementsBeforeScroll)
    }

    func testPendingNumstatWeightEstablishesExpandedDocumentGeometry() {
        let pending = GitFileDiff(
            path: "Sources/Pending.swift",
            change: .modified,
            hunks: [],
            added: 120,
            removed: 30
        )

        XCTAssertEqual(
            GitReviewFileRow.estimatedPendingTableHeight(for: pending, expanded: false),
            48
        )
        XCTAssertGreaterThan(
            GitReviewFileRow.estimatedPendingTableHeight(for: pending, expanded: true),
            2_000,
            "a pending large file must contribute its line weight before its hunks hydrate"
        )
    }

    /// A scrollbar-thumb drag may replace the viewport on every pointer event. Those transient
    /// rows preserve expanded geometry without building TextKit; release installs the complete
    /// diff at the exact same scroll origin.
    func testScrollerThumbSeekDefersBodiesUntilTheRestingViewport() throws {
        let files = Self.stressSmallExpandedFiles(count: 80, linesPerFile: 9)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        controller.beginFileScrollerSeek()
        controller.scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: controller.fileTableView.rect(ofRow: 60).minY + 13
        ))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.view.layoutSubtreeIfNeeded()
        let originDuringSeek = controller.scrollView.contentView.bounds.origin
        XCTAssertGreaterThan(controller.instantiatedDeferredFileRowCount, 0)
        XCTAssertNil(
            Self.firstDescendant(
                of: GitReviewDiffTextView.self,
                in: controller.scrollView.contentView
            )
        )

        controller.finishFileLiveScrolling()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            originDuringSeek.y,
            accuracy: 0.5
        )
        XCTAssertNotNil(
            Self.firstDescendant(
                of: GitReviewDiffTextView.self,
                in: controller.scrollView.contentView
            )
        )
    }

    /// The seek row's body area is a ghost, not bare card surface: scrubbing through one
    /// enormous expanded diff used to show a screen of empty card, which read as the pane
    /// failing to draw rather than declining to yet.
    func testScrollerSeekRowsWearTheSkeletonGhost() throws {
        let files = Self.stressSmallExpandedFiles(count: 80, linesPerFile: 9)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        controller.beginFileScrollerSeek()
        controller.scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: controller.fileTableView.rect(ofRow: 60).minY + 13
        ))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertNotNil(
            Self.firstDescendant(
                of: DiffSkeletonView.self,
                in: controller.scrollView.contentView
            ),
            "a deferred expanded row must ghost its body"
        )
        controller.finishFileLiveScrolling()
    }

    /// A thumb held still mid-drag is the reader pausing to look. The settle pass installs
    /// the real viewport at the exact origin without ending the drag's transaction, without
    /// moving the document's extent — and the next knob jump re-enters the cheap path.
    func testAHeldStillScrollerThumbMaterializesTheViewportBeforeRelease() throws {
        let files = Self.stressSmallExpandedFiles(count: 80, linesPerFile: 9)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.show(.files(files))
        controller.view.layoutSubtreeIfNeeded()

        controller.beginFileScrollerSeek()
        controller.scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: controller.fileTableView.rect(ofRow: 60).minY + 13
        ))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.view.layoutSubtreeIfNeeded()
        let originDuringSeek = controller.scrollView.contentView.bounds.origin
        let extentDuringSeek = controller.fileTableView.bounds.height
        XCTAssertNil(
            Self.firstDescendant(
                of: GitReviewDiffTextView.self,
                in: controller.scrollView.contentView
            )
        )

        controller.settleFileScrollerSeek()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertNotNil(
            Self.firstDescendant(
                of: GitReviewDiffTextView.self,
                in: controller.scrollView.contentView
            ),
            "the pause must be answered with real content, not the ghost"
        )
        XCTAssertEqual(
            controller.scrollView.contentView.bounds.origin.y,
            originDuringSeek.y,
            accuracy: 0.5
        )
        XCTAssertEqual(
            controller.fileTableView.bounds.height,
            extentDuringSeek,
            accuracy: 0.5,
            "height discovery stays coalesced while the thumb is held"
        )
        XCTAssertTrue(controller.isFileLiveScrolling, "the drag's transaction is still open")
        XCTAssertFalse(controller.isFileScrollerSeeking)

        let deferredBeforeResume = controller.instantiatedDeferredFileRowCount
        controller.beginFileScrollerSeek()
        controller.scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: controller.fileTableView.rect(ofRow: 20).minY + 13
        ))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(
            controller.instantiatedDeferredFileRowCount,
            deferredBeforeResume,
            "resuming the drag must re-enter the cheap deferred path"
        )

        controller.finishFileLiveScrolling()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(
            Self.firstDescendant(
                of: GitReviewDiffTextView.self,
                in: controller.scrollView.contentView
            )
        )
    }

    /// A pending file with known numstat weight presents as an expanded ghost, and its height
    /// stays the model's estimate: the skeleton stretches to whatever it is given, so measuring
    /// it would collapse the honest document extent to the header's own fitting height.
    func testAPendingRowWithKnownWeightWearsTheSkeletonAtItsEstimatedHeight() throws {
        let pending = GitFileDiff(
            path: "Sources/Pending.swift",
            change: .modified,
            hunks: [],
            added: 120,
            removed: 30
        )
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .lastTurn
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        controller.show(.fileIndex([pending]))
        controller.view.layoutSubtreeIfNeeded()

        let expected = GitReviewFileRow.estimatedPendingTableHeight(for: pending, expanded: true)
        XCTAssertEqual(
            controller.fileTableView.rect(ofRow: 0).height,
            expected,
            accuracy: 1
        )
        XCTAssertNotNil(
            Self.firstDescendant(
                of: DiffSkeletonView.self,
                in: controller.scrollView.contentView
            ),
            "the numstat height the row already owns must show as a ghost, not an empty card"
        )

        // The exact-height pass a real row takes must skip the ghost. Run it synchronously by
        // closing a live-scroll transaction over this same viewport.
        controller.isFileLiveScrolling = true
        controller.finishFileLiveScrolling()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            controller.fileTableView.rect(ofRow: 0).height,
            expected,
            accuracy: 1,
            "the ghost's fitting height must not replace the numstat estimate"
        )
    }

    /// Opt-in rather than part of the fast suite: this is a repeatable workload for `sample`,
    /// `xctrace`, and before/after measurements of the pane's large-file-index path.
    ///
    /// Run with:
    /// `THREADING_GIT_STRESS=1 scripts/test.sh fast
    /// -only-testing:ThreadingTests/GitReviewViewTests/testStressLargeFileIndexesWhenEnabled`
    func testStressLargeFileIndexesWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_GIT_STRESS"] == "1",
            "Set THREADING_GIT_STRESS=1 to run the large Git Review sweep."
        )

        for fileCount in [10, 100, 500, 1_000] {
            let controller = GitReviewViewController(
                sessionID: SessionID(),
                folderPath: NSTemporaryDirectory(),
                mode: .uncommitted
            )
            _ = controller.view
            controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)

            let files = Self.stressFiles(count: fileCount)
            let renderStarted = DispatchTime.now().uptimeNanoseconds
            controller.show(.files(files))
            let renderEnded = DispatchTime.now().uptimeNanoseconds
            controller.view.layoutSubtreeIfNeeded()
            let layoutEnded = DispatchTime.now().uptimeNanoseconds

            print(
                "THREADING_PERF git-review-file-index "
                    + "files=\(fileCount) instantiated=\(controller.instantiatedFileRowCount) "
                    + "render_ms=\(Self.milliseconds(renderEnded - renderStarted)) "
                    + "layout_ms=\(Self.milliseconds(layoutEnded - renderEnded)) "
                    + "elapsed_ms=\(Self.milliseconds(layoutEnded - renderStarted))"
            )

            let scrollStarted = DispatchTime.now().uptimeNanoseconds
            controller.fileTableView.scrollRowToVisible(fileCount - 1)
            controller.view.layoutSubtreeIfNeeded()
            let scrollElapsed = DispatchTime.now().uptimeNanoseconds - scrollStarted
            print(
                "THREADING_PERF git-review-file-deep-scroll "
                    + "files=\(fileCount) instantiated=\(controller.instantiatedFileRowCount) "
                    + "elapsed_ms=\(Self.milliseconds(scrollElapsed))"
            )
        }

        let targetIndex = 777
        let expandableFiles = Self.stressExpandableFiles(count: 1_000)
        let deepController = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = deepController.view
        deepController.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        deepController.expansionOverrides[expandableFiles[targetIndex].path] = false
        deepController.show(.files(expandableFiles))
        deepController.view.layoutSubtreeIfNeeded()
        deepController.fileTableView.scrollRowToVisible(targetIndex)
        deepController.view.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(
            deepController.fileTableView.view(
                atColumn: 0,
                row: targetIndex,
                makeIfNecessary: true
            )
        )
        let fileRow = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        let openStarted = DispatchTime.now().uptimeNanoseconds
        fileRow.setExpanded(true)
        deepController.view.layoutSubtreeIfNeeded()
        let openElapsed = DispatchTime.now().uptimeNanoseconds - openStarted

        XCTAssertEqual(deepController.expansionOverrides[expandableFiles[targetIndex].path], true)
        XCTAssertEqual(GitReviewFileRow.firstChangedLine(in: expandableFiles[targetIndex]), 779)
        print(
            "THREADING_PERF git-review-file-open "
                + "files=1000 row=\(targetIndex) exact_line=779 "
                + "elapsed_ms=\(Self.milliseconds(openElapsed))"
        )

        // The original disclosure fixture above is deliberately tiny: it guards exact deep
        // navigation, but its two diff lines cannot reproduce the pause reported on a real
        // working tree. This one matches the production per-file display cap and the reported
        // 174-file index, and splits body construction from the table's cached-height layout.
        let denseFiles = Self.stressDenseFiles(
            count: 174,
            linesPerFile: GitReviewDefaults.fileDisplayCap
        )
        let denseController = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = denseController.view
        denseController.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        denseController.expansionOverrides[denseFiles[87].path] = false
        denseController.show(.files(denseFiles))
        denseController.view.layoutSubtreeIfNeeded()

        let denseTarget = 87
        denseController.fileTableView.scrollRowToVisible(denseTarget)
        denseController.view.layoutSubtreeIfNeeded()
        let denseHost = try XCTUnwrap(
            denseController.fileTableView.view(
                atColumn: 0,
                row: denseTarget,
                makeIfNecessary: true
            )
        )
        let denseRow = try XCTUnwrap(denseHost.subviews.first as? GitReviewFileRow)

        let openSetStarted = DispatchTime.now().uptimeNanoseconds
        denseRow.setExpanded(true)
        let openSetEnded = DispatchTime.now().uptimeNanoseconds
        denseController.view.layoutSubtreeIfNeeded()
        let openLayoutEnded = DispatchTime.now().uptimeNanoseconds

        let closeSetStarted = DispatchTime.now().uptimeNanoseconds
        denseRow.setExpanded(false)
        let closeSetEnded = DispatchTime.now().uptimeNanoseconds
        denseController.view.layoutSubtreeIfNeeded()
        let closeLayoutEnded = DispatchTime.now().uptimeNanoseconds

        let reopenSetStarted = DispatchTime.now().uptimeNanoseconds
        denseRow.setExpanded(true)
        let reopenSetEnded = DispatchTime.now().uptimeNanoseconds
        denseController.view.layoutSubtreeIfNeeded()
        let reopenLayoutEnded = DispatchTime.now().uptimeNanoseconds

        let targetRect = denseController.fileTableView.rect(ofRow: denseTarget)
        let viewport = denseController.scrollView.bounds
        let scrollDistance = max(targetRect.height - viewport.height, 0)
        let scrollFrames = 48
        let scrollBitmap = try XCTUnwrap(
            denseController.scrollView.bitmapImageRepForCachingDisplay(in: viewport)
        )
        var scrollNanoseconds: UInt64 = 0
        var layoutNanoseconds: UInt64 = 0
        var drawNanoseconds: UInt64 = 0
        let scrollStarted = DispatchTime.now().uptimeNanoseconds
        for frame in 0..<scrollFrames {
            let fraction = CGFloat(frame) / CGFloat(max(scrollFrames - 1, 1))
            let frameStarted = DispatchTime.now().uptimeNanoseconds
            denseController.scrollView.contentView.scroll(
                to: NSPoint(x: 0, y: targetRect.minY + scrollDistance * fraction)
            )
            denseController.scrollView.reflectScrolledClipView(
                denseController.scrollView.contentView
            )
            let scrollEnded = DispatchTime.now().uptimeNanoseconds
            denseController.view.layoutSubtreeIfNeeded()
            let layoutEnded = DispatchTime.now().uptimeNanoseconds
            denseController.scrollView.cacheDisplay(in: viewport, to: scrollBitmap)
            let drawEnded = DispatchTime.now().uptimeNanoseconds
            scrollNanoseconds += scrollEnded - frameStarted
            layoutNanoseconds += layoutEnded - scrollEnded
            drawNanoseconds += drawEnded - layoutEnded
        }
        let scrollEnded = DispatchTime.now().uptimeNanoseconds

        print(
            "THREADING_PERF git-review-file-disclosure "
                + "files=174 row=\(denseTarget) lines=\(GitReviewDefaults.fileDisplayCap) "
                + "open_set_ms=\(Self.milliseconds(openSetEnded - openSetStarted)) "
                + "open_layout_ms=\(Self.milliseconds(openLayoutEnded - openSetEnded)) "
                + "close_set_ms=\(Self.milliseconds(closeSetEnded - closeSetStarted)) "
                + "close_layout_ms=\(Self.milliseconds(closeLayoutEnded - closeSetEnded)) "
                + "reopen_set_ms=\(Self.milliseconds(reopenSetEnded - reopenSetStarted)) "
                + "reopen_layout_ms=\(Self.milliseconds(reopenLayoutEnded - reopenSetEnded))"
        )
        print(
            "THREADING_PERF git-review-file-continuous-scroll "
                + "files=174 row=\(denseTarget) lines=\(GitReviewDefaults.fileDisplayCap) "
                + "frames=\(scrollFrames) "
                + "elapsed_ms=\(Self.milliseconds(scrollEnded - scrollStarted)) "
                + "per_frame_ms=\(Self.milliseconds((scrollEnded - scrollStarted) / UInt64(scrollFrames))) "
                + "scroll_ms=\(Self.milliseconds(scrollNanoseconds / UInt64(scrollFrames))) "
                + "layout_ms=\(Self.milliseconds(layoutNanoseconds / UInt64(scrollFrames))) "
                + "draw_ms=\(Self.milliseconds(drawNanoseconds / UInt64(scrollFrames)))"
        )
    }

    /// Thousands of short generated files are a different row-mount shape from either the
    /// 1,000 collapsed headers or 174 maximum-size files above. This matches the reported
    /// accidental-build-output case: roughly 9,000 expanded files and 80,000 added lines.
    func testStressMassiveExpandedFileIndexWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["THREADING_GIT_MASSIVE_STRESS"] == "1",
            "Set THREADING_GIT_MASSIVE_STRESS=1 to run the massive expanded-file sweep."
        )
        let fileCount = environment["THREADING_GIT_MASSIVE_STRESS_FILES"]
            .flatMap(Int.init)
            .map { max($0, 1) }
            ?? 8_985
        let linesPerFile = environment["THREADING_GIT_MASSIVE_STRESS_LINES"]
            .flatMap(Int.init)
            .map { max($0, 1) }
            ?? 9
        let files = Self.stressSmallExpandedFiles(
            count: fileCount,
            linesPerFile: linesPerFile
        )
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)

        let renderStarted = DispatchTime.now().uptimeNanoseconds
        controller.show(.files(files))
        let renderEnded = DispatchTime.now().uptimeNanoseconds
        controller.view.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds

        let table = controller.fileTableView
        let scroll = controller.scrollView
        let viewport = scroll.bounds
        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: viewport))
        let initialDocumentHeight = table.frame.height
        let frames = 120

        // Width changes run through the controller's real `viewDidLayout`, including the
        // complete-index height invalidation used to keep the scrollbar extent honest. A
        // triangle wave avoids measuring the no-op guard at a repeated width.
        let resizeFrames = 48
        var resizeMutationNanoseconds: UInt64 = 0
        var resizeLayoutNanoseconds: UInt64 = 0
        var resizeFrameNanoseconds: [UInt64] = []
        let resizeHost = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let resizeCard = try XCTUnwrap(resizeHost.subviews.first as? GitReviewFileRow)
        let resizeDiff = try XCTUnwrap(
            Self.firstDescendant(of: GitReviewDiffTextView.self, in: resizeCard)
        )
        var previousResizeWidths = [
            scroll.contentView.bounds.width,
            table.bounds.width,
            table.tableColumns[0].width,
            resizeHost.bounds.width,
            resizeCard.bounds.width,
            resizeDiff.bounds.width
        ]
        var maximumResizeWidthDeltaDrift: CGFloat = 0
        var pendingResizeLayoutFrames = 0
        for frame in 0..<resizeFrames {
            let phase = CGFloat(frame) / CGFloat(max(resizeFrames - 1, 1))
            let fraction = phase <= 0.5 ? phase * 2 : (1 - phase) * 2
            let width = 420 + 400 * fraction
            let started = DispatchTime.now().uptimeNanoseconds
            controller.view.setFrameSize(NSSize(width: width, height: 760))
            let mutated = DispatchTime.now().uptimeNanoseconds
            controller.view.layoutSubtreeIfNeeded()
            let laidOut = DispatchTime.now().uptimeNanoseconds
            resizeMutationNanoseconds += mutated - started
            resizeLayoutNanoseconds += laidOut - mutated
            resizeFrameNanoseconds.append(laidOut - started)

            let currentResizeWidths = [
                scroll.contentView.bounds.width,
                table.bounds.width,
                table.tableColumns[0].width,
                resizeHost.bounds.width,
                resizeCard.bounds.width,
                resizeDiff.bounds.width
            ]
            let viewportDelta = currentResizeWidths[0] - previousResizeWidths[0]
            for index in 1..<currentResizeWidths.count {
                let descendantDelta = currentResizeWidths[index] - previousResizeWidths[index]
                maximumResizeWidthDeltaDrift = max(
                    maximumResizeWidthDeltaDrift,
                    abs(descendantDelta - viewportDelta)
                )
            }
            if table.needsLayout || resizeCard.needsLayout {
                pendingResizeLayoutFrames += 1
            }
            previousResizeWidths = currentResizeWidths
        }
        controller.view.setFrameSize(NSSize(width: 620, height: 760))
        controller.view.layoutSubtreeIfNeeded()
        let sortedResizeFrames = resizeFrameNanoseconds.sorted()
        let resizeP95 = sortedResizeFrames[
            min(
                Int(Double(sortedResizeFrames.count - 1) * 0.95),
                sortedResizeFrames.count - 1
            )
        ]
        let resizeWidthDrift = String(format: "%.3f", maximumResizeWidthDeltaDrift)
        func measureSweep(distance: CGFloat) -> (
            scroll: UInt64,
            layout: UInt64,
            draw: UInt64,
            p95: UInt64,
            maximum: UInt64
        ) {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            controller.view.layoutSubtreeIfNeeded()

            var scrollNanoseconds: UInt64 = 0
            var layoutNanoseconds: UInt64 = 0
            var drawNanoseconds: UInt64 = 0
            var frameNanoseconds: [UInt64] = []
            for frame in 0..<frames {
                let fraction = CGFloat(frame) / CGFloat(max(frames - 1, 1))
                let started = DispatchTime.now().uptimeNanoseconds
                scroll.contentView.scroll(to: NSPoint(x: 0, y: distance * fraction))
                scroll.reflectScrolledClipView(scroll.contentView)
                let scrolled = DispatchTime.now().uptimeNanoseconds
                controller.view.layoutSubtreeIfNeeded()
                let laidOut = DispatchTime.now().uptimeNanoseconds
                scroll.cacheDisplay(in: viewport, to: bitmap)
                let drawn = DispatchTime.now().uptimeNanoseconds
                scrollNanoseconds += scrolled - started
                layoutNanoseconds += laidOut - scrolled
                drawNanoseconds += drawn - laidOut
                frameNanoseconds.append(drawn - started)
            }
            let sortedFrames = frameNanoseconds.sorted()
            let p95 = sortedFrames[
                min(Int(Double(sortedFrames.count - 1) * 0.95), sortedFrames.count - 1)
            ]
            return (
                scrollNanoseconds / UInt64(frames),
                layoutNanoseconds / UInt64(frames),
                drawNanoseconds / UInt64(frames),
                p95,
                sortedFrames.last ?? 0
            )
        }

        let maximumDistance = max(table.frame.height - scroll.contentView.bounds.height, 0)
        let continuous = measureSweep(distance: min(
            maximumDistance,
            scroll.contentView.bounds.height * 24
        ))
        controller.beginFileScrollerSeek()
        let fullIndex = measureSweep(distance: maximumDistance)
        let seekSettleStarted = DispatchTime.now().uptimeNanoseconds
        controller.finishFileLiveScrolling()
        controller.view.layoutSubtreeIfNeeded()
        let seekSettleEnded = DispatchTime.now().uptimeNanoseconds

        // Let the deferred exact-height pass catch up. The cheap model estimates are what make
        // a 9,000-file document immediately scrollable; resolving the materialized rows must not
        // substantially rewrite the scrollbar extent once the user is already at the end.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.view.layoutSubtreeIfNeeded()
        let finalDocumentHeight = table.frame.height

        // A build watcher can deliver this shape repeatedly while the user is scrolling. Insert
        // generated files before the current viewport to exercise both incremental row
        // reconciliation and path-relative scroll anchoring, not merely the cold table mount.
        let inserted = Self.stressSmallExpandedFiles(
            count: 12,
            linesPerFile: linesPerFile,
            pathPrefix: "000-Earlier"
        )
        let instantiatedBeforeRefresh = controller.instantiatedFileRowCount
        let refreshStarted = DispatchTime.now().uptimeNanoseconds
        controller.show(.files(inserted + files))
        let refreshEnded = DispatchTime.now().uptimeNanoseconds
        controller.view.layoutSubtreeIfNeeded()
        let refreshLayoutEnded = DispatchTime.now().uptimeNanoseconds

        print(
            "THREADING_PERF git-review-massive-expanded "
                + "files=\(fileCount) lines=\(fileCount * linesPerFile) "
                + "instantiated=\(controller.instantiatedFileRowCount) "
                + "render_ms=\(Self.milliseconds(renderEnded - renderStarted)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - renderEnded)) "
                + "document_delta=\(Int(finalDocumentHeight - initialDocumentHeight))"
        )
        print(
            "THREADING_PERF git-review-massive-resize "
                + "files=\(fileCount) frames=\(resizeFrames) "
                + "mutation_ms="
                + "\(Self.milliseconds(resizeMutationNanoseconds / UInt64(resizeFrames))) "
                + "layout_ms="
                + "\(Self.milliseconds(resizeLayoutNanoseconds / UInt64(resizeFrames))) "
                + "p95_frame_ms=\(Self.milliseconds(resizeP95)) "
                + "max_frame_ms=\(Self.milliseconds(sortedResizeFrames.last ?? 0)) "
                + "max_width_delta_drift=\(resizeWidthDrift) "
                + "pending_layout_frames=\(pendingResizeLayoutFrames)"
        )
        for (kind, measurement) in [("continuous", continuous), ("full-index", fullIndex)] {
            print(
                "THREADING_PERF git-review-massive-scroll "
                    + "kind=\(kind) files=\(fileCount) frames=\(frames) "
                    + "scroll_ms=\(Self.milliseconds(measurement.scroll)) "
                    + "layout_ms=\(Self.milliseconds(measurement.layout)) "
                    + "draw_ms=\(Self.milliseconds(measurement.draw)) "
                    + "p95_frame_ms=\(Self.milliseconds(measurement.p95)) "
                    + "max_frame_ms=\(Self.milliseconds(measurement.maximum))"
            )
        }
        print(
            "THREADING_PERF git-review-massive-seek-settle "
                + "files=\(fileCount) "
                + "elapsed_ms=\(Self.milliseconds(seekSettleEnded - seekSettleStarted)) "
                + "deferred_rows=\(controller.instantiatedDeferredFileRowCount)"
        )
        print(
            "THREADING_PERF git-review-massive-refresh "
                + "old_files=\(fileCount) files=\(fileCount + inserted.count) "
                + "refresh_ms=\(Self.milliseconds(refreshEnded - refreshStarted)) "
                + "layout_ms=\(Self.milliseconds(refreshLayoutEnded - refreshEnded)) "
                + "instantiated_delta="
                + "\(controller.instantiatedFileRowCount - instantiatedBeforeRefresh)"
        )

        XCTAssertEqual(table.numberOfRows, fileCount + inserted.count)
        XCTAssertLessThan(controller.instantiatedFileRowCount, fileCount + inserted.count)
        XCTAssertGreaterThan(controller.instantiatedDeferredFileRowCount, 0)
        XCTAssertLessThanOrEqual(
            maximumResizeWidthDeltaDrift,
            0.5,
            "the visible diff width trailed the viewport during live resize"
        )
        XCTAssertEqual(
            pendingResizeLayoutFrames,
            0,
            "a displayed resize frame left the visible diff geometry pending"
        )
    }

    /// Opt-in end-to-end wall-latency sweep against a real, already-present repository. The
    /// generated fixtures above isolate view scaling; this covers the other half of opening the
    /// pane: spawning the production git reads, walking a large index/history, parsing a real
    /// revision range, and then handing those models to the production table.
    ///
    /// The checkout is read-only. By default the range is `HEAD~100..HEAD`; set explicit
    /// revisions when the repository is shallow or when a known large change is more useful.
    func testStressRealRepositoryWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let repositoryPath = environment["THREADING_GIT_REPOSITORY_STRESS_PATH"],
              !repositoryPath.isEmpty else {
            throw XCTSkip(
                "Set THREADING_GIT_REPOSITORY_STRESS_PATH to an existing checkout."
            )
        }

        let repository = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repository.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "The real-repository stress path is not a directory: \(repository.path)"
        )

        let runs = environment["THREADING_GIT_REPOSITORY_STRESS_RUNS"]
            .flatMap(Int.init)
            .map { max($0, 1) }
            ?? 3
        let base = environment["THREADING_GIT_REPOSITORY_STRESS_BASE"] ?? "HEAD~100"
        let target = environment["THREADING_GIT_REPOSITORY_STRESS_TARGET"] ?? "HEAD"

        // Fail before the measured work if the path or either requested revision is invalid.
        // A shallow clone should supply a nearer base rather than accidentally measuring an
        // empty/fallback comparison.
        for revision in [base, target] {
            _ = try GitProcess.run(
                GitReviewCommands.common + ["rev-parse", "--verify", "\(revision)^{tree}"],
                in: repository,
                maximumOutput: 16 * 1024
            )
        }

        var repositoryFileDurations: [UInt64] = []
        var repositorySingleFileDurations: [UInt64] = []
        var summaryDurations: [UInt64] = []
        var uncommittedDurations: [UInt64] = []
        var historyDurations: [UInt64] = []
        var historyStatsDurations: [UInt64] = []
        var repositoryFileCount = 0
        var uncommittedFileCount = 0
        var historyCount = 0
        var historyCommits: [GitCommitSummary] = []

        for _ in 0..<runs {
            var started = DispatchTime.now().uptimeNanoseconds
            let paths = try awaitGitValue {
                GitReviewReader.repositoryFiles(in: repository, completion: $0)
            }
            repositoryFileDurations.append(DispatchTime.now().uptimeNanoseconds - started)
            repositoryFileCount = paths.count

            if let path = paths.first {
                started = DispatchTime.now().uptimeNanoseconds
                _ = try awaitGitValue {
                    GitReviewReader.repositoryFile(path: path, in: repository, completion: $0)
                }
                repositorySingleFileDurations.append(
                    DispatchTime.now().uptimeNanoseconds - started
                )
            }

            started = DispatchTime.now().uptimeNanoseconds
            _ = try awaitGitValue {
                GitReviewReader.uncommittedSummary(in: repository, completion: $0)
            }
            summaryDurations.append(DispatchTime.now().uptimeNanoseconds - started)

            started = DispatchTime.now().uptimeNanoseconds
            let uncommitted = try awaitGitValue {
                GitReviewReader.diff(.uncommitted, in: repository, completion: $0)
            }
            uncommittedDurations.append(DispatchTime.now().uptimeNanoseconds - started)
            uncommittedFileCount = uncommitted.count

            started = DispatchTime.now().uptimeNanoseconds
            let history = try awaitGitValue {
                GitReviewReader.log(skip: 0, in: repository, completion: $0)
            }
            historyDurations.append(DispatchTime.now().uptimeNanoseconds - started)
            historyCount = history.count
            historyCommits = history

            started = DispatchTime.now().uptimeNanoseconds
            let historyStats = try awaitGitValue {
                GitReviewReader.logStats(skip: 0, in: repository, completion: $0)
            }
            historyStatsDurations.append(DispatchTime.now().uptimeNanoseconds - started)
            historyCommits = historyStats
        }

        Self.printRealRepositoryMetric(
            "git-repository-files",
            durations: repositoryFileDurations,
            fields: "paths=\(repositoryFileCount)"
        )
        if !repositorySingleFileDurations.isEmpty {
            Self.printRealRepositoryMetric(
                "git-repository-single-file",
                durations: repositorySingleFileDurations,
                fields: "paths=\(repositoryFileCount)"
            )
        }
        Self.printRealRepositoryMetric(
            "git-repository-summary",
            durations: summaryDurations,
            fields: "paths=\(repositoryFileCount)"
        )
        Self.printRealRepositoryMetric(
            "git-repository-uncommitted",
            durations: uncommittedDurations,
            fields: "paths=\(repositoryFileCount) files=\(uncommittedFileCount)"
        )
        Self.printRealRepositoryMetric(
            "git-repository-history",
            durations: historyDurations,
            fields: "paths=\(repositoryFileCount) commits=\(historyCount) statistics=deferred"
        )
        Self.printRealRepositoryMetric(
            "git-repository-history-stats",
            durations: historyStatsDurations,
            fields: "paths=\(repositoryFileCount) commits=\(historyCount)"
        )

        let historyController = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: repository.path,
            mode: .commit
        )
        _ = historyController.view
        historyController.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        historyController.commits = historyCommits

        let historyRenderStarted = DispatchTime.now().uptimeNanoseconds
        historyController.show(.commits(canLoadMore: historyCount == GitReviewDefaults.logPageSize))
        let historyRenderEnded = DispatchTime.now().uptimeNanoseconds
        historyController.view.layoutSubtreeIfNeeded()
        let historyLayoutEnded = DispatchTime.now().uptimeNanoseconds

        let historyViewport = historyController.scrollView.bounds
        if let bitmap = historyController.scrollView.bitmapImageRepForCachingDisplay(in: historyViewport) {
            historyController.scrollView.cacheDisplay(in: historyViewport, to: bitmap)
        }
        let historyDrawEnded = DispatchTime.now().uptimeNanoseconds

        let historySeekStarted = DispatchTime.now().uptimeNanoseconds
        let historyDocumentHeight = historyController.historyTableView.frame.height
        historyController.scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: max(historyDocumentHeight - historyViewport.height, 0)
        ))
        historyController.scrollView.reflectScrolledClipView(historyController.scrollView.contentView)
        historyController.view.layoutSubtreeIfNeeded()
        if let bitmap = historyController.scrollView.bitmapImageRepForCachingDisplay(in: historyViewport) {
            historyController.scrollView.cacheDisplay(in: historyViewport, to: bitmap)
        }
        let historySeekEnded = DispatchTime.now().uptimeNanoseconds

        print(
            "THREADING_PERF git-repository-history-view "
                + "commits=\(historyCount) rows=\(historyController.historyTableView.numberOfRows) "
                + "instantiated=\(historyController.instantiatedCommitRowCount) "
                + "render_ms=\(Self.milliseconds(historyRenderEnded - historyRenderStarted)) "
                + "layout_ms=\(Self.milliseconds(historyLayoutEnded - historyRenderEnded)) "
                + "draw_ms=\(Self.milliseconds(historyDrawEnded - historyLayoutEnded)) "
                + "bottom_seek_ms=\(Self.milliseconds(historySeekEnded - historySeekStarted))"
        )

        var indexDurations: [UInt64] = []
        var statsDurations: [UInt64] = []
        var visibleHydrationDurations: [UInt64] = []
        var commandDurations: [UInt64] = []
        var parseDurations: [UInt64] = []
        var rangeIndexFiles: [GitFileDiff] = []
        var rangeFiles: [GitFileDiff] = []
        var diffBytes = 0
        for _ in 0..<runs {
            var commandStarted = DispatchTime.now().uptimeNanoseconds
            let indexData = try GitProcess.run(
                GitReviewCommands.common + GitReviewCommands.diffIndex(
                    from: base,
                    to: target
                ),
                in: repository,
                maximumOutput: GitReviewDefaults.maximumDiffBytes
            )
            rangeIndexFiles = GitDiffParser.files(fromRawDiff: indexData)
            indexDurations.append(DispatchTime.now().uptimeNanoseconds - commandStarted)

            commandStarted = DispatchTime.now().uptimeNanoseconds
            _ = GitDiffParser.fileStats(fromNumstat: try GitProcess.run(
                GitReviewCommands.common + GitReviewCommands.diffNumstat(
                    from: base,
                    to: target
                ),
                in: repository,
                maximumOutput: GitReviewDefaults.maximumDiffBytes
            ))
            statsDurations.append(DispatchTime.now().uptimeNanoseconds - commandStarted)

            let visiblePaths = Array(Set(rangeIndexFiles
                .prefix(GitReviewDefaults.progressiveDiffHydrationBatch)
                .flatMap { file -> [String] in
                    if case .renamed(let from) = file.change { return [from, file.path] }
                    return [file.path]
                })).sorted()
            if !visiblePaths.isEmpty {
                commandStarted = DispatchTime.now().uptimeNanoseconds
                _ = try GitProcess.run(
                    GitReviewCommands.common + GitReviewCommands.diff(
                        from: base,
                        to: target,
                        paths: visiblePaths
                    ),
                    in: repository,
                    maximumOutput: GitReviewDefaults.maximumDiffBytes
                )
                visibleHydrationDurations.append(
                    DispatchTime.now().uptimeNanoseconds - commandStarted
                )
            }

            commandStarted = DispatchTime.now().uptimeNanoseconds
            let data: Data
            do {
                data = try GitProcess.run(
                    GitReviewCommands.common + GitReviewCommands.diff(
                        from: base,
                        to: target
                    ),
                    in: repository,
                    maximumOutput: GitReviewDefaults.maximumDiffBytes
                )
            } catch GitFailure.outputTooLarge {
                let elapsed = DispatchTime.now().uptimeNanoseconds - commandStarted
                print(
                    "THREADING_PERF git-repository-range "
                        + "paths=\(repositoryFileCount) "
                        + "result=output-too-large limit_bytes=\(GitReviewDefaults.maximumDiffBytes) "
                        + "elapsed_ms=\(Self.milliseconds(elapsed))"
                )
                return
            }
            let commandEnded = DispatchTime.now().uptimeNanoseconds
            let parsed = GitDiffParser.files(fromUnifiedDiff: GitDiffParser.decode(data))
            let parseEnded = DispatchTime.now().uptimeNanoseconds
            commandDurations.append(commandEnded - commandStarted)
            parseDurations.append(parseEnded - commandEnded)
            diffBytes = data.count
            rangeFiles = parsed
        }

        let changedLines = rangeFiles.lazy.reduce(into: 0) { count, file in
            count += file.hunks.lazy.reduce(into: 0) { $0 += $1.lines.count }
        }
        let rangeFields = "paths=\(repositoryFileCount) files=\(rangeFiles.count) "
            + "lines=\(changedLines) bytes=\(diffBytes)"
        Self.printRealRepositoryMetric(
            "git-repository-range-index",
            durations: indexDurations,
            fields: "paths=\(repositoryFileCount) files=\(rangeIndexFiles.count)"
        )
        Self.printRealRepositoryMetric(
            "git-repository-range-stats",
            durations: statsDurations,
            fields: "paths=\(repositoryFileCount) files=\(rangeIndexFiles.count)"
        )
        if !visibleHydrationDurations.isEmpty {
            Self.printRealRepositoryMetric(
                "git-repository-range-visible-hydration",
                durations: visibleHydrationDurations,
                fields: "paths=\(repositoryFileCount) batch="
                    + "\(GitReviewDefaults.progressiveDiffHydrationBatch)"
            )
        }
        Self.printRealRepositoryMetric(
            "git-repository-range-command",
            durations: commandDurations,
            fields: rangeFields
        )
        Self.printRealRepositoryMetric(
            "git-repository-range-parse",
            durations: parseDurations,
            fields: rangeFields
        )

        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: repository.path,
            mode: .uncommitted
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)

        let renderStarted = DispatchTime.now().uptimeNanoseconds
        controller.show(.files(rangeFiles))
        let renderEnded = DispatchTime.now().uptimeNanoseconds
        controller.view.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds

        let viewport = controller.scrollView.bounds
        if let bitmap = controller.scrollView.bitmapImageRepForCachingDisplay(in: viewport) {
            controller.scrollView.cacheDisplay(in: viewport, to: bitmap)
        }
        let drawEnded = DispatchTime.now().uptimeNanoseconds

        let seekStarted = DispatchTime.now().uptimeNanoseconds
        if !rangeFiles.isEmpty {
            controller.fileTableView.scrollRowToVisible(rangeFiles.count - 1)
            controller.view.layoutSubtreeIfNeeded()
            if let bitmap = controller.scrollView.bitmapImageRepForCachingDisplay(in: viewport) {
                controller.scrollView.cacheDisplay(in: viewport, to: bitmap)
            }
        }
        let seekEnded = DispatchTime.now().uptimeNanoseconds

        print(
            "THREADING_PERF git-repository-range-view "
                + "paths=\(repositoryFileCount) files=\(rangeFiles.count) lines=\(changedLines) "
                + "instantiated=\(controller.instantiatedFileRowCount) "
                + "render_ms=\(Self.milliseconds(renderEnded - renderStarted)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - renderEnded)) "
                + "draw_ms=\(Self.milliseconds(drawEnded - layoutEnded)) "
                + "bottom_seek_ms=\(Self.milliseconds(seekEnded - seekStarted))"
        )
        XCTAssertEqual(controller.fileTableView.numberOfRows, rangeFiles.count)
    }

    // MARK: - The Pane's Own Ordering

    /// **The diff arrives after the pane is laid out, and the cards still span it.**
    ///
    /// Every other test here sets `view.frame` and *then* renders, which lays the pane out with
    /// the file table already installed. The app never does that: git runs off the main thread,
    /// so the pane is sized, drawn and idle for a beat before `documentView = fileTableView`.
    /// A document-view swap deep inside a scroll view does not lay out the controller's root
    /// view, so `viewDidLayout` — which was the only thing calling `sizeLastColumnToFit()` — was
    /// never called, and the sole column kept `NSTableColumn`'s 100pt default. The pane, the
    /// header, the counters and the table were all the pane's full width; only the cells were
    /// not, and 76pt-wide cards wrapped source code three characters to a line for the whole
    /// height of the window. `SoleColumnFit` is the fix, and this ordering is the test.
    func testFileCardsSpanThePaneWhenTheDiffArrivesAfterLayout() throws {
        let paneWidth: CGFloat = 900
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let content = try XCTUnwrap(window.contentView)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: content.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])

        // Laid out — and settled — before there is anything to show, exactly as the pane is
        // while git reads the checkout.
        window.layoutIfNeeded()
        XCTAssertEqual(controller.view.bounds.width, paneWidth, accuracy: 0.5)

        controller.show(.files(Self.stressExpandableFiles(count: 40)))
        window.layoutIfNeeded()

        let table = controller.fileTableView
        XCTAssertEqual(
            table.tableColumns[0].width, table.bounds.width, accuracy: 0.5,
            "the file table's sole column did not follow the table's width"
        )

        let host = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let card = try XCTUnwrap(host.subviews.first as? GitReviewFileRow)
        let cardFrame = card.convert(card.bounds, to: controller.view)
        XCTAssertEqual(
            cardFrame.minX, Design.Spacing.inset, accuracy: 0.5,
            "a file card should start on the pane's own margin"
        )
        XCTAssertEqual(
            cardFrame.maxX, paneWidth - Design.Spacing.inset, accuracy: 0.5,
            "a file card should end on the pane's own margin, not at a default column width"
        )

        // And the diff inside it, which is what the reader actually sees wrapped to a ribbon.
        let diff = try XCTUnwrap(Self.firstDescendant(of: GitReviewDiffTextView.self, in: card))
        XCTAssertEqual(
            diff.convert(diff.bounds, to: controller.view).width, cardFrame.width, accuracy: 0.5,
            "the diff did not use the full width of its card"
        )
    }

    // MARK: - Find

    func testFindIndexSearchesOnlyDestinationsThePaneCanReveal() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)

        let path = GitReviewFindIndex.results(in: files, matching: "foo.swift")
        XCTAssertEqual(path.matches.count, 1)
        XCTAssertEqual(path.matches.first?.location, .path)

        let hunk = GitReviewFindIndex.results(in: files, matching: "-10,2")
        XCTAssertEqual(hunk.matches.count, 1)
        XCTAssertEqual(hunk.matches.first?.location, .hunk(1))

        let lines = GitReviewFindIndex.results(in: files, matching: "new")
        XCTAssertEqual(lines.matches.map(\.text), ["new line", "newer"])
        XCTAssertEqual(
            lines.matches.map(\.location),
            [
                .line(
                    hunk: 0,
                    line: 2,
                    range: GitReviewFindMatch.TextRange(location: 0, length: 3)
                ),
                .line(
                    hunk: 1,
                    line: 1,
                    range: GitReviewFindMatch.TextRange(location: 0, length: 3)
                )
            ]
        )
    }

    func testFindIndexDoesNotReturnTextPastTheFileDisplayCap() {
        let lines = (0...GitReviewDefaults.fileDisplayCap).map { index in
            GitDiffLine(
                kind: .added,
                text: index == GitReviewDefaults.fileDisplayCap
                    ? "hidden destination"
                    : "visible line \(index)",
                oldNumber: nil,
                newNumber: index + 1
            )
        }
        let file = GitFileDiff(
            path: "Large.swift",
            change: .modified,
            hunks: [GitHunk(header: "@@ -0,0 +1,401 @@", lines: lines)],
            added: lines.count,
            removed: 0
        )

        XCTAssertTrue(
            GitReviewFindIndex.results(in: [file], matching: "hidden destination")
                .matches.isEmpty
        )
    }

    func testFindIndexStatesWhenItsNavigationListWasCapped() {
        let results = GitReviewFindIndex.results(
            in: Self.stressExpandableFiles(count: 4),
            matching: "newValue",
            limit: 2
        )

        XCTAssertEqual(results.matches.count, 2)
        XCTAssertTrue(results.isTruncated)
    }

    func testFindBarBelongsToTheReviewPaneBelowItsSafeArea() {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(host)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            host.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        controller.show(.files(files))
        controller.showFind()
        window.layoutIfNeeded()

        XCTAssertTrue(controller.isFindBarVisible)
        XCTAssertTrue(controller.findBar.superview === controller.view)
        let barFrame = controller.findBar.convert(controller.findBar.bounds, to: controller.view)
        XCTAssertLessThanOrEqual(
            barFrame.maxY,
            controller.view.safeAreaRect.maxY,
            "Review Find must not enter the full-size window's titlebar strip"
        )
    }

    // MARK: - Stress Fixtures

    private static func stressFiles(count: Int) -> [GitFileDiff] {
        (0..<count).map { index in
            GitFileDiff(
                path: "Sources/Generated/Feature\(index)/ChangedFile\(index).swift",
                change: .binary,
                hunks: [],
                added: index % 17,
                removed: index % 11
            )
        }
    }

    private static func stressExpandableFiles(count: Int) -> [GitFileDiff] {
        (0..<count).map { index in
            let line = index + 2
            return GitFileDiff(
                path: "Sources/Generated/Feature\(index)/ChangedFile\(index).swift",
                change: .modified,
                hunks: [
                    GitHunk(
                        header: "@@ -\(line),2 +\(line),2 @@",
                        lines: [
                            GitDiffLine(
                                kind: .removed,
                                text: "let oldValue = \(index)",
                                oldNumber: line,
                                newNumber: nil
                            ),
                            GitDiffLine(
                                kind: .added,
                                text: "let newValue = \(index)",
                                oldNumber: nil,
                                newNumber: line
                            )
                        ]
                    )
                ],
                added: 1,
                removed: 1
            )
        }
    }

    private static func stressDenseFiles(count: Int, linesPerFile: Int) -> [GitFileDiff] {
        (0..<count).map { fileIndex in
            let lines = (0..<linesPerFile).map { lineIndex in
                let number = lineIndex + 1
                let kind: GitDiffLine.Kind = switch lineIndex % 5 {
                case 0: .removed
                case 1: .added
                default: .context
                }
                return GitDiffLine(
                    kind: kind,
                    text: "let generatedValue\(lineIndex) = Feature\(fileIndex).value + \(lineIndex)",
                    oldNumber: kind == .added ? nil : number,
                    newNumber: kind == .removed ? nil : number
                )
            }
            return GitFileDiff(
                path: "Sources/Generated/Feature\(fileIndex)/DenseChangedFile\(fileIndex).swift",
                change: .modified,
                hunks: [GitHunk(header: "@@ -1,\(linesPerFile) +1,\(linesPerFile) @@", lines: lines)],
                added: lines.lazy.filter { $0.kind == .added }.count,
                removed: lines.lazy.filter { $0.kind == .removed }.count
            )
        }
    }

    private static func stressSmallExpandedFiles(
        count: Int,
        linesPerFile: Int,
        pathPrefix: String = "tmp/BuildProducts"
    ) -> [GitFileDiff] {
        (0..<count).map { fileIndex in
            let lines = (0..<linesPerFile).map { lineIndex in
                GitDiffLine(
                    kind: .added,
                    text: "generated artifact \(fileIndex)-\(lineIndex) records a representative build value and its dependency fingerprint",
                    oldNumber: nil,
                    newNumber: lineIndex + 1
                )
            }
            return GitFileDiff(
                path: "\(pathPrefix)/Shard\(fileIndex / 100)/artifact-\(fileIndex).json",
                change: .untracked,
                hunks: [GitHunk(
                    header: "@@ -0,0 +1,\(linesPerFile) @@",
                    lines: lines
                )],
                added: linesPerFile,
                removed: 0
            )
        }
    }

    private static func firstDescendant<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> View? {
        for child in root.subviews {
            if let match = child as? View { return match }
            if let match = firstDescendant(of: type, in: child) { return match }
        }
        return nil
    }

    private static func descendants<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> [View] {
        root.subviews.flatMap { child -> [View] in
            let current = (child as? View).map { [$0] } ?? []
            return current + descendants(of: type, in: child)
        }
    }

    private func awaitGitValue<Value>(
        _ work: (@escaping @MainActor @Sendable (Result<Value, GitFailure>) -> Void) -> Void
    ) throws -> Value {
        let finished = expectation(description: "real repository git operation")
        var outcome: Result<Value, GitFailure>?
        work { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)

        switch try XCTUnwrap(outcome) {
        case .success(let value): return value
        case .failure(let failure): throw failure
        }
    }

    private static func printRealRepositoryMetric(
        _ name: String,
        durations: [UInt64],
        fields: String
    ) {
        guard let first = durations.first else { return }
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(Int(Double(sorted.count - 1) * 0.95), sorted.count - 1)]
        print(
            "THREADING_PERF \(name) \(fields) runs=\(durations.count) "
                + "first_ms=\(milliseconds(first)) median_ms=\(milliseconds(median)) "
                + "p95_ms=\(milliseconds(p95)) max_ms=\(milliseconds(sorted.last ?? first))"
        )
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }
}
