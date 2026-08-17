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

        /// Where the real outline places a session cell inside its row — measured through the
        /// production tree (a 320pt sidebar puts the cell at 39…304 in a row whose hover and
        /// selection capsule spans 10…310). The depth of the session decides the leading edge;
        /// the trailing inset is the outline's own. A story that pins the cell to the row's
        /// edges instead paints the archive box *outside* the capsule — an overhang the app
        /// does not have, and one that was reported as a bug from these very pictures.
        static let cellLeadingInset: CGFloat = 39
        static let cellTrailingInset: CGFloat = 16
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

        // Pinning is orthogonal to activity and hover. These combinations used to be absent
        // from the visual catalogue, which let the pin collide with the working indicator and
        // disappear when the trailing actions arrived.
        written += try write(
            story: "11-pinned-and-working",
            activity: .working,
            hovered: false,
            pinned: true
        )
        written += try write(
            story: "12-pinned-and-hovered",
            activity: .idle,
            hovered: true,
            pinned: true
        )
        written += try write(
            story: "13-pinned-hovered-long-title",
            activity: .working,
            hovered: true,
            pinned: true,
            title: "Refactor the sidebar trailing slot and its hover controls"
        )

        // The two states the pair used to be drawn in two places by. A loading row is the one
        // that caught it: the spinner is raised because the sidebar is presenting the row that
        // was just clicked, so it arrives under a pointer already on its way to the archive
        // button. Both should put that button exactly where story 03 does.
        written += try write(story: "14-hovered-while-loading", activity: .idle, hovered: true, loading: true)
        written += try write(story: "15-hovered-while-blocked", activity: .awaitingUser, hovered: true)

        // A reserved scheduled conversation is alive in the tree but is not a dormant session.
        // Its durable label replaces that dimming, and its hover has only the safe actions menu.
        written += try write(
            story: "16-scheduled-start",
            activity: .dormant,
            hovered: false,
            scheduled: true,
            title: "Audit the release checklist"
        )

        // The reported terminal state: a silent foreground command owns the PTY while the
        // selected row stays legible. This runs through the same cell and selected ground the
        // shipping outline uses, rather than rendering the spinner by itself.
        written += try writeBusyTerminal(story: "17-terminal-working-and-selected")

        XCTAssertEqual(written, 34, "Every story should render in both appearances")
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

    /// Every trailing state a session row can be hovered in, stacked at one width, so the archive
    /// button's column can be read down the sheet rather than compared between two screenshots.
    ///
    /// This is the picture the bug was reported from: the pair took the row's edge when there was
    /// no status and stepped a column inboard when there was, so the same button stood in two
    /// places down one list — and moved under the pointer whenever a row's state changed while it
    /// was being reached for. What to look for is a single vertical line of archive glyphs, with
    /// each row's status, where it has one, on the line outboard of it.
    func testRendersEveryHoveredTrailingState() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let states: [(name: String, activity: SessionActivity, loading: Bool)] = [
            ("Idle session", .idle, false),
            ("Loading session", .idle, true),
            ("Working session", .working, false),
            ("Blocked session", .awaitingUser, false),
            ("Unread session", .needsAttention, false)
        ]

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?

            let render = {
                let host = NSView(
                    frame: NSRect(
                        x: 0,
                        y: 0,
                        width: Fixture.width,
                        height: Fixture.height * CGFloat(states.count)
                    )
                )
                host.appearance = appearance

                // Each cell inside the hover ground the sidebar paints under it, so the sheet
                // shows the pair on the surface it is actually inked against.
                let rows: [NSView] = states.map { state in
                    let cell = Self.hoveredSessionRow(
                        AgentSession(kind: .claude, title: state.name),
                        activity: state.activity,
                        loading: state.loading
                    )
                    let ground = SidebarHoverRowView()
                    ground.translatesAutoresizingMaskIntoConstraints = false
                    ground.addSubview(cell)
                    // The cell sits where the outline actually places it, inside the capsule
                    // the ground draws — see `Fixture.cellLeadingInset`.
                    NSLayoutConstraint.activate([
                        cell.leadingAnchor.constraint(
                            equalTo: ground.leadingAnchor,
                            constant: Fixture.cellLeadingInset
                        ),
                        cell.trailingAnchor.constraint(
                            equalTo: ground.trailingAnchor,
                            constant: -Fixture.cellTrailingInset
                        ),
                        cell.topAnchor.constraint(equalTo: ground.topAnchor),
                        cell.bottomAnchor.constraint(equalTo: ground.bottomAnchor)
                    ])
                    if let entered = Self.enterEvent() { ground.mouseEntered(with: entered) }
                    return ground
                }

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

            let image = try XCTUnwrap(data, "Failed to render the hovered-state sheet in \(name)")
            try image.write(
                to: directory.appendingPathComponent("sidebar-hovered-states-\(name).png")
            )
        }
        print("Rendered hovered trailing states to \(Render.directory.path)")
    }

    // MARK: - Trailing Edge

    /// The row is the menu's visible source, not merely the few points under the pointer. Once a
    /// trailing control opens a menu, moving into that menu must not crossfade the source away.
    /// All three sidebar row kinds inherit the same presenter lifecycle rather than each menu
    /// callback remembering to pin and unpin its own hover state.
    func testAnOpenMenuCarriesEverySidebarRowsHoverActions() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: 120))

        let project = ProjectRowView(customizationLookup: { _ in .empty })
        project.frame = NSRect(x: 0, y: 84, width: Fixture.width, height: Fixture.height)
        project.configure(
            with: Project(
                name: "Threading",
                folderURL: URL(fileURLWithPath: "/tmp/Threading")
            )
        )

        let session = SessionRowView(customizationLookup: { _ in .empty })
        session.frame = NSRect(x: 0, y: 48, width: Fixture.width, height: Fixture.height)
        session.configure(
            with: AgentSession(kind: .claude, title: "Keep the source visible"),
            activity: .idle
        )

        let terminal = ProjectTerminalRowView()
        terminal.frame = NSRect(x: 0, y: 12, width: Fixture.width, height: Fixture.height)
        terminal.configure(
            with: ProjectTerminal(currentDirectory: "/tmp/Threading", title: "zsh"),
            running: true,
            busy: false,
            projectRoot: nil
        )

        for row in [project, session, terminal] {
            root.addSubview(row)
        }
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        defer { window.close() }

        let projectActions = try XCTUnwrap(
            project.descendant(identified: "sidebar.project.actions")
        )
        let sessionActions = try XCTUnwrap(
            session.descendant(identified: "sidebar.session.hover-controls")
        )
        let terminalAction = try XCTUnwrap(
            terminal.descendant(identified: "sidebar.terminal.actions")
                as? ThemedIconButton
        )
        let fixtures: [(name: String, row: NSView, source: ThemedIconButton, actions: NSView)] = [
            (
                "project",
                project,
                try XCTUnwrap(projectActions.subviews.compactMap { $0 as? ThemedIconButton }.first),
                projectActions
            ),
            (
                "session",
                session,
                try XCTUnwrap(sessionActions.subviews.compactMap { $0 as? ThemedIconButton }.first),
                sessionActions
            ),
            ("terminal", terminal, terminalAction, terminalAction)
        ]

        for fixture in fixtures {
            let token = try XCTUnwrap(ThemedMenuPresenter.present(
                ThemedMenuPresentation(
                    entries: [.item(ThemedMenuItem(title: "Action"))],
                    minimumWidth: 120
                ),
                from: fixture.source,
                selectedEntryIndex: nil,
                onChoose: { _, _ in },
                onDismiss: {}
            ))

            // This is the crossing in the report: the pointer has left the row for the overlay.
            fixture.row.mouseExited(with: try XCTUnwrap(Self.exitEvent()))

            XCTAssertTrue(
                fixture.source.isPresentingMenu,
                "the \(fixture.name) source forgot the menu it opened"
            )
            XCTAssertEqual(
                fixture.actions.alphaValue,
                1,
                "the \(fixture.name) row disappeared while its menu was open"
            )

            ThemedMenuPresenter.dismiss(token)
            XCTAssertFalse(fixture.source.isPresentingMenu)
        }
    }

    /// Every trailing mark lands on one optical line, whatever kind of thing it is.
    ///
    /// A count is text, whose frame is its ink. A hover control is a click target with a glyph
    /// floating inside it — pinned by frame it stops short of the margin the count reaches, and
    /// the row's trailing edge visibly steps inboard under the pointer. `OpticalInsetProviding`
    /// is what closes that gap; this asserts the row actually subtracts it.
    ///
    /// A project row is asserted at rest, where its count and the controls that replace it share
    /// the one line. A session row's archive button takes that same line under the pointer —
    /// it crossfades with the status mark inside the status's own column, so the mark at rest
    /// and the button that replaces it are asserted against the *same* margin.
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

        let sessionRow = Self.hoveredSessionRow(
            AgentSession(kind: .claude, title: "Fix the hover state")
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

    /// The OpenAI knot is a template image, so unlike Claude's fixed-colour mark its pixels are
    /// exactly the tint the row retained for it. A selected row correctly chose selection ink,
    /// then its customization restore put the pre-selection sidebar tint back after every
    /// activity refresh — black title beside a white mark on Threading's orange selection.
    func testASelectedCodexMarkKeepsSelectionInkAfterRowRefresh() throws {
        for theme in AppThemeLibrary.stock {
            try withTheme(theme) {
                let row = SessionRowView(customizationLookup: { _ in .empty })
                let session = AgentSession(kind: .codex, title: "Selected Codex session")

                row.configure(with: session, activity: .idle)
                row.backgroundStyle = .emphasized
                // Shipping rows are configured again whenever activity changes. This second
                // pass reaches the native-content restore that used to overwrite selection ink.
                row.configure(with: session, activity: .working)

                let mark = try XCTUnwrap(
                    row.descendant(identified: "sidebar.session.identity") as? NSImageView
                )
                XCTAssertTrue(try XCTUnwrap(mark.image).isTemplate)
                XCTAssertEqual(
                    mark.contentTintColor?.hexString,
                    Design.Ink.selection.label.hexString,
                    "\(theme.name): a refreshed selected Codex mark should use its row's ink"
                )
            }
        }
    }

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

                let terminal = ProjectTerminalRowView()
                terminal.translatesAutoresizingMaskIntoConstraints = false
                terminal.configure(
                    with: ProjectTerminal(
                        currentDirectory: "/tmp/Threading",
                        title: "sleep"
                    ),
                    running: true,
                    busy: true,
                    projectRoot: "/tmp/Threading"
                )

                let terminalInk = try strongestRowInk(
                    of: terminal,
                    identified: "sidebar.terminal.status",
                    over: fill
                )
                let selectedTerminal = distance(
                    terminalInk,
                    Design.Ink.selection.label.composited(over: fill)
                )
                let ordinaryTerminal = distance(
                    terminalInk,
                    Design.Surface.accent.composited(over: fill)
                )

                XCTAssertLessThanOrEqual(
                    selectedTerminal,
                    ordinaryTerminal,
                    "\(theme.name): a selected terminal spinner did not ink from its fill"
                )
            }
        }
    }

    /// A foreground command and the row's action share one trailing slot. The status must stay
    /// visible at rest, yield under the pointer, return when the pointer leaves, and disappear
    /// when the shell regains the foreground.
    func testATerminalWorkingStatusTradesPlacesWithItsAction() throws {
        let row = ProjectTerminalRowView()
        row.frame = NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height)
        let terminal = ProjectTerminal(currentDirectory: "/tmp/Threading", title: "sleep")

        row.configure(with: terminal, running: true, busy: true, projectRoot: "/tmp/Threading")
        let spinner = try XCTUnwrap(
            row.descendant(identified: "sidebar.terminal.status") as? ThemedSpinner
        )
        let action = try XCTUnwrap(
            row.descendant(identified: "sidebar.terminal.actions") as? ThemedIconButton
        )
        XCTAssertTrue(spinner.isAnimating)
        XCTAssertEqual(spinner.alphaValue, 1)
        XCTAssertEqual(action.alphaValue, 0)

        row.mouseEntered(with: try XCTUnwrap(Self.enterEvent()))
        row.configure(with: terminal, running: true, busy: true, projectRoot: "/tmp/Threading")
        XCTAssertEqual(spinner.alphaValue, 0)
        XCTAssertEqual(action.alphaValue, 1)

        row.mouseExited(with: try XCTUnwrap(Self.exitEvent()))
        row.configure(with: terminal, running: true, busy: true, projectRoot: "/tmp/Threading")
        XCTAssertEqual(spinner.alphaValue, 1)
        XCTAssertEqual(action.alphaValue, 0)

        row.configure(with: terminal, running: true, busy: false, projectRoot: "/tmp/Threading")
        XCTAssertFalse(spinner.isAnimating)
        XCTAssertTrue(spinner.isHidden)
        XCTAssertEqual(action.alphaValue, 0)
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
            busy: false,
            projectRoot: nil
        )
        if let entered = enterEvent() { row.mouseEntered(with: entered) }
        return row
    }

    private static func hoveredSessionRow(
        _ session: AgentSession,
        activity: SessionActivity = .idle,
        loading: Bool = false
    ) -> SessionRowView {
        let row = SessionRowView(customizationLookup: { _ in .empty })
        row.translatesAutoresizingMaskIntoConstraints = false
        row.configure(with: session, activity: activity, isLoading: loading)
        if let entered = enterEvent() {
            row.mouseEntered(with: entered)
            row.configure(with: session, activity: activity, isLoading: loading)
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

    private static func exitEvent() -> NSEvent? {
        NSEvent.enterExitEvent(
            with: .mouseExited,
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
        loading: Bool = false,
        scheduled: Bool = false,
        title: String = "Fix the hover state"
    ) throws -> Int {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)

            var data: Data?
            let render = {
                let cell = SessionRowView(customizationLookup: { _ in .empty })
                cell.translatesAutoresizingMaskIntoConstraints = false
                let row = SidebarHoverRowView()
                row.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(cell)

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
                // The cell sits where the outline actually places it, inside the hover and
                // selection capsule the row draws — see `Fixture.cellLeadingInset`.
                NSLayoutConstraint.activate([
                    cell.leadingAnchor.constraint(
                        equalTo: row.leadingAnchor,
                        constant: Fixture.cellLeadingInset
                    ),
                    cell.trailingAnchor.constraint(
                        equalTo: row.trailingAnchor,
                        constant: -Fixture.cellTrailingInset
                    ),
                    cell.topAnchor.constraint(equalTo: row.topAnchor),
                    cell.bottomAnchor.constraint(equalTo: row.bottomAnchor)
                ])

                // Configured before the hover is asserted, then again after: `configure`
                // reapplies the hover state without animating, which is what makes the
                // hovered stories deterministic rather than a race with the crossfade.
                var session = AgentSession(kind: .claude, title: title)
                session.isPinned = pinned
                cell.configure(
                    with: session,
                    activity: activity,
                    isLoading: loading,
                    isScheduledStart: scheduled
                )
                if hovered, let entered = Self.enterEvent() {
                    row.mouseEntered(with: entered)
                    cell.mouseEntered(with: entered)
                    cell.configure(
                        with: session,
                        activity: activity,
                        isLoading: loading,
                        isScheduledStart: scheduled
                    )
                }
                // The row view owns hover and selection ground; the cell owns the ink that
                // must read on it. Keeping both in the evidence fixture prevents a hover story
                // from proving only that its buttons appeared while omitting their hit region.
                row.isSelected = selected
                if selected {
                    row.isEmphasized = true
                    cell.backgroundStyle = .emphasized
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

            let image = try XCTUnwrap(data, "Failed to render \(story) in \(name)")
            try image.write(
                to: directory.appendingPathComponent("sidebar-row-\(story)-\(name).png")
            )
            written += 1
        }
        return written
    }

    private func writeBusyTerminal(story: String) throws -> Int {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?

            let render = {
                let cell = ProjectTerminalRowView()
                cell.translatesAutoresizingMaskIntoConstraints = false
                let row = SidebarHoverRowView()
                row.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(cell)

                let host = NSView(
                    frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height)
                )
                host.appearance = appearance
                host.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    row.topAnchor.constraint(equalTo: host.topAnchor),
                    row.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    cell.leadingAnchor.constraint(
                        equalTo: row.leadingAnchor,
                        constant: Fixture.cellLeadingInset
                    ),
                    cell.trailingAnchor.constraint(
                        equalTo: row.trailingAnchor,
                        constant: -Fixture.cellTrailingInset
                    ),
                    cell.topAnchor.constraint(equalTo: row.topAnchor),
                    cell.bottomAnchor.constraint(equalTo: row.bottomAnchor)
                ])

                cell.configure(
                    with: ProjectTerminal(
                        currentDirectory: "/tmp/Threading",
                        title: "AnotherTerminal"
                    ),
                    running: true,
                    busy: true,
                    projectRoot: "/tmp/Threading"
                )
                row.isSelected = true
                row.isEmphasized = true
                cell.backgroundStyle = .emphasized

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
