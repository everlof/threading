import AppKit
import XCTest
@testable import Threading

/// The two ways a broad corner went wrong: a fill wider than the shape it turns, and content
/// held at a distance that a modest corner earned and a 40pt one eats.
///
/// Both were found under Botanical, whose panel corner is 40 and whose control corner is 24 —
/// the widest silhouette any stock theme states, and therefore the one that shows what the
/// tokens do when a theme takes them seriously.
@MainActor
final class PanelContentInsetTests: XCTestCase {

    private enum Fixture {
        /// A menu row: far wider than it is tall, and shorter than Botanical's control corner.
        static let row = NSRect(x: 0, y: 0, width: 190, height: 26)
        static let broadControlCorner: CGFloat = 24
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - The inset

    /// The base inset stands unless the corner is broad enough to reach past it.
    func testAModestCornerLeavesTheInsetAlone() {
        for radius in [CGFloat(0), 2, 6, 8, 9, 10, 12] {
            XCTAssertEqual(
                Design.Spacing.inset(inside: radius),
                Design.Spacing.inset,
                "a \(radius)pt corner asked content to move"
            )
        }
    }

    /// Botanical's card and Claymorphism's, measured: content starts far enough in that its own
    /// corner clears the arc by the base inset along the diagonal, where the arc comes closest.
    func testABroadCornerMovesContentIn() {
        XCTAssertEqual(Design.Spacing.inset(inside: 40), 20)
        XCTAssertEqual(Design.Spacing.inset(inside: 32), 18)

        for radius in stride(from: CGFloat(13), through: 64, by: 1) {
            let inset = Design.Spacing.inset(inside: radius)
            let diagonalClearance = radius - (radius - inset) * 2.0.squareRoot()
            XCTAssertGreaterThanOrEqual(
                diagonalClearance,
                Design.Spacing.inset - 1,
                "content inside a \(radius)pt corner stands \(diagonalClearance)pt off the arc"
            )
        }
    }

    /// A surface that pads tighter than a card says so, and keeps its own measure until the
    /// corner reaches past it — a chat bubble is `medium`, not a card's `inset`.
    func testASurfaceKeepsItsOwnPaddingUntilTheCornerReachesPastIt() {
        let bubble = Design.Spacing.medium

        XCTAssertEqual(Design.Spacing.inset(inside: 10, from: bubble), bubble)
        XCTAssertEqual(Design.Spacing.inset(inside: 40, from: bubble), 19)
        XCTAssertLessThan(
            Design.Spacing.inset(inside: 40, from: bubble),
            Design.Spacing.inset(inside: 40),
            "a bubble was widened to a card's padding"
        )
    }

    /// The role form and the measurement form are the same answer, so a call site may state
    /// whichever it has.
    func testTheInsetFollowsTheThemeThroughTheSurfaceRole() {
        AppThemePalette.set(AppThemeStyles.botanical)
        XCTAssertEqual(Design.Spacing.inset(inside: SurfaceRadius.panel), 20)

        AppThemePalette.set(.system)
        XCTAssertEqual(Design.Spacing.inset(inside: SurfaceRadius.panel), Design.Spacing.inset)
    }

    // MARK: - The silhouette

    /// `NSBezierPath` clamps a corner's two axes separately, so a radius wider than the rect is
    /// tall becomes a taper rather than a capsule — the shape a highlighted menu row drew under
    /// Botanical while the layer-backed surfaces beside it drew capsules.
    func testACornerBroaderThanItsRowIsFittedToTheRow() {
        let shape = ThemedSurface.Shape(rect: Fixture.row, radius: Fixture.broadControlCorner)
        XCTAssertEqual(shape.radius, Fixture.row.height / 2)

        let square = ThemedSurface.Shape(
            rect: NSRect(x: 0, y: 0, width: 16, height: 16),
            radius: Fixture.broadControlCorner
        )
        XCTAssertEqual(square.radius, 8, "a corner may still take a small square to a disc")

        let ordinary = ThemedSurface.Shape(rect: Fixture.row, radius: 8)
        XCTAssertEqual(ordinary.radius, 8, "a corner that fits was moved anyway")
    }

    /// The fitted corner, in ink.
    ///
    /// A capsule's cap runs no further along the top edge than it does down the side; the taper
    /// this replaced ran 15pt in from a 13pt half-height, which is what read as pointed.
    func testABroadCornerDrawsNoTaper() throws {
        let profile = try leadingEdgeProfile {
            ThemedSurface.draw(
                Fixture.row,
                fill: .black,
                radius: Fixture.broadControlCorner,
                bevel: .none
            )
        }

        let run = try capRun(profile)
        XCTAssertLessThanOrEqual(
            run,
            Fixture.row.height / 2,
            "the cap runs \(run)pt along the top edge of a \(Fixture.row.height)pt row"
        )
        XCTAssertEqual(profile.last ?? -1, 0, "the cap never reached the row's leading edge")
    }

    /// The same rule where the bug was reported: the row a theme's own menu highlights.
    ///
    /// A row may take the whole half — that is a capsule, and a capsule keeps a long flat edge —
    /// where a square may not, because it has none to keep.
    func testAFittedCornerFollowsTheShapeItTurns() {
        AppThemePalette.set(AppThemeStyles.botanical)

        XCTAssertEqual(
            Design.Radius.control(fitting: Fixture.row.size),
            Fixture.row.height / 2,
            "a row-shaped fill did not reach the capsule its theme states"
        )
        XCTAssertEqual(
            Design.Radius.control(fitting: CGSize(width: 24, height: 24)),
            24 * Design.Radius.cornerFitFraction,
            "a square took more than a corner"
        )
        XCTAssertLessThan(
            Design.Radius.control(fitting: Fixture.row.size),
            Fixture.broadControlCorner,
            "the theme's unfitted control corner reached a row that cannot turn it"
        )
    }

    /// The System theme's corner is under every cap, so none of this reaches it — the fitting is
    /// a ceiling for themes that state a broad one, not a new shape for the stock look.
    func testTheStockCornerIsUnmovedByTheFitting() {
        AppThemePalette.set(.system)
        let stock = Design.Radius.control

        XCTAssertEqual(Design.Radius.control(fitting: Fixture.row.size), stock)
        XCTAssertEqual(
            Design.Radius.control(fitting: CGSize(width: 16, height: 16)),
            16 * Design.Radius.cornerFitFraction,
            "the 16pt square that this fitting was written for stopped being fitted"
        )
    }

    /// The sidebar's selected chat, which draws the same fill from its own path rather than
    /// through `ThemedSurface.draw` — so the fitting has to be stated there too, and the
    /// selection and the hover wash under it have to keep agreeing about the silhouette.
    func testTheSelectedSidebarRowDrawsNoTaperUnderABroadTheme() throws {
        AppThemePalette.set(AppThemeStyles.botanical)
        AppThemeLibrary.apply(AppThemeStyles.botanical)
        defer { AppThemeLibrary.apply(.system) }

        let row = SidebarHoverRowView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        row.isSelected = true

        let profile = try leadingEdgeProfile(size: row.frame.size) {
            row.drawSelection(in: row.bounds)
        }
        let run = try capRun(profile)
        XCTAssertLessThanOrEqual(
            run,
            row.frame.height / 2,
            "the selection's cap runs \(run)pt along a \(row.frame.height)pt row"
        )
    }

    // MARK: - A fill that runs to the edge

    /// How far a corner reaches along its edge, for content already held in from the side.
    func testACornerReachesAlongItsEdgePastAFillHeldInFromTheSide() {
        let margin = ThemedMenuMetrics.outerInset

        XCTAssertEqual(Design.Radius.edgeReach(of: 40, clearing: margin), 18.93, accuracy: 0.01)
        XCTAssertEqual(Design.Radius.edgeReach(of: 32, clearing: margin), 13.35, accuracy: 0.01)
        XCTAssertEqual(
            Design.Radius.edgeReach(of: margin, clearing: margin),
            0,
            "a corner no wider than the margin has nothing to reach past"
        )
        XCTAssertEqual(Design.Radius.edgeReach(of: 0, clearing: margin), 0)
    }

    /// The menu's rows start where its corner has finished, so a highlighted first or last row
    /// cannot draw outside the panel holding it — neither clips the other.
    func testAMenuStartsItsRowsWhereItsCornerHasFinished() {
        AppThemePalette.set(AppThemeStyles.botanical)
        XCTAssertEqual(ThemedMenuMetrics.verticalOuterInset, 19)
        XCTAssertGreaterThanOrEqual(
            ThemedMenuMetrics.verticalOuterInset,
            Design.Radius.edgeReach(
                of: Design.Radius.panel,
                clearing: ThemedMenuMetrics.outerInset
            ),
            "the first row's fill starts while the panel's corner is still outside it"
        )

        AppThemePalette.set(AppThemeStyles.claymorphism)
        XCTAssertEqual(ThemedMenuMetrics.verticalOuterInset, 14)

        AppThemePalette.set(.system)
        XCTAssertEqual(
            ThemedMenuMetrics.verticalOuterInset,
            ThemedMenuMetrics.outerInset,
            "a modest corner moved a menu that had nothing to clear"
        )
    }

    /// The panel is as much taller as its ends are wider — a menu that reserved the old inset
    /// would put its last row where the corner is.
    func testAMenuPanelIsAsTallAsItsEndsAsk() {
        let entries: [ThemedMenuEntry] = (0..<4).map {
            .item(ThemedMenuItem(title: "Row \($0)"))
        }
        let rows = ThemedMenuMetrics.heights(for: entries).reduce(0, +)

        AppThemePalette.set(.system)
        let stock = ThemedMenuMetrics.height(for: entries)
        XCTAssertEqual(stock, rows + ThemedMenuMetrics.outerInset * 2)

        AppThemePalette.set(AppThemeStyles.botanical)
        XCTAssertEqual(
            ThemedMenuMetrics.height(for: entries),
            rows + ThemedMenuMetrics.verticalOuterInset * 2
        )
        XCTAssertGreaterThan(ThemedMenuMetrics.height(for: entries), stock)
    }

    // MARK: - A live theme switch

    /// A constraint's constant freezes exactly the way a layer's corner does, so the padding is
    /// re-fitted by the sweep that re-applies the corner — not left wearing the padding of the
    /// theme the card happened to be built under.
    func testAPaddedPanelRefitsItsInsetWhenTheThemeChanges() {
        AppThemePalette.set(.system)

        let card = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        card.applySurface(fill: Design.Surface.panel, radius: .panel)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        let padding = [
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: Design.Spacing.inset),
            content.leadingAnchor.constraint(
                equalTo: card.leadingAnchor, constant: Design.Spacing.inset
            ),
            content.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -Design.Spacing.inset
            ),
            content.bottomAnchor.constraint(
                equalTo: card.bottomAnchor, constant: -Design.Spacing.inset
            )
        ]
        NSLayoutConstraint.activate(padding)
        card.holdAtContentInset(padding)

        XCTAssertEqual(padding.map(\.constant), [12, 12, -12, -12])

        AppThemePalette.set(AppThemeStyles.botanical)
        AppThemeRefresh.repaint(card)
        XCTAssertEqual(
            padding.map(\.constant),
            [20, 20, -20, -20],
            "a 40pt corner arrived and the content stayed where a 10pt corner put it"
        )

        AppThemePalette.set(.system)
        AppThemeRefresh.repaint(card)
        XCTAssertEqual(padding.map(\.constant), [12, 12, -12, -12], "the padding did not come back")
    }

    /// Padding the content already carries is not paid twice: a settings card stacks rows that
    /// pad themselves, so the card owes only what its corner asks beyond that.
    func testAPanelPaysOnlyWhatItsContentDoesNotAlreadyCarry() {
        AppThemePalette.set(AppThemeStyles.botanical)

        let card = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        card.applySurface(fill: Design.Surface.panel, radius: .panel)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        let ends = [
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2)
        ]
        NSLayoutConstraint.activate(ends)
        card.holdAtContentInset(ends, less: Design.Spacing.medium)

        XCTAssertEqual(ends.map(\.constant), [10, -10])

        AppThemePalette.set(.system)
        AppThemeRefresh.repaint(card)
        XCTAssertEqual(
            ends.map(\.constant),
            [2, -2],
            "a modest corner asked the card for more than the difference"
        )
    }

    /// A card built while a broad theme is current starts fitted, rather than waiting for a
    /// theme change that may never come.
    func testAPanelBuiltUnderABroadThemeStartsFitted() {
        AppThemePalette.set(AppThemeStyles.botanical)

        let card = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        card.applySurface(fill: Design.Surface.panel, radius: .panel)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        let leading = content.leadingAnchor.constraint(
            equalTo: card.leadingAnchor,
            constant: Design.Spacing.inset
        )
        NSLayoutConstraint.activate([leading])
        card.holdAtContentInset([leading])

        XCTAssertEqual(leading.constant, 20)
    }

    // MARK: - Helpers

    /// How far the cap runs *along the top edge*, measured from the shape's own leading edge
    /// rather than the view's — a row that insets its fill would otherwise report its margin as
    /// part of the corner.
    private func capRun(_ profile: [CGFloat]) throws -> CGFloat {
        let top = try XCTUnwrap(profile.first, "nothing was drawn")
        let middle = try XCTUnwrap(profile.last, "nothing was drawn")
        return top - middle
    }

    /// How far in from the leading edge the drawn shape starts, row of pixels by row of pixels,
    /// from the top of the shape to its vertical middle — the cap's profile.
    private func leadingEdgeProfile(
        size: NSSize = Fixture.row.size,
        _ draw: () -> Void
    ) throws -> [CGFloat] {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()

        // Any ink at all, rather than a solid threshold: a selection drawn at the theme's muted
        // strength is a fifth of an alpha, and the question here is where the shape starts.
        return (0...Int(size.height) / 2).compactMap { row in
            (0..<Int(size.width)).first { column in
                (rep.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.05
            }.map(CGFloat.init)
        }
    }
}
