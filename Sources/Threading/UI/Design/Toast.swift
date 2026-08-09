import AppKit

// MARK: - Defaults

enum ToastDefaults {

    /// How long a toast holds before it leaves on its own.
    ///
    /// Long enough to see a row vanish, look down, and press the way back; short enough that a
    /// band nobody wanted stops being furniture. The pointer resting on it stops the clock, so
    /// this is the floor for somebody who is *not* already reaching — see `ToastPresenter`.
    static let dwell: TimeInterval = 6

    /// How long a band holds when nobody just did the thing it reports.
    ///
    /// The default is measured from the click: the user's hand is on the mouse, their eye is on
    /// the row that changed, and six seconds is a long time to notice a receipt you were
    /// expecting. An agent archiving its own session is the same receipt arriving with none of
    /// that — the user asked for it a turn ago and has been reading something else since, so the
    /// clock has to survive them looking up. Long enough for that, and still short of a band
    /// that has to be dismissed.
    static let unattendedDwell: TimeInterval = 14

    /// The extra distance a card keeps going past the pane's edge on its way out, and the
    /// extra it starts below on its way in — `Design.Size.glowGutter`, the room that token
    /// already budgets between a glowing panel and any clip edge. A band exactly level with
    /// the pane's edge is gone, but the shadow its theme hangs off it is not, and a
    /// departure that stopped there would leave a smear of shade over the footer with
    /// nothing above it to cast it.
    static let clearance: CGFloat = Design.Size.glowGutter

    /// The curve every card in the deck travels on — arriving, and settling forward when
    /// the card in front goes. Hard deceleration: the card crosses most of its distance at
    /// once and spends the rest easing into place, which reads as *put there*. The standard
    /// ease-out at this distance reads as floated, and linear as conveyor-belted.
    static var glide: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.19, 1, 0.22, 1)
    }

    /// The curve a dismissed card leaves on: acceleration, because a card let go of falls
    /// rather than lowering itself out. Its mirror is `glide` — what arrives decelerates
    /// into the hand, what leaves accelerates out of it.
    static var drop: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.55, 0, 1, 0.45)
    }

    /// Between the band's edge and its content.
    static let contentInset: CGFloat = Design.Spacing.inset

    /// Between the message and the ✕ standing in the corner beside it.
    static let closeGap: CGFloat = Design.Spacing.small

    /// How far the pointer travels sideways before a press on the band becomes a carry.
    ///
    /// The tab strip's slop, for the tab strip's reason: a hand that is not quite still must not
    /// turn a press into a one-point throw. Measured on the horizontal alone, so a gesture aimed
    /// down the sidebar never lifts the band at all.
    static let throwSlop: CGFloat = Design.Spacing.tight

    /// How far the band has to be carried before letting go throws it out, as a fraction of its
    /// own width.
    ///
    /// A fraction rather than a distance, because the band is as wide as the column it is in: the
    /// same 80 points is most of the way across a narrow sidebar and a nudge on a band at its
    /// full `maxWidth`. Set where a deliberate push clears it and the sideways part of a diagonal
    /// scroll does not.
    static let throwCommitFraction: CGFloat = 0.32

    /// How fast a flick has to be going to throw the band from wherever it got to, in points per
    /// second.
    ///
    /// The distance alone is the wrong test for a *throw*: the gesture people make at a band they
    /// want gone is short and fast, and it releases well before a third of the way across. Speed
    /// counts only when it is going the way the band already is, so a flick back towards the rest
    /// position is a change of mind rather than a throw in the other direction.
    static let throwVelocity: CGFloat = 450

    /// Between the band and the pane it floats in.
    static let hostInset: CGFloat = Design.Spacing.medium

    /// Widest the band grows. It fills a narrow column and stops well short of spanning a pane:
    /// a receipt read at a glance is a couple of short lines, not one long one.
    static let maxWidth: CGFloat = 320

    /// How hard the band's words argue for the band's width — which is to say, not at all.
    ///
    /// A wrapping label resists compression at 750 by default, and the band is pinned inside its
    /// host, so a chain of required constraints carried *the text of a receipt* out to the pane
    /// it floats in. In the sidebar that text outranked the constraint the split view holds the
    /// column's width with (`SidebarDefaults.holdingPriority`, one step above `defaultLow`), so
    /// the sidebar widened to fit the band as it arrived and snapped back six seconds later when
    /// it left — a column resized twice by a message *about something else*.
    ///
    /// The band takes the width it is given and wraps inside it. Silenced in both directions —
    /// compression *and* hugging — because the fill pin below is deliberately weaker than any
    /// pane's grip on its width, and words hugging at the ordinary 250 would outrank it and
    /// shrink-wrap the band to its own message. Only the words are silenced: the action keeps
    /// its own resistance, because a way back too narrow to read is not one.
    static let contentWidthPriority = NSLayoutConstraint.Priority(1)

    /// How hard the band pulls its trailing edge out to fill the column.
    ///
    /// Hard enough to beat the silenced words, and softer than the grip *any* pane holds its
    /// width with — the same step below `defaultLow` that the sidebar and display panes hold
    /// above it (`SidebarDefaults.holdingPriority`), with the terminal's plain item at the
    /// default in between. The pin must be this weak because in a pane wider than `maxWidth`
    /// it cannot be satisfied by the band at all: the required cap holds the band, and a solver
    /// forbidden from stretching the band satisfies the pin with the *pane* instead. At
    /// `defaultHigh` it did exactly that — a sidebar dragged past the cap snapped in to meet it
    /// as a receipt arrived, and sprang back out six seconds later when it left.
    static let fillPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue - 10
    )

    /// How many receipts may wait behind the one on screen.
    ///
    /// Bounded because the queue is measured in *dwells*: at four deep the last band arrives
    /// most of a minute after the click it reports, by which point it is news rather than a
    /// receipt. When a burst overruns this, the oldest waiting receipt is the one dropped — its
    /// action is the one the user has had longest to miss, and for the archive the way back is
    /// still in Settings, which is what the band's own detail line says.
    static let queueLimit = 3

    /// How far each waiting receipt stands above the one in front of it.
    ///
    /// One step of the scale, because all that has to be visible is a card edge: a rule plus the
    /// fill it carries is enough to read as another surface, and anything deeper spends the list
    /// the band floats over on a thing nobody opened.
    static let stackStep: CGFloat = Design.Spacing.tight

    /// How much narrower each waiting receipt is than the one in front of it, per side.
    ///
    /// Stepped in on **both** sides. Offset in one direction it reads as a page sliding off a
    /// desk — a band that is slipping — where the same card centred behind the front one reads
    /// as the next in a deck, which is what it is.
    static let stackInset: CGFloat = Design.Spacing.small

    /// How many edges are drawn, however many are waiting.
    ///
    /// The stack answers *is this the only one*, not *how many*: two edges say another is coming
    /// and a third is a distinction nobody counts at a glance. It is also the only honest answer
    /// — the queue is bounded and drops from the front when a burst overruns it, so a depth read
    /// as a count would be promising receipts the queue has already thrown away.
    static let stackDepth = 2
}

// MARK: - Request

/// What a toast says, and the one thing it offers to do about it.
///
/// The action is what this type exists for. **An action that can be taken back does not have to
/// be asked about first**: a confirmation stops the person who meant it every single time in
/// order to catch the one who did not, while a receipt with a way back charges the mistake
/// alone. `ConfirmationPrompt` is still the register for questions — this is the counterpart for
/// the actions that turned out not to be questions, and archiving a session is the first of
/// them.
///
/// `detail` carries the consequence the verb does not: where the thing went, or what stopped
/// along with it. Left out, the band is one line.
struct ToastRequest {

    /// What happened, in the fewest words that name what it happened to.
    let message: String

    /// The consequence, when there is one the message does not carry.
    var detail: String?

    /// The way back. Titled by the caller, since "Undo" is right for an archive and wrong for
    /// half the things a toast will report next.
    var actionTitle: String?
    var action: (() -> Void)?

    /// How long this band holds, where the presenter's own dwell is the wrong length for what it
    /// reports. Nil takes the presenter's.
    ///
    /// It belongs to the *request* because how long a receipt has to last is a fact about who
    /// caused the thing, not about the pane it appears in: the same sidebar shows both an
    /// archive the user clicked a moment ago and one an agent performed while they were reading
    /// elsewhere. See `ToastDefaults.unattendedDwell`.
    var dwell: TimeInterval?

    /// For UI scripting and tests; the band and its action each take one.
    var identifier: String?

    /// What VoiceOver is told when the band arrives. The band is transient and takes no focus,
    /// so nothing else would ever read it out.
    var announcement: String {
        [message, detail].compactMap { $0 }.joined(separator: " ")
    }

    var hasAction: Bool { actionTitle != nil && action != nil }
}

// MARK: - Departure

/// How a band leaves, which is the one thing about its exit the presenter cannot decide alone.
///
/// The clock running out, the ✕ and a throw all end in the same removal; what differs is where
/// the band goes on the way, and a band that was pushed sideways must not drop straight down
/// instead. A thrown receipt carries on the way it was sent, because the gesture is the animation
/// — the hand did the first half of it and the band owes it the second.
enum ToastDeparture: Equatable {

    /// Its time ran out, or the ✕ was pressed: it settles back the way it arrived.
    case settled

    /// It was thrown, and leaves the way it was going. `-1` towards the leading edge, `1` towards
    /// the trailing one.
    case thrown(direction: CGFloat)
}

// MARK: - View

/// A floating band that reports something already done and offers to take it back.
///
/// It draws on `elevated` — the role for a card above a pane — rather than on a translucent
/// control surface: this floats over a list, and a see-through fill at 14% is how the git card
/// once let a conversation's own text run through its middle (see
/// [`design-system.md`](../../../../docs/architecture/design-system.md)). Quiet-at-rest belongs
/// on a control that is waiting to be used; a band that leaves by itself in six seconds has to
/// be legible for all six.
///
/// Its two controls are a `ThemedButton` and a `ThemedIconButton`, which is what gives the way
/// back and the way out a keyboard route, a focus ring and an accessible name for free — and what
/// keeps the band itself out of the interactive-component contract, which exists so that a *drawn
/// control* cannot be mouse-only. The band draws nothing that is pressable.
///
/// It does read two gestures over its own surface, and neither is a control:
///
/// - **Hover** stops the clock. The presenter reads it, because what a held band means is a
///   decision about time and this view owns none.
/// - **A carry** — a drag, or a two-finger swipe — takes the band sideways, and letting go past
///   `throwCommitFraction` or above `throwVelocity` throws it out. Every part of that is also on
///   the ✕, so the gesture is an accelerator rather than the only route: a receipt whose only way
///   out was a mouse gesture would be one a keyboard could not be rid of.
final class ToastView: NSView {

    // MARK: - Properties

    /// Pressed the way back. The presenter dismisses the band; the caller undoes the work.
    var onAction: (() -> Void)?

    /// Asked for the band to go now — the ✕, or a throw that carried far enough to commit.
    ///
    /// It reports *how* it was sent away rather than only that it was, so the departure finishes
    /// the movement the hand started. See `ToastDeparture`.
    var onDismiss: ((ToastDeparture) -> Void)?

    /// Whether the band is being held: the pointer is on it, or a gesture is carrying it.
    ///
    /// Reported rather than acted on, because what it means — the dwell pauses — is the
    /// presenter's decision and not this view's. The two are one signal because they are one
    /// fact: a band under a hand is a band being read, and a carry that let the clock run would
    /// expire under the very gesture aimed at it.
    var onHoldChanged: ((Bool) -> Void)?

    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            reportHold()
        }
    }

    /// What was last reported through `onHoldChanged`, so a pointer arriving on a band already
    /// held by its own carry is not a second hold — the presenter reads the remainder of a stopped
    /// clock when one is handed to it, and handing it two would spend the pause twice.
    private var isHeld = false

    let request: ToastRequest

    /// Whether the band is showing a clock that is running.
    ///
    /// Intent rather than depiction: Reduce Motion takes the rail away and the dwell still runs,
    /// so this is what the presenter last said about the clock, which is the thing worth
    /// asserting.
    private(set) var isDwellRunning = false

    /// Whether the countdown is drawn at all. Reduce Motion takes the rail away while the clock
    /// keeps running, and that difference is the part worth asserting.
    var showsDwellCountdown: Bool { !dwellRail.isHidden }

    private let messageLabel: NSTextField
    private let detailLabel: NSTextField?
    private let actionButton: ThemedButton?

    /// The way out, as against the way back.
    ///
    /// **Visible whenever the band is, rather than under the pointer.** Revealing it on hover is
    /// what a tab's ✕ does, and it is the wrong grammar here for a reason particular to this
    /// surface: hovering the band *stops its clock*, so the gesture that would discover a
    /// hidden ✕ is the same gesture that makes the band stay. A receipt that has to be leant on
    /// before it admits how to be rid of it is a receipt that answers "make this go away" with
    /// "it will stay as long as you keep looking for the button".
    ///
    /// Quiet all the same: an icon button rests at `secondary` and only lifts to full strength
    /// under the pointer, which is the vocabulary's quiet-until-relevant without hiding the
    /// affordance.
    private let closeButton: ThemedIconButton
    private let dwellRail = ToastDwellRail()
    private var hoverTracking: NSTrackingArea?

    /// What each wrapping label is held to, measured the way its cell draws rather than the way it
    /// reports itself. See `layout()`.
    private var messageHeight: NSLayoutConstraint?
    private var detailHeight: NSLayoutConstraint?

    // MARK: - Initialization

    init(request: ToastRequest) {
        self.request = request
        messageLabel = NSTextField(wrappingLabelWithString: request.message)
        detailLabel = request.detail.map { NSTextField(wrappingLabelWithString: $0) }
        actionButton = request.hasAction
            ? ThemedButton(title: request.actionTitle ?? "", target: nil, action: nil)
            : nil
        closeButton = ThemedIconButton(
            symbolName: "xmark",
            accessibility: L10n.string("Dismiss"),
            target: .inline,
            inkSource: .chrome
        )

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        configureLabels()
        configureAction()
        configureClose()
        installContent()
        applyBandSurface()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(request.announcement)
        if let identifier = request.identifier {
            setAccessibilityIdentifier(identifier)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    /// A wrapping label measures its height against a width it has to be told, and the width
    /// here is whatever the host column left — capped, but never fixed. Guarded on the values
    /// actually changing: assigning them unconditionally in `layout()` invalidates the size that
    /// caused the layout.
    ///
    /// **Each label is told its own width, not the band's.** The message stops short of the ✕ and
    /// the detail runs the full width under it, so one figure derived from the band cannot be
    /// right for both — handed the band's, the message believed it had 26 points it did not have
    /// and laid a receipt out as one line that the band then clipped: *Archived “Refactor* with
    /// the rest of the session's name simply gone. The label's own frame is the answer the solver
    /// already computed, and it is not circular: these labels neither hug nor resist at any
    /// meaningful priority (`ToastDefaults.contentWidthPriority`), so their width comes from the
    /// pins alone and never from the text being measured against it.
    ///
    /// **And the height is measured the way the label is drawn, rather than asked for.** An
    /// `NSTextField`'s `intrinsicContentSize` and the cell that actually typesets it can disagree
    /// about whether a string wraps, and at a width the string very nearly fits they do: under
    /// Claymorphism's rounded face the same receipt measured 175 points on one line — inside the
    /// 178 it had — while the cell laid out at exactly 178 broke it in two. The band was built one
    /// line tall and clipped the second, which is the same missing session name arriving by a
    /// different route and is why this asks the cell instead. It costs a constraint per label and
    /// removes an entire class of theme-specific clipping: a font whose measurement is a hair
    /// optimistic can no longer cost a receipt its last line.
    override func layout() {
        super.layout()
        for (label, height) in [(messageLabel, messageHeight), (detailLabel, detailHeight)]
            .compactMap({ label, height -> (NSTextField, NSLayoutConstraint)? in
                guard let label, let height else { return nil }
                return (label, height)
            }) {
            let width = label.frame.width
            guard width > 0 else { continue }

            if abs(label.preferredMaxLayoutWidth - width) > 0.5 {
                label.preferredMaxLayoutWidth = width
                label.invalidateIntrinsicContentSize()
            }

            let drawn = label.cell?.cellSize(
                forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
            ).height ?? label.intrinsicContentSize.height
            if abs(height.constant - drawn) > 0.5 { height.constant = drawn }
        }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area

        // A fresh tracking area assumes the pointer is outside, so a band the pointer has left
        // during a relayout would hold a hover nothing ever clears — and the clock would never
        // restart. Only ever corrected in the leaving direction — see `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) { isHovered = false }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    /// The pointer on the band and a gesture carrying it are one signal, because they are one
    /// fact — see `onHoldChanged`. Reported only on a change, so a pointer crossing a band that
    /// its own carry already holds does not hand the presenter a second pause to spend.
    private func reportHold() {
        let held = isHovered || isCarried
        guard held != isHeld else { return }
        isHeld = held
        onHoldChanged?(held)
    }

    // MARK: - The Throw

    /// How far the band has been carried from where the presenter put it. Zero at rest.
    private(set) var carryOffset: CGFloat = 0

    /// Whether a gesture currently has the band. Readable so the hold can be asserted where it
    /// happens rather than by watching something fail to leave.
    private(set) var isCarried = false

    /// How fast the band was last moving, in points per second, and which way. What tells a throw
    /// from a push: the gesture aimed at a band somebody wants gone is short and fast.
    private var carrySpeed: CGFloat = 0

    /// The last place and moment the carry was measured at, which is what a speed is measured
    /// between.
    private var carrySample: (offset: CGFloat, time: TimeInterval)?

    /// Where a press went down and when, in window coordinates. Nil when nothing is tracking.
    private var press: (origin: CGPoint, sample: CGPoint, time: TimeInterval)?

    /// A trackpad gesture in flight: what it has covered so far, and whether the band has already
    /// handed it to the list underneath.
    private var swipe: (dx: CGFloat, dy: CGFloat, declined: Bool)?

    /// How far the band has to go before letting go throws it — a fraction of the width it was
    /// given, not a constant. See `ToastDefaults.throwCommitFraction`.
    private var throwCommitDistance: CGFloat {
        max(1, bounds.width * ToastDefaults.throwCommitFraction)
    }

    /// The gesture, stated as what it does to the band rather than as the events that drive it.
    ///
    /// Both routes in — the pointer's drag and the trackpad's swipe — end here, so the rules about
    /// when a carry becomes a throw are written once. It is also what a test drives: synthesising
    /// a pointer means synthesising its modifiers too, and a `CGEvent` built here reads the
    /// keyboard the developer's hands are actually on.
    func carryBegan() {
        guard !isCarried else { return }
        isCarried = true
        carrySpeed = 0
        carrySample = nil
        reportHold()
    }

    /// Moves the carried band to `offset` points from where it rests, as measured at `time`.
    func carryChanged(to offset: CGFloat, at time: TimeInterval) {
        guard isCarried else { return }
        if let last = carrySample, time > last.time {
            carrySpeed = (offset - last.offset) / CGFloat(time - last.time)
        }
        carrySample = (offset, time)
        carryOffset = offset
        applyCarry(animated: false)
    }

    /// Lets the band go. It leaves if it was carried far enough or thrown hard enough, and springs
    /// back to where the presenter put it if it was neither.
    func carryEnded() {
        guard isCarried else { return }
        isCarried = false
        carrySample = nil
        let direction: CGFloat = carryOffset < 0 ? -1 : 1
        // Speed counts only in the direction the band already went: a flick back towards the rest
        // position is somebody changing their mind, and throwing on it would send the band out of
        // the side they just pulled it away from.
        let flung = abs(carrySpeed) >= ToastDefaults.throwVelocity
            && (carrySpeed < 0) == (carryOffset < 0)
            && carryOffset != 0
        let committed = flung || abs(carryOffset) >= throwCommitDistance
        reportHold()
        guard committed else { return springBack() }
        onDismiss?(.thrown(direction: direction))
    }

    /// Sends the band the rest of the way out, the way it was thrown.
    ///
    /// Called from inside the departure's own animation group, so the translation rides it rather
    /// than starting a second animation beside the fade. Far enough to clear the pane either way:
    /// the band's own width plus the inset it rests at is past the leading edge going one way and
    /// past the trailing edge going the other.
    func flyOut(_ direction: CGFloat) {
        layer?.transform = CATransform3DMakeTranslation(
            direction * (bounds.width + ToastDefaults.hostInset),
            0,
            0
        )
    }

    /// Sends the band down out of the pane, back the way it arrived — the settled departure's
    /// half of `flyOut`, called from inside the departure's own animation group for the same
    /// reason. Negative, because the band is not flipped: down is towards zero. Its own height
    /// plus the inset it rests at puts it below the pane's edge, and the clearance takes the
    /// shadow its theme hangs off it along as well.
    func dropOut() {
        layer?.transform = CATransform3DMakeTranslation(
            0,
            -(bounds.height + ToastDefaults.hostInset + ToastDefaults.clearance),
            0
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Taken rather than passed on, whether or not it becomes a carry: a card floating over a
        // list must not hand a click through to the row it is covering, and this is the one place
        // that can say so — the band is the topmost view in the pane.
        press = (event.locationInWindow, event.locationInWindow, event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var tracking = press else { return super.mouseDragged(with: event) }
        let location = event.locationInWindow
        let offset = location.x - tracking.origin.x

        // A slop before the carry begins, and a sideways one: a press with an unsteady hand stays
        // a press, and a gesture aimed down the list the band floats over never lifts it at all.
        if !isCarried {
            guard abs(offset) > ToastDefaults.throwSlop else { return }
            carryBegan()
        }

        tracking.sample = location
        tracking.time = event.timestamp
        press = tracking
        carryChanged(to: offset, at: event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        press = nil
        carryEnded()
    }

    /// The same throw with two fingers, which is the gesture a trackpad has for it — and the one
    /// macOS's own notifications answer to.
    ///
    /// Only a *phased* gesture qualifies. A wheel reports no phase, and a band that a wheel could
    /// throw would be thrown by somebody scrolling the list underneath it. A gesture that turns
    /// out to be going down the list rather than across the band is declined for its whole life
    /// and handed on, so the pane behind still scrolls with the pointer over a receipt.
    override func scrollWheel(with event: NSEvent) {
        guard !event.phase.isEmpty || !event.momentumPhase.isEmpty else {
            return super.scrollWheel(with: event)
        }
        if event.phase.contains(.began) { swipe = (0, 0, false) }
        guard var gesture = swipe, !gesture.declined else {
            return super.scrollWheel(with: event)
        }

        gesture.dx += event.scrollingDeltaX
        gesture.dy += event.scrollingDeltaY

        if !isCarried {
            guard abs(gesture.dx) > ToastDefaults.throwSlop, abs(gesture.dx) > abs(gesture.dy)
            else {
                gesture.declined = abs(gesture.dy) > ToastDefaults.throwSlop
                swipe = gesture
                if gesture.declined { super.scrollWheel(with: event) }
                return
            }
            carryBegan()
        }

        swipe = gesture
        carryChanged(to: gesture.dx, at: event.timestamp)

        // Decided when the fingers lift rather than when the momentum stops, for the reason the
        // mouse decides on release: the throw is over when the hand is done with it, and a band
        // still sliding after that is an animation rather than a gesture.
        guard event.phase.contains(.ended) || event.phase.contains(.cancelled) else { return }
        swipe = nil
        carryEnded()
    }

    /// Puts a band that was not thrown back where the presenter had it.
    private func springBack() {
        carryOffset = 0
        carrySpeed = 0
        applyCarry(animated: true)
    }

    /// The transform, not the frame: layout still owns the band's place in the pane, and the
    /// gesture only borrows the pixels — the same division `ThemedTabStripView` drags a tab under.
    ///
    /// The band also fades as it goes, to `Design.Opacity.dragAway` at the distance that commits
    /// it. That opacity is the token for exactly this — still visible where it came from, clearly
    /// on its way out — and it is the only thing that says *let go now and it goes*, on a gesture
    /// whose threshold is otherwise invisible until it is crossed.
    private func applyCarry(animated: Bool) {
        let travelled = min(1, abs(carryOffset) / throwCommitDistance)
        let fade = 1 - (1 - Design.Opacity.dragAway) * travelled
        let transform = CATransform3DMakeTranslation(carryOffset, 0, 0)

        guard animated, Design.Motion.quick > 0 else {
            // Tracking a hand rather than reporting a change: the band belongs under the fingers
            // now, not eased after them.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.transform = transform
            CATransaction.commit()
            alphaValue = fade
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            layer?.transform = transform
            animator().alphaValue = fade
        }
    }

    // MARK: - The Clock, Drawn

    /// Starts the countdown the band shows for its own dwell, from full.
    func startDwell(_ duration: TimeInterval) {
        isDwellRunning = true
        dwellRail.run(for: duration)
    }

    /// Picks the countdown back up where the pointer stopped it, over what is left of the clock.
    ///
    /// From where it stopped rather than from full, because that is what the clock behind it does:
    /// releasing a held band schedules the remainder of its dwell rather than a fresh one, and a
    /// rail refilling as the pointer leaves would promise time the band no longer has.
    func resumeDwell(_ remaining: TimeInterval) {
        isDwellRunning = true
        dwellRail.resume(for: remaining)
    }

    /// Freezes the countdown where it stands — the pointer is on the band and its clock stopped.
    func holdDwell() {
        isDwellRunning = false
        dwellRail.hold()
    }

    /// Ends layer work before an off-screen host disappears. Render fixtures create and discard
    /// many presenters in one run; leaving those drains committed after their view trees are
    /// gone eventually asks Core Animation to update a dead context.
    func stopDwell() {
        isDwellRunning = false
        dwellRail.stop()
    }

    // MARK: - Private Methods

    private func configureLabels() {
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.applyFont(.control)
        messageLabel.textColor = Design.Text.label
        messageLabel.maximumNumberOfLines = 0

        // `.detail`, not `.caption`: the caption role is semibold, which on the line *under* a
        // medium-weight message reads as a second heading rather than as the consequence of the
        // first. Two lines of small regular type in secondary ink is what a receipt's fine print
        // looks like, and it is the only way the message stays the thing read first.
        detailLabel?.translatesAutoresizingMaskIntoConstraints = false
        detailLabel?.applyFont(.detail())
        detailLabel?.textColor = Design.Text.secondary
        detailLabel?.maximumNumberOfLines = 0

        // A receipt does not get to decide how wide the column it floats in is — see
        // `ToastDefaults.contentWidthPriority`, which is the sidebar jumping wider as the band
        // arrived and back again as it left. Hugging goes with it, so the fill pin — weaker
        // than a pane's hold on its width — is still the strongest opinion about the band's.
        for label in [messageLabel, detailLabel].compactMap({ $0 }) {
            label.setContentCompressionResistancePriority(
                ToastDefaults.contentWidthPriority,
                for: .horizontal
            )
            label.setContentHuggingPriority(
                ToastDefaults.contentWidthPriority,
                for: .horizontal
            )
        }
    }

    private func configureAction() {
        guard let actionButton else { return }
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        // Secondary: the band reports one thing and offers one action, so the action is the
        // only thing on it asking to be pressed — but a receipt is not the screen's primary
        // business, and an accent fill floating over a list would claim it was.
        actionButton.emphasis = .secondary
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        if let identifier = request.identifier {
            actionButton.setAccessibilityIdentifier("\(identifier).action")
        }
    }

    private func configureClose() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.onPress = { [weak self] in self?.onDismiss?(.settled) }
        if let identifier = request.identifier {
            closeButton.setAccessibilityIdentifier("\(identifier).dismiss")
        }
    }

    private func installContent() {
        addSubview(messageLabel)
        detailLabel.map { addSubview($0) }
        actionButton.map { addSubview($0) }
        addSubview(closeButton)
        addSubview(dwellRail)

        let inset = ToastDefaults.contentInset
        // **Aligned by ink, so the ✕ is inset like the words rather than like a box.** An icon
        // button carries its own padding around its glyph; pinned at the content inset outright,
        // the mark itself would sit a further four points in from every edge than the message
        // beside it, which reads as a control that missed the corner it was aimed at.
        let closeInset = inset - closeButton.opticalHorizontalInset

        // Each label's height, restated from the cell on every layout. Starts at whatever the
        // label reports for itself, so a band that is measured before it is ever laid out — a
        // fitting size asked for off screen — is no worse off than it was.
        messageHeight = messageLabel.heightAnchor.constraint(
            equalToConstant: messageLabel.intrinsicContentSize.height
        )
        detailHeight = detailLabel.map {
            $0.heightAnchor.constraint(equalToConstant: $0.intrinsicContentSize.height)
        }

        var constraints: [NSLayoutConstraint] = [
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            messageLabel.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor,
                constant: -ToastDefaults.closeGap
            ),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: closeInset),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -closeInset),
            // The band is never shorter than its own corner control, however few words it carries
            // — measured from the button's ink for the same reason its top and trailing pins are.
            bottomAnchor.constraint(
                greaterThanOrEqualTo: closeButton.bottomAnchor,
                constant: closeInset
            ),

            // Flush to three edges, and no inset anywhere: the clock is the band's own bottom
            // border, tinted, rather than a rule laid across the band's field. It sits *in* the
            // band's bottom inset rather than in a row of its own, so it says nothing the
            // content says and makes the band no taller than the receipt is.
            dwellRail.leadingAnchor.constraint(equalTo: leadingAnchor),
            dwellRail.trailingAnchor.constraint(equalTo: trailingAnchor),
            dwellRail.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]

        // **The message clears the ✕; whatever is under it runs the full width.** Only the first
        // line of a receipt is beside the corner control, and holding the fine print to the same
        // column would spend 26 points of a 240-point sidebar on every line of it for a mark that
        // occupies one. So the row directly under the message is asked to clear the button
        // instead — inert at every stock size, and load-bearing only where a large message font
        // would otherwise walk that row up into it.
        //
        // The spacing is stated *below* that guard rather than beside it. Two required opinions
        // about one edge is a constraint the solver has to break and log; demoted, the spacing is
        // exact whenever the guard is satisfied and yields by exactly the difference when it is
        // not, which is the whole intent written as an order of preference.
        func under(_ previous: NSLayoutYAxisAnchor, by gap: CGFloat, clearingClose: Bool)
            -> (NSLayoutYAxisAnchor) -> [NSLayoutConstraint] {
            { top in
                let spacing = top.constraint(equalTo: previous, constant: gap)
                guard clearingClose else { return [spacing] }
                spacing.priority = .defaultHigh
                return [spacing, top.constraint(greaterThanOrEqualTo: self.closeButton.bottomAnchor)]
            }
        }

        var lastText: NSView = messageLabel
        if let detailLabel {
            constraints += under(
                messageLabel.bottomAnchor,
                by: Design.Spacing.hairline,
                clearingClose: true
            )(detailLabel.topAnchor)
            constraints += [
                detailLabel.leadingAnchor.constraint(equalTo: messageLabel.leadingAnchor),
                detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
            ]
            lastText = detailLabel
        }

        if let actionButton {
            // Under the words rather than beside them: the band lives in the sidebar's column,
            // where a title long enough to wrap and a button on the same line leave the button
            // a few points wide.
            //
            // Pinned at the inset outright, **not** by ink. A bordered button's ink *is* its
            // surface, and `opticalHorizontalInset` reports the bordered shape's title inset —
            // the right answer for a footer aligning a row of plain controls by their words, and
            // the wrong one here, where subtracting it left the pill three points from the
            // band's own border.
            constraints += under(
                lastText.bottomAnchor,
                by: Design.Spacing.small,
                clearingClose: lastText === messageLabel
            )(actionButton.topAnchor)
            constraints += [
                actionButton.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -inset
                ),
                actionButton.leadingAnchor.constraint(
                    greaterThanOrEqualTo: leadingAnchor,
                    constant: inset
                ),
                bottomAnchor.constraint(equalTo: actionButton.bottomAnchor, constant: inset)
            ]
        } else {
            constraints.append(bottomAnchor.constraint(equalTo: lastText.bottomAnchor, constant: inset))
        }

        constraints += [messageHeight, detailHeight].compactMap { $0 }
        NSLayoutConstraint.activate(constraints)
    }

    private func applyBandSurface() {
        applySurface(
            fill: Design.Surface.elevated,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )
    }

    @objc private func actionPressed() {
        onAction?()
    }
}

// MARK: - Dwell Rail

/// The band's clock, drawn: ordinarily the band's own bottom border in the accent, emptying as
/// the dwell runs down. A material asking for segmented progress instead gets the native grammar
/// of its period: a sunken block control. Windows exposed a separate smooth-progress style; its
/// default control was blocks, so a one-pixel continuously shrinking line is explicitly the
/// modern answer that a classic material should not inherit.
///
/// A band that leaves on its own is the one surface in the window whose *remaining* time is
/// worth knowing — the receipt is only useful while the way back is still on it, and without
/// this the only way to learn how long that is was to lose it once. Drawn as a line rather than
/// as a number because it is read at the edge of vision, on a band nobody opened.
///
/// **It rides the band's edge rather than floating in its padding.** Held a step in from three
/// sides and a step up from the bottom, it was a rule between nothing and nothing — a stray
/// underline beneath the way back, which is what it looked like it belonged to. Pinned flush and
/// clipped to the band's own silhouette, it is a second edge on top of the first: the accent runs
/// exactly where the border runs, curves into the corners the border curves into, and takes the
/// weight the theme rules everything else at. What it leaves behind as it drains is the band's
/// own border, which is why it needs no track drawn under it.
///
/// It empties towards the leading edge, so the ink that is left is under the words rather than
/// under the button: the last thing to disappear is beside the thing being reported.
///
/// Animated on a layer rather than by redrawing on a timer, for `ThemedSpinner`'s reason at a
/// tenth of its length: a six-second linear drain is six seconds of main-thread work the moment
/// it is a `Timer`, and the main thread is where the agents' output is being parsed. The layer's
/// colour is re-applied on every redraw for the same reason it is there — a `CGColor` handed to
/// a layer is frozen at assignment, and `ThemeRedraw` is what asks for the redraw.
private final class ToastDwellRail: NSView, ThemedComponent {

    private enum Animation {
        static let key = "dwell"
        static let path = "strokeEnd"
    }

    private let ink = CAShapeLayer()

    /// The band's silhouette, so the line's ends follow the corners the band's own border does.
    ///
    /// A mask rather than `masksToBounds` on the band: the band's rounded rect is the shape being
    /// followed, and clipping the *band* to its bounds would take its glow with it.
    private let silhouette = CALayer()
    private var themeRedraw: ThemeRedraw?

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // CAShapeLayer fills paths black by default. This path is intentionally open — its only
        // content is the stroked lower contour — so a fill would close the two tangents with a
        // solid chord and paint the bottom third of the toast black.
        ink.fillColor = nil
        layer?.addSublayer(ink)

        silhouette.anchorPoint = CGPoint(x: 0, y: 0)
        silhouette.cornerCurve = .continuous
        silhouette.backgroundColor = NSColor.black.cgColor
        layer?.mask = silhouette

        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(false)

        // Nothing has started the clock yet, and a full rail under a band with no countdown
        // behind it is a promise of time rather than a report of it.
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    /// Flat and ordinarily rounded themes need only two rules of height. A large-radius material
    /// owns enough of the lower corner to follow it: the rail joins halfway around the
    /// bottom-left corner, crosses the bottom edge, and leaves halfway around the bottom-right.
    ///
    /// `Design.Radius.border` rather than a thickness of its own, because a style states how
    /// heavily it rules as surely as it states its palette — the same token `SeparatorView`
    /// weighs itself with, and the reason a theme change remeasures this view (`ThemeRedraw`)
    /// instead of only repainting it.
    override var intrinsicContentSize: NSSize {
        if usesClassicProgress {
            return NSSize(width: NSView.noIntrinsicMetric, height: Classic.height)
        }
        let height = followsPanelContour
            ? Design.Radius.panel + contourWidth / 2
            : Design.Radius.border * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        // The model geometry only: a running drain is a transform on top of this, and assigning
        // bounds mid-animation would move the line without touching what it is scaling from.
        withoutImplicitAnimation {
            ink.frame = bounds
            if usesClassicProgress {
                layer?.mask = nil
                let track = classicTrackRect
                let path = CGMutablePath()
                path.move(to: CGPoint(x: track.minX + Classic.edge, y: track.midY))
                path.addLine(to: CGPoint(x: max(track.minX + Classic.edge, track.maxX - Classic.edge), y: track.midY))
                ink.lineWidth = max(1, track.height - Classic.edge * 2)
                ink.lineCap = .butt
                ink.lineDashPattern = [
                    NSNumber(value: Double(Classic.segmentWidth)),
                    NSNumber(value: Double(Classic.segmentGap))
                ]
                ink.path = path
                return
            }
            ink.lineDashPattern = nil
            if followsPanelContour {
                // A clay surface has no straight bottom edge from x=0 to x=width: both ends are
                // corners. Stroke the actual lower outline so every fraction remains visible and
                // the clock reads as part of the card rather than as a pill laid inside it.
                layer?.mask = nil
                ink.lineWidth = contourWidth
                ink.lineCap = .round
                ink.path = lowerContourPath
                return
            }

            layer?.mask = silhouette
            // A layer draws its border *above* its sublayers, so a line lying in the band's
            // bottom rule would be painted out by the band's own edge. It sits one rule up,
            // where the two together read as a single tinted border.
            let rule = Design.Radius.border
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: rule * 1.5))
            path.addLine(to: CGPoint(x: bounds.width, y: rule * 1.5))
            ink.lineWidth = rule
            ink.lineCap = .butt
            ink.path = path

            // Tall enough to carry the corner it is following. Only the bottom of this shape
            // does any clipping; the rest stands above the line and touches nothing.
            let radius = Design.Radius.panel
            silhouette.bounds = CGRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: max(bounds.height, radius * 2)
            )
            silhouette.position = .zero
            silhouette.cornerRadius = radius
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if usesClassicProgress {
            ThemedSurface.draw(
                classicTrackRect,
                fill: Design.Surface.controlResting,
                radius: 0,
                bevel: .sunken
            )
        }
        ink.strokeColor = inkColour.cgColor
    }

    private enum Classic {
        static let height: CGFloat = 14
        static let horizontalInset: CGFloat = 3
        static let verticalInset: CGFloat = 2
        static let edge: CGFloat = 2
        static let segmentWidth: CGFloat = 7
        static let segmentGap: CGFloat = 2
    }

    private var usesClassicProgress: Bool {
        let style = AppThemePalette.current.material(for: effectiveAppearance).progressStyle
        return style == .segmented
    }

    private var classicTrackRect: NSRect {
        bounds.insetBy(dx: Classic.horizontalInset, dy: Classic.verticalInset)
    }

    private var followsPanelContour: Bool {
        // The curved rail earns its height only on an intentionally large corner. At the
        // ordinary 8–18 point radii it turned a small rounding decision into a coloured side
        // stroke; those themes keep the compact bottom rule. Clay's 32-point card (and a custom
        // material at the same scale) gives the contour enough room to read as part of the edge.
        Design.Radius.panel >= Design.Spacing.large
    }

    private var contourWidth: CGFloat {
        max(3, Design.Radius.border * 2)
    }

    /// The toast's lower outline, inset by half the stroke so the accent replaces its edge.
    /// It joins each corner halfway around rather than climbing to the side tangent: tinting the
    /// whole quarter-circle made a countdown look like a partial side border. The path order is
    /// also the countdown order: `strokeEnd` retracts from the right corner towards the left.
    private var lowerContourPath: CGPath {
        let inset = contourWidth / 2
        let outerRadius = min(
            Design.Radius.panel,
            max(0, min(bounds.width, bounds.height * 2) / 2)
        )
        let radius = max(0, outerRadius - inset)
        let centreY = inset + radius
        let leftCentre = CGPoint(x: inset + radius, y: centreY)
        let rightCentre = CGPoint(x: max(leftCentre.x, bounds.width - inset - radius), y: centreY)

        let path = CGMutablePath()
        let leftStart = CGFloat.pi * 1.25
        path.move(to: CGPoint(
            x: leftCentre.x + cos(leftStart) * radius,
            y: leftCentre.y + sin(leftStart) * radius
        ))
        path.addArc(
            center: leftCentre,
            radius: radius,
            startAngle: leftStart,
            endAngle: .pi * 1.5,
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rightCentre.x, y: inset))
        path.addArc(
            center: rightCentre,
            radius: radius,
            startAngle: .pi * 1.5,
            endAngle: .pi * 1.75,
            clockwise: false
        )
        return path
    }

    /// The accent, whole. Re-derived on every redraw rather than stored, so a live theme switch
    /// takes the hue with it.
    ///
    /// It used to be held back to half strength, because a saturated line ruled across a card's
    /// field is the loudest thing on a sidebar reporting the least. On the edge that reasoning
    /// inverts: the line adds no ink the band was not already spending on its border, and half an
    /// accent over a hairline is not a quieter clock, it is a smudged one.
    private var inkColour: NSColor {
        let style = AppThemePalette.current.material(for: effectiveAppearance).progressStyle
        if style == .amiga {
            return WindowChromeAppearance.resolve()?.activeGradient.colors.first
                ?? Design.Surface.accent
        }
        return Design.Surface.accent
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Public Methods

    /// Drains the rail over `duration`, from full.
    func run(for duration: TimeInterval) {
        drain(from: 1, over: duration)
    }

    /// Drains what `hold` left standing over `duration` — the rest of a clock the pointer stopped.
    ///
    /// The line carries on from where it froze, at the pace it was going: the remainder it is
    /// given is the remainder the timer is on, and both were read at the same instant.
    func resume(for duration: TimeInterval) {
        drain(from: heldFraction, over: duration)
    }

    /// Stops the rail where it stands, holding what is left of it on screen.
    ///
    /// The animation comes off whether or not there is a presentation layer to read it from: a
    /// layer that has never been committed to the render server has nothing on screen to freeze,
    /// and a drain left running on a clock that has stopped is the one outcome worth ruling out.
    func hold() {
        let held: Any = ink.presentation()?.value(forKeyPath: Animation.path) ?? heldFraction
        ink.removeAnimation(forKey: Animation.key)
        let fraction = (held as? NSNumber)?.doubleValue ?? heldFraction
        withoutImplicitAnimation { ink.strokeEnd = CGFloat(fraction) }
    }

    func stop() {
        ink.removeAnimation(forKey: Animation.key)
        isHidden = true
    }

    // MARK: - Private Methods

    /// How much of the line is standing, per the model layer — which is where `hold` puts what it
    /// froze, and what an uncommitted layer has instead of a presentation to read.
    private var heldFraction: Double {
        Double(ink.strokeEnd)
    }

    private func drain(from start: Double, over duration: TimeInterval) {
        ink.removeAnimation(forKey: Animation.key)
        withoutImplicitAnimation { ink.strokeEnd = CGFloat(start) }

        // Reduce Motion takes the rail away rather than freezing it full: a still line is not a
        // slower countdown, it is a band claiming a clock it is not showing. The dwell itself is
        // unchanged, and the words and the way back are the whole receipt either way.
        guard !Design.Motion.reducesMotion, duration > 0 else {
            isHidden = true
            return
        }
        isHidden = false

        let drain = CABasicAnimation(keyPath: Animation.path)
        drain.fromValue = start
        drain.toValue = 0
        drain.duration = duration
        // Linear: time passes at one speed, and an eased countdown reports a pace nothing has.
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        drain.fillMode = .forwards
        drain.isRemovedOnCompletion = false
        ink.add(drain, forKey: Animation.key)
    }

    /// A layer animates every property it is handed unless told otherwise, and each of these
    /// assignments is a *correction* to what is on screen rather than a change to report.
    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// MARK: - The Stack

/// A receipt still waiting its turn, drawn as the edge of the card it is about to be.
///
/// Nothing with a way back on it may be thrown away to make room for the next report, so bursts
/// queue (see `ToastPresenter.present`) — and until this, the queue was invisible. A band that
/// was the only one and a band with three behind it looked exactly alike, so the only way to
/// learn another was coming was to read one, watch it leave, and be handed a second: the user
/// who turns away as the first band lands has no way to know they are turning away from more
/// than one.
///
/// It is the **same card** as the band in front, a step up and a step in on either side, so all
/// that shows of it is its top edge. Not a dimmed copy: what is behind the band is a receipt
/// exactly like it, and the depth is carried by the offset and by the front band's own glow
/// falling across it, which is where a card behind a card gets its depth anywhere else too.
///
/// It carries no words and takes no clicks — the receipt it stands for says its piece when its
/// turn comes, which is also why nothing here is announced: VoiceOver is read each band as it
/// arrives, so the stack is telling the eye what the ear is already promised.
private final class ToastStackEdgeView: NSView {

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)

        // No glow of its own: the band in front already casts one over the whole group, and a
        // second shadow under a 4-point sliver is a smudge rather than a lift.
        applySurface(
            fill: Design.Surface.elevated,
            radius: .panel,
            border: Design.Surface.border
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - The Lane

/// The strip of pane the deck moves in: the pane's full width, from its top down to the edge
/// the band rests above. It exists for the one thing a card cannot arrange for itself — **being
/// somewhere the pane does not show** — so a receipt can start below the pane's edge and rise
/// over it, and a dismissed one can drop back the same way, without either ever drawing across
/// the footer under the line or the pane next door. The footer cannot lend cover for this: it
/// draws nothing but its hairline, so a card behind it would read straight through.
///
/// Structural in the theme boundary's sense — it draws nothing and styles nothing — and it
/// crops only while a card is actually crossing the edge (`clips`, held per transition by the
/// presenter): a theme may hang up to `Design.Size.glowGutter` of shadow off a card, and a lane
/// that cropped at rest would slice that shade off every receipt it holds for the sake of
/// transitions that are not running.
///
/// It pins to the host's own top knowingly, against window-chrome's rule of thumb: nothing
/// here is content that could land under a toolbar — every card pins to the lane's *bottom*,
/// and the height above is only headroom so no receipt, however tall its words wrap, meets the
/// crop from the inside.
private final class ToastLaneView: NSView {

    /// Whether the lane crops to the pane. On only while a card is crossing the pane's edge —
    /// see the class note for why never at rest.
    var clips = false {
        didSet { layer?.masksToBounds = clips }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A full-pane overlay must not become the pane's click surface: whatever lands on a card
    /// is the card's, and everything else belongs to the list the lane is stretched over. The
    /// band's own hover-versus-row discipline depends on this staying true — see
    /// `testAPointerOnTheBandDoesNotHoverTheRowUnderneath` and its other half.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - Presenter

/// Puts one toast at a time into a pane, holds it for its dwell, and takes it away again.
///
/// Separate from the view because everything that goes wrong with a transient band is about
/// *time*, not about drawing: two of them stacking up, one outliving the thing it reports, one
/// vanishing from under the pointer that was reaching for its button. Stated once here, a host
/// contributes only where the band sits.
///
/// The host pins nothing: this owns the band's position, because "above the pane's footer,
/// inset from its edges" is the same decision in every pane that grows one — the reason
/// `PaneFooterView` owns its own geometry rather than handing hosts a constant.
@MainActor
final class ToastPresenter {

    // MARK: - Properties

    /// The dwell this presenter uses for a band that asks for none of its own. Settable so a
    /// test can watch the band leave without waiting six seconds for it.
    var dwell: TimeInterval = ToastDefaults.dwell

    private(set) var current: ToastView?

    /// Whether a band is up with its clock stopped — which is to say, whether the pointer is
    /// holding it open. Readable so the hold can be asserted at the moment it happens rather
    /// than by waiting to see whether something failed to leave.
    var isHeldOpen: Bool { current != nil && dismissal == nil }

    /// What is waiting for the band on screen to leave. Readable so a burst can be asserted on
    /// the queue rather than by sitting through it.
    var queued: [ToastRequest] { pending }

    /// The edges standing behind the band, front to back — one per waiting receipt, capped at
    /// `ToastDefaults.stackDepth`. Readable for `queued`'s reason: what the stack says is state,
    /// and a test should be able to ask for it rather than read it out of a picture.
    var stackEdges: [NSView] { deck.map(\.view) }

    /// The interval behind the current clock. Readable for the same reason as `queued`: choosing
    /// the request's dwell over the pane default is state, and tests should not sleep to infer it.
    ///
    /// After the pointer has held a band, this is what was *left* of its dwell rather than the
    /// whole of it — see `holdOpen`.
    private(set) var scheduledDwell: TimeInterval?

    /// One waiting receipt's edge and the pins holding it behind the band, kept together so a
    /// promotion can re-pin the whole deck to a new front card and a deal can raise a fresh
    /// edge from behind the band it was dealt under.
    private struct DeckEdge {
        let view: ToastStackEdgeView
        var pins: [NSLayoutConstraint]
    }

    /// The constraints that put the front band where it belongs, kept as a set so a promotion
    /// can stand a new band in the deck's front slot and then move it — bottom, both sides and
    /// the width cap together — into the resting position, rather than rebuilding it there.
    private struct Placement {

        let bottom: NSLayoutConstraint
        let leading: NSLayoutConstraint
        let fill: NSLayoutConstraint
        let cap: NSLayoutConstraint

        /// At rest: `hostInset` in from every edge of the lane, the cap at full width.
        func settle() {
            bottom.constant = -ToastDefaults.hostInset
            leading.constant = ToastDefaults.hostInset
            fill.constant = -ToastDefaults.hostInset
            cap.constant = ToastDefaults.maxWidth
        }

        /// The deck's front slot: one step up and one step in on either side, the cap stepped
        /// in with it — where a promoted receipt stands at the moment its turn comes, so it
        /// takes over exactly the silhouette of the edge that stood for it.
        func standInDeckFront() {
            bottom.constant = -ToastDefaults.hostInset - ToastDefaults.stackStep
            leading.constant = ToastDefaults.hostInset + ToastDefaults.stackInset
            fill.constant = -(ToastDefaults.hostInset + ToastDefaults.stackInset)
            cap.constant = ToastDefaults.maxWidth - ToastDefaults.stackInset * 2
        }
    }

    private weak var host: NSView?
    private let bottom: NSLayoutYAxisAnchor
    private var lane: ToastLaneView?
    private var placement: Placement?
    private var deck: [DeckEdge] = []
    private var dismissal: Timer?
    private var pending: [ToastRequest] = []

    /// How many transitions are currently crossing the pane's edge. The lane crops while any
    /// is — a count rather than a flag, because a burst walked through quickly has the next
    /// card's arrival still travelling when the one after is dismissed.
    private var clipHolds = 0 {
        didSet { lane?.clips = clipHolds > 0 }
    }

    /// What was left of the band's dwell when the pointer stopped its clock. Written when the
    /// pointer arrives and spent when it leaves; nil whenever a clock is running.
    private var heldRemainder: TimeInterval?

    // MARK: - Initialization

    /// `bottom` is what the band sits above — a pane's footer band, or the pane's own bottom
    /// edge where it has none.
    init(host: NSView, above bottom: NSLayoutYAxisAnchor) {
        self.host = host
        self.bottom = bottom
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }

    // MARK: - Public Methods

    /// Shows a toast — or lines it up behind the one already on screen.
    ///
    /// One band at a time, still: two of them in a 240-point column is a wall over the list they
    /// report on, and the second would arrive on top of the first's button. What changed is what
    /// happens to the first, and the rule is **nothing that can be taken back is dropped**.
    ///
    /// - A band **with a way back** is never replaced. Archiving four sessions in a row is four
    ///   separate undos, and the receipt that gets overwritten a quarter-second after it lands is
    ///   the one whose action nobody ever gets to press — which is exactly the safety net that
    ///   justified archiving without asking first. The later report waits its turn.
    /// - A band with **nothing to offer** is replaced where it stands. Nothing is lost, and the
    ///   newer report is the one that describes the state the user is in — the navigator's error
    ///   arriving behind its own progress message is the case.
    ///
    /// The queue is bounded (`ToastDefaults.queueLimit`), because a receipt that surfaces most of
    /// a minute after the click is news rather than a receipt. What is waiting is **visible**:
    /// each one stands behind the band as a card edge (`ToastStackEdgeView`), so a band with more
    /// coming no longer looks like the last thing that happened.
    func present(_ request: ToastRequest) {
        guard host != nil else { return }

        guard let current else { return show(request) }
        guard current.request.hasAction else {
            removeCurrent()
            return show(request)
        }

        pending.append(request)
        // Oldest out first: everything waiting reports something the user did, and the one they
        // did longest ago is the one they have had the most time to notice for themselves.
        while pending.count > ToastDefaults.queueLimit {
            pending.removeFirst()
        }
        dealDeck()
    }

    /// Takes the current band away early — the action was taken, the ✕ was pressed, the band was
    /// thrown, or what it reported no longer holds.
    ///
    /// The queue is unaffected by *how* it went: a receipt sent away by hand still hands the pane
    /// to whatever was waiting behind it, so throwing one card after another walks the deck.
    func dismiss(_ departure: ToastDeparture = .settled) {
        guard let toast = current else { return }
        stopClock()
        toast.stopDwell()
        // The departing band answers to nobody from here. Its gesture is spent, and its hover
        // must stop mattering *now*: with a successor taking over, a pointer crossing a card on
        // its way out would otherwise hold the next receipt's clock.
        toast.onAction = nil
        toast.onDismiss = nil
        toast.onHoldChanged = nil
        current = nil
        placement = nil

        // Whatever was waiting takes over in the same motion the departure makes — the front
        // card leaves and the deck steps forward behind it, which is what a deck of cards does.
        // One band *at rest* is still the rule; two sharing a departure is the departure.
        guard pending.isEmpty else {
            return promote(pending.removeFirst(), replacing: toast, by: departure)
        }
        removeStack()
        depart(toast, by: departure) { [weak self] in
            self?.dropLaneIfIdle()
        }
    }

    /// Sends a band the rest of the way out of the pane — down the way it came, or on along the
    /// way it was thrown — and removes it once it has gone. A band that was pushed sideways does
    /// not then drop: the throw is half an animation the hand already performed, and the
    /// departure owes it the other half.
    private func depart(
        _ toast: ToastView,
        by departure: ToastDeparture,
        then completion: (() -> Void)? = nil
    ) {
        guard Design.Motion.travel > 0 else {
            toast.removeFromSuperview()
            completion?()
            return
        }
        holdClip()
        NSAnimationContext.runAnimationGroup({ context in
            switch departure {
            case .settled:
                // Falling, not lowering itself: a dismissed card leaves on gravity's curve —
                // and at travel's length rather than vanish's, because it has the same ground
                // to cover leaving as it had arriving.
                context.duration = Design.Motion.travel
                context.timingFunction = ToastDefaults.drop
            case .thrown:
                // Quick, because the hand already supplied the first half of this movement and
                // is owed the rest at the speed it meant.
                context.duration = Design.Motion.vanish
            }
            context.allowsImplicitAnimation = true
            switch departure {
            case .settled:
                toast.dropOut()
            case .thrown(let direction):
                toast.flyOut(direction)
                // The carry already faded the band towards `dragAway`; the flight finishes that
                // fade as it finishes the translation. Both belong to the gesture — the settled
                // departure, which is a transition and not a gesture, fades nothing.
                toast.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                toast.removeFromSuperview()
                self?.releaseClip()
                completion?()
            }
        })
    }

    /// Brings the next receipt forward in the departing band's own motion: the new band starts
    /// in the deck's front slot — the position of the edge that has been standing for it — and
    /// settles into the resting one while the old band drops or flies, the surviving edges
    /// step one slot shallower behind it, and any receipt newly entitled to an edge rises from
    /// behind the band. Nothing fades; every card is somewhere the whole time.
    private func promote(
        _ request: ToastRequest,
        replacing departing: ToastView,
        by departure: ToastDeparture
    ) {
        guard let host, let lane else { return }

        let next = makeToast(for: request)
        // From behind: under the band on its way out, over everything still waiting.
        lane.addSubview(next, positioned: .below, relativeTo: departing)
        current = next
        let placement = place(next, in: lane)
        self.placement = placement

        // The deck's front edge is the card this receipt has been standing behind the band
        // *as*; the real band takes its place before anything moves.
        if !deck.isEmpty {
            let replaced = deck.removeFirst()
            NSLayoutConstraint.deactivate(replaced.pins)
            replaced.view.removeFromSuperview()
        }

        guard Design.Motion.travel > 0 else {
            squareDeck(behind: next, staged: false)
            departing.removeFromSuperview()
            host.layoutSubtreeIfNeeded()
            announce(request)
            scheduleDismissal()
            return
        }

        placement.standInDeckFront()
        // Freeze the starting picture: the new band in the front slot, the survivors still
        // pinned behind the departing band — which their pins may be, since its exit is a
        // transform and never moves its frame.
        host.layoutSubtreeIfNeeded()

        placement.settle()
        let dealt = squareDeck(behind: next, staged: true)
        holdClip()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.travel
            context.timingFunction = ToastDefaults.glide
            context.allowsImplicitAnimation = true
            raiseDeck(dealt)
            host.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.releaseClip() }
        })
        depart(departing, by: departure)

        announce(request)
        scheduleDismissal()
    }

    /// Ends this presenter's ownership immediately. Pane owners normally get this through
    /// `deinit`; short-lived off-screen renderers call it explicitly because AppKit may extend a
    /// local object's debug lifetime beyond its lexical scope while its layer work is committed.
    func invalidate() {
        stopClock()
        pending.removeAll()
        current?.stopDwell()
        current?.removeFromSuperview()
        current = nil
        placement = nil
        removeStack()
        // The lane goes synchronously and takes every card with it — the one at rest and any
        // still mid-departure: a pane being torn down must not have to wait out an animation
        // to be rid of its overlay.
        clipHolds = 0
        lane?.removeFromSuperview()
        lane = nil
    }

    // MARK: - Private Methods

    private func show(_ request: ToastRequest) {
        guard let host else { return }
        let lane = ensureLane(in: host)

        let toast = makeToast(for: request)
        // Topmost in the lane: over a band still finishing its own departure, and over
        // everything waiting in the deck.
        lane.addSubview(toast, positioned: .above, relativeTo: nil)
        current = toast
        let placement = place(toast, in: lane)
        self.placement = placement

        // Built before the arrival rather than after it, so a band that is already the front of
        // a queue rises with its deck behind it instead of growing one a frame later — the deck
        // is pinned to the band, so the one staging below carries the other.
        squareDeck(behind: toast, staged: false)

        if Design.Motion.travel > 0 {
            // The band arrives from below the pane's edge, whole: no fade, just ground to
            // cover. How far below is its own height plus the deck peeking over it, which is
            // not known until its words have wrapped — hence a layout at rest first.
            host.layoutSubtreeIfNeeded()
            placement.bottom.constant = toast.frame.height
                + ToastDefaults.stackStep * CGFloat(deck.count)
                + ToastDefaults.clearance
            host.layoutSubtreeIfNeeded()

            placement.settle()
            holdClip()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Design.Motion.travel
                context.timingFunction = ToastDefaults.glide
                context.allowsImplicitAnimation = true
                host.layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.releaseClip() }
            })
        } else {
            host.layoutSubtreeIfNeeded()
        }

        announce(request)
        scheduleDismissal()
    }

    /// The band, wired to this presenter: the way back dismisses through the caller's undo, the
    /// way out and the throw dismiss directly, and both holds — pointer and carry — arrive as
    /// the one signal the view reports.
    private func makeToast(for request: ToastRequest) -> ToastView {
        let toast = ToastView(request: request)
        toast.onAction = { [weak self] in
            request.action?()
            self?.dismiss()
        }
        toast.onDismiss = { [weak self] departure in
            self?.dismiss(departure)
        }
        toast.onHoldChanged = { [weak self] isHeld in
            guard let self else { return }
            isHeld ? holdOpen() : scheduleDismissal()
        }
        return toast
    }

    /// Pins a band into the lane and hands back the constraints a transition moves.
    ///
    /// The fill pin: the band fills the column it is given, up to its cap. It is breakable so
    /// the cap wins in a pane wider than the band should ever be — and weaker than the pane's
    /// own hold on its width, so losing to the cap never narrows the pane to make up the
    /// difference; the lane's edges are required-equal to the pane's, so every priority
    /// relationship reads through it unchanged. See `ToastDefaults.fillPriority`.
    private func place(_ toast: ToastView, in lane: ToastLaneView) -> Placement {
        let fill = toast.trailingAnchor.constraint(
            equalTo: lane.trailingAnchor,
            constant: -ToastDefaults.hostInset
        )
        fill.priority = ToastDefaults.fillPriority

        let placement = Placement(
            bottom: toast.bottomAnchor.constraint(
                equalTo: lane.bottomAnchor,
                constant: -ToastDefaults.hostInset
            ),
            leading: toast.leadingAnchor.constraint(
                equalTo: lane.leadingAnchor,
                constant: ToastDefaults.hostInset
            ),
            fill: fill,
            cap: toast.widthAnchor.constraint(lessThanOrEqualToConstant: ToastDefaults.maxWidth)
        )
        NSLayoutConstraint.activate([
            placement.bottom,
            placement.leading,
            placement.fill,
            placement.cap,
            toast.trailingAnchor.constraint(
                lessThanOrEqualTo: lane.trailingAnchor,
                constant: -ToastDefaults.hostInset
            )
        ])
        return placement
    }

    /// The lane every card lives in, made on the first receipt and kept while any card is up.
    private func ensureLane(in host: NSView) -> ToastLaneView {
        if let lane, lane.superview === host { return lane }
        let lane = ToastLaneView()
        host.addSubview(lane, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            lane.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            lane.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            lane.topAnchor.constraint(equalTo: host.topAnchor),
            lane.bottomAnchor.constraint(equalTo: bottom)
        ])
        self.lane = lane
        return lane
    }

    /// Removes the lane once nothing is left to hold it — the pane must not keep an invisible
    /// overlay for having once shown a receipt. Departure completions call this; one that lands
    /// after a new receipt has already arrived finds `current` set and leaves the lane alone.
    private func dropLaneIfIdle() {
        guard current == nil, deck.isEmpty else { return }
        lane?.removeFromSuperview()
        lane = nil
        clipHolds = 0
    }

    private func holdClip() {
        clipHolds += 1
    }

    private func releaseClip() {
        clipHolds = max(0, clipHolds - 1)
    }

    /// Removes the band outright, with no animation and without running its action. Used when a
    /// receipt with nothing to offer is replaced: sending one out while the next slides in over
    /// it reads as a glitch rather than as a replacement.
    private func removeCurrent() {
        stopClock()
        current?.stopDwell()
        current?.removeFromSuperview()
        current = nil
        placement = nil
        removeStack()
    }

    /// Deals the newly waiting receipt's edge in behind the band.
    ///
    /// It arrives the way everything here moves — as a card, from somewhere: dealt at the
    /// band's own silhouette, exactly hidden behind it, and risen from there into its slot. The
    /// band itself never moves, so the only motion is a sliver of card emerging above an edge
    /// the reader already has, which is the report ("another is coming") drawn as the movement
    /// that causes it.
    private func dealDeck() {
        guard let toast = current else { return removeStack() }
        let staged = Design.Motion.travel > 0
        let dealt = squareDeck(behind: toast, staged: staged)
        guard staged, !dealt.isEmpty else { return }
        host?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.travel
            context.timingFunction = ToastDefaults.glide
            context.allowsImplicitAnimation = true
            raiseDeck(dealt)
            host?.layoutSubtreeIfNeeded()
        }
    }

    /// Squares the deck with what is actually waiting, pinned behind `front`.
    ///
    /// Grown from the front, because the z-order is the whole illusion: an edge added for a
    /// receipt that arrived later belongs *behind* the ones already standing there, and
    /// `addSubview(_:positioned:relativeTo:)` puts a view directly under whichever one it is
    /// handed — so each new edge goes under the last, and the first goes under the band.
    ///
    /// Edges already standing are re-pinned to `front` at their current index's depth, which is
    /// how a promotion steps the deck forward: the pin swap is instant and moves nothing by
    /// itself — the caller's animated layout is what carries each edge from where it stands to
    /// where its new pins say. A `staged` deal adds new edges at the band's own silhouette —
    /// depth zero, exactly hidden — and returns them still standing there; the caller owes them
    /// `raiseDeck` inside whatever animation carries the rest of its transition.
    @discardableResult
    private func squareDeck(behind front: ToastView, staged: Bool) -> [DeckEdge] {
        guard let lane else { return [] }
        let wanted = min(pending.count, ToastDefaults.stackDepth)
        while deck.count > wanted {
            deck.removeLast().view.removeFromSuperview()
        }

        for (index, edge) in deck.enumerated() {
            NSLayoutConstraint.deactivate(edge.pins)
            let pins = deckPins(for: edge.view, behind: front, depth: CGFloat(index + 1))
            NSLayoutConstraint.activate(pins)
            deck[index].pins = pins
        }

        var dealt: [DeckEdge] = []
        while deck.count < wanted {
            let depth = CGFloat(deck.count + 1)
            let edge = ToastStackEdgeView()
            lane.addSubview(edge, positioned: .below, relativeTo: deck.last?.view ?? front)
            let pins = deckPins(for: edge, behind: front, depth: staged ? 0 : depth)
            NSLayoutConstraint.activate(pins)
            if staged {
                // The start frame, committed by hand: a promotion deals this edge *after* the
                // freeze layout, and a view that enters an animated layout with no frame of its
                // own animates in from a zero rect at the pane's corner. At depth zero its pins
                // resolve to the band's own frame, which the band already has.
                edge.frame = front.frame
            }
            let record = DeckEdge(view: edge, pins: pins)
            deck.append(record)
            dealt.append(record)
        }
        return dealt
    }

    /// The four pins that stand an edge behind its band — pinned to the band's own two edges
    /// rather than given a height of its own: the card behind *is* the same card, lifted, so
    /// everything below the band's top edge is behind an opaque surface however tall the
    /// receipt in front turns out to be — and the theme's corner radius never has to be
    /// measured into a constant here. In `reslot`'s order.
    private func deckPins(
        for edge: NSView,
        behind front: ToastView,
        depth: CGFloat
    ) -> [NSLayoutConstraint] {
        [
            edge.topAnchor.constraint(
                equalTo: front.topAnchor,
                constant: -ToastDefaults.stackStep * depth
            ),
            edge.bottomAnchor.constraint(
                equalTo: front.bottomAnchor,
                constant: -ToastDefaults.stackStep * depth
            ),
            edge.leadingAnchor.constraint(
                equalTo: front.leadingAnchor,
                constant: ToastDefaults.stackInset * depth
            ),
            edge.trailingAnchor.constraint(
                equalTo: front.trailingAnchor,
                constant: -ToastDefaults.stackInset * depth
            )
        ]
    }

    /// Moves an edge's pins to another slot without re-making them, in `deckPins`' order.
    private func reslot(_ pins: [NSLayoutConstraint], to depth: CGFloat) {
        guard pins.count == 4 else { return }
        pins[0].constant = -ToastDefaults.stackStep * depth
        pins[1].constant = -ToastDefaults.stackStep * depth
        pins[2].constant = ToastDefaults.stackInset * depth
        pins[3].constant = -ToastDefaults.stackInset * depth
    }

    /// Lifts freshly dealt edges from behind the band into their slots — called inside an
    /// animation group, so the rise rides whatever else that transition is moving.
    private func raiseDeck(_ dealt: [DeckEdge]) {
        for record in dealt {
            guard let index = deck.firstIndex(where: { $0.view === record.view }) else { continue }
            reslot(record.pins, to: CGFloat(index + 1))
        }
    }

    /// Takes the stack away outright — the band it stood behind is going with no departure of its
    /// own, or there is no band left to stand behind.
    private func removeStack() {
        deck.forEach { $0.view.removeFromSuperview() }
        deck.removeAll()
    }

    /// Starts the band's clock, and the countdown it shows for it. One method, because a rail
    /// draining on a band whose timer says something else is worse than no rail at all.
    ///
    /// A band the pointer was holding picks its clock back up rather than starting a new one: the
    /// dwell is the time a receipt gets to be read, and time spent reading it under the pointer is
    /// that time being used. Restarting instead meant a pointer crossing the band on its way
    /// somewhere else bought the receipt a whole second dwell, and a band leant on and released
    /// twice never had to leave at all.
    private func scheduleDismissal() {
        let resumed = heldRemainder
        stopClock()
        guard let current else { return }
        let interval = resumed ?? (current.request.dwell ?? dwell)
        scheduledDwell = interval
        dismissal = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        resumed == nil ? current.startDwell(interval) : current.resumeDwell(interval)
    }

    /// The pointer is on the band, so the clock stops: a way back that expires while it is being
    /// reached for is worse than no way back, because the reach is the moment the person has
    /// already decided.
    ///
    /// What was left of it is kept, because the pointer leaving is not a new receipt — the timer
    /// is read for the remainder before it is cancelled, so the clock the band goes back on is
    /// the one it came off.
    private func holdOpen() {
        let remainder = dismissal.map { max(0, $0.fireDate.timeIntervalSinceNow) }
        stopClock()
        heldRemainder = remainder
        current?.holdDwell()
    }

    /// Ends the current clock outright. The remainder goes with it: what is kept across a pause is
    /// written by `holdOpen` alone, so a band arriving after one cannot inherit it.
    private func stopClock() {
        dismissal?.invalidate()
        dismissal = nil
        scheduledDwell = nil
        heldRemainder = nil
    }

    /// The band takes no focus and disappears by itself, so without this it is invisible to
    /// VoiceOver — the one part of the audience that cannot glance at a corner of the window.
    private func announce(_ request: ToastRequest) {
        guard let element = host?.window else { return }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: request.announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
