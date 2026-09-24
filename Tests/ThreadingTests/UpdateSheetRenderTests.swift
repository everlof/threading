import AppKit
import XCTest
@testable import Threading

/// Draws the software-update sheets as they actually assemble — through
/// `UpdatePresenter`'s own request builders and `ConfirmationAlert.makeAlert` — and writes
/// each stage out as an image, light and dark, under System plus three deliberately different
/// stock themes. Win98 exercises segmented progress and Neo Brutalism covers the square alert
/// silhouette that native macOS sheet attachment would otherwise round.
///
/// What these have to get right is relational: whether a Markdown release-notes column reads
/// as content or as a second dialog, whether a 3-point bar under a heading reads as progress
/// or as a divider, and whether Install carries the accent while Remind Me Later stays quiet.
@MainActor
final class UpdateSheetRenderTests: XCTestCase {

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
            ("swiss", AppThemeStyles.swissMinimalist),
            ("win98", AppThemeStyles.win98),
            ("neo-brutalism", AppThemeStyles.neoBrutalism)
        ]

        enum Story: String, CaseIterable {
            /// An ordinary update with embedded Markdown notes — the common case.
            case found
            /// A critical update: no Skip, and the sheet must still read calm.
            case critical
            /// Mid-download, bar at 40%.
            case downloading
            /// The last question before the app quits.
            case ready
            /// The final narration-only sheet, including the reported corner failure.
            case installing
        }

        static let notes = """
        ## What's new in 1.2.0

        - The sidebar keeps its selection across a relaunch.
        - `claude --resume` sessions rejoin their original account.
        - Fixed a crash when a theme was deleted while its editor was open.

        ## Known issues

        Emoji in terminal titles still render without their background plate.
        """
    }

    // MARK: - Stories

    func testRendersTheUpdateSheetStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                for story in Render.Story.allCases {
                    let data = try XCTUnwrap(
                        sheetImage(appearance: appearanceID, story: story),
                        """
                        Failed to render the \(story.rawValue) update sheet under \
                        \(themeName) in \(appearanceName)
                        """
                    )
                    try data.write(
                        to: directory.appendingPathComponent(
                            "update-\(story.rawValue)-\(themeName)-\(appearanceName).png"
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
    }

    /// The behavioural half the pictures rest on: each story's alert is the one the flow
    /// builds, so the render cannot quietly drift onto a hand-rolled fixture.
    func testTheStoriesBuildTheAlertsTheFlowShips() {
        let found = alert(for: .found)
        XCTAssertEqual(
            found.buttons.map(\.title),
            ["Install Update", "Skip This Version", "Remind Me Later"]
        )
        XCTAssertNotNil(found.accessoryView)

        let critical = alert(for: .critical)
        XCTAssertEqual(critical.buttons.map(\.title), ["Install Update", "Remind Me Later"])

        let ready = alert(for: .ready)
        XCTAssertEqual(ready.buttons.map(\.title), ["Install and Relaunch", "Later"])

        let downloading = alert(for: .downloading)
        XCTAssertEqual(downloading.buttons.map(\.title), ["Cancel"])

        let installing = alert(for: .installing)
        XCTAssertEqual(installing.buttons.map(\.title), ["Hide"])
        XCTAssertEqual(installing.messageText, L10n.string("Installing Update…"))
    }

    /// The content-only storybook cannot prove the real window's silhouette. A square theme
    /// must remain square after attachment, including the first pixel of every black edge.
    func testRealInstallingSheetKeepsSquareThemedBorder() throws {
        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }
        AppThemePalette.set(AppThemeStyles.neoBrutalism)

        let parent = try visibleSheetParent()
        let alert = UpdatePresenter.installingAlert()
        alert.beginSheetModal(for: parent)
        defer { alert.dismiss(); parent.orderOut(nil) }

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let panel = try XCTUnwrap(alert.presentedWindow)
        XCTAssertTrue(panel.hasShadow)
        XCTAssertTrue(panel.parent === parent)
        XCTAssertNil(panel.sheetParent)
        XCTAssertTrue(parent.ignoresMouseEvents)
        let rep = try capture(panel)
        for y in [0, rep.pixelsHigh - 1] {
            for x in [0, rep.pixelsWide - 1] {
                let ink = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(ink.alphaComponent, 0.98)
                XCTAssertLessThan(
                    max(ink.redComponent, ink.greenComponent, ink.blueComponent),
                    0.25,
                    "the square themed border is missing at (\(x), \(y))"
                )
            }
        }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(
            at: Render.directory, withIntermediateDirectories: true
        )
        try data.write(to: Render.directory.appendingPathComponent("update-installing-panel-neo.png"))
        alert.dismiss()
        XCTAssertFalse(parent.ignoresMouseEvents)
    }

    /// A classic requester keeps its caption and depth button at the square title band's ends.
    func testRealClassicSheetKeepsSquareTitleHardware() throws {
        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }
        AppThemePalette.set(AppThemeStyles.win98)

        let parent = try visibleSheetParent()
        let alert = UpdatePresenter.installingAlert()
        alert.beginSheetModal(for: parent)
        defer { alert.dismiss(); parent.orderOut(nil) }

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let panel = try XCTUnwrap(alert.presentedWindow)
        let content = try XCTUnwrap(panel.contentView)
        let depth = try XCTUnwrap(depthButton(in: content))
        let depthFrame = depth.convert(depth.bounds, to: content)
        XCTAssertGreaterThan(depthFrame.maxX, content.bounds.maxX - 20)

        let rep = try capture(panel)
        let titleInkX = (3..<18).flatMap { y in
            (0..<(rep.pixelsWide / 2)).compactMap { x -> Int? in
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      min(color.redComponent, color.greenComponent, color.blueComponent) > 0.8,
                      color.alphaComponent > 0.9 else { return nil }
                return x
            }
        }.min()
        XCTAssertLessThan(try XCTUnwrap(titleInkX), 20)

        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(
            at: Render.directory, withIntermediateDirectories: true
        )
        try data.write(to: Render.directory.appendingPathComponent("update-installing-panel-win98.png"))
    }

    private func visibleSheetParent() throws -> NSWindow {
        // WindowServer returns transparent pixels for a child panel whose host application
        // never came to the front. A command-line XCTest run does not activate its app host.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            let deadline = Date().addingTimeInterval(2)
            while !NSApp.isActive, Date() < deadline {
                RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
            }
        }
        try XCTSkipUnless(
            NSApp.isActive,
            "the test host could not become active; its attached sheet is not observable in this run"
        )

        let parent = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.backgroundColor = NSColor(calibratedWhite: 0.8, alpha: 1)
        parent.makeKeyAndOrderFront(nil)
        return parent
    }

    private func capture(_ panel: NSWindow) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
            [.boundsIgnoreFraming, .nominalResolution]
        ))
        let rep = NSBitmapImageRep(cgImage: image)
        XCTAssertGreaterThan(
            rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0,
            0.9,
            "the sheet capture was blank"
        )
        return rep
    }

    private func depthButton(in view: NSView) -> WindowChromeButton? {
        for child in view.subviews {
            if let button = child as? WindowChromeButton, button.role == .depth { return button }
            if let button = depthButton(in: child) { return button }
        }
        return nil
    }

    // MARK: - Fixtures

    private func versionInfo(critical: Bool) -> UpdateVersionInfo {
        UpdateVersionInfo(
            version: "1.2.0",
            isInformational: false,
            isCritical: critical,
            infoURL: nil,
            releaseNotes: .embedded(Render.notes)
        )
    }

    private func alert(for story: Render.Story) -> ThemedAlert {
        switch story {
        case .found:
            return ConfirmationAlert.makeAlert(
                UpdatePresenter.foundRequest(versionInfo(critical: false)).request
            )
        case .critical:
            return ConfirmationAlert.makeAlert(
                UpdatePresenter.foundRequest(versionInfo(critical: true)).request
            )
        case .ready:
            return ConfirmationAlert.makeAlert(UpdatePresenter.readyRequest())
        case .downloading:
            // The presenter's downloading sheet, assembled the same way `showDownloadStarted`
            // assembles it: narration plus a cancel, with the shared progress accessory.
            let accessory = UpdateProgressAccessoryView(width: 360)
            var progress = UpdateDownloadProgress()
            progress.expect(100)
            progress.receive(40)
            accessory.show(fraction: progress.fraction)

            let alert = ThemedAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.string("Downloading Update…")
            alert.accessoryView = accessory
            alert.addButton(withTitle: L10n.string("Cancel"))
            return alert
        case .installing:
            return UpdatePresenter.installingAlert()
        }
    }

    private func sheetImage(appearance name: NSAppearance.Name, story: Render.Story) -> Data? {
        guard let appearance = NSAppearance(named: name) else { return nil }

        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            MainActor.assumeIsolated {
                let content = alert(for: story).makeContentView()
                content.appearance = appearance
                content.layoutSubtreeIfNeeded()
                content.frame = NSRect(origin: .zero, size: content.fittingSize)

                AppThemeRefresh.repaint(content)
                content.layoutSubtreeIfNeeded()

                guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                    return
                }
                content.cacheDisplay(in: content.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
        }
        return data
    }
}
