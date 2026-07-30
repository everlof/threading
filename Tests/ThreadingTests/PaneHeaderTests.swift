import XCTest
@testable import Threading

/// `PaneHeaderView`'s contract is the same geometry as its footer mirror — the band's height,
/// the edge-to-edge hairline (at the bottom, where a header folds), and controls whose *ink*
/// lands on the stated margin. Asserted against `contentGuide` for the same reason
/// `PaneFooterTests` does: the region the content is measured from is the assertion's subject.
@MainActor
final class PaneHeaderTests: XCTestCase {

    /// The ink-to-edge inset the header states, `Design.Spacing.inset` — restated here so a
    /// drive-by change to the band's margin fails a test rather than passing silently.
    private let contentInset: CGFloat = Design.Spacing.inset

    private func host(_ header: PaneHeaderView, width: CGFloat = 240) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        host.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            header.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func inlineButton() -> ThemedIconButton {
        ThemedIconButton(
            symbolName: SidebarDefaults.arrangementSymbol,
            accessibility: "Test",
            target: .inline,
            inkSource: .chrome
        )
    }

    // MARK: - Band

    func testBandSuppliesItsOwnHeight() {
        let header = PaneHeaderView()
        _ = host(header)
        XCTAssertEqual(header.frame.height, PaneHeaderView.bandHeight)
    }

    /// The height the content pane's strip states is this band's, read from one place — the
    /// hairlines of the two panes land on one line only for as long as this holds.
    func testBandMatchesTheContentPanesHeaderStrip() {
        XCTAssertEqual(PaneHeaderView.bandHeight, PaneHeaderDefaults.height)
    }

    func testSeparatorRunsEdgeToEdgeAtTheBottom() throws {
        let header = PaneHeaderView(trailing: [inlineButton()])
        _ = host(header)

        let separator = header.subviews.compactMap { $0 as? SeparatorView }.first
        let frame = try XCTUnwrap(separator).frame
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.maxX, header.bounds.width)
        // Unflipped coordinates: the bottom anchor is the frame's minY.
        XCTAssertEqual(frame.minY, 0)
    }

    func testControlsAreCentredInTheBand() {
        let button = inlineButton()
        let header = PaneHeaderView(trailing: [button])
        _ = host(header)
        XCTAssertEqual(button.frame.midY, header.bounds.midY, accuracy: 0.5)
    }

    // MARK: - Ink alignment

    func testInkLandsOnTheMarginOnBothSides() {
        let leading = inlineButton()
        let trailing = inlineButton()
        let header = PaneHeaderView(leading: [leading], trailing: [trailing])
        _ = host(header)

        let region = header.contentGuide.frame
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

    func testSiblingsKeepTheStatedSpacing() {
        let first = inlineButton()
        let second = inlineButton()
        let header = PaneHeaderView(trailing: [first, second])
        _ = host(header)

        XCTAssertEqual(second.frame.minX - first.frame.maxX, Design.Spacing.small)
    }
}
