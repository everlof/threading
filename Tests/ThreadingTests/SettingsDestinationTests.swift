@testable import Threading
import ThreadingExtensionKit
import XCTest

/// Settings in the command palette: every page and every row is a destination, invoking one
/// navigates to it, and none of them leak into the surfaces that are for *commands*.
@MainActor
final class SettingsDestinationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ExtensionSettingsRegistry.shared.replace(enabledManifests: [])
    }

    override func tearDown() {
        ExtensionSettingsRegistry.shared.replace(enabledManifests: [])
        super.tearDown()
    }

    // MARK: - Coverage

    func testEverySettingsPageAndRowIsADestination() {
        let destinations = SettingsPages.destinations

        for page in SettingsPages.all {
            XCTAssertTrue(
                destinations.contains { $0.pageID == page.id && $0.rowTitle == nil },
                "the “\(page.title)” page itself is not reachable from the palette"
            )
            for entry in page.liveEntries {
                XCTAssertTrue(
                    destinations.contains {
                        $0.pageID == page.id && $0.rowTitle == entry.title
                    },
                    "\(page.id): “\(entry.title)” is in the catalogue but not in the palette"
                )
            }
        }
    }

    /// The other direction: nothing is offered that is not a real place. A palette row promising
    /// a destination the reveal cannot find is worse than no row.
    func testNothingIsOfferedThatIsNotAPageARowOrAnInstalledExtension() {
        let destinations = SettingsPages.destinations
        let ids = destinations.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "an id must name one place")
        XCTAssertGreaterThan(
            destinations.filter { $0.rowTitle != nil }.count, 50,
            "the built-in catalogue is smaller than it was"
        )

        let catalogued = Set(
            SettingsPages.all.flatMap { page in
                page.liveEntries.map { "\(page.id)#\($0.title)" }
            }
        )
        let installed = Set(ExtensionManager.shared.installedExtensions.map(\.name))
        for destination in destinations {
            guard let rowTitle = destination.rowTitle else {
                XCTAssertNotNil(
                    SettingsPages.page(id: destination.pageID),
                    "\(destination.id) points at a page that is not offered"
                )
                continue
            }
            XCTAssertTrue(
                catalogued.contains("\(destination.pageID)#\(rowTitle)")
                    || (destination.pageID == SettingsPages.extensionsID
                        && installed.contains(rowTitle)),
                "\(destination.id) is neither a catalogue row nor an installed extension"
            )
        }
    }

    // MARK: - Identity

    func testAPageAndARowOnItAreDifferentDestinations() {
        let page = SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App"
        )
        let row = SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App",
            section: "Notifications",
            rowTitle: "Alert sound"
        )

        XCTAssertEqual(page.id, "settings.page.general")
        XCTAssertEqual(row.id, "settings.row.general#Alert sound")
        XCTAssertTrue(SettingsDestinationCatalog.isDestinationID(page.id))
        XCTAssertTrue(SettingsDestinationCatalog.isDestinationID(row.id))
        XCTAssertFalse(SettingsDestinationCatalog.isDestinationID(AppCommands.ID.newSession))
    }

    func testARepeatedTitleKeepsTheRowTheCatalogueListedFirst() {
        let first = SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App",
            section: "Sessions",
            rowTitle: "Sound"
        )
        let second = SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App",
            section: "Notifications",
            rowTitle: "Sound"
        )

        let catalog = SettingsDestinationCatalog.catalog([first, second])

        XCTAssertEqual(catalog.count, 1, "one anchor cannot be two destinations")
        XCTAssertEqual(catalog.first?.section, "Sessions")
    }

    func testTheCatalogueIsBounded() {
        let many = (0 ..< (SettingsDestinationCatalog.maximumDestinations + 50)).map {
            SettingsDestination(
                pageID: "general",
                pageTitle: "General",
                group: "App",
                rowTitle: "Row \($0)"
            )
        }

        XCTAssertEqual(
            SettingsDestinationCatalog.catalog(many).count,
            SettingsDestinationCatalog.maximumDestinations
        )
    }

    // MARK: - What the palette shows

    func testARowSaysWhereItLivesAndCarriesNoShortcut() {
        let descriptor = SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App",
            section: "Notifications",
            rowTitle: "Alert sound",
            keywords: ["beep"]
        ).hostDescriptor()

        XCTAssertEqual(descriptor.title, "Alert sound")
        XCTAssertEqual(descriptor.detail, "General › Notifications")
        XCTAssertEqual(descriptor.keywords, ["beep"])
        XCTAssertEqual(descriptor.origin, .settings)
        XCTAssertTrue(descriptor.availability.isAvailable)
        XCTAssertNil(descriptor.shortcut)
        XCTAssertFalse(
            descriptor.shortcutEditable,
            "a place to scroll to is not something a chord can mean"
        )
        XCTAssertNil(descriptor.nextInput)
    }

    func testAPageSaysWhichSettingsGroupHoldsIt() {
        let descriptor = SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App"
        ).hostDescriptor()

        XCTAssertEqual(descriptor.title, "General")
        XCTAssertEqual(descriptor.detail, "\(L10n.string("Settings")) › App")
    }

    // MARK: - Where they must not appear

    /// The Keyboard page and the menu bar enumerate `CommandRegistry`. Two hundred rows that can
    /// never carry a key would ruin both, which is why destinations are appended to the palette's
    /// catalog instead of registered as commands.
    func testDestinationsAreNotCommands() {
        let registered = Set(CommandRegistry.shared.all.map(\.id))
        for destination in SettingsPages.destinations {
            XCTAssertFalse(
                registered.contains(destination.id),
                "\(destination.id) reached the command registry"
            )
        }
    }

    // MARK: - Search

    func testTypingASettingsRowTitleFindsIt() {
        let descriptors = SettingsPages.destinations.map { $0.hostDescriptor() }

        let results = HostCommandSearch.results(in: descriptors, matching: "alert sound")

        XCTAssertEqual(results.first?.title, L10n.string("Alert sound"))
    }

    func testAKeywordFindsARowThatNeverSaysTheWord() {
        let bell = SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App",
            section: "Notifications",
            rowTitle: "Terminal bell",
            keywords: ["beep"]
        ).hostDescriptor()

        XCTAssertEqual(
            HostCommandSearch.results(in: [bell], matching: "beep").first?.id,
            bell.id
        )
        XCTAssertTrue(
            HostCommandSearch.results(in: [bell], matching: "kazoo").isEmpty,
            "a keyword search must still be a search"
        )
    }

    /// Both are honest answers to "compact tree". One of them does it.
    func testACommandOutranksASettingsRowThatMatchedAsWell() {
        let command = AppCommand(
            id: AppCommands.ID.compactTree,
            group: .view,
            title: "Compact Tree",
            defaultShortcut: nil,
            isEditable: true
        ).hostDescriptor(shortcut: nil, availability: .available)
        let setting = SettingsDestination(
            pageID: "general",
            pageTitle: "General",
            group: "App",
            section: "Sessions",
            rowTitle: "Compact Tree"
        ).hostDescriptor()

        let results = HostCommandSearch.results(
            in: [setting, command],
            matching: "compact tree"
        )

        XCTAssertEqual(results.map(\.id), [command.id, setting.id])
    }

    // MARK: - Extensions

    func testAnExtensionsOwnPageContributesItsFieldsAsDestinations() throws {
        let manifest = try enabledManifest(
            settings: ExtensionSettingsContribution(pages: [
                ExtensionSettingsPage(
                    id: "panels",
                    title: "Panels",
                    sections: [
                        ExtensionSettingsSection(
                            id: "frames",
                            title: "Frames",
                            fields: [
                                ExtensionSettingField(
                                    id: "width",
                                    title: "Frame width",
                                    description: "How wide a captured frame is.",
                                    control: .integer(
                                        defaultValue: 800,
                                        minimum: 320,
                                        maximum: 4096,
                                        step: 10
                                    )
                                ),
                            ]
                        ),
                    ]
                ),
            ])
        )
        let pageID = ExtensionSettingsRegistry.qualifiedPageID(
            extensionIdentifier: manifest.identifier,
            localPageID: "panels"
        )

        let destinations = SettingsPages.destinations
        let field = try XCTUnwrap(destinations.first { $0.rowTitle == "Frame width" })

        XCTAssertEqual(field.pageID, pageID)
        XCTAssertEqual(field.section, "Frames")
        XCTAssertEqual(field.hostDescriptor().detail, "Marketing — Panels › Frames")
        XCTAssertTrue(
            field.keywords.contains("How wide a captured frame is."),
            "an extension's own description is the vocabulary its row answers to"
        )
        XCTAssertTrue(destinations.contains { $0.pageID == pageID && $0.rowTitle == nil })
    }

    func testAnExtensionsRowsOnAThreadingPageAreDestinationsToo() throws {
        _ = try enabledManifest(
            settings: ExtensionSettingsContribution(sections: [
                ExtensionHostSettingsSection(
                    id: "capture",
                    page: .tools,
                    title: "Capture",
                    fields: [
                        ExtensionSettingField(
                            id: "retina",
                            title: "Capture at 2×",
                            control: .toggle(defaultValue: true)
                        ),
                    ]
                ),
            ])
        )

        let destination = try XCTUnwrap(
            SettingsPages.destinations.first { $0.rowTitle == "Capture at 2×" }
        )

        XCTAssertEqual(destination.pageID, SettingsPages.toolsID)
        XCTAssertEqual(
            destination.section,
            "Marketing — Capture",
            "a row on a shared page has to name the extension that put it there"
        )
    }

    /// The palette result the screenshot in the original report was reaching for: an installed
    /// extension is a row on the Extensions page, so its name is what you type.
    func testAnInstalledExtensionIsADestination() throws {
        let installed = ExtensionManager.shared.installedExtensions
        try XCTSkipIf(installed.isEmpty, "no extension is installed on this machine")

        let destinations = SettingsPages.destinations
        for extensionPackage in installed {
            let destination = destinations.first {
                $0.pageID == SettingsPages.extensionsID
                    && $0.rowTitle == extensionPackage.name
            }
            XCTAssertNotNil(
                destination,
                "“\(extensionPackage.name)” is installed but cannot be typed into the palette"
            )
            XCTAssertEqual(destination?.keywords, [extensionPackage.identifier])
        }
    }

    // MARK: - Fixtures

    @discardableResult
    private func enabledManifest(
        settings: ExtensionSettingsContribution
    ) throws -> ExtensionManifest {
        let manifest = ExtensionManifest(
            identifier: "com.example.settings-destinations",
            name: "Marketing",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/settings",
            capabilities: [.settings],
            settings: settings
        )
        try manifest.validate()
        ExtensionSettingsRegistry.shared.replace(enabledManifests: [manifest])
        return manifest
    }
}
