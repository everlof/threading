import AppKit

/// One of a chrome-takeover window's own buttons: Window menu, close, minimize, zoom, or depth.
///
/// Exists because a takeover window has no traffic lights — the theme asked for the entire
/// frame, and these are the frame's working parts. One component for every semantic role and
/// every glyph style (`WindowChromeStyle.TitleBar.ButtonGlyphStyle`): a theme picks a style, it
/// never draws its own buttons, and a fourth role or another style arrives here rather than as
/// a sibling class — the tab strip's "every" lesson, applied before there are two.
///
/// The action is the window's own (`performClose` / `performMiniaturize` / `performZoom`), so
/// the button needs no wiring beyond living in a window — and behaves identically for keyboard
/// and accessibility activation, which `ThemedControl` routes through the same press.
final class WindowChromeButton: ThemedControl {

    /// Caption hardware is allowed to cast its period shadow into the otherwise unused part of
    /// its title-band slot. Cheetah's 13px glass face has a measured 17px shadow envelope; the
    /// default view clipping reduced that to a hard 14px silhouette and no amount of colour
    /// tuning could reconstruct the native edge. Other families remain inside their slots, so
    /// opting this shared caption surface out of default clipping does not alter their pixels.
    override var wantsDefaultClipping: Bool { false }

    enum Role: Equatable {
        case windowMenu
        case close
        case minimize
        case zoom
        case depth

        var accessibilityLabel: String {
            switch self {
            case .windowMenu: L10n.string("Window menu")
            case .close: L10n.string("Close")
            case .minimize: L10n.string("Minimize")
            case .zoom: L10n.string("Zoom")
            case .depth: L10n.string("Send to Back")
            }
        }
    }

    let role: Role

    /// A style stated by a fixture — a gallery story, a render test — instead of resolved
    /// from the active theme. Per instance, so a preview can never dress the real window.
    var fixtureStyle: WindowChromeAppearance.Resolved? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Key-state stated by a fixture: an unshown render window is never key, and the band
    /// hands its own value down so the cluster previews as one piece.
    var fixtureIsKey: Bool? {
        didSet { needsDisplay = true }
    }

    /// Zoom state stated by a fixture. Real buttons follow `window.isZoomed` and exchange the
    /// maximize figure for Restore, just as the system caption button does.
    var fixtureIsZoomed: Bool? {
        didSet { applyWindowState() }
    }

    private var isPressed = false { didSet { needsDisplay = true } }
    nonisolated(unsafe) private var windowStateObservations: [NSObjectProtocol] = []

    /// Replaces presentation in a component test while still receiving the exact semantic
    /// menu a real press would show. Nil in production.
    var fixtureMenuPresentation: ((ThemedMenuPresentation) -> Void)?
    private var menuSession: AnyObject?

    var displaysRestore: Bool {
        guard case .zoom = role else { return false }
        return fixtureIsZoomed ?? window?.isZoomed == true
    }

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(role.accessibilityLabel)
        toolTip = role.accessibilityLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        windowStateObservations.forEach(NotificationCenter.default.removeObserver)
    }

    /// The family's measured period slot, from the one anatomy table. The rationale for
    /// each measurement lives on its row in `WindowChromeCaptionAnatomy`.
    override var intrinsicContentSize: NSSize {
        let anatomy = WindowChromeCaptionAnatomy.of(
            (fixtureStyle ?? WindowChromeAppearance.resolve())?.glyphStyle
        )
        return anatomy.slotSize ?? NSSize(
            width: Design.Size.windowButtonWidth,
            height: Design.Size.windowButtonHeight
        )
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowStateObservations.forEach(NotificationCenter.default.removeObserver)
        windowStateObservations = []

        guard let newWindow else {
            applyWindowState()
            return
        }
        for name in [
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ] {
            windowStateObservations.append(NotificationCenter.default.addObserver(
                forName: name,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyWindowState() }
            })
        }
        applyWindowState()
    }

    private func applyWindowState() {
        let label = displaysRestore ? L10n.string("Restore") : role.accessibilityLabel
        setAccessibilityLabel(label)
        toolTip = label
        needsDisplay = true
    }

    // MARK: - Press

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let fires = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if fires { _ = performPrimaryAction() }
    }

    /// The semantic operations, not the `perform*` forms: those simulate a press on the
    /// standard button they animate, and a frameless window has none to press — measured,
    /// `performZoom` and `performClose` refuse outright there. Close still asks
    /// `windowShouldClose`, which is the half of `performClose` that was behaviour rather
    /// than button theatre.
    override func performPrimaryAction() -> Bool {
        guard isEnabled, let window else { return false }
        switch role {
        case .windowMenu:
            presentWindowMenu()
        case .close:
            if window.delegate?.windowShouldClose?(window) ?? true {
                window.close()
            }
        case .minimize:
            window.miniaturize(nil)
        case .zoom:
            window.zoom(nil)
        case .depth:
            window.orderBack(nil)
        }
        return true
    }

    // MARK: - Drawing

    /// One interpreter over the family's anatomy row. Nothing here knows which family it is
    /// drawing — every per-family decision (plate recipe, rendering, ink source, press
    /// behaviour, alphabet) is a value on `WindowChromeCaptionAnatomy`, so a fix landing in
    /// this method lands for every family at once.
    override func draw(_ dirtyRect: NSRect) {
        let resolved = fixtureStyle ?? WindowChromeAppearance.resolve()
        let anatomy = WindowChromeCaptionAnatomy.of(resolved?.glyphStyle)

        if resolved?.glyphStyle == .classicPlayer {
            drawClassicPlayerButton(resolved: resolved, anatomy: anatomy)
            return
        }

        // A keyed 4Dwm title is one continuous indexed-palette frame: the button bevels
        // share dither phase and rails with the surrounding band. The parent paints that
        // resting construction in one pass while these controls retain their semantic hit
        // regions. A pressed button still falls through to the live sunken treatment.
        if resolved?.glyphStyle == .irix, isKeyOrHasNoWindow, !isPressed {
            return
        }

        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        if anatomy.rendering == .pixel {
            NSGraphicsContext.current?.shouldAntialias = false
        }

        switch anatomy.plate {
        case .none:
            if isHovered || isPressed {
                let bandInk = InkSource.titleBand.ink
                ThemedSurface.draw(
                    bounds,
                    fill: isPressed ? bandInk.surfaceHover : bandInk.surface
                )
            }
        case .control(let hoverLifts):
            if resolved?.glyphStyle == .platinum, !isPressed {
                drawPlatinumPlate(in: bounds)
            } else if resolved?.glyphStyle == .openStep,
                      role == .close,
                      isKeyOrHasNoWindow,
                      !isPressed {
                drawOpenStepClosePlate(in: bounds)
            } else {
                let fill = isPressed
                    ? Design.Surface.controlHover
                    : (hoverLifts && isHovered
                        ? Design.Surface.elevated
                        : Design.Surface.controlResting)
                ThemedSurface.draw(
                    bounds,
                    fill: fill,
                    border: Design.Surface.border,
                    bevel: isPressed ? .sunken : .automatic
                )
            }
        case .band(let dimsWithWindow, let pressedUsesControlHover):
            if resolved?.glyphStyle == .beOS, isKeyOrHasNoWindow, !isPressed {
                drawBeOSPlate(in: bounds)
            } else {
                let gradient = dimsWithWindow && !isKeyOrHasNoWindow
                    ? resolved?.inactiveGradient
                    : resolved?.activeGradient
                let base = gradient?.colors.first ?? Design.Surface.controlResting
                ThemedSurface.draw(
                    bounds,
                    fill: pressedUsesControlHover && isPressed
                        ? Design.Surface.controlHover
                        : base,
                    border: Design.Surface.border,
                    bevel: isPressed ? .sunken : .automatic
                )
            }
        case .gel(let recipe):
            drawAquaPlate(in: bounds, recipe: recipe)
        case .reverseVideo:
            if isHovered || isPressed {
                let cell = bandInk(of: resolved)
                cell.setFill()
                // A terminal cell has no translucent pressed material. Seat the keyed face
                // one hard pixel inside its hover cell instead: the same two inks, with the
                // ground becoming a tiny mechanical edge around the depressed face.
                (isPressed ? bounds.insetBy(dx: 1, dy: 1) : bounds).fill()
            }
        }
        if anatomy.outlinedInBorder {
            Design.Surface.border.setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }

        var ink: NSColor
        switch anatomy.glyphInk {
        case .label:
            ink = Design.Text.label
        case .band:
            // With no style at all — a fixture under a theme that states no chrome — the
            // glyph takes the label's ink so the component stays visible for review.
            ink = bandInk(of: resolved)
        case .fixed(let stated):
            ink = stated
        }
        // An inverted cell shows its figure as the ground coming *through* the ink, which is
        // the one thing `glyphInk` cannot say: every other value names a colour to paint
        // with, and this one is decided by whichever plate is under the pointer.
        if case .reverseVideo = anatomy.plate, isHovered || isPressed {
            ink = bandGround(of: resolved)
        }

        let opticalGlyphBounds = bounds.offsetBy(
            dx: anatomy.glyphOpticalOffset.x,
            dy: anatomy.glyphOpticalOffset.y
        )
        let glyphBounds = isPressed
            ? opticalGlyphBounds.offsetBy(
                dx: anatomy.pressedGlyphOffset.x,
                dy: anatomy.pressedGlyphOffset.y
            )
            : opticalGlyphBounds
        let plateContainsRestingArtwork = resolved?.glyphStyle == .platinum
            || (resolved?.glyphStyle == .beOS && isKeyOrHasNoWindow && !isPressed)
            || (resolved?.glyphStyle == .openStep
                && role == .close
                && isKeyOrHasNoWindow
                && !isPressed)
        if !plateContainsRestingArtwork,
           !anatomy.glyphsRequireHover || isHovered || isPressed {
            switch anatomy.alphabet {
            case .vector:
                drawGlyph(in: glyphBounds, ink: ink)
            case .aquaGel:
                drawAquaGlyph(in: glyphBounds, ink: ink)
            case .bitmap(let artwork):
                WindowChromeCaptionArtwork.draw(
                    artwork(role, displaysRestore),
                    in: glyphBounds,
                    ink: ink
                )
            }
        }
        drawKeyboardFocus(around: ThemedSurface.Shape(
            rect: bounds,
            radius: Design.Radius.control(fitting: bounds.size)
        ))
    }

    /// Draws either the exact sprite from a user-imported `.wsz` sheet or the stock
    /// clean-room Classic Player button. Behaviour remains semantic: the skin's Shade image
    /// is Threading's Zoom/Restore operation, and its Options image opens the app-owned window
    /// menu rather than running code from the archive.
    private func drawClassicPlayerButton(
        resolved: WindowChromeAppearance.Resolved?,
        anatomy: WindowChromeCaptionAnatomy
    ) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.imageInterpolation = .none

        if let sheet = resolved?.classicSkin?.titleBarImage,
           drawClassicPlayerSprite(from: sheet) {
            drawKeyboardFocus(around: ThemedSurface.Shape(rect: bounds, radius: 0))
            return
        }

        ThemedSurface.draw(
            bounds,
            fill: isPressed ? Design.Surface.controlHover : Design.Surface.controlResting,
            border: Design.Surface.border,
            bevel: isPressed ? .sunken : .automatic
        )
        let glyphBounds = isPressed
            ? bounds.offsetBy(
                dx: anatomy.pressedGlyphOffset.x,
                dy: anatomy.pressedGlyphOffset.y
            )
            : bounds
        WindowChromeCaptionArtwork.draw(
            WindowChromeCaptionArtwork.classicPlayer(role, restored: displaysRestore),
            in: glyphBounds,
            ink: bandInk(of: resolved)
        )
        drawKeyboardFocus(around: ThemedSurface.Shape(rect: bounds, radius: 0))
    }

    /// Classic TITLEBAR.BMP coordinates, independently cross-checked against Webamp's MIT
    /// sprite table and Audacious's GPLv3 skins plugin. Source coordinates are top-left;
    /// `NSImage.draw` consumes bottom-left coordinates, hence the y conversion.
    @discardableResult
    private func drawClassicPlayerSprite(from sheet: NSImage) -> Bool {
        let topLeft: NSPoint
        switch role {
        case .windowMenu:
            topLeft = NSPoint(x: 0, y: isPressed ? 9 : 0)
        case .minimize:
            topLeft = NSPoint(x: 9, y: isPressed ? 9 : 0)
        case .zoom, .depth:
            topLeft = NSPoint(x: isPressed ? 9 : 0, y: 18)
        case .close:
            topLeft = NSPoint(x: 18, y: isPressed ? 9 : 0)
        }

        let side: CGFloat = 9
        guard sheet.size.width >= topLeft.x + side,
              sheet.size.height >= topLeft.y + side else { return false }
        let source = NSRect(
            x: topLeft.x,
            y: sheet.size.height - topLeft.y - side,
            width: side,
            height: side
        )
        sheet.draw(
            in: bounds,
            from: source,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.none]
        )
        return true
    }

    /// Mac OS 9's resting caption boxes are thirteen-pixel indexed-palette plates inside a
    /// fourteen-pixel hit slot. Their diagonal silver fill is the close affordance; Zoom adds
    /// two dark rails to that same plate. A generic bevel plus a modern square glyph loses both
    /// facts, which is why the old reproduction looked like an outlined checkbox.
    private func drawPlatinumPlate(in slot: NSRect) {
        var rows = [
            "HHHHHHHHHHHHA",
            "HGGGGGGGGGGGB",
            "HGBAAAAAAAAGB",
            "HGAEEJJIIAHGB",
            "HGAEJJIIAAHGB",
            "HGAJJIIAAFHGB",
            "HGAJIIAAFFHGB",
            "HGAIIAAFFQHGB",
            "HGAIAAFFQQHGB",
            "HGAAAFFQQBHGB",
            "HGAHHHHHHHHGB",
            "HGGGGGGGGGGGB",
            "ABBBBBBBBBBBB"
        ]
        if role == .zoom {
            rows[5] = "HGGGGGGGGGGGB"
            rows[7] = "HGGGGGGGGGGGB"
        }

        let palette: [Character: NSColor] = [
            "A": NSColor(srgbRed: 204 / 255, green: 204 / 255, blue: 204 / 255, alpha: 1),
            "B": .white,
            "E": NSColor(srgbRed: 153 / 255, green: 153 / 255, blue: 153 / 255, alpha: 1),
            "F": NSColor(srgbRed: 221 / 255, green: 221 / 255, blue: 221 / 255, alpha: 1),
            "G": NSColor(srgbRed: 34 / 255, green: 34 / 255, blue: 34 / 255, alpha: 1),
            "H": NSColor(srgbRed: 136 / 255, green: 136 / 255, blue: 136 / 255, alpha: 1),
            "I": NSColor(srgbRed: 187 / 255, green: 187 / 255, blue: 187 / 255, alpha: 1),
            "J": NSColor(srgbRed: 170 / 255, green: 170 / 255, blue: 170 / 255, alpha: 1),
            "Q": NSColor(srgbRed: 238 / 255, green: 238 / 255, blue: 238 / 255, alpha: 1)
        ]
        let plate = NSRect(x: slot.minX + 1, y: slot.minY, width: 13, height: 13)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        for (rowIndex, row) in rows.enumerated() {
            let y = isFlipped
                ? plate.minY + CGFloat(rowIndex)
                : plate.maxY - CGFloat(rowIndex + 1)
            for (column, sample) in row.enumerated() {
                (palette[sample] ?? .black).setFill()
                NSRect(x: plate.minX + CGFloat(column), y: y, width: 1, height: 1).fill()
            }
        }
    }

    /// BeOS R5's tab gadgets are indexed-palette artwork, not a generic bevel with a symbol
    /// painted on top. Close and Zoom even use different ochre ramps where their figures meet
    /// the yellow tab. These rows are the native 14×14 pixels from the Charts title-tab crop;
    /// the surrounding 16×14 slot remains the hit target and cluster-spacing mechanism.
    private func drawBeOSPlate(in slot: NSRect) {
        let rows: [String]
        let palette: [Character: NSColor]
        if role == .zoom {
            rows = [
                "BBBBBBBBCCCCCC",
                "BAAAAAAAACCCCC",
                "BAADDCCBACCCCC",
                "BADDCDCBABBBBB",
                "BADCDCCBAAAAAA",
                "BACDCCEBADDDBA",
                "BACCEEEBADDEBA",
                "BABBBBBBADCEBA",
                "CAAAAAAAACDEBA",
                "CCCBADDDCDCEBA",
                "CCCBADDCDCCEBA",
                "CCCBADEEEEEEBA",
                "CCCBABBBBBBBBA",
                "CCCBAAAAAAAAAA"
            ]
            palette = [
                "A": NSColor(srgbRed: 1, green: 1, blue: 63 / 255, alpha: 1),
                "B": NSColor(srgbRed: 210 / 255, green: 157 / 255, blue: 0, alpha: 1),
                "C": NSColor(srgbRed: 1, green: 203 / 255, blue: 0, alpha: 1),
                "D": NSColor(srgbRed: 1, green: 236 / 255, blue: 33 / 255, alpha: 1),
                "E": NSColor(srgbRed: 234 / 255, green: 181 / 255, blue: 0, alpha: 1)
            ]
        } else {
            rows = [
                "BBBBBBBBBBBBBB",
                "BAAAAAAAAAAAAA",
                "BAACACCCCCCDBA",
                "BACACCCCDCDCBA",
                "BAACCCCDCDCDBA",
                "BACCCCDCDDDDBA",
                "BACCCDCDDDDEBA",
                "BACCDCDDDEEEBA",
                "BACDCDDDEDEEBA",
                "BACCDDDEDEEEBA",
                "BACDCDDEEEEEBA",
                "BADCDDEEEEEEBA",
                "BABBBBBBBBBBBA",
                "BAAAAAAAAAAAAA"
            ]
            palette = [
                "A": NSColor(srgbRed: 1, green: 1, blue: 63 / 255, alpha: 1),
                "B": NSColor(srgbRed: 183 / 255, green: 130 / 255, blue: 0, alpha: 1),
                "C": NSColor(srgbRed: 1, green: 236 / 255, blue: 33 / 255, alpha: 1),
                "D": NSColor(srgbRed: 1, green: 203 / 255, blue: 0, alpha: 1),
                "E": NSColor(srgbRed: 234 / 255, green: 181 / 255, blue: 0, alpha: 1)
            ]
        }

        let plate = NSRect(x: slot.minX + 1, y: slot.minY, width: 14, height: 14)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        for (rowIndex, row) in rows.enumerated() {
            let y = isFlipped
                ? plate.minY + CGFloat(rowIndex)
                : plate.maxY - CGFloat(rowIndex + 1)
            for (column, sample) in row.enumerated() {
                (palette[sample] ?? .black).setFill()
                NSRect(x: plate.minX + CGFloat(column), y: y, width: 1, height: 1).fill()
            }
        }
    }

    /// The OPENSTEP close plate is a 14×14 indexed-palette inset inside its 18×16 title
    /// slot. The two-pixel horizontal gutter belongs to the title band, while the plate owns
    /// the exact white/#AAA/#555/black diagonal figure. Drawing a generic two-point bevel and
    /// a separate X made the box four pixels too large and changed its four-tone raster into
    /// dozens of antialiased grays.
    private func drawOpenStepClosePlate(in slot: NSRect) {
        let rows = [
            "WWWWWWWWWWWWWW",
            "WGGGGGGGGGGGGD",
            "WGKDGGGGGGDKGD",
            "WGDKDGGGGDKDGD",
            "WGGDKDGGDKDGGD",
            "WGGGDKDDKDGGGD",
            "WGGGGDKKDGGGGD",
            "WGGGGDKKDGGGGD",
            "WGGGDKDDKDGGGD",
            "WGGDKDGGDKDGGD",
            "WGDKDGGGGDKDGD",
            "WGKDGGGGGGDKGD",
            "WGGGGGGGGGGGGD",
            "WDDDDDDDDDDDDD"
        ]
        let palette: [Character: NSColor] = [
            "K": .black,
            "D": NSColor(srgbRed: 85 / 255, green: 85 / 255, blue: 85 / 255, alpha: 1),
            "G": NSColor(srgbRed: 170 / 255, green: 170 / 255, blue: 170 / 255, alpha: 1),
            "W": .white
        ]
        let plate = NSRect(x: slot.minX + 2, y: slot.minY + 1, width: 14, height: 14)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        for (rowIndex, row) in rows.enumerated() {
            let y = isFlipped
                ? plate.minY + CGFloat(rowIndex)
                : plate.maxY - CGFloat(rowIndex + 1)
            for (column, sample) in row.enumerated() {
                (palette[sample] ?? .black).setFill()
                NSRect(
                    x: plate.minX + CGFloat(column),
                    y: y,
                    width: 1,
                    height: 1
                ).fill()
            }
        }
    }

    /// The first Aqua traffic lights were coloured glass rather than flat semantic dots: a
    /// charcoal rim and shadow, a narrow white reflection, and colour that becomes lighter
    /// toward the lower face. Tiger later reversed that balance into a tighter lens-like cap.
    private func drawAquaPlate(
        in rect: NSRect,
        recipe: WindowChromeCaptionAnatomy.Plate.GelRecipe
    ) {
        // The native 1x Cheetah asset is centred on an integer x coordinate inside its even
        // slot (one fully covered top-rim pixel, not two half-covered pixels). Its optical
        // centre therefore sits half a point toward the trailing edge.
        let circle = rect.insetBy(dx: recipe == .cheetah ? 1.0 : 0.75,
                                  dy: recipe == .cheetah ? 0.5 : 0.75)
            .offsetBy(
                dx: recipe == .cheetah ? 0.5 : 0,
                dy: recipe == .tiger ? -1 : 0
            )
        let path = NSBezierPath(ovalIn: circle)
        let base: NSColor
        switch role {
        case .close: base = NSColor(hex: "#F45B4F") ?? Design.Status.negative
        case .minimize: base = NSColor(hex: "#F5BD3B") ?? Design.Status.warning
        case .zoom: base = NSColor(hex: "#52B849") ?? Design.Status.positive
        case .windowMenu, .depth: base = NSColor(hex: "#B8B8B8") ?? Design.Text.secondary
        }
        let pressedBase = isPressed
            ? (base.blended(withFraction: 0.24, of: .black) ?? base)
            : base
        switch recipe {
        case .cheetah:
            // The archived 1x control carries a soft neutral shadow two pixels beyond its
            // charcoal rim. A displaced solid oval produced a clipped, hard-bottomed badge;
            // AppKit's shadow rasteriser gives the period control its measured 17px envelope.
            NSColor.black.withAlphaComponent(0.08).setFill()
            NSBezierPath(ovalIn: circle.insetBy(dx: -2, dy: 0)).fill()
            NSColor.black.withAlphaComponent(0.08).setFill()
            NSBezierPath(ovalIn: circle.insetBy(dx: -1.5, dy: 0)).fill()
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.58)
            shadow.shadowBlurRadius = 2.0
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            NSColor.black.withAlphaComponent(0.82).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Sampled from the native 10.0 crop at the upper saturated row, equator, and
            // lower bloom. A single semantic base cannot produce these hue shifts: notably,
            // the red face loses red while gaining green in its upper third.
            let measured: (
                top: String,
                upper: String,
                middle: String,
                lower: String,
                lowerRim: String,
                sideWall: String
            )
            switch role {
            case .close:
                measured = (
                    "#C6BABA", "#D05449", "#FF877C", "#FFBDB0", "#E9836F", "#C01810"
                )
            case .minimize:
                measured = (
                    "#D5BABA", "#EDA833", "#FFD565", "#FFFF96", "#E9E94D", "#C08000"
                )
            case .zoom:
                measured = (
                    "#BABABA", "#70B83A", "#A6E968", "#D8FF9B", "#AAE955", "#50B010"
                )
            case .windowMenu, .depth:
                measured = (
                    "#C4C4C4", "#868686", "#B8B8B8", "#E0E0E0", "#A0A0A0", "#606060"
                )
            }
            let resolvedTone: (String) -> NSColor = { value in
                let tone = NSColor(hex: value) ?? pressedBase
                return self.isPressed
                    ? (tone.blended(withFraction: 0.24, of: .black) ?? tone)
                    : tone
            }
            NSGradient(colorsAndLocations:
                (resolvedTone(measured.top), 0),
                (resolvedTone(measured.upper), 0.32),
                (resolvedTone(measured.middle), 0.56),
                (resolvedTone(measured.lower), 0.82),
                (resolvedTone(measured.lowerRim), 1)
            )?.draw(in: path, angle: -90)
            // Preserve the sampled centre column while rolling the same tones into the dark
            // side wall visible in the source. This is the spherical half of the gel; the
            // narrow white ellipse below is its separate reflected light.
            let sideWall = resolvedTone(measured.sideWall).withAlphaComponent(
                isPressed ? 0.68 : 0.55
            )
            let leftWall = NSRect(
                x: circle.minX,
                y: circle.minY,
                width: circle.width / 2,
                height: circle.height
            )
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSBezierPath(rect: leftWall).addClip()
            NSGradient(starting: sideWall, ending: .clear)?.draw(in: leftWall, angle: 0)
            NSGraphicsContext.restoreGraphicsState()

            let rightWall = NSRect(
                x: circle.midX,
                y: circle.minY,
                width: circle.width / 2,
                height: circle.height
            )
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSBezierPath(rect: rightWall).addClip()
            NSGradient(starting: .clear, ending: sideWall)?.draw(in: rightWall, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
            // The native face is not a stack of flat horizontal bands: its lower half blooms
            // around the centre while retaining the darker side wall. Keep this deliberately
            // subtle so the sampled centre-column tones remain the dominant construction.
            NSGradient(
                starting: NSColor.white.withAlphaComponent(isPressed ? 0.05 : 0.08),
                ending: .clear
            )?.draw(
                in: path,
                relativeCenterPosition: NSPoint(x: 0, y: -0.55)
            )
        case .tiger:
            let measured: (rows: [String], sideWall: String)
            switch role {
            case .close:
                measured = ([
                    "#C8C0C0", "#E6E0E0", "#DEB4B5", "#C5635D",
                    "#C44A43", "#D66056", "#EB7971", "#F88D84",
                    "#FA9E94", "#FAABA1", "#F9B6AC", "#E2A49A"
                ], "#410D10")
            case .minimize:
                measured = ([
                    "#D8C0C0", "#E7DEDE", "#EAD2B7", "#E1A74E",
                    "#E7A028", "#F6B23F", "#FCC757", "#FDDA6B",
                    "#FFEF7A", "#FFFD85", "#FDFC92", "#E7E381"
                ], "#641911")
            case .zoom:
                measured = ([
                    "#C0C2C0", "#DEE1DE", "#C3D8B8", "#86B652",
                    "#74B02C", "#89C342", "#A0D85C", "#B5EB70",
                    "#C5FB7F", "#D3FF8B", "#DBFD96", "#C6E486"
                ], "#172D10")
            case .windowMenu, .depth:
                measured = ([
                    "#969696", "#E2E2E2", "#D2D2D2", "#A6A6A6",
                    "#9C9C9C", "#AAAAAA", "#BABABA", "#C8C8C8",
                    "#D2D2D2", "#DADADA", "#DEDEDE", "#C8C8C8"
                ], "#303030")
            }
            let resolvedRows = measured.rows.map { value -> NSColor in
                let tone = NSColor(hex: value) ?? pressedBase
                return isPressed
                    ? (tone.blended(withFraction: 0.24, of: .black) ?? tone)
                    : tone
            }
            let locations = resolvedRows.indices.map {
                CGFloat($0) / CGFloat(max(1, resolvedRows.count - 1))
            }
            NSGradient(
                colors: resolvedRows,
                atLocations: locations,
                colorSpace: .sRGB
            )?.draw(in: path, angle: -90)

            let sideWallTone = NSColor(hex: measured.sideWall) ?? .black
            let sideWall = (isPressed
                ? (sideWallTone.blended(withFraction: 0.20, of: .black) ?? sideWallTone)
                : sideWallTone).withAlphaComponent(isPressed ? 0.42 : 0.32)
            let leftWall = NSRect(
                x: circle.minX,
                y: circle.minY,
                width: circle.width / 2,
                height: circle.height
            )
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSBezierPath(rect: leftWall).addClip()
            NSGradient(starting: sideWall, ending: .clear)?.draw(in: leftWall, angle: 0)
            NSGraphicsContext.restoreGraphicsState()

            let rightWall = NSRect(
                x: circle.midX,
                y: circle.minY,
                width: circle.width / 2,
                height: circle.height
            )
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSBezierPath(rect: rightWall).addClip()
            NSGradient(starting: .clear, ending: sideWall)?.draw(in: rightWall, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }

        NSColor.black.withAlphaComponent(recipe == .cheetah ? 0.88 : 0.64).setStroke()
        path.lineWidth = recipe == .cheetah ? 1.0 : 0.9
        path.stroke()

        if recipe == .tiger {
            // Tiger's upper arc is almost black while its lower arc retains the role colour.
            // A single uniform outline either washed out the top or crushed the bottom.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(
                x: circle.minX,
                y: circle.maxY - 0.75,
                width: circle.width,
                height: 0.75
            )).addClip()
            NSColor.black.withAlphaComponent(isPressed ? 1 : 0.98).setStroke()
            path.lineWidth = 2
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        path.addClip()
        NSColor.white.withAlphaComponent(
            isPressed ? 0.18 : (recipe == .cheetah ? 0.88 : 0.42)
        ).setFill()
        switch recipe {
        case .cheetah:
            // The source's white band occupies only two-to-three native rows. The older broad
            // cap made the controls look like later glossy badges and erased their dark rim.
            NSBezierPath(ovalIn: NSRect(
                x: circle.minX + 2,
                y: circle.midY + 4.0,
                width: max(0, circle.width - 4),
                height: max(0, circle.height * 0.14)
            )).fill()
        case .tiger:
            break
        }
    }

    private func drawAquaGlyph(in rect: NSRect, ink: NSColor) {
        let glyph = rect.insetBy(dx: 4.25, dy: 4.25)
        let path = NSBezierPath()
        path.lineWidth = 1
        path.lineCapStyle = .round
        switch role {
        case .close:
            path.move(to: NSPoint(x: glyph.minX, y: glyph.minY))
            path.line(to: NSPoint(x: glyph.maxX, y: glyph.maxY))
            path.move(to: NSPoint(x: glyph.minX, y: glyph.maxY))
            path.line(to: NSPoint(x: glyph.maxX, y: glyph.minY))
        case .minimize:
            path.move(to: NSPoint(x: glyph.minX, y: glyph.midY))
            path.line(to: NSPoint(x: glyph.maxX, y: glyph.midY))
        case .zoom:
            path.move(to: NSPoint(x: glyph.midX, y: glyph.minY))
            path.line(to: NSPoint(x: glyph.midX, y: glyph.maxY))
            path.move(to: NSPoint(x: glyph.minX, y: glyph.midY))
            path.line(to: NSPoint(x: glyph.maxX, y: glyph.midY))
        case .windowMenu:
            path.move(to: NSPoint(x: glyph.minX, y: glyph.midY))
            path.line(to: NSPoint(x: glyph.maxX, y: glyph.midY))
        case .depth:
            path.appendRect(glyph)
        }
        ink.setStroke()
        path.stroke()
    }

    /// A fixture with no window draws its key form; a real band dims with its window.
    private var isKeyOrHasNoWindow: Bool {
        fixtureIsKey ?? (window == nil || window?.isKeyWindow == true)
    }

    /// The band's stated ink for the current key state. Read from the *resolved* style handed
    /// in rather than from `WindowChromeAppearance`'s global answer, so a fixture previewing
    /// one theme inside another is drawn in the style it was given.
    private func bandInk(of resolved: WindowChromeAppearance.Resolved?) -> NSColor {
        isKeyOrHasNoWindow
            ? (resolved?.ink ?? Design.Text.label)
            : (resolved?.inactiveInk ?? Design.Text.secondary)
    }

    /// What the band is painted with under this button — the first stop of the gradient it
    /// sits on, which is what an inverted cell's figure shows through to.
    private func bandGround(of resolved: WindowChromeAppearance.Resolved?) -> NSColor {
        let gradient = isKeyOrHasNoWindow
            ? resolved?.activeGradient
            : resolved?.inactiveGradient
        return gradient?.colors.first ?? Design.Surface.ground
    }

    /// The three glyphs, drawn as shapes rather than set as symbols: the close cross, the
    /// minimize sill, and the zoom frame are *shapes*, and a font's rendition of them varies
    /// with the face the theme chose — the one thing a window button must not do.
    private func drawGlyph(in rect: NSRect, ink: NSColor) {
        let side = min(rect.width, rect.height)
        let glyph = rect.insetBy(
            dx: (rect.width - side) / 2 + side * Glyph.inset,
            dy: (rect.height - side) / 2 + side * Glyph.inset
        )
        let path = NSBezierPath()
        path.lineWidth = Glyph.strokeWidth
        path.lineCapStyle = .butt

        switch role {
        case .windowMenu:
            path.move(to: NSPoint(x: glyph.minX, y: glyph.midY))
            path.line(to: NSPoint(x: glyph.maxX, y: glyph.midY))
        case .close:
            path.move(to: NSPoint(x: glyph.minX, y: glyph.minY))
            path.line(to: NSPoint(x: glyph.maxX, y: glyph.maxY))
            path.move(to: NSPoint(x: glyph.minX, y: glyph.maxY))
            path.line(to: NSPoint(x: glyph.maxX, y: glyph.minY))
        case .minimize:
            path.move(to: NSPoint(x: glyph.minX, y: glyph.minY + Glyph.strokeWidth / 2))
            path.line(to: NSPoint(x: glyph.maxX, y: glyph.minY + Glyph.strokeWidth / 2))
        case .zoom:
            if displaysRestore {
                let side = min(glyph.width, glyph.height) * 0.72
                let front = NSRect(
                    x: glyph.minX,
                    y: glyph.minY,
                    width: side,
                    height: side
                ).insetBy(dx: Glyph.strokeWidth / 2, dy: Glyph.strokeWidth / 2)
                let back = front.offsetBy(
                    dx: glyph.width - side,
                    dy: glyph.height - side
                )
                path.appendRect(back)
                path.appendRect(front)
                path.move(to: NSPoint(x: front.minX, y: front.maxY - Glyph.strokeWidth))
                path.line(to: NSPoint(x: front.maxX, y: front.maxY - Glyph.strokeWidth))
            } else {
                path.appendRect(glyph.insetBy(
                    dx: Glyph.strokeWidth / 2,
                    dy: Glyph.strokeWidth / 2
                ))
                // The heavier lintel is what reads "window" rather than "checkbox" at this size —
                // the frame's own title bar in eight points.
                path.move(to: NSPoint(x: glyph.minX, y: glyph.maxY - Glyph.strokeWidth))
                path.line(to: NSPoint(x: glyph.maxX, y: glyph.maxY - Glyph.strokeWidth))
            }
        case .depth:
            let side = min(glyph.width, glyph.height) * 0.72
            let front = NSRect(x: glyph.minX, y: glyph.minY, width: side, height: side)
                .insetBy(dx: Glyph.strokeWidth / 2, dy: Glyph.strokeWidth / 2)
            let back = front.offsetBy(dx: glyph.width - side, dy: glyph.height - side)
            path.appendRect(back)
            path.appendRect(front)
        }

        ink.setStroke()
        path.stroke()
    }

    // MARK: - Window menu

    private func presentWindowMenu() {
        let menu = makeWindowMenu()
        if let fixtureMenuPresentation {
            fixtureMenuPresentation(menu)
            return
        }
        menuSession = ThemedMenuPresenter.present(
            menu,
            from: self,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
    }

    /// The menu belongs to the semantic role rather than to IRIX: any authored chrome can
    /// expose it, and every item invokes the same window operations as the caption buttons.
    func makeWindowMenuForTesting() -> ThemedMenuPresentation { makeWindowMenu() }

    private func makeWindowMenu() -> ThemedMenuPresentation {
        func item(
            _ title: String,
            enabled: Bool = true,
            action: @escaping () -> Void
        ) -> ThemedMenuEntry {
            .item(ThemedMenuItem(
                title: L10n.string(title),
                isEnabled: enabled,
                onChoose: action
            ))
        }

        let canRestore = window?.isMiniaturized == true || window?.isZoomed == true
        return ThemedMenuPresentation(entries: [
            item("Restore", enabled: canRestore) { [weak self] in self?.restoreFromMenu() },
            .separator,
            item("Minimize") { [weak self] in self?.minimizeFromMenu() },
            item("Maximize") { [weak self] in self?.maximizeFromMenu() },
            .separator,
            item("Close") { [weak self] in self?.closeFromMenu() }
        ], minimumWidth: 148)
    }

    private func restoreFromMenu() {
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        } else if window?.isZoomed == true {
            window?.zoom(nil)
        }
    }

    private func minimizeFromMenu() { window?.miniaturize(nil) }
    private func maximizeFromMenu() {
        guard window?.isZoomed != true else { return }
        window?.zoom(nil)
    }

    private func closeFromMenu() {
        guard let window, window.delegate?.windowShouldClose?(window) ?? true else { return }
        window.close()
    }

    private enum Glyph {
        /// The drawn figure's margin inside the square it is centred in, as a fraction.
        static let inset: CGFloat = 0.28
        static let strokeWidth: CGFloat = 1.5
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }
}
