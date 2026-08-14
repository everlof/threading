import AppKit

/// A themed position control, replacing `NSSlider`.
///
/// `NSSlider` is banned for the reason every stock control is: its track and knob are drawn from
/// the *system* accent and bezel, so a scrubber under a styled theme stays system-blue on a page
/// that has gone red, green or one-bit. This draws the track from `Design.Surface` and the elapsed
/// run from the theme's own accent.
///
/// **A scrub has an end, and the end is not the same event as the travel.** That is the whole
/// reason this exists rather than a progress bar with a pointer: a media transport applies the
/// position continuously while the knob is dragged — the canvas follows the thumb — and commits
/// once when the drag finishes, because committing on every intermediate value is how a seek turns
/// into a queue of seeks. `onChange` is the travel; `onScrubEnd` is the decision. A keyboard step
/// raises both, because one key press *is* a complete scrub.
///
/// Values are normalized `0…1`. A caller with a duration maps into that range and formats the
/// reading itself; the control carries no unit, which is what keeps it usable for a media position,
/// a zoom, or anything else that is a fraction of a whole.
final class ThemedScrubber: ThemedControl {

    // MARK: - Geometry

    /// Internal rather than private: the behaviour tests pin the knob inside this geometry.
    enum Layout {
        static let trackHeight: CGFloat = 4
        static let knobDiameter: CGFloat = 12
        /// Clear space between the knob and its focus ring, so the ring reads as a ring rather
        /// than as a border the knob has grown. Matches `ThemedToggle.Layout.focusGap`.
        static let focusGap: CGFloat = 2
        /// The knob's corner when the theme's corners are square, so a Swiss scrubber picks up
        /// the same silhouette as its cards. Matches `ThemedToggle.Layout.squareKnobRadius`.
        static let squareKnobRadius: CGFloat = 2
        /// Enough width that the track is a track rather than a dash, at the narrowest pane a
        /// transport is offered in.
        static let minimumTrackWidth: CGFloat = 80
    }

    // MARK: - Steps

    /// How far one key press moves the knob.
    ///
    /// Two sizes rather than one: a coarse step crosses a document in a handful of presses, and
    /// the fine step — Shift — is what makes a keyboard user able to land on a specific frame.
    /// Both are fractions, because the control has no unit.
    enum Step {
        static let coarse: Double = 0.05
        static let fine: Double = 0.01
    }

    // MARK: - State

    /// `0…1`, clamped. Assigning does not raise `onChange`: a caller writing the position is
    /// stating it, not scrubbing to it, and a control that echoed its own assignment back would
    /// make a player's state report a feedback loop.
    var value: Double = 0 {
        didSet {
            value = min(max(value, 0), 1)
            guard value != oldValue else { return }
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// Raised continuously while the knob travels, and once per keyboard step.
    var onChange: ((Double) -> Void)?

    /// Raised once when a scrub finishes — mouse up, or the same key press that moved it.
    ///
    /// Distinct from `onChange` because a seek is expensive and a drag is not one seek. A caller
    /// that only wants the committed value can leave `onChange` nil.
    var onScrubEnd: ((Double) -> Void)?

    /// Spoken by VoiceOver in place of the raw fraction — a transport supplies "0:12 of 1:40".
    /// Without it the control reads out "0.12", which is true and useless.
    var spokenValue: String? {
        didSet { setAccessibilityValueDescription(spokenValue) }
    }

    private(set) var isScrubbing = false

    // MARK: - Metrics

    /// The room the focus ring is given outside the knob, on each side.
    ///
    /// Read at draw *and* measure time rather than stated as a constant, because `focusRingWidth`
    /// grows under Increase Contrast and `ThemeRedraw` answers that with an intrinsic-size
    /// invalidation.
    private var focusMargin: CGFloat {
        Layout.focusGap + Design.Accessibility.focusRingWidth
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Layout.minimumTrackWidth + Layout.knobDiameter + focusMargin * 2,
            height: Layout.knobDiameter + focusMargin * 2
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("themed.scrubber")
    }

    // MARK: - Geometry helpers

    /// The centre-line rect the knob travels along, inset by the focus margin and by the knob's
    /// own radius so a knob at either end stays inside the control.
    private var travelRect: NSRect {
        let inset = focusMargin + Layout.knobDiameter / 2
        return NSRect(
            x: bounds.minX + inset,
            y: bounds.midY,
            width: max(0, bounds.width - inset * 2),
            height: 0
        )
    }

    /// The knob's frame at `value`. Internal so the behaviour tests can assert containment
    /// without reimplementing the arithmetic they are checking.
    var knobRect: NSRect {
        let travel = travelRect
        let centre = travel.minX + travel.width * CGFloat(value)
        return NSRect(
            x: centre - Layout.knobDiameter / 2,
            y: bounds.midY - Layout.knobDiameter / 2,
            width: Layout.knobDiameter,
            height: Layout.knobDiameter
        )
    }

    private func value(at point: NSPoint) -> Double {
        let travel = travelRect
        guard travel.width > 0 else { return 0 }
        return min(max(Double((point.x - travel.minX) / travel.width), 0), 1)
    }

    // MARK: - Pointer

    /// Tracked in place rather than through `NSEvent.trackEvents`: the drag has to keep following
    /// the pointer after it leaves the control, which is what a scrubber must do and what
    /// stopping at the bounds would break.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isScrubbing = true
        applyScrub(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isScrubbing else { return }
        applyScrub(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, isScrubbing else { return }
        applyScrub(to: convert(event.locationInWindow, from: nil))
        isScrubbing = false
        needsDisplay = true
        onScrubEnd?(value)
        sendAction(action, to: target)
    }

    private func applyScrub(to point: NSPoint) {
        let proposed = value(at: point)
        guard proposed != value else {
            needsDisplay = true
            return
        }
        value = proposed
        onChange?(value)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard isEnabled, let key = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }
        let step = event.modifierFlags.contains(.shift) ? Step.fine : Step.coarse
        switch Int(key.value) {
        case NSLeftArrowFunctionKey:
            commit(value - step)
        case NSRightArrowFunctionKey:
            commit(value + step)
        case NSDownArrowFunctionKey:
            commit(value - step)
        case NSUpArrowFunctionKey:
            commit(value + step)
        case NSHomeFunctionKey:
            commit(0)
        case NSEndFunctionKey:
            commit(1)
        default:
            super.keyDown(with: event)
        }
    }

    /// One complete scrub: the travel and its end together, because a key press has no drag.
    private func commit(_ proposed: Double) {
        let clamped = min(max(proposed, 0), 1)
        guard clamped != value else { return }
        value = clamped
        onChange?(value)
        onScrubEnd?(value)
        sendAction(action, to: target)
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? L10n.string("Position")
    }
    override func accessibilityValue() -> Any? { value }
    // Doubles, explicitly: an `Int` literal in an `Any?` return reads back as an `Int`, and a
    // client asking for the range as a number gets nil for a control that plainly has one.
    override func accessibilityMinValue() -> Any? { Double(0) }
    override func accessibilityMaxValue() -> Any? { Double(1) }

    /// A position control has no press.
    ///
    /// Stated rather than inherited because the themed-control contract requires every drawn
    /// control to answer for its primary action, and answering *no* is the honest answer here:
    /// there is no single value a press could pick, and inventing one — jump to the middle, jump
    /// to the end — would put a destructive seek behind VoiceOver's most reflexive gesture. The
    /// primary actions are the increment and decrement below, which is how AppKit's own slider
    /// is driven too.
    override func accessibilityPerformPress() -> Bool { false }

    /// A drawn control has no cell to route these through, so a VoiceOver user could read the
    /// position and never move it.
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        commit(value + Step.coarse)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        commit(value - Step.coarse)
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        DisabledControlDrawing.draw(isEnabled: isEnabled) {
            drawContents()
        }
    }

    private func drawContents() {
        let travel = travelRect
        let square = AppThemePalette.current.material.panelRadius == 0
        let trackRadius = square ? 0 : Layout.trackHeight / 2
        let trackRect = NSRect(
            x: travel.minX - Layout.knobDiameter / 2,
            y: bounds.midY - Layout.trackHeight / 2,
            width: travel.width + Layout.knobDiameter,
            height: Layout.trackHeight
        )

        let track = ThemedSurface.Shape(rect: trackRect, radius: trackRadius)
        Design.Surface.controlResting.setFill()
        track.path.fill()

        let elapsedWidth = (travel.minX + travel.width * CGFloat(value)) - trackRect.minX
        if elapsedWidth > 0 {
            let elapsed = ThemedSurface.Shape(
                rect: NSRect(
                    x: trackRect.minX,
                    y: trackRect.minY,
                    width: min(elapsedWidth, trackRect.width),
                    height: trackRect.height
                ),
                radius: trackRadius
            )
            Design.Surface.accent.setFill()
            elapsed.path.fill()
        }

        let knob = knobRect
        let knobRadius = square ? Layout.squareKnobRadius : knob.width / 2
        let knobShape = ThemedSurface.Shape(rect: knob, radius: knobRadius)

        // The ground, for the same reason `ThemedToggle`'s knob is: it is by definition the tone
        // furthest from the surfaces stacked on it, so the knob reads against both the neutral
        // track and the accent run it sits on the boundary of.
        Design.Surface.ground.setFill()
        knobShape.path.fill()

        let outline = knobShape.path
        outline.lineWidth = 1
        (isScrubbing || isHovered ? Design.Surface.accent : Design.Surface.border).setStroke()
        outline.stroke()

        // Outside the knob, in the margin `intrinsicContentSize` reserved for it.
        drawKeyboardFocus(around: knobShape, outsideBy: Layout.focusGap)
    }
}
