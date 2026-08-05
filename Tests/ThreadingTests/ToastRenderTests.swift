import AppKit
import XCTest
@testable import Threading

/// Draws the archive receipt where it actually appears — above the sidebar's footer, at the
/// sidebar's width, on the sidebar's own ground — and writes each state out as an image: System
/// light and dark plus three deliberately different stock themes, per the component contract
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
            ("swiss", AppThemeStyles.swissMinimalist),
            ("claymorphism", AppThemeStyles.claymorphism),
            ("win98", AppThemeStyles.win98)
        ]

        /// The three receipts the archive can produce: a running session, whose agent stopped; a
        /// dormant one, which had nothing to interrupt; and the one an agent files away itself,
        /// which names the agent and carries its reason. The third is deliberately the longest —
        /// a three-sentence detail under a wrapped message is where a 240-point column either
        /// still reads as a receipt or turns into a paragraph.
        ///
        /// The fourth is the same running receipt with a burst behind it, because what the stack
        /// has to get right is only visible in a picture: whether two 4-point slivers above a
        /// card read as more receipts waiting or as a drawing error, and whether a style with
        /// square corners and a heavy rule (Swiss) still separates the three edges at all.
        enum Story: String, CaseIterable {
            case running
            case dormant
            case agent
            case queued
        }
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
                for story in Render.Story.allCases {
                    let data = try XCTUnwrap(
                        toastImage(appearance: appearanceID, story: story),
                        """
                        Failed to render the \(story.rawValue) toast under \(themeName) \
                        in \(appearanceName)
                        """
                    )
                    try data.write(
                        to: directory.appendingPathComponent(
                            "toast-\(story.rawValue)-\(themeName)-\(appearanceName).png"
                        )
                    )
                    written += 1
                }
            }
        }

        XCTAssertEqual(
            written,
            Render.themes.count * Render.appearances.count * Render.Story.allCases.count
        )
        print("Rendered archive toast storybook to \(directory.path)")
    }

    // MARK: - Helpers

    /// The receipts as the app builds them, rather than a second copy of their wording here that
    /// could drift from the one that ships.
    @MainActor
    private func request(for story: Render.Story, session: AgentSession) -> ToastRequest {
        switch story {
        case .running, .queued:
            return SessionCoordinator.archiveToast(for: session, wasRunning: true, undo: {})
        case .dormant:
            return SessionCoordinator.archiveToast(for: session, wasRunning: false, undo: {})
        case .agent:
            return SessionCoordinator.agentArchiveToast(
                for: session,
                reason: "committed and pushed the parser fix",
                wasRunning: true,
                undo: {}
            )
        }
    }

    private func toastImage(appearance name: NSAppearance.Name, story: Render.Story) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let session = AgentSession(kind: .claude, title: "Refactor the parser")
            let request = self.request(for: story, session: session)

            let host = ThemedSurfaceView()
            // Tall enough for the tallest band any stock theme draws: a mono-faced style wraps
            // the message onto a second line, the agent's receipt carries three sentences of
            // detail under it, and a fixture cropping the top of the receipt reports a layout
            // fault the component does not have.
            host.frame = NSRect(
                x: 0,
                y: 0,
                width: SidebarDefaults.defaultWidth,
                height: 280
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
            defer { presenter.invalidate() }
            presenter.present(request)

            // A burst, sent the way the sidebar sends one: each carries a way back, so none of
            // them is thrown away and each waits behind the band as a card edge.
            if story == .queued {
                for _ in 0..<ToastDefaults.stackDepth {
                    presenter.present(self.request(for: story, session: session))
                }
            }

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
