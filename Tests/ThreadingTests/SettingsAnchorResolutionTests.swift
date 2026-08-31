import ThreadingExtensionKit
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
                    SettingsRowAnchor.locate(title: entry.title, in: controller.view),
                    "\(page.id): no built row carries the anchor “\(entry.title)”"
                )
            }
            withExtendedLifetime(host) {}
        }
    }

    /// The half of that contract a run of segments introduced: some rows are not on the page
    /// until the page is asked for them.
    ///
    /// Remote Access shows one way in's rows and builds none of the others', so two catalogue
    /// entries are behind a selection. `locate` has to move that selection, and `find` — which is
    /// the honest question about the tree as it stands — has to keep saying no.
    func testARowBehindASegmentIsNotFoundUntilThePageIsAskedForIt() throws {
        let controller = RemoteAccessPreferencesViewController()
        let host = fixture(holding: controller.view)
        let title = L10n.string("Open in a browser on your tailnet")

        XCTAssertEqual(controller.shownWayIn, .thisNetwork, "the page did not open where it used to")
        XCTAssertNil(
            SettingsRowAnchor.find(title: title, in: controller.view),
            "the row was built for a way in nobody selected"
        )

        XCTAssertNotNil(
            SettingsRowAnchor.locate(title: title, in: controller.view),
            "asking the page for the row did not bring it on screen"
        )
        XCTAssertEqual(
            controller.shownWayIn, .tailscale,
            "the row appeared without its own way in being selected"
        )

        // A title nothing owns leaves the page exactly where it was, rather than on whichever
        // segment the search happened to stop at.
        XCTAssertNil(SettingsRowAnchor.locate(title: "Nothing on this page", in: controller.view))
        XCTAssertEqual(controller.shownWayIn, .tailscale, "a failed lookup moved the selection")
        withExtendedLifetime(host) {}
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

    // MARK: - Rows a virtual list has not built

    /// The half of the contract a virtualized page introduces: a field twenty rows down does
    /// not exist yet, so `find` has to keep saying no and `locate` has to make it exist.
    ///
    /// Extension pages are one table over arbitrarily many fields — before this, a palette
    /// result for an extension's own setting opened the page and stopped there.
    func testAFieldBelowTheFoldOnAnExtensionPageIsBroughtOnScreen() throws {
        let manifest = try settingsManifest(
            settings: ExtensionSettingsContribution(pages: [
                ExtensionSettingsPage(
                    id: "panels",
                    title: "Panels",
                    sections: [
                        ExtensionSettingsSection(
                            id: "frames",
                            title: "Frames",
                            fields: (0..<40).map {
                                ExtensionSettingField(
                                    id: "field-\($0)",
                                    title: "Field \($0)",
                                    control: .toggle(defaultValue: false)
                                )
                            }
                        )
                    ]
                )
            ])
        )
        ExtensionSettingsRegistry.shared.replace(enabledManifests: [manifest])
        defer { ExtensionSettingsRegistry.shared.replace(enabledManifests: []) }

        let registered = try XCTUnwrap(ExtensionSettingsRegistry.shared.pages.first)
        let controller = ExtensionSettingsViewController(page: registered)
        let host = fixture(holding: controller.view)

        XCTAssertNil(
            SettingsRowAnchor.find(title: "Field 39", in: controller.view),
            "a row that far down should not have been built yet"
        )
        XCTAssertNotNil(
            SettingsRowAnchor.locate(title: "Field 39", in: controller.view),
            "asking the page for the row did not bring it into the table"
        )
        XCTAssertNil(
            SettingsRowAnchor.locate(title: "Field 400", in: controller.view),
            "a title nothing owns must still resolve to nothing"
        )
        withExtendedLifetime(host) {}
    }

    /// The same question of the Extensions page, whose rows are packages rather than settings.
    func testAnExtensionsOwnRowOnTheExtensionsPageIsBroughtOnScreen() throws {
        let manifest = try settingsManifest(
            settings: ExtensionSettingsContribution(sections: [
                ExtensionHostSettingsSection(
                    id: "capture",
                    page: .extensions,
                    title: "Capture",
                    fields: (0..<40).map {
                        ExtensionSettingField(
                            id: "field-\($0)",
                            title: "Capture field \($0)",
                            control: .toggle(defaultValue: false)
                        )
                    }
                )
            ])
        )
        ExtensionSettingsRegistry.shared.replace(enabledManifests: [manifest])
        defer { ExtensionSettingsRegistry.shared.replace(enabledManifests: []) }

        let controller = ExtensionsPreferencesViewController()
        let host = fixture(holding: controller.view)

        XCTAssertNotNil(
            SettingsRowAnchor.locate(title: "Capture field 39", in: controller.view),
            "the Extensions page did not bring its own last row into the table"
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

    private func settingsManifest(
        settings: ExtensionSettingsContribution
    ) throws -> ExtensionManifest {
        let manifest = ExtensionManifest(
            identifier: "com.example.anchor-reveal",
            name: "Anchor Reveal",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/settings",
            capabilities: [.settings],
            settings: settings
        )
        try manifest.validate()
        return manifest
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
