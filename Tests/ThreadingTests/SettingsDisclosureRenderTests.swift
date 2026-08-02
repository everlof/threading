import AppKit
import XCTest
@testable import Threading

/// Draws the reworked settings surfaces — the pinned page header and the collapsed cards — to
/// images, under System light and dark plus two deliberately different authored themes.
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

        /// System in both appearances, plus the two styles the design docs name as the
        /// representative extremes — neon-on-dark and print-red-on-light.
        @MainActor
        static var fixtures: [(name: String, theme: AppTheme, appearance: NSAppearance.Name)] {
            [
                ("system-light", .system, .aqua),
                ("system-dark", .system, .darkAqua),
                ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
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

        let collapsedHeight = documentHeight(in: controller.view)
        let disclosure = try XCTUnwrap(
            descendants(of: controller.view, type: ThemedDisclosureRow.self).first,
            "the Tools page built no disclosure headers"
        )

        XCTAssertTrue(disclosure.performPrimaryAction())
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            documentHeight(in: controller.view), collapsedHeight,
            "unfolding the first group did not add its tool rows"
        )
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
    private func laidOut(_ view: NSView, height: CGFloat = Render.height) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: height))
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
}
