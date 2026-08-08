import AppKit
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

            let storageShaped = SettingsUI.disclosureCard(
                title: "sonda · feature/deploy-pipeline",
                subtitle: "~/repo/sonda/.worktrees/feature-deploy-pipeline",
                summary: "12.4 GB",
                control: SettingsUI.button("Remove All…", target: self, action: #selector(noop)),
                isExpanded: false,
                localizes: false,
                onToggle: { _ in }
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
            let url = directory.appendingPathComponent("sidebar-\(fixture.name).png")
            try XCTUnwrap(data, "no sidebar render for \(fixture.name)").write(to: url)
        }
    }

    @MainActor
    func testFilteringKeepsOnlySectionsWithSurvivingRows() {
        let sidebar = SettingsSidebar(items: [
            .init(id: "a", title: "Alpha", symbol: "gearshape", searchText: "alpha", group: "One"),
            .init(id: "b", title: "Beta", symbol: "keyboard", searchText: "beta", group: "One"),
            .init(id: "c", title: "Gamma", symbol: "paintpalette", searchText: "gamma", group: "Two")
        ])

        sidebar.updateSearchQuery("gamma")

        XCTAssertEqual(sidebar.visibleItemIDs, ["c"])
        let captions = labels(in: sidebar).filter { $0.stringValue == "ONE" || $0.stringValue == "TWO" }
        XCTAssertEqual(
            captions.map(\.stringValue), ["TWO"],
            "a section with no surviving rows kept its caption"
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

    @MainActor
    private func labels(in root: NSView) -> [NSTextField] {
        descendants(of: root, type: NSTextField.self)
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
}
