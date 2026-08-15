import XCTest
@testable import Threading

/// `PaneHeaderView`'s contract is the same geometry as its footer mirror — the band's height,
/// the edge-to-edge hairline (at the bottom, where a header folds), and controls whose *ink*
/// lands on the stated margin. Asserted against `contentGuide` for the same reason
/// `PaneFooterTests` does: the region the content is measured from is the assertion's subject.
@MainActor
final class PaneHeaderTests: XCTestCase {

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

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
        XCTAssertEqual(
            header.frame.height,
            Design.Size.tabHeight + Design.Spacing.small * 2 + Design.Radius.border,
            "the rule consumed one of the tab's margins instead of following them"
        )
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

    func testControlsAreCentredAboveTheRule() throws {
        let button = inlineButton()
        let header = PaneHeaderView(trailing: [button])
        _ = host(header)
        let separator = try XCTUnwrap(
            header.subviews.compactMap { $0 as? SeparatorView }.first
        )
        XCTAssertEqual(
            button.frame.midY,
            (separator.frame.maxY + header.bounds.maxY) / 2,
            accuracy: 0.5,
            "the rule was counted as lower breathing room"
        )
    }

    /// Bauhaus is the case that exposed the bug: its four-point structural rule used to take
    /// four of the six points below a tab while leaving all six above it. The band must remeasure
    /// in place when that rule arrives, not only when it is constructed under the theme.
    func testALiveThemeSwitchKeepsTheRuleOutsideTheContentMargins() throws {
        AppThemePalette.set(.system)
        let tab = ThemedTabItemView(
            title: "Attachments",
            symbolName: "paperclip",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )
        let header = PaneHeaderView(leading: [tab], margin: .paneEdge)
        let host = host(header)
        let systemHeight = header.frame.height
        let systemRule = Design.Radius.border

        AppThemePalette.set(AppThemeStyles.bauhaus)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.bauhaus.id))
        host.layoutSubtreeIfNeeded()

        let separator = try XCTUnwrap(
            header.subviews.compactMap { $0 as? SeparatorView }.first
        )
        XCTAssertEqual(
            header.frame.height - systemHeight,
            Design.Radius.border - systemRule,
            accuracy: 0.5
        )
        XCTAssertEqual(
            header.bounds.maxY - tab.frame.maxY,
            Design.Spacing.small,
            accuracy: 0.5
        )
        XCTAssertEqual(
            tab.frame.minY - separator.frame.maxY,
            Design.Spacing.small,
            accuracy: 0.5
        )
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

    // MARK: - Baseline alignment

    /// The footer's text rule, mirrored — see `PaneFooterTests` for the full set; this pins
    /// that the header states the same one.
    func testLooseTextSitsOnTheTitledControlsBaseline() {
        let button = ThemedButton()
        button.title = "Projects"
        button.isBordered = false
        button.font = .systemFont(ofSize: 14)
        let label = NSTextField(labelWithString: "DEV")
        label.font = .systemFont(ofSize: 10)
        let header = PaneHeaderView(leading: [button, label])
        _ = host(header)

        XCTAssertEqual(
            label.frame.maxY - label.firstBaselineOffsetFromTop,
            button.frame.maxY - button.firstBaselineOffsetFromTop,
            accuracy: 0.5
        )
    }

    // MARK: - Margin

    /// The reason `PaneBandMargin` exists, stated as a number.
    ///
    /// The platform's corner-adapted region is not a corner allowance. Measured inside a real
    /// window it holds the whole **window-controls** width clear, across the band's entire
    /// height, whether or not the traffic lights are anywhere near it — so a band that takes it
    /// while sitting *below* them starts some eighty points in. The sidebar's did, and the brand
    /// ended up under the toolbar rather than over the list it names.
    ///
    /// The window is built and never shown, which is all this needs: an unshown window still
    /// lays out, and the inset is a property of being in one.
    func testTheCornerAdaptedRegionHoldsTheWindowControlsClear() {
        let header = PaneHeaderView(leading: [inlineButton()])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor)
        ])
        content.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            header.contentGuide.frame.minX,
            Design.Spacing.pane,
            "if the platform ever stops reserving the window controls here, .paneEdge's reason "
                + "has gone with it and the sidebar can go back to the default"
        )
    }

    /// `.paneEdge` measures from the band itself, so its ink lands on the pane's own margin.
    func testAPaneEdgeBandMeasuresFromItsOwnEdges() {
        let leading = inlineButton()
        let header = PaneHeaderView(leading: [leading], margin: .paneEdge)
        let host = host(header, width: 600)

        XCTAssertEqual(header.contentGuide.frame.minX, 0)
        XCTAssertEqual(header.contentGuide.frame.width, host.bounds.width)
        XCTAssertEqual(
            leading.frame.minX + leading.opticalHorizontalInset,
            contentInset,
            accuracy: 0.5
        )
    }
}
