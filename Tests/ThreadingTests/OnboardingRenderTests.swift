import AppKit
import UserNotifications
import XCTest
@testable import Threading

/// The walkthrough drawn whole — flow chrome plus each page — light and dark, System plus two
/// deliberately different themes. The appearance page is also asserted structurally: thirteen
/// tiles, one selected, and a mid-build theme switch survived, because that page's whole
/// argument is restyling the wizard live.
@MainActor
final class OnboardingRenderTests: XCTestCase {

    private enum Render {
        static let size = NSSize(width: 760, height: 560)

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    func testAppearancePageOffersEveryStockThemeAndMarksTheCurrentOne() {
        let page = OnboardingAppearancePageViewController()
        _ = page.view
        page.view.layoutSubtreeIfNeeded()

        let tiles = descendants(of: page.view).compactMap { $0 as? NavigatorGridItemView }
        XCTAssertEqual(tiles.count, AppThemeLibrary.stock.count)
        XCTAssertEqual(tiles.filter(\.isSelected).count, 1)
    }

    func testAppearancePageFollowsAThemeAppliedWhileItIsUp() throws {
        let page = OnboardingAppearancePageViewController()
        _ = page.view
        page.view.layoutSubtreeIfNeeded()

        let cyberpunk = try XCTUnwrap(AppThemeLibrary.stock.first { $0.name == "Cyberpunk" })
        AppThemeLibrary.apply(cyberpunk)
        defer { AppThemeLibrary.apply(.system) }

        let tiles = descendants(of: page.view).compactMap { $0 as? NavigatorGridItemView }
        let selected = tiles.filter(\.isSelected)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.accessibilityTitle(), "Cyberpunk")
    }

    func testActivatingATileAppliesItsTheme() throws {
        let page = OnboardingAppearancePageViewController()
        _ = page.view
        page.view.layoutSubtreeIfNeeded()
        defer { AppThemeLibrary.apply(.system) }

        let tile = try XCTUnwrap(
            descendants(of: page.view).compactMap { $0 as? NavigatorGridItemView }.first {
                $0.accessibilityTitle() == "Swiss Minimalist"
            }
        )
        _ = tile.performPrimaryAction()
        XCTAssertEqual(AppThemeLibrary.current.name, "Swiss Minimalist")
    }

    func testRendersTheFlowUnderSystemAndTwoStyledThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let styled = ["Cyberpunk", "Swiss Minimalist"].map { name in
            AppThemeLibrary.stock.first { $0.name == name }
        }
        let themes = try [AppTheme.system] + styled.map { try XCTUnwrap($0) }

        var written = 0
        for theme in themes {
            AppThemePalette.set(theme)
            for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    data = flowImage(appearance: appearance, theme: theme)
                }
                let url = directory.appendingPathComponent(
                    "onboarding-appearance-\(theme.id.rawValue)-\(suffix).png"
                )
                try XCTUnwrap(data, "Failed to render \(theme.name) \(suffix)").write(to: url)
                written += 1
            }
        }
        print("Rendered \(written) onboarding pages to \(directory.path)")
        XCTAssertEqual(written, themes.count * 2)
    }

    /// The remaining pages, each in its telling state, drawn once in light and dark: the
    /// discovery page as this machine sees it, the import page over a fixture scan, and the
    /// notifications page in all three authorization states.
    func testRendersTheOtherPages() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AppThemePalette.set(.system)

        let fixtureScan = GlobalScanResult(
            groups: [
                DiscoveredProjectImports(
                    folder: "/Users/dev/code/threading",
                    conversations: [
                        fixtureSession("a", title: "Fix the login flow", hoursAgo: 3),
                        fixtureSession("b", title: "Migrate the settings store", hoursAgo: 30),
                        fixtureSession("c", title: "Spike: themed checkboxes", hoursAgo: 200)
                    ]
                ),
                DiscoveredProjectImports(
                    folder: "/Users/dev/code/side-project",
                    conversations: [
                        fixtureSession("d", title: "Write the readme", hoursAgo: 12)
                    ]
                )
            ],
            missingFolderConversations: 2
        )

        var pages: [(String, () -> NSViewController)] = [
            ("discovery", { OnboardingDiscoveryPageViewController() }),
            ("import", {
                let page = OnboardingImportPageViewController()
                _ = page.view
                page.apply(result: fixtureScan)
                return page
            })
        ]
        for (name, status) in [
            ("notifications-undetermined", UNAuthorizationStatus.notDetermined),
            ("notifications-granted", .authorized),
            ("notifications-denied", .denied)
        ] {
            pages.append((name, {
                let page = OnboardingNotificationsPageViewController()
                _ = page.view
                page.apply(authorization: status)
                return page
            }))
        }

        var written = 0
        for (name, make) in pages {
            for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    data = pageImage(make(), appearance: appearance)
                }
                let url = directory.appendingPathComponent("onboarding-\(name)-\(suffix).png")
                try XCTUnwrap(data, "Failed to render \(name) \(suffix)").write(to: url)
                written += 1
            }
        }
        print("Rendered \(written) onboarding pages to \(directory.path)")
        XCTAssertEqual(written, pages.count * 2)
    }

    private func fixtureSession(
        _ id: String,
        title: String,
        hoursAgo: Double
    ) -> ImportableSession {
        ImportableSession(
            agentSessionID: TranscriptID(id),
            kind: .claude,
            accountHandle: .standard,
            title: title,
            lastActiveAt: Date(timeIntervalSinceNow: -hoursAgo * 60 * 60)
        )
    }

    private func pageImage(_ page: NSViewController, appearance: NSAppearance) -> Data? {
        let host = NSView(frame: NSRect(origin: .zero, size: Render.size))
        host.appearance = appearance
        let view = page.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = AppTheme.system
            .resolved(.ground, appearance: appearance).cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func flowImage(appearance: NSAppearance, theme: AppTheme) -> Data? {
        let flow = OnboardingFlowViewController(
            pages: [OnboardingAppearancePageViewController()],
            onFinish: {}
        )
        let host = NSView(frame: NSRect(origin: .zero, size: Render.size))
        host.appearance = appearance
        let view = flow.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = theme.resolved(.ground, appearance: appearance).cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
