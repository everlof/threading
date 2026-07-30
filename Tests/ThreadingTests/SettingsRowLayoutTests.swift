import AppKit
import XCTest
@testable import Threading

/// `SettingsUI.row` is every settings page's row, so a layout fault in it is a fault on all of
/// them at once. What is pinned here is the one that is invisible in a single narrow screenshot
/// and obvious across two: whether a row's subtitle actually uses the width it is given.
@MainActor
final class SettingsRowLayoutTests: XCTestCase {

    private enum Fixture {
        static let title = "App theme"
        static let subtitle = "Follows macOS — light, dark, and your accent colour."
    }

    // MARK: - Helpers

    /// Builds a row, lays it out at a given width, and returns it.
    private func row(width: CGFloat, control: NSView?) -> NSView {
        let row = SettingsUI.row(
            title: Fixture.title,
            subtitle: Fixture.subtitle,
            control: control
        )
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        container.addSubview(row)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        return row
    }

    /// The wrapping subtitle, found by its text rather than by position.
    private func subtitle(
        in view: NSView,
        text: String = Fixture.subtitle
    ) throws -> NSTextField {
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == text {
                return field
            }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return try XCTUnwrap(search(view), "the row has no subtitle")
    }

    private func popUp() -> ThemedPopUp {
        let control = ThemedPopUp()
        control.addItem(withTitle: "System")
        return control
    }

    // MARK: - Tests

    /// The regression this was written for: a wrapping label has no intrinsic width, so against
    /// anything willing to grow it collapses to its narrowest wrap and stays there. Measured on
    /// the Themes page, the App theme description wrapped to the same six lines at 420pt and at
    /// 620pt with most of the row empty beside it — which a single render cannot show, because
    /// nothing in it looks wrong until you have the other one to compare against.
    func testASubtitleUsesTheExtraWidthAWiderRowGivesIt() throws {
        let narrow = try subtitle(in: row(width: 420, control: popUp())).frame.width
        let wide = try subtitle(in: row(width: 620, control: popUp())).frame.width

        XCTAssertGreaterThan(wide, narrow,
                             "the subtitle wrapped identically at both widths, so it is not "
                             + "using the room the wider row gave it")
    }

    /// The subtitle should take what the control does not, rather than a fraction of it — the
    /// row is a label and a control, and everything left over belongs to the label.
    func testASubtitleFillsTheRowBesideItsControl() throws {
        let control = popUp()
        let built = row(width: 620, control: control)
        let width = try subtitle(in: built).frame.width

        let available = 620 - control.fittingSize.width
        XCTAssertGreaterThan(width, available * 0.6,
                             "the subtitle took only \(width)pt of roughly \(available)pt")
    }

    /// Growing the labels must not come at the control's expense: a pop-up squeezed below its
    /// own fitting width truncates the one string saying what the setting is set to.
    func testTheControlKeepsItsFullWidth() throws {
        let control = popUp()
        _ = row(width: 420, control: control)

        XCTAssertGreaterThanOrEqual(control.frame.width, control.fittingSize.width - 0.5,
                                    "the control was squeezed by the labels beside it")
    }

    /// The real Themes-page failure used the opposite fixture from the long App theme line:
    /// a short subtitle beside the standard fixed-width picker. Under the stack's default
    /// gravity distribution those two views clustered at the leading edge, leaving the rest
    /// of a wide row empty and wrapping the copy one word per line.
    func testAFixedWidthControlTrailsAndShortCopyUsesTheRemainingWidth() throws {
        let control = popUp()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true

        let built = SettingsUI.row(
            title: "App font",
            subtitle: "Overrides the typeface the theme states.",
            control: control
        )
        built.translatesAutoresizingMaskIntoConstraints = false

        let width: CGFloat = 620
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        container.addSubview(built)
        NSLayoutConstraint.activate([
            built.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            built.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            built.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        container.layoutSubtreeIfNeeded()

        let controlFrame = control.convert(control.bounds, to: built)
        XCTAssertEqual(
            controlFrame.maxX,
            width - Design.Spacing.inset,
            accuracy: 0.5,
            "the fixed-width picker did not reach the row's trailing inset"
        )

        let shortSubtitle = try subtitle(
            in: built,
            text: "Overrides the typeface the theme states."
        )
        XCTAssertGreaterThan(
            shortSubtitle.frame.width,
            SettingsUIDefaults.controlWidth,
            "the short subtitle collapsed instead of taking the row's remaining width"
        )
    }

    /// A row with no control at all still lays its subtitle out across the row.
    func testARowWithNoControlStillFillsItsWidth() throws {
        let narrow = try subtitle(in: row(width: 420, control: nil)).frame.width
        let wide = try subtitle(in: row(width: 620, control: nil)).frame.width

        XCTAssertGreaterThan(wide, narrow)
    }

    // MARK: - The Explanatory Row

    /// `detailRow` had the same fault as `row`, twice over, because two pages each grew their own
    /// copy before it was a component. A horizontal stack left on `.gravityAreas` never assigns
    /// its leftover width, so whether the detail line filled the card came down to whether that
    /// particular string happened to be long enough to claim it. Short copy collapsed into a
    /// third of the width with the rest of the row empty beside it.
    ///
    /// Short copy is therefore the fixture: the long strings passed by accident.
    private func detailRow(width: CGFloat, detail: String) -> NSView {
        let built = SettingsUI.detailRow(
            symbol: "lock.shield",
            title: "Your own devices",
            detail: detail,
            localizes: false
        )
        built.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        container.addSubview(built)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            built.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            built.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            built.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        return built
    }

    func testAShortDetailStillUsesTheRowsWidth() throws {
        let short = "Owner access."
        let built = detailRow(width: 620, detail: short)
        let field = try subtitle(in: built, text: short)

        XCTAssertGreaterThan(
            field.frame.width,
            620 * 0.6,
            "the detail line collapsed to \(field.frame.width)pt of a 620pt row"
        )
    }

    func testADetailUsesTheExtraWidthAWiderRowGivesIt() throws {
        let detail = "The QR code is owner access. A paired device can see and manage your "
            + "chats, send prompts, and review permission requests."

        let narrow = try subtitle(in: detailRow(width: 420, detail: detail), text: detail)
            .frame.width
        let wide = try subtitle(in: detailRow(width: 620, detail: detail), text: detail)
            .frame.width

        XCTAssertGreaterThan(wide, narrow, "the detail wrapped identically at both widths")
    }

    func testSettingsSearchMatchesAllTokensAcrossTitlesAndExplicitMetadata() {
        let sidebar = SettingsSidebar(items: [
            .init(
                id: "general",
                title: "General",
                symbol: "gearshape",
                searchText: "General sessions startup shell"
            ),
            .init(
                id: "profiles",
                title: "Profiles",
                symbol: "person.crop.circle",
                searchText: "Profiles terminal font cursor scrollback"
            ),
            .init(
                id: "themes",
                title: "Themes",
                symbol: "paintpalette",
                searchText: "Themes appearance text size large typography"
            )
        ])

        sidebar.updateSearchQuery("terminal font")
        XCTAssertEqual(sidebar.visibleItemIDs, ["profiles"])

        sidebar.updateSearchQuery("THEME large")
        XCTAssertEqual(sidebar.visibleItemIDs, ["themes"])

        sidebar.updateSearchQuery("session")
        XCTAssertEqual(sidebar.visibleItemIDs, ["general"])

        sidebar.updateSearchQuery("missing setting")
        XCTAssertEqual(sidebar.visibleItemIDs, [])

        sidebar.updateSearchQuery("")
        XCTAssertEqual(sidebar.visibleItemIDs, ["general", "profiles", "themes"])
    }

    func testSettingsCatalogueMakesTextSizeAndExtensionFieldsDiscoverable() {
        let themes = SettingsPages.sidebarItems.first {
            $0.id == SettingsPages.themesID
        }
        XCTAssertTrue(
            themes?.searchText.localizedCaseInsensitiveContains("text size") == true
        )

        let extensionPage = RegisteredExtensionSettingsPage(
            id: ExtensionSettingsRegistry.qualifiedPageID(
                extensionIdentifier: "com.example.search",
                localPageID: "integration"
            ),
            extensionIdentifier: "com.example.search",
            extensionName: "Search Example",
            page: .init(
                id: "integration",
                title: "Server Integration",
                symbol: "network",
                sections: [
                    .init(
                        id: "connection",
                        title: "Connection",
                        fields: [
                            .init(
                                id: "endpoint",
                                title: "API endpoint",
                                description: "Server used for synchronization",
                                control: .text(
                                    defaultValue: "",
                                    placeholder: "https://example.test",
                                    maximumLength: 1_000
                                )
                            )
                        ]
                    )
                ]
            )
        )
        let terms = ExtensionSettingsRegistry.searchTerms(for: extensionPage)
        XCTAssertTrue(terms.contains("API endpoint"))
        XCTAssertTrue(terms.contains("Server used for synchronization"))
        XCTAssertTrue(terms.contains("https://example.test"))
    }
}
