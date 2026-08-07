import AppKit
import XCTest
@testable import Threading

/// Draws the software-update sheets as they actually assemble — through
/// `UpdatePresenter`'s own request builders and `ConfirmationAlert.makeAlert` — and writes
/// each stage out as an image, light and dark, under System plus two deliberately different
/// stock themes. Win98 is one of them on purpose: it is the theme whose `ThemedProgressBar`
/// switches to segmented classic drawing, which no assertion would think to look at.
///
/// What these have to get right is relational: whether a Markdown release-notes column reads
/// as content or as a second dialog, whether a 3-point bar under a heading reads as progress
/// or as a divider, and whether Install carries the accent while Remind Me Later stays quiet.
@MainActor
final class UpdateSheetRenderTests: XCTestCase {

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
            ("swiss", AppThemeStyles.swissMinimalist),
            ("win98", AppThemeStyles.win98)
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
