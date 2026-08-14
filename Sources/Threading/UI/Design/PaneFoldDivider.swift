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
final class PaneFoldDivider: ThemedControl {

    // MARK: - Geometry

    enum Layout {
        /// The clear space under the rule — the pane's own gap, and the grip.
        static let grip: CGFloat = Design.Spacing.small

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
        // the hand, or under the keyboard's focus. That is what the accent already means on
        // `ThemedSplitView`'s divider, and the reason focus is shown this way rather than as a
        // ring: a ring around a band this thin reads as a bar, not as a ring.
        let ink = isActive || hasKeyboardFocus ? Design.Surface.accent : Design.Surface.divider
        ink.setFill()
        let weight = Design.Radius.border
        NSRect(
            x: bounds.minX,
            y: bounds.maxY - weight,
            width: bounds.width,
            height: weight
        ).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
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
    }

    /// Tracked through the ordinary drag events rather than a tracking loop: the pointer leaves
    /// this band on the first point of travel, and the events keep arriving here for as long as
    /// the button is down, which is exactly the span the fold is being moved over.
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isDragging else { return }
        onDrag?(event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
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
