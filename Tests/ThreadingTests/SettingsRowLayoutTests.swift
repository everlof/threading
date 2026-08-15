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

    /// A long title is allowed to truncate; moving the setting's control outside the card is
    /// not. This is the exact pressure shape the 420pt General-page evidence exposed.
    func testALongTitleKeepsTheControlInsideANarrowRow() throws {
        let control = popUp()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(
            equalToConstant: SettingsUIDefaults.controlWidth
        ).isActive = true
        let width: CGFloat = 420
        let built = SettingsUI.row(
            title: "A deliberately long setting title that cannot keep its natural width",
            subtitle: "The explanation wraps while the setting itself remains reachable.",
            control: control,
            localizes: false
        )
        built.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        container.addSubview(built)
        NSLayoutConstraint.activate([
            built.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            built.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            built.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        container.layoutSubtreeIfNeeded()

        let frame = control.convert(control.bounds, to: built)
        XCTAssertLessThanOrEqual(
            frame.maxX,
            width - Design.Spacing.inset + 0.5,
            "the title pushed the control beyond the narrow card"
        )
        XCTAssertGreaterThan(frame.minX, Design.Spacing.inset)
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

    // MARK: - A Composite Trailing Control

    /// Storage's rows carry two things on the trailing edge — the size and Remove — so the
    /// "control" they hand `row` is a stack. A stack has no intrinsic content size, so the row's
    /// `setContentHuggingPriority(.required)` said nothing to it, and the group was as willing to
    /// take the row's slack as the label column was.
    ///
    /// **In a card held at a fixed width it looked right**, which is why this shipped: the tie
    /// resolved in the labels' favour there and in the group's favour inside the real scrolling
    /// page, where all three groups floated mid-card, each at a different distance because each
    /// row's own size string set where its group began. So the fixture is the page, not the card
    /// — the container the row actually ships in.
    private func storagePage(
        width: CGFloat = Design.Size.readableWidth
    ) -> (page: NSView, card: NSView, sizes: [NSTextField], buttons: [ThemedButton], window: NSWindow) {
        let fixtures = [
            ("FestinaPackages/.build", "Swift build output · swift build · last written 1 wk ago", "5.1 GB"),
            ("Android/chronos/build", "Gradle build output · gradle build · last written 1 wk ago", "3.1 GB"),
            ("Android/watch/build", "Gradle build output · gradle build · last written 1 hr ago", "1.41 GB")
        ]

        var sizes: [NSTextField] = []
        var buttons: [ThemedButton] = []
        var rows: [NSView] = []
        for fixture in fixtures {
            let button = SettingsUI.button(
                "Remove",
                target: self,
                action: #selector(noop),
                localizes: false
            )
            buttons.append(button)

            let size = NSTextField(labelWithString: fixture.2)
            size.applyFont(.numericBody)
            size.alignment = .right
            sizes.append(size)

            rows.append(SettingsUI.row(
                title: fixture.0,
                subtitle: fixture.1,
                control: SettingsUI.controlGroup([size, button]),
                localizes: false
            ))
        }

        let card = SettingsUI.disclosureCard(
            title: "app-mono · release/12.14.x",
            subtitle: "~/fest/app-mono",
            summary: "10.99 GB",
            control: SettingsUI.button(
                "Remove All…",
                target: self,
                action: #selector(noop),
                localizes: false
            ),
            isExpanded: true,
            localizes: false,
            onToggle: { _ in },
            detailRows: rows
        )

        let page = SettingsUI.page(
            title: "Storage",
            summary: "14.53 GB reclaimable in 43 directories",
            actions: [
                SettingsUI.button("Rescan", target: self, action: #selector(noop), localizes: false)
            ],
            sections: [card],
            localizes: false
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: width + Design.Size.glowGutter * 2,
                height: 600
            ),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = page
        page.layoutSubtreeIfNeeded()
        return (page, card, sizes, buttons, window)
    }

    @objc private func noop() {}

    func testACompositeTrailingControlReachesTheRowsTrailingInset() {
        let built = storagePage()

        XCTAssertEqual(built.card.bounds.width, Design.Size.readableWidth, accuracy: 0.5)
        for (index, button) in built.buttons.enumerated() {
            let frame = button.convert(button.bounds, to: built.card)
            XCTAssertEqual(
                frame.maxX,
                built.card.bounds.width - Design.Spacing.inset,
                accuracy: 0.5,
                "row \(index)'s trailing group stopped at \(frame.maxX)pt of a "
                    + "\(built.card.bounds.width)pt card"
            )
        }
        withExtendedLifetime(built.window) {}
    }

    /// And they line up with each other: three Remove buttons at three x positions is the same
    /// fault read a second way, since how wide a row's size string is is not the row's business.
    func testCompositeTrailingControlsAlignAcrossRows() throws {
        let built = storagePage()
        let buttonEdges = built.buttons.map { $0.convert($0.bounds, to: built.card).minX }
        let sizeEdges = built.sizes.map { $0.convert($0.bounds, to: built.card).maxX }

        let firstButton = try XCTUnwrap(buttonEdges.first)
        for edge in buttonEdges {
            XCTAssertEqual(edge, firstButton, accuracy: 0.5,
                           "the Remove buttons do not share a column: \(buttonEdges)")
        }

        let firstSize = try XCTUnwrap(sizeEdges.first)
        for edge in sizeEdges {
            XCTAssertEqual(edge, firstSize, accuracy: 0.5,
                           "the sizes do not share a column: \(sizeEdges)")
        }
        withExtendedLifetime(built.window) {}
    }

    /// The group holds its own width rather than being squeezed by the label column, which is the
    /// same contract the single-control row keeps at 420pt.
    func testACompositeTrailingControlKeepsItsWidthInANarrowPage() throws {
        let built = storagePage(width: 420)

        for (index, button) in built.buttons.enumerated() {
            let frame = button.convert(button.bounds, to: built.card)
            XCTAssertEqual(
                frame.maxX,
                built.card.bounds.width - Design.Spacing.inset,
                accuracy: 0.5,
                "row \(index)'s group left the narrow card's trailing inset"
            )
            XCTAssertGreaterThanOrEqual(
                button.frame.width,
                button.fittingSize.width - 0.5,
                "row \(index)'s Remove was squeezed by the labels beside it"
            )
        }
        withExtendedLifetime(built.window) {}
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

    /// The raw term lists hold every localised spelling of one concept, so a page carries
    /// "sessions", "Sessions" and the translation. Three rows saying one thing is worse than
    /// none: the first spelling wins, capitalised so a row reads as a label.
    func testTermsAreCollapsedToOneRowPerConcept() {
        XCTAssertEqual(
            SettingsSearch.presentable(["sessions", "Sessions", "  ", "shell", "SESSIONS"]),
            ["Sessions", "Shell"]
        )
    }

    /// The catalogue's own answer, so a feature whose vocabulary stops matching is caught here
    /// rather than by a reader who searched for it and found nothing. "mute" has to surface
    /// the actual setting — a result that only said "General" made the reader run their own
    /// search inside the page.
    func testTheCatalogueAnswersMuteWithTheSilenceSetting() throws {
        let general = try XCTUnwrap(
            SettingsPages.sidebarItems.first { $0.id == SettingsPages.generalID }
        )
        let hits = general.entries.filter {
            SettingsSearch.matches(query: "mute", text: $0.searchText)
        }
        XCTAssertTrue(
            hits.contains { $0.title == L10n.string("Silence every sound") },
            "mute should name the silence setting, found \(hits.map(\.title))"
        )
    }

    /// The Startup section's verbs joined the vocabulary the day a search for the relaunch
    /// feature found nothing: the section relaunches and reopens sessions, and neither word
    /// was indexed on General.
    func testTheCatalogueFindsTheStartupRelaunchFeatureByItsVerbs() throws {
        let general = try XCTUnwrap(
            SettingsPages.sidebarItems.first { $0.id == SettingsPages.generalID }
        )
        for query in ["relaunch", "reopen at startup", "resume automatically"] {
            XCTAssertTrue(
                SettingsSearch.matches(query: query, text: general.searchText),
                "\(query) no longer lands on General"
            )
        }
    }

    /// Copy-on-select is a terminal behaviour that lives on a page called Profiles, so the word
    /// someone will actually type for it is "terminal" — and the result has to *name* the
    /// setting, not leave them opening the page to find out which of its rows matched.
    func testTheCatalogueFindsCopyOnSelectByWhatItIsCalled() throws {
        let profiles = try XCTUnwrap(
            SettingsPages.sidebarItems.first { $0.id == SettingsPages.profilesID }
        )
        for query in ["copy on select", "clipboard", "terminal selection"] {
            XCTAssertTrue(
                SettingsSearch.matches(query: query, text: profiles.searchText),
                "\(query) no longer lands on Profiles"
            )
        }

        let hits = profiles.entries.filter {
            SettingsSearch.matches(query: "terminal selection", text: $0.searchText)
        }
        XCTAssertTrue(
            hits.contains { $0.title == L10n.string("Copy selected text to the clipboard") },
            "a search for terminal selection should name the setting, found \(hits.map(\.title))"
        )
    }

    /// Typing turns the list into results: each surviving page keeps its row, and beneath it
    /// the settings the query landed on — title plus its section as the path — because a
    /// result saying only "General" is the reader's own search handed back to them.
    func testSearchingShowsTheSettingsUnderTheirPageWithTheirSections() {
        let sidebar = SettingsSidebar(items: [
            .init(
                id: "general",
                title: "General",
                symbol: "gearshape",
                searchText: "General notifications mute sound silence",
                entries: [
                    .init(
                        title: "Alert sound",
                        section: "Notifications",
                        searchText: "Alert sound Notifications General"
                    ),
                    .init(
                        title: "Silence every sound",
                        section: "Silence",
                        searchText: "Silence every sound mute Silence General"
                    )
                ]
            ),
            .init(
                id: "themes",
                title: "Themes",
                symbol: "paintpalette",
                searchText: "Themes appearance font"
            )
        ])

        sidebar.updateSearchQuery("sound")
        XCTAssertEqual(sidebar.visibleItemIDs, ["general"])
        XCTAssertEqual(rowTitles(in: sidebar), ["General"])
        XCTAssertEqual(
            sidebar.visibleEntryTitles,
            ["Alert sound — Notifications", "Silence every sound — Silence"]
        )

        // A narrower query keeps the page and narrows its settings.
        sidebar.updateSearchQuery("mute")
        XCTAssertEqual(sidebar.visibleEntryTitles, ["Silence every sound — Silence"])

        // Cleared, every destination returns in place, and no result rows remain.
        sidebar.updateSearchQuery("")
        XCTAssertEqual(rowTitles(in: sidebar), ["General", "Themes"])
        XCTAssertEqual(sidebar.visibleEntryTitles, [])
    }

    /// Choosing a setting-level result reports the page *and* the row, so the pane can scroll
    /// to and mark the setting rather than leaving the reader at the top of the page.
    func testChoosingASettingResultReportsThePageAndTheRow() throws {
        let sidebar = SettingsSidebar(items: [
            .init(
                id: "general",
                title: "General",
                symbol: "gearshape",
                searchText: "General mute",
                entries: [
                    .init(
                        title: "Silence every sound",
                        section: "Silence",
                        searchText: "Silence every sound mute"
                    )
                ]
            )
        ])
        var openedPage: String?
        var openedRow: String?
        sidebar.onOpenSetting = { page, row in
            openedPage = page
            openedRow = row
        }

        sidebar.updateSearchQuery("mute")
        let hit = try XCTUnwrap(sidebar.hitRows.first)
        XCTAssertTrue(hit.performPrimaryAction(), "the row must answer keyboard activation")
        XCTAssertEqual(openedPage, "general")
        XCTAssertEqual(openedRow, "Silence every sound")
        XCTAssertEqual(sidebar.selectedID, "general", "the page row should read as chosen")
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

    /// The pane's answer to an Ask AI run: each suggested destination named by its full path,
    /// with the run's own sentence on why, and a way in — the tag indexing this page's rows,
    /// never the catalogue.
    func testTheAIResultsPageListsSuggestionsAndOpensThePageBehindARow() throws {
        let results = SettingsAISearchViewController()
        var openedPage: String?
        var openedRow: String?
        results.onOpen = { page, row in
            openedPage = page
            openedRow = row
        }
        results.loadView()
        results.apply(.answered(query: "flashing", matches: [
            .init(pageID: "general", title: "General", symbol: "gearshape",
                  settingTitle: "Alert sound", settingSection: "Notifications",
                  reason: "Notifications and their sounds live here."),
            .init(pageID: "motion", title: "Motion", symbol: "sparkles",
                  settingTitle: nil, settingSection: nil,
                  reason: "The working indicator's animation.")
        ]))

        let titles = labels(in: results.view)
        XCTAssertTrue(
            titles.contains("General › Notifications › Alert sound"),
            "a suggestion that names a setting shows its whole path, showed \(titles)"
        )
        XCTAssertTrue(titles.contains("Motion"), "a page-level answer stays the page's name")
        XCTAssertTrue(titles.contains("Notifications and their sounds live here."))
        XCTAssertTrue(
            titles.contains { $0.localizedCaseInsensitiveContains("flashing") },
            "the page never repeated the query it is answering"
        )

        let buttons = descendants(of: results.view)
            .compactMap { $0 as? ThemedButton }
            .filter { $0.title == L10n.string("Open") }
        XCTAssertEqual(buttons.count, 2)
        let first = try XCTUnwrap(buttons.first)
        _ = NSApp.sendAction(try XCTUnwrap(first.action), to: first.target, from: first)
        XCTAssertEqual(openedPage, "general")
        XCTAssertEqual(openedRow, "Alert sound", "the named setting travels with the open")

        let second = try XCTUnwrap(buttons.last)
        _ = NSApp.sendAction(try XCTUnwrap(second.action), to: second.target, from: second)
        XCTAssertEqual(openedPage, "motion")
        XCTAssertNil(openedRow, "a page-level answer has no row to scroll to")
    }

    /// An answer already held for the same query is re-shown rather than re-bought: the run
    /// spends the user's usage, and the Ask AI button doubles as the way back into the
    /// suggestions after opening one. A guard that stopped holding would put a paid run
    /// behind every return trip.
    func testAskingTheSameQueryAgainReusesTheAnswerInsteadOfRerunning() {
        let results = SettingsAISearchViewController()
        results.loadView()
        let answered = SettingsAISearchViewController.Phase.answered(
            query: "flashing",
            matches: [.init(
                pageID: "motion", title: "Motion", symbol: "sparkles",
                settingTitle: nil, settingSection: nil, reason: "r"
            )]
        )
        results.apply(answered)

        results.begin(query: "flashing")
        XCTAssertEqual(results.phase, answered, "the held answer was re-bought")
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

    /// The ✕ appears exactly while there is a query, and pressing it clears the way typing
    /// would: through the field's own change path, so the list, the hits and the Ask AI
    /// affordance all stand down together.
    func testTheClearButtonEmptiesTheQueryAndRestoresTheList() throws {
        let sidebar = SettingsSidebar(items: [
            .init(id: "general", title: "General", symbol: "gearshape", searchText: "General mute"),
            .init(id: "themes", title: "Themes", symbol: "paintpalette", searchText: "Themes font")
        ])
        sidebar.isAskAIAvailable = true

        XCTAssertNil(sidebar.clearSearchButton, "nothing typed means nothing to clear")

        sidebar.updateSearchQuery("mute")
        XCTAssertEqual(sidebar.visibleItemIDs, ["general"])
        let clear = try XCTUnwrap(sidebar.clearSearchButton)

        XCTAssertTrue(clear.accessibilityPerformPress(), "the ✕ must answer its press")
        XCTAssertEqual(sidebar.visibleItemIDs, ["general", "themes"], "clearing restores the list")
        XCTAssertNil(sidebar.clearSearchButton, "an empty field has nothing to clear")
        XCTAssertNil(sidebar.askAIButton, "an empty field has nothing to interpret")
    }

    /// Escape clears a filled query and keeps the caret — Spotlight's contract. Empty, the
    /// command travels on to whoever owns dismissal, exactly as before.
    func testEscapeClearsAFilledQueryAndTravelsOnWhenEmpty() {
        let sidebar = SettingsSidebar(items: [
            .init(id: "general", title: "General", symbol: "gearshape", searchText: "General mute")
        ])
        sidebar.updateSearchQuery("mute")

        let field = sidebar.searchFieldForTesting
        let escape = #selector(NSResponder.cancelOperation(_:))
        XCTAssertTrue(
            sidebar.control(field, textView: NSTextView(), doCommandBy: escape),
            "a filled field claims Escape"
        )
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(sidebar.visibleItemIDs, ["general"], "the full list is back")

        XCTAssertFalse(
            sidebar.control(field, textView: NSTextView(), doCommandBy: escape),
            "an empty field lets Escape travel on"
        )
    }

    /// A search is a question about the visit that asked it, so leaving Settings drops it.
    ///
    /// The sidebar is built once and hidden rather than torn down, so the query used to outlive
    /// its visit: reopening Settings landed on a filter nobody had just typed, with the pane on
    /// the General page that re-entry selects and the sidebar not listing it.
    func testLeavingSettingsDropsTheSearchSoTheNextVisitOpensOnTheWholeList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-settings-search-reset-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = StateManager(appSupportDirectory: directory)
        defer { manager.closeDatabase() }

        let controller = ProjectSidebarViewController(
            projectStore: ProjectStore(stateManager: manager)
        )
        _ = controller.view

        controller.setSettingsMode(true)
        let sidebar = try XCTUnwrap(
            descendants(of: controller.view).compactMap { $0 as? SettingsSidebar }.first
        )
        let restingPages = sidebar.visibleItemIDs
        XCTAssertFalse(restingPages.isEmpty, "the resting list is the whole catalogue")

        sidebar.updateSearchQuery("themes")
        XCTAssertNotEqual(sidebar.visibleItemIDs, restingPages, "the query filtered nothing")

        controller.setSettingsMode(false)
        XCTAssertEqual(sidebar.searchFieldForTesting.stringValue, "")
        XCTAssertNil(sidebar.clearSearchButton, "an emptied field still offered its ✕")

        controller.setSettingsMode(true)
        XCTAssertEqual(
            sidebar.visibleItemIDs,
            restingPages,
            "reopening Settings landed on the previous visit's filter"
        )
    }

    // MARK: - The result rows

    /// A setting-level result marks the words the query accounts for, so the reader is not
    /// asked to run their own search inside the answer to their search. The page-level
    /// searchText carries the entry's words too, as `SettingsPages.sidebarItems` builds it —
    /// the page has to survive the filter for its settings to be shown at all.
    func testAResultRowMarksTheWordsTheQueryAccountsFor() {
        let sidebar = SettingsSidebar(items: [
            .init(
                id: "general",
                title: "General",
                symbol: "gearshape",
                searchText: "General mute Silence every sound",
                entries: [
                    .init(
                        title: "Silence every sound",
                        section: "Silence",
                        searchText: "Silence every sound mute"
                    )
                ]
            )
        ])
        sidebar.updateSearchQuery("silence")
        XCTAssertEqual(marks(in: sidebar), ["Silence"])
    }

    /// The results are a retained stack rebuilt per keystroke while pages are externally
    /// sized — 256 installed packages may contribute eight pages each — so the search path
    /// caps construction at `SettingsSidebar.Defaults.maximumResultRows` and says what it
    /// cut. This fixture drives the extension-scale worst case through the real sidebar;
    /// `scripts/profile_threading.sh settings-search-stress` runs it with measurements.
    @MainActor
    func testStressSettingsSearchResultsWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THREADING_SETTINGS_SEARCH_STRESS"] == "1" else {
            throw XCTSkip("Set THREADING_SETTINGS_SEARCH_STRESS=1 to run settings search stress.")
        }
        let resultCount = max(
            Int(environment["THREADING_SETTINGS_SEARCH_STRESS_RESULTS"] ?? "") ?? 2_048,
            1
        )
        let items = (0..<resultCount).map { index in
            SettingsSidebar.Item(
                id: "com.example.stress-\(index).page",
                title: "Stress Extension \(index) — Matching Settings Page",
                symbol: "puzzlepiece.extension",
                searchText: "Stress Extension \(index) Matching Settings Performance",
                group: "Extensions"
            )
        }

        let loadStarted = DispatchTime.now().uptimeNanoseconds
        let sidebar = SettingsSidebar(items: items)
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(sidebar)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 240),
            host.heightAnchor.constraint(equalToConstant: 600),
            sidebar.topAnchor.constraint(equalTo: host.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        let loaded = DispatchTime.now().uptimeNanoseconds

        let searchStarted = DispatchTime.now().uptimeNanoseconds
        sidebar.updateSearchQuery("matching")
        host.layoutSubtreeIfNeeded()
        let searched = DispatchTime.now().uptimeNanoseconds

        let updateStarted = DispatchTime.now().uptimeNanoseconds
        sidebar.updateSearchQuery("settings")
        host.layoutSubtreeIfNeeded()
        let updated = DispatchTime.now().uptimeNanoseconds

        let resultRows = rowTitles(in: sidebar).count
        print(
            "THREADING_PERF settings-search results=\(resultCount) "
                + "load_ms=\(Self.milliseconds(loaded - loadStarted)) "
                + "search_ms=\(Self.milliseconds(searched - searchStarted)) "
                + "update_ms=\(Self.milliseconds(updated - updateStarted)) "
                + "result_rows=\(resultRows) "
                + "descendants=\(descendants(of: sidebar).count + 1)"
        )

        XCTAssertEqual(
            sidebar.visibleItemIDs.count, resultCount,
            "every matching page is still reported as matching"
        )
        XCTAssertLessThanOrEqual(
            resultRows,
            SettingsSidebar.Defaults.maximumResultRows,
            "the capped search built more rows than it promised"
        )
        XCTAssertTrue(
            labels(in: sidebar).contains {
                $0.contains("\(resultCount - SettingsSidebar.Defaults.maximumResultRows)")
            },
            "a capped list has to say how much it cut"
        )
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: sidebar), [])
        withExtendedLifetime(host) {}
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.2f", Double(nanoseconds) / 1_000_000)
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
