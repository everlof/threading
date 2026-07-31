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

    /// How far the band travels as it arrives, and back as it leaves. A short slide, because
    /// the movement is only there to say the band was not always on screen.
    static let rise: CGFloat = 8

    /// Between the band's edge and its content.
    static let contentInset: CGFloat = Design.Spacing.inset

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
    /// The band takes the width it is given and wraps inside it. Only the words are silenced:
    /// the action keeps its own resistance, because a way back too narrow to read is not one.
    static let contentWidthPriority = NSLayoutConstraint.Priority(1)

    /// The countdown rail: how thick it is, and how far its underside sits above the band's
    /// bottom edge. It lives *inside* the band's bottom inset rather than under the content, so
    /// showing the clock costs the band no height.
    static let dwellRailThickness: CGFloat = 2
    static let dwellRailBottomInset: CGFloat = Design.Spacing.tight

    /// How much accent the rail carries.
    ///
    /// Held back, because a full-strength accent ruled across a card is a progress bar, and this
    /// is a thing you are meant to notice only if you are already looking for it — the receipt's
    /// words are what the band is for. At full strength under System it drew a saturated blue
    /// line under two lines of grey text, which is the loudest thing on the sidebar reporting the
    /// least. Increase Contrast takes the whole reduction back: a faint tint is the first thing
    /// that preference exists to undo.
    static let dwellRailOpacity: CGFloat = 0.5

    /// How many receipts may wait behind the one on screen.
    ///
    /// Bounded because the queue is measured in *dwells*: at four deep the last band arrives
    /// most of a minute after the click it reports, by which point it is news rather than a
    /// receipt. When a burst overruns this, the oldest waiting receipt is the one dropped — its
    /// action is the one the user has had longest to miss, and for the archive the way back is
    /// still in Settings, which is what the band's own detail line says.
    static let queueLimit = 3
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
/// The band handles no clicks of its own. Its action is a `ThemedButton`, which is what gives
/// the way back a keyboard route, a focus ring and an accessible name for free — and what keeps
/// this class out of the interactive-component contract, which exists so that a *drawn control*
/// cannot be mouse-only. Hover is the exception, and it is not an interaction: the presenter
/// reads it to hold the clock while somebody is reaching for the button.
final class ToastView: NSView {

    // MARK: - Properties

    /// Pressed the way back. The presenter dismisses the band; the caller undoes the work.
    var onAction: (() -> Void)?

    /// Whether the pointer is on the band. Reported rather than acted on, because what it means
    /// — the dwell pauses — is the presenter's decision and not this view's.
    var onHoverChanged: ((Bool) -> Void)?

    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            onHoverChanged?(isHovered)
        }
    }

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
    private let dwellRail = ToastDwellRail()
    private var hoverTracking: NSTrackingArea?

    // MARK: - Initialization

    init(request: ToastRequest) {
        self.request = request
        messageLabel = NSTextField(wrappingLabelWithString: request.message)
        detailLabel = request.detail.map { NSTextField(wrappingLabelWithString: $0) }
        actionButton = request.hasAction
            ? ThemedButton(title: request.actionTitle ?? "", target: nil, action: nil)
            : nil

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        configureLabels()
        configureAction()
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
    /// here is whatever the host column left — capped, but never fixed. Guarded on the value
    /// actually changing: assigning it unconditionally in `layout()` invalidates the size that
    /// caused the layout.
    override func layout() {
        super.layout()
        let available = max(0, bounds.width - ToastDefaults.contentInset * 2)
        for label in [messageLabel, detailLabel].compactMap({ $0 })
        where abs(label.preferredMaxLayoutWidth - available) > 0.5 {
            label.preferredMaxLayoutWidth = available
            label.invalidateIntrinsicContentSize()
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

    // MARK: - The Clock, Drawn

    /// Starts the countdown the band shows for its own dwell, from full.
    ///
    /// From full rather than from where it stopped, because that is what the clock behind it
    /// does: releasing a held band schedules a *fresh* dwell rather than the remainder of the
    /// old one, and a rail resuming from a third full would promise less time than the band has.
    func startDwell(_ duration: TimeInterval) {
        isDwellRunning = true
        dwellRail.run(for: duration)
    }

    /// Freezes the countdown where it stands — the pointer is on the band and its clock stopped.
    func holdDwell() {
        isDwellRunning = false
        dwellRail.hold()
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
        // arrived and back again as it left.
        for label in [messageLabel, detailLabel].compactMap({ $0 }) {
            label.setContentCompressionResistancePriority(
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

    private func installContent() {
        addSubview(messageLabel)
        detailLabel.map { addSubview($0) }
        actionButton.map { addSubview($0) }
        addSubview(dwellRail)

        let inset = ToastDefaults.contentInset
        var constraints: [NSLayoutConstraint] = [
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            // The rail runs under the words, aligned with their ink, and sits *in* the band's
            // own bottom inset rather than in a row of its own: the clock says nothing the
            // content says, so it must not make the band any taller than the receipt is.
            dwellRail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            dwellRail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            dwellRail.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -ToastDefaults.dwellRailBottomInset
            )
        ]

        var lastText: NSView = messageLabel
        if let detailLabel {
            constraints += [
                detailLabel.topAnchor.constraint(
                    equalTo: messageLabel.bottomAnchor,
                    constant: Design.Spacing.hairline
                ),
                detailLabel.leadingAnchor.constraint(equalTo: messageLabel.leadingAnchor),
                detailLabel.trailingAnchor.constraint(equalTo: messageLabel.trailingAnchor)
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
            constraints += [
                actionButton.topAnchor.constraint(
                    equalTo: lastText.bottomAnchor,
                    constant: Design.Spacing.small
                ),
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

/// The band's clock, drawn: a hairline in the accent that empties as the dwell runs down.
///
/// A band that leaves on its own is the one surface in the window whose *remaining* time is
/// worth knowing — the receipt is only useful while the way back is still on it, and without
/// this the only way to learn how long that is was to lose it once. Drawn as a line rather than
/// as a number because it is read at the edge of vision, on a band nobody opened.
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
        static let path = "transform.scale.x"
    }

    private let ink = CALayer()
    private var themeRedraw: ThemeRedraw?

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Anchored at the leading edge so scaling it down eats the line from the trailing end.
        ink.anchorPoint = CGPoint(x: 0, y: 0.5)
        ink.cornerCurve = .continuous
        layer?.addSublayer(ink)

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

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ToastDefaults.dwellRailThickness)
    }

    override func layout() {
        super.layout()
        // The model geometry only: a running drain is a transform on top of this, and assigning
        // bounds mid-animation would move the line without touching what it is scaling from.
        withoutImplicitAnimation {
            ink.bounds = CGRect(origin: .zero, size: bounds.size)
            ink.position = CGPoint(x: 0, y: bounds.midY)
            // The pill token rather than half the height: a style that squares its cards squares
            // this too, which is a point of difference at two points tall and the rule anyway.
            ink.cornerRadius = Design.Radius.pill(height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ink.backgroundColor = inkColour.cgColor
    }

    /// The accent, held back — and handed over whole under Increase Contrast. Re-derived on every
    /// redraw rather than stored, so a live theme switch takes the hue with it.
    private var inkColour: NSColor {
        let accent = Design.Surface.accent
        guard !Design.Accessibility.increasesContrast else { return accent }
        return accent.withAlphaComponent(ToastDefaults.dwellRailOpacity)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Public Methods

    /// Drains the rail over `duration`, from full.
    func run(for duration: TimeInterval) {
        ink.removeAnimation(forKey: Animation.key)
        withoutImplicitAnimation { ink.setValue(1, forKeyPath: Animation.path) }

        // Reduce Motion takes the rail away rather than freezing it full: a still line is not a
        // slower countdown, it is a band claiming a clock it is not showing. The dwell itself is
        // unchanged, and the words and the way back are the whole receipt either way.
        guard !Design.Motion.reducesMotion, duration > 0 else {
            isHidden = true
            return
        }
        isHidden = false

        let drain = CABasicAnimation(keyPath: Animation.path)
        drain.fromValue = 1
        drain.toValue = 0
        drain.duration = duration
        // Linear: time passes at one speed, and an eased countdown reports a pace nothing has.
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        drain.fillMode = .forwards
        drain.isRemovedOnCompletion = false
        ink.add(drain, forKey: Animation.key)
    }

    /// Stops the rail where it stands, holding what is left of it on screen.
    ///
    /// The animation comes off whether or not there is a presentation layer to read it from: a
    /// layer that has never been committed to the render server has nothing on screen to freeze,
    /// and a drain left running on a clock that has stopped is the one outcome worth ruling out.
    func hold() {
        let held: Any = ink.presentation()?.value(forKeyPath: Animation.path) ?? 1
        ink.removeAnimation(forKey: Animation.key)
        withoutImplicitAnimation { ink.setValue(held, forKeyPath: Animation.path) }
    }

    // MARK: - Private Methods

    /// A layer animates every property it is handed unless told otherwise, and each of these
    /// assignments is a *correction* to what is on screen rather than a change to report.
    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
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

    private weak var host: NSView?
    private let bottom: NSLayoutYAxisAnchor
    private var bottomConstraint: NSLayoutConstraint?
    private var dismissal: Timer?
    private var pending: [ToastRequest] = []

    // MARK: - Initialization

    /// `bottom` is what the band sits above — a pane's footer band, or the pane's own bottom
    /// edge where it has none.
    init(host: NSView, above bottom: NSLayoutYAxisAnchor) {
        self.host = host
        self.bottom = bottom
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
    /// a minute after the click is news rather than a receipt.
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
    }

    /// Takes the current band away early — the action was taken, or what it reported no longer
    /// holds.
    func dismiss() {
        guard let toast = current else { return }
        stopClock()
        current = nil

        bottomConstraint?.constant = -ToastDefaults.hostInset - ToastDefaults.rise
        let host = self.host
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.vanish
            context.allowsImplicitAnimation = true
            toast.animator().alphaValue = 0
            host?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self, weak toast] in
            MainActor.assumeIsolated {
                toast?.removeFromSuperview()
                // After the departure rather than during it: the next receipt sliding up through
                // the one leaving is two bands on screen, which is the thing the queue exists to
                // avoid.
                self?.showNext()
            }
        })
    }

    // MARK: - Private Methods

    private func show(_ request: ToastRequest) {
        guard let host else { return }

        let toast = ToastView(request: request)
        toast.onAction = { [weak self] in
            request.action?()
            self?.dismiss()
        }
        toast.onHoverChanged = { [weak self] isHovered in
            guard let self else { return }
            isHovered ? holdOpen() : scheduleDismissal()
        }

        // Topmost in the pane: the band floats over the list, the settings sidebar, and
        // anything else the pane swaps in beneath it.
        host.addSubview(toast, positioned: .above, relativeTo: nil)
        current = toast

        let bottomConstraint = toast.bottomAnchor.constraint(
            equalTo: bottom,
            constant: -ToastDefaults.hostInset - ToastDefaults.rise
        )
        self.bottomConstraint = bottomConstraint

        // Fills the column it is given, up to its cap. The trailing pin is breakable so the cap
        // wins in a pane wider than the band should ever be.
        let trailing = toast.trailingAnchor.constraint(
            equalTo: host.trailingAnchor,
            constant: -ToastDefaults.hostInset
        )
        trailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            bottomConstraint,
            trailing,
            toast.leadingAnchor.constraint(
                equalTo: host.leadingAnchor,
                constant: ToastDefaults.hostInset
            ),
            toast.trailingAnchor.constraint(
                lessThanOrEqualTo: host.trailingAnchor,
                constant: -ToastDefaults.hostInset
            ),
            toast.widthAnchor.constraint(lessThanOrEqualToConstant: ToastDefaults.maxWidth)
        ])

        toast.alphaValue = 0
        host.layoutSubtreeIfNeeded()

        bottomConstraint.constant = -ToastDefaults.hostInset
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.appear
            context.allowsImplicitAnimation = true
            toast.animator().alphaValue = 1
            host.layoutSubtreeIfNeeded()
        }

        announce(request)
        scheduleDismissal()
    }

    /// Brings up whatever a departing band was holding the pane for.
    private func showNext() {
        guard current == nil, !pending.isEmpty else { return }
        show(pending.removeFirst())
    }

    /// Removes the band outright, with no animation and without running its action. Used when a
    /// receipt with nothing to offer is replaced: fading one out while the next slides in over it
    /// reads as a glitch rather than as a replacement.
    private func removeCurrent() {
        stopClock()
        current?.removeFromSuperview()
        current = nil
        bottomConstraint = nil
    }

    /// Starts the band's clock, and the countdown it shows for it. One method, because a rail
    /// draining on a band whose timer says something else is worse than no rail at all.
    private func scheduleDismissal() {
        stopClock()
        guard let current else { return }
        let interval = current.request.dwell ?? dwell
        dismissal = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        current.startDwell(interval)
    }

    /// The pointer is on the band, so the clock stops: a way back that expires while it is being
    /// reached for is worse than no way back, because the reach is the moment the person has
    /// already decided.
    private func holdOpen() {
        stopClock()
        current?.holdDwell()
    }

    private func stopClock() {
        dismissal?.invalidate()
        dismissal = nil
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
