import AppKit
import XCTest
@testable import Threading

/// Close takes its cluster's outer edge, whatever order the theme listed the operations in.
///
/// The default list is Windows order, written for the default trailing placement. A theme that
/// moved its buttons to the leading edge and kept that list put Close third from the corner —
/// where a Mac hand reaches for Zoom — and nothing in its preview showed it.
@MainActor
final class WindowButtonClusterTests: XCTestCase {

    private typealias Role = WindowChromeStyle.TitleBar.ButtonRole
    private typealias Placement = WindowChromeStyle.TitleBar.ButtonPlacement

    // MARK: - The Rule

    func testALeadingClusterInWindowsOrderPutsCloseAtTheCorner() {
        let clusters = Placement.leading.clusters(of: Role.standardOperations)
        XCTAssertEqual(clusters.leading, [.close, .minimize, .zoom])
        XCTAssertEqual(clusters.trailing, [])
    }

    func testATrailingClusterInMacOrderPutsCloseAtTheCorner() {
        let clusters = Placement.trailing.clusters(of: [.close, .minimize, .zoom])
        XCTAssertEqual(clusters.leading, [])
        XCTAssertEqual(clusters.trailing, [.minimize, .zoom, .close])
    }

    func testTheOtherOperationsKeepTheirAuthoredOrder() {
        XCTAssertEqual(
            Placement.leading.clusters(of: [.zoom, .depth, .close, .windowMenu]).leading,
            [.close, .zoom, .depth, .windowMenu]
        )
        let bookends = Placement.bookends.clusters(of: [.minimize, .close, .zoom])
        XCTAssertEqual(bookends.leading, [.minimize])
        XCTAssertEqual(bookends.trailing, [.zoom, .close])
        let split = Placement.split.clusters(of: [.zoom, .close, .depth])
        XCTAssertEqual(split.leading, [.close])
        XCTAssertEqual(split.trailing, [.zoom, .depth])
    }

    /// Every stock frame already puts Close at its corner, so the rule changes none of them —
    /// it only catches a theme that did not.
    func testEveryStockFrameDrawsAsItIsWritten() throws {
        var checked = 0
        for theme in AppThemeStyles.all {
            for kind in theme.availableVariants {
                guard let titleBar = theme.variant(kind)?.chrome?.titleBar else { continue }
                let visible = titleBar.visibleButtons
                let written: (leading: [Role], trailing: [Role])
                switch titleBar.buttonPlacement {
                case .trailing: written = ([], visible)
                case .leading: written = (visible, [])
                case .split: written = (visible.filter { $0 == .close }, visible.filter { $0 != .close })
                case .bookends: written = (Array(visible.prefix(1)), Array(visible.dropFirst()))
                }
                let drawn = titleBar.buttonPlacement.clusters(of: visible)
                XCTAssertEqual(drawn.leading, written.leading, "\(theme.name) \(kind)")
                XCTAssertEqual(drawn.trailing, written.trailing, "\(theme.name) \(kind)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "no stock frame was checked")
    }

    // MARK: - In the Band

    /// The band draws the rule, not just the model: the leftmost button of a leading cluster in
    /// Windows order is Close.
    func testTheBandDrawsCloseFirstInALeadingCluster() throws {
        let band = WindowTitleBandView(appIconProvider: { nil })
        band.fixtureIsKey = true
        band.fixtureStyle = WindowChromeAppearance.resolved(from: WindowChromeStyle(
            titleBar: .init(
                activeGradient: .init(stops: [
                    .init(color: NSColor(srgbRed: 0.6, green: 0.4, blue: 0.2, alpha: 1), position: 0),
                    .init(color: NSColor(srgbRed: 0.45, green: 0.27, blue: 0.12, alpha: 1), position: 1)
                ], angleDegrees: 180),
                ink: .white,
                height: 36,
                buttonGlyphStyle: .pills,
                buttonPlacement: .leading
            )
        ))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 36))
        host.addSubview(band)
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            band.topAnchor.constraint(equalTo: host.topAnchor),
            band.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        let roles = buttons(in: band)
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
            .map(\.role)
        XCTAssertEqual(roles, [.close, .minimize, .zoom])
    }

    // MARK: - Private Methods

    private func buttons(in view: NSView) -> [WindowChromeButton] {
        view.subviews.flatMap { subview -> [WindowChromeButton] in
            (subview as? WindowChromeButton).map { [$0] } ?? buttons(in: subview)
        }
    }
}
