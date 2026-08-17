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

    // MARK: - Metrics

    /// Drawing-only constants. The geometry that decides *where* anything goes lives in
    /// `ConversationMinimap`, where it can be tested without a window; these are the two
    /// numbers that only mean anything once something is being painted.
    private enum Metrics {

        /// How much of the spine's length each end spends fading out.
        static let spineFadeFraction: CGFloat = 0.12

        /// How far the pointer must travel before the taper is redrawn.
        ///
        /// The taper now follows the pointer continuously, so without this every mouse-moved
        /// event repaints the rail. Half a point is below what the taper can show and well
        /// below what the eye can catch, so the frames it drops are frames that would have
        /// been identical.
        static let pointerRedrawThreshold: CGFloat = 0.5
    }

    // MARK: - Properties

    /// Called with the row index to scroll to.
    var onSelect: ((Int) -> Void)?

    private var turns: [ConversationTimeline.Turn] = []

    /// The mark under the pointer, which drives the preview and the click target.
    ///
    /// It no longer drives the taper. Rounding the pointer to a mark and tapering from *that*
    /// is what made the rail step: between two marks nothing moved, and on the midpoint every
    /// mark in the taper changed width at once. The preview still wants a whole turn, so this
    /// stays — the two questions were only ever one by accident.
    private var activeIndex: Int? {
        didSet {
            guard activeIndex != oldValue else { return }
            updatePreview()
        }
    }

    /// Where the pointer is on the rail, in rail-relative points, and how far the taper has
    /// opened around it.
    ///
    /// The centre outlives the pointer on purpose. Cleared on exit, the taper would collapse
    /// flat from wherever it had reached instead of settling back towards the place the pointer
    /// left, which is the half-second that reads as the control letting go rather than blinking.
    private var fisheyeCenter: CGFloat?

    /// 0 rests every mark, 1 is the full taper. Ramped rather than assigned so arriving and
    /// leaving are movements, not cuts.
    private var fisheye: CGFloat = 0 {
        didSet {
            guard fisheye != oldValue else { return }
            needsDisplay = true
        }
    }

    private var fisheyeFrom: CGFloat = 0
    private var fisheyeTarget: CGFloat = 0
    private var fisheyeStart: CFTimeInterval = 0
    private var fisheyeDuration: TimeInterval = 0

    /// The frame source while the taper opens or closes — a display link on 14+, a 60Hz timer
    /// on 13, the pattern `ThemedToggle` and `UsageBarView` already use. It runs only for the
    /// ramp itself: while the pointer is inside, the taper follows it directly and needs no
    /// clock. Both retain the view, so completion and window removal each stop it.
    private var displayLink: Any? // CADisplayLink, stored untyped for macOS 13
    private var fallbackTimer: Timer?

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
        // A different conversation is not the same rail with the pointer still on it. Settling
        // the taper by hand rather than ramping it: nothing moved, the thing under it changed.
        stopDriver()
        fisheye = 0
        fisheyeTarget = 0
        fisheyeCenter = nil
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

    /// How many marks are actually drawn, which is one per turn until they would sit closer than
    /// the pointer can separate. Everything the pointer touches is in *mark* space; everything
    /// the preview and `onSelect` speak is in *turn* space; the two maps below are the border.
    private var markCount: Int {
        ConversationMinimap.markCount(turnCount: turns.count, railHeight: railHeight)
    }

    private func turn(forMark mark: Int) -> Int {
        ConversationMinimap.turnIndex(forMark: mark, markCount: markCount, turnCount: turns.count)
    }

    private func mark(forTurn turn: Int) -> Int {
        ConversationMinimap.markIndex(forTurn: turn, markCount: markCount, turnCount: turns.count)
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
        //
        // Faded at both ends rather than cut. A hairline that simply stops states a boundary
        // the rail does not have — the conversation continues past the first and last mark, and
        // a hard terminus reads as the end of the list rather than the end of the index.
        let spine = NSRect(
            x: 0, y: top - Design.Spacing.tight,
            width: 1, height: height + Design.Spacing.small
        )
        let ink = Design.Surface.border.withAlphaComponent(0.4)
        NSGradient(colorsAndLocations:
            (ink.withAlphaComponent(0), 0),
            (ink, Metrics.spineFadeFraction),
            (ink, 1 - Metrics.spineFadeFraction),
            (ink.withAlphaComponent(0), 1)
        )?.draw(in: spine, angle: -90)

        let marks = markCount
        // Which marks have a turn on screen behind them. In the bucketed regime one mark can
        // stand for several turns, so this is a set rather than a lookup: the mark brightens if
        // any turn it speaks for is visible, which is the honest reading of "you are here".
        let visibleMarks = Set(visibleTurnIndices.map(mark(forTurn:)))

        for index in 0..<marks {
            let centre = top + ConversationMinimap.markerCenterY(
                mark: index,
                markCount: marks,
                railHeight: height
            )

            // Distance from the pointer itself, not from the mark it is nearest, and scaled by
            // how far the taper has opened. At `fisheye == 0` this is exactly the resting rail.
            let distance = ConversationMinimap.markerDistance(
                mark: index,
                pointerY: fisheyeCenter ?? 0,
                markCount: marks,
                railHeight: height
            )
            let resting = ConversationMinimap.Metrics.restingMarkerWidth
            let reach = fisheyeCenter == nil ? 0 : fisheye
            let width = resting
                + (ConversationMinimap.markerWidth(distance: distance) - resting) * reach
            let emphasis = ConversationMinimap.markerEmphasis(distance: distance) * reach

            // The mark's own state sets the tone it rests at; the taper lifts it from there
            // towards the foreground, on the same curve as the width.
            let base = visibleMarks.contains(index)
                ? Design.Text.secondary
                : Design.Text.tertiary
            let colour = base.blended(withFraction: emphasis, of: Design.Text.label) ?? base
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
        trackPointer(with: event)
        rampFisheye(to: 1)
        updateVisibility()
    }

    override func mouseMoved(with event: NSEvent) {
        // Position rides `mouseMoved`, which reaches the rail through an open dropdown — the one
        // pointer delivery `CoveredWindowPointer` cannot hold back — and the fisheye and its
        // preview must not follow a pointer that is on a menu row. See
        // `NSView.uncoveredPointerLocation(in:)`.
        guard uncoveredPointerLocation(in: event) != nil else { return }
        trackPointer(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        activeIndex = nil
        rampFisheye(to: 0)
        updateVisibility()
    }

    override func mouseDown(with event: NSEvent) {
        trackPointer(with: event)
        guard let activeIndex, turns.indices.contains(activeIndex) else { return }
        onSelect?(turns[activeIndex].rowIndex)
    }

    /// The pointer answers two different questions, so it is asked both.
    ///
    /// The taper wants where it *is* — continuously, or it steps. The preview and the click
    /// want which turn it is *nearest* — a whole one, or there is nothing to show or scroll to.
    private func trackPointer(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y - railTop

        if let previous = fisheyeCenter,
           abs(previous - y) < Metrics.pointerRedrawThreshold {
            // Below the threshold the taper is unchanged, but the nearest mark may still have
            // flipped on a boundary, and the preview must follow it.
        } else {
            fisheyeCenter = y
            needsDisplay = true
        }

        // The pointer resolves to a mark, and a mark speaks for a turn. In the bucketed regime
        // those differ, and the preview must describe the turn a click would actually land on.
        activeIndex = ConversationMinimap.mark(
            atY: y,
            markCount: markCount,
            railHeight: railHeight
        ).map(turn(forMark:))
    }

    // MARK: - Fisheye Ramp

    /// Opens or closes the taper over time.
    ///
    /// Arriving is slower than leaving, the rule `Design.Motion` already states for surfaces:
    /// the rail opening is information the eye follows, the rail letting go is a decision
    /// already made. Under Reduce Motion both durations are zero and this lands immediately.
    private func rampFisheye(to target: CGFloat) {
        stopDriver()

        let duration = target > fisheye ? Design.Motion.quick : Design.Motion.vanish
        guard duration > 0, window != nil, fisheye != target else {
            fisheye = target
            return
        }

        fisheyeFrom = fisheye
        fisheyeTarget = target
        fisheyeDuration = duration
        fisheyeStart = CACurrentMediaTime()
        startDriver()
    }

    /// One frame of the ramp, split from the tick so the interpolation has one clock-independent
    /// boundary. Tests drive this directly; the display link only translates time into phase.
    func advanceFisheye(toPhase requestedPhase: CGFloat) {
        let phase = min(1, max(0, requestedPhase))
        fisheye = fisheyeFrom + (fisheyeTarget - fisheyeFrom) * phase

        guard phase >= 1 else { return }
        fisheye = fisheyeTarget
        // The taper is shut, so the place it shut towards is no longer worth holding.
        if fisheyeTarget == 0 { fisheyeCenter = nil }
        stopDriver()
    }

    /// One display-link frame of the ramp.
    func advanceFisheye(now: CFTimeInterval) {
        guard fisheyeDuration > 0 else { return }
        advanceFisheye(toPhase: CGFloat((now - fisheyeStart) / fisheyeDuration))
    }

    @objc private func tick() {
        advanceFisheye(now: CACurrentMediaTime())
    }

    private func startDriver() {
        guard displayLink == nil, fallbackTimer == nil else { return }
        if #available(macOS 14.0, *) {
            let link = self.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(tick),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    private func stopDriver() {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    /// A driver retains its target, so a rail leaving the window settles and stops rather than
    /// tapering unseen — or, timer-driven, never deallocating.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        stopDriver()
        fisheye = fisheyeTarget
        if fisheyeTarget == 0 { fisheyeCenter = nil }
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
            mark: mark(forTurn: activeIndex),
            markCount: markCount,
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
