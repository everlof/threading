import AppKit

/// A switch drawn from the theme, replacing `NSSwitch`.
///
/// `NSSwitch` takes the *system* accent for its on-state, which is the single most visible way a
/// styled app betrays that its theme is only skin deep — a page of system-blue switches on a
/// Cyberpunk-green or Swiss-red surface. This draws the on-track in the theme's own accent.
///
/// A drop-in for the call sites it replaces: it is an `NSControl` with the same `state`
/// property and the same target/action, so `toggle.state == .on` and the action selector keep
/// working unchanged.
final class ThemedToggle: ThemedControl {

    // MARK: - Geometry

    private enum Layout {
        static let width: CGFloat = 38
        static let height: CGFloat = 22
        static let knobInset: CGFloat = 2
        /// How far the knob travels when the theme's corners are square (Swiss), so the switch
        /// picks up the same silhouette as everything else.
        static let squareKnobRadius: CGFloat = 2
    }

    // MARK: - State

    /// Mirrors `NSSwitch.state`, so `toggle.state == .on` reads unchanged at the call sites this
    /// replaces. Declared here rather than overridden — `NSControl` itself has no `state`.
    var state: NSControl.StateValue = .off {
        didSet { needsDisplay = true }
    }

    private var isOn: Bool { state == .on }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.width, height: Layout.height)
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        state = isOn ? .off : .on
        sendAction(action, to: target)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn }

    /// A drawn control has no cell to inherit this from, so the press has to be routed by hand or
    /// the switch can be read but never flipped without a pointer.
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        state = isOn ? .off : .on
        sendAction(action, to: target)
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(
            x: (bounds.width - Layout.width) / 2,
            y: (bounds.height - Layout.height) / 2,
            width: Layout.width,
            height: Layout.height
        )

        // Square corners follow the theme's material, so a Swiss switch is a rounded-rect and a
        // Cyberpunk one is nearly a stadium — the same corner language as its cards and chips.
        let square = AppThemePalette.current.material.panelRadius == 0
        let trackRadius = square ? Layout.squareKnobRadius : rect.height / 2

        let track = NSBezierPath(roundedRect: rect, xRadius: trackRadius, yRadius: trackRadius)
        (isOn ? Design.Surface.accent : Design.Surface.controlHover).setFill()
        track.fill()

        if !isOn {
            // A hairline keeps the off-state legible where the track and the surface behind it
            // are close in tone — a pale switch on a pale card.
            Design.Surface.border.setStroke()
            track.lineWidth = 1
            track.stroke()
        }

        let knobDiameter = rect.height - Layout.knobInset * 2
        let knobX = isOn
            ? rect.maxX - knobDiameter - Layout.knobInset
            : rect.minX + Layout.knobInset
        let knobRect = NSRect(
            x: knobX,
            y: rect.minY + Layout.knobInset,
            width: knobDiameter,
            height: knobDiameter
        )
        let knobRadius = square ? Layout.squareKnobRadius : knobDiameter / 2
        let knob = NSBezierPath(roundedRect: knobRect, xRadius: knobRadius, yRadius: knobRadius)

        // The knob is the ground colour, so it reads against both an accent track and a neutral
        // one, on a light theme and a dark one alike — the ground is by definition the tone
        // furthest from the surfaces stacked on it.
        Design.Surface.ground.setFill()
        knob.fill()

        alphaValue = isEnabled ? 1 : 0.5
    }
}
