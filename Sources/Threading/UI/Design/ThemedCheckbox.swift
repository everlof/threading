import AppKit

/// A drawn checkbox: box, mark and title as one full-width target, with hover, press, keyboard,
/// VoiceOver, and drag-out cancellation.
///
/// Extracted from `ThemedAlert`'s suppression row the day a list needed per-row selection: the
/// alert's "don't ask again" and an import list's "include this one" are the same control, and a
/// second drawing of it would be the duplication the theme boundary exists to prevent. Beyond
/// the alert's needs it adds `.mixed`, for a group row summarising children that disagree —
/// activating a mixed box selects everything, which is macOS's own reading of that state.
@MainActor
final class ThemedCheckbox: ThemedControl {
    private enum Layout {
        static let modernBox: CGFloat = 16
        /// Win32, Platinum, Intuition and the workstation widget sets all use the compact
        /// thirteen-pixel square inherited from their native control metrics. Leaving the
        /// modern sixteen-point box in those dense rows made the checkbox taller than Topaz.
        static let historicalBox: CGFloat = 13
        static let gap: CGFloat = Design.Spacing.small
        static let inset: CGFloat = Design.Spacing.tight
        static let markPointSize: CGFloat = 10
        static let markInset: CGFloat = 3

        /// Between the box and the ring around it — `ThemedToggle`'s gap, for the same reason a
        /// ring needs one: a ring flush against a shape reads as that shape's own border grown
        /// thicker rather than as something the keyboard did.
        static let focusGap: CGFloat = Design.Spacing.hairline
    }

    /// The room the box is given before the title, and never less than its ring needs.
    ///
    /// A checked box is filled with the accent, so a ring drawn *inside* it was the accent on
    /// the accent — nothing at all, in every theme, which is what a checked checkbox showed
    /// about where the keyboard was. Ringing it from outside is the only treatment that reads
    /// the same in all three states, and drawing is clipped to `bounds`, so the room has to be
    /// reserved rather than assumed.
    ///
    /// Read at measure *and* draw time rather than stated as a constant, because
    /// `focusRingWidth` grows under Increase Contrast; `ThemeRedraw` answers that notification
    /// with `invalidateIntrinsicContentSize()`, so the reserved margin follows it. The ordinary
    /// case is the scale's own step, unchanged.
    private var boxInset: CGFloat {
        max(Layout.inset, Layout.focusGap + Design.Accessibility.focusRingWidth)
    }

    private var checkboxStyle: AppTheme.Material.CheckboxStyle {
        let material = AppThemePalette.current.material(for: effectiveAppearance)
        guard material.checkboxStyle == .automatic else { return material.checkboxStyle }
        // Documents written before `checkboxStyle` existed already received the square
        // recessed gadget under a hard historical material. Preserve that rendering exactly;
        // new source-backed themes state their family explicitly.
        return material.controlRadius == 0 && material.bevel != nil
            ? .recessedTick
            : .automatic
    }

    private var usesHistoricalGadget: Bool { checkboxStyle != .automatic }

    private var boxSize: CGFloat {
        usesHistoricalGadget ? Layout.historicalBox : Layout.modernBox
    }

    let title: String

    /// Settable so a group row can follow its children. User activation never *produces*
    /// `.mixed` — it cycles mixed → on and on ↔ off; mixed only arrives from data.
    var state: NSControl.StateValue {
        didSet {
            guard state != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Spoken title when the drawn one is empty or abbreviated — a bare box in a table row
    /// still has to say what it includes.
    private let accessibilityOverride: String?
    private let changed: (NSControl.StateValue) -> Void
    private var isPressed = false { didSet { needsDisplay = true } }

    init(
        title: String,
        state: NSControl.StateValue = .off,
        accessibility: String? = nil,
        changed: @escaping (NSControl.StateValue) -> Void
    ) {
        self.title = title
        self.state = state
        self.accessibilityOverride = accessibility
        self.changed = changed
        super.init(frame: .zero)
        if !title.isEmpty {
            toolTip = title
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        guard !title.isEmpty else {
            return NSSize(width: boxInset * 2 + boxSize, height: Design.Size.chipHeight)
        }
        let width = ceil(title.size(withAttributes: [.font: Design.Typography.controlRegular()]).width)
        return NSSize(
            width: boxInset * 2 + boxSize + Layout.gap + width,
            height: Design.Size.chipHeight
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
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

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        state = state == .on ? .off : .on
        changed(state)
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityTitle() -> String? { accessibilityOverride ?? title }

    /// The checkbox convention: 0 off, 1 on, 2 mixed. A Bool cannot say "some".
    override func accessibilityValue() -> Any? {
        switch state {
        case .on: 1
        case .mixed: 2
        default: 0
        }
    }

    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    override func draw(_ dirtyRect: NSRect) {
        if !usesHistoricalGadget, isEnabled, isHovered || isPressed {
            ThemedSurface.draw(
                bounds,
                fill: isPressed ? Design.Surface.controlHover : Design.Surface.controlResting,
                radius: Design.Radius.control
            )
        }

        let box = NSRect(
            x: floor(boxInset),
            y: floor((bounds.height - boxSize) / 2),
            width: boxSize,
            height: boxSize
        )
        let filled = state != .off
        let corner: CGFloat
        if usesHistoricalGadget {
            corner = 0
            let historicalFill: NSColor = if !isEnabled, checkboxStyle == .beOSCross {
                Design.Surface.controlHover
            } else if !isEnabled, checkboxStyle == .windows98Tick {
                Design.Surface.controlResting
            } else {
                Design.Surface.field
            }
            ThemedSurface.draw(
                box,
                fill: historicalFill,
                radius: 0,
                bevel: checkboxStyle == .beOSCross
                    ? .sunken
                    : (isPressed ? .automatic : .sunken)
            )
            if filled {
                switch checkboxStyle {
                case .beOSCross:
                    drawBeOSCross(in: box, mixed: state == .mixed)
                case .recessedTick, .windows98Tick, .automatic:
                    if checkboxStyle == .windows98Tick {
                        drawWindows98Tick(in: box, mixed: state == .mixed)
                    } else {
                        drawHistoricalTick(in: box, mixed: state == .mixed)
                    }
                }
            }
        } else {
            corner = Design.Radius.control(fitting: box.size)
            ThemedSurface.draw(
                box,
                fill: filled ? Design.Surface.accent : Design.Surface.controlResting,
                border: filled ? nil : Design.Surface.border,
                radius: corner
            )
            let markName = state == .mixed ? "minus" : "checkmark"
            if filled,
               let mark = NSImage(systemSymbolName: markName, accessibilityDescription: nil)?
                .withSymbolConfiguration(Design.Symbol.configuration(
                    Layout.markPointSize,
                    weight: .semibold
                )) {
                TemplateImageDrawing.draw(
                    mark,
                    in: box.insetBy(dx: Layout.markInset, dy: Layout.markInset),
                    tint: isEnabled ? Design.Text.selected : Design.Text.tertiary
                )
            }
        }
        // Around the box rather than on it, and from the box itself rather than from what the
        // fill returned: a bordered shape is drawn half a point in, and a ring that followed
        // that would sit half a point closer to a clear box than to a checked one.
        drawKeyboardFocus(
            around: ThemedSurface.Shape(rect: box, radius: corner),
            outsideBy: Layout.focusGap
        )

        guard !title.isEmpty else { return }
        let font = Design.Typography.controlRegular()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isEnabled ? Design.Text.label : Design.Text.tertiary
        ]
        let x = box.maxX + Layout.gap
        // The line box, so the words share the box's own centre. Sized from
        // `boundingRectForFont` the label rode above its checkbox by whatever the family
        // reserves beyond the line it lays out — nothing under SF, four points under Geneva.
        let height = Design.Typography.lineHeight(of: font)
        withHistoricalRasterization {
            (title as NSString).draw(
                in: NSRect(
                    x: x,
                    y: bounds.midY - height / 2,
                    width: max(0, bounds.maxX - x),
                    height: height
                ),
                withAttributes: attributes
            )
        }
    }

    private func drawHistoricalTick(in box: NSRect, mixed: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        let ink = isEnabled ? Design.Text.label : Design.Surface.bevelShadow
        ink.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .square
        path.lineJoinStyle = .miter
        if mixed {
            path.move(to: NSPoint(x: box.minX + 3, y: box.midY))
            path.line(to: NSPoint(x: box.maxX - 3, y: box.midY))
        } else {
            path.move(to: NSPoint(x: box.minX + 3, y: box.midY))
            path.line(to: NSPoint(x: box.minX + 5, y: box.minY + 3))
            path.line(to: NSPoint(x: box.maxX - 2, y: box.maxY - 3))
        }
        path.stroke()
    }

    /// 98.css's checked glyph is a seven-by-seven bitmap, positioned three pixels into the
    /// thirteen-pixel field. Keeping its descending one-pixel staircase avoids the soft diagonal
    /// a stroked Bezier introduces at the exact size where Win32's checkmark was designed to read.
    private func drawWindows98Tick(in box: NSRect, mixed: Bool) {
        guard !mixed else {
            drawHistoricalTick(in: box, mixed: true)
            return
        }
        let rows = [
            "......K",
            ".....KK",
            "K...KKK",
            "KK.KKK.",
            "KKKKK..",
            ".KKK...",
            "..K...."
        ]
        let ink = isEnabled ? Design.Text.label : Design.Surface.bevelShadow
        ink.setFill()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        for (row, value) in rows.enumerated() {
            for (column, glyph) in value.enumerated() where glyph == "K" {
                let y = flipped
                    ? box.minY + 3 + CGFloat(row)
                    : box.maxY - 4 - CGFloat(row)
                NSRect(
                    x: box.minX + 3 + CGFloat(column),
                    y: y,
                    width: 1,
                    height: 1
                ).fill()
            }
        }
    }

    /// Haiku's MIT-licensed `BeControlLook::DrawCheckBox` preserves the R5 figure: after the
    /// nested white well is drawn it insets four pixels, uses a two-pixel square pen, and crosses
    /// both diagonals in the system control-mark colour. It is an X, not the tick shared by the
    /// other hard historical materials.
    private func drawBeOSCross(in box: NSRect, mixed: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext.current else { return }
        context.shouldAntialias = false
        context.cgContext.setShouldAntialias(false)
        let ink = isEnabled
            ? Design.Surface.accent
            : Design.Surface.accent.withAlphaComponent(0.38)
        ink.setStroke()
        let mark = box.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .square
        if mixed {
            path.move(to: NSPoint(x: mark.minX, y: mark.midY))
            path.line(to: NSPoint(x: mark.maxX, y: mark.midY))
        } else {
            path.move(to: NSPoint(x: mark.minX, y: mark.minY))
            path.line(to: NSPoint(x: mark.maxX, y: mark.maxY))
            path.move(to: NSPoint(x: mark.minX, y: mark.maxY))
            path.line(to: NSPoint(x: mark.maxX, y: mark.minY))
        }
        path.stroke()
    }

    private func withHistoricalRasterization(_ draw: () -> Void) {
        let material = AppThemePalette.current.material(for: effectiveAppearance)
        guard !material.buttonStyle.antialiasesTitle,
              let context = NSGraphicsContext.current else {
            draw()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.shouldAntialias = false
        context.cgContext.setShouldAntialias(false)
        context.cgContext.setAllowsAntialiasing(false)
        context.cgContext.setShouldSmoothFonts(false)
        context.cgContext.setAllowsFontSmoothing(false)
        draw()
    }
}

/// A mutually-exclusive option mark drawn from the same period field vocabulary as
/// `ThemedCheckbox`.
///
/// Win98's 98.css keeps radio fields separate from checkboxes: the well is a compact twelve-pixel
/// circle and selection is a four-pixel dot, not a tick. Keeping this as a sibling rather than
/// teaching the checkbox a second semantic role lets accessibility clients, keyboard navigation,
/// and callers say which kind of choice they are presenting.
@MainActor
final class ThemedRadioButton: ThemedControl {
    private enum Layout {
        static let modernBox: CGFloat = 16
        static let historicalBox: CGFloat = 12
        static let gap: CGFloat = Design.Spacing.small
        static let inset: CGFloat = Design.Spacing.tight
        static let markInset: CGFloat = 4
        static let focusGap: CGFloat = Design.Spacing.hairline
    }

    private var checkboxStyle: AppTheme.Material.CheckboxStyle {
        let material = AppThemePalette.current.material(for: effectiveAppearance)
        guard material.checkboxStyle == .automatic else { return material.checkboxStyle }
        return material.controlRadius == 0 && material.bevel != nil
            ? .recessedTick
            : .automatic
    }

    private var usesHistoricalGadget: Bool { checkboxStyle != .automatic }
    private var boxSize: CGFloat { usesHistoricalGadget ? Layout.historicalBox : Layout.modernBox }

    let title: String
    var state: NSControl.StateValue {
        didSet {
            guard state != oldValue else { return }
            needsDisplay = true
        }
    }

    private let accessibilityOverride: String?
    private let changed: (NSControl.StateValue) -> Void
    private var isPressed = false { didSet { needsDisplay = true } }

    init(
        title: String,
        state: NSControl.StateValue = .off,
        accessibility: String? = nil,
        changed: @escaping (NSControl.StateValue) -> Void
    ) {
        self.title = title
        self.state = state
        self.accessibilityOverride = accessibility
        self.changed = changed
        super.init(frame: .zero)
        if !title.isEmpty { toolTip = title }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var boxInset: CGFloat {
        max(Layout.inset, Layout.focusGap + Design.Accessibility.focusRingWidth)
    }

    override var intrinsicContentSize: NSSize {
        guard !title.isEmpty else {
            return NSSize(width: boxInset * 2 + boxSize, height: Design.Size.chipHeight)
        }
        let width = ceil(title.size(withAttributes: [.font: Design.Typography.controlRegular()]).width)
        return NSSize(
            width: boxInset * 2 + boxSize + Layout.gap + width,
            height: Design.Size.chipHeight
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
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

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        guard state != .on else { return true }
        state = .on
        changed(state)
        NSAccessibility.post(element: self, notification: .valueChanged)
        return true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityTitle() -> String? { accessibilityOverride ?? title }
    override func accessibilityValue() -> Any? { state == .on }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    override func draw(_ dirtyRect: NSRect) {
        if !usesHistoricalGadget, isEnabled, isHovered || isPressed {
            ThemedSurface.draw(
                bounds,
                fill: isPressed ? Design.Surface.controlHover : Design.Surface.controlResting,
                radius: Design.Radius.control
            )
        }

        let box = NSRect(
            x: floor(boxInset),
            y: floor((bounds.height - boxSize) / 2),
            width: boxSize,
            height: boxSize
        )
        let selected = state == .on
        let shape: ThemedSurface.Shape
        if checkboxStyle == .windows98Tick {
            drawWindows98Radio(in: box, selected: selected)
            shape = ThemedSurface.Shape(rect: box, radius: boxSize / 2)
        } else if usesHistoricalGadget {
            let fill: NSColor = isEnabled ? Design.Surface.field : Design.Surface.controlResting
            shape = ThemedSurface.draw(
                box,
                fill: fill,
                border: Design.Surface.bevelShadow,
                radius: boxSize / 2,
                bevel: .none
            )
            if selected { drawHistoricalDot(in: box) }
        } else {
            shape = ThemedSurface.draw(
                box,
                fill: Design.Surface.controlResting,
                border: Design.Surface.border,
                radius: boxSize / 2
            )
            if selected { drawModernDot(in: box) }
        }
        drawKeyboardFocus(
            around: shape,
            outsideBy: Layout.focusGap
        )

        guard !title.isEmpty else { return }
        let font = Design.Typography.controlRegular()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isEnabled ? Design.Text.label : Design.Text.tertiary
        ]
        let height = Design.Typography.lineHeight(of: font)
        withHistoricalRasterization {
            (title as NSString).draw(
                in: NSRect(
                    x: box.maxX + Layout.gap,
                    y: bounds.midY - height / 2,
                    width: max(0, bounds.maxX - box.maxX - Layout.gap),
                    height: height
                ),
                withAttributes: attributes
            )
        }
    }

    private func drawModernDot(in box: NSRect) {
        let dot = box.insetBy(dx: Layout.markInset, dy: Layout.markInset)
        (isEnabled ? Design.Surface.accent : Design.Surface.bevelShadow).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    private func drawHistoricalDot(in box: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
        let dot = box.insetBy(dx: Layout.markInset, dy: Layout.markInset)
        let ink = checkboxStyle == .beOSCross && isEnabled
            ? Design.Surface.accent
            : (isEnabled ? Design.Text.label : Design.Surface.bevelShadow)
        ink.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    /// The pinned 98.css radio assets are deliberately tiny indexed sprites. A generic rounded
    /// path gives Core Graphics permission to anti-alias the 12px edge and loses the four visible
    /// Win32 rails (gray/black on the upper-left, #DFDFDF/white on the lower-right). Keep the
    /// source's 12 rows as a palette grid so the result stays a device-pixel construction at 1×.
    /// `G/K/W/D` mean shadow, frame, highlight, and the button-face sheen respectively; the
    /// disabled variant maps the ink through the same control roles rather than inventing a
    /// second theme colour.
    private func drawWindows98Radio(in box: NSRect, selected: Bool) {
        let rows = [
            "....GGGG....",
            "..GGKKKKGG..",
            ".GKKWWWWKKW.",
            ".GKWWWWWWDW.",
            "GKWWWWWWWWDW",
            "GKWWWWWWWWDW",
            "GKWWWWWWWWDW",
            "GKWWWWWWWWDW",
            ".GKWWWWWWDW.",
            ".GDDWWWWDDW.",
            "..WWDDDDWW..",
            "....WWWW...."
        ]
        let enabled = isEnabled
        let shadow = enabled ? Design.Surface.bevelShadow : Design.Surface.controlResting
        let frame = enabled ? Design.Text.label : Design.Surface.bevelShadow
        let highlight = enabled ? Design.Surface.bevelHighlight : Design.Surface.controlHover
        let sheen = enabled
            ? Design.Surface.bevelHighlight.lightened(by: -0.125)
            : Design.Surface.controlHover

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        for (row, value) in rows.enumerated() {
            for (column, glyph) in value.enumerated() {
                let color: NSColor? = switch glyph {
                case "G": shadow
                case "K": frame
                case "W": highlight
                case "D": sheen
                default: nil
                }
                guard let color else { continue }
                color.setFill()
                let y = flipped
                    ? box.minY + CGFloat(row)
                    : box.maxY - CGFloat(row + 1)
                NSRect(
                    x: box.minX + CGFloat(column),
                    y: y,
                    width: 1,
                    height: 1
                ).fill()
            }
        }

        guard selected else { return }
        let dotRows = [".KK.", "KKKK", "KKKK", ".KK."]
        let dotInk = enabled ? Design.Text.label : Design.Surface.bevelShadow
        dotInk.setFill()
        let dotOrigin = NSPoint(
            x: box.minX + 4,
            y: flipped ? box.minY + 4 : box.maxY - 8
        )
        for (row, value) in dotRows.enumerated() {
            for (column, glyph) in value.enumerated() where glyph == "K" {
                let y = flipped
                    ? dotOrigin.y + CGFloat(row)
                    : dotOrigin.y + CGFloat(3 - row)
                NSRect(
                    x: dotOrigin.x + CGFloat(column),
                    y: y,
                    width: 1,
                    height: 1
                ).fill()
            }
        }
    }

    private func withHistoricalRasterization(_ draw: () -> Void) {
        let material = AppThemePalette.current.material(for: effectiveAppearance)
        guard !material.buttonStyle.antialiasesTitle,
              let context = NSGraphicsContext.current else {
            draw()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.shouldAntialias = false
        context.cgContext.setShouldAntialias(false)
        context.cgContext.setAllowsAntialiasing(false)
        context.cgContext.setShouldSmoothFonts(false)
        context.cgContext.setAllowsFontSmoothing(false)
        draw()
    }
}
