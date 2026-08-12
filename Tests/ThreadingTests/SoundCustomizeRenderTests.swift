import AppKit
import XCTest
@testable import Threading

/// Draws the Customize sheet and writes it out as an image, light and dark.
///
/// The sheet is eleven near-identical rows whose only difference is a word inside a
/// parenthetical, which is exactly the kind of screen that can be wrong in every row while every
/// assertion passes. `SoundCustomizeSheetTests` pins what each row says; these pin what the
/// eleven look like beside one another — whether the two group captions read as groups, whether
/// the footnote lands under the events it is about, and whether a row inheriting silence is
/// distinguishable from one that was switched off.
///
/// The fixture window is built and never shown, per `CLAUDE.md`: an unshown window still lays
/// out and still draws through `cacheDisplay`.
@MainActor
final class SoundCustomizeRenderTests: XCTestCase {

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
    }

    /// The app scope's keys, snapshotted and put back — the bundle is hosted in the app, so
    /// these are the developer's own defaults.
    private enum Key {
        static let all = ["silencesAllSounds", "terminalBellSound", "attentionAlertSound",
                          "soundEventChoices"]
    }

    override func setUp() {
        super.setUp()
        let previous = Key.all.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        addTeardownBlock {
            for (key, value) in previous {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        AppSettings.shared.silencesAllSounds = false
        AppSettings.shared.resetSoundChoices()
    }

    // MARK: - Stories

    /// Three sheets: a chat inheriting everything from an app that has chosen one sound, the
    /// same chat carrying exceptions of its own, and the app scope — where the word changes to
    /// *Default* and the two kind rows lose their outermost item.
    func testRendersTheCustomizeSheetStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("sound-sheet-render-\(UUID().uuidString)", isDirectory: true)
        ))
        defer { _ = store.removeProject(id: project.id) }
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))

        let stories: [(name: String, prepare: @MainActor () -> SoundScope)] = [
            ("inherited", {
                AppSettings.shared.terminalBellSound = .named("Basso.aiff")
                AppSettings.shared.attentionAlertSound = .named("Glass.aiff")
                _ = store.setSoundOverrides(nil, forSessionID: session.id)
                return .session(session.id)
            }),
            ("customized", {
                AppSettings.shared.terminalBellSound = .named("Basso.aiff")
                AppSettings.shared.attentionAlertSound = .named("Glass.aiff")
                _ = store.setSoundOverrides(
                    [
                        "all": SoundChoice.named("Submarine.aiff").storedValue,
                        "bell.launch": SoundChoice.silent.storedValue,
                        "alert.unread": SoundChoice.named("Purr.aiff").storedValue
                    ],
                    forSessionID: session.id
                )
                return .session(session.id)
            }),
            ("app", {
                AppSettings.shared.terminalBellSound = .named("Basso.aiff")
                AppSettings.shared.attentionAlertSound = .named("Glass.aiff")
                return .app
            })
        ]

        var written = 0
        for (storyName, prepare) in stories {
            let scope = prepare()
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    sheetImage(scope: scope, appearance: appearanceID),
                    "Failed to render the \(storyName) sheet in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "sound-customize-\(storyName)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, stories.count * Render.appearances.count)
        print("Rendered sound customize storybook to \(directory.path)")
    }

    // MARK: - Helpers

    private func sheetImage(scope: SoundScope, appearance name: NSAppearance.Name) -> Data? {
        guard let appearance = NSAppearance(named: name) else { return nil }

        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            MainActor.assumeIsolated {
                let controller = SoundCustomizeViewController(scope: scope)
                let root = controller.view
                root.appearance = appearance

                // Built, never ordered on screen: `applicationShouldTerminateAfterLastWindowClosed`
                // makes a shown-then-released fixture window exit the host inside a later,
                // unrelated test. An unshown window still lays out and still draws.
                let window = NSWindow(
                    contentRect: root.bounds,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.appearance = appearance
                window.contentView = root

                AppThemeRefresh.repaint(root)
                root.layoutSubtreeIfNeeded()

                guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
                root.cacheDisplay(in: root.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
        }
        return data
    }
}
