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

    // MARK: - What a search found

    /// A page qualifies on **all** tokens; a term is worth showing if **any** token touched it.
    /// The two rules are deliberately different — see `SettingsSearch.terms(in:touchedBy:)`.
    func testATermIsShownWhenAnyTokenTouchesItEvenThoughThePageNeedsAll() {
        let terms = ["Notifications", "Mute", "Sound", "Startup"]

        XCTAssertEqual(
            SettingsSearch.terms(in: terms, touchedBy: "mute sound"),
            ["Mute", "Sound"]
        )
        XCTAssertEqual(SettingsSearch.terms(in: terms, touchedBy: "notif"), ["Notifications"])
        XCTAssertEqual(SettingsSearch.terms(in: terms, touchedBy: "nothing"), [])
    }

    /// The raw term lists hold every localised spelling of one concept, so a page carries
    /// "sessions", "Sessions" and the translation. Three rows saying one thing is worse than
    /// none: the first spelling wins, capitalised so a row reads as a label.
    func testTermsAreCollapsedToOneRowPerConcept() {
        XCTAssertEqual(
            SettingsSearch.presentable(["sessions", "Sessions", "  ", "shell", "SESSIONS"]),
            ["Sessions", "Shell"]
        )
    }

    func testAMatchNeverShowsMoreTermsThanItCanSummarise() {
        let many = (0..<20).map { "Term \($0)" }
        XCTAssertEqual(
            SettingsSearch.terms(in: many, touchedBy: "term").count,
            SettingsSearch.maximumTermsShown
        )
    }

    /// The catalogue's own answer, so a page whose terms stop matching is caught here rather
    /// than by a reader who searched for a feature and was shown its section with nothing said.
    func testTheCatalogueReportsWhichTermsAQueryLandedOn() throws {
        let match = try XCTUnwrap(
            SettingsPages.search("mute").first { $0.pageID == SettingsPages.generalID }
        )
        XCTAssertEqual(match.terms, ["Mute"])
        XCTAssertTrue(SettingsPages.search("").isEmpty, "an empty query is not a search")
    }

    /// The Startup section's verbs joined the vocabulary the day a search for the relaunch
    /// feature found nothing: the section relaunches and reopens sessions, and neither word
    /// was indexed on General.
    func testTheCatalogueFindsTheStartupRelaunchFeatureByItsVerbs() {
        for query in ["relaunch", "reopen at startup", "resume automatically"] {
            XCTAssertTrue(
                SettingsPages.search(query).contains { $0.pageID == SettingsPages.generalID },
                "\(query) no longer lands on General"
            )
        }
    }

    /// Copy-on-select is a terminal behaviour that lives on a page called Profiles, so the word
    /// someone will actually type for it is "terminal" — and the result has to *say* selection,
    /// not leave them opening the page to find out which of its settings matched.
    func testTheCatalogueFindsCopyOnSelectByWhatItIsCalled() throws {
        for query in ["copy on select", "clipboard", "terminal selection"] {
            XCTAssertTrue(
                SettingsPages.search(query).contains { $0.pageID == SettingsPages.profilesID },
                "\(query) no longer lands on Profiles"
            )
        }

        let match = try XCTUnwrap(
            SettingsPages.search("terminal").first { $0.pageID == SettingsPages.profilesID }
        )
        XCTAssertTrue(
            match.terms.contains("Terminal selection"),
            "a search for terminal should name the selection setting, showed \(match.terms)"
        )
    }

    /// Typing filters destinations in place. Search terms decide whether a page stays, but do
    /// not become extra rows that can overflow the sidebar or duplicate the destination.
    func testTheListFiltersPagesWithoutAddingSettingHits() {
        let sidebar = SettingsSidebar(items: [
            .init(
                id: "general",
                title: "General",
                symbol: "gearshape",
                searchText: "General notifications mute sound"
            ),
            .init(
                id: "themes",
                title: "Themes",
                symbol: "paintpalette",
                searchText: "Themes appearance font"
            )
        ])

        sidebar.updateSearchQuery("mute")
        XCTAssertEqual(sidebar.visibleItemIDs, ["general"])
        XCTAssertEqual(rowTitles(in: sidebar), ["General"])

        // Cleared, every destination returns in place.
        sidebar.updateSearchQuery("")
        XCTAssertEqual(rowTitles(in: sidebar), ["General", "Themes"])
    }

    // MARK: - Ask AI

    /// The affordance appears exactly when there is a query to interpret and a provider to
    /// ask — with results and without, because the filter matches words and the page the user
    /// *means* is often not among the pages their words matched.
    func testAskAIIsOfferedWheneverThereIsAQueryAndAProvider() {
        let sidebar = SettingsSidebar(items: [
            .init(id: "general", title: "General", symbol: "gearshape", searchText: "General mute")
        ])
        sidebar.isAskAIAvailable = true

        XCTAssertNil(sidebar.askAIButton, "nothing typed means nothing to interpret")

        sidebar.updateSearchQuery("mute")
        XCTAssertNotNil(sidebar.askAIButton, "hidden beside results, where a miss is likeliest")

        sidebar.updateSearchQuery("zzzz")
        XCTAssertEqual(sidebar.visibleItemIDs, [])
        XCTAssertNotNil(sidebar.askAIButton)

        sidebar.updateSearchQuery("")
        XCTAssertNil(sidebar.askAIButton)
    }

    /// Without an eligible login there is nothing to ask, and a button that apologises when
    /// clicked is worse than no button.
    func testAskAIStaysHiddenWithoutAProvider() {
        let sidebar = SettingsSidebar(items: [
            .init(id: "general", title: "General", symbol: "gearshape", searchText: "General")
        ])
        sidebar.isAskAIAvailable = false
        sidebar.updateSearchQuery("anything")
        XCTAssertNil(sidebar.askAIButton)
    }

    /// The click hands over the trimmed query — the same text the filter read, so the AI and
    /// the filter are always answering the same question.
    func testAskAIReportsTheTrimmedQuery() throws {
        let sidebar = SettingsSidebar(items: [
            .init(id: "general", title: "General", symbol: "gearshape", searchText: "General")
        ])
        sidebar.isAskAIAvailable = true
        var asked: String?
        sidebar.onAskAI = { asked = $0 }
        sidebar.updateSearchQuery("  stop the flashing  ")

        let button = try XCTUnwrap(sidebar.askAIButton)
        _ = NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button)
        XCTAssertEqual(asked, "stop the flashing")
    }

    // MARK: - The AI results page

    /// The pane's answer to an Ask AI run: each suggested page with the run's own sentence
    /// on why, and a way in — the tag indexing this page's rows, never the catalogue.
    func testTheAIResultsPageListsSuggestionsAndOpensThePageBehindARow() throws {
        let results = SettingsAISearchViewController()
        var opened: String?
        results.onOpen = { opened = $0 }
        results.loadView()
        results.apply(.answered(query: "flashing", matches: [
            .init(pageID: "general", title: "General", symbol: "gearshape",
                  reason: "Notifications and their sounds live here."),
            .init(pageID: "motion", title: "Motion", symbol: "sparkles",
                  reason: "The working indicator's animation.")
        ]))

        let titles = labels(in: results.view)
        XCTAssertTrue(titles.contains("General"))
        XCTAssertTrue(titles.contains("Notifications and their sounds live here."))
        XCTAssertTrue(
            titles.contains { $0.localizedCaseInsensitiveContains("flashing") },
            "the page never repeated the query it is answering"
        )

        let buttons = descendants(of: results.view)
            .compactMap { $0 as? ThemedButton }
            .filter { $0.title == L10n.string("Open") }
        XCTAssertEqual(buttons.count, 2)
        let second = try XCTUnwrap(buttons.last)
        _ = NSApp.sendAction(try XCTUnwrap(second.action), to: second.target, from: second)
        XCTAssertEqual(opened, "motion")
    }

    /// A run in flight says who is being asked; a run that answered nothing says so in the
    /// same words the term filter uses, because to the reader it is the same outcome.
    func testTheAIResultsPageReportsProgressAndAnEmptyAnswer() {
        let results = SettingsAISearchViewController()
        results.loadView()

        results.apply(.running(query: "q", providerName: "Claude Code"))
        XCTAssertTrue(
            labels(in: results.view).contains { $0.contains("Claude Code") }
        )

        results.apply(.answered(query: "q", matches: []))
        XCTAssertTrue(labels(in: results.view).contains(L10n.string("No settings found.")))

        results.apply(.failed(query: "q", message: "The search timed out."))
        XCTAssertTrue(labels(in: results.view).contains("The search timed out."))
    }

    // MARK: - The results page

    /// The pane's half of the answer. A search that only narrowed the sidebar left the one
    /// surface the reader is looking at showing the page they had open before they typed.
    func testTheResultsPageListsEverySectionTheQueryFound() {
        let results = SettingsSearchResultsViewController(
            query: "mute",
            matches: [
                .init(pageID: "general", title: "General", symbol: "gearshape", terms: ["Mute"]),
                .init(pageID: "motion", title: "Motion", symbol: "sparkles", terms: [])
            ]
        )
        results.loadView()

        let titles = labels(in: results.view)
        XCTAssertTrue(titles.contains("General"))
        XCTAssertTrue(titles.contains("Motion"))
        XCTAssertTrue(titles.contains("Mute"), "the row never said what the query landed on")
        // The caption is set in the design's uppercase, so the query comes back shouted.
        XCTAssertTrue(
            titles.contains { $0.localizedCaseInsensitiveContains("mute") },
            "the page never repeated the query it is answering"
        )
    }

    func testTheResultsPageSaysSoWhenNothingMatched() {
        let results = SettingsSearchResultsViewController(query: "zzzz", matches: [])
        results.loadView()
        XCTAssertTrue(labels(in: results.view).contains(L10n.string("No settings found.")))
    }

    /// The tag indexes the rows this page built, never `SettingsPages.all` — an extension
    /// starting between the build and the click would re-number the catalogue under it.
    func testOpeningAResultReportsThePageBehindIt() throws {
        let results = SettingsSearchResultsViewController(
            query: "font",
            matches: [
                .init(pageID: "profiles", title: "Profiles", symbol: "person", terms: ["Font"]),
                .init(pageID: "themes", title: "Themes", symbol: "paintpalette", terms: ["Font"])
            ]
        )
        var opened: String?
        results.onOpen = { opened = $0 }
        results.loadView()

        let buttons = descendants(of: results.view)
            .compactMap { $0 as? ThemedButton }
            .filter { $0.title == L10n.string("Open") }
        XCTAssertEqual(buttons.count, 2)

        let second = try XCTUnwrap(buttons.last)
        _ = NSApp.sendAction(try XCTUnwrap(second.action), to: second.target, from: second)
        XCTAssertEqual(opened, "themes")
    }

    /// Listing the terms said *that* the query landed here and left the reader to find the word
    /// themselves — which on a row reading "Notifications · Mute · Sound" is the row asking them
    /// to search inside the answer to their search.
    func testAResultMarksTheWordsTheQueryAccountsFor() {
        let results = SettingsSearchResultsViewController(
            query: "mute",
            matches: [
                .init(
                    pageID: "general",
                    title: "General",
                    symbol: "gearshape",
                    terms: ["Notifications", "Mute", "Sound"]
                )
            ]
        )
        results.loadView()

        XCTAssertEqual(marks(in: results.view), ["Mute"])
    }

    /// A page whose *name* is what matched says so on the line the reader is reading, rather than
    /// leaving the only evidence in a sidebar that has already narrowed itself.
    func testAResultMarksAMatchedPageTitleToo() {
        let results = SettingsSearchResultsViewController(
            query: "motion",
            matches: [.init(pageID: "motion", title: "Motion", symbol: "sparkles", terms: [])]
        )
        results.loadView()

        XCTAssertEqual(marks(in: results.view), ["Motion"])
    }

    /// An ordinary settings page is not a search result. Every row on it must be exactly the row
    /// it was before the highlight existed — one plain label, no component that follows a query.
    func testAnOrdinaryRowIsNotBuiltAsASearchResult() {
        let row = SettingsUI.row(
            title: "General",
            subtitle: "Sessions, startup, shell",
            control: nil,
            localizes: false
        )
        XCTAssertTrue(
            descendants(of: row).compactMap { $0 as? SearchMatchLabel }.isEmpty,
            "a page that is merely open paid for a search nobody ran"
        )
    }

    private func marks(in view: NSView) -> [String] {
        descendants(of: view)
            .compactMap { $0 as? SearchMatchLabel }
            .flatMap(\.markedTextForTesting)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func labels(in view: NSView) -> [String] {
        descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    /// Pre-order, so the titles come back in the order they are read down the list.
    private func rowTitles(in view: NSView) -> [String] {
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        return descendants(view).compactMap { ($0 as? ThemedTabItemView)?.accessibilityTitle() }
    }
}
