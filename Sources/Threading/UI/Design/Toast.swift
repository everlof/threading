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

            // Flush to three edges, and no inset anywhere: the clock is the band's own bottom
            // border, tinted, rather than a rule laid across the band's field. It sits *in* the
            // band's bottom inset rather than in a row of its own, so it says nothing the
            // content says and makes the band no taller than the receipt is.
            dwellRail.leadingAnchor.constraint(equalTo: leadingAnchor),
            dwellRail.trailingAnchor.constraint(equalTo: trailingAnchor),
            dwellRail.bottomAnchor.constraint(equalTo: bottomAnchor)
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
        AppThemePalette.current.material(for: effectiveAppearance).progressStyle == .segmented
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
    private var inkColour: NSColor { Design.Surface.accent }

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
    private(set) var stackEdges: [NSView] = []

    /// The interval behind the current clock. Readable for the same reason as `queued`: choosing
    /// the request's dwell over the pane default is state, and tests should not sleep to infer it.
    ///
    /// After the pointer has held a band, this is what was *left* of its dwell rather than the
    /// whole of it — see `holdOpen`.
    private(set) var scheduledDwell: TimeInterval?

    private weak var host: NSView?
    private let bottom: NSLayoutYAxisAnchor
    private var bottomConstraint: NSLayoutConstraint?
    private var dismissal: Timer?
    private var pending: [ToastRequest] = []

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
        refreshStack(animated: true)
    }

    /// Takes the current band away early — the action was taken, or what it reported no longer
    /// holds.
    func dismiss() {
        guard let toast = current else { return }
        stopClock()
        toast.stopDwell()
        current = nil

        // The stack leaves with the band it stands behind, and is handed to the departure rather
        // than kept: its edges are pinned to a band that is on its way out, and the receipt
        // arriving next builds its own from what is left waiting.
        let leaving: [NSView] = [toast] + stackEdges
        stackEdges = []

        bottomConstraint?.constant = -ToastDefaults.hostInset - ToastDefaults.rise
        let host = self.host
        guard Design.Motion.vanish > 0 else {
            leaving.forEach { $0.alphaValue = 0 }
            host?.layoutSubtreeIfNeeded()
            leaving.forEach { $0.removeFromSuperview() }
            bottomConstraint = nil
            showNext()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.vanish
            context.allowsImplicitAnimation = true
            leaving.forEach { $0.animator().alphaValue = 0 }
            host?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self, leaving] in
            MainActor.assumeIsolated {
                leaving.forEach { $0.removeFromSuperview() }
                if self?.current == nil { self?.bottomConstraint = nil }
                // After the departure rather than during it: the next receipt sliding up through
                // the one leaving is two bands on screen, which is the thing the queue exists to
                // avoid.
                self?.showNext()
            }
        })
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
        removeStack()
        // A stack handed to a departure is no longer this presenter's to name, and a pane being
        // torn down must not have to wait out an animation to be rid of it.
        host?.subviews
            .compactMap { $0 as? ToastStackEdgeView }
            .forEach { $0.removeFromSuperview() }
        bottomConstraint = nil
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
        // wins in a pane wider than the band should ever be — and weaker than the pane's own
        // hold on its width, so losing to the cap never narrows the pane to make up the
        // difference. See `ToastDefaults.fillPriority`.
        let trailing = toast.trailingAnchor.constraint(
            equalTo: host.trailingAnchor,
            constant: -ToastDefaults.hostInset
        )
        trailing.priority = ToastDefaults.fillPriority

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

        // Built before the arrival rather than after it, so a band that is already the front of a
        // queue rises with its stack behind it instead of growing one a frame later.
        refreshStack(animated: false)

        let arriving: [NSView] = [toast] + stackEdges
        arriving.forEach { $0.alphaValue = 0 }
        host.layoutSubtreeIfNeeded()

        bottomConstraint.constant = -ToastDefaults.hostInset
        if Design.Motion.appear > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Design.Motion.appear
                context.allowsImplicitAnimation = true
                arriving.forEach { $0.animator().alphaValue = 1 }
                host.layoutSubtreeIfNeeded()
            }
        } else {
            arriving.forEach { $0.alphaValue = 1 }
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
        current?.stopDwell()
        current?.removeFromSuperview()
        current = nil
        removeStack()
        bottomConstraint = nil
    }

    /// Squares the stack behind the band with what is actually waiting.
    ///
    /// Grown from the front, because the z-order is the whole illusion: an edge added for a
    /// receipt that arrived later belongs *behind* the ones already standing there, and
    /// `addSubview(_:positioned:relativeTo:)` puts a view directly under whichever one it is
    /// handed — so each new edge goes under the last, and the first goes under the band.
    private func refreshStack(animated: Bool) {
        guard let host, let toast = current else { return removeStack() }

        let wanted = min(pending.count, ToastDefaults.stackDepth)
        while stackEdges.count > wanted {
            stackEdges.removeLast().removeFromSuperview()
        }
        guard stackEdges.count < wanted else { return }

        var arrived: [NSView] = []
        while stackEdges.count < wanted {
            let depth = CGFloat(stackEdges.count + 1)
            let edge = ToastStackEdgeView()
            host.addSubview(edge, positioned: .below, relativeTo: stackEdges.last ?? toast)

            // Pinned to the band's own two edges rather than given a height of its own: the card
            // behind *is* the same card, lifted, so everything below the band's top edge is
            // behind an opaque surface however tall the receipt in front turns out to be — and
            // the theme's corner radius never has to be measured into a constant here.
            NSLayoutConstraint.activate([
                edge.topAnchor.constraint(
                    equalTo: toast.topAnchor,
                    constant: -ToastDefaults.stackStep * depth
                ),
                edge.bottomAnchor.constraint(
                    equalTo: toast.bottomAnchor,
                    constant: -ToastDefaults.stackStep * depth
                ),
                edge.leadingAnchor.constraint(
                    equalTo: toast.leadingAnchor,
                    constant: ToastDefaults.stackInset * depth
                ),
                edge.trailingAnchor.constraint(
                    equalTo: toast.trailingAnchor,
                    constant: -ToastDefaults.stackInset * depth
                )
            ])
            stackEdges.append(edge)
            arrived.append(edge)
        }

        // A fade rather than a slide: the band does not move when something lines up behind it,
        // and an edge sliding out from under a receipt somebody is reading is motion drawing the
        // eye away from the thing the motion is *about*.
        guard animated, Design.Motion.appear > 0 else { return }
        arrived.forEach { $0.alphaValue = 0 }
        host.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.appear
            context.allowsImplicitAnimation = true
            arrived.forEach { $0.animator().alphaValue = 1 }
        }
    }

    /// Takes the stack away outright — the band it stood behind is going with no departure of its
    /// own, or there is no band left to stand behind.
    private func removeStack() {
        stackEdges.forEach { $0.removeFromSuperview() }
        stackEdges.removeAll()
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
