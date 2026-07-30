import AppKit
import XCTest
@testable import Threading

/// Draws the archive receipt where it actually appears — above the sidebar's footer, at the
/// sidebar's width, on the sidebar's own ground — and writes each state out as an image: System
/// light and dark plus the two deliberately different stock themes, per the component contract
/// in `docs/THEME_BOUNDARY.md`.
///
/// It exists because what this band has to get right is a *relationship* no assertion states:
/// whether a card floating over a list still reads as floating, whether the words clear the
/// button under them, and whether a two-line detail in a 240-point column looks like a receipt
/// or like a paragraph. `ToastTests` pins the behaviour; these pin what the behaviour looks
/// like.
@MainActor
final class ToastRenderTests: XCTestCase {

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

        /// The two receipts the archive can produce: a running session, whose agent stopped, and
        /// a dormant one, which had nothing to interrupt.
        static let stories: [(name: String, wasRunning: Bool)] = [
            ("running", true),
            ("dormant", false)
        ]
    }

    // MARK: - Stories

    func testRendersTheArchiveToastStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                for (storyName, wasRunning) in Render.stories {
                    let data = try XCTUnwrap(
                        toastImage(appearance: appearanceID, wasRunning: wasRunning),
                        "Failed to render the \(storyName) toast under \(themeName) in \(appearanceName)"
                    )
                    try data.write(
                        to: directory.appendingPathComponent(
                            "toast-\(storyName)-\(themeName)-\(appearanceName).png"
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
        print("Rendered archive toast storybook to \(directory.path)")
    }

    // MARK: - Helpers

    private func toastImage(appearance name: NSAppearance.Name, wasRunning: Bool) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let session = AgentSession(kind: .claude, title: "Refactor the parser")
            let request = SessionCoordinator.archiveToast(
                for: session,
                wasRunning: wasRunning,
                undo: {}
            )

            let host = ThemedSurfaceView()
            // Tall enough for the widest band any stock theme draws: a mono-faced style wraps
            // the message onto a second line, and a fixture cropping the top of the receipt
            // reports a layout fault the component does not have.
            host.frame = NSRect(
                x: 0,
                y: 0,
                width: SidebarDefaults.defaultWidth,
                height: 210
            )
            // The sidebar's ground, so the band is judged against the surface it floats on
            // rather than against a blank one.
            host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            host.appearance = appearance

            let footer = PaneFooterView()
            host.addSubview(footer)
            NSLayoutConstraint.activate([
                footer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                footer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                footer.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])

            let presenter = ToastPresenter(host: host, above: footer.topAnchor)
            presenter.present(request)

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
