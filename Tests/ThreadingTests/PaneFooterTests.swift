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

    func testAFrameAlignedActionKeepsItsPlateInsideTheMargin() {
        let button = ThemedButton()
        button.title = "Update chat"
        button.emphasis = .primary
        let footer = PaneFooterView(
            trailing: [button],
            margin: .paneEdge,
            outerEdgeAlignment: .controlFrame
        )
        _ = host(footer)

        XCTAssertEqual(
            button.frame.maxX,
            footer.contentGuide.frame.maxX - contentInset,
            accuracy: 0.5
        )
    }

    func testSiblingsKeepTheStatedSpacing() {
        let first = plainButton()
        let second = plainButton()
        let footer = PaneFooterView(leading: [first, second])
        _ = host(footer)

        XCTAssertEqual(second.frame.minX - first.frame.maxX, Design.Spacing.small)
    }

    /// A footer lives *inside* a pane; it cannot turn a title into an undocumented pane floor.
    /// The host here is held exactly as an `NSSplitViewItem` holds the sidebar: above ordinary
    /// hugging but far below a control's default resistance. Naming the flexible member makes
    /// that member truncate while the pane and the other controls keep their widths.
    func testTheNamedMemberYieldsBeforeThePaneChangesWidth() {
        let root = NSView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 400)
        )

        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        let flexible = ThemedButton()
        flexible.title = "A destination whose title yields"
        flexible.isBordered = false
        let fixed = ThemedButton()
        fixed.title = "Settings"
        fixed.isBordered = false
        let trailing = plainButton()
        let footer = PaneFooterView(
            leading: [flexible, fixed],
            trailing: [trailing],
            compressing: flexible,
            margin: .paneEdge
        )
        column.addSubview(footer)

        let heldWidth: CGFloat = 207
        let held = column.widthAnchor.constraint(equalToConstant: heldWidth)
        held.priority = SidebarDefaults.holdingPriority
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            held,
            footer.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: column.bottomAnchor)
        ])
        root.layoutSubtreeIfNeeded()

        XCTAssertEqual(column.frame.width, heldWidth, accuracy: 0.5)
        XCTAssertLessThan(flexible.frame.width, flexible.intrinsicContentSize.width)
        XCTAssertEqual(fixed.frame.width, fixed.intrinsicContentSize.width, accuracy: 0.5)
        XCTAssertEqual(trailing.frame.width, trailing.intrinsicContentSize.width, accuracy: 0.5)
    }

    // MARK: - Baseline alignment

    /// Where a view's first baseline landed in its superview, from AppKit's own report.
    /// Unflipped coordinates: the frame's top is `maxY`, and the offset is measured down
    /// from it.
    private func baselineY(of view: NSView) -> CGFloat {
        view.frame.maxY - view.firstBaselineOffsetFromTop
    }

    /// A bare label beside a titled button sits on the button's baseline, not on its own
    /// centre — centred, the two fonts' metrics put the smaller text visibly above the line
    /// (the DEV build mark beside Settings). The fonts here are further apart than the
    /// product's so a regression to centring is a point and a half, not a rounding error.
    func testLooseTextSitsOnTheTitledControlsBaseline() {
        let button = ThemedButton()
        button.title = "Settings"
        button.isBordered = false
        button.font = .systemFont(ofSize: 14)
        let label = NSTextField(labelWithString: "DEV")
        label.font = .systemFont(ofSize: 10)
        let footer = PaneFooterView(leading: [button, label])
        _ = host(footer)

        XCTAssertEqual(baselineY(of: label), baselineY(of: button), accuracy: 0.5)
        // The anchor is still the band's: the control keeps the centre, the text joins it.
        XCTAssertEqual(button.frame.midY, footer.bounds.midY, accuracy: 0.5)
    }

    /// The attachments scope band's exact shape — the label leads, the titled control trails —
    /// so the line is the band's, not the leading run's.
    func testTextJoinsTheBaselineAcrossTheTwoRuns() {
        let label = NSTextField(labelWithString: "3 files outside the project")
        label.font = .systemFont(ofSize: 10)
        let button = ThemedButton()
        button.title = "Allow"
        button.isBordered = false
        button.font = .systemFont(ofSize: 14)
        let footer = PaneFooterView(leading: [label], trailing: [button])
        _ = host(footer)

        XCTAssertEqual(baselineY(of: label), baselineY(of: button), accuracy: 0.5)
    }

    /// An icon-only control never leaves the band's centre for a text line it has no text on.
    func testAnIconOnlyControlStaysCentredBesideTheTextLine() {
        let button = ThemedButton()
        button.title = "Settings"
        button.isBordered = false
        let label = NSTextField(labelWithString: "DEV")
        label.font = Design.Typography.detail()
        let gate = ThemedIconButton(symbolName: "speaker.slash", accessibility: "Silence", target: .inline)
        let footer = PaneFooterView(leading: [button, label], trailing: [gate])
        _ = host(footer)

        XCTAssertEqual(gate.frame.midY, footer.bounds.midY, accuracy: 0.5)
    }

    /// A theme may retitle and re-size the band's text live; the line has to follow the new
    /// font rather than stay where the old one was reported. This is the assertion that the
    /// baseline `ThemedButton` states is re-read after `invalidateIntrinsicContentSize`.
    func testTheBaselineFollowsAFontChange() {
        let button = ThemedButton()
        button.title = "Settings"
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        let label = NSTextField(labelWithString: "DEV")
        label.font = .systemFont(ofSize: 10)
        let footer = PaneFooterView(leading: [button, label])
        let container = host(footer)

        button.font = .systemFont(ofSize: 16)
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(baselineY(of: label), baselineY(of: button), accuracy: 0.5)
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
