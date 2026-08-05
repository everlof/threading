import AppKit

// MARK: - Conversation Minimap View

/// The turn rail: one mark per exchange, down the gutter beside the conversation.
///
/// A long conversation scrolls past the point where scrolling finds anything — the scroller's
/// thumb says how far through you are but nothing about what is there. The rail is a contents
/// page: every mark is one exchange, hovering one says what was asked and what came of it, and
/// clicking jumps to it.
///
/// It lives in the gutter left by capping the column at `Design.Size.readableWidth`, and
/// `ConversationMinimap.railWidth` returns zero when a pane is too narrow to spare one — at
/// which point this view hides rather than drawing over the text. That rule is the difference
/// between a control that helps in a wide window and one that ruins a narrow one.
final class ConversationMinimapView: NSView {

    // MARK: - Properties

    /// Called with the row index to scroll to.
    var onSelect: ((Int) -> Void)?

    private var turns: [ConversationTimeline.Turn] = []

    /// The mark under the pointer, which drives both the fisheye and the preview.
    private var activeIndex: Int? {
        didSet {
            guard activeIndex != oldValue else { return }
            needsDisplay = true
            updatePreview()
        }
    }

    /// Turns whose rows are on screen, brightened so the rail also answers "where am I".
    private var visibleTurnIndices: Set<Int> = [] {
        didSet {
            guard visibleTurnIndices != oldValue else { return }
            needsDisplay = true
        }
    }

    private var isPersistent = true

    /// Hidden from the moment it exists: see `attachPreview(to:)` for what a visible one with
    /// no active mark did.
    private let preview: ConversationTurnPreview = {
        let preview = ConversationTurnPreview()
        preview.isHidden = true
        return preview
    }()

    /// Where the card sits in its container, as constraints rather than as an assigned frame.
    ///
    /// The card sizes itself from its own contents, so Auto Layout owns its frame — and a frame
    /// written straight onto a view the engine owns survives exactly until the next layout pass,
    /// which then resolves the position it was never given from the only thing it has: nothing.
    /// The card reappeared at the container's origin, over the composer, still holding the
    /// pointer's last turn. Two constants the pointer moves are the same arithmetic, kept.
    private var previewLeading: NSLayoutConstraint?
    private var previewTop: NSLayoutConstraint?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: - Public Methods

    /// Replaces the turns the rail indexes.
    func setTurns(_ turns: [ConversationTimeline.Turn]) {
        self.turns = turns
        activeIndex = nil
        needsDisplay = true
        invalidateIntrinsicContentSize()
        updateVisibility()
    }

    /// Live conversations change only at the tail. Keeping that fact here avoids copying the
    /// entire turn array and resetting hover state whenever one exchange begins or settles.
    func appendTurn(_ turn: ConversationTimeline.Turn) {
        turns.append(turn)
        needsDisplay = true
        invalidateIntrinsicContentSize()
        updateVisibility()
    }

    func replaceTurn(_ turn: ConversationTimeline.Turn, at index: Int) {
        guard turns.indices.contains(index) else { return }
        turns[index] = turn
        if activeIndex == index { updatePreview() }
        needsDisplay = true
    }

    func setVisibleTurnIndices(_ indices: Set<Int>) {
        visibleTurnIndices = indices
    }

    /// Tells the rail how much room it has, which decides whether it appears at all.
    func setAvailableWidth(_ width: CGFloat, paneWidth: CGFloat) {
        isPersistent = ConversationMinimap.isPersistent(
            paneWidth: paneWidth,
            columnWidth: Design.Size.readableWidth
        )
        updateVisibility()
    }

    /// The preview is a sibling rather than a subview: it is wider than the rail and would be
    /// clipped by it, and it must float over the conversation.
    ///
    /// It is attached hidden, and `updatePreview` is what ever shows it. A card is only ever
    /// correct beside the mark it describes, and until the pointer picks one there is no such
    /// mark — so an attached-and-visible card had no position to be at and took Auto Layout's
    /// answer for one: the pane's bottom-left corner, on top of the composer, an empty
    /// translucent panel two lines tall that no pointer had asked for and nothing dismissed.
    func attachPreview(to container: NSView) {
        guard preview.superview !== container else { return }
        container.addSubview(preview, positioned: .above, relativeTo: nil)

        let leading = preview.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        let top = preview.topAnchor.constraint(equalTo: container.topAnchor)
        previewLeading = leading
        previewTop = top
        NSLayoutConstraint.activate([leading, top])

        updatePreview()
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    private var railHeight: CGFloat {
        ConversationMinimap.railHeight(turnCount: turns.count, paneHeight: bounds.height)
    }

    /// The rail is centred vertically: it is an index of a list, not a scale of the pane.
    private var railTop: CGFloat {
        (bounds.height - railHeight) / 2
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !turns.isEmpty else { return }

        let top = railTop
        let height = railHeight

        // The hairline the marks hang off, so the rail reads as one object when every mark is
        // at its resting width.
        let spine = NSRect(
            x: 0, y: top - Design.Spacing.tight,
            width: 1, height: height + Design.Spacing.small
        )
        Design.Surface.border.withAlphaComponent(0.4).setFill()
        spine.fill()

        for index in turns.indices {
            let centre = top + ConversationMinimap.markerCenterY(
                index: index,
                turnCount: turns.count,
                railHeight: height
            )
            let width = ConversationMinimap.markerWidth(index: index, activeIndex: activeIndex)

            let isOnScreen = visibleTurnIndices.contains(index)
            let colour: NSColor
            if index == activeIndex {
                colour = Design.Text.label
            } else if isOnScreen {
                colour = Design.Text.secondary
            } else {
                colour = Design.Text.tertiary
            }
            colour.setFill()

            let mark = NSRect(
                x: 0,
                y: centre - ConversationMinimap.Metrics.markerHeight / 2,
                width: width,
                height: ConversationMinimap.Metrics.markerHeight
            )
            NSBezierPath(
                roundedRect: mark,
                xRadius: ConversationMinimap.Metrics.markerHeight / 2,
                yRadius: ConversationMinimap.Metrics.markerHeight / 2
            ).fill()
        }
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        updateActiveIndex(with: event)
        updateVisibility()
    }

    override func mouseMoved(with event: NSEvent) {
        updateActiveIndex(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        activeIndex = nil
        updateVisibility()
    }

    override func mouseDown(with event: NSEvent) {
        updateActiveIndex(with: event)
        guard let activeIndex, turns.indices.contains(activeIndex) else { return }
        onSelect?(turns[activeIndex].rowIndex)
    }

    private func updateActiveIndex(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        activeIndex = ConversationMinimap.index(
            atY: point.y - railTop,
            turnCount: turns.count,
            railHeight: railHeight
        )
    }

    // MARK: - Private Methods

    private func updateVisibility() {
        let hasRail = turns.count >= ConversationMinimap.Metrics.minimumTurns
        let wanted: CGFloat = hasRail ? (isPersistent || activeIndex != nil ? 1 : 0) : 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            animator().alphaValue = wanted
        }
    }

    private func updatePreview() {
        guard let activeIndex, turns.indices.contains(activeIndex),
              let container = preview.superview else {
            preview.isHidden = true
            return
        }

        let turn = turns[activeIndex]
        preview.configure(userText: turn.userText, assistantText: turn.assistantText)
        preview.isHidden = false

        // Anchored to the mark it describes, then nudged back inside the pane rather than
        // being allowed to run off the top or bottom.
        let markCentre = railTop + ConversationMinimap.markerCenterY(
            index: activeIndex,
            turnCount: turns.count,
            railHeight: railHeight
        )
        let anchor = convert(NSPoint(x: bounds.maxX, y: markCentre), to: container)
        let height = preview.fittingSize.height

        // The rail is flipped and the pane it hangs in usually is not, so the mark's distance
        // from the *top* is asked for explicitly rather than assumed from either view.
        let fromTop = container.isFlipped
            ? anchor.y
            : container.bounds.height - anchor.y
        let lowest = max(
            Design.Spacing.inset,
            container.bounds.height - height - Design.Spacing.inset
        )

        previewLeading?.constant = anchor.x + Design.Spacing.small
        previewTop?.constant = min(max(fromTop - height / 2, Design.Spacing.inset), lowest)
    }
}
