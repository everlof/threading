import AppKit
import XCTest
@testable import Threading

/// The changed-files card's own behaviour: where the tree spends its horizontal room, and the
/// diff preview a file row answers with under the pointer.
///
/// Presentation is deliberately not driven here. `ThemedPopover.show` orders a panel on screen,
/// and the card builds its surface apart from the gesture that presents it for exactly that
/// reason — the same split `SessionRowView.makeSessionHoverCard` makes.
@MainActor
final class ChangedFilesCardTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTree(_ files: [(String, Int, Int)]) -> ChangedFilesTree {
        ChangedFilesTree.build(from: files.map {
            ChangedFilesTree.File(path: $0.0, added: $0.1, removed: $0.2)
        })
    }

    private func makeDiff(path: String, lines: Int, hunks: Int = 1) -> GitFileDiff {
        GitFileDiff(
            path: path,
            change: .modified,
            hunks: (0..<hunks).map { hunk in
                GitHunk(
                    header: "@@ -1,\(lines) +1,\(lines) @@",
                    lines: (0..<lines).map {
                        GitDiffLine(
                            kind: $0.isMultiple(of: 2) ? .added : .context,
                            text: "let value\($0) = \(hunk)",
                            newNumber: $0 + 1
                        )
                    }
                )
            },
            added: lines,
            removed: 0
        )
    }

    /// A card in a container that states its width the way the conversation pane does. A
    /// detached fixture with only a frame pins nothing, and its rows lay out at the width they
    /// would prefer rather than the one they will ship at.
    private func makeCard(
        tree: ChangedFilesTree,
        previews: [String: ChangedFileDiffPreview] = [:]
    ) -> ChangedFilesCardView {
        let card = ChangedFilesCardView(tree: tree, previews: previews, onViewDiff: {})
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 640),
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return card
    }

    /// The label drawing a node's name, found by its text so the assertion names the row the
    /// way the reader does.
    private func nameLabel(_ name: String, in card: ChangedFilesCardView) throws -> NSTextField {
        let labels = card.descendantTextFields.filter { $0.stringValue == name }
        return try XCTUnwrap(labels.first, "No row is drawing \"\(name)\"")
    }

    /// Where a label's *ink* starts, which is what indentation is read off. Auto Layout
    /// constrains alignment rects, and `NSTextField` keeps two points of frame outside its own:
    /// measuring frames reports every row two points left of where it was placed.
    private func leadingEdge(of view: NSView, in card: ChangedFilesCardView) -> CGFloat {
        guard let superview = view.superview else { return view.frame.minX }
        return superview.convert(view.alignmentRect(forFrame: view.frame), to: card).minX
    }

    // MARK: - Geometry

    func testAFilesNameStartsOneIndentStepRightOfItsDirectory() throws {
        let card = makeCard(tree: makeTree([("Tests/ThreadingTests/ThemedControlTests.swift", 4, 1)]))

        let directory = try nameLabel("Tests/ThreadingTests", in: card)
        let file = try nameLabel("ThemedControlTests.swift", in: card)

        XCTAssertEqual(
            leadingEdge(of: file, in: card) - leadingEdge(of: directory, in: card),
            ChangedFilesCardDefaults.indentStep,
            accuracy: 0.5,
            "A directory's files should begin exactly one indent step right of its own name"
        )
    }

    func testEveryNameSpendsOneMarkColumnAndNotTwo() throws {
        // The lead-in is the chevron's column, once. A second glyph beside it charged every row
        // in the tree the width of a mark that said what the chevron already said.
        let card = makeCard(tree: makeTree([("src/index.ts", 2, 0)]))

        let directory = try nameLabel("src", in: card)
        let cardInset = Design.Spacing.medium

        XCTAssertEqual(
            leadingEdge(of: directory, in: card) - cardInset,
            ChangedFilesCardDefaults.markColumn,
            accuracy: 0.5
        )
        XCTAssertLessThan(
            ChangedFilesCardDefaults.markColumn,
            2 * Design.Chat.toolIconWidth,
            "A row's lead-in is one glyph column wide"
        )
    }

    func testADeepTreeStaysReadableAtItsDeepestRow() throws {
        // Four levels of a real path: the deepest name still starts well inside the card,
        // which is what the indentation is for and what it stops being when it is too wide.
        let card = makeCard(tree: makeTree([
            ("Sources/a.swift", 1, 0),
            ("Sources/Threading/UI/Views/Deep.swift", 1, 0)
        ]))

        let deepest = try nameLabel("Deep.swift", in: card)
        XCTAssertLessThan(leadingEdge(of: deepest, in: card), 80)
    }

    // MARK: - Preview

    func testOnlyAFileWithADiffOffersAPreview() throws {
        let tree = makeTree([
            ("src/index.ts", 2, 0),
            ("src/icon.png", 0, 0)
        ])
        let card = makeCard(tree: tree, previews: ChangedFileDiffPreview.previews(from: [
            makeDiff(path: "src/index.ts", lines: 6),
            GitFileDiff(path: "src/icon.png", change: .binary, hunks: [], added: 0, removed: 0)
        ]))

        let directory = try XCTUnwrap(tree.nodes.firstIndex { $0.name == "src" })
        let source = try XCTUnwrap(tree.nodes.firstIndex { $0.name == "index.ts" })
        let binary = try XCTUnwrap(tree.nodes.firstIndex { $0.name == "icon.png" })

        XCTAssertNil(card.preview(forNodeAt: directory), "A directory has no diff of its own")
        XCTAssertNil(card.preview(forNodeAt: binary), "A binary file has nothing to draw")
        XCTAssertEqual(card.preview(forNodeAt: source)?.path, "src/index.ts")
    }

    func testACardBuiltWithoutDiffsOffersNoPreviewAtAll() {
        // Every card built before the previews existed, and any built from a diff that could
        // not be read: the tree still draws, the pointer just answers nothing.
        let card = makeCard(tree: makeTree([("README.md", 1, 0)]))
        XCTAssertNil(card.preview(forNodeAt: 0))
    }

    func testThePreviewDrawsTheDiffAndSaysWhatTheCapLeftOut() throws {
        let preview = ChangedFileDiffPreview.preview(
            of: makeDiff(path: "src/index.ts", lines: 30, hunks: 2),
            lineCap: 40
        )
        let card = makeCard(tree: makeTree([("src/index.ts", 30, 0)]))

        let surface = card.makePreviewSurface(for: preview)
        surface.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            surface.view.accessibilityIdentifier(),
            "conversation.changed-file-diff"
        )
        XCTAssertEqual(
            surface.view.fittingSize.width,
            ChangedFilesCardDefaults.previewContentWidth + 2 * Design.Spacing.medium,
            accuracy: 0.5
        )
        XCTAssertFalse(
            surface.view.descendants(ofType: GitReviewDiffTextView.self).isEmpty,
            "The preview draws the diff with Git Review's own renderer"
        )

        let text = surface.view.descendantTextFields.map(\.stringValue)
        XCTAssertTrue(text.contains("src/index.ts"), "The preview names the file it is showing")
        XCTAssertTrue(
            text.contains { $0.contains("20 more lines") },
            "A preview cut off by the capture cap says so: \(text)"
        )
    }

    func testTheScrollingPreviewStopsGrowingAtItsCeiling() throws {
        let short = ChangedFileDiffPreview.preview(of: makeDiff(path: "a.swift", lines: 3))
        let long = ChangedFileDiffPreview.preview(of: makeDiff(path: "a.swift", lines: 300))
        let card = makeCard(tree: makeTree([("a.swift", 3, 0)]))

        let shortScroll = try laidOutScroll(of: card.makePreviewSurface(for: short))
        let longScroll = try laidOutScroll(of: card.makePreviewSurface(for: long))

        XCTAssertLessThan(
            shortScroll.frame.height,
            ChangedFilesCardDefaults.previewMaximumHeight,
            "A three-line change should not open a full-height surface"
        )
        XCTAssertEqual(
            longScroll.frame.height,
            ChangedFilesCardDefaults.previewMaximumHeight,
            accuracy: 0.5,
            "Past its ceiling the preview scrolls instead of growing"
        )
        XCTAssertGreaterThan(
            longScroll.documentView?.fittingSize.height ?? 0,
            longScroll.frame.height,
            "…and there is more document than viewport, or nothing scrolls"
        )
    }

    /// The preview laid out the way the popover lays it out: at the width it states for itself.
    private func laidOutScroll(of surface: NSViewController) throws -> ThemedScrollView {
        let host = NSView()
        host.addSubview(surface.view)
        NSLayoutConstraint.activate([
            surface.view.topAnchor.constraint(equalTo: host.topAnchor),
            surface.view.leadingAnchor.constraint(equalTo: host.leadingAnchor)
        ])
        host.frame = NSRect(origin: .zero, size: surface.view.fittingSize)
        host.layoutSubtreeIfNeeded()
        return try XCTUnwrap(surface.view.descendants(ofType: ThemedScrollView.self).first)
    }

    // MARK: - Hover

    func testARowLightsUpOnlyWhenItAnswersThePointer() throws {
        let tree = makeTree([
            ("src/index.ts", 2, 0),
            ("src/icon.png", 0, 0)
        ])
        let card = makeCard(tree: tree, previews: ChangedFileDiffPreview.previews(from: [
            makeDiff(path: "src/index.ts", lines: 6),
            GitFileDiff(path: "src/icon.png", change: .binary, hunks: [], added: 0, removed: 0)
        ]))

        let rows = card.descendants(ofType: ChangedFilesRowView.self)
        func row(named name: String) throws -> ChangedFilesRowView {
            try XCTUnwrap(rows.first { tree.nodes[$0.nodeIndex].name == name })
        }

        // A directory folds under a click and a file with a diff previews it: both answer.
        for name in ["src", "index.ts"] {
            let row = try row(named: name)
            row.setHovered(true)
            XCTAssertTrue(row.isHovered, "\(name) should take the hover")
            row.setHovered(false)
            XCTAssertFalse(row.isHovered)
        }

        let binary = try row(named: "icon.png")
        binary.setHovered(true)
        XCTAssertFalse(
            binary.isHovered,
            "A row with nothing to show takes no tracking and promises nothing"
        )
    }

    func testALargeFlatTreeBindsOnlyTheOuterViewportsRows() {
        let tree = makeTree((0..<1_000).map { index in
            (String(format: "File%04d.swift", index), 1, 0)
        })
        let card = ChangedFilesCardView(tree: tree, onViewDiff: {})
        let viewport = NSRect(x: 0, y: 0, width: 640, height: 700)
        let host = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: viewport.width,
            height: card.fittingSize.height
        ))
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        let scroll = ThemedScrollView(frame: viewport)
        scroll.contentView = FlippedClipView()
        scroll.documentView = host
        let window = NSWindow(
            contentRect: viewport,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        host.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()

        // Large flat trees defer their data source until this outer clip has committed its
        // viewport. Let that main-queue bind run, then ask how much AppKit actually retained.
        let didBind = expectation(description: "bind behind outer viewport layout")
        DispatchQueue.main.async { didBind.fulfill() }
        wait(for: [didBind], timeout: 1)
        host.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()

        XCTAssertEqual(card.presentedNodeCountForTesting, tree.nodes.count)
        XCTAssertGreaterThan(card.materializedRowCountForTesting, 0)
        XCTAssertLessThanOrEqual(card.materializedRowCountForTesting, 80)

        let initialRows = Set(card.materializedNodeIndicesForTesting)
        scroll.contentView.scroll(to: NSPoint(
            x: 0,
            y: ChangedFilesCardDefaults.rowStride * 500
        ))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        scroll.displayIfNeeded()

        let didScroll = expectation(description: "recycle rows at the outer scroll position")
        DispatchQueue.main.async { didScroll.fulfill() }
        wait(for: [didScroll], timeout: 1)
        scroll.layoutSubtreeIfNeeded()
        scroll.displayIfNeeded()

        let deepRows = Set(card.materializedNodeIndicesForTesting)
        XCTAssertLessThanOrEqual(deepRows.count, 80)
        XCTAssertTrue(deepRows.contains { $0 >= 400 })
        XCTAssertTrue(initialRows.isDisjoint(with: deepRows))
        withExtendedLifetime(window) {}
    }

    // MARK: - Performance

    /// Exercises the production card at scales a hand-authored unit fixture never reaches.
    ///
    /// `collapsed` isolates the tree's retained-view cost: the card starts folded and must keep
    /// its AppKit working set bounded after expansion. `previews` also gives every file a diff
    /// larger than the production capture cap, separating the aggregate preview-model budget
    /// from the virtual row cost. Expansion is timed because it is the mutation a reader can
    /// actually feel after the cold card appears.
    func testStressChangedFilesCardWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["THREADING_CHANGED_FILES_STRESS"] == "1",
            "Set THREADING_CHANGED_FILES_STRESS=1 to run the changed-files card sweep."
        )

        enum Shape: String {
            case collapsed
            case previews
        }

        let fileCount = environment["THREADING_CHANGED_FILES_STRESS_FILES"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 1_000
        let shape = Shape(
            rawValue: environment["THREADING_CHANGED_FILES_STRESS_SHAPE"] ?? "collapsed"
        ) ?? .collapsed
        let linesPerFile = environment["THREADING_CHANGED_FILES_STRESS_LINES"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? ChangedFilesDefaults.previewLineCap
        let themeID = AppThemeID(
            environment["THREADING_CHANGED_FILES_STRESS_THEME"] ?? "system"
        )
        let theme = try XCTUnwrap(
            AppThemeLibrary.theme(withID: themeID),
            "Unknown stress theme \(themeID.rawValue)"
        )
        _ = NSApplication.shared
        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(theme)
        defer { AppThemeLibrary.apply(previousTheme) }

        let baselineMemory = Self.physicalFootprintBytes()
        let fixtureStarted = DispatchTime.now().uptimeNanoseconds
        var files: [ChangedFilesTree.File]? = (0..<fileCount).map { index in
            ChangedFilesTree.File(
                path: String(format: "Sources/Stress/File%05d.swift", index),
                added: shape == .previews ? linesPerFile : 1,
                removed: index.isMultiple(of: 7) ? 1 : 0
            )
        }
        var diffs: [GitFileDiff]? = shape == .previews
            ? (0..<fileCount).map { index in
                makeDiff(
                    path: String(format: "Sources/Stress/File%05d.swift", index),
                    lines: linesPerFile + 25
                )
            }
            : nil
        let fixtureEnded = DispatchTime.now().uptimeNanoseconds

        let treeStarted = DispatchTime.now().uptimeNanoseconds
        let tree = ChangedFilesTree.build(from: files ?? [])
        let treeEnded = DispatchTime.now().uptimeNanoseconds
        let previews = ChangedFileDiffPreview.previews(from: diffs ?? [])
        let previewsEnded = DispatchTime.now().uptimeNanoseconds
        files = nil
        diffs = nil
        let modelMemory = Self.physicalFootprintBytes()

        let constructStarted = DispatchTime.now().uptimeNanoseconds
        let card = ChangedFilesCardView(tree: tree, previews: previews, onViewDiff: {})
        let constructEnded = DispatchTime.now().uptimeNanoseconds

        let viewport = NSRect(x: 0, y: 0, width: 640, height: 700)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 1))
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        let clip = FlippedClipView()
        clip.drawsBackground = false
        let scroll = ThemedScrollView(frame: viewport)
        scroll.contentView = clip
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = host
        let window = NSWindow(
            contentRect: viewport,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll

        func layoutDocument() {
            host.frame.size = NSSize(width: viewport.width, height: card.fittingSize.height)
            host.layoutSubtreeIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            card.layoutSubtreeIfNeeded()
        }
        layoutDocument()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds

        let initialLogicalRows = card.presentedNodeCountForTesting
        let initialRowViews = card.materializedRowCountForTesting
        let expandButton = try XCTUnwrap(
            card.descendants(ofType: ThemedButton.self).first { $0.title == "Expand all" },
            "a large card should start collapsed"
        )

        let expandStarted = DispatchTime.now().uptimeNanoseconds
        expandButton.performClick()
        let expandUpdated = DispatchTime.now().uptimeNanoseconds
        layoutDocument()
        let expandLaidOut = DispatchTime.now().uptimeNanoseconds
        let expandedLogicalRows = card.presentedNodeCountForTesting
        let expandedRowViews = card.materializedRowCountForTesting

        let collapseStarted = DispatchTime.now().uptimeNanoseconds
        expandButton.performClick()
        let collapseUpdated = DispatchTime.now().uptimeNanoseconds
        layoutDocument()
        let collapseLaidOut = DispatchTime.now().uptimeNanoseconds
        let collapsedRowViews = card.materializedRowCountForTesting
        let viewMemory = Self.physicalFootprintBytes()
        let retainedPreviewLines = previews.values.reduce(0) { total, preview in
            total + preview.hunks.reduce(0) { $0 + $1.lines.count }
        }

        print(
            "THREADING_PERF changed-files-card "
                + "theme=\(themeID.rawValue) shape=\(shape.rawValue) files=\(fileCount) "
                + "lines_per_file=\(shape == .previews ? linesPerFile : 0) "
                + "nodes=\(tree.nodes.count) previews=\(previews.count) "
                + "retained_preview_lines=\(retainedPreviewLines) "
                + "fixture_ms=\(Self.milliseconds(fixtureEnded - fixtureStarted)) "
                + "tree_ms=\(Self.milliseconds(treeEnded - treeStarted)) "
                + "previews_ms=\(Self.milliseconds(previewsEnded - treeEnded)) "
                + "construct_ms=\(Self.milliseconds(constructEnded - constructStarted)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - constructEnded)) "
                + "expand_update_ms=\(Self.milliseconds(expandUpdated - expandStarted)) "
                + "expand_layout_ms=\(Self.milliseconds(expandLaidOut - expandUpdated)) "
                + "collapse_update_ms=\(Self.milliseconds(collapseUpdated - collapseStarted)) "
                + "collapse_layout_ms=\(Self.milliseconds(collapseLaidOut - collapseUpdated)) "
                + "descendants=\(card.descendants(ofType: NSView.self).count) "
                + "initial_logical_rows=\(initialLogicalRows) "
                + "initial_row_views=\(initialRowViews) "
                + "expanded_logical_rows=\(expandedLogicalRows) "
                + "expanded_row_views=\(expandedRowViews) "
                + "collapsed_row_views=\(collapsedRowViews) "
                + "model_mb=\(Self.megabytes(Self.positiveDifference(modelMemory, baselineMemory))) "
                + "view_mb=\(Self.megabytes(Self.positiveDifference(viewMemory, modelMemory)))"
        )

        XCTAssertLessThan(initialLogicalRows, tree.nodes.count)
        XCTAssertLessThanOrEqual(initialRowViews, initialLogicalRows)
        XCTAssertEqual(expandedLogicalRows, tree.nodes.count)
        XCTAssertLessThanOrEqual(expandedRowViews, min(tree.nodes.count, 80))
        XCTAssertLessThanOrEqual(collapsedRowViews, initialLogicalRows)
        withExtendedLifetime(window) {}
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private static func physicalFootprintBytes() -> UInt64 {
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        return ProcessUtility.getResourceUsage(forPid: pid)?.memoryBytes ?? 0
    }

    private static func positiveDifference(_ larger: UInt64, _ smaller: UInt64) -> UInt64 {
        larger >= smaller ? larger - smaller : 0
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

// MARK: - Helpers

private extension NSView {

    var descendantTextFields: [NSTextField] {
        descendants(ofType: NSTextField.self)
    }

    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            let below = view.descendants(ofType: type)
            return (view as? T).map { [$0] + below } ?? below
        }
    }
}
