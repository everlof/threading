import AppKit
import XCTest
@testable import Threading

/// A list row states its selection in the theme's colours, not in AppKit's.
///
/// The bug: nothing in the attachments pane claimed selection, so the selected file drew with
/// the **system** accent — a Finder blue bar in the middle of a lavender window, and the same
/// blue whatever theme was in force, since AppKit reads that colour from the user's settings
/// rather than from anything the app paints. Asserted from pixels, because the mistake is a
/// colour that no property in the app was ever set to.
@MainActor
final class ThemedTableRowSelectionTests: XCTestCase {

    private enum Fixture {
        static let width: CGFloat = 220
        static let height: CGFloat = 32
        /// A ground no theme's selection sits on, so a row that painted nothing is obvious.
        static let ground = NSColor.white
    }

    /// How far a rendered colour may sit from the one the fixture asked for, summed over the
    /// channels — the working-space conversion, not the measurement.
    private static let tolerance: CGFloat = 0.02

    // MARK: - The fill

    /// Asked as "which of the two colours is this", not as an exact match: the row is rendered
    /// through the display's own colour management, so a saturated fill comes back a hundredth
    /// or two off the arithmetic — far too little to confuse the theme's answer with AppKit's,
    /// and more than an equality would forgive.
    func testASelectedRowFillsWithTheThemesSelectionRole() throws {
        for theme in AppThemeLibrary.stock where !theme.isSystem {
            try withTheme(theme) {
                let drawn = try middlePixel(of: render(selected: true))

                XCTAssertGreaterThan(
                    distance(drawn, Fixture.ground),
                    Self.tolerance,
                    "\(theme.name): a selected row should paint something at all"
                )
                XCTAssertLessThan(
                    distance(drawn, expectedSelection()),
                    distance(drawn, appKitsOwnSelection()),
                    "\(theme.name): a selected row should fill with its own selection role, "
                        + "not with the system accent"
                )
            }
        }
    }

    /// The other half of the same claim: the row paints *only* when it is selected, so an
    /// unselected one leaves the list's own ground showing.
    func testAnUnselectedRowPaintsNothing() throws {
        let theme = try styledTheme()

        try withTheme(theme) {
            let drawn = try middlePixel(of: render(selected: false))

            XCTAssertLessThanOrEqual(
                distance(drawn, Fixture.ground),
                Self.tolerance,
                "an unselected row should leave the ground it sits on alone"
            )
        }
    }

    /// The fill is read at draw time rather than kept from the theme the row was built under —
    /// the rule every themed component here follows, and the one a cached `CGColor` breaks.
    func testTheFillFollowsALiveThemeSwitch() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height))
        let row = ThemedTableRowView(frame: host.bounds)
        row.isSelected = true
        host.addSubview(row)
        host.applyLayerBackground(Fixture.ground)

        var fills: [NSColor] = []
        for theme in try twoStyledThemesWithDifferentSelections() {
            try withTheme(theme) {
                fills.append(try middlePixel(of: try draw(host)))
            }
        }

        XCTAssertGreaterThan(
            distance(fills[0], fills[1]),
            Self.tolerance,
            "one row drawn under two themes should show two selections"
        )
    }

    /// Under **System** the row draws nothing of its own: AppKit's highlight is the user's
    /// accent, its emphasis and its vibrancy, and replacing it there would be the same mistake
    /// in the other direction.
    ///
    /// Asserted as a colour rather than against a stock `NSTableRowView`, which would have been
    /// the more direct claim and is not available: AppKit calls `drawSelection(in:)` on a row
    /// that *overrides* it and skips it entirely on one that does not, so a detached stock row
    /// draws nothing at all and the two are incomparable outside a list.
    func testTheSystemThemeKeepsAppKitsOwnHighlight() throws {
        try withTheme(.system) {
            let drawn = try middlePixel(of: render(selected: true))

            XCTAssertLessThan(
                distance(drawn, appKitsOwnSelection()),
                distance(drawn, expectedSelection()),
                "under System the row should hand the highlight back to AppKit"
            )
        }
    }

    // MARK: - The pane that reported it

    func testTheAttachmentsListSelectsThroughTheThemedRow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A picture, because that is what the pane admits — see `AttachmentReferenceDetector`.
        let file = root.appendingPathComponent("mark.png")
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: file)

        let sessionID = SessionID()
        XCTAssertEqual(
            SessionAttachmentStore.shared.record(
                urls: [file], sessionID: sessionID, projectRoot: root
            ).count,
            1,
            "the fixture attachment was refused"
        )

        let controller = SessionAttachmentsViewController(sessionID: sessionID)
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
        controller.view.layoutSubtreeIfNeeded()

        let table = try XCTUnwrap(
            firstTable(in: controller.view),
            "the attachments pane should hold a list"
        )
        XCTAssertEqual(table.numberOfRows, 1, "the recorded attachment should be listed")
        XCTAssertTrue(
            table.rowView(atRow: 0, makeIfNecessary: true) is ThemedTableRowView,
            "the attachments list should select through the themed row"
        )
    }

    // MARK: - Harness

    /// Draws the row alone over a known ground, so what lands in the bitmap is the selection
    /// and nothing else — no cell, no list, no scroll view.
    private func render(selected: Bool) throws -> NSBitmapImageRep {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height))
        let row = ThemedTableRowView(frame: host.bounds)
        row.isSelected = selected
        row.isEmphasized = selected
        host.addSubview(row)
        // `applyLayerBackground` rather than a bare `CGColor`: the fill has to be *recorded* for
        // `resolvedGround` to find it, and the row now measures its ground to decide how far the
        // selection has to be held back — see `SelectionSurface.quiet`.
        host.applyLayerBackground(Fixture.ground)
        return try draw(host)
    }

    private func draw(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "Failed to build a bitmap for the row"
        )
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The middle of the row — inside the fill under every corner radius a theme can ask for.
    private func middlePixel(of rep: NSBitmapImageRep) throws -> NSColor {
        let colour = try XCTUnwrap(
            rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2),
            "No pixel at the centre of the row"
        )
        return try XCTUnwrap(colour.usingColorSpace(.sRGB), "The pixel would not convert")
    }

    private func distance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        guard let first = first.usingColorSpace(.sRGB),
              let second = second.usingColorSpace(.sRGB) else { return .greatestFiniteMagnitude }

        return abs(first.redComponent - second.redComponent)
            + abs(first.greenComponent - second.greenComponent)
            + abs(first.blueComponent - second.blueComponent)
    }

    /// The colour the fill *should* have come out, resolved under the appearance the row was
    /// drawn in — a themed role is dynamic, and reading it under the wrong one is how a dark
    /// theme's assertion quietly measures its light variant.
    private func expectedSelection() -> NSColor {
        var colour = NSColor.clear
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            colour = SelectionSurface.quiet(over: Fixture.ground)
                .fill
                .composited(over: Fixture.ground)
        }
        return colour
    }

    /// The colour the bug was: AppKit's selected-row fill, which is the *user's* accent and has
    /// nothing to do with the window it lands in.
    private func appKitsOwnSelection() -> NSColor {
        var colour = NSColor.clear
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            colour = NSColor.selectedContentBackgroundColor.composited(over: Fixture.ground)
        }
        return colour
    }

    private func styledTheme() throws -> AppTheme {
        try XCTUnwrap(
            AppThemeLibrary.stock.first { !$0.isSystem },
            "Expected at least one authored stock theme"
        )
    }

    /// Two themes whose selections are far enough apart to tell one drawn row from the other —
    /// picked by colour rather than by name, so a retired style is not a failing test.
    private func twoStyledThemesWithDifferentSelections() throws -> [AppTheme] {
        let styled = AppThemeLibrary.stock.filter { !$0.isSystem }
        for first in styled {
            let fill = first.resolved(.selection).composited(over: Fixture.ground)
            if let second = styled.first(where: {
                distance($0.resolved(.selection).composited(over: Fixture.ground), fill)
                    > Self.tolerance * 10
            }) {
                return [first, second]
            }
        }
        throw XCTSkip("No two stock themes state different selections")
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let found = firstTable(in: child) { return found }
        }
        return nil
    }

    /// `apply` is what the app itself calls, and it sets both halves of what the row reads:
    /// `AppThemeLibrary.current`, which decides whether the row draws at all, and
    /// `AppThemePalette.current`, which carries the colour and the corner.
    private func withTheme(_ theme: AppTheme, _ body: () throws -> Void) rethrows {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }

        AppThemeLibrary.apply(theme)
        try body()
    }
}
