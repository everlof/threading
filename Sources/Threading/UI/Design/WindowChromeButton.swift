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

    override var intrinsicContentSize: NSSize {
        switch (fixtureStyle ?? WindowChromeAppearance.resolve())?.glyphStyle {
        case .squares:
            // The default Win95/98 non-client metrics are not the generic takeover slot:
            // a caption button is 16×14 inside an 18px title bar. The former 18×16 plates
            // were visibly too broad beside the original even before comparing the marks.
            return NSSize(width: 16, height: 14)
        case .amiga:
            // Intuition gadgets consume almost the full 26px title strip. The generic 18×16
            // caption slot made the same figures float in the blue rather than partition it.
            return NSSize(width: 24, height: 22)
        default:
            return NSSize(
                width: Design.Size.windowButtonWidth,
                height: Design.Size.windowButtonHeight
            )
        }
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
                border: Design.Surface.border,
                bevel: isPressed ? .sunken : .automatic
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
        case .irix:
            // 4Dwm seats its caption figures in a gray button with a black outer rule and a
            // softer lit inner edge. A two-point bevel supplies the inner construction; the
            // explicit rule is the workstation outline, not an extra theme-specific surface.
            let fill = isPressed
                ? Design.Surface.controlHover
                : (resolved?.activeGradient.colors.first ?? Design.Surface.controlResting)
            ThemedSurface.draw(
                bounds,
                fill: fill,
                border: Design.Surface.border,
                bevel: isPressed ? .sunken : .automatic
            )
            Design.Surface.border.setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            ink = Design.Text.label
        case .amiga:
            // Intuition's gadgets are cut from the title strip itself. The active blue is
            // therefore both the band and each control's plate; inactive gadgets fall back
            // to the Workbench gray with the rest of the title. Hard black/white bevel edges
            // and one-bit figures do all the separation.
            let gradient = isKeyOrHasNoWindow
                ? resolved?.activeGradient
                : resolved?.inactiveGradient
            ThemedSurface.draw(
                bounds,
                fill: gradient?.colors.first ?? Design.Surface.controlResting,
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

        // Raised bitmap-era controls move their figure with the pressed face. This is one
        // physical-button rule shared by the hard retro families; leaving the glyph behind
        // made the bevel invert while its contents appeared painted on the window.
        let glyphBounds = style != .plain && isPressed
            ? bounds.offsetBy(dx: 1, dy: -1)
            : bounds

        if style == .platinum {
            drawPlatinumGlyph(in: glyphBounds, ink: ink)
        } else if style == .beOS {
            drawBeOSGlyph(in: glyphBounds, ink: ink)
        } else if style == .openStep {
            drawOpenStepGlyph(in: glyphBounds, ink: ink)
        } else if style == .irix {
            drawIRIXGlyph(in: glyphBounds, ink: ink)
        } else if style == .amiga {
            drawAmigaGlyph(in: glyphBounds, ink: ink)
        } else if style == .squares {
            drawWindows98Glyph(in: glyphBounds, ink: ink)
        } else {
            drawGlyph(in: glyphBounds, ink: ink)
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

    /// Win95/98 caption marks reconstructed from the Marlett figures Windows used for its
    /// non-client buttons. This is deliberately *not* the generic vector alphabet above:
    /// Marlett's `r` close mark has two-pixel stair steps, `1` is a nine-pixel window with a
    /// two-pixel title rail, and `0` is a six-by-two sill. The previous seven-point canvas and
    /// single-pixel diagonals were crisp but visibly too small and too light.
    private func drawWindows98Glyph(in rect: NSRect, ink: NSColor) {
        let bitmap = Windows98GlyphArtwork.bitmap(for: role, restored: displaysRestore)
        let width = CGFloat(bitmap.width)
        let height = CGFloat(bitmap.rowsTopToBottom.count)
        // An odd bitmap cannot have equal whole-pixel margins in an even-width button. The
        // originals made the same one-pixel choice; bias top/leading and keep every cell whole.
        let originX = floor(rect.midX - width / 2)
        // Minimize is a short figure inside the same nine-pixel Marlett em as Maximize. Its
        // two rows sit on that cell's floor; centering those two ink rows made it resemble a
        // generic dash instead of the Windows caption sill.
        let originY = floor(rect.midY - CGFloat(bitmap.canvasHeight) / 2)
        ink.setFill()

        for (rowIndex, row) in bitmap.rowsTopToBottom.enumerated() {
            let y = originY + height - 1 - CGFloat(rowIndex)
            var runStart: Int?
            for column in 0...bitmap.width {
                let filled = column < bitmap.width
                    && row[row.index(row.startIndex, offsetBy: column)] == "#"
                if filled, runStart == nil {
                    runStart = column
                } else if !filled, let start = runStart {
                    NSRect(
                        x: originX + CGFloat(start),
                        y: y,
                        width: CGFloat(column - start),
                        height: 1
                    ).fill()
                    runStart = nil
                }
            }
        }
    }

    /// Readable one-bit source artwork, kept internal so component tests can pin the exact
    /// figure rather than merely asserting that some black pixels appeared in the button.
    enum Windows98GlyphArtwork {
        struct Bitmap: Equatable {
            let rowsTopToBottom: [String]
            let canvasHeight: Int

            init(rowsTopToBottom: [String], canvasHeight: Int? = nil) {
                self.rowsTopToBottom = rowsTopToBottom
                self.canvasHeight = canvasHeight ?? rowsTopToBottom.count
            }

            var width: Int { rowsTopToBottom.first?.count ?? 0 }
        }

        static func bitmap(for role: Role, restored: Bool) -> Bitmap {
            switch role {
            case .windowMenu:
                return Bitmap(rowsTopToBottom: ["#######", "#######"])
            case .minimize:
                return Bitmap(
                    rowsTopToBottom: ["######", "######"],
                    canvasHeight: 9
                )
            case .close:
                return Bitmap(rowsTopToBottom: [
                    "##.....##",
                    ".##...##.",
                    "..##.##..",
                    "...###...",
                    "...###...",
                    "..##.##..",
                    ".##...##.",
                    "##.....##"
                ])
            case .zoom where restored:
                return Bitmap(rowsTopToBottom: [
                    "..########",
                    "..########",
                    "..#......#",
                    "########.#",
                    "########.#",
                    "#......#.#",
                    "#......#.#",
                    "#......#..",
                    "########.."
                ])
            case .zoom:
                return Bitmap(rowsTopToBottom: [
                    "#########",
                    "#########",
                    "#.......#",
                    "#.......#",
                    "#.......#",
                    "#.......#",
                    "#.......#",
                    "#.......#",
                    "#########"
                ])
            case .depth:
                return Bitmap(rowsTopToBottom: [
                    "..########",
                    "..#......#",
                    "..#......#",
                    "########.#",
                    "#......#.#",
                    "#......#.#",
                    "#......#..",
                    "########.."
                ])
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
        case .windowMenu:
            dot(1, 3, 6, 2)
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
        case .depth:
            frame(2, 2, side: 5)
            frame(0, 0, side: 5)
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
        case .windowMenu:
            dot(1, 3, 6, 2)
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
        case .depth:
            frame(2, 2, 5, 5)
            frame(0, 0, 5, 5)
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
        case .windowMenu:
            dot(1, 3, 6, 2)
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
        case .depth:
            dot(2, 2, 5, 1)
            dot(2, 6, 5, 1)
            dot(2, 2, 1, 5)
            dot(6, 2, 1, 5)
            dot(0, 0, 5, 1)
            dot(0, 4, 2, 1)
            dot(0, 0, 1, 5)
        }
    }

    /// The deliberately tiny 4Dwm figures visible in original IRIX 6.5 captures: a broad
    /// dash for the Window menu, a two-pixel minimization mark, and an outlined maximize box.
    private func drawIRIXGlyph(in rect: NSRect, ink: NSColor) {
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
        case .windowMenu:
            dot(1, 3, 6, 2)
        case .minimize:
            dot(3, 3, 2, 2)
        case .zoom:
            if displaysRestore {
                frame(2, 2, side: 5)
                frame(0, 0, side: 5)
            } else {
                frame(1, 1, side: 6)
            }
        case .close:
            for step in 1..<7 {
                dot(CGFloat(step), CGFloat(step))
                dot(CGFloat(7 - step), CGFloat(step))
            }
        case .depth:
            frame(2, 2, side: 5)
            frame(0, 0, side: 5)
        }
    }

    /// Workbench 3.1's Intuition gadget alphabet, reconstructed on its original eight-point
    /// grid. Close is the small upright inset lozenge; Zoom is the single recessed window;
    /// Depth is the unmistakable pair of overlapping windows at the far right. The figures
    /// deliberately use black, white, and Workbench gray rather than a modern monochrome icon.
    private func drawAmigaGlyph(in rect: NSRect, ink: NSColor) {
        let size: CGFloat = 10
        let originX = (rect.midX - size / 2).rounded()
        let originY = (rect.midY - size / 2).rounded()

        func fill(_ color: NSColor, _ x: CGFloat, _ y: CGFloat,
                  _ width: CGFloat = 1, _ height: CGFloat = 1) {
            color.setFill()
            NSRect(x: originX + x, y: originY + y, width: width, height: height).fill()
        }

        func window(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            fill(ink, x, y, width, height)
            fill(.white, x + 1, y + 1, width - 2, height - 2)
            fill(Design.Surface.controlResting, x + 2, y + 2, width - 3, height - 3)
        }

        switch role {
        case .windowMenu:
            fill(ink, 2, 4, 6, 2)
        case .close:
            // The original is a narrow upright recess, not a cross or a filled stop box.
            fill(ink, 3, 1, 5, 8)
            fill(.white, 4, 2, 3, 6)
            fill(Design.Surface.controlResting, 5, 3, 2, 5)
        case .minimize:
            // Workbench has no standard minimize gadget, but authored mixtures still need a
            // coherent member of this family.
            fill(ink, 2, 2, 6, 6)
            fill(.white, 3, 3, 4, 4)
            fill(ink, 4, 4, 2, 2)
        case .zoom:
            window(1, 1, 8, 8)
            fill(ink, 5, 5, 3, 3)
            fill(.white, 5, 6, 2, 1)
        case .depth:
            window(1, 3, 7, 6)
            window(3, 1, 7, 6)
        }
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
