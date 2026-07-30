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

        XCTAssertEqual(written, 10, "Every story should render in both appearances")
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
                let session = AgentSession(kind: .claude, title: title)
                row.configure(with: session, activity: activity)
                if hovered, let entered = Self.enterEvent() {
                    row.mouseEntered(with: entered)
                    row.configure(with: session, activity: activity)
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
