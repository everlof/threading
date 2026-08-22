import AppKit

/// The fold between a pane's two halves, and the grip that moves it.
///
/// A hand-rolled divider rather than an `NSSplitView`, for `ShellDrawerDivider`'s reason and one
/// more of its own: the halves this folds between are not both flexible. The half above states a
/// height derived from its own content — a list is as tall as its rows — so what a drag moves
/// here is the *ceiling* on that half rather than a position between two panes, which is not a
/// sentence a split view has anywhere to say.
///
/// **The band is the rule plus the clear space a pane already left under it.** A fold drawn as a
/// hairline is a one-point target, and a fold given its own thick strip moves everything below it
/// the day it becomes draggable. Neither happens here: the rule keeps the theme's own weight at
/// the top edge, and the gap that was already there becomes the part the pointer can hold.
///
/// **Where the fold reaches its pane's own edge, the two seams meet, and the corner holds both.**
/// A fold that runs edge to edge ends *on* the window's split divider, and holding the point where
/// they cross while moving only one of them is the gesture arriving at half its meaning: the hand
/// is on both. So a press within `Layout.cornerReach` of an edge with a seam beside it takes that
/// seam as well (`ThemedSplitView.holdSeam(beside:on:)`), and the drag moves the fold down and the
/// pane wider in one movement. Pointer-only on purpose — both seams are already draggable on their
/// own, so the corner is a shortcut rather than the only way to either.
final class PaneFoldDivider: ThemedControl {

    // MARK: - Geometry

    enum Layout {
        /// The clear space under the rule — the pane's own gap, and the grip.
        static let grip: CGFloat = Design.Spacing.small

        /// How far in from a pane's own edge this band is also that pane's *corner*.
        ///
        /// A whole `large` rather than the band's own height: the corner is aimed at along a strip
        /// seven points tall, and a square that small is a target only a steady hand finds. It is
        /// still a twentieth of the panel at the width it opens to, so the fold is a plain fold
        /// for all but its very ends.
        static let cornerReach: CGFloat = Design.Spacing.large

        /// How far one key press moves the fold, and the fine step under Shift. A fold has no
        /// unit of its own, so these are points: what the pane does with them is its business.
        static let coarseStep: CGFloat = Design.Spacing.large
        static let fineStep: CGFloat = Design.Spacing.tight
    }

    // MARK: - Properties

    /// The travel since the last report, positive as the pointer moves **down**.
    ///
    /// A delta rather than a position: only the host knows what the fold is a fold *between*, and
    /// therefore what floor and ceiling the travel has to be answered against.
    var onDrag: ((CGFloat) -> Void)?

    /// A double-click: the fold goes back to wherever the pane itself would have put it.
    ///
    /// The same gesture `NSSplitView` answers, and the way out of a fold dragged somewhere
    /// unhelpful without having to find the original position by hand.
    var onReset: (() -> Void)?

    /// Held for the whole of a drag, because the pointer leaves the band almost immediately —
    /// a seam lit only while hovered would go out under the hand that is still moving it.
    private var isDragging = false {
        didSet {
            guard isDragging != oldValue else { return }
            needsDisplay = true
        }
    }

    private var focusOrigin = KeyboardFocusOrigin()

    /// The split view whose seam this drag is also moving, held from the press that began in a
    /// corner until the hand lets go. Nil for a drag that began anywhere else along the band,
    /// which is every drag on a fold with no pane edge under either of its ends.
    private var heldSplitView: ThemedSplitView?

    /// Whether the seam is lit for the keyboard — see `KeyboardFocusOrigin`.
    ///
    /// A press takes the focus so the arrow keys work on the fold the hand just left, and focus is
    /// drawn in the same accent the pointer lights, because a ring around a 7pt band reads as a
    /// bar. Together those two made every drag end with the seam still lit: the pointer had gone,
    /// the hand had let go, and the fold was still first responder. No other divider in the window
    /// does that — `ThemedSplitView` and `ShellDrawerDivider` never take focus at all — so the
    /// accent here follows the split's rule and goes out with the pointer, and stays only for a
    /// focus that arrived by Tab or an arrow: the one case where there is no pointer to say
    /// where the fold is.
    var showsKeyboardFocus: Bool { hasKeyboardFocus && focusOrigin.isFromKeyboard }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("pane.fold")
    }

    /// The rule's own weight plus the grip under it. Read from the token rather than stated flat,
    /// so a theme that rules heavily folds heavily too — the same decision `SeparatorView` takes,
    /// and `ThemeRedraw` is what re-asks it when the theme changes.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Design.Radius.border + Layout.grip)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let isActive = isHovered || isDragging
        if isActive {
            Design.Surface.controlResting.setFill()
            bounds.fill()
        }

        // The seam takes the accent wherever a drag would attach to it — under the pointer, under
        // the hand, or under a focus the keyboard placed. That is what the accent already means on
        // `ThemedSplitView`'s divider, and the reason focus is shown this way rather than as a
        // ring: a ring around a band this thin reads as a bar, not as a ring. Only a *keyboard*
        // focus, though — see `showsKeyboardFocus`.
        let ink = isActive || showsKeyboardFocus ? Design.Surface.accent : Design.Surface.divider
        ink.setFill()
        let weight = Design.Radius.border
        NSRect(
            x: bounds.minX,
            y: bounds.maxY - weight,
            width: bounds.width,
            height: weight
        ).fill()
    }

    /// Three rects rather than one over another: overlapping cursor rects are resolved by an order
    /// AppKit does not promise, and the corner's whole job is to say it is not the plain fold.
    /// The corners first, then the band under the whole seam. Stated in that order the band no
    /// longer has to be trimmed around them by hand: a claim wins the ground it shares with a
    /// later one, and `PointerClaiming` carves the rest. See `PointerClaiming`.
    override var pointerClaims: [PointerClaim] {
        [ThemedSplitView.Side.leading, .trailing].compactMap { side in
            cornerRect(on: side).map { PointerClaim($0, Self.cornerCursor(on: side)) }
        } + [PointerClaim(bounds, .resizeUpDown)]
    }

    // MARK: - The Corner

    /// The corner's own square at one end of the band, or nil where there is no seam beside it.
    ///
    /// Asked live rather than configured: whether a pane has a seam on a given side is the split
    /// view's answer and it changes — a collapsed neighbour has no divider to grab
    /// (`ThemedSplitView.hasMovableSeam(beside:on:)`), and a fold inset from its pane's edge has
    /// no corner at all.
    func cornerRect(on side: ThemedSplitView.Side) -> NSRect? {
        guard let split = paneSplitView, split.hasMovableSeam(beside: self, on: side) else {
            return nil
        }
        // Never more than half the band: a fold narrower than two corners is all corner and no
        // fold, and the plain drag is the one that must survive.
        let reach = min(Layout.cornerReach, bounds.width / 2)
        guard reach > 0 else { return nil }
        return NSRect(
            x: side == .leading ? bounds.minX : bounds.maxX - reach,
            y: bounds.minY,
            width: reach,
            height: bounds.height
        )
    }

    /// The side a press at `point` would take the seam of, or nil for the plain fold.
    ///
    /// Internal so a fixture can ask what the band believes about a point without a cursor rect,
    /// which an unshown window never resolves.
    func cornerSide(at point: NSPoint) -> ThemedSplitView.Side? {
        // Leading first, so a band too narrow for two full corners resolves rather than overlaps.
        [ThemedSplitView.Side.leading, .trailing].first {
            cornerRect(on: $0)?.contains(point) == true
        }
    }

    /// The split view this fold's pane belongs to, if it belongs to one.
    private var paneSplitView: ThemedSplitView? {
        var next: NSView? = superview
        while let view = next {
            if let split = view as? ThemedSplitView { return split }
            next = view.superview
        }
        return nil
    }

    /// The diagonal a corner grip has worn since windows had them.
    ///
    /// `NSCursor.frameResize` is macOS 15, and the crosshair is the honest stand-in below it: not
    /// "resize", but not "up and down" either — which is the one thing this corner must not say.
    private static func cornerCursor(on side: ThemedSplitView.Side) -> NSCursor {
        guard #available(macOS 15.0, *) else { return .crosshair }
        return .frameResize(position: side == .leading ? .topLeft : .topRight, directions: .all)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusArrived(from: NSApp.currentEvent) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            focusOrigin.resigned()
            needsDisplay = true
        }
        return resigned
    }

    /// Internal rather than private so a fixture can state the event that moved focus:
    /// `NSApp.currentEvent` is whatever the run loop last pulled off the queue, and an unshown
    /// test window pulls nothing.
    func focusArrived(from event: NSEvent?) {
        focusOrigin.arrived(from: event)
        needsDisplay = true
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)

        guard event.clickCount < 2 else {
            onReset?()
            return
        }
        isDragging = true

        // Resolved at the press and held for the whole drag, not re-asked per event: the seam
        // moves out from under the pointer as it goes, and a corner re-tested mid-drag would let
        // go of the thing the hand is still moving.
        let pressed = convert(event.locationInWindow, from: nil)
        if let side = cornerSide(at: pressed),
           let split = paneSplitView,
           split.holdSeam(beside: self, on: side) {
            heldSplitView = split
        }
    }

    /// Tracked through the ordinary drag events rather than a tracking loop: the pointer leaves
    /// this band on the first point of travel, and the events keep arriving here for as long as
    /// the button is down, which is exactly the span the fold is being moved over.
    ///
    /// Both axes, independently. A corner drag straight down is a fold drag with nothing across
    /// it, which is what makes the corner safe to be generous with: aiming at it costs nothing.
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isDragging else { return }
        heldSplitView?.moveHeldSeam(by: event.deltaX)
        onDrag?(event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        releaseHeldSeam()
        isDragging = false
    }

    /// A drag can also end without a mouse-up reaching this view — the window resigning key
    /// mid-drag is the ordinary way — and a seam left held would stay lit under no hand at all.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { releaseHeldSeam() }
    }

    private func releaseHeldSeam() {
        heldSplitView?.releaseSeam()
        heldSplitView = nil
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard isEnabled, let key = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }

        let step = event.modifierFlags.contains(.shift) ? Layout.fineStep : Layout.coarseStep
        switch Int(key.value) {
        case NSUpArrowFunctionKey: onDrag?(-step)
        case NSDownArrowFunctionKey: onDrag?(step)
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }

    override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? L10n.string("Pane divider")
    }

    override func accessibilityOrientation() -> NSAccessibilityOrientation { .horizontal }

    /// A fold has no press.
    ///
    /// Stated rather than inherited because the themed-control contract requires every drawn
    /// control to answer for its primary action, and answering *no* is the honest answer: there is
    /// no single position a press could pick. The primary actions are the two below, which is how
    /// AppKit drives its own splitters as well.
    override func accessibilityPerformPress() -> Bool { false }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        onDrag?(Layout.coarseStep)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        onDrag?(-Layout.coarseStep)
        return true
    }
}
