import AppKit
import XCTest
@testable import Threading

/// Draws a sidebar row in each of its trailing-slot states and writes them out, both
/// appearances — the same fixture-to-PNG idea as the other render tests.
///
/// The trailing slot is the one part of the row that cannot be reviewed any other way. Its
/// contents swap under the pointer, so a screenshot of the running app would need the pointer
/// driven onto a row; and whether the `⋯` and the archive button read as a *pair* at the row's
/// edge — rather than as two icons that happen to be adjacent, or as a cluster crowding the
/// title — is exactly the kind of question no assertion answers.
///
/// One question about the slot *is* answerable, and is asserted below rather than drawn: every
/// mark that can occupy the trailing edge — a count, a status dot, a hover glyph — has to leave
/// the same air beside it, or the row's edge steps inboard the moment the pointer arrives.
@MainActor
final class SidebarRowRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private enum Fixture {
        static let width: CGFloat = 240
        static let height: CGFloat = 28
    }

    // MARK: - Stories

    func testRendersTheStorybook() throws {
        var written = 0

        // At rest: the status dot alone, at the row's trailing edge. The dot's position here
        // is the one to compare against the hovered stories — it must not have moved.
        written += try write(story: "01-idle-at-rest", activity: .idle, hovered: false)

        // Working, at rest: the spinner occupies the same place the dot does.
        written += try write(story: "02-working-at-rest", activity: .working, hovered: false)

        // Hovered: the `⋯` and the archive button, the archive outboard at the row's edge.
        written += try write(story: "03-hovered", activity: .idle, hovered: true)

        // Hovered while working — the state a user is most often in when reaching for either
        // button, and the one where the pair replaces a spinner rather than a static dot.
        written += try write(story: "04-hovered-while-working", activity: .working, hovered: true)

        // A title long enough to be truncated, so the gap the widened slot takes from the
        // text is visible rather than inferred.
        written += try write(
            story: "05-hovered-long-title",
            activity: .idle,
            hovered: true,
            title: "Refactor the sidebar trailing slot and its hover controls"
        )

        // The same title at rest: it should visibly reclaim the inboard action target while
        // leaving the status on the same trailing line.
        written += try write(
            story: "06-long-title-at-rest",
            activity: .idle,
            hovered: false,
            title: "Refactor the sidebar trailing slot and its hover controls"
        )

        // Hovered on the *selected* row — the state where the row's ground is the theme's accent
        // rather than the sidebar's surface, and the one the `⋯` and archive were once drawn
        // wrong in: they kept the chrome's label over a block of colour it was never measured
        // against. What to look for is that the pair reads as the title beside it does.
        written += try write(
            story: "07-hovered-and-selected",
            activity: .idle,
            hovered: true,
            selected: true
        )

        // Working on the selected ground — the spinner must invert with the title instead of
        // retaining the accent that the row itself uses as its fill.
        written += try write(
            story: "08-working-and-selected",
            activity: .working,
            hovered: false,
            selected: true
        )

        // Pinning changes the row's order under every sort, and the filled pin beside the title
        // makes that durable state visible even when the row would have led the list anyway.
        written += try write(
            story: "09-pinned-at-rest",
            activity: .idle,
            hovered: false,
            pinned: true
        )

        // On a selected row the pin must use the selection's ink rather than disappearing into
        // the same accent that fills the row.
        written += try write(
            story: "10-pinned-and-selected",
            activity: .idle,
            hovered: false,
            selected: true,
            pinned: true
        )

        XCTAssertEqual(written, 20, "Every story should render in both appearances")
        print("Rendered sidebar-row storybook to \(Render.directory.path)")
    }

    /// Every row *kind* the sidebar draws, stacked at one width and all hovered, so the
    /// trailing controls of a project, a branch heading and a session can be compared against
    /// each other rather than each against itself.
    func testRendersEveryRowKindHovered() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?

            let render = {
                let host = NSView(
                    frame: NSRect(
                        x: 0,
                        y: 0,
                        width: Fixture.width,
                        height: Fixture.height * 5
                    )
                )
                host.appearance = appearance

                let project = Project(
                    name: "Threading",
                    folderURL: URL(fileURLWithPath: "/tmp/Threading")
                )
                let session = AgentSession(kind: .claude, title: "Fix the hover state")

                let rows: [NSView] = [
                    Self.hoveredProjectRow { $0.configureAsRepository(named: "Threading", count: 2) },
                    Self.hoveredProjectRow {
                        $0.configure(with: project, collapsedSessionCount: 0)
                    },
                    Self.hoveredProjectRow {
                        $0.configureAsBranch(named: "master", collapsedSessionCount: 0)
                    },
                    Self.hoveredSessionRow(session)
                ]

                let stack = NSStackView(views: rows)
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 0
                stack.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    stack.topAnchor.constraint(equalTo: host.topAnchor)
                ])
                for row in rows {
                    NSLayoutConstraint.activate([
                        row.widthAnchor.constraint(equalTo: host.widthAnchor),
                        row.heightAnchor.constraint(equalToConstant: Fixture.height)
                    ])
                }

                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                host.wantsLayer = true
                host.layer?.backgroundColor = Design.Surface.background.cgColor

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    return
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }

            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            let image = try XCTUnwrap(data, "Failed to render the row-kind sheet in \(name)")
            try image.write(
                to: directory.appendingPathComponent("sidebar-row-kinds-\(name).png")
            )
        }
        print("Rendered sidebar row kinds to \(Render.directory.path)")
    }

    // MARK: - Trailing Edge

    /// Every trailing mark lands on one optical line, whatever kind of thing it is.
    ///
    /// A count is text, whose frame is its ink. A hover control is a click target with a glyph
    /// floating inside it — pinned by frame it stops short of the margin the count reaches, and
    /// the row's trailing edge visibly steps inboard under the pointer. `OpticalInsetProviding`
    /// is what closes that gap; this asserts the row actually subtracts it.
    ///
    /// Asserted on rows at rest: hovering only crossfades the slot's contents, so the geometry
    /// under the pointer is the geometry here — and building it without a synthesized hover
    /// keeps the code-stats service and the popover timer out of a layout test.
    func testEveryTrailingMarkLandsOnOneOpticalLine() throws {
        let margin = Fixture.width - SidebarRowDefaults.trailingInset

        let project = Project(name: "Threading", folderURL: URL(fileURLWithPath: "/tmp/Threading"))
        let projectRow = ProjectRowView(customizationLookup: { _ in .empty })
        projectRow.translatesAutoresizingMaskIntoConstraints = false
        projectRow.configure(with: project, collapsedSessionCount: 2)
        Self.layOut(projectRow)

        let count = try XCTUnwrap(projectRow.descendant(identified: "sidebar.project.count"))
        XCTAssertEqual(
            count.alignmentRect(forFrame: count.convert(count.bounds, to: projectRow)).maxX,
            margin,
            accuracy: 0.5,
            "The collapsed-session count should sit on the row's trailing margin"
        )
        try assertOpticalEdge(
            ofControlsIn: "sidebar.project.actions",
            of: projectRow,
            equals: margin,
            "the project row's ⋯"
        )

        let branchRow = ProjectRowView(customizationLookup: { _ in .empty })
        branchRow.translatesAutoresizingMaskIntoConstraints = false
        branchRow.configureAsBranch(named: "master")
        Self.layOut(branchRow)
        try assertOpticalEdge(
            ofControlsIn: "sidebar.project.actions",
            of: branchRow,
            equals: margin,
            "the branch heading's gear"
        )

        let sessionRow = SessionRowView(customizationLookup: { _ in .empty })
        sessionRow.translatesAutoresizingMaskIntoConstraints = false
        sessionRow.configure(
            with: AgentSession(kind: .claude, title: "Fix the hover state"),
            activity: .idle
        )
        Self.layOut(sessionRow)

        let status = try XCTUnwrap(sessionRow.descendant(identified: "sidebar.session.status"))
        XCTAssertEqual(
            status.convert(status.bounds, to: sessionRow).maxX,
            margin,
            accuracy: 0.5,
            "The status dot should sit on the same margin the count does"
        )
        try assertOpticalEdge(
            ofControlsIn: "sidebar.session.hover-controls",
            of: sessionRow,
            equals: margin,
            "the session row's archive button"
        )
    }

    /// The same margin, on a *recycled* row. A fresh row always passed the assertion above,
    /// yet in the app one project's `+ ⋯` sat against its name while another's sat on the
    /// margin: reuse had toggled the slot's visibility and width, and with the slot arranged
    /// in the row's stack its position rested on a hugging tie the solver could break either
    /// way. The slot is pinned to the row now; this holds the reuse path to the same line.
    func testTrailingControlsKeepTheMarginOnAReusedRow() throws {
        let margin = Fixture.width - SidebarRowDefaults.trailingInset

        let row = ProjectRowView(customizationLookup: { _ in .empty })
        row.translatesAutoresizingMaskIntoConstraints = false
        row.configureAsRepository(named: "sondalabs", count: 3)
        Self.layOut(row)

        row.prepareForReuse()
        row.configure(
            with: Project(
                name: "AnotherTerminal",
                folderURL: URL(fileURLWithPath: "/tmp/AnotherTerminal")
            ),
            collapsedSessionCount: 2
        )
        Self.layOut(row)

        let count = try XCTUnwrap(row.descendant(identified: "sidebar.project.count"))
        XCTAssertEqual(
            count.alignmentRect(forFrame: count.convert(count.bounds, to: row)).maxX,
            margin,
            accuracy: 0.5,
            "A reused row's count should sit on the row's trailing margin"
        )
        try assertOpticalEdge(
            ofControlsIn: "sidebar.project.actions",
            of: row,
            equals: margin,
            "a reused project row's ⋯"
        )
    }

    // MARK: - Selected Ground

    /// A selected row's trailing controls have to ink against the fill the *row* painted, not
    /// against the chrome's ground they were built for.
    ///
    /// Reported against Botanical, whose accent is a deep herbarium green: the selected row's
    /// title inverted to near-white and the `⋯` and archive beside it kept the chrome's dark
    /// green secondary label — two glyphs sunk into the fill, in the one row the eye is already
    /// on. Nothing about the buttons was Botanical-specific, so the sweep is every stock theme
    /// and every row kind the sidebar can select: the three rows state the rule separately, and
    /// two of three would be the drift the component vocabulary exists to prevent.
    ///
    /// Asserted as *which of two inks* the glyphs were drawn in rather than as a contrast floor,
    /// because contrast does not separate them: under Bauhaus the chrome's dark label reads on
    /// the selection better than the ink measured against it does (3.8 against 2.8), and under
    /// Art Deco it reads at 1.1. Any threshold that passed Bauhaus would pass Botanical's 2.6 as
    /// well, and Botanical's 2.6 is the bug. The rule is not "clears a number", it is "measured
    /// against the ground it is on".
    ///
    /// Nearest-of-two rather than an exact colour, because the two composites being told apart
    /// are far apart while the *rendering* of either is only close: CoreGraphics flattens the
    /// glyph's transparency layer in its own working space, which lands a few points off a
    /// component-wise mix of the same two colours. A classification is immune to that, where a
    /// tolerance would be a number tuned until it passed.
    ///
    /// Read from pixels rather than from the buttons' tint, because the tint is set twice —
    /// `ThemedIconButton` resolves the glyph again inside `draw(_:)`, so a fix that reached only
    /// `applyInk` would satisfy the property and still paint the old colour.
    func testASelectedRowsTrailingControlsReadAgainstItsSelectionFill() throws {
        let themes = AppThemeLibrary.stock
        XCTAssertFalse(themes.isEmpty, "Fixture premise: there are stock themes to sweep")

        for theme in themes {
            try withTheme(theme) {
                for row in Self.selectableRows {
                    let fill = Design.Surface.selectionFill
                    let drawn = try strongestRowInk(
                        of: row.build(),
                        identified: row.controls,
                        over: fill
                    )

                    // The two answers the button could have given: the ink the fill asks for, and
                    // the chrome's own, which is what it drew before the row started saying what
                    // it had painted. A theme whose accent happens to sit where its chrome ink
                    // already reads leaves the two nearly equal, and passes either way —
                    // correctly, since under that theme there is nothing to get wrong.
                    let selected = distance(
                        drawn, Design.Ink.selection.secondary.composited(over: fill)
                    )
                    let chrome = distance(
                        drawn, Design.Ink.chrome.secondary.composited(over: fill)
                    )

                    XCTAssertLessThanOrEqual(
                        selected,
                        chrome,
                        "\(theme.name): a selected \(row.name)'s actions should ink from its fill"
                    )
                }
            }
        }
    }

    /// The status slot sits on the same selected ground as the title and trailing controls. The
    /// spinner's ordinary accent is that selection fill itself, which made the loader disappear.
    /// Swept through the real session row so the component and its host wiring are both exercised.
    func testASelectedWorkingRowsSpinnerReadsAgainstItsSelectionFill() throws {
        for theme in AppThemeLibrary.stock {
            try withTheme(theme) {
                let row = SessionRowView(customizationLookup: { _ in .empty })
                row.translatesAutoresizingMaskIntoConstraints = false
                row.configure(
                    with: AgentSession(kind: .claude, title: "Selected status"),
                    activity: .working
                )

                let fill = Design.Surface.selectionFill
                let drawn = try strongestRowInk(
                    of: row,
                    identified: "sidebar.session.status",
                    over: fill
                )
                let selected = distance(
                    drawn,
                    Design.Ink.selection.label.composited(over: fill)
                )
                let ordinary = distance(
                    drawn,
                    Design.Surface.accent.composited(over: fill)
                )

                XCTAssertLessThanOrEqual(
                    selected,
                    ordinary,
                    "\(theme.name): a selected row's spinner did not ink from its fill"
                )
            }
        }
    }

    /// One row kind a sidebar selection can land on, hovered so its trailing controls are what is
    /// in the slot, named by the identifier the row hangs them under.
    private struct SelectableRow {
        let name: String
        let controls: String
        let build: () -> NSTableCellView
    }

    private static let selectableRows = [
        SelectableRow(
            name: "session row",
            controls: "sidebar.session.hover-controls",
            build: { hoveredSessionRow(AgentSession(kind: .claude, title: "Fix the hover state")) }
        ),
        SelectableRow(
            name: "project row",
            controls: "sidebar.project.actions",
            build: {
                hoveredProjectRow {
                    $0.configure(
                        with: Project(
                            name: "Threading",
                            folderURL: URL(fileURLWithPath: "/tmp/Threading")
                        ),
                        collapsedSessionCount: 0
                    )
                }
            }
        ),
        SelectableRow(
            name: "terminal row",
            controls: "sidebar.terminal.actions",
            build: { hoveredTerminalRow() }
        )
    ]

    /// How far the rendered ground may sit from the colour the fixture handed it — the same few
    /// points of working-space conversion the ink comparison above is written around, summed over
    /// three channels. It is a premise check, not the measurement.
    private static let groundTolerance: CGFloat = 0.1

    /// `color` as the fixture's own backing store can hold it.
    ///
    /// The rep `bitmapImageRepForCachingDisplay` hands back is Generic RGB, and a saturated
    /// primary does not survive the trip from sRGB into it: Vaporwave's magenta comes back 0.25
    /// away summed over the channels, and Newsprint's red 0.11 — both of them correct renders of
    /// exactly the colour asked for. Putting the expected colour through the same store is what
    /// keeps the premise below strict; widening its tolerance to 0.26 instead would have
    /// swallowed a fill that genuinely failed to land.
    private func drawn(
        _ color: NSColor,
        inTheSpaceOf rep: NSBitmapImageRep
    ) throws -> NSColor {
        let probe = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: rep.colorSpaceName,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "Failed to build the reference pixel")

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: probe)
        color.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()

        return try XCTUnwrap(probe.colorAt(x: 0, y: 0), "No reference pixel was drawn")
    }

    /// How far apart two colours are, summed over the channels — the same reading
    /// `SidebarRowHighlightTests` takes, and enough to say which of two inks a pixel is.
    private func distance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        guard let first = first.usingColorSpace(.sRGB),
              let second = second.usingColorSpace(.sRGB) else { return .greatestFiniteMagnitude }

        return abs(first.redComponent - second.redComponent)
            + abs(first.greenComponent - second.greenComponent)
            + abs(first.blueComponent - second.blueComponent)
    }

    /// The most fully inked pixel the hover controls put on the fill they are drawn over.
    ///
    /// The *most*, because a glyph is mostly its own antialiased edge: only a stroke's solid
    /// centre carries the colour that was chosen, and a half-covered pixel carries half of it.
    /// Scanned across the controls' whole column so the probe need not know where inside a `⋯`
    /// the dots fall.
    private func strongestRowInk(
        of row: NSTableCellView,
        identified identifier: String,
        over dynamicFill: NSColor
    ) throws -> NSColor {
        // The other half of what selection means to the row: the caller paints the fill, and this
        // is the background style AppKit hands the cell to say that fill is emphasized.
        row.backgroundStyle = .emphasized

        let host = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height))
        // A role is a *dynamic* colour, and asking one for its components resolves it against
        // whatever appearance AppKit last had in hand rather than the one this fixture draws in —
        // the trap `GeneratedAppIcon` documents at length. Vaporwave and Newsprint state an accent
        // that moves between appearances, so the premise below was comparing one appearance's fill
        // against the other appearance's pixels and reporting a correct render as a broken
        // fixture. Flattened once, here, under the appearance the row is actually drawn in.
        var fill = dynamicFill
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = dynamicFill.usingColorSpace(.sRGB) ?? dynamicFill
        }
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        // The fill the sidebar's row view paints under a selected row, laid down here so the
        // glyphs composite over it the way they do on screen. Read back from the render below
        // rather than assumed: a ground that failed to land would make every comparison a
        // comparison against transparency, which nothing can be wrong about.
        host.wantsLayer = true
        host.layer?.backgroundColor = fill.cgColor

        let controls = try XCTUnwrap(
            row.descendant(identified: identifier),
            "The row should hold \(identifier)"
        )
        let column = controls.convert(controls.bounds, to: host)

        let rep = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "Failed to build a bitmap for the row"
        )
        host.cacheDisplay(in: host.bounds, to: rep)

        // The controls' column, at every height: the buttons are the only thing drawn there once
        // the status indicator has crossfaded out, so this needs no flipped-coordinate arithmetic
        // to find the glyphs.
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let first = max(0, Int(column.minX * scale))
        let last = min(rep.pixelsWide - 1, Int(column.maxX * scale))
        XCTAssertLessThan(first, last, "The hover controls should occupy a column of pixels")

        // The ground as *rendered*, read from a corner the row draws nothing in, so the search
        // below measures against the pixels the glyphs actually sit on rather than against the
        // colour the fixture asked for.
        let ground = try XCTUnwrap(rep.colorAt(x: 0, y: 0), "No pixel at the fixture's corner")
        XCTAssertLessThan(
            distance(ground, try drawn(fill, inTheSpaceOf: rep)),
            Self.groundTolerance,
            "\(AppThemePalette.current.name): fixture premise — the corner should hold the "
                + "selection fill the row was given"
        )

        var strongest = ground
        var moved: CGFloat = 0
        for x in first...last {
            for y in 0..<rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                let inked = distance(pixel, ground)
                if inked > moved {
                    moved = inked
                    strongest = pixel
                }
            }
        }

        XCTAssertGreaterThan(moved, 0, "The hover controls should have drawn something")
        return strongest
    }

    /// `apply` is what the app itself calls, and it moves both halves the row reads: the library,
    /// which decides whether the row draws its own selection at all, and the palette the fill and
    /// the ink over it both come from.
    private func withTheme(_ theme: AppTheme, _ body: () throws -> Void) rethrows {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }

        AppThemeLibrary.apply(theme)
        try body()
    }

    // MARK: - Lookup

    /// Reads the trailing control's *ink* edge: its frame pulled in by the padding it reports.
    private func assertOpticalEdge(
        ofControlsIn identifier: String,
        of row: NSView,
        equals expected: CGFloat,
        _ what: String
    ) throws {
        let controls = try XCTUnwrap(row.descendant(identified: identifier))
        let outermost = try XCTUnwrap(
            controls.subviews.compactMap { $0 as? OpticalInsetProviding & NSView }
                .max(by: { $0.frame.maxX < $1.frame.maxX }),
            "\(identifier) should hold a control that states its own padding"
        )
        XCTAssertEqual(
            controls.convert(outermost.frame, to: row).maxX - outermost.opticalHorizontalInset,
            expected,
            accuracy: 0.5,
            "\(what) should land its glyph on the row's trailing margin, not its click target"
        )
    }

    private static func layOut(_ row: NSView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
    }

    private static func hoveredProjectRow(
        _ configure: (ProjectRowView) -> Void
    ) -> ProjectRowView {
        let row = ProjectRowView(customizationLookup: { _ in .empty })
        row.translatesAutoresizingMaskIntoConstraints = false
        configure(row)
        if let entered = enterEvent() {
            row.mouseEntered(with: entered)
            configure(row)
        }
        return row
    }

    private static func hoveredTerminalRow() -> ProjectTerminalRowView {
        let row = ProjectTerminalRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.configure(
            with: ProjectTerminal(currentDirectory: "/tmp/Threading", title: "zsh"),
            running: true,
            projectRoot: nil
        )
        if let entered = enterEvent() { row.mouseEntered(with: entered) }
        return row
    }

    private static func hoveredSessionRow(_ session: AgentSession) -> SessionRowView {
        let row = SessionRowView(customizationLookup: { _ in .empty })
        row.translatesAutoresizingMaskIntoConstraints = false
        row.configure(with: session, activity: .idle)
        if let entered = enterEvent() {
            row.mouseEntered(with: entered)
            row.configure(with: session, activity: .idle)
        }
        return row
    }

    // MARK: - Harness

    /// The row reads nothing off the event — `mouseEntered` only records the hover and starts
    /// the crossfade — so a synthesized one is enough to reach the hovered state without a
    /// pointer, and without test-only API on the row itself.
    private static func enterEvent() -> NSEvent? {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )
    }

    private func write(
        story: String,
        activity: SessionActivity,
        hovered: Bool,
        selected: Bool = false,
        pinned: Bool = false,
        title: String = "Fix the hover state"
    ) throws -> Int {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)

            var data: Data?
            let render = {
                let row = SessionRowView(customizationLookup: { _ in .empty })
                row.translatesAutoresizingMaskIntoConstraints = false

                let host = NSView(
                    frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height)
                )
                host.appearance = appearance
                host.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    row.topAnchor.constraint(equalTo: host.topAnchor),
                    row.bottomAnchor.constraint(equalTo: host.bottomAnchor)
                ])

                // Configured before the hover is asserted, then again after: `configure`
                // reapplies the hover state without animating, which is what makes the
                // hovered stories deterministic rather than a race with the crossfade.
                var session = AgentSession(kind: .claude, title: title)
                session.isPinned = pinned
                row.configure(with: session, activity: activity)
                if hovered, let entered = Self.enterEvent() {
                    row.mouseEntered(with: entered)
                    row.configure(with: session, activity: activity)
                }
                // The selection is two things and the row owns only one of them: the ground is
                // the sidebar's row view's to paint, and `backgroundStyle` is what the cell is
                // told about it.
                if selected { row.backgroundStyle = .emphasized }

                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()

                host.wantsLayer = true
                host.layer?.backgroundColor = selected
                    ? Design.Surface.selectionFill.cgColor
                    : Design.Surface.background.cgColor

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    return
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }

            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            let image = try XCTUnwrap(data, "Failed to render \(story) in \(name)")
            try image.write(
                to: directory.appendingPathComponent("sidebar-row-\(story)-\(name).png")
            )
            written += 1
        }
        return written
    }
}

// MARK: - Lookup

/// The slot's parts are private to the row; its accessibility identifiers are not, and are the
/// same names the app's own inspector reads a row by.
private extension NSView {
    func descendant(identified identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier { return self }
        for subview in subviews {
            if let found = subview.descendant(identified: identifier) { return found }
        }
        return nil
    }
}
