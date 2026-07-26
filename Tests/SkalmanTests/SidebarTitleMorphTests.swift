import AppKit
import XCTest
@testable import Skalman

/// The sidebar's names are `MorphingTitleLabel`s, so a rename is animated character by
/// character rather than swapped. What is worth pinning is not the animation — that is the
/// package's — but the two decisions this side owns: *when* a change counts as a rename, and
/// that a row still shows what it is meant to say when it does not.
@MainActor
final class SidebarTitleMorphTests: XCTestCase {

    // MARK: - Helpers

    private func label(
        _ identifier: String,
        in view: NSView
    ) throws -> MorphingTitleLabel {
        func walk(_ node: NSView) -> MorphingTitleLabel? {
            if node.accessibilityIdentifier() == identifier,
               let found = node as? MorphingTitleLabel {
                return found
            }
            for child in node.subviews {
                if let found = walk(child) { return found }
            }
            return nil
        }

        return try XCTUnwrap(walk(view), "no MorphingTitleLabel identified as \(identifier)")
    }

    private func sessionRow() -> SessionRowView {
        let row = SessionRowView(customizationLookup: { _ in .empty })
        row.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        row.layoutSubtreeIfNeeded()
        return row
    }

    // MARK: - Session rows

    func testSessionRowShowsItsTitle() throws {
        let row = sessionRow()
        row.configure(with: AgentSession(kind: .claude, title: "Land the fix"), activity: .idle)

        XCTAssertEqual(
            try label("sidebar.session.title", in: row).stringValue,
            "Land the fix"
        )
    }

    /// The rename an agent or the user performs: same session, different name. This is the
    /// one case the morph exists for.
    func testRenamingASessionReachesTheLabel() throws {
        var session = AgentSession(kind: .claude, title: "Land the fix")
        let row = sessionRow()
        row.configure(with: session, activity: .idle)

        session.customTitle = "Land the other fix"
        row.configure(with: session, activity: .idle)

        XCTAssertEqual(
            try label("sidebar.session.title", in: row).stringValue,
            "Land the other fix"
        )
    }

    /// Rows reconfigure constantly while an agent works — the status indicator moves, the
    /// account chip is re-read — and none of that renames anything. A morph on every pass
    /// would make a working session's name flicker for the length of the turn.
    func testReconfiguringWithTheSameTitleIsNotTreatedAsARename() throws {
        let session = AgentSession(kind: .claude, title: "Land the fix")
        let row = sessionRow()
        row.configure(with: session, activity: .idle)

        let title = try label("sidebar.session.title", in: row)
        for activity in [SessionActivity.working, .idle, .working] {
            row.configure(with: session, activity: activity)
            XCTAssertEqual(title.stringValue, "Land the fix")
        }
    }

    /// A cell arriving from the reuse pool carries the last row's name. Morphing from it
    /// would animate a transition between two unrelated sessions, which reads as a glitch
    /// rather than as a rename — so a recycled row lands its name directly.
    func testACellRecycledForAnotherSessionLandsItsTitleDirectly() throws {
        let row = sessionRow()
        row.configure(with: AgentSession(kind: .claude, title: "First"), activity: .idle)
        row.configure(with: AgentSession(kind: .codex, title: "Second"), activity: .idle)

        XCTAssertEqual(try label("sidebar.session.title", in: row).stringValue, "Second")
    }

    /// The row's own accessibility value is what VoiceOver reads, and the morphing view is
    /// not an `NSTextField` the table would expose for us.
    func testTitleIsExposedToAccessibility() throws {
        let row = sessionRow()
        row.configure(with: AgentSession(kind: .claude, title: "Land the fix"), activity: .idle)

        let title = try label("sidebar.session.title", in: row)
        XCTAssertEqual(title.accessibilityValue() as? String, "Land the fix")
        XCTAssertEqual(title.accessibilityLabel(), "Land the fix")
    }

    // MARK: - Ink

    /// The package freezes a `CGColor` per glyph, so ink stated once and never revisited
    /// survives a theme switch as the old theme's value. The row states a rule instead.
    func testSelectionInvertsTheTitleAndDeselectionRestoresIt() throws {
        let row = sessionRow()
        row.configure(with: AgentSession(kind: .claude, title: "Land the fix"), activity: .idle)
        let title = try label("sidebar.session.title", in: row)

        let resting = title.textColor
        row.backgroundStyle = .emphasized
        XCTAssertNotEqual(title.textColor, resting)

        row.backgroundStyle = .normal
        XCTAssertEqual(title.textColor, resting)
    }

    func testADormantSessionIsDimmed() throws {
        let row = sessionRow()
        let session = AgentSession(kind: .claude, title: "Land the fix")

        row.configure(with: session, activity: .idle)
        let live = try label("sidebar.session.title", in: row).textColor

        row.configure(with: session, activity: .dormant)
        XCTAssertNotEqual(try label("sidebar.session.title", in: row).textColor, live)
    }

    // MARK: - Truncation

    /// The one way this could read worse than the `NSTextField` it replaces: the label
    /// clips its layer, so without truncation a long name is cut dead mid-glyph. Sidebar
    /// rows are narrow and session names are sentences, so this is the common case.
    func testALongTitleIsEllipsizedRatherThanClipped() throws {
        let row = sessionRow()
        row.configure(
            with: AgentSession(
                kind: .claude,
                title: "Land what the last sessions built but never committed"
            ),
            activity: .idle
        )
        row.layoutSubtreeIfNeeded()

        let title = try label("sidebar.session.title", in: row)
        let drawn = title.subviews
            .flatMap { $0.layer?.sublayers ?? [] }
            .compactMap { $0 as? CATextLayer }

        XCTAssertFalse(drawn.isEmpty, "the title drew nothing")
        for glyph in drawn {
            XCTAssertLessThanOrEqual(
                glyph.frame.maxX,
                title.bounds.maxX + 0.5,
                "a glyph overruns the label and is clipped rather than truncated"
            )
        }
        XCTAssertTrue(
            drawn.contains { ($0.string as? NSAttributedString)?.string == "\u{2026}" },
            "a shortened title says nothing about having been shortened"
        )
    }

    // MARK: - Project rows

    func testProjectRowShowsItsName() throws {
        let row = ProjectRowView(customizationLookup: { _ in .empty })
        row.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        row.configureAsRepository(named: "AnotherTerminal")

        XCTAssertEqual(
            try label("sidebar.project.title", in: row).stringValue,
            "AnotherTerminal"
        )
    }

    func testARepositoryHeadingRenamedIsADifferentHeading() throws {
        let row = ProjectRowView(customizationLookup: { _ in .empty })
        row.frame = NSRect(x: 0, y: 0, width: 220, height: 24)

        // A heading's name *is* its identity — there is no record behind it that stayed the
        // same while the name moved — so it lands directly rather than morphing.
        row.configureAsRepository(named: "AnotherTerminal")
        row.configureAsRepository(named: "Skalman")

        XCTAssertEqual(try label("sidebar.project.title", in: row).stringValue, "Skalman")
    }

    // MARK: - Intrinsic size

    /// A font change must reach the layout engine, which caches the *wrapper's* intrinsic
    /// size separately from the inner label's. Left stale, a tab that swaps weight on
    /// selection lays the heavier line out in the lighter line's width, and tail truncation
    /// cuts two characters to fit an ellipsis into a shortfall of a point and a half — the
    /// settings sidebar read "Usage" as "Usa…" precisely while it was selected.
    func testAFontChangeReachesTheLayoutEngine() {
        let title = MorphingTitleLabel()
        title.font = Design.Typography.controlRegular()
        title.setStringValue("Usage", animated: false)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        title.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            title.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(title.frame.width, title.intrinsicContentSize.width)

        title.font = Design.Typography.control()
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            title.frame.width,
            title.intrinsicContentSize.width,
            "the engine is still laying the new weight out in the old weight's width"
        )
    }

    /// The symptom, pinned where it showed: a sidebar tab selected — which is what swaps its
    /// title to the emphasized weight — must still give its label the width the heavier line
    /// needs, or truncation fires with the whole pane's slack sitting beside it.
    func testASelectedTabKeepsItsWholeTitle() throws {
        let tab = ThemedTabItemView(
            title: "Usage",
            symbolName: "gauge.with.needle",
            placement: .sidebar,
            inkSource: .chrome
        )

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        host.addSubview(tab)
        NSLayoutConstraint.activate([
            tab.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            tab.topAnchor.constraint(equalTo: host.topAnchor),
            tab.widthAnchor.constraint(equalToConstant: 180)
        ])
        host.layoutSubtreeIfNeeded()

        tab.isSelected = true
        host.layoutSubtreeIfNeeded()

        let title = try XCTUnwrap(morphingLabel(in: tab))
        XCTAssertGreaterThanOrEqual(
            title.frame.width,
            title.intrinsicContentSize.width,
            "a selected tab's label is narrower than its own emphasized title"
        )
    }

    private func morphingLabel(in view: NSView) -> MorphingTitleLabel? {
        if let found = view as? MorphingTitleLabel { return found }
        for child in view.subviews {
            if let found = morphingLabel(in: child) { return found }
        }
        return nil
    }
}
