import XCTest
@testable import Threading

/// The contract between the settings catalogue and the pages it indexes: every
/// `SettingsEntry` must resolve to a row the built page actually tags, or a search result
/// promises a scroll the reveal cannot perform. This is what stops the catalogue and the
/// pages drifting apart — a renamed row fails here, not under a reader's click.
@MainActor
final class SettingsAnchorResolutionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Immediate transitions, so the reveal's scroll has landed by the next line.
        Design.Motion.reduceMotionOverrideForTesting = true
    }

    override func tearDown() {
        Design.Motion.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: - Catalogue ↔ page agreement

    func testEveryCatalogueEntryResolvesToARowOnItsBuiltPage() {
        for page in SettingsPages.builtIn where !page.entries.isEmpty {
            let controller = page.make()
            let host = fixture(holding: controller.view)

            for entry in page.entries {
                XCTAssertNotNil(
                    SettingsRowAnchor.find(title: entry.title, in: controller.view),
                    "\(page.id): no built row carries the anchor “\(entry.title)”"
                )
            }
            withExtendedLifetime(host) {}
        }
    }

    /// An anchor is the row's localized title; an empty title is not a destination and must
    /// not tag anything — an identifier of bare prefix would make every untitled row "first".
    func testAnEmptyTitleTagsNothing() {
        let view = NSView()
        SettingsRowAnchor.tag(view, title: "")
        XCTAssertNil(view.identifier)
    }

    // MARK: - The reveal

    func testRevealScrollsToTheRowAndStandsTheWashOnIt() throws {
        let title = L10n.string("Silence every sound")
        let controller = GeneralPreferencesViewController()
        let host = fixture(holding: controller.view)

        SettingsRowReveal.reveal(title: title, in: controller.view)

        let row = try XCTUnwrap(
            SettingsRowAnchor.find(title: title, in: controller.view),
            "the row the reveal was asked for has to exist"
        )
        let scroll = try XCTUnwrap(enclosingScrollView(of: row))
        XCTAssertGreaterThan(
            scroll.contentView.bounds.origin.y, 0,
            "a row far down the page should have moved the pane"
        )

        let washes = descendants(of: controller.view)
            .compactMap { $0 as? RevealHighlightView }
        XCTAssertEqual(washes.count, 1, "one reveal stands one wash")
        let wash = try XCTUnwrap(washes.first)
        XCTAssertEqual(
            wash.frame,
            row.convert(row.bounds, to: wash.superview),
            "the wash stands exactly on the row it marks"
        )
        XCTAssertNil(
            wash.hitTest(wash.frame.origin),
            "the wash must never stand between the pointer and the row"
        )
        withExtendedLifetime(host) {}
    }

    /// A page that cannot answer for the anchor — here, a title no row carries — degrades to
    /// the page simply being open: no wash, no scroll, no error.
    func testRevealOfAnUnknownAnchorLeavesThePageAlone() {
        let controller = AdvancedPreferencesViewController()
        let host = fixture(holding: controller.view)

        SettingsRowReveal.reveal(title: "No such row", in: controller.view)

        XCTAssertTrue(
            descendants(of: controller.view).compactMap { $0 as? RevealHighlightView }.isEmpty
        )
        withExtendedLifetime(host) {}
    }

    // MARK: - The result rows in their sidebar

    func testASidebarShowingResultsPassesTheThemeBoundaryAudit() {
        let sidebar = SettingsSidebar(items: [
            .init(
                id: "general",
                title: "General",
                symbol: "gearshape",
                searchText: "General sound",
                entries: [
                    .init(
                        title: "Alert sound",
                        section: "Notifications",
                        searchText: "Alert sound Notifications"
                    )
                ]
            )
        ])
        sidebar.updateSearchQuery("sound")
        let host = fixture(holding: sidebar, width: 240, height: 500)

        XCTAssertEqual(sidebar.hitRows.count, 1)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: sidebar), [])
        withExtendedLifetime(host) {}
    }

    // MARK: - Fixture

    /// A fixture standing in for a pane states its size the way a split view does; a detached
    /// frame constrains nothing.
    private func fixture(
        holding view: NSView,
        width: CGFloat = 640,
        height: CGFloat = 480
    ) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: height),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var candidate = view.superview
        while let current = candidate {
            if let scroll = current as? NSScrollView { return scroll }
            candidate = current.superview
        }
        return nil
    }
}
