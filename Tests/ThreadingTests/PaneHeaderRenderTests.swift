import AppKit
import XCTest
@testable import Threading

/// Draws the pane header at the sidebar's width, on the sidebar's own ground, and writes each
/// state out as an image — System light and dark plus the two deliberately different stock
/// themes, per the component contract in `docs/THEME_BOUNDARY.md`.
///
/// The same reason `PaneFooterRenderTests` exists, at the other end of the pane: whether the
/// band, its hairline and the lone trailing control read as one quiet strip is a relationship
/// no assertion states.
@MainActor
final class PaneHeaderRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]

        static let themes: [(name: String, theme: AppTheme)] = [
            ("system", .system),
            ("cyberpunk", AppThemeStyles.cyberpunk),
            ("swiss", AppThemeStyles.swissMinimalist),
            ("bauhaus", AppThemeStyles.bauhaus)
        ]
    }

    // MARK: - Stories

    func testRendersTheHeaderStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    headerImage(appearance: appearanceID),
                    "Failed to render the header under \(themeName) in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "header-\(themeName)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count)
        print("Rendered pane header storybook to \(directory.path)")
    }

    /// The shipping header with the spectrum material selected: three live workers, a recent
    /// semantic-output pulse, and MAX lit because one worker uses its provider's top effort.
    func testRendersClassicPlayerWorkloadAnalyzer() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer {
            AppThemePalette.set(.system)
            Design.Motion.reduceMotionOverrideForTesting = nil
        }
        AppThemePalette.set(AppThemeStyles.classicPlayer)
        Design.Motion.reduceMotionOverrideForTesting = true

        let intensity = AgentIntensity(
            workload: AgentWorkload(workingCount: 3, anyAtTopEffort: true),
            recentActivity: 0.78,
            measuredAt: 100
        )
        let data = try XCTUnwrap(
            headerImage(appearance: .darkAqua, workloadIntensity: intensity),
            "Failed to render the Classic Player workload analyzer"
        )
        try data.write(
            to: directory.appendingPathComponent(
                "sidebar-workload-analyzer-classic-player.png"
            )
        )
        print("Rendered Classic Player workload analyzer to \(directory.path)")
    }

    // MARK: - Helpers

    /// The sidebar header's exact shape: the brand row at the leading edge, the list's add
    /// and arrangement controls at the trailing one.
    private func headerImage(
        appearance name: NSAppearance.Name,
        workloadIntensity: AgentIntensity? = nil
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let brand = SidebarBrandView()
            if let workloadIntensity,
               let analyzer = self.descendant(
                   of: brand,
                   as: AgentWorkloadAnalyzerView.self
               ) {
                analyzer.freezePresentationForTesting(
                    intensity: workloadIntensity,
                    phase: 0.37
                )
            }

            let add = ThemedIconButton(
                symbolName: "plus",
                accessibility: "Add Project",
                target: .inline,
                inkSource: .chrome
            )

            let arrange = ThemedIconButton(
                symbolName: SidebarDefaults.arrangementSymbol,
                accessibility: SidebarStrings.arrangementOptions,
                target: .inline,
                inkSource: .chrome
            )

            let header = PaneHeaderView(leading: [brand], trailing: [add, arrange])

            let host = ThemedSurfaceView()
            host.frame = NSRect(
                x: 0,
                y: 0,
                width: SidebarDefaults.defaultWidth,
                height: PaneHeaderView.bandHeight * 2
            )
            host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            host.appearance = appearance
            host.addSubview(header)

            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                header.topAnchor.constraint(equalTo: host.topAnchor)
            ])
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }

        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return data
    }

    private func descendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = descendant(of: subview, as: type) { return match }
        }
        return nil
    }
}
