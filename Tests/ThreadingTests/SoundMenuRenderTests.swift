import AppKit
import XCTest
@testable import Threading

/// Draws the Sounds submenu and writes it out as an image, light and dark.
///
/// The parentheticals are the part that will silently go wrong. *Inherit (Purr)* against
/// *Inherit* is one word's difference in a list of a dozen similar rows, and which row carries
/// the checkmark is a relationship no assertion states — `SoundMenuTests` pins the strings and
/// the check, and these pin what they look like beside each other.
@MainActor
final class SoundMenuRenderTests: HostedStoreTestCase {

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
    }

    // MARK: - Stories

    /// Three states of the first item and the checkmark: inheriting a sound every voiced event
    /// agrees on, inheriting a mixed answer, and carrying a base coat of its own.
    func testRendersTheSoundSubmenuStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("sound-menu-render-\(UUID().uuidString)", isDirectory: true)
        ))
        defer { _ = store.removeProject(id: project.id) }
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))

        let stories: [(name: String, prepare: @MainActor () -> Void)] = [
            ("inherited", {
                AppSettings.shared.terminalBellSound = .named("Purr.aiff")
                AppSettings.shared.attentionAlertSound = .named("Purr.aiff")
                _ = store.setSoundOverrides(nil, forSessionID: session.id)
            }),
            ("mixed", {
                AppSettings.shared.terminalBellSound = .named("Glass.aiff")
                AppSettings.shared.attentionAlertSound = .named("Submarine.aiff")
                _ = store.setSoundOverrides(nil, forSessionID: session.id)
            }),
            ("chosen", {
                AppSettings.shared.terminalBellSound = .named("Glass.aiff")
                AppSettings.shared.attentionAlertSound = .named("Submarine.aiff")
                _ = store.setSoundOverrides(
                    ["all": SoundChoice.silent.storedValue],
                    forSessionID: session.id
                )
            })
        ]

        var written = 0
        for (storyName, prepare) in stories {
            prepare()
            let entries = try submenuEntries(forSessionID: session.id)
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    menuImage(entries: entries, appearance: appearanceID),
                    "Failed to render the \(storyName) submenu in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "sound-menu-\(storyName)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, stories.count * Render.appearances.count)
        print("Rendered sound submenu storybook to \(directory.path)")
    }

    /// The audition button, in the three states a pointer makes: absent on a row nobody is on,
    /// revealed on the row that is current, and lit under the pointer itself.
    ///
    /// A hover-revealed control is exactly the kind of thing every assertion can pass on while
    /// the picture is wrong — too loud for a row it is not the subject of, sitting where a
    /// checkmark or a countdown would go, or invisible against a highlighted band. So the states
    /// are drawn beside each other and looked at.
    func testRendersTheAuditionButton() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var funk = ThemedMenuItem(title: "Funk", representedValue: SoundChoice.named("Funk.aiff"))
        funk.accessory = SoundPickerMenu.audition(
            try XCTUnwrap(
                NotificationSoundLibrary.available().first,
                "no installed sound to audition"
            )
        )
        let entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "Off")),
            .item(ThemedMenuItem(title: "macOS Alert Sound")),
            .separator,
            .item(ThemedMenuItem(title: "Basso")),
            .item(funk),
            .item(ThemedMenuItem(title: "Glass"))
        ]
        let auditioned = 4

        let stories: [(name: String, highlighted: Int?, hovering: Bool, pressed: Bool)] = [
            ("resting", nil, false, false),
            ("current", auditioned, false, false),
            ("lit", auditioned, true, false),
            ("pressed", auditioned, true, true)
        ]

        var written = 0
        for story in stories {
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    auditionImage(
                        entries: entries,
                        highlighted: story.highlighted,
                        hovering: story.hovering,
                        pressed: story.pressed,
                        entryIndex: auditioned,
                        appearance: appearanceID
                    ),
                    "Failed to render the \(story.name) audition button in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "sound-audition-\(story.name)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        // And under two deliberately different app themes, because the trailing edge is where
        // the historical grammars differ most: Win98 draws a solid selection band this glyph has
        // to be legible against and a hard four-tone frame it must not touch, and Platinum sets
        // its rows in a bitmap face at a different rhythm.
        let previous = AppThemePalette.current
        defer { AppThemePalette.set(previous) }
        for theme in [AppThemeStyles.win98, AppThemeStyles.platinum] {
            AppThemePalette.set(theme)
            let data = try XCTUnwrap(
                auditionImage(
                    entries: entries,
                    highlighted: auditioned,
                    hovering: true,
                    pressed: false,
                    entryIndex: auditioned,
                    appearance: .aqua
                ),
                "Failed to render the audition button under \(theme.id.rawValue)"
            )
            try data.write(
                to: directory.appendingPathComponent(
                    "sound-audition-lit-\(theme.id.rawValue).png"
                )
            )
            written += 1
        }

        XCTAssertEqual(written, stories.count * Render.appearances.count + 2)
        print("Rendered the audition button to \(directory.path)")
    }

    // MARK: - Helpers

    /// The menu surface alone, in the pointer state a render fixture cannot otherwise reach.
    private func auditionImage(
        entries: [ThemedMenuEntry],
        highlighted: Int?,
        hovering: Bool,
        pressed: Bool,
        entryIndex: Int,
        appearance name: NSAppearance.Name
    ) -> Data? {
        let appearance = NSAppearance(named: name)
        let size = NSSize(width: 260, height: 200)

        var data: Data?
        let render: @MainActor () -> Void = {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            let root = ThemedSurfaceView()
            root.translatesAutoresizingMaskIntoConstraints = true
            root.frame = NSRect(origin: .zero, size: size)
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            window.contentView = root

            let surface = ThemedMenuReferenceFixture.make(
                entries: entries,
                size: size,
                highlightedEntryIndex: highlighted
            )
            root.addSubview(surface)
            if hovering || pressed {
                ThemedMenuReferenceFixture.setAccessoryPointerState(
                    in: surface,
                    entryIndex: entryIndex,
                    hovering: hovering,
                    pressed: pressed
                )
            }

            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()

            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }

        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return data
    }

    private func submenuEntries(forSessionID sessionID: SessionID) throws -> [ThemedMenuEntry] {
        let entry = SoundMenuBuilder().sessionSoundEntry(for: sessionID)
        return try XCTUnwrap(entry.item?.submenu, "the Sounds item has no submenu")
    }

    /// The submenu presented as its own panel, in a window that is built and never shown —
    /// `ThemedMenuPresenter` draws inside the window's content view rather than in a second
    /// window, so `cacheDisplay` sees the whole panel without anything reaching the screen.
    private func menuImage(
        entries: [ThemedMenuEntry],
        appearance name: NSAppearance.Name
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 560),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            let root = ThemedSurfaceView()
            root.translatesAutoresizingMaskIntoConstraints = true
            root.frame = NSRect(x: 0, y: 0, width: 320, height: 560)
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            let source = NSView(frame: NSRect(x: 12, y: 528, width: 1, height: 1))
            root.addSubview(source)
            window.contentView = root

            let token = ThemedMenuPresenter.present(
                ThemedMenuPresentation(entries: entries, minimumWidth: SidebarDefaults.menuWidth),
                from: source,
                selectedEntryIndex: nil,
                onChoose: { _, _ in },
                onDismiss: {}
            )
            defer { ThemedMenuPresenter.dismiss(token) }

            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()

            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
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
