import XCTest
@testable import Threading

/// `PaneFooterView`'s contract is geometry — the band's height, the edge-to-edge hairline, and
/// controls whose *ink* lands on the stated margin — so that is what these pin. The margins are
/// asserted against `contentGuide`, the region the content is actually measured from, which is
/// what keeps the assertions true whether or not the platform is insetting for a window corner.
@MainActor
final class PaneFooterTests: XCTestCase {

    /// The ink-to-edge inset the footer states, `Design.Spacing.inset` — restated here so a
    /// drive-by change to the band's margin fails a test rather than passing silently.
    private let contentInset: CGFloat = Design.Spacing.inset

    private func host(_ footer: PaneFooterView, width: CGFloat = 240) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        host.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func plainButton() -> ThemedButton {
        let button = ThemedButton()
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Plus")
        button.isBordered = false
        return button
    }

    // MARK: - Band

    func testBandSuppliesItsOwnHeight() {
        let footer = PaneFooterView()
        _ = host(footer)
        XCTAssertEqual(footer.frame.height, Design.Size.footerHeight)
    }

    func testSeparatorRunsEdgeToEdgeAtTheTop() throws {
        let footer = PaneFooterView(leading: [plainButton()])
        _ = host(footer)

        let separator = footer.subviews.compactMap { $0 as? SeparatorView }.first
        let frame = try XCTUnwrap(separator).frame
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.maxX, footer.bounds.width)
        // Unflipped coordinates: the top anchor is the frame's maxY.
        XCTAssertEqual(frame.maxY, footer.bounds.height)
    }

    func testControlsAreCentredInTheBand() {
        let button = plainButton()
        let footer = PaneFooterView(leading: [button])
        _ = host(footer)
        XCTAssertEqual(button.frame.midY, footer.bounds.midY, accuracy: 0.5)
    }

    // MARK: - Ink alignment

    func testInkLandsOnTheMarginOnBothSides() {
        let leading = plainButton()
        let trailing = plainButton()
        let footer = PaneFooterView(leading: [leading], trailing: [trailing])
        _ = host(footer)

        let region = footer.contentGuide.frame
        // The frame is pulled *out* by the control's own padding, so the visible content —
        // frame edge plus padding — sits exactly on the margin.
        XCTAssertEqual(
            leading.frame.minX + leading.opticalHorizontalInset,
            region.minX + contentInset
        )
        XCTAssertEqual(
            trailing.frame.maxX - trailing.opticalHorizontalInset,
            region.maxX - contentInset
        )
    }

    func testAViewStatingNoPaddingIsTakenAtItsFrame() {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: 20).isActive = true
        view.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let footer = PaneFooterView(leading: [view])
        _ = host(footer)

        XCTAssertEqual(view.frame.minX, footer.contentGuide.frame.minX + contentInset)
    }

    func testSiblingsKeepTheStatedSpacing() {
        let first = plainButton()
        let second = plainButton()
        let footer = PaneFooterView(leading: [first, second])
        _ = host(footer)

        XCTAssertEqual(second.frame.minX - first.frame.maxX, Design.Spacing.small)
    }

    // MARK: - Margin

    /// `.paneEdge` measures from the band itself — see `PaneBandMargin`, and `PaneHeaderTests`
    /// for the measurement that made it necessary.
    func testAPaneEdgeBandMeasuresFromItsOwnEdges() {
        let leading = plainButton()
        let footer = PaneFooterView(leading: [leading], margin: .paneEdge)
        let host = host(footer, width: 600)

        XCTAssertEqual(footer.contentGuide.frame.minX, 0)
        XCTAssertEqual(footer.contentGuide.frame.width, host.bounds.width)
        XCTAssertEqual(
            leading.frame.minX + leading.opticalHorizontalInset,
            contentInset,
            accuracy: 0.5
        )
    }

    // MARK: - Optical insets

    /// The values the design-system controls report: the bordered button's title inset, the
    /// plain button's hover-surface padding, and the icon button's `(target − glyph) / 2` —
    /// each the number its own geometry already states.
    func testControlsReportTheirOwnPadding() {
        let bordered = ThemedButton()
        XCTAssertEqual(bordered.opticalHorizontalInset, Design.Spacing.inset)

        let plain = plainButton()
        XCTAssertEqual(plain.opticalHorizontalInset, Design.Spacing.tight)

        let inline = ThemedIconButton(symbolName: "gearshape", accessibility: "Test", target: .inline)
        XCTAssertEqual(
            inline.opticalHorizontalInset,
            (Design.Size.inlineButtonTarget - Design.Size.inlineButtonGlyph) / 2
        )

        let toolbar = ThemedIconButton(symbolName: "gearshape", accessibility: "Test", target: .toolbar)
        XCTAssertEqual(
            toolbar.opticalHorizontalInset,
            (Design.Size.toolbarButtonWidth - Design.Size.tabIconSlot) / 2
        )
    }
}
