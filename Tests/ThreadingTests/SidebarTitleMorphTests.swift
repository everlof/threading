import AppKit
import LabelMorph
import XCTest
@testable import Threading

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

    /// A row in a window sized like a sidebar's. The package refuses to animate a label that
    /// is not in a window, so the one thing these tests never checked — that a rename actually
    /// moves — can only be asserted against a hosted row. The window is never ordered on
    /// screen: an unshown one still lays out, and `window != nil` is all the morph asks.
    private func hostedSessionRow() -> (SessionRowView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let row = SessionRowView(customizationLookup: { _ in .empty })
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.widthAnchor.constraint(equalToConstant: 220),
            row.heightAnchor.constraint(equalToConstant: 24)
        ])
        window.layoutIfNeeded()
        return (row, window)
    }

    /// The glyph layers currently carrying a morph animation.
    private func animatingGlyphs(in title: MorphingTitleLabel) throws -> [CALayer] {
        let morphing = try XCTUnwrap(
            title.subviews.compactMap { $0 as? MorphingLabel }.first,
            "the wrapper is not holding a MorphingLabel"
        )
        return (morphing.layer?.sublayers ?? [])
            .filter { !($0.animationKeys() ?? []).isEmpty }
    }

    /// The header names the same page it named before, under the same identity — the
    /// definition of a rename it should morph through. Hosted for the same reason the row is.
    func testRenamingThePageTitleAnimatesItsGlyphs() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let header = PageTitleView(symbolName: "folder", inkSource: .backdrop)
        let content = window.contentView!
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        let identity = UUID()
        header.update(title: "Land the fix", symbolName: "folder", identity: identity)
        window.layoutIfNeeded()

        header.update(title: "Land the other fix", symbolName: "folder", identity: identity)

        let title = try XCTUnwrap(
            walkForMorphingTitle(in: header),
            "the header has no morphing title"
        )
        XCTAssertFalse(
            try animatingGlyphs(in: title).isEmpty,
            "the header's rename landed without animating a single glyph"
        )
    }

    private func walkForMorphingTitle(in view: NSView) -> MorphingTitleLabel? {
        if let found = view as? MorphingTitleLabel { return found }
        for child in view.subviews {
            if let found = walkForMorphingTitle(in: child) { return found }
        }
        return nil
    }

    /// The bug this suite was blind to: every assertion about a rename read `stringValue`,
    /// which is set the moment the morph *starts*, so a rename that landed instantly passed
    /// them all. This asserts the animation itself.
    func testRenamingAHostedSessionAnimatesItsGlyphs() throws {
        let (row, _) = hostedSessionRow()
        var session = AgentSession(kind: .claude, title: "Land the fix")
        row.configure(with: session, activity: .idle)
        row.layoutSubtreeIfNeeded()

        session.customTitle = "Land the other fix"
        row.configure(with: session, activity: .idle)

        let title = try label("sidebar.session.title", in: row)
        XCTAssertFalse(
            try animatingGlyphs(in: title).isEmpty,
            "the rename landed without animating a single glyph"
        )
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
        // Asked of the ink rather than the layers: a glyph layer is a raster tile,
        // padded past the glyph's metrics so overhanging ink is not clipped, so it
        // overruns the label by that margin whether or not the text fits.
        let ink = try innerLabel(of: title).glyphInkFrames
        XCTAssertEqual(ink.count, drawn.count)
        for box in ink {
            XCTAssertLessThanOrEqual(
                box.maxX,
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
        row.configureAsRepository(named: "Threading")

        XCTAssertEqual(try label("sidebar.project.title", in: row).stringValue, "Threading")
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

    // MARK: - Rasterisation

    /// The package rasterises each glyph against a ground so macOS's font smoothing
    /// can run — the stem-darkening pass that, below 2x, is most of what separates
    /// legible text from grey text. Only the *polarity* of that ground against the
    /// ink is load-bearing, and getting it backwards is silent: the text renders at
    /// visibly the wrong weight on an external display and at no weight at all on
    /// the Retina one the mistake is usually made on.
    func testASidebarRowSmoothsItsNameAgainstAGroundThatContrastsTheInk() throws {
        let row = sessionRow()
        row.configure(with: AgentSession(kind: .claude, title: "Land the fix"), activity: .idle)

        let inner = try innerLabel(of: try label("sidebar.session.title", in: row))
        let ground = try XCTUnwrap(inner.rasterizationBackground,
                                   "a row on a known surface should state it")

        let inkLuminance = try luminance(of: inner.textColor)
        let groundLuminance = try luminance(of: ground)
        XCTAssertGreaterThan(
            abs(inkLuminance - groundLuminance), 0.25,
            "ink and ground should sit on opposite sides of the contrast, not beside each other"
        )
    }

    /// Guards the swap itself: a `CATextLayer` would draw its own text and leave
    /// `contents` empty, and nothing else in the suite would notice — the
    /// characters, metrics and truncation would all still be right.
    func testASidebarRowsGlyphsAreRasterisedTilesRatherThanSelfDrawnText() throws {
        let row = sessionRow()
        row.configure(with: AgentSession(kind: .claude, title: "Land the fix"), activity: .idle)
        row.layoutSubtreeIfNeeded()

        let inner = try innerLabel(of: try label("sidebar.session.title", in: row))
        let glyphs = try XCTUnwrap(inner.layer?.sublayers, "the name should have laid out")
        XCTAssertFalse(glyphs.isEmpty)

        for glyph in glyphs {
            glyph.displayIfNeeded()
            XCTAssertNotNil(glyph.contents,
                            "every glyph should carry a rasterised tile of its own")
        }
    }

    /// The package's label, reached through the app's wrapper — the ground and ink
    /// are set on it, and only the wrapper knows how to resolve them.
    private func innerLabel(of title: MorphingTitleLabel) throws -> MorphingLabel {
        try XCTUnwrap(title.subviews.compactMap { $0 as? MorphingLabel }.first)
    }

    private func luminance(of color: NSColor) throws -> CGFloat {
        let resolved = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return 0.2126 * resolved.redComponent
            + 0.7152 * resolved.greenComponent
            + 0.0722 * resolved.blueComponent
    }
}
