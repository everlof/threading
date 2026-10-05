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
final class ToastRenderTests: HostedStoreTestCase {

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
        ///
        /// The fifth is that burst with the deck opened. It is the one state where the deck has
        /// to hold *words*: whether three stacked strips in a 240-point column read as a queue or
        /// as a wall over the list, whether a truncated message still names its session, and
        /// whether a way back set in a theme's own face still fits the strip it is standing in.
        /// The cleanup story holds an in-flight operation at half progress: the determinate bar
        /// must remain legible on every material without being confused for the dwell rail. The
        /// update story carries three aligned version rows and its update action at the same real
        /// sidebar width, which is the longest shape the daily five-tool check ordinarily produces.
        /// The long report must stay a compact preview when an automation supplies paragraphs.
        enum Story: String, CaseIterable {
            case running
            case dormant
            case agent
            case queued
            case opened
            case cleanup
            case agentUpdates = "agent-updates"
            case longReport = "long-report"
        }

        /// Automation summaries are provider text, and can be entire reports rather than the
        /// one-sentence archive reason. Preserve paragraphs and paths from that input shape.
        static let longReport = String(repeating: """
            The device failed while compiling its graphics program. The latest event points to
            the startup capability check in Sources/Renderer/GraphicsSupport.swift. The fix is
            committed; the next step is to verify the release on the affected device.


            """, count: 24)

        /// What the cards in an opened deck stand for: three different sessions, one of them
        /// named at a length no 240-point strip can hold, because a card that cannot name its
        /// receipt is a card nobody can act on.
        static let waitingSessions = [
            "Rewrite the rollout discovery so Codex reports its own id",
            "Parser",
            "Empty state"
        ]

        /// A column dragged well past the width the app ever opens the sidebar at.
        ///
        /// The divider has no maximum (`SidebarDefaults.maxWidth` is only how wide the app opens
        /// the column *itself*), so this is a shape a user can put the receipt in and the
        /// storybook could not previously show: at 240 the band fills, and every fault in how it
        /// meets a wider column is invisible there.
        static let draggedColumnWidth: CGFloat = 460
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

    /// The same receipts in a column the user has dragged wide, which is the one relationship the
    /// 240-point storybook cannot show: whether a band in a column with more room than it needs
    /// still belongs to the column, or reads as a card stranded at one edge of it.
    func testRendersTheArchiveToastInADraggedColumn() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }
        AppThemePalette.set(.system)

        for (appearanceName, appearanceID) in Render.appearances {
            for story in [Render.Story.running, .agent] {
                let data = try XCTUnwrap(
                    toastImage(
                        appearance: appearanceID,
                        story: story,
                        width: Render.draggedColumnWidth
                    ),
                    "Failed to render the \(story.rawValue) toast in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "toast-wide-\(story.rawValue)-\(appearanceName).png"
                    )
                )
            }
        }

        print("Rendered the dragged-column receipts to \(directory.path)")
    }

    func testRendersLongReportInTheMainWindowSidebar() throws {
        let previousTheme = AppThemeLibrary.current
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        Design.Motion.reduceMotionOverrideForTesting = true
        defer {
            AppThemeLibrary.apply(previousTheme)
            Design.Motion.reduceMotionOverrideForTesting = previousMotion
        }
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_100, height: 760))
        let content = try XCTUnwrap(window.contentView)
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceID))
                content.appearance = appearance
                controller.sidebarViewController.presentToast(ToastRequest(
                    message: "Automation completed",
                    detail: Render.longReport,
                    persistsUntilDismissed: true
                ))
                AppThemeRefresh.repaint(content)
                content.layoutSubtreeIfNeeded()
                let sidebar = controller.sidebarViewController.view
                let toast = try XCTUnwrap(descendants(in: sidebar).compactMap { $0 as? ToastView }.first)
                print("Long report toast \(themeName)-\(appearanceName): \(toast.frame.height)pt")
                XCTAssertLessThan(toast.frame.height, 150, "A report must remain a sidebar receipt")
                XCTAssertTrue(sidebar.bounds.contains(toast.convert(toast.bounds, to: sidebar)))
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                appearance.performAsCurrentDrawingAppearance {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                }
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("toast-shell-long-report-\(themeName)-\(appearanceName).png")
                )
            }
        }
        _ = controller.sidebarViewController.takePresentedToastsForTransfer()
        XCTAssertFalse(window.isVisible, "Fast evidence must not order the main window on screen")
    }

    // MARK: - Helpers

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    /// The sidebar's standing destination, built the way `ProjectSidebarViewController` builds
    /// it: borderless, so its ink is its glyph and the footer aligns it by that.
    @MainActor
    private static func settingsButton() -> ThemedButton {
        let button = ThemedButton()
        button.title = L10n.string("Settings")
        button.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: L10n.string("Settings")
        )?.withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
        button.isBordered = false
        button.applyFont(.controlRegular)
        return button
    }

    /// The receipts as the app builds them, rather than a second copy of their wording here that
    /// could drift from the one that ships.
    @MainActor
    private func request(for story: Render.Story, session: AgentSession) -> ToastRequest {
        switch story {
        case .running, .queued, .opened:
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
        case .cleanup:
            return StorageCleanupToast.request(for: ArtifactCleanupProgress(
                phase: .removing,
                totalCount: 4,
                completedCount: 2,
                removedCount: 2,
                refusedCount: 0,
                failedCount: 0,
                reclaimedBytes: 8_000_000_000,
                currentName: "DerivedData",
                persistenceRecovery: .notNeeded
            ))
        case .agentUpdates:
            return AgentCLIUpdateToast.request(for: [
                AgentCLIUpdate(
                    id: "claude",
                    displayName: "Claude Code",
                    executable: "claude",
                    versionArguments: ["--version"],
                    comparison: .semantic,
                    installedVersion: "2.1.220",
                    latestVersion: "2.1.237",
                    updateArguments: ["update"]
                ),
                AgentCLIUpdate(
                    id: "codex",
                    displayName: "Codex",
                    executable: "codex",
                    versionArguments: ["--version"],
                    comparison: .semantic,
                    installedVersion: "0.145.0",
                    latestVersion: "0.148.0",
                    updateArguments: ["update"]
                ),
                AgentCLIUpdate(
                    id: "opencode",
                    displayName: "OpenCode",
                    executable: "opencode",
                    versionArguments: ["--version"],
                    comparison: .semantic,
                    installedVersion: "1.17.0",
                    latestVersion: "1.18.19",
                    updateArguments: ["upgrade"]
                )
            ], runUpdates: { _ in })
        case .longReport:
            return ToastRequest(message: "Automation completed", detail: Render.longReport)
        }
    }

    private func toastImage(
        appearance name: NSAppearance.Name,
        story: Render.Story,
        width: CGFloat = SidebarDefaults.defaultWidth
    ) -> Data? {
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
            host.frame = NSRect(x: 0, y: 0, width: width, height: 280)
            // The sidebar's ground, so the band is judged against the surface it floats on
            // rather than against a blank one.
            host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            host.appearance = appearance

            // The footer carries the sidebar's own Settings control rather than being an empty
            // band, because the edge the band is judged against is that control's ink: a card
            // floating a couple of points inside the gear beneath it is exactly the kind of miss
            // no assertion was going to be written for.
            let footer = PaneFooterView(leading: [Self.settingsButton()], margin: .paneEdge)
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
            // them is thrown away and each waits behind the band as a card edge. The opened deck
            // is drawn with the queue full, since what the fan has to survive is its own height:
            // three strips of words standing over a band in a 240-point column.
            switch story {
            case .queued:
                for _ in 0..<ToastDefaults.stackDepth {
                    presenter.present(self.request(for: story, session: session))
                }
            case .opened:
                // Different sessions, because a deck of one repeated line says nothing about
                // whether a card names the thing it stands for.
                for title in Render.waitingSessions {
                    presenter.present(
                        self.request(
                            for: story,
                            session: AgentSession(kind: .claude, title: title)
                        )
                    )
                }
                // Unanimated: the fan is staggered, so a picture taken the moment it is asked
                // for would be a deck two frames into opening.
                presenter.openDeck(true, animated: false)
            default:
                break
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
