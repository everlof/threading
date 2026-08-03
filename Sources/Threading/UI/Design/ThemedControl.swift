import AppKit

/// The base for a control that draws itself from the theme rather than from AppKit's stock
/// chrome.
///
/// This exists because of a lesson learned the hard way: a stock `NSSwitch`, `NSPopUpButton` or
/// `NSButton` bakes in the *system* accent and bezel, so under an app style it stays
/// system-blue on a page that has gone red or neon — the theme reaches the cards around it and
/// stops at the control. The design system's rule ("built from `UI/Design/`, not stock AppKit")
/// was already written; this is the machinery that lets it actually hold, and a lint rule keeps
/// raw controls out of the rest of the app so it cannot quietly erode again.
///
/// **Draws in `draw(_:)`, never into a frozen layer.** That is the second half of the lesson:
/// `layer.backgroundColor = colour.cgColor` resolves once and keeps that value, so a live theme
/// switch left stale colours all over the app. A `ThemedControl` reads its roles at *draw
/// time* — where a dynamic colour resolves correctly — and a theme change is answered by a
/// single `needsDisplay = true`. Nothing to record, nothing to re-apply, nothing to freeze.
///
/// Subclasses override `layout()`/`draw(_:)` and read `Design.*`. The only obligation is to
/// draw from roles; the redraw-on-change is handled here.
///
/// No explicit `@MainActor`: `NSControl` already carries it from the SDK, and adding it again
/// over-isolates the control's own properties relative to the plain `SettingsUI` helpers that
/// build these.
class ThemedControl: NSControl, ThemedComponent {

    private var themeRedraw: ThemeRedraw?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Themed controls draw their own appearance top to bottom, so the layer-backed view never
    /// needs the extra pass AppKit would otherwise take.
    override var wantsUpdateLayer: Bool { false }

    /// Keyboard access is part of the base contract, not something each drawn control may
    /// remember independently. A disabled control leaves the key-view loop just like AppKit's.
    override var acceptsFirstResponder: Bool { isEnabled }

    var hasKeyboardFocus: Bool {
        window?.firstResponder === self
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled, hasKeyboardFocus {
                window?.makeFirstResponder(nil)
            }
            needsDisplay = true
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }

    // MARK: - Hover

    /// Whether the pointer is on this control.
    ///
    /// **Owned here because six controls had each written the same three members** — a
    /// `trackingArea`, an `isHovered`, an `updateTrackingAreas` — and so carried the same bug six
    /// times over: a tracking area reports what the *pointer* did, so a control that moves out
    /// from under a stationary pointer is never told it was left and stays lit. See
    /// `NSView.isPointerInside` for how that reaches the screen. One implementation is also what
    /// stops the seventh control from being the one that forgot.
    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hoverDidChange()
        }
    }

    /// Answered when the pointer arrives or leaves. The default redraw is what a control drawing
    /// its own hover fill needs; a control that hovers by moving a layer or a constraint overrides
    /// this instead of watching the flag itself.
    func hoverDidChange() {
        needsDisplay = true
    }

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area

        // Tracking is rebuilt exactly when this view's geometry changed, which is the moment a
        // hover can have gone stale without the pointer moving at all.
        if hoverIsStale(isHovered) {
            isHovered = false
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            super.keyDown(with: event)
            return
        }

        switch event.charactersIgnoringModifiers {
        case " ", "\r":
            if !performPrimaryAction() {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// Subclasses route keyboard activation through the same semantic action as pointer and
    /// accessibility activation. Returning false lets AppKit continue handling the key.
    func performPrimaryAction() -> Bool {
        guard action != nil else { return false }
        sendAction(action, to: target)
        return true
    }

    /// Strokes the focus ring *inside* the control's own silhouette.
    ///
    /// Both halves of that sentence were bugs. A stroke is centred on its path, so a ring drawn
    /// on the surface's own edge puts half its width outside the control — and drawing is
    /// clipped there, so the ring came out at half weight everywhere. Worse where the silhouette
    /// is not the one the caller drew: `applySurface` puts the corner on the *layer*, and a
    /// layer corner clips what `draw(_:)` lays down, so the accounts pane's 30pt icon well —
    /// a disc — cut a rounded-rect ring down to four 1pt dashes at the edge midpoints, which is
    /// what a broken circle looks like. Insetting by half the width, on the shape that actually
    /// clips, is what makes one ring appear at full weight on every control.
    func drawKeyboardFocus(around shape: ThemedSurface.Shape, color: NSColor = Design.Surface.accent) {
        guard hasKeyboardFocus else { return }
        let width = Design.Accessibility.focusRingWidth
        strokeFocusRing((clippingSilhouette ?? shape).inset(by: width / 2), color)
    }

    /// Strokes the ring *outside* the silhouette, holding `gap` clear between the two.
    ///
    /// The ring above assumes a control has slack between its edge and whatever it draws inside
    /// it. `ThemedToggle` has none: its knob is inset by exactly the ring's width, so an inside
    /// ring lands on the entire gutter and the knob comes out flush against it, with the track's
    /// own colour gone from three sides — and what survives at each knob corner is the wedge
    /// between the knob's arc and the ring's inner edge, four accent specks in a control that
    /// otherwise has no accent left to show.
    ///
    /// A caller taking this overload has reserved `gap + focusRingWidth` of its own bounds
    /// outside `shape`, because drawing is clipped there: a ring stroked into room that was not
    /// reserved comes back at partial weight or not at all. `clippingSilhouette` is deliberately
    /// not consulted — an applied surface *is* the clip, so there is no outside to draw in.
    func drawKeyboardFocus(
        around shape: ThemedSurface.Shape,
        color: NSColor = Design.Surface.accent,
        outsideBy gap: CGFloat
    ) {
        guard hasKeyboardFocus else { return }
        strokeFocusRing(shape.outset(by: gap + Design.Accessibility.focusRingWidth / 2), color)
    }

    private func strokeFocusRing(_ shape: ThemedSurface.Shape, _ color: NSColor) {
        let path = shape.path
        color.setStroke()
        path.lineWidth = Design.Accessibility.focusRingWidth
        path.stroke()
    }

    /// The shape clipping this control's drawing when its surface was *applied* rather than
    /// drawn. Nil when nothing was applied, where what the caller drew is the silhouette.
    private var clippingSilhouette: ThemedSurface.Shape? {
        guard let radius = appliedSurfaceRadius, radius > 0 else { return nil }
        return ThemedSurface.Shape(rect: bounds, radius: radius)
    }

    /// A stock control is an accessibility element because its *cell* is; a control that draws
    /// itself has no cell, so it has to say so. Without this a themed control is invisible to
    /// VoiceOver and to UI scripting alike — which is also how this was noticed, a settings page
    /// reporting no pop-up buttons on a page that visibly has one.
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
}

// MARK: - Surface

/// The fill and hairline every themed control sits on, drawn rather than applied.
///
/// The draw-time counterpart of `applySurface`, and the reason both exist: `applySurface` sets a
/// `cgColor` on a layer, which resolves once and freezes — fine for a container rebuilt on a
/// theme change, wrong for a control that must survive a live switch.
@MainActor
enum ThemedSurface {

    /// The silhouette a surface was drawn as: a rect and the corner it was given.
    ///
    /// Returned instead of the `NSBezierPath` itself because the ring that follows a surface has
    /// to be *inset* from it, and a path cannot be inset — only rebuilt, which is the caller
    /// re-deriving the same three tokens and drifting by half a point.
    struct Shape {
        let rect: NSRect
        let radius: CGFloat

        var path: NSBezierPath {
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }

        /// The same silhouette pulled inwards, corners kept concentric: a disc stays a disc and
        /// a squared theme's rect stays square, where holding the radius would leave a ring
        /// bulging out of the shape it belongs to.
        func inset(by amount: CGFloat) -> Shape {
            Shape(
                rect: rect.insetBy(dx: amount, dy: amount),
                radius: max(0, radius - amount)
            )
        }

        /// The mirror of `inset`, for a ring drawn *around* a silhouette rather than inside it.
        ///
        /// A squared theme's rect stays square for the same reason it does on the way in: the
        /// true offset curve of a sharp corner is a round one, but a hard-cornered theme wants a
        /// hard-cornered ring, and the ring exists to restate the shape it surrounds.
        func outset(by amount: CGFloat) -> Shape {
            Shape(
                rect: rect.insetBy(dx: -amount, dy: -amount),
                radius: radius > 0 ? radius + amount : 0
            )
        }
    }

    /// Returns the shape it drew, so a caller can stroke a focus ring on the same shape rather
    /// than rebuilding it from the same three tokens and drifting by half a point.
    @discardableResult
    static func draw(
        _ bounds: NSRect,
        fill: NSColor,
        border: NSColor? = nil,
        radius: CGFloat? = nil,
        bevel: SurfaceBevel = .automatic
    ) -> Shape {
        // A bevel material bevels the drawn controls too — this is the draw-time half of
        // `applySurface`'s interpretation, under the same rules: participation stated by the
        // call site, square corners only, and the bevel replaces the flat border. A surface
        // that draws *nothing* — a resting icon button's clear fill, no border — stays
        // nothing: the period toolbar button is flat until the pointer arrives, and a bevel
        // ring around empty air read as a plate nobody drew.
        if let spec = AppThemePalette.current.material.bevel,
           bevel != .none,
           fill.alphaComponent > 0 || border != nil,
           (radius ?? Design.Radius.control(fitting: bounds.size)) == 0 {
            return drawBevelled(
                bounds,
                fill: fill,
                edgeWidth: spec.width,
                sunken: bevel == .sunken
            )
        }

        let width = Design.Radius.border
        // Half a point in, so a one-point border falls inside the control rather than straddling
        // its edge and drawing at half intensity.
        let rect = border == nil ? bounds : bounds.insetBy(dx: width / 2, dy: width / 2)
        // Fitted to the shape being drawn, so one token cannot produce a rounded square in one
        // control and a disc in the small one beside it — see `Design.Radius.control(fitting:)`.
        let corner = radius ?? Design.Radius.control(fitting: rect.size)
        let shape = Shape(rect: rect, radius: corner)
        let path = shape.path

        fill.setFill()
        path.fill()

        if let border {
            border.setStroke()
            path.lineWidth = width
            path.stroke()
        }
        return shape
    }

    /// The classic construction, at draw time — `BevelArtwork`'s two square-cornered rings,
    /// painted as exact edge rects so a translucent fill (a tab's 14% lift) never has an
    /// opaque construction bleeding through it. Which way is "up" is asked of the context, so
    /// the light always comes from the window's top-leading corner whether or not the view
    /// is flipped.
    private static func drawBevelled(
        _ bounds: NSRect,
        fill: NSColor,
        edgeWidth: CGFloat,
        sunken: Bool
    ) -> Shape {
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        let colors = BevelArtwork.edgeColors(
            highlight: Design.Surface.bevelHighlight,
            shadow: Design.Surface.bevelShadow,
            sunken: sunken
        )
        let widths = BevelArtwork.ringWidths(for: edgeWidth)

        // A bevel is pixel art: every edge is a hard line, and an antialiased one is a gray
        // halo that reads as a faded imitation of the real thing however right the colours
        // are. Off for the whole construction, restored before anything else draws.
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false

        fill.setFill()
        bounds.insetBy(dx: edgeWidth, dy: edgeWidth).fill()

        func ring(_ rect: NSRect, width: CGFloat, topLeft: NSColor, bottomRight: NSColor) {
            guard width > 0 else { return }
            let visualTopY = flipped ? rect.minY : rect.maxY - width
            let visualBottomY = flipped ? rect.maxY - width : rect.minY
            // The dark side owns both mixed corners: its column runs the full height, its
            // row the full width — the square meeting that reads as an edge, where a mitre
            // read as a cast shadow.
            bottomRight.setFill()
            NSRect(x: rect.maxX - width, y: rect.minY,
                   width: width, height: rect.height).fill()
            NSRect(x: rect.minX, y: visualBottomY,
                   width: rect.width, height: width).fill()
            topLeft.setFill()
            NSRect(x: rect.minX, y: visualTopY,
                   width: rect.width - width, height: width).fill()
            NSRect(x: rect.minX, y: flipped ? rect.minY : rect.minY + width,
                   width: width, height: rect.height - width).fill()
        }

        ring(bounds, width: widths.outer,
             topLeft: colors.topLeftOuter, bottomRight: colors.bottomRightOuter)
        ring(bounds.insetBy(dx: widths.outer, dy: widths.outer), width: widths.inner,
             topLeft: colors.topLeftInner, bottomRight: colors.bottomRightInner)

        return Shape(rect: bounds, radius: 0)
    }
}

// MARK: - Theme Redraw

/// Restyles a view on every theme change — the app theme, and the profile/assignment changes that
/// can move a role too. A view drawn from roles needs nothing more.
///
/// Held separately from `ThemedControl` because not every themed control can inherit from it:
/// `ThemedTextField` has to subclass `NSTextField` for the field editor, the formatter and the
/// whole of text editing. One description of what "follows the theme" means, two bases.
@MainActor
final class ThemeRedraw {

    private let appEvents = AppEventObservations()

    init(_ view: NSView) {
        for observe in [
            { self.appEvents.observe(AppThemeDidChange.self) { [weak view] _ in view?.restyle() } },
            { self.appEvents.observe(ProfileDidChange.self) { [weak view] _ in view?.restyle() } },
            {
                self.appEvents.observe(AccessibilityDisplayOptionsDidChange.self) {
                    [weak view] _ in view?.restyle()
                }
            }
        ] { observe() }
    }
}

private extension NSView {

    /// A theme states sizes as well as colours, so following it is a redraw **and** a remeasure.
    ///
    /// A themed view whose `intrinsicContentSize` reads a token — `SeparatorView`'s thickness is
    /// `Design.Radius.border`, the same token the split seam weighs itself with — is placed against
    /// the size the constraint system last *asked* for, and AppKit caches that until it is told the
    /// answer moved. Repainting alone left every rule in the window ruling for the theme that had
    /// just left, while anything built after the switch took the new weight: arriving at Editorial
    /// (1) from Neo Brutalism (3), one window drew hairlines and 3-point rules at once. The seam
    /// itself was already right — `dividerThickness` is computed per read — which is exactly why
    /// the mismatch survived being fixed there.
    ///
    /// Invalidating for views that state no intrinsic size costs nothing: `noIntrinsicMetric`
    /// re-read is still `noIntrinsicMetric`, and a theme change is a rare, user-driven event.
    func restyle() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}
