import AppKit
import XCTest
@testable import Threading

/// Draws the recovery surface at a pane's width and writes each state out as an image — System
/// light and dark plus two deliberately different stock themes, per the component contract in
/// `docs/THEME_BOUNDARY.md`.
///
/// `RecoveryModeSurfaceTests` pins what each offer does; these pin whether the screen can be read
/// at all. This is the surface somebody meets when the app has already failed them twice, and the
/// things that would make it worse — a mark that disappears into its ground, seven controls of
/// equal weight with no order to them, a sentence that runs under the button answering it — are
/// visible in a picture and in no assertion anyone would have written.
///
/// It is rendered under System too, and not only because System is what recovery wears: Settings
/// is reachable from recovery, so a theme applied there is a theme this screen has to survive.
@MainActor
final class RecoveryModeRenderTests: XCTestCase {

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
            ("swiss", AppThemeStyles.swissMinimalist)
        ]

        /// The width the window opens near, and the pane at its floor.
        static let paneWidth: CGFloat = 760
        static let narrowPaneWidth: CGFloat = 420
        static let paneHeight: CGFloat = 620
    }

    private let inertActions = RecoveryModeActions(
        tryNormalLaunchOnce: {},
        continueInRecoveryMode: {},
        toggleExtensionsForNextLaunch: {},
        resetWindowLayout: {},
        createSupportReport: {},
        moveAppDataAside: {},
        revealCrashReport: {}
    )

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Stories

    /// The ordinary case: two crashes in a row, a checkpoint to name, and a report to reveal.
    func testRendersTheCrashLoopSurface() throws {
        try writeStorybook(named: "recovery-crash-loop") { [inertActions] in
            RecoveryModeSurface.make(
                reason: .crashLoop,
                checkpoint: .themeRestored,
                hasCrashReport: true,
                extensionsDisabledNextLaunch: false,
                actions: inertActions
            )
        }
    }

    /// A kill, a power cut, or a report the system never filed, on a launch that recorded no
    /// checkpoint at all. Both facts go missing at once, which is the state the heading is most
    /// likely to be wrong in — a gap where the fact line was, or a stranded button.
    func testRendersTheSurfaceWithNothingToPointAt() throws {
        try writeStorybook(named: "recovery-no-evidence") { [inertActions] in
            RecoveryModeSurface.make(
                reason: .crashLoop,
                checkpoint: nil,
                hasCrashReport: false,
                extensionsDisabledNextLaunch: false,
                actions: inertActions
            )
        }
    }

    /// The harder verdict: the recovery launch died too, so the leading offer is demoted and the
    /// troubleshooting group is where the answer is. The pair of images is how "demoted" is
    /// checked for actually reading that way rather than merely being a different enum case.
    func testRendersTheSurfaceAfterARecoveryLaunchAlsoFailed() throws {
        try writeStorybook(named: "recovery-escalated") { [inertActions] in
            RecoveryModeSurface.make(
                reason: .recoveryLaunchFailed,
                checkpoint: .mainWindowConstructed,
                hasCrashReport: true,
                extensionsDisabledNextLaunch: false,
                actions: inertActions
            )
        }
    }

    /// Armed. The one control whose title is a state rather than a command, and the longest
    /// string on the screen — so this is also where the group's row layout is checked.
    func testRendersTheSurfaceWithTheExtensionsOneShotArmed() throws {
        try writeStorybook(named: "recovery-extensions-armed") { [inertActions] in
            RecoveryModeSurface.make(
                reason: .optionKeyHeld,
                checkpoint: .stable,
                hasCrashReport: false,
                extensionsDisabledNextLaunch: true,
                actions: inertActions
            )
        }
    }

    /// The pane at its floor, where every sentence has to wrap and no control may be pushed off
    /// the edge that answers it.
    func testRendersTheSurfaceInANarrowPane() throws {
        try writeStorybook(
            named: "recovery-narrow",
            width: Render.narrowPaneWidth
        ) { [inertActions] in
            RecoveryModeSurface.make(
                reason: .crashLoop,
                checkpoint: .persistenceOpened,
                hasCrashReport: true,
                extensionsDisabledNextLaunch: false,
                actions: inertActions
            )
        }
    }

    // MARK: - Helpers

    private func writeStorybook(
        named name: String,
        width: CGFloat = Render.paneWidth,
        build: @escaping @MainActor () -> RecoveryModeView
    ) throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    surfaceImage(appearance: appearanceID, width: width, build: build),
                    "Failed to render \(name) under \(themeName) in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "\(name)-\(themeName)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count)
        print("Rendered \(name) storybook to \(directory.path)")
    }

    /// The surface in the position the pane gives it: filling the content area, on the pane's own
    /// chrome ground, which is what `applyPaneBackground(.chrome)` puts behind it in the app.
    private func surfaceImage(
        appearance name: NSAppearance.Name,
        width: CGFloat,
        build: @escaping @MainActor () -> RecoveryModeView
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let surface = build()

            let host = ThemedSurfaceView()
            host.frame = NSRect(x: 0, y: 0, width: width, height: Render.paneHeight)
            host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            // Without this the offscreen draw comes out blank: `cacheDisplay` resolves dynamic
            // colours against the host's appearance, and a host with none has nothing to resolve.
            host.appearance = appearance
            host.addSubview(surface)

            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: width),
                host.heightAnchor.constraint(equalToConstant: Render.paneHeight),
                surface.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                surface.topAnchor.constraint(equalTo: host.topAnchor),
                surface.bottomAnchor.constraint(equalTo: host.bottomAnchor)
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
