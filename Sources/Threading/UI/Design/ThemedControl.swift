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
        let path = (clippingSilhouette ?? shape).inset(by: width / 2).path
        color.setStroke()
        path.lineWidth = width
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
    }

    /// Returns the shape it drew, so a caller can stroke a focus ring on the same shape rather
    /// than rebuilding it from the same three tokens and drifting by half a point.
    @discardableResult
    static func draw(
        _ bounds: NSRect,
        fill: NSColor,
        border: NSColor? = nil,
        radius: CGFloat? = nil
    ) -> Shape {
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
}

// MARK: - Theme Redraw

/// Redraws a view on every theme change — the app theme, and the profile/assignment changes that
/// can move a role too. A view drawn from roles needs nothing more.
///
/// Held separately from `ThemedControl` because not every themed control can inherit from it:
/// `ThemedTextField` has to subclass `NSTextField` for the field editor, the formatter and the
/// whole of text editing. One description of what "follows the theme" means, two bases.
final class ThemeRedraw {

    private let appEvents = AppEventObservations()

    init(_ view: NSView) {
        for observe in [
            { self.appEvents.observe(AppThemeDidChange.self) { [weak view] _ in view?.needsDisplay = true } },
            { self.appEvents.observe(ProfileDidChange.self) { [weak view] _ in view?.needsDisplay = true } },
            {
                self.appEvents.observe(AccessibilityDisplayOptionsDidChange.self) {
                    [weak view] _ in view?.needsDisplay = true
                }
            }
        ] { observe() }
    }
}
