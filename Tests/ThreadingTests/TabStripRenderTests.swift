import AppKit
import XCTest
@testable import Threading

/// Draws the tab strip and writes each state out as an image — System light and dark plus the
/// two deliberately different stock themes, per the component contract in
/// `docs/THEME_BOUNDARY.md`.
///
/// Two stories: a strip at ease, and one clipped at both ends — whether the edge fade reads as
/// "there is more" rather than as a defect is a relationship no assertion states.
@MainActor
final class TabStripRenderTests: XCTestCase {

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
            ("swiss", AppThemeStyles.swissMinimalist),
            ("bauhaus", AppThemeStyles.bauhaus)
        ]

        static let stories: [(name: String, width: CGFloat, tabCount: Int, isDropTarget: Bool)] = [
            ("tabstrip", 480, 3, false),
            ("tabstrip-overflow", 260, 6, false),
            // The wash a strip shows while another pane's chip would land on it — whether it
            // reads as an invitation rather than a selection is a relationship no assertion
            // states.
            ("tabstrip-droptarget", 480, 3, true)
        ]
    }

    // MARK: - Stories

    func testRendersTheTabStripStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                for (storyName, width, tabCount, isDropTarget) in Render.stories {
                    let data = try XCTUnwrap(
                        stripImage(
                            appearance: appearanceID,
                            width: width,
                            tabCount: tabCount,
                            isDropTarget: isDropTarget
                        ),
                        "Failed to render \(storyName) under \(themeName) in \(appearanceName)"
                    )
                    try data.write(
                        to: directory.appendingPathComponent(
                            "\(storyName)-\(themeName)-\(appearanceName).png"
                        )
                    )
                    written += 1
                }
            }
        }

        XCTAssertEqual(
            written,
            Render.themes.count * Render.appearances.count * Render.stories.count
        )
        print("Rendered tab strip storybook to \(directory.path)")
    }

    // MARK: - Helpers

    private static let storyTabs: [(title: String, symbolName: String)] = [
        ("Terminal", "terminal"),
        ("Browser", "globe"),
        ("Review", "plus.forwardslash.minus"),
        ("Overview", "rectangle.grid.1x2"),
        ("Compare", "rectangle.on.rectangle"),
        ("Attachments", "paperclip")
    ]

    private func stripImage(
        appearance name: NSAppearance.Name,
        width: CGFloat,
        tabCount: Int,
        isDropTarget: Bool = false
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let strip = ThemedTabStripView(inkSource: .chrome)
            strip.isDropTarget = isDropTarget
            strip.update(items: Self.storyTabs.prefix(tabCount).enumerated().map {
                index, tab in
                TabStripItem(
                    id: UUID(),
                    title: tab.title,
                    symbolName: tab.symbolName,
                    isActive: index == 0
                )
            })

            let host = ThemedSurfaceView()
            host.frame = NSRect(
                x: 0,
                y: 0,
                width: width,
                height: ThemedTabStripView.bandHeight
            )
            host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            host.appearance = appearance
            host.addSubview(strip)
            let separator = SeparatorView()
            host.addSubview(separator)

            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                strip.topAnchor.constraint(equalTo: host.topAnchor),
                strip.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                separator.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                separator.bottomAnchor.constraint(equalTo: host.bottomAnchor)
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
