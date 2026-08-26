import AppKit
import XCTest
@testable import Threading

/// Draws the switch focused and unfocused and writes each state out, per the component contract
/// in `docs/THEME_BOUNDARY.md`.
///
/// Two themes on purpose, because the switch takes its corner from the theme's material and the
/// two cases are geometrically different controls: Neo Brutalism's square track (`panelRadius` 0)
/// puts a hard-cornered knob in a hard-cornered track, Cyberpunk's rounded one puts a disc in a
/// stadium. Both were wrong in the same place and only one of them showed it.
///
/// The assertions are the bug this file was written for. `drawKeyboardFocus` strokes *inside* the
/// silhouette it is given, which every other control can afford; the switch's knob is inset by
/// exactly the ring's width, so the ring landed on the whole accent gutter and the knob came out
/// flush against a near-white ring with the track's own colour gone from three sides. What
/// survived at each knob corner was the wedge between the knob's arc and the ring's square inner
/// edge — four accent specks around a knob that otherwise looked flush, which is how it was
/// reported. Focus now happens entirely outside the track, in margin the control reserves, so the
/// track has to render identically either way.
@MainActor
final class ThemedToggleRenderTests: XCTestCase {

    /// Pixel comparisons need a window only for first-responder state. Reusing one unshown host
    /// keeps that dependency bounded across the theme/state matrix; constructing a fresh window
    /// for every resting/focused sample was enough to cross AppKit's live-window threshold late
    /// in the full test plan even though each sample detached its content afterwards.
    private static let renderHostWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }()

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

        /// A square-cornered theme and a rounded one — the two silhouettes the switch draws.
        static let themes: [(name: String, theme: AppTheme)] = [
            ("neo-brutalism", AppThemeStyles.neoBrutalism),
            ("cyberpunk", AppThemeStyles.cyberpunk)
        ]

        static let states: [(name: String, isOn: Bool)] = [("off", false), ("on", true)]
        static let focus: [(name: String, focused: Bool)] = [("resting", false), ("focused", true)]

        /// Room around the control, so the picture shows the ring meeting the page rather than
        /// the ring meeting the edge of the file.
        static let padding: CGFloat = 12
    }

    // MARK: - Focus Leaves The Track Alone

    /// The reported defect, stated as the thing that has to stay true: taking focus changes
    /// nothing inside the track. Every pixel of it, both states, both silhouettes — the specks
    /// were four pixels, and an assertion that samples a handful of points is how four pixels
    /// survive a test.
    func testFocusLeavesEveryPixelOfTheTrackAlone() throws {
        defer { AppThemePalette.set(.system) }

        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                for (stateName, isOn) in Render.states {
                    let resting = try XCTUnwrap(
                        toggleRender(appearance: appearanceID, isOn: isOn, focused: false)
                    )
                    let focused = try XCTUnwrap(
                        toggleRender(appearance: appearanceID, isOn: isOn, focused: true)
                    )
                    let where_ = "\(themeName)/\(appearanceName)/\(stateName)"

                    if let (x, y, a, b) = firstDifference(
                        between: resting,
                        and: focused,
                        over: resting.track
                    ) {
                        XCTFail(
                            """
                            The focus ring reached into the track at (\(x), \(y)) under \(where_): \
                            \(describe(a)) resting became \(describe(b)) focused.
                            """
                        )
                    }
                }
            }
        }
    }

    // MARK: - The Ring Reaches The Margin

    /// The other half: a ring drawn into room the control did not reserve is clipped to `bounds`
    /// and comes back at partial weight or not at all, which is a focus ring that silently is not
    /// one. Sampled at all four edge midpoints because that is where an under-reserved margin
    /// still leaves *something*, and at the clear gap because a ring that has swallowed its own
    /// gap is a border.
    func testTheFocusRingDrawsInTheMarginAndHoldsTheGapClear() throws {
        defer { AppThemePalette.set(.system) }

        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            let resting = try XCTUnwrap(toggleRender(appearance: .aqua, isOn: false, focused: false))
            let focused = try XCTUnwrap(toggleRender(appearance: .aqua, isOn: false, focused: true))

            // Anchored on the *track*, not on the control's edge: those coincide only while the
            // margin is actually reserved, and a ring that never left the track would otherwise
            // satisfy this by sitting where the margin was supposed to be.
            let width = Design.Accessibility.focusRingWidth
            let reach = ThemedToggle.Layout.focusGap + width / 2
            let ring = focused.trackRect.insetBy(dx: -reach, dy: -reach)
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
                    "\(themeName)'s ring never reached its \(edge) margin"
                )
                assertCarriesAccentHue(inked, themeName: themeName, where_: "the \(edge) ring")
            }

            // Halfway across the clear gap, between the track and the ring's inner edge.
            let half = ThemedToggle.Layout.focusGap / 2
            let gap = focused.trackRect.insetBy(dx: -half, dy: -half)
            let inGap = try XCTUnwrap(focused.color(at: NSPoint(x: gap.midX, y: gap.maxY)))
            let bareGap = try XCTUnwrap(resting.color(at: NSPoint(x: gap.midX, y: gap.maxY)))
            XCTAssertLessThan(
                distance(inGap, bareGap), 0.05,
                "\(themeName)'s ring closed the gap it is supposed to hold clear"
            )
        }
    }

    // MARK: - The Knob Fills Its Corner

    /// The specks, at rest and with no focus ring in sight — because that is where they come
    /// from. A knob holding a corner of its own is not concentric with the track, so the accent
    /// gutter is `knobInset` on the flats and `knobInset √2` across the diagonals, and a wedge of
    /// track survives at each knob corner. A full gutter hides it; anything else drawn in the
    /// gutter leaves it as the only accent still showing, which is how it was reported.
    ///
    /// Stated against a hard-cornered theme because that is where the mismatch is visible: a
    /// square track over a 2pt inset wants a knob with no corner at all, so the pixel in the
    /// knob's own corner has to be knob.
    func testTheKnobFillsItsCornerUnderAHardCorneredTheme() throws {
        AppThemePalette.set(AppThemeStyles.neoBrutalism)
        defer { AppThemePalette.set(.system) }

        let render = try XCTUnwrap(toggleRender(appearance: .aqua, isOn: true, focused: false))
        let ground = try XCTUnwrap(
            render.color(at: NSPoint(x: render.knob.midX, y: render.knob.midY))
        )

        let corners: [(String, NSPoint)] = [
            ("top-trailing", NSPoint(x: render.knob.maxX - 0.5, y: render.knob.maxY - 0.5)),
            ("bottom-trailing", NSPoint(x: render.knob.maxX - 0.5, y: render.knob.minY + 0.5))
        ]
        for (name, point) in corners {
            let sampled = try XCTUnwrap(render.color(at: point))
            XCTAssertLessThan(
                distance(sampled, ground), 0.05,
                """
                A wedge of track survives at the knob's \(name) corner — \(describe(sampled)) \
                where the knob is \(describe(ground)).
                """
            )
        }
    }

    // MARK: - Storybook

    func testRendersTheToggleStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                for (stateName, isOn) in Render.states {
                    for (focusName, focused) in Render.focus {
                        let render = try XCTUnwrap(
                            toggleRender(appearance: appearanceID, isOn: isOn, focused: focused),
                            "Failed to render \(stateName)/\(focusName) under \(themeName)"
                        )
                        let data = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]))
                        try data.write(
                            to: directory.appendingPathComponent(
                                "toggle-\(stateName)-\(focusName)-\(themeName)-\(appearanceName).png"
                            )
                        )
                        written += 1
                    }
                }
            }
        }

        XCTAssertEqual(
            written,
            Render.themes.count * Render.appearances.count * Render.states.count * Render.focus.count
        )
        print("Rendered switch storybook to \(directory.path)")
    }

    // MARK: - Fixture

    /// One drawn switch, plus the two rectangles the assertions are stated in. Sampling is by
    /// *point*, in the host's own coordinates, because the backing store may be 1× or 2× and a
    /// test that hard-codes pixels is a test that passes on one Mac.
    private struct Toggle {
        let rep: NSBitmapImageRep
        let bounds: NSRect
        /// The switch's whole footprint — track plus the margin reserved for its ring.
        let control: NSRect
        /// The track: what the switch looks like, and all that focus must not touch.
        let trackRect: NSRect
        /// The same, as the *silhouette* rather than its bounding box. A stadium track leaves
        /// most of each box corner to the page, and a ring drawn 2pt outside a stadium sweeps
        /// straight through that corner — correctly, and 4.5pt clear of anything the switch drew.
        let track: NSBezierPath
        /// Where the knob came to rest.
        let knob: NSRect

        var scale: CGFloat { CGFloat(rep.pixelsWide) / bounds.width }

        func color(at point: NSPoint) -> NSColor? {
            let x = Int((point.x * scale).rounded(.down))
            let y = Int(((bounds.height - point.y) * scale).rounded(.down))
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
            return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        }
    }

    private func toggleRender(
        appearance name: NSAppearance.Name,
        isOn: Bool,
        focused: Bool
    ) -> Toggle? {
        let appearance = NSAppearance(named: name)

        var result: Toggle?
        let render: @MainActor () -> Void = {
            let toggle = ThemedToggle()
            toggle.state = isOn ? .on : .off

            let size = toggle.intrinsicContentSize
            let host = NSView(
                frame: NSRect(
                    x: 0,
                    y: 0,
                    width: size.width + Render.padding * 2,
                    height: size.height + Render.padding * 2
                )
            )
            host.applySurface(fill: Design.Surface.panel, radius: .fixed(0))
            host.appearance = appearance
            toggle.frame = NSRect(origin: NSPoint(x: Render.padding, y: Render.padding), size: size)
            host.addSubview(toggle)

            // The ring only exists while the switch is the window's first responder, and
            // `hasKeyboardFocus` asks the window directly — so the fixture needs a window, but
            // never a visible one: `makeFirstResponder` does not require key status, and a window
            // ordered on screen and then released is what strands the test host mid-suite.
            let window = Self.renderHostWindow
            window.setContentSize(host.bounds.size)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: host.bounds.size)
            if focused {
                XCTAssertTrue(window.makeFirstResponder(toggle), "the switch refused focus")
            }

            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)

            let margin = (size.height - ThemedToggle.Layout.height) / 2
            let track = toggle.frame.insetBy(dx: margin, dy: margin)
            let radius = ThemedToggle.Layout.trackRadius(
                square: AppThemePalette.current.material.panelRadius == 0
            )
            let inset = ThemedToggle.Layout.knobInset
            let diameter = ThemedToggle.Layout.height - inset * 2
            let travel = ThemedToggle.Layout.width - diameter - inset * 2
            result = Toggle(
                rep: rep,
                bounds: host.bounds,
                control: toggle.frame,
                trackRect: track,
                track: NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius),
                knob: NSRect(
                    x: track.minX + inset + (isOn ? travel : 0),
                    y: track.minY + inset,
                    width: diameter,
                    height: diameter
                )
            )
            window.makeFirstResponder(nil)
            window.contentView = nil
        }

        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return result
    }

    // MARK: - Sampling

    private func firstDifference(
        between resting: Toggle,
        and focused: Toggle,
        over shape: NSBezierPath
    ) -> (x: CGFloat, y: CGFloat, resting: NSColor, focused: NSColor)? {
        let rect = shape.bounds
        let step = 1 / max(resting.scale, 1)
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                let point = NSPoint(x: x, y: y)
                if shape.contains(point),
                   let a = resting.color(at: point),
                   let b = focused.color(at: point),
                   distance(a, b) > 0.02 {
                    return (x, y, a, b)
                }
                x += step
            }
            y += step
        }
        return nil
    }

    /// Straight RGB distance, which is all these comparisons need: the question is never "which
    /// shade" but "did anything land here at all".
    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    /// The ring is the theme's accent, so its hue is checkable without pinning bytes that drift
    /// with anti-aliasing: Neo Brutalism's `#0057FF` is blue-dominant, Cyberpunk's neon is green.
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

    private func describe(_ color: NSColor) -> String {
        String(
            format: "#%02X%02X%02X",
            Int(color.redComponent * 255),
            Int(color.greenComponent * 255),
            Int(color.blueComponent * 255)
        )
    }
}
