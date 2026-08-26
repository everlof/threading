import AppKit
import XCTest
@testable import Threading
@testable import ThreadingExtensionKit

/// Draws the scrubber and the transport in every state that matters and writes each one out, per
/// the component contract in `docs/THEME_BOUNDARY.md`.
///
/// Two themes, because the scrubber takes its corner from the theme's material and the two cases
/// are geometrically different controls: Neo Brutalism's square track puts a hard-cornered knob on
/// a hard-cornered rail, Cyberpunk's rounded one puts a disc on a stadium.
@MainActor
final class MediaTransportRenderTests: XCTestCase {

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
            ("neo-brutalism", AppThemeStyles.neoBrutalism),
            ("cyberpunk", AppThemeStyles.cyberpunk)
        ]

        static let padding: CGFloat = 12
        static let width: CGFloat = 320
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - The elapsed run is drawn in the accent

    /// The whole reason a scrubber is not a progress bar with a pointer: the run behind the knob
    /// has to read as *where you are*. A track drawn in one neutral from end to end says nothing,
    /// and it is the state a control that forgot to fill would silently ship in.
    func testTheElapsedRunCarriesTheAccentAndTheRestDoesNot() throws {
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            let render = try XCTUnwrap(scrubberRender(value: 0.5, focused: false, appearance: .aqua))

            let track = render.trackRect
            let elapsed = try XCTUnwrap(
                render.color(at: NSPoint(x: track.minX + track.width * 0.2, y: track.midY)),
                "no pixel on the elapsed run"
            )
            let remaining = try XCTUnwrap(
                render.color(at: NSPoint(x: track.minX + track.width * 0.85, y: track.midY))
            )

            XCTAssertGreaterThan(
                distance(elapsed, remaining), 0.05,
                "\(themeName) drew one flat rail with no position on it"
            )
            assertCarriesAccentHue(elapsed, themeName: themeName, where_: "the elapsed run")
        }
    }

    /// Focus is drawn outside the knob, in margin the control reserves for it — the lesson
    /// `ThemedToggle` paid for. A ring stroked into room that was not reserved is clipped to
    /// `bounds` and comes back at partial weight or not at all.
    func testTheFocusRingDrawsOutsideTheKnob() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        // At the start of the range, so the ring is the only accent in the picture. Sampled at
        // the midpoint of the range instead, the ring's leading edge lands on the elapsed run —
        // also the theme's accent — and the assertion passes on a control that drew no ring at
        // all.
        let resting = try XCTUnwrap(scrubberRender(value: 0, focused: false, appearance: .aqua))
        let focused = try XCTUnwrap(scrubberRender(value: 0, focused: true, appearance: .aqua))

        let reach = ThemedScrubber.Layout.focusGap + Design.Accessibility.focusRingWidth / 2
        let ring = focused.knobRect.insetBy(dx: -reach, dy: -reach)
        let edges: [(String, NSPoint)] = [
            ("leading", NSPoint(x: ring.minX, y: ring.midY)),
            ("trailing", NSPoint(x: ring.maxX, y: ring.midY)),
            ("bottom", NSPoint(x: ring.midX, y: ring.minY)),
            ("top", NSPoint(x: ring.midX, y: ring.maxY))
        ]
        for (edge, point) in edges {
            let inked = try XCTUnwrap(focused.color(at: point), "no pixel at \(edge)")
            let bare = try XCTUnwrap(resting.color(at: point))
            XCTAssertGreaterThan(
                distance(inked, bare), 0.05,
                "the ring never reached its \(edge) margin"
            )
        }

        // The knob's own middle is untouched: the ring is around it, not on it.
        let centre = NSPoint(x: focused.knobRect.midX, y: focused.knobRect.midY)
        let restingKnob = try XCTUnwrap(resting.color(at: centre))
        let focusedKnob = try XCTUnwrap(focused.color(at: centre))
        XCTAssertLessThan(
            distance(restingKnob, focusedKnob), 0.05,
            "the focus ring reached into the knob"
        )
    }

    // MARK: - The player

    /// The whole player — canvas, transport and reading — with a real document in it, light and
    /// dark. Several frames, because a still of a player says nothing about whether it plays: the
    /// point of the picture is that the canvas differs across the timeline while the chrome
    /// around it does not.
    func testRendersThePlayerStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Under authored themes, like every other story here. The System theme's surface roles
        // are *dynamic* colours, and an offscreen host that applies one freezes the light variant
        // inside a dark pass — a fixture trap rather than anything the player decides, but one
        // that produces a convincing-looking picture with its controls invisible.
        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                for (stateName, progress) in [("start", 0.0), ("midway", 0.5), ("end", 0.99)] {
                    let rep = try XCTUnwrap(
                        playerRender(atProgress: progress, appearance: appearanceID),
                        "Failed to render the player at \(stateName)"
                    )
                    try write(
                        rep,
                        to: directory,
                        named: "player-\(stateName)-\(themeName)-\(appearanceName)"
                    )
                    written += 1
                }
            }
        }
        XCTAssertEqual(written, Render.themes.count * Render.appearances.count * 3)
        print("Rendered player storybook to \(directory.path)")
    }

    private func playerRender(
        atProgress progress: Double,
        appearance name: NSAppearance.Name
    ) -> NSBitmapImageRep? {
        var result: NSBitmapImageRep?
        let render: @MainActor () -> Void = {
            let player = MediaDocumentPlayerView(loader: { _ in
                .success(LottieFixture.spinningDot())
            })
            player.windowVisibility = { _ in true }

            // Tall enough for the canvas *and* the transport under it. The canvas takes the
            // document's aspect ratio from the width it is given, so a square host swallows the
            // whole player and the picture silently loses the controls it exists to show.
            // `ThemedSurfaceView` rather than `applySurface` on a plain view: under the System
            // theme the surface roles are *dynamic* colours, and `applySurface` freezes the one
            // resolved when it was called — which came out light inside a dark pass and drew the
            // transport's glyph and its reading light-on-light. Drawing the ground at draw time
            // is the whole reason that component exists.
            let host = ThemedSurfaceView()
            host.translatesAutoresizingMaskIntoConstraints = true
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 360)
            host.appearance = NSAppearance(named: name)
            host.applySurface(fill: Design.Surface.panel, radius: .fixed(0))
            host.addSubview(player)
            NSLayoutConstraint.activate([
                player.leadingAnchor.constraint(
                    equalTo: host.leadingAnchor,
                    constant: Render.padding
                ),
                player.trailingAnchor.constraint(
                    equalTo: host.trailingAnchor,
                    constant: -Render.padding
                ),
                player.topAnchor.constraint(
                    equalTo: host.topAnchor,
                    constant: Render.padding
                )
            ])
            let window = NSWindow(
                contentRect: host.bounds,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host

            let ready = XCTestExpectation(description: "ready")
            player.onStateReport = { if $0.phase == .ready { ready.fulfill() } }
            player.update(document: ExtensionMediaDocument(
                id: "storybook",
                source: .extensionResource("storybook.json"),
                format: .lottie,
                playback: ExtensionMediaPlayback(
                    isPlaying: false,
                    loop: .loop,
                    speed: 1,
                    progress: progress,
                    background: .checkerboard
                ),
                allowsFrameCopy: true,
                accessibilityLabel: "A travelling dot",
                stateActionID: "storybook-state"
            ))
            _ = XCTWaiter.wait(for: [ready], timeout: 5)
            // `ready` fires when the document is *opened*; the first frame is rasterized off the
            // main actor and committed afterwards. Waiting a fixed interval is how a picture of a
            // player comes back with an empty canvas on a loaded machine — so wait for the frame
            // itself, which is a state the canvas can be asked about.
            let deadline = Date(timeIntervalSinceNow: 5)
            while player.canvasForTesting.presentedFrameForTesting == nil,
                  Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            XCTAssertNotNil(
                player.canvasForTesting.presentedFrameForTesting,
                "the player never committed a frame to draw"
            )

            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            result = rep
            window.contentView = nil
        }

        if let appearance = NSAppearance(named: name) {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return result
    }

    // MARK: - Storybook

    func testRendersTheTransportStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                for (stateName, value, focused) in [
                    ("start", 0.0, false),
                    ("midway", 0.5, false),
                    ("midway-focused", 0.5, true),
                    ("end", 1.0, false)
                ] as [(String, Double, Bool)] {
                    let render = try XCTUnwrap(
                        scrubberRender(value: value, focused: focused, appearance: appearanceID),
                        "Failed to render \(stateName) under \(themeName)"
                    )
                    try write(
                        render.rep,
                        to: directory,
                        named: "scrubber-\(stateName)-\(themeName)-\(appearanceName)"
                    )
                    written += 1
                }

                for (stateName, isPlaying, duration) in [
                    ("paused", false, 95.0),
                    ("playing", true, 95.0),
                    ("unknown-duration", false, 0.0)
                ] as [(String, Bool, Double)] {
                    let rep = try XCTUnwrap(
                        transportRender(
                            isPlaying: isPlaying,
                            documentDuration: duration,
                            appearance: appearanceID
                        ),
                        "Failed to render transport \(stateName) under \(themeName)"
                    )
                    try write(
                        rep,
                        to: directory,
                        named: "transport-\(stateName)-\(themeName)-\(appearanceName)"
                    )
                    written += 1
                }
            }
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count * 7)
        print("Rendered transport storybook to \(directory.path)")
    }

    // MARK: - Fixture

    private struct Scrubber {
        let rep: NSBitmapImageRep
        let bounds: NSRect
        let trackRect: NSRect
        let knobRect: NSRect

        var scale: CGFloat { CGFloat(rep.pixelsWide) / bounds.width }

        func color(at point: NSPoint) -> NSColor? {
            let x = Int((point.x * scale).rounded(.down))
            let y = Int(((bounds.height - point.y) * scale).rounded(.down))
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
            return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        }
    }

    private func scrubberRender(
        value: Double,
        focused: Bool,
        appearance name: NSAppearance.Name
    ) -> Scrubber? {
        var result: Scrubber?
        let render: @MainActor () -> Void = {
            let scrubber = ThemedScrubber(frame: .zero)
            scrubber.value = value

            let size = NSSize(
                width: Render.width,
                height: scrubber.intrinsicContentSize.height
            )
            let host = NSView(
                frame: NSRect(
                    x: 0,
                    y: 0,
                    width: size.width + Render.padding * 2,
                    height: size.height + Render.padding * 2
                )
            )
            // Without this the offscreen pass draws a blank picture.
            host.appearance = NSAppearance(named: name)
            host.applySurface(fill: Design.Surface.panel, radius: .fixed(0))
            scrubber.frame = NSRect(
                origin: NSPoint(x: Render.padding, y: Render.padding),
                size: size
            )
            host.addSubview(scrubber)

            let window = NSWindow(
                contentRect: host.bounds,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            if focused {
                XCTAssertTrue(window.makeFirstResponder(scrubber), "the scrubber refused focus")
            }

            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)

            let knob = host.convert(scrubber.knobRect, from: scrubber)
            result = Scrubber(
                rep: rep,
                bounds: host.bounds,
                trackRect: NSRect(
                    x: scrubber.frame.minX,
                    y: knob.midY - ThemedScrubber.Layout.trackHeight / 2,
                    width: scrubber.frame.width,
                    height: ThemedScrubber.Layout.trackHeight
                ).insetBy(dx: Design.Accessibility.focusRingWidth + ThemedScrubber.Layout.focusGap, dy: 0),
                knobRect: knob
            )
            window.contentView = nil
        }

        if let appearance = NSAppearance(named: name) {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return result
    }

    private func transportRender(
        isPlaying: Bool,
        documentDuration: Double,
        appearance name: NSAppearance.Name
    ) -> NSBitmapImageRep? {
        var result: NSBitmapImageRep?
        let render: @MainActor () -> Void = {
            let transport = MediaTransportView(frame: .zero)
            transport.isPlaying = isPlaying
            transport.documentDuration = documentDuration
            transport.progress = documentDuration > 0 ? 0.4 : 0

            let host = NSView(
                frame: NSRect(
                    x: 0,
                    y: 0,
                    width: Render.width + Render.padding * 2,
                    height: MediaTransportView.Layout.height + Render.padding * 2
                )
            )
            host.appearance = NSAppearance(named: name)
            host.applySurface(fill: Design.Surface.panel, radius: .fixed(0))
            host.addSubview(transport)
            NSLayoutConstraint.activate([
                transport.leadingAnchor.constraint(
                    equalTo: host.leadingAnchor,
                    constant: Render.padding
                ),
                transport.trailingAnchor.constraint(
                    equalTo: host.trailingAnchor,
                    constant: -Render.padding
                ),
                transport.centerYAnchor.constraint(equalTo: host.centerYAnchor)
            ])

            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            result = rep
        }

        if let appearance = NSAppearance(named: name) {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return result
    }

    private func write(_ rep: NSBitmapImageRep, to directory: URL, named name: String) throws {
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    private func assertCarriesAccentHue(_ color: NSColor, themeName: String, where_: String) {
        let accent = Design.Surface.accent.usingColorSpace(.sRGB) ?? .black
        let dominant = max(accent.redComponent, accent.greenComponent, accent.blueComponent)
        let channel: (NSColor) -> CGFloat
        switch dominant {
        case accent.redComponent: channel = { $0.redComponent }
        case accent.greenComponent: channel = { $0.greenComponent }
        default: channel = { $0.blueComponent }
        }
        XCTAssertGreaterThan(
            channel(color), 0.4,
            "\(where_) under \(themeName) is not drawn in the theme's accent"
        )
    }
}
