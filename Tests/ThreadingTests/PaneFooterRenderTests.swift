import AppKit
import XCTest
@testable import Threading

/// Draws the pane footer at the sidebar's width, on the sidebar's own ground, and writes each
/// state out as an image — System light and dark plus the two deliberately different stock
/// themes, per the component contract in `docs/THEME_BOUNDARY.md`.
///
/// It exists because the thing the footer fixes is a *relationship* no assertion states:
/// whether the band's two margins read as balanced when one edge meets the window's rounded
/// corner and the other a straight divider. `PaneFooterTests` pins the arithmetic — ink on the
/// stated margin, measured from the corner-adapted region — and these pin what the arithmetic
/// is for.
@MainActor
final class PaneFooterRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
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
            ("swiss", AppThemeStyles.swissMinimalist)
        ]
    }

    // MARK: - Stories

    func testRendersTheFooterStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    footerImage(appearance: appearanceID),
                    "Failed to render the footer under \(themeName) in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "footer-\(themeName)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count)
        print("Rendered pane footer storybook to \(directory.path)")
    }

    /// The same band as a non-release build wears it: the channel mark beside Settings.
    /// NIGHTLY is the story because it is the longest of the three titles.
    func testRendersTheFooterWithABuildChannelBadge() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    footerImage(appearance: appearanceID, channel: .nightly),
                    "Failed to render the badged footer under \(themeName) in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "footer-badge-\(themeName)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count)
        print("Rendered badged pane footer storybook to \(directory.path)")
    }

    /// The band carrying the global silence gate, in both of its states.
    ///
    /// The worn state is the part no assertion can review. "Quiet when inactive, filled and
    /// tinted while silenced" is a claim about a *relationship* — how loudly the on-state reads
    /// against the Settings button it shares a band with, under themes whose control surfaces
    /// differ as much as Cyberpunk's and Swiss Minimalist's — and a control that stops every
    /// sound the app makes and then hides is the mystery-noise problem inverted.
    func testRendersTheSilenceGateInBothStates() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                for (stateName, silenced) in [("audible", false), ("silenced", true)] {
                    let data = try XCTUnwrap(
                        footerImage(appearance: appearanceID, silenced: silenced),
                        "Failed to render the \(stateName) gate under \(themeName) in \(appearanceName)"
                    )
                    try data.write(
                        to: directory.appendingPathComponent(
                            "footer-silence-\(stateName)-\(themeName)-\(appearanceName).png"
                        )
                    )
                    written += 1
                }
            }
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count * 2)
        print("Rendered silence-gate footer storybook to \(directory.path)")
    }

    // MARK: - Helpers

    /// The sidebar footer's exact shape: the band at the pane's bottom on the pane's own
    /// ground, the titled Settings button at the leading margin — followed by the channel
    /// badge when a channel is asked for, exactly as `ProjectSidebarViewController` builds it,
    /// and the silence gate in the trailing slot when a state for it is asked for.
    private func footerImage(
        appearance name: NSAppearance.Name,
        channel: BuildChannel? = nil,
        silenced: Bool? = nil
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let gear = ThemedButton()
            gear.title = "Settings"
            gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?
                .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
            gear.isBordered = false
            gear.font = Design.Typography.controlRegular()

            let leading = [gear, channel.flatMap(BuildChannelBadge.make(for:))].compactMap { $0 }
            let trailing: [NSView] = silenced.map { isOn in
                let gate = ThemedIconButton(
                    symbolName: SidebarDefaults.silenceSymbol,
                    accessibility: SidebarStrings.silenceSounds,
                    target: .inline,
                    inkSource: .chrome
                )
                gate.isSelected = isOn
                return [gate]
            } ?? []
            let footer = PaneFooterView(leading: leading, trailing: trailing)

            let host = ThemedSurfaceView()
            host.frame = NSRect(
                x: 0,
                y: 0,
                width: SidebarDefaults.defaultWidth,
                height: Design.Size.footerHeight * 2
            )
            host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            host.appearance = appearance
            host.addSubview(footer)

            NSLayoutConstraint.activate([
                footer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                footer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                footer.bottomAnchor.constraint(equalTo: host.bottomAnchor)
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
}
