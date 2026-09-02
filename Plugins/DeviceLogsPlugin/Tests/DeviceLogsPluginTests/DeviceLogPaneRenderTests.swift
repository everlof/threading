import AppKit
import XCTest
import ThreadingDesignKit
@testable import DeviceLogsPlugin

/// The log pane, drawn.
///
/// `design-system.md` asks for a rendered state on any new component, and this one earned it the
/// hard way: its column header was built from a zero frame, reserved no room in the scroll view,
/// and drew *on top of* the first rows. Every assertion anyone would think to write still passed.
/// A picture is where that is noticed; the assertions below are what it turned into.
@MainActor
final class DeviceLogPaneRenderTests: XCTestCase {

    private func fixtureRows() -> [DeviceLogRow] {
        (0..<24).map { index in
            DeviceLogRow(
                time: String(format: "13:06:%02d.969", index % 60),
                level: index % 7 == 0 ? "Error" : "Debug",
                process: "apsd",
                subsystem: "com.apple.uaps",
                message: "START BUFFER lut.addFirst @ 0x10940c02d,4: entry \(index)"
            )
        }
    }

    private func pane() -> DeviceLogPaneViewController {
        let controller = DeviceLogPaneViewController(owningSessionID: UUID().uuidString)
        controller.loadView()
        controller.installRowsForTesting(fixtureRows())
        return controller
    }

    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        // A detached view with only a frame constrains nothing, so the size is stated the way a
        // split item states it.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: height),
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The bug the picture found. The header must sit *above* the rows, not over them.
    func testTheColumnHeaderReservesItsOwnRoomAboveTheRows() throws {
        let controller = pane()
        _ = laidOut(controller.view, width: 900, height: 420)
        let table = try XCTUnwrap(
            descendants(of: controller.view).compactMap { $0 as? NSTableView }.first
        )
        let header = try XCTUnwrap(table.headerView)
        XCTAssertGreaterThan(header.frame.height, 1, "a zero-height header reserves no room")
        XCTAssertGreaterThan(table.numberOfRows, 0, "the fixture should have rows to sit under")
        // Compared against the first *row*, not against the clip view. A scroll view tiles lazily,
        // so an unshown fixture reports a clip that still spans the header's band while drawing
        // perfectly — the render proves it. What actually matters, and what broke, is whether a row
        // lands under the column titles.
        //
        // Converted to the pane rather than to `nil`: a detached fixture has no window, so window
        // coordinates are meaningless.
        let headerFrame = header.convert(header.bounds, to: controller.view)
        let firstRow = table.convert(table.rect(ofRow: 0), to: controller.view)
        XCTAssertFalse(
            headerFrame.intersects(firstRow),
            "the first row drew under the column titles: \(firstRow) vs \(headerFrame)"
        )
        XCTAssertLessThan(
            firstRow.maxY,
            headerFrame.minY + 1,
            "rows must begin below the header, not behind it"
        )
    }

    /// A row of controls that disagree on height by a point or two reads as sloppy long before
    /// anyone can say why.
    func testEveryControlInTheBarIsTheSameHeight() {
        let controller = pane()
        _ = laidOut(controller.view, width: 900, height: 420)
        // The bar's controls only. The resume button floats over the rows rather than sitting in
        // the bar, so it is free to be its own size and must not drag the row's height with it.
        let controls = descendants(of: controller.view).filter {
            ($0 is ThemedPopUp || $0 is ThemedButton || $0 is ThemedTextField)
                && $0.accessibilityIdentifier() != "device-log-resume-follow"
        }
        XCTAssertGreaterThanOrEqual(controls.count, 5, "expected the bar's controls")
        let heights = Set(controls.map { $0.frame.height.rounded() })
        XCTAssertEqual(heights.count, 1, "control heights disagree: \(heights.sorted())")
    }

    /// Counts and rate belong in a footer. In the control bar they competed with the filter field
    /// for width, so the chrome resized as rows arrived.
    func testTheCountsSitBelowTheRowsNotBesideTheFilter() throws {
        let controller = pane()
        _ = laidOut(controller.view, width: 900, height: 420)
        let table = try XCTUnwrap(
            descendants(of: controller.view).compactMap { $0 as? NSTableView }.first
        )
        // By identity, not by text: with no device attached the status reads its empty state,
        // and a test that matched on "/s" was really asserting a phone was plugged in.
        let status = try XCTUnwrap(
            descendants(of: controller.view)
                .first { $0.accessibilityIdentifier() == "device-log-status" }
        )
        let statusY = status.convert(status.bounds, to: controller.view).midY
        let tableY = table.convert(table.bounds, to: controller.view).midY
        XCTAssertLessThan(statusY, tableY, "the status line should be below the rows")
    }

    /// The picture itself, written where `THREADING_RENDER_OUT` points.
    ///
    /// One image, not a light/dark pair: this pane follows the *app theme* through `Design` roles,
    /// not `NSAppearance`, so rendering it twice under aqua and darkAqua produced two identical
    /// pictures and implied a coverage it did not have.
    func testRendersThePaneToImages() throws {
        for name in ["current-theme"] {
            let controller = pane()
            let host = laidOut(controller.view, width: 900, height: 420)
            host.layoutSubtreeIfNeeded()
            host.wantsLayer = true
            // `ThemedTableView` is deliberately clear and its host paints the ground. In the app
            // that is the display panel; here it has to be said, or the rows render as ink on
            // whatever the system supplies and the contrast reads as a bug that is not there.
            host.layer?.backgroundColor = Design.Surface.ground.cgColor
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 2_000, "\(name) render came out blank")
            if let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !directory.isEmpty {
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("device-log-pane-\(name).png"))
            }
        }
    }

    /// The bug that came back. A header assigned before the table has a scroll view is adopted by
    /// the *table*, so it scrolls with the rows: the first lines draw under the column titles and a
    /// ghost header appears mid-list. Its owner is the assertion, because the geometry looks right
    /// until something scrolls.
    func testTheHeaderBelongsToTheScrollViewRatherThanScrollingWithTheRows() throws {
        let controller = pane()
        _ = laidOut(controller.view, width: 900, height: 420)
        let table = try XCTUnwrap(
            descendants(of: controller.view).compactMap { $0 as? NSTableView }.first
        )
        let header = try XCTUnwrap(table.headerView)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertFalse(
            descendants(of: table).contains(header),
            "the header is inside the table, so it will scroll away with the rows"
        )
        XCTAssertTrue(
            descendants(of: scroll).contains(header),
            "the header should be hosted by the scroll view's own header band"
        )
    }

    /// Following is something you leave and rejoin. The button is the only thing that says the view
    /// stopped moving on purpose — without it, a reader who scrolled up cannot tell a held view
    /// from a source that went quiet.
    func testTheResumeButtonAppearsOnlyWhenTheViewHasLeftTheBottom() throws {
        let controller = pane()
        _ = laidOut(controller.view, width: 900, height: 300)
        let resume = try XCTUnwrap(
            descendants(of: controller.view)
                .first { $0.accessibilityIdentifier() == "device-log-resume-follow" }
        )
        XCTAssertTrue(resume.isHidden, "at the bottom there is nothing to resume")

        let scroll = try XCTUnwrap(
            descendants(of: controller.view).compactMap { $0 as? NSScrollView }.first
        )
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        XCTAssertFalse(resume.isHidden, "having scrolled away, the pane should offer to resume")
    }
}
