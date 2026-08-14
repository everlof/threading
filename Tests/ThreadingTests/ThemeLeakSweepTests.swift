import AppKit
import XCTest
@testable import Threading

/// The screens of this app, swept for the shape of theme defect that has no call site.
///
/// The attachments pane shipped a Finder-blue selected row inside a lavender window, and every
/// gate this repository has stayed quiet — correctly, by its own rules. The source lint reads
/// what was *written*, and nothing was: `NSTableView` builds a plain `NSTableRowView` for a
/// delegate that declines to supply one, and that row fills its selection from the system accent.
/// `ThemeBoundaryAudit` walks what was *built*, and every class in the tree was legitimate — a
/// row view is structure, not chrome. The wrong pixels came out of a permitted class through a
/// path no line of code mentions.
///
/// So this file asserts against the three things that remain when neither code nor class is wrong:
///
/// - **What each screen renders.** Lists here are asked to materialise and select a row first,
///   because an audit of a list with no rows in it is an audit of nothing — the reason the
///   existing per-controller audits could not have caught this either.
/// - **What the reuse queue hands back.** A pooled view is in no window, so the sweep that walks
///   windows on a live switch cannot reach it, and it returns wearing the theme it went in with.
///   Settled where it is vended — `ThemedTableRowDefaults.vendedView(for:recycling:)` — for the
///   same reason as the row above, and asserted there rather than per list.
/// - **Which colours reach the glass.** Under a theme whose accent is nowhere near the system's,
///   a run of system accent in a screen is a framework default drawing itself, whatever the
///   mechanism. This is the net that does not need to know what the next one will be.
///
/// **What that second net cannot see, stated because it was measured rather than assumed:**
/// AppKit draws a list's own selection only in a **key** window, and `isEmphasized` does not
/// override that — so a screen rendered by any test in `Threading-Fast` shows no stock selection
/// fill, and the sweep would have passed against the very build this file was written for. A key
/// window is not available here either: the test host cannot activate under `xcodebuild`, so
/// `makeKeyAndOrderFront` leaves the fixture unkeyed and an assertion on `isKeyWindow` fails
/// outright. The sweep therefore covers the framework defaults that draw regardless of key state,
/// and the row's own case is held by the three layers above it — the construction in
/// `ThemedTableRowDefaults`, the audit rule, and the screen sweep, each of which *was* watched to
/// fail with the construction disabled.
@MainActor
final class ThemeLeakSweepTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-leak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - The construction

    /// The rule the panes now rely on, pinned where it is made rather than where it is used: a
    /// list whose delegate says **nothing** about row views still selects through the theme's.
    ///
    /// This is the one assertion that would fail if a future macOS stopped routing default row
    /// views through `makeView(withIdentifier:)`. It fails loudly and in one place, instead of
    /// every list quietly going back to system blue.
    func testAListThatSaysNothingAboutSelectionStillGetsTheThemedRow() throws {
        let source = SilentListSource()
        for list in [ThemedTableView(), ThemedOutlineView()] as [NSTableView] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("only"))
            list.addTableColumn(column)
            (list as? NSOutlineView)?.outlineTableColumn = column
            list.dataSource = source
            list.delegate = source
            list.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
            list.reloadData()
            list.layoutSubtreeIfNeeded()

            let row = try XCTUnwrap(
                list.rowView(atRow: 0, makeIfNecessary: true),
                "\(type(of: list)) built no row"
            )
            XCTAssertTrue(
                row is ThemedTableRowView,
                "\(type(of: list)) fell back to \(type(of: row)), which draws the system accent"
            )
        }
    }

    /// The other half: a delegate that *does* state a row is still the one that decides. The
    /// construction fills a gap; it does not take the question away from the sidebar.
    func testADelegateThatStatesItsOwnRowKeepsIt() throws {
        let source = SpokenListSource()
        let list = ThemedTableView()
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("only")))
        list.dataSource = source
        list.delegate = source
        list.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        list.reloadData()
        list.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            list.rowView(atRow: 0, makeIfNecessary: true) is SidebarHoverRowView,
            "the list's own row view should win over the default"
        )
    }

    // MARK: - The reuse queue

    /// **A view waiting in the reuse queue is the one view of a themed screen a live switch
    /// cannot reach**, because `AppThemeRefresh.repaintEverything` walks windows and a pooled
    /// view is in none. Nothing re-applies its font when it comes back either: `applyFont` runs
    /// once, where the cell is built.
    ///
    /// Same species as the row above, and it shipped the same way — no line of code to review,
    /// because the defect is the absence of one. After a switch to Tiger a sidebar row vended
    /// from the queue was still set in SF 12 beside neighbours in Lucida Grande 10.8.
    ///
    /// Driven through the seam directly, since AppKit decides when a queue is used and this has
    /// to hold whenever it does. The test below drives a real table through a real queue.
    func testTheVendingSeamBringsARecycledViewUpToTheThemeInForce() throws {
        let original = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(original) }

        AppThemeLibrary.apply(.system)
        let cell = NSTextField(labelWithString: "Fix dropdown issues on macOS Tiger")
        cell.applyFont(.controlRegular)
        let pooled = try XCTUnwrap(cell.font)

        AppThemeLibrary.apply(AppThemeStyles.aquaTiger)
        let inForce = Design.Typography.controlRegular()
        XCTAssertNotEqual(
            inForce, pooled,
            "the two themes state the same control font, so this test could not tell them apart"
        )
        XCTAssertEqual(
            cell.font, pooled,
            "a detached view followed the switch by itself — the seam is no longer what fixes this"
        )

        let vended = try XCTUnwrap(
            ThemedTableRowDefaults.vendedView(
                for: NSUserInterfaceItemIdentifier("cell"),
                recycling: cell
            ) as? NSTextField,
            "the seam should hand back the view it was given"
        )
        XCTAssertTrue(vended === cell, "the seam replaced a recycled view instead of reusing it")
        XCTAssertEqual(
            vended.font, inForce,
            "the view came back out of the queue in the theme it went in wearing"
        )
    }

    /// The same thing end to end, because the seam is only worth anything if AppKit's own queue
    /// reaches it. Both classes, since `NSOutlineView` overrides `makeView` separately.
    func testACellRecycledAcrossAThemeSwitchComesBackInTheNewFace() throws {
        let original = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(original) }

        for list in [ThemedTableView(), ThemedOutlineView()] as [NSTableView] {
            let name = String(describing: type(of: list))
            AppThemeLibrary.apply(.system)

            let source = RecycledCellSource()
            source.rows = 40
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("only"))
            list.addTableColumn(column)
            (list as? NSOutlineView)?.outlineTableColumn = column
            list.dataSource = source
            list.delegate = source

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
            scroll.documentView = list

            // In a window, never on screen: the whole point is that the *pooled* cell is the one
            // view of this list the sweep cannot walk to.
            let window = NSWindow(
                contentRect: scroll.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView?.addSubview(scroll)
            list.reloadData()
            try draw(scroll)

            let total = list.numberOfRows
            let parked = try XCTUnwrap(
                list.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTextField,
                "\(name) built no cell"
            )
            let wornIn = try XCTUnwrap(parked.font)

            // **Rows leaving the list is what parks a cell.** Two ways that look like they should
            // and do not: scrolling hands each cell straight to a row arriving at the other end,
            // and `reloadData` over an emptied source releases them outright. `removeItems` is the
            // sidebar's own incremental update — where a collapsed project's rows go — and it
            // leaves them in the queue with nothing to take them.
            source.rows = 1
            if let outline = list as? NSOutlineView {
                outline.removeItems(at: IndexSet(1..<total), inParent: nil, withAnimation: [])
            } else {
                list.removeRows(at: IndexSet(1..<total), withAnimation: [])
            }
            try draw(scroll)
            let built = source.builds
            XCTAssertNil(
                parked.window,
                "\(name) kept the removed cell in the window, so the sweep can still reach it and "
                    + "this test is not standing where the defect is"
            )

            AppThemeLibrary.apply(AppThemeStyles.aquaTiger)
            let inForce = Design.Typography.controlRegular()
            XCTAssertNotEqual(inForce, wornIn, "\(name): the two themes state the same font")

            source.rows = total
            if let outline = list as? NSOutlineView {
                outline.insertItems(at: IndexSet(1..<total), inParent: nil, withAnimation: [])
            } else {
                list.insertRows(at: IndexSet(1..<total), withAnimation: [])
            }
            try draw(scroll)

            XCTAssertEqual(
                source.builds, built,
                "\(name) built fresh cells rather than reusing the queue, so this test no longer "
                    + "covers the queue it was written for"
            )
            XCTAssertNotNil(parked.window, "\(name) never vended the pooled cell back")
            XCTAssertEqual(
                parked.font, inForce,
                "\(name) vended a cell still set in the theme it was pooled under"
            )
        }
    }

    // MARK: - The same shape, one control over

    /// Found while hardening against the row: a text view's **selected text** was highlighted
    /// with `selectedTextBackgroundColor`, because `selectedTextAttributes` is another value
    /// AppKit fills in for you. Same defect, same invisibility to every gate — a themed prompt
    /// with a system-blue drag selection through it.
    func testATextViewStatesWhatASelectionLooksLike() throws {
        try withTheme(try canaryTheme()) {
            let view = ThemedTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 40), textContainer: nil)
            let ground = try XCTUnwrap(
                view.selectedTextAttributes[.backgroundColor] as? NSColor,
                "a text view should state its selection ground"
            )

            XCTAssertEqual(
                ground.resolvedColour(),
                SelectionSurface.stated(over: Design.Surface.ground).fill.resolvedColour(),
                "selected text should fill with the theme's selection role"
            )
            XCTAssertNotEqual(
                ground.resolvedColour(),
                NSColor.selectedTextBackgroundColor.resolvedColour(),
                "selected text should not keep AppKit's own highlight"
            )
        }
    }

    /// The field editor is the harder half: AppKit creates it, shares it between every field in
    /// the window, and hands it over only for the moment a field is being edited — so the
    /// statement has to be made at that hand-off. Driven through the cell's real entry point
    /// rather than by calling the helper, since the hand-off is the part that can be forgotten.
    func testAFieldEditorIsToldTheSameThing() throws {
        try withTheme(try canaryTheme()) {
            let field = ThemedTextField()
            field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
            let host = NSView(frame: field.bounds)
            host.addSubview(field)

            let editor = NSTextView(frame: field.bounds)
            let cell = try XCTUnwrap(field.cell as? NSTextFieldCell, "the field should have a cell")
            cell.edit(
                withFrame: field.bounds, in: field, editor: editor, delegate: nil, event: nil
            )

            let ground = try XCTUnwrap(
                editor.selectedTextAttributes[.backgroundColor] as? NSColor,
                "the field editor should be told what a selection looks like"
            )
            XCTAssertEqual(
                ground.resolvedColour(),
                SelectionSurface.stated(over: Design.Surface.ground).fill.resolvedColour(),
                "a field editor's selection should be the theme's, not the system's"
            )
        }
    }

    // MARK: - The screens

    func testEveryScreenWithAListDrawsItsRowsThroughTheBoundary() throws {
        for screen in try screens() {
            try withTheme(try canaryTheme()) {
                let view = try screen.build()
                try present(view)

                let violations = ThemeBoundaryAudit.violations(in: view)
                XCTAssertEqual(
                    violations,
                    [],
                    ThemeBoundaryAudit.failureDescription(for: violations, windowTitle: screen.name)
                )
            }
        }
    }

    /// The wide net. Under a theme whose accent is nowhere near the system's, no screen may put a
    /// *fill's worth* of system accent on the glass.
    ///
    /// A run rather than a pixel, because artwork is allowed to be blue: a file icon, an agent's
    /// mark and a status dot all carry colours the theme never chose, and none of them is 32
    /// device pixels of the accent in an unbroken line. A selected row is hundreds.
    func testNoScreenLeaksTheSystemAccentUnderAThemedPalette() throws {
        let theme = try canaryTheme()

        for screen in try screens() {
            try withTheme(theme) {
                let view = try screen.build()
                let rendered = try present(view)

                for leak in systemFills() {
                    let run = longestRun(of: leak.colour, in: rendered)
                    XCTAssertLessThan(
                        run,
                        Sweep.runThreshold,
                        "\(screen.name) under \(theme.name): \(run) unbroken pixels of "
                            + "\(leak.name). A framework default is drawing itself — find what "
                            + "the app did not state, rather than repainting over it."
                    )
                }
            }
        }
    }

    /// **The detector, proven against a leak it is allowed to see.**
    ///
    /// Written because the sweep above spent its first afternoon passing for the wrong reason: an
    /// unshown fixture draws no AppKit selection at all, so it was scanning screens that could not
    /// have failed. A net nobody has watched catch anything is a green light, not a test — this
    /// paints a system-coloured fill on purpose and asserts the scan reports it, which pins the
    /// threshold and the tolerance to a real measurement rather than to two chosen numbers.
    func testTheSweepReportsASystemColouredFill() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.white.cgColor

        let leak = NSView(frame: NSRect(x: 10, y: 10, width: 100, height: 20))
        leak.wantsLayer = true
        leak.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        host.addSubview(leak)

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let accent = try XCTUnwrap(systemFills().first).colour
        XCTAssertGreaterThanOrEqual(
            longestRun(of: accent, in: rep),
            Sweep.runThreshold,
            "the sweep should see a fill of the system accent"
        )

        let clean = NSView(frame: host.bounds)
        clean.wantsLayer = true
        clean.layer?.backgroundColor = Design.Surface.panel.cgColor
        let cleanRep = try XCTUnwrap(clean.bitmapImageRepForCachingDisplay(in: clean.bounds))
        clean.cacheDisplay(in: clean.bounds, to: cleanRep)
        XCTAssertEqual(
            longestRun(of: accent, in: cleanRep),
            0,
            "a themed surface should read as no leak at all"
        )
    }

    // MARK: - Fixtures

    private struct Screen {
        let name: String
        let size: NSSize
        let build: () throws -> NSView
    }

    private func screens() throws -> [Screen] {
        [
            Screen(name: "attachments pane", size: NSSize(width: 380, height: 420)) {
                let sessionID = SessionID()
                _ = SessionAttachmentStore.shared.record(
                    urls: try self.pictures(count: 3), sessionID: sessionID, projectRoot: self.root
                )
                let controller = SessionAttachmentsViewController(sessionID: sessionID)
                controller.view.frame = NSRect(x: 0, y: 0, width: 380, height: 420)
                return controller.view
            },
            Screen(name: "project file tree", size: NSSize(width: 320, height: 360)) {
                _ = try self.pictures(count: 4)
                let controller = FileTreeViewController(folderPath: self.root.path)
                controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 360)
                self.refreshAndWait(controller)
                return controller.view
            },
            Screen(name: "themes settings", size: NSSize(width: 720, height: 560)) {
                let controller = ThemePreferencesViewController()
                controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
                return controller.view
            },
            Screen(name: "import conversations", size: NSSize(width: 620, height: 400)) {
                let controller = SessionImportViewController(sessions: [
                    ImportableSession(
                        agentSessionID: TranscriptID("6E54D70F-F0B5-4DA7-95DB-2B16E96E9F77"),
                        kind: .claude,
                        accountHandle: .standard,
                        title: "Fix the sidebar's width jump",
                        lastActiveAt: Date(timeIntervalSince1970: 1_700_000_000)
                    ),
                    ImportableSession(
                        agentSessionID: TranscriptID("0A3C1B22-77E8-41D9-BF41-9D3E2A5C8B10"),
                        kind: .codex,
                        accountHandle: .standard,
                        title: "Align the pill component's height",
                        lastActiveAt: Date(timeIntervalSince1970: 1_700_090_000)
                    )
                ])
                controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 400)
                return controller.view
            }
        ]
    }

    /// Files the panes admit, so their lists have rows to select. Written once per screen build
    /// and left in `root`, which `tearDown` removes.
    private func pictures(count: Int) throws -> [URL] {
        try (0..<count).map { index in
            let url = root.appendingPathComponent("picture-\(index).png")
            guard !FileManager.default.fileExists(atPath: url.path) else { return url }
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 16, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
            return url
        }
    }

    // MARK: - Harness

    private func refreshAndWait(_ controller: FileTreeViewController) {
        var finished = false
        controller.refresh { finished = true }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(finished, "file-tree refresh timed out")
    }

    /// Lays a screen out, makes every list in it produce rows, selects the first of each, and
    /// renders — the state the defect was reported in, and the only one in which a list has any
    /// rows for an audit to walk.
    @discardableResult
    private func present(_ view: NSView) throws -> NSBitmapImageRep {
        // In a window, never on screen — the rule `CLAUDE.md` states for this target. A themed
        // row draws its own selection either way; AppKit's does not, which is the blind spot
        // recorded on this class.
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        for list in lists(in: view) {
            // The state worth sweeping. A test window is never key, so without this every list
            // draws its *unemphasized* selection — AppKit's quiet grey rather than the accent —
            // and the sweep passes against a build that would show system blue on a real screen.
            // Found by regressing the construction on purpose and watching this test stay green.
            switch list {
            case let table as ThemedTableView: table.fixtureIsKey = true
            case let outline as ThemedOutlineView: outline.fixtureIsKey = true
            default: break
            }
            list.reloadData()
            (list as? NSOutlineView)?.expandItem(nil, expandChildren: false)
            list.layoutSubtreeIfNeeded()
            if list.numberOfRows > 0 {
                list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds),
            "Failed to build a bitmap for the screen"
        )
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Lays a view out **and draws it**, because a list reclaims cells while it draws: after a
    /// layout pass alone the rows it no longer has are still in the window, and a queue with
    /// nothing in it cannot demonstrate anything about a queue.
    private func draw(_ view: NSView) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds),
            "Failed to build a bitmap for \(type(of: view))"
        )
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    private func lists(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        if let list = view as? NSTableView { found.append(list) }
        for child in view.subviews { found += lists(in: child) }
        return found
    }

    private enum Sweep {
        /// Sixteen points at 2×. Chosen as the smallest run no glyph, mark or file icon in this
        /// app draws solid, and a fraction of the shortest row a selection can fill.
        static let runThreshold = 32
        /// Summed over the channels — a fill is the colour exactly; only its antialiased edge is
        /// anywhere near it.
        static let tolerance: CGFloat = 0.06
    }

    /// The fills AppKit reaches for when nothing else has been said. Named so a failure reports
    /// which default it was rather than a colour triple.
    private func systemFills() -> [(name: String, colour: NSColor)] {
        var fills: [(name: String, colour: NSColor)] = []
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let candidates: [(name: String, colour: NSColor)] = [
                (name: "the system accent", colour: NSColor.controlAccentColor),
                (name: "AppKit's selected-row fill", colour: NSColor.selectedContentBackgroundColor),
                (
                    name: "AppKit's quiet selected-row fill",
                    colour: NSColor.unemphasizedSelectedContentBackgroundColor
                ),
                (name: "AppKit's text selection", colour: NSColor.selectedTextBackgroundColor)
            ]
            fills = candidates.map {
                (name: $0.name, colour: $0.colour.usingColorSpace(.sRGB) ?? $0.colour)
            }
        }
        return fills
    }

    private func longestRun(of colour: NSColor, in rep: NSBitmapImageRep) -> Int {
        var longest = 0
        // Every other scanline. The target is a *fill*, which is dozens of lines tall, and
        // halving the scan halves a sweep that runs over every screen in the app.
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            var run = 0
            for x in 0..<rep.pixelsWide {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      distance(pixel, colour) <= Sweep.tolerance else {
                    run = 0
                    continue
                }
                run += 1
                longest = max(longest, run)
            }
        }
        return longest
    }

    private func distance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        abs(first.redComponent - second.redComponent)
            + abs(first.greenComponent - second.greenComponent)
            + abs(first.blueComponent - second.blueComponent)
    }

    /// A stock theme whose accent is as far from the system's as the catalogue offers, picked by
    /// colour rather than by name so a retired style does not become a failing test. Under it,
    /// any system accent on screen came from AppKit and not from the palette.
    private func canaryTheme() throws -> AppTheme {
        var system = NSColor.controlAccentColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            system = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? system
        }

        return try XCTUnwrap(
            AppThemeLibrary.stock
                .filter { !$0.isSystem }
                .max(by: {
                    distance($0.resolved(.accent).usingColorSpace(.sRGB) ?? $0.resolved(.accent), system)
                        < distance($1.resolved(.accent).usingColorSpace(.sRGB) ?? $1.resolved(.accent), system)
                }),
            "Expected a stock theme whose accent is not the system's"
        )
    }

    private func withTheme(_ theme: AppTheme, _ body: () throws -> Void) rethrows {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }

        AppThemeLibrary.apply(theme)
        try body()
    }
}

// MARK: - List sources

/// A data source that answers rows and nothing else — the shape every list in this app had
/// before the defect, and the one a new pane will have again the day it is written.
private final class SilentListSource: NSObject,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { 3 }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "row \(row)")
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? 3 : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        "row \(index)"
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor column: NSTableColumn?,
        item: Any
    ) -> NSView? {
        NSTextField(labelWithString: item as? String ?? "")
    }
}

/// A source that vends through `makeView(withIdentifier:owner:)`, the way every list in this app
/// does, with a recorded role on the label so a theme switch has something to move.
private final class RecycledCellSource: NSObject,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate {

    var rows = 3

    /// How many cells this source has had to build, so a test can tell a vend from the queue
    /// from a fresh cell that would have been correct however the seam behaved.
    private(set) var builds = 0

    private static let identifier = NSUserInterfaceItemIdentifier("RecycledCell")

    private func cell(from list: NSTableView, titled title: String) -> NSView {
        if let reused = list.makeView(withIdentifier: Self.identifier, owner: self) as? NSTextField {
            reused.stringValue = title
            return reused
        }

        builds += 1
        let field = NSTextField(labelWithString: title)
        field.identifier = Self.identifier
        MainActor.assumeIsolated { field.applyFont(.controlRegular) }
        return field
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        cell(from: tableView, titled: "row \(row)")
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? rows : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        "row \(index)"
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor column: NSTableColumn?,
        item: Any
    ) -> NSView? {
        cell(from: outlineView, titled: item as? String ?? "")
    }
}

/// The sidebar's shape: a source that states its own row view.
private final class SpokenListSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { 3 }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "row \(row)")
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarHoverRowView()
    }
}

// MARK: - Colour comparison

private extension NSColor {

    /// A dynamic colour compared by what it *resolves to*, since two roles can be the same
    /// colour through different providers and never compare equal as objects.
    func resolvedColour() -> NSColor {
        var resolved = self
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = (self.usingColorSpace(.sRGB) ?? self)
        }
        return resolved
    }
}
