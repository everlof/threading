import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// Theme Options on the Current Theme page: the contributing extension's own settings, shown
/// beside the theme they shape and only while that theme is the active one.
@MainActor
final class CurrentThemeOptionsTests: XCTestCase {

    private static let extensionIdentifier = "com.example.matrix-rain"

    /// Both registries, the theme, its stored choice and the app appearance are the app's own;
    /// the guard puts back exactly what this class found — not "empty" and not the stored
    /// choice, either of which can differ from what the previous class left in force.
    private var hostedState: HostedExtensionStateGuard?

    override func setUp() async throws {
        try await super.setUp()
        hostedState = HostedExtensionStateGuard()
        // The rows read their values through `ExtensionManager.shared`, and that manager's first
        // touch replaces the settings registry with its own inventory — silently. Made here, the
        // fixture's registry is installed after it rather than wiped by the first row built; the
        // guard was taken first, so even that replacement is put back.
        _ = ExtensionManager.shared
    }

    override func tearDown() async throws {
        hostedState?.restore()
        hostedState = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// Adaptive, so the light and dark renders really are light and dark.
    private var theme: AppTheme {
        let base = AppThemeStyles.threading
        return AppTheme(
            id: AppThemeID("ext.\(Self.extensionIdentifier).matrix"),
            name: "The Matrix",
            mode: base.mode,
            summary: "Contributed for tests",
            variants: base.variants
        )
    }

    private var manifest: ExtensionManifest {
        ExtensionManifest(
            identifier: Self.extensionIdentifier,
            name: "Matrix Rain",
            version: "0.3.0",
            runtime: .webAssembly,
            executable: "bin/matrix-rain.wasm",
            capabilities: [.settings],
            settings: ExtensionSettingsContribution(sections: [
                .init(id: "rain", page: .themes, title: "Rain", fields: [
                    .init(
                        id: "perimeter-comets",
                        title: "Perimeter comets",
                        description: "Comets run around the window's edge.",
                        control: .toggle(defaultValue: true),
                        appliedBy: .host
                    ),
                    .init(
                        id: "density",
                        title: "Density",
                        control: .choice(defaultValue: "normal", options: [
                            .init(id: "sparse", title: "Sparse", value: 0.25),
                            .init(id: "normal", title: "Normal", value: 0.5),
                            .init(id: "storm", title: "Storm", value: 1)
                        ]),
                        appliedBy: .host
                    )
                ])
            ])
        )
    }

    private func install(theme: AppTheme, settings: Bool) {
        ExtensionAppearanceRegistry.shared.replace(contributions: [
            .init(
                extensionIdentifier: Self.extensionIdentifier,
                extensionName: "Matrix Rain",
                themes: [theme],
                fontURLs: []
            )
        ])
        ExtensionSettingsRegistry.shared.replace(enabledManifests: settings ? [manifest] : [])
    }

    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
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

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func options(in root: NSView) throws -> CurrentThemeOptionsSection {
        try XCTUnwrap(descendants(in: root).compactMap { $0 as? CurrentThemeOptionsSection }.first)
    }

    private func view(_ identifier: String, in root: NSView) -> NSView? {
        descendants(in: root).first { $0.accessibilityIdentifier() == identifier }
    }

    // MARK: - Presence

    func testThemeOptionsFollowTheActiveContributedTheme() throws {
        let contributed = theme
        install(theme: contributed, settings: true)
        AppThemeLibrary.apply(contributed)

        let controller = CurrentThemeViewController()
        _ = laidOut(controller.view, width: SettingsUIDefaults.pageWidth, height: 1000)
        let section = try options(in: controller.view)
        XCTAssertFalse(section.isHidden, "a contributed theme with settings shows its options")
        XCTAssertEqual(section.extensionIdentifierForTesting, Self.extensionIdentifier)
        let toggle = try XCTUnwrap(
            view("settings.extension.\(Self.extensionIdentifier).perimeter-comets", in: section)
                as? ThemedToggle,
            "the field is the Settings page's own themed control"
        )
        XCTAssertEqual(toggle.state, .on)
        XCTAssertTrue(
            view("settings.extension.\(Self.extensionIdentifier).density", in: section) is ThemedPopUp
        )

        AppThemeLibrary.apply(AppThemeStyles.swissMinimalist)
        XCTAssertTrue(section.isHidden, "a built-in theme has no extension options")
        XCTAssertTrue(section.subviews.isEmpty, "the absent section keeps no rows")
        XCTAssertNil(section.extensionIdentifierForTesting)

        AppThemeLibrary.apply(contributed)
        XCTAssertFalse(section.isHidden)

        ExtensionSettingsRegistry.shared.replace(enabledManifests: [])
        XCTAssertTrue(section.isHidden, "disabling the extension takes its options away")
        ExtensionSettingsRegistry.shared.replace(enabledManifests: [manifest])
        XCTAssertFalse(section.isHidden, "enabling it brings them back without a theme change")
    }

    func testAContributedThemeWithoutSettingsShowsNoOptions() throws {
        let contributed = theme
        install(theme: contributed, settings: false)
        AppThemeLibrary.apply(contributed)

        let controller = CurrentThemeViewController()
        _ = laidOut(controller.view, width: SettingsUIDefaults.pageWidth, height: 1000)
        XCTAssertTrue(try options(in: controller.view).isHidden)
        XCTAssertNil(view("current-theme.options.rain", in: controller.view))
    }

    // MARK: - Rendering

    /// The page top — overview, then Theme Options — light and dark, at the shared settings
    /// width and in a squeezed pane, written beside the other Current Theme renders.
    func testRendersThemeOptionsLightAndDark() throws {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
           !override.isEmpty {
            directory = URL(fileURLWithPath: override)
        } else {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let contributed = theme
        install(theme: contributed, settings: true)
        AppThemeLibrary.apply(contributed)

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width in [420, SettingsUIDefaults.pageWidth] {
                let controller = CurrentThemeViewController()
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                controller.view.appearance = appearance
                let host = laidOut(controller.view, width: width, height: 760)
                host.appearance = appearance
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
                    AppThemeRefresh.repaint(host)
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        data = rep.representation(using: .png, properties: [:])
                    }
                }

                let section = try options(in: controller.view)
                XCTAssertFalse(section.isHidden)
                let frame = section.convert(section.bounds, to: host)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertLessThanOrEqual(
                    frame.maxX, host.bounds.maxX + 0.5,
                    "the options card overflowed a \(Int(width))pt pane"
                )
                let url = directory.appendingPathComponent(
                    "current-theme-options-\(name)-\(Int(width)).png"
                )
                try XCTUnwrap(data, "no render for \(name) at \(Int(width))").write(to: url)
            }
        }
    }
}
