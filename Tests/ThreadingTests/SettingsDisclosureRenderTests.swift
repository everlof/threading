import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// Draws the reworked settings surfaces — the pinned page header and the collapsed cards — to
/// images, under System light and dark plus three deliberately different authored themes.
///
/// The claims these pages now make are visual: a collapsed group reads as one scannable row, an
/// unfolded one still lines its tools up, and the header band sits above the scroll rather than
/// inside it. Each is checked by looking at a render; the assertions pin only what an image
/// cannot — that folding actually removes rows, and that the title no longer lives in the
/// scrolling document.
final class SettingsDisclosureRenderTests: XCTestCase {

    private enum Render {
        static let width = SettingsUIDefaults.pageWidth
        static let height: CGFloat = 1100

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        /// System in both appearances, plus the styles that stress glow, hard-shadow and
        /// square print constructions respectively.
        @MainActor
        static var fixtures: [(name: String, theme: AppTheme, appearance: NSAppearance.Name)] {
            [
                ("system-light", .system, .aqua),
                ("system-dark", .system, .darkAqua),
                ("threading", AppThemeStyles.threading, .darkAqua),
                ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
                ("neo-brutalism", AppThemeStyles.neoBrutalism, .aqua),
                ("swiss", AppThemeStyles.swissMinimalist, .aqua)
            ]
        }
    }

    // MARK: - Folding

    @MainActor
    func testFoldingAGroupRemovesItsToolRows() throws {
        let controller = ToolsPreferencesViewController(
            groups: Array(MCPToolCatalog.allGroups.prefix(3))
        )
        let host = laidOut(controller.view)

        let collapsedRows = controller.virtualRowCount
        let originalScroll = try XCTUnwrap(firstScrollView(in: controller.view))
        let disclosure = try XCTUnwrap(
            descendants(of: controller.view, type: ThemedDisclosureRow.self).first,
            "the Tools page built no disclosure headers"
        )

        XCTAssertTrue(disclosure.performPrimaryAction())
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            controller.virtualRowCount, collapsedRows,
            "unfolding the first group did not add its tool rows"
        )
        XCTAssertTrue(
            firstScrollView(in: controller.view) === originalScroll,
            "a disclosure replaced the page instead of mutating its virtual rows"
        )
    }

    @MainActor
    func testExpandedToolsMaterializeOnlyTheViewport() throws {
        let groups = MCPToolCatalog.allGroups
        let controller = ToolsPreferencesViewController(groups: groups)
        let host = laidOut(controller.view, height: 360)

        for group in groups {
            controller.setGroup(group.id, expanded: true)
        }
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(controller.virtualRowCount, 60)
        XCTAssertLessThan(
            controller.materializedRowCount,
            controller.virtualRowCount / 2,
            "the expanded Tools page retained rows far outside its viewport"
        )
        withExtendedLifetime(host) {}
    }

    @MainActor
    func testArchivedFoldMutatesTheVirtualRowsWithoutReplacingThePage() throws {
        let entries = archivedEntries(count: 80)
        let controller = ArchivedPreferencesViewController(rowsProvider: { entries })
        let page = controller.view
        controller.viewWillAppear()
        let window = performanceWindow(page)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(firstScrollView(in: page))
        let collapsedRows = controller.virtualRowCountForTesting
        let disclosure = try XCTUnwrap(
            descendants(of: page, type: ThemedDisclosureRow.self).first
        )

        XCTAssertTrue(disclosure.performPrimaryAction())
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(firstScrollView(in: page) === scroll)
        XCTAssertEqual(controller.virtualRowCountForTesting, collapsedRows + 70)
        XCTAssertLessThan(
            controller.materializedRowCountForTesting,
            controller.virtualRowCountForTesting / 2
        )
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: page), [])
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testBrowserSignInExemptionsRemainActionableWhenVirtualized() throws {
        let previousProvider = BrowserCredentialPreference.provider
        BrowserCredentialPreference.provider = .systemAutoFill
        let exemptions = BrowserSubmissionExemptions.shared
        exemptions.revokeAll()
        defer {
            exemptions.revokeAll()
            BrowserCredentialPreference.provider = previousProvider
        }
        for index in 0..<80 {
            let url = try XCTUnwrap(URL(string: "https://virtual-\(index).example.test"))
            exemptions.exempt(try XCTUnwrap(BrowserOrigin(url: url)))
        }
        let suite = "BrowserSignInVirtualization-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = ToolsPreferencesViewController(
            groups: [],
            browserAccessStore: BrowserAccessStore(defaults: defaults)
        )
        let page = controller.view
        let window = performanceWindow(page)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let askAgain = try XCTUnwrap(
            descendants(of: page, type: ThemedButton.self).first { $0.title == "Ask Again" }
        )

        XCTAssertEqual(controller.virtualRowCount, 86)
        XCTAssertLessThan(controller.materializedRowCount, controller.virtualRowCount)
        XCTAssertTrue(askAgain.performPrimaryAction())
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(exemptions.exemptOriginKeys.count, 79)
        XCTAssertEqual(controller.virtualRowCount, 85)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: page), [])
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testBrowserSignInVaultEmptyStateRemainsASeparateVirtualRow() throws {
        let previousProvider = BrowserCredentialPreference.provider
        BrowserCredentialPreference.provider = .threadingVault
        defer { BrowserCredentialPreference.provider = previousProvider }
        let suite = "BrowserSignInVaultEmpty-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ToolsPreferencesViewController(
            groups: [],
            browserAccessStore: BrowserAccessStore(defaults: defaults),
            credentialStore: BrowserCredentialStore(
                service: "codes.threading.browser.credential.empty-\(UUID().uuidString)",
                dataProtection: false
            )
        )
        let page = controller.view
        let window = performanceWindow(page)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(labels(in: page).contains { $0.stringValue == "No test credentials stored" })
        XCTAssertEqual(controller.virtualRowCount, 7)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: page), [])
        withExtendedLifetime(window) {}
    }

    @MainActor
    func testArchivedVirtualPagePreservesContributedSettingsFields() throws {
        let field = ExtensionSettingField(
            id: "archive-label",
            title: "Archive label",
            control: .text(
                defaultValue: "Filed",
                placeholder: "Filed",
                maximumLength: 40
            )
        )
        let manifest = ExtensionManifest(
            identifier: "com.example.archived-settings",
            name: "Archive Settings",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/archive-settings",
            capabilities: [.settings],
            settings: .init(sections: [
                .init(
                    id: "archive-host",
                    page: .archived,
                    title: "Archive additions",
                    fields: [field]
                )
            ])
        )
        _ = ExtensionManager.shared
        ExtensionSettingsRegistry.shared.replace(enabledManifests: [manifest])
        defer { ExtensionSettingsRegistry.shared.replace(enabledManifests: []) }

        let controller = ArchivedPreferencesViewController(rowsProvider: { [] })
        let page = controller.view
        controller.viewWillAppear()
        let window = performanceWindow(page)
        window.contentView?.layoutSubtreeIfNeeded()
        let identifiers = Set(descendants(of: page, type: NSView.self).compactMap {
            $0.accessibilityIdentifier()
        })

        XCTAssertTrue(identifiers.contains(
            "settings.extension.com.example.archived-settings.archive-label"
        ))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: page), [])
        withExtendedLifetime(window) {}
    }

    // MARK: - The Header Stays Put

    @MainActor
    func testThePageTitleLivesOutsideTheScroll() throws {
        let controller = ToolsPreferencesViewController(
            groups: Array(MCPToolCatalog.allGroups.prefix(2))
        )
        _ = laidOut(controller.view)

        let scroll = try XCTUnwrap(firstScrollView(in: controller.view))
        let title = descendants(of: controller.view, type: NSTextField.self).first {
            $0.stringValue == L10n.string("Tools")
        }

        let heading = try XCTUnwrap(title, "the page draws no title at all")
        XCTAssertFalse(
            heading.isDescendant(of: scroll),
            "the title is back inside the scrolling document"
        )
    }

    // MARK: - Images

    @MainActor
    func testRendersTheToolsPageCollapsedAndUnfoldedAcrossThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        var written = 0
        for fixture in Render.fixtures {
            AppThemePalette.set(fixture.theme)

            let controller = ToolsPreferencesViewController(
                groups: Array(MCPToolCatalog.allGroups.prefix(4))
            )
            let host = laidOut(controller.view)
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            host.appearance = appearance
            controller.view.appearance = appearance

            for state in ["collapsed", "unfolded"] {
                if state == "unfolded" {
                    let disclosure = try XCTUnwrap(
                        descendants(of: controller.view, type: ThemedDisclosureRow.self).first
                    )
                    XCTAssertTrue(disclosure.performPrimaryAction())
                }
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()

                // The page must hold its readable measure in every theme: the first cyberpunk
                // render caught a tool row whose incompressible detail label pushed the whole
                // page 126pt past its pane — monospace is simply the widest spelling of it.
                assertNothingWiderThanThePage(in: host, fixture: fixture.name, state: state)

                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    data = self.png(of: host)
                }
                let url = directory.appendingPathComponent(
                    "tools-\(fixture.name)-\(state).png"
                )
                try XCTUnwrap(data, "no render for \(fixture.name) \(state)").write(to: url)
                written += 1
            }
        }

        print("Rendered \(written) tools pages to \(directory.path)")
        XCTAssertEqual(written, Render.fixtures.count * 2)
    }

    /// The bare kit pieces — a pinned header over one collapsed and one unfolded card — drawn
    /// without any page's data behind them, so a kit regression shows without a fixture story.
    @MainActor
    func testRendersTheDisclosureKitAcrossThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        var written = 0
        for fixture in Render.fixtures {
            AppThemePalette.set(fixture.theme)

            let collapsed = SettingsUI.disclosureCard(
                title: "Browser",
                subtitle: "Drive the shared browser beside the terminal.",
                summary: "35 tools",
                control: SettingsUI.toggle(isOn: true, target: self, action: #selector(noop)),
                isExpanded: false,
                localizes: false,
                onToggle: { _ in }
            )
            let unfolded = SettingsUI.disclosureCard(
                title: "Display",
                subtitle: "Show images, HTML and comparisons in the panel.",
                summary: "6 tools",
                control: SettingsUI.toggle(isOn: false, target: self, action: #selector(noop)),
                isExpanded: true,
                localizes: false,
                onToggle: { _ in },
                detailRows: [
                    SettingsUI.row(
                        title: "display_image",
                        subtitle: "Show an image in the session's panel.",
                        localizes: false
                    ),
                    SettingsUI.row(
                        title: "display_html",
                        subtitle: "Render a page in a real browser engine.",
                        localizes: false
                    )
                ]
            )

            // Unfolded, and with the two-part trailing control its rows actually carry: a size
            // beside a Remove is one group, and a group is a stack view the row cannot hand its
            // ordinary hugging contract to. Collapsed, this fixture drew none of that and the
            // page shipped with all three groups floating in the middle of the card.
            let storageShaped = SettingsUI.disclosureCard(
                title: "sonda · feature/deploy-pipeline",
                subtitle: "~/repo/sonda/.worktrees/feature-deploy-pipeline",
                summary: "12.4 GB",
                control: SettingsUI.button("Remove All…", target: self, action: #selector(noop)),
                isExpanded: true,
                localizes: false,
                onToggle: { _ in },
                detailRows: [
                    storageRow(path: "web/node_modules", size: "5.1 GB", age: "1 wk ago"),
                    storageRow(path: "target", size: "3.14 GB", age: "2 hr ago"),
                    SettingsUI.disclosureRow(
                        title: "27 smaller directories",
                        subtitle: "Under 1 GB, click to show each",
                        summary: "1.37 GB",
                        isExpanded: false,
                        localizes: false,
                        onToggle: { _ in }
                    )
                ]
            )
            let extensionShaped = SettingsUI.disclosureCard(
                title: "Weather Panel",
                subtitle: "Version 2.1 · com.example.weather",
                summary: "Running",
                summaryColor: Design.Status.positive,
                control: SettingsUI.toggle(isOn: true, target: self, action: #selector(noop)),
                isExpanded: false,
                localizes: false,
                onToggle: { _ in }
            )

            let page = SettingsUI.page(
                title: "Fixture",
                summary: "A summary line under the fixed title",
                actions: [SettingsUI.button("Action", target: self, action: #selector(noop))],
                sections: [collapsed, unfolded, storageShaped, extensionShaped],
                localizes: false
            )

            let host = laidOut(page, height: 760)
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            host.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                data = self.png(of: host)
            }
            let url = directory.appendingPathComponent("disclosure-kit-\(fixture.name).png")
            try XCTUnwrap(data, "no render for \(fixture.name)").write(to: url)
            written += 1
        }

        print("Rendered \(written) kit fixtures to \(directory.path)")
        XCTAssertEqual(written, Render.fixtures.count)
    }

    // MARK: - The Scratch Tiers On Storage

    /// A build cache found outside every project belongs to whichever workspace its manifest
    /// names, and the three possible answers are three different headings on the page.
    ///
    /// Asserted against the page's own splitter with stated projects and a stated answer for
    /// "does this workspace still exist", because that is exactly what the page does: the
    /// attribution is computed when the page is read, from values, with no scan and no git.
    /// The claim that matters is the last one — a workspace that is alive and simply is not
    /// ours must not be filed under a heading saying it was deleted.
    @MainActor
    func testScratchFindingsSplitByTheWorkspaceTheyWereBuiltFor() throws {
        let project = Project(
            name: "Threading",
            folderURL: URL(fileURLWithPath: "/private/tmp/threading-fixture-project")
        )
        let live = scratchArtifact(
            "/private/tmp/dd-live",
            workspace: "/private/tmp/threading-fixture-project/Threading.xcodeproj",
            bytes: 4_000_000_000
        )
        let orphan = scratchArtifact(
            "/private/tmp/dd-orphan",
            workspace: "/private/tmp/threading-verify-9f2/Threading.xcodeproj",
            bytes: 3_000_000_000
        )
        let stranger = scratchArtifact(
            "/private/tmp/dd-stranger",
            workspace: "/private/tmp/someone-elses-copy/Other.xcodeproj",
            bytes: 2_000_000_000
        )

        let onDisk = Set([live, stranger].compactMap(\.workspacePath))
        let groups = StoragePreferencesViewController.scratchGroups(
            [orphan, stranger, live],
            among: [project],
            workspaceExists: { onDisk.contains($0) }
        )

        XCTAssertEqual(
            groups.map { tier(of: $0.attribution) },
            ["project", "orphan", "other"],
            "the tiers are not the three the page draws, in the order it draws them"
        )

        XCTAssertEqual(groups[0].artifacts.map(\.id), [live.id])
        XCTAssertEqual(groups[0].attribution.project?.id, project.id)
        XCTAssertTrue(
            groups[0].title.contains(project.name),
            "a project's own build cache is headed \(groups[0].title)"
        )
        XCTAssertFalse(
            groups[0].attribution.trailsThePage,
            "a project's cache should sort among its checkouts by size"
        )

        XCTAssertEqual(groups[1].artifacts.map(\.id), [orphan.id])
        XCTAssertTrue(groups[1].attribution.namesADeletedWorkspace)
        XCTAssertTrue(groups[1].attribution.trailsThePage)

        XCTAssertEqual(
            groups[2].artifacts.map(\.id), [stranger.id],
            "a workspace that still exists was filed under the deleted-workspace heading"
        )
        XCTAssertFalse(groups[2].attribution.namesADeletedWorkspace)
        XCTAssertTrue(groups[2].attribution.trailsThePage)

        XCTAssertTrue(groups.allSatisfy { $0.attribution.isScratch })
        XCTAssertEqual(
            Set(groups.map(\.identity)).count, 3,
            "two groups share a fold identity, so unfolding one would unfold the other"
        )
    }

    /// The three scratch headings as cards, drawn by the page's own builder so the copy in the
    /// picture is the copy that ships rather than a transcription of it.
    @MainActor
    func testRendersTheScratchStorageGroupsAcrossThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        let controller = StoragePreferencesViewController()
        let groups = scratchFixtureGroups()
        XCTAssertEqual(groups.count, 3, "the fixture did not produce all three tiers")

        var written = 0
        for fixture in Render.fixtures {
            AppThemePalette.set(fixture.theme)

            let page = SettingsUI.page(
                title: "Storage",
                summary: "38.1 GB reclaimable in 24 directories · measured 12 min ago · only 31 GB free",
                actions: [
                    SettingsUI.button("Rescan", target: self, action: #selector(noop)),
                    SettingsUI.button("Remove All…", target: self, action: #selector(noop))
                ],
                sections: groups.enumerated().map { index, group in
                    controller.groupSection(group, groupIndex: index, expanded: true)
                },
                localizes: false
            )

            let host = laidOut(page, height: 900)
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            host.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                data = self.png(of: host)
            }
            let url = directory.appendingPathComponent("storage-scratch-\(fixture.name).png")
            try XCTUnwrap(data, "no render for \(fixture.name)").write(to: url)
            XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])
            written += 1
        }

        print("Rendered \(written) scratch storage pages to \(directory.path)")
        XCTAssertEqual(written, Render.fixtures.count)
    }

    /// The grouped sidebar: one caption per section run, and a filtered list keeping only the
    /// sections that still have rows.
    @MainActor
    func testRendersTheGroupedSettingsSidebar() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        for fixture in Render.fixtures {
            AppThemePalette.set(fixture.theme)
            let sidebar = SettingsSidebar(items: SettingsPages.sidebarItems)
            let host = laidOut(sidebar, height: 700, width: 240)
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            host.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                data = self.png(of: host)
            }
            let url = directory.appendingPathComponent(
                "settings-sidebar-\(fixture.name).png"
            )
            try XCTUnwrap(data, "no sidebar render for \(fixture.name)").write(to: url)

            // The same sidebar mid-search: page rows over their setting-level results, the
            // highlight on the matched words, the Ask AI action riding in the field.
            sidebar.isAskAIAvailable = true
            sidebar.updateSearchQuery("sound")
            host.layoutSubtreeIfNeeded()
            var searchData: Data?
            appearance.performAsCurrentDrawingAppearance {
                searchData = self.png(of: host)
            }
            let searchURL = directory.appendingPathComponent(
                "settings-sidebar-search-\(fixture.name).png"
            )
            try XCTUnwrap(searchData, "no sidebar search render for \(fixture.name)")
                .write(to: searchURL)
        }
    }

    /// While a search is typed the group captions stand down entirely: a result's geography
    /// is the page row above it, not the sidebar's sections. Cleared, the geography returns.
    @MainActor
    func testFilteringStandsTheGroupCaptionsDown() {
        let sidebar = SettingsSidebar(items: [
            .init(id: "a", title: "Alpha", symbol: "gearshape", searchText: "alpha", group: "One"),
            .init(id: "b", title: "Beta", symbol: "keyboard", searchText: "beta", group: "One"),
            .init(id: "c", title: "Gamma", symbol: "paintpalette", searchText: "gamma", group: "Two")
        ])

        sidebar.updateSearchQuery("gamma")

        XCTAssertEqual(sidebar.visibleItemIDs, ["c"])
        let captions = { self.labels(in: sidebar).filter {
            $0.stringValue == "ONE" || $0.stringValue == "TWO"
        } }
        XCTAssertEqual(
            captions().map(\.stringValue), [],
            "results keep no section captions — the page row is the geography"
        )

        sidebar.updateSearchQuery("")
        XCTAssertEqual(
            captions().map(\.stringValue), ["ONE", "TWO"],
            "the resting list keeps one caption per section run"
        )
    }

    // MARK: - Performance

    /// Keeps the Tools settings page's cold render, disclosure mutation and fully expanded scroll
    /// as separate numbers. The page synchronously reads its catalog and account/browser state,
    /// then materializes only the viewport; one elapsed time would make model, mount and paint
    /// costs indistinguishable.
    @MainActor
    func testStressToolsPreferencesWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["THREADING_TOOLS_SETTINGS_STRESS"] == "1" else {
            throw XCTSkip("Set THREADING_TOOLS_SETTINGS_STRESS=1 to run the Tools settings stress case")
        }

        let themeID = AppThemeID(
            ProcessInfo.processInfo.environment["THREADING_TOOLS_SETTINGS_STRESS_THEME"] ?? "system"
        )
        let theme = try XCTUnwrap(AppThemeLibrary.theme(withID: themeID))
        let previousTheme = AppThemePalette.current
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        AppThemePalette.set(theme)
        application.appearance = theme.mode.appearance
        defer {
            AppThemePalette.set(previousTheme)
            application.appearance = previousAppearance
        }

        let catalogStarted = DispatchTime.now().uptimeNanoseconds
        let groups = MCPToolCatalog.allGroups
        let catalogEnded = DispatchTime.now().uptimeNanoseconds
        let toolCount = groups.reduce(0) { $0 + $1.tools.count }

        let controllerStarted = DispatchTime.now().uptimeNanoseconds
        let controller = ToolsPreferencesViewController(groups: groups)
        let controllerEnded = DispatchTime.now().uptimeNanoseconds
        let page = controller.view
        let renderEnded = DispatchTime.now().uptimeNanoseconds
        let window = performanceWindow(page)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds

        let collapsedDescendants = descendantCount(in: page)
        let largestGroupIndex = try XCTUnwrap(
            groups.indices.max { groups[$0].tools.count < groups[$1].tools.count }
        )

        let expandStarted = DispatchTime.now().uptimeNanoseconds
        controller.setGroup(groups[largestGroupIndex].id, expanded: true)
        let expandRenderEnded = DispatchTime.now().uptimeNanoseconds
        host.layoutSubtreeIfNeeded()
        let expandLayoutEnded = DispatchTime.now().uptimeNanoseconds

        let expandedDescendants = descendantCount(in: page)
        let collapseStarted = DispatchTime.now().uptimeNanoseconds
        controller.setGroup(groups[largestGroupIndex].id, expanded: false)
        let collapseRenderEnded = DispatchTime.now().uptimeNanoseconds
        host.layoutSubtreeIfNeeded()
        let collapseLayoutEnded = DispatchTime.now().uptimeNanoseconds

        let expandedController = ToolsPreferencesViewController(groups: groups)
        let expandedPage = expandedController.view
        let expandedWindow = performanceWindow(expandedPage)
        let expandedHost = try XCTUnwrap(expandedWindow.contentView)
        expandedHost.layoutSubtreeIfNeeded()

        var expandAllRenderNanoseconds: UInt64 = 0
        var expandAllLayoutNanoseconds: UInt64 = 0
        for index in groups.indices {
            let started = DispatchTime.now().uptimeNanoseconds
            expandedController.setGroup(groups[index].id, expanded: true)
            let rendered = DispatchTime.now().uptimeNanoseconds
            expandedHost.layoutSubtreeIfNeeded()
            let laidOut = DispatchTime.now().uptimeNanoseconds
            expandAllRenderNanoseconds += rendered - started
            expandAllLayoutNanoseconds += laidOut - rendered
        }

        let scroll = try XCTUnwrap(firstScrollView(in: expandedPage))
        let document = try XCTUnwrap(scroll.documentView)
        let viewport = scroll.bounds
        let overflow = max(document.bounds.height - scroll.contentSize.height, 0)
        let frames = 48
        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: viewport))
        var scrollNanoseconds: UInt64 = 0
        var scrollLayoutNanoseconds: UInt64 = 0
        var drawNanoseconds: UInt64 = 0
        for frame in 0..<frames {
            let fraction = CGFloat(frame) / CGFloat(max(frames - 1, 1))
            let started = DispatchTime.now().uptimeNanoseconds
            scroll.contentView.scroll(to: NSPoint(x: 0, y: overflow * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            let scrolled = DispatchTime.now().uptimeNanoseconds
            expandedHost.layoutSubtreeIfNeeded()
            let laidOut = DispatchTime.now().uptimeNanoseconds
            scroll.cacheDisplay(in: viewport, to: bitmap)
            let drawn = DispatchTime.now().uptimeNanoseconds
            scrollNanoseconds += scrolled - started
            scrollLayoutNanoseconds += laidOut - scrolled
            drawNanoseconds += drawn - laidOut
        }

        print(
            "THREADING_PERF tools-settings-cold "
                + "theme=\(themeID.rawValue) groups=\(groups.count) tools=\(toolCount) "
                + "catalog_ms=\(Self.milliseconds(catalogEnded - catalogStarted)) "
                + "controller_ms=\(Self.milliseconds(controllerEnded - controllerStarted)) "
                + "render_ms=\(Self.milliseconds(renderEnded - controllerEnded)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - renderEnded)) "
                + "descendants=\(collapsedDescendants)"
        )
        print(
            "THREADING_PERF tools-settings-disclosure "
                + "theme=\(themeID.rawValue) group=\(groups[largestGroupIndex].id) "
                + "tools=\(groups[largestGroupIndex].tools.count) "
                + "expand_render_ms=\(Self.milliseconds(expandRenderEnded - expandStarted)) "
                + "expand_layout_ms=\(Self.milliseconds(expandLayoutEnded - expandRenderEnded)) "
                + "collapse_render_ms=\(Self.milliseconds(collapseRenderEnded - collapseStarted)) "
                + "collapse_layout_ms=\(Self.milliseconds(collapseLayoutEnded - collapseRenderEnded)) "
                + "expanded_descendants=\(expandedDescendants)"
        )
        print(
            "THREADING_PERF tools-settings-expanded "
                + "theme=\(themeID.rawValue) groups=\(groups.count) tools=\(toolCount) "
                + "expand_render_ms=\(Self.milliseconds(expandAllRenderNanoseconds)) "
                + "expand_layout_ms=\(Self.milliseconds(expandAllLayoutNanoseconds)) "
                + "document_height=\(Int(document.bounds.height)) "
                + "descendants=\(descendantCount(in: expandedPage)) "
                + "virtual_rows=\(expandedController.virtualRowCount) "
                + "materialized_rows=\(expandedController.materializedRowCount) "
                + "frames=\(frames) "
                + "scroll_ms=\(Self.milliseconds(scrollNanoseconds / UInt64(frames))) "
                + "layout_ms=\(Self.milliseconds(scrollLayoutNanoseconds / UInt64(frames))) "
                + "draw_ms=\(Self.milliseconds(drawNanoseconds / UInt64(frames)))"
        )

        XCTAssertGreaterThanOrEqual(expandedController.virtualRowCount, groups.count + toolCount)
        XCTAssertLessThan(
            expandedController.materializedRowCount,
            expandedController.virtualRowCount,
            "the virtual Tools page retained every expanded row"
        )
        XCTAssertGreaterThan(document.bounds.height, scroll.contentSize.height)
        withExtendedLifetime((window, expandedWindow)) {}
    }

    /// Archived conversations can grow without a product cap. Keep the cold collapsed page,
    /// disclosure, scrolling and a same-data project event separate: the original implementation
    /// made every AppKit row before taking its ten-row prefix, which a collapsed screenshot hid.
    @MainActor
    func testStressArchivedPreferencesWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THREADING_ARCHIVED_SETTINGS_STRESS"] == "1" else {
            throw XCTSkip(
                "Set THREADING_ARCHIVED_SETTINGS_STRESS=1 to run the Archived settings stress case"
            )
        }
        let rowCount = max(
            Int(environment["THREADING_ARCHIVED_SETTINGS_STRESS_ROWS"] ?? "") ?? 1_000,
            ArchivedDefaultsForTesting.recentLimit + 1
        )
        let themeID = AppThemeID(
            environment["THREADING_ARCHIVED_SETTINGS_STRESS_THEME"] ?? "system"
        )
        let theme = try XCTUnwrap(AppThemeLibrary.theme(withID: themeID))
        let previousTheme = AppThemePalette.current
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        AppThemePalette.set(theme)
        application.appearance = theme.mode.appearance
        defer {
            AppThemePalette.set(previousTheme)
            application.appearance = previousAppearance
        }

        let fixtureStarted = DispatchTime.now().uptimeNanoseconds
        let entries = archivedEntries(count: rowCount)
        let fixtureEnded = DispatchTime.now().uptimeNanoseconds
        let memoryBefore = physicalFootprintBytes()
        let controllerStarted = DispatchTime.now().uptimeNanoseconds
        let controller = ArchivedPreferencesViewController(rowsProvider: { entries })
        let controllerEnded = DispatchTime.now().uptimeNanoseconds
        let page = controller.view
        let viewLoaded = DispatchTime.now().uptimeNanoseconds
        controller.viewWillAppear()
        let renderEnded = DispatchTime.now().uptimeNanoseconds
        let window = performanceWindow(page)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds
        let collapsedDescendants = descendantCount(in: page)
        let collapsedVirtualRows = controller.virtualRowCountForTesting
        let collapsedMaterializedRows = controller.materializedRowCountForTesting

        let disclosure = try XCTUnwrap(
            descendants(of: page, type: ThemedDisclosureRow.self).first
        )
        let expandStarted = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(disclosure.performPrimaryAction())
        let expandRenderEnded = DispatchTime.now().uptimeNanoseconds
        host.layoutSubtreeIfNeeded()
        let expandLayoutEnded = DispatchTime.now().uptimeNanoseconds
        let expandedDescendants = descendantCount(in: page)
        let expandedVirtualRows = controller.virtualRowCountForTesting
        let expandedMaterializedRows = controller.materializedRowCountForTesting

        let scroll = try XCTUnwrap(firstScrollView(in: page))
        let scrollStarted = DispatchTime.now().uptimeNanoseconds
        let overflow = max(
            (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height,
            0
        )
        scroll.contentView.scroll(to: NSPoint(x: 0, y: overflow))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        let scrollEnded = DispatchTime.now().uptimeNanoseconds
        let originBeforeRefresh = scroll.contentView.bounds.origin

        let refreshStarted = DispatchTime.now().uptimeNanoseconds
        NotificationCenter.default.post(ProjectsDidChange())
        let refreshRenderEnded = DispatchTime.now().uptimeNanoseconds
        host.layoutSubtreeIfNeeded()
        let refreshLayoutEnded = DispatchTime.now().uptimeNanoseconds
        let originAfterRefresh = scroll.contentView.bounds.origin
        let memoryAfter = physicalFootprintBytes()
        let memoryDelta = memoryAfter >= memoryBefore ? memoryAfter - memoryBefore : 0

        print(
            "THREADING_PERF archived-settings "
                + "theme=\(themeID.rawValue) rows=\(rowCount) "
                + "fixture_ms=\(Self.milliseconds(fixtureEnded - fixtureStarted)) "
                + "controller_ms=\(Self.milliseconds(controllerEnded - controllerStarted)) "
                + "view_load_ms=\(Self.milliseconds(viewLoaded - controllerEnded)) "
                + "render_ms=\(Self.milliseconds(renderEnded - viewLoaded)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - renderEnded)) "
                + "expand_render_ms=\(Self.milliseconds(expandRenderEnded - expandStarted)) "
                + "expand_layout_ms=\(Self.milliseconds(expandLayoutEnded - expandRenderEnded)) "
                + "scroll_to_end_ms=\(Self.milliseconds(scrollEnded - scrollStarted)) "
                + "refresh_render_ms=\(Self.milliseconds(refreshRenderEnded - refreshStarted)) "
                + "refresh_layout_ms=\(Self.milliseconds(refreshLayoutEnded - refreshRenderEnded)) "
                + "collapsed_descendants=\(collapsedDescendants) "
                + "expanded_descendants=\(expandedDescendants) "
                + "collapsed_virtual_rows=\(collapsedVirtualRows) "
                + "collapsed_materialized_rows=\(collapsedMaterializedRows) "
                + "expanded_virtual_rows=\(expandedVirtualRows) "
                + "expanded_materialized_rows=\(expandedMaterializedRows) "
                + "footprint_delta_mb=\(Self.megabytes(memoryDelta))"
        )

        XCTAssertGreaterThanOrEqual(expandedVirtualRows, rowCount + 2)
        XCTAssertGreaterThan(collapsedMaterializedRows, 0)
        XCTAssertLessThan(expandedMaterializedRows, expandedVirtualRows)
        XCTAssertEqual(originAfterRefresh.x, originBeforeRefresh.x, accuracy: 0.5)
        XCTAssertEqual(originAfterRefresh.y, originBeforeRefresh.y, accuracy: 0.5)
        withExtendedLifetime(window) {}
    }

    /// Exercises the coarse Website Access row independently of the tool catalog. The outer
    /// table cannot provide a viewport bound when one cell itself retains every origin row.
    @MainActor
    func testStressToolsWebsiteAccessWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THREADING_TOOLS_WEBSITE_ACCESS_STRESS"] == "1" else {
            throw XCTSkip(
                "Set THREADING_TOOLS_WEBSITE_ACCESS_STRESS=1 to run Website Access stress."
            )
        }
        let originCount = max(
            Int(environment["THREADING_TOOLS_WEBSITE_ACCESS_STRESS_ORIGINS"] ?? "") ?? 1_000,
            1
        )
        let suite = "ToolsWebsiteAccessStress-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            (0..<originCount).map { "https://stress-\($0).example.test" },
            forKey: "browser.allowedOrigins"
        )
        let previousProvider = BrowserCredentialPreference.provider
        BrowserCredentialPreference.provider = .systemAutoFill
        defer { BrowserCredentialPreference.provider = previousProvider }

        let memoryBefore = physicalFootprintBytes()
        let controller = ToolsPreferencesViewController(
            groups: [],
            browserAccessStore: BrowserAccessStore(defaults: defaults)
        )
        let loadStarted = DispatchTime.now().uptimeNanoseconds
        let page = controller.view
        let loaded = DispatchTime.now().uptimeNanoseconds
        let window = performanceWindow(page)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let laidOut = DispatchTime.now().uptimeNanoseconds
        let descendants = descendantCount(in: page)
        let memoryAfter = physicalFootprintBytes()
        let memoryDelta = memoryAfter >= memoryBefore ? memoryAfter - memoryBefore : 0

        print(
            "THREADING_PERF tools-website-access origins=\(originCount) "
                + "load_ms=\(Self.milliseconds(loaded - loadStarted)) "
                + "layout_ms=\(Self.milliseconds(laidOut - loaded)) "
                + "virtual_rows=\(controller.virtualRowCount) "
                + "materialized_rows=\(controller.materializedRowCount) "
                + "descendants=\(descendants) "
                + "footprint_delta_mb=\(Self.megabytes(memoryDelta))"
        )

        XCTAssertGreaterThanOrEqual(controller.virtualRowCount, originCount + 5)
        XCTAssertGreaterThan(controller.materializedRowCount, 0)
        XCTAssertLessThan(controller.materializedRowCount, controller.virtualRowCount)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: page), [])
        withExtendedLifetime(window) {}
    }

    /// Exercises Browser Sign-In's inner inventory independently of Keychain and 1Password.
    /// Submission exemptions are process-lifetime values, but they share the same coarse outer
    /// table cell as stored credentials and therefore expose the same retained-stack scaling.
    @MainActor
    func testStressToolsBrowserSignInWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THREADING_TOOLS_BROWSER_SIGN_IN_STRESS"] == "1" else {
            throw XCTSkip(
                "Set THREADING_TOOLS_BROWSER_SIGN_IN_STRESS=1 to run Browser Sign-In stress."
            )
        }
        let originCount = max(
            Int(environment["THREADING_TOOLS_BROWSER_SIGN_IN_STRESS_ORIGINS"] ?? "") ?? 1_000,
            1
        )
        let previousProvider = BrowserCredentialPreference.provider
        BrowserCredentialPreference.provider = .systemAutoFill
        let exemptions = BrowserSubmissionExemptions.shared
        exemptions.revokeAll()
        defer {
            exemptions.revokeAll()
            BrowserCredentialPreference.provider = previousProvider
        }
        for index in 0..<originCount {
            let url = try XCTUnwrap(URL(string: "https://stress-\(index).example.test"))
            exemptions.exempt(try XCTUnwrap(BrowserOrigin(url: url)))
        }

        let memoryBefore = physicalFootprintBytes()
        let controller = ToolsPreferencesViewController(
            groups: [],
            browserAccessStore: BrowserAccessStore()
        )
        let loadStarted = DispatchTime.now().uptimeNanoseconds
        let page = controller.view
        let loaded = DispatchTime.now().uptimeNanoseconds
        let window = performanceWindow(page)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let laidOut = DispatchTime.now().uptimeNanoseconds
        let descendants = descendantCount(in: page)
        let memoryAfter = physicalFootprintBytes()
        let memoryDelta = memoryAfter >= memoryBefore ? memoryAfter - memoryBefore : 0

        print(
            "THREADING_PERF tools-browser-sign-in origins=\(originCount) "
                + "load_ms=\(Self.milliseconds(loaded - loadStarted)) "
                + "layout_ms=\(Self.milliseconds(laidOut - loaded)) "
                + "virtual_rows=\(controller.virtualRowCount) "
                + "materialized_rows=\(controller.materializedRowCount) "
                + "descendants=\(descendants) "
                + "footprint_delta_mb=\(Self.megabytes(memoryDelta))"
        )

        XCTAssertGreaterThanOrEqual(controller.virtualRowCount, originCount + 6)
        XCTAssertGreaterThan(controller.materializedRowCount, 0)
        XCTAssertLessThan(controller.materializedRowCount, controller.virtualRowCount)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: page), [])
        withExtendedLifetime(window) {}
    }

    @MainActor
    private func labels(in root: NSView) -> [NSTextField] {
        descendants(of: root, type: NSTextField.self)
    }

    /// One finding from the scratch scope, shaped the way the scanner returns them: a
    /// manifest-gated kind, a scratch root for a checkout it has none of, and the workspace its
    /// `info.plist` named.
    @MainActor
    private func scratchArtifact(
        _ path: String,
        workspace: String,
        bytes: Int64,
        root: String = "/private/tmp",
        age: TimeInterval = 60 * 60 * 26
    ) -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: URL(fileURLWithPath: path),
            kind: .xcodeDerivedData,
            byteCount: bytes,
            modifiedAt: Date(timeIntervalSinceNow: -age),
            checkoutPath: root,
            workspacePath: workspace
        )
    }

    /// Which tier a group landed in, named rather than compared: the attribution carries a
    /// `Project`, which is not `Equatable`, and the assertion wants to read as the page's three
    /// headings anyway.
    @MainActor
    private func tier(of attribution: StoragePreferencesViewController.GroupAttribution) -> String {
        switch attribution {
        case .checkout: return "checkout"
        case .scratchProject: return "project"
        case .scratchOrphan: return "orphan"
        case .scratchOther: return "other"
        }
    }

    /// The three tiers with enough between them to draw: two large caches and a small one under
    /// the project's heading, so its sub-gigabyte fold row appears too, plus one orphan and one
    /// tree belonging to a workspace that is alive and is not ours.
    @MainActor
    private func scratchFixtureGroups() -> [StoragePreferencesViewController.FindingsGroup] {
        let project = Project(
            name: "Threading",
            folderURL: URL(fileURLWithPath: "/Users/dev/repo/Threading")
        )
        let workspace = "/Users/dev/repo/Threading/Threading.xcodeproj"
        let stranger = "/Users/dev/repo/sonda/Sonda.xcodeproj"
        let artifacts = [
            scratchArtifact("/private/tmp/dd", workspace: workspace, bytes: 14_800_000_000),
            scratchArtifact("/private/tmp/verify-dd", workspace: workspace, bytes: 6_120_000_000),
            scratchArtifact(
                "/private/tmp/dd-snap",
                workspace: workspace,
                bytes: 402_000_000,
                age: 60 * 4
            ),
            scratchArtifact(
                "/private/tmp/claude-501/8f3c/scratchpad/dd",
                workspace: "/private/tmp/claude-501/8f3c/scratchpad/tree/Threading.xcodeproj",
                bytes: 9_400_000_000
            ),
            scratchArtifact(
                "/var/folders/qy/9x8k2/T/codex-dd",
                workspace: stranger,
                bytes: 3_260_000_000,
                root: "/var/folders/qy/9x8k2/T"
            )
        ]

        return StoragePreferencesViewController.scratchGroups(
            artifacts,
            among: [project],
            workspaceExists: { $0 == workspace || $0 == stranger }
        )
    }

    /// One reclaimable directory, built the way the Storage page builds it.
    @MainActor
    private func storageRow(path: String, size: String, age: String) -> NSView {
        let reading = NSTextField(labelWithString: size)
        reading.applyFont(.numericBody)
        reading.textColor = Design.Text.secondary
        reading.alignment = .right

        return SettingsUI.row(
            title: path,
            subtitle: "Rust build output · cargo build · last written \(age)",
            control: SettingsUI.controlGroup([
                reading,
                SettingsUI.button("Remove", target: self, action: #selector(noop))
            ]),
            localizes: false
        )
    }

    @objc private func noop() {}

    /// Fails naming the widest offender, so a regression reads as "this label pushed" rather
    /// than as two images differing.
    @MainActor
    private func assertNothingWiderThanThePage(
        in host: NSView,
        fixture: String,
        state: String
    ) {
        var widest: (view: NSView, width: CGFloat)?
        func walk(_ view: NSView) {
            if view.frame.width > SettingsUIDefaults.pageWidth + 1,
               view.frame.width > (widest?.width ?? 0) {
                widest = (view, view.frame.width)
            }
            view.subviews.forEach(walk)
        }
        walk(host)

        if let widest {
            let text = (widest.view as? NSTextField)?.stringValue.prefix(40) ?? ""
            XCTFail(
                "\(fixture)/\(state): \(type(of: widest.view)) is \(Int(widest.width))pt in a "
                    + "\(Int(SettingsUIDefaults.pageWidth))pt page \(text)"
            )
        }
    }

    // MARK: - Helpers

    @MainActor
    private func laidOut(
        _ view: NSView,
        height: CGFloat = Render.height,
        width: CGFloat = Render.width
    ) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func documentHeight(in root: NSView) -> CGFloat {
        firstScrollView(in: root)?.documentView?.bounds.height ?? 0
    }

    @MainActor
    private func firstScrollView(in root: NSView) -> NSScrollView? {
        descendants(of: root, type: NSScrollView.self).first
    }

    @MainActor
    private func performanceWindow(_ page: NSView) -> NSWindow {
        let host = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: Render.width,
            height: 700
        ))
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        return window
    }

    @MainActor
    private func descendantCount(in root: NSView) -> Int {
        1 + root.subviews.reduce(0) { $0 + descendantCount(in: $1) }
    }

    @MainActor
    private func archivedEntries(count: Int) -> [ArchivedPreferencesViewController.Entry] {
        let project = Project(
            name: "Archive stress",
            folderURL: URL(fileURLWithPath: "/tmp/threading-archive-stress")
        )
        let now = Date()
        return (0..<count).map { index in
            var session = AgentSession(
                kind: .codex,
                title: "Archived conversation \(index) with a representative long title"
            )
            session.isArchived = true
            session.lastActiveAt = now.addingTimeInterval(TimeInterval(-index * 60))
            return (project, session)
        }
    }

    private func physicalFootprintBytes() -> UInt64 {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        return ProcessUtility.getResourceUsage(forPid: pid)?.memoryBytes ?? 0
    }

    @MainActor
    private func descendants<T: NSView>(of root: NSView, type: T.Type) -> [T] {
        var found: [T] = []
        for view in root.subviews {
            if let match = view as? T { found.append(match) }
            found += descendants(of: view, type: type)
        }
        return found
    }

    @MainActor
    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = AppThemePalette.current.resolved(.ground).cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.2f", Double(nanoseconds) / 1_000_000)
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

private enum ArchivedDefaultsForTesting {
    static let recentLimit = 10
}
