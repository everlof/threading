import AppKit

/// One of a chrome-takeover window's own buttons: close, minimize, or zoom.
///
/// Exists because a takeover window has no traffic lights — the theme asked for the entire
/// frame, and these three are the frame's working parts. One component for all three roles and
/// every glyph style (`WindowChromeStyle.TitleBar.ButtonGlyphStyle`): a theme picks a style, it
/// never draws its own buttons, and a fourth role or another style arrives here rather than as
/// a sibling class — the tab strip's "every" lesson, applied before there are two.
///
/// The action is the window's own (`performClose` / `performMiniaturize` / `performZoom`), so
/// the button needs no wiring beyond living in a window — and behaves identically for keyboard
/// and accessibility activation, which `ThemedControl` routes through the same press.
final class WindowChromeButton: ThemedControl {

    enum Role: Equatable {
        case close
        case minimize
        case zoom

        var accessibilityLabel: String {
            switch self {
            case .close: L10n.string("Close")
            case .minimize: L10n.string("Minimize")
            case .zoom: L10n.string("Zoom")
            }
        }
    }

    let role: Role

    /// A style stated by a fixture — a gallery story, a render test — instead of resolved
    /// from the active theme. Per instance, so a preview can never dress the real window.
    var fixtureStyle: WindowChromeAppearance.Resolved? {
        didSet { needsDisplay = true }
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: Design.Size.windowButtonWidth, height: Design.Size.windowButtonHeight)
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
        case .close:
            if window.delegate?.windowShouldClose?(window) ?? true {
                window.close()
            }
        case .minimize:
            window.miniaturize(nil)
        case .zoom:
            window.zoom(nil)
        }
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let resolved = fixtureStyle ?? WindowChromeAppearance.resolve()
        let style = resolved?.glyphStyle ?? .plain

        // The squares style *is* pixel art — its plates and glyphs were bitmaps, and every
        // edge in them is one hard pixel. Antialiasing turns those into gray halos, which
        // reads as a soft, faded imitation however correct the colours are. Compared
        // against a real screenshot side by side, this is the single largest difference.
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        if style != .plain {
            NSGraphicsContext.current?.shouldAntialias = false
        }

        let ink: NSColor
        switch style {
        case .squares:
            // A plate in the theme's own control vocabulary, so its glyph reads on the plate
            // rather than on the band. Pressed, the plate darkens the way every themed
            // control's does.
            let fill = isPressed
                ? Design.Surface.controlHover
                : (isHovered ? Design.Surface.elevated : Design.Surface.controlResting)
            ThemedSurface.draw(
                bounds,
                fill: fill,
                border: Design.Surface.border
            )
            ink = Design.Text.label
        case .platinum:
            // Platinum's boxes are the same silver as the band and are separated by their
            // inset edge, not by a coloured fill. Press reverses the edge through the ordinary
            // surface interpreter, preserving the one lighting model used everywhere else.
            ThemedSurface.draw(
                bounds,
                fill: isPressed ? Design.Surface.controlHover : Design.Surface.controlResting,
                border: Design.Surface.border,
                bevel: isPressed ? .sunken : .automatic
            )
            ink = Design.Text.label
        case .beOS:
            // BeOS caption boxes are cut from the tab itself, not from the gray application
            // surface. That shared yellow is what makes them read as part of the tab while the
            // raised edge keeps each operation independently pressable.
            let gradient = isKeyOrHasNoWindow
                ? resolved?.activeGradient
                : resolved?.inactiveGradient
            ThemedSurface.draw(
                bounds,
                fill: gradient?.colors.first ?? Design.Surface.controlResting,
                border: Design.Surface.border,
                bevel: isPressed ? .sunken : .automatic
            )
            ink = isKeyOrHasNoWindow
                ? (resolved?.ink ?? Design.Text.label)
                : (resolved?.inactiveInk ?? Design.Text.secondary)
        case .openStep:
            // OPENSTEP's title controls are gray hardware seated in a black title band.
            // They keep the application material's hard directional light in both key states;
            // only the surrounding band changes when the window resigns key.
            ThemedSurface.draw(
                bounds,
                fill: isPressed ? Design.Surface.controlHover : Design.Surface.controlResting,
                border: Design.Surface.border,
                bevel: isPressed ? .sunken : .automatic
            )
            ink = Design.Text.label
        case .plain:
            // Bare glyphs in the band's own ink, lifted on hover the way a toolbar button is.
            if isHovered || isPressed {
                let bandInk = InkSource.titleBand.ink
                ThemedSurface.draw(
                    bounds,
                    fill: isPressed ? bandInk.surfaceHover : bandInk.surface
                )
            }
            // With no style at all — a fixture under a theme that states no chrome — the
            // glyph takes the label's ink so the component stays visible for review.
            ink = isKeyOrHasNoWindow
                ? (resolved?.ink ?? Design.Text.label)
                : (resolved?.inactiveInk ?? Design.Text.secondary)
        }

        if style == .platinum {
            drawPlatinumGlyph(in: bounds, ink: ink)
        } else if style == .beOS {
            drawBeOSGlyph(in: bounds, ink: ink)
        } else if style == .openStep {
            drawOpenStepGlyph(in: bounds, ink: ink)
        } else {
            drawGlyph(in: bounds, ink: ink, pixelArt: style == .squares)
        }
        drawKeyboardFocus(around: ThemedSurface.Shape(
            rect: bounds,
            radius: Design.Radius.control(fitting: bounds.size)
        ))
    }

    /// A fixture with no window draws its key form; a real band dims with its window.
    private var isKeyOrHasNoWindow: Bool {
        fixtureIsKey ?? (window == nil || window?.isKeyWindow == true)
    }

    /// The three glyphs, drawn as shapes rather than set as symbols: the close cross, the
    /// minimize sill, and the zoom frame are *shapes*, and a font's rendition of them varies
    /// with the face the theme chose — the one thing a window button must not do.
    private func drawGlyph(in rect: NSRect, ink: NSColor, pixelArt: Bool) {
        let side = min(rect.width, rect.height)
        let glyph = rect.insetBy(
            dx: (rect.width - side) / 2 + side * Glyph.inset,
            dy: (rect.height - side) / 2 + side * Glyph.inset
        )
        if pixelArt {
            drawPixelGlyph(in: glyph, ink: ink)
            return
        }

        let path = NSBezierPath()
        path.lineWidth = Glyph.strokeWidth
        path.lineCapStyle = .butt

        switch role {
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
        }

        ink.setStroke()
        path.stroke()
    }

    /// The same three figures built from whole-point rectangles on a snapped grid, which is
    /// what the originals were: the cross is a stair-stepped diagonal, not a smoothed line.
    /// Every coordinate is integral, so with antialiasing off each rectangle lands on exact
    /// device pixels and the figure has no gray in it anywhere.
    private func drawPixelGlyph(in rect: NSRect, ink: NSColor) {
        let size = max(3, floor(min(rect.width, rect.height)))
        let originX = (rect.midX - size / 2).rounded()
        let originY = (rect.midY - size / 2).rounded()
        ink.setFill()

        func dot(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 1, _ height: CGFloat = 1) {
            NSRect(x: originX + x, y: originY + y, width: width, height: height).fill()
        }

        switch role {
        case .close:
            // Two stair-stepped diagonals, each step one point square — the aliased cross
            // the original bitmap draws.
            for step in stride(from: 0, to: size, by: 1) {
                dot(step, step)
                dot(size - 1 - step, step)
            }
        case .minimize:
            // The sill sits on the figure's floor, two points deep, and stops short of the
            // full width the way the original does.
            dot(1, 0, size - 2, 2)
        case .zoom:
            func frame(_ x: CGFloat, _ y: CGFloat, side: CGFloat) {
                dot(x, y, side, 1)
                dot(x, y + side - 1, side, 1)
                dot(x, y, 1, side)
                dot(x + side - 1, y, 1, side)
                dot(x, y + side - 3, side, 2)
            }
            if displaysRestore {
                let windowSide = max(3, size - 2)
                frame(2, 2, side: windowSide)
                frame(0, 0, side: windowSide)
            } else {
                // A window in miniature: a one-point frame under a two-point title bar.
                frame(0, 0, side: size)
            }
        }
    }

    /// The three figures from the Platinum window frame. They are deliberately not the
    /// Windows caption glyphs recoloured: Close is a small inset box, WindowShade is a pair of
    /// rules, and Zoom is the offset-window figure. Whole-point rectangles keep the figures
    /// crisp on the 1× displays the originals targeted.
    private func drawPlatinumGlyph(in rect: NSRect, ink: NSColor) {
        let size: CGFloat = 8
        let originX = (rect.midX - size / 2).rounded()
        let originY = (rect.midY - size / 2).rounded()
        ink.setFill()

        func dot(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 1, _ height: CGFloat = 1) {
            NSRect(x: originX + x, y: originY + y, width: width, height: height).fill()
        }

        func frame(_ x: CGFloat, _ y: CGFloat, side: CGFloat) {
            dot(x, y, side, 1)
            dot(x, y + side - 1, side, 1)
            dot(x, y, 1, side)
            dot(x + side - 1, y, 1, side)
        }

        switch role {
        case .close:
            frame(1, 1, side: 6)
        case .minimize:
            dot(1, 5, 6, 1)
            dot(1, 7, 6, 1)
        case .zoom:
            if displaysRestore {
                frame(2, 2, side: 5)
                frame(0, 0, side: 5)
            } else {
                frame(0, 0, side: 8)
                dot(1, 6, 6, 1)
            }
        }
    }

    /// BeOS's caption figures are tiny bitmap marks inside a raised yellow plate. Close is a
    /// solid stop box; Zoom is the two-level window figure shown at the other end of the tab.
    /// They intentionally do not borrow the Windows cross/maximize alphabet.
    private func drawBeOSGlyph(in rect: NSRect, ink: NSColor) {
        let size: CGFloat = 8
        let originX = (rect.midX - size / 2).rounded()
        let originY = (rect.midY - size / 2).rounded()
        ink.setFill()

        func dot(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 1, _ height: CGFloat = 1) {
            NSRect(x: originX + x, y: originY + y, width: width, height: height).fill()
        }
        func frame(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            dot(x, y, width, 1)
            dot(x, y + height - 1, width, 1)
            dot(x, y, 1, height)
            dot(x + width - 1, y, 1, height)
        }

        switch role {
        case .close:
            dot(2, 2, 4, 4)
        case .minimize:
            dot(1, 1, 6, 2)
        case .zoom:
            if displaysRestore {
                frame(2, 2, 5, 5)
                frame(0, 0, 5, 5)
            } else {
                frame(1, 1, 6, 6)
                dot(2, 5, 4, 1)
            }
        }
    }

    /// OPENSTEP 4.2's two title figures. Miniaturize is a small window nested inside the
    /// control; Close is the sharply aliased diagonal figure from the opposite bookend.
    /// Whole-point rectangles preserve the one-bit workstation drawing instead of turning it
    /// into a modern SF Symbol.
    private func drawOpenStepGlyph(in rect: NSRect, ink: NSColor) {
        let size: CGFloat = 8
        let originX = (rect.midX - size / 2).rounded()
        let originY = (rect.midY - size / 2).rounded()
        ink.setFill()

        func dot(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat = 1, _ height: CGFloat = 1) {
            NSRect(x: originX + x, y: originY + y, width: width, height: height).fill()
        }

        switch role {
        case .minimize:
            // A six-point outer window with a second inset outline.
            dot(1, 1, 6, 1)
            dot(1, 6, 6, 1)
            dot(1, 1, 1, 6)
            dot(6, 1, 1, 6)
            dot(3, 3, 3, 1)
            dot(3, 3, 1, 3)
            dot(3, 5, 3, 1)
            dot(5, 3, 1, 3)
        case .close:
            for step in 0..<6 {
                let point = CGFloat(step + 1)
                dot(point, point)
                dot(7 - point, point)
            }
            // The center of the original mark is heavier than the diagonal tips.
            dot(3, 3, 2, 2)
        case .zoom:
            // OPENSTEP does not normally expose Zoom, but an authored theme may choose to.
            // Use the same nested-window alphabet as its Miniaturize control.
            dot(1, 1, 6, 1)
            dot(1, 6, 6, 1)
            dot(1, 1, 1, 6)
            dot(6, 1, 1, 6)
            dot(2, 5, 4, 1)
        }
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
