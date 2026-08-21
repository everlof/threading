import AppKit

// MARK: - Limit Escape Strip

/// The offer over a session whose provider refused its turn for a spent usage limit: what
/// happened, one login to carry on under, and the way to be rid of the offer.
///
/// **One tap, and the button names its whole action.** `limit-recovery.md` makes the migrating
/// policies something a user arms in advance, because they type into somebody's session and spend
/// their quota with nobody watching; here the press *is* the watching, so there is no second
/// dialog to confirm what the button already says on its face — and no opt-in in front of it.
///
/// **Not a `PaneNoticeView`.** That band is a condition the *pane* found — it spans the pane, it
/// pushes the header apart from the content, and one of them at a time is chrome. This is a
/// condition of one conversation, drawn on that conversation's own column beside what is waiting
/// to be sent into it, which is where the answer to it belongs.
///
/// One direction, like `ScheduledMessageStripView`: the store is the truth, this draws what it is
/// handed, and both gestures are reported back as intentions.
final class LimitEscapeStripView: NSView, ThemedComponent, PointerClaiming {

    // MARK: - Offer

    /// What the strip says, already resolved by its owner. Not a `LimitEscapeSuggestion`, for the
    /// reason the scheduled strip's `Row` is not a `ScheduledMessage`: a view holding the model
    /// would have to decide which of its states are the user's business.
    struct Offer: Equatable {

        /// Who stopped this conversation, which decides the mark and the words.
        ///
        /// **The strip is shared and the mark is not.** `ThemedWarningMark` means "the provider
        /// stopped this and you cannot answer it"; a line the user drew is conduct, not weather,
        /// and wearing the triangle for it would teach the reader that the triangle is sometimes
        /// negotiable. Same surface, same geometry, same two offers — a different mark, a
        /// different sentence, and a Continue that says *Anyway*.
        enum Source: Equatable {
            case provider
            case ownLimit
        }

        var source: Source = .provider

        /// The login the account button offers, named after the person. **Nil is the ordinary
        /// case for somebody with one login**, and it is not an empty strip: the wait offer needs
        /// no second account, so the row still stands and carries that alone.
        let accountName: String?

        /// That login's compact reading — `5h 12% · 7d 40%`. Nil where it reports no windows.
        let reading: String?

        /// Whether waiting for the window to reset is on the table. False only where the
        /// conversation has already been armed, so the strip does not offer what is already
        /// filed — the scheduled-message strip names that.
        let offersWaitForReset: Bool

        /// When the refused account comes back, in the provider's own words. Nil where the
        /// provider refused without saying, and then the clause is simply absent.
        let resetHint: String?

        /// Why the offer cannot be taken, when it cannot. It replaces the sentence and dims the
        /// buttons rather than naming a different login: another account is a *new* suggestion
        /// the user can press, not something to escalate to on their behalf.
        let problem: String?

        /// Which answer is being carried out, if either. Both controls dim while one runs, but
        /// only the pressed one reports it — see `LimitEscapeSuggestion.busy`.
        let busy: LimitEscapeAction?

        /// Whether either answer is in flight.
        var isBusy: Bool { busy != nil }

        init(
            source: Source = .provider,
            accountName: String? = nil,
            reading: String? = nil,
            offersWaitForReset: Bool = false,
            resetHint: String? = nil,
            problem: String? = nil,
            busy: LimitEscapeAction? = nil
        ) {
            self.source = source
            self.accountName = accountName
            self.reading = reading
            self.offersWaitForReset = offersWaitForReset
            self.resetHint = resetHint
            self.problem = problem
            self.busy = busy
        }

        /// Whether there is anything left to press.
        var offersContinuation: Bool { problem == nil }

        /// Whether a login is named, which is what decides if the account button is on the row
        /// at all. A refusal with nothing to move to keeps the wait offer and the sentence.
        var offersAccountEscape: Bool { accountName != nil }
    }

    // MARK: - Properties

    /// Take the offer: migrate this conversation and carry on under the named login.
    var onContinue: (() -> Void)?

    /// Take the other offer: stay on this login and pick the conversation up when its window
    /// resets. Reported as an intention like every other gesture here — answering the CLI's
    /// chooser and filing the continuation is `LimitRecoveryCoordinator`'s.
    var onWaitForReset: (() -> Void)?

    /// Put the offer away until the next refusal.
    var onDismiss: (() -> Void)?

    /// Walk through a park by one of the user's own limits. Separate from `onContinue`, which
    /// migrates the conversation to another login: these are different acts, and a park's Continue
    /// keeps the session exactly where it is.
    var onContinueAnyway: (() -> Void)?

    /// The offer currently drawn, or nil while the strip has nothing to say.
    private(set) var offer: Offer?

    /// The button that takes the offer. Readable so a test presses the control the user presses
    /// rather than the closure behind it.
    var continueControl: ThemedButton { continueButton }

    /// The button that waits it out, readable for the same reason.
    var waitControl: ThemedButton { waitButton }

    /// The ✕.
    var dismissControl: ThemedIconButton { dismissButton }

    private let mark = ThemedWarningMark()

    /// The park's mark: the same glyph the sidebar row wears for conduct, for the same reason —
    /// a line the user drew is not weather.
    private let conductMark = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private lazy var continueButton = ThemedButton(
        title: L10n.string("Continue"),
        target: self,
        action: #selector(continuePressed)
    )
    private lazy var waitButton = ThemedButton(
        title: LimitEscapeStripStrings.waitForReset,
        target: self,
        action: #selector(waitPressed)
    )
    /// Holds whichever of the two answers this refusal actually has. Structural only: it chooses
    /// no styling, and both of its members are themed controls.
    private let actions = NSStackView()

    private lazy var dismissButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: DesignSymbols.removeAttachment,
            accessibility: L10n.string("Dismiss this suggestion"),
            target: .inline
        )
        button.onPress = { [weak self] in self?.onDismiss?() }
        button.setAccessibilityIdentifier(LimitEscapeStripDefaults.dismissIdentifier)
        return button
    }()

    private let appEvents = AppEventObservations()

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Draws an offer, or nothing at all. A strip with nothing to say hides rather than standing
    /// as an empty plate over the conversation it belongs to.
    func setOffer(_ offer: Offer?) {
        guard offer != self.offer else { return }
        self.offer = offer

        guard let offer else {
            isHidden = true
            return
        }

        isHidden = false
        mark.isHidden = offer.source == .ownLimit
        conductMark.isHidden = offer.source != .ownLimit
        messageLabel.stringValue = Self.sentence(for: offer)
        messageLabel.toolTip = messageLabel.stringValue
        mark.setAccessibilityLabel(Self.sentence(for: offer))

        // The button keeps its title and its numbers when the offer cannot be taken, and is
        // dimmed instead of removed: what it would have done is still the clearest statement of
        // what the sentence beside it is about, and a control that leaves the row takes the
        // explanation's subject with it.
        //
        // Absence is different from refusal, and the two are drawn differently on purpose: a
        // login that *cannot be moved to* is dimmed with its reason, while a login that does not
        // exist is not a dimmed button with nothing behind it — it is simply not on the row.
        // A park always offers its Continue Anyway, with or without a second login to move to:
        // the rule is the user's own, so walking through it needs no destination.
        continueButton.isHidden = !(offer.offersAccountEscape || offer.source == .ownLimit)
        if !continueButton.isHidden {
            continueButton.title = Self.actionTitle(for: offer)
            continueButton.isEnabled = offer.offersContinuation && !offer.isBusy
            continueButton.toolTip = continueButton.title
        }

        waitButton.isHidden = !offer.offersWaitForReset
        waitButton.isEnabled = offer.offersContinuation && !offer.isBusy
        waitButton.title = offer.busy == .waitForReset
            ? LimitEscapeStripStrings.waitingBusy
            : LimitEscapeStripStrings.waitForReset
        waitButton.toolTip = LimitEscapeStripStrings.waitToolTip

        applyTheme()
    }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        // The same mark the sidebar row wears for this state, and for the same reason: a stop
        // nobody typed has a silhouette of its own, so it stays legible with the red removed.
        // Its label is the host's to set (`ThemedWarningMark`), which `setOffer` does.
        mark.severity = .negative
        mark.translatesAutoresizingMaskIntoConstraints = false

        // The condition and its answer are peers. The old caption/secondary treatment made the
        // state look like metadata attached to the much larger button, even though the button only
        // makes sense after the state has been read.
        messageLabel.applyFont(.control, in: .chrome)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.usesSingleLineMode = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        // The sentence is the flexible half: a narrow pane truncates the explanation rather than
        // squeezing the button that answers it, whose title is the whole action. A step below
        // the button's own, so which of the two gives way is decided rather than left to the
        // solver — `PaneNoticeView`'s rule, and the same number.
        messageLabel.setContentCompressionResistancePriority(
            LimitEscapeStripDefaults.sentencePriority,
            for: .horizontal
        )
        messageLabel.setContentHuggingPriority(
            .defaultHigh,
            for: .horizontal
        )

        for button in [continueButton, waitButton] {
            button.emphasis = .secondary
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        continueButton.setAccessibilityIdentifier(LimitEscapeStripDefaults.continueIdentifier)
        waitButton.setAccessibilityIdentifier(LimitEscapeStripDefaults.waitIdentifier)

        // A stack rather than a constraint chain because either action can be absent, and a
        // hidden view in a chain still holds its own gap open. The row carries two answers at
        // most, a fixed pair, so a retained stack is the right shape here.
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The immediate answer first and the deferred one after it: moving login carries on now,
        // while waiting is what is left when nothing can. Reading order is the ranking.
        actions.addArrangedSubview(continueButton)
        actions.addArrangedSubview(waitButton)

        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        conductMark.holdSymbol(
            RowConductDefaults.symbol,
            slot: Design.Size.inlineButtonGlyph
        )
        conductMark.imageScaling = .scaleProportionallyDown
        conductMark.contentTintColor = Design.Text.secondary
        conductMark.translatesAutoresizingMaskIntoConstraints = false
        conductMark.isHidden = true
        conductMark.setAccessibilityElement(true)
        conductMark.setAccessibilityRole(.image)

        addSubview(conductMark)
        addSubview(mark)
        addSubview(messageLabel)
        addSubview(actions)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(
                greaterThanOrEqualToConstant: LimitEscapeStripDefaults.rowHeight
            ),

            mark.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: LimitEscapeStripDefaults.contentInset
            ),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Exactly on top of the warning mark: only one is ever visible, and two marks that
            // sat in different places would move the sentence beside them between the two states.
            conductMark.leadingAnchor.constraint(equalTo: mark.leadingAnchor),
            conductMark.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            conductMark.widthAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph),
            conductMark.heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph),

            messageLabel.leadingAnchor.constraint(
                equalTo: mark.trailingAnchor,
                constant: Design.Spacing.small
            ),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.leadingAnchor.constraint(
                equalTo: messageLabel.trailingAnchor,
                constant: Design.Spacing.medium
            ),
            actions.trailingAnchor.constraint(
                lessThanOrEqualTo: dismissButton.leadingAnchor,
                constant: -Design.Spacing.small
            ),
            // The plate grows with its tallest member rather than clipping it: a material that
            // states a taller control height than the row's floor must not push the button
            // through the edge it is centred in.
            actions.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: Design.Spacing.tight
            ),
            actions.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -Design.Spacing.tight
            ),

            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Aligned by ink: a glyph button's frame carries its click target, and its edge is
            // not its mark — the rule `PaneNoticeView` states for the band above it.
            dismissButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(LimitEscapeStripDefaults.contentInset
                    - dismissButton.opticalHorizontalInset)
            )
        ])

        // The plate is a recorded surface and the labels are inked here, so a live theme switch
        // has to reach both halves.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()

        setAccessibilityIdentifier(LimitEscapeStripDefaults.identifier)
    }

    // MARK: - Theme

    private func applyTheme() {
        // Its own ground, for `PaneNoticeView`'s reason: the surface behind it may be the
        // *terminal's* palette, which the app theme knows nothing about, so a transparent strip
        // would put chrome ink on an unknown colour.
        applySurface(fill: Design.Surface.panel, radius: .control)
        messageLabel.textColor = offer?.problem == nil
            ? Design.Text.label
            : Design.Status.warning
    }

    // MARK: - Copy

    /// What the strip says: the state, and the provider's own words for when it lifts.
    ///
    /// The reset clause is quoted, never reformatted into the Mac's locale — `1:20pm
    /// (Europe/Rome)` is a wall clock in the *account's* zone with no date, and a strip that
    /// restated it as a local time would be inventing the half it does not know.
    private static func sentence(for offer: Offer) -> String {
        if let problem = offer.problem { return problem }
        guard let hint = offer.resetHint, !hint.isEmpty else {
            return offer.source == .ownLimit
                ? L10n.string("Held at your own limit")
                : L10n.string("Limit reached")
        }
        // Different words for a different fact. "Limit reached" is the provider's; a line of the
        // user's is one they can move, and the sentence says whose it is before it says when the
        // window comes back.
        return offer.source == .ownLimit
            ? L10n.format("Held at your own limit · resets %@", hint)
            : L10n.format("Limit reached · resets %@", hint)
    }

    private static func actionTitle(for offer: Offer) -> String {
        guard let accountName = offer.accountName else {
            // **Anyway**, and the word is load-bearing: this button walks through a rule the
            // reader wrote, so it has to read as an exception rather than as a resume.
            return offer.source == .ownLimit
                ? L10n.string("Continue Anyway")
                : L10n.string("Continue")
        }
        // Only when *this* button is what is running: a migration announced because somebody
        // pressed the one beside it would name a login change that is not happening.
        if offer.busy == .moveAccount { return L10n.string("Continuing…") }
        guard let reading = offer.reading, !reading.isEmpty else {
            return L10n.format("Continue as %@", accountName)
        }
        return L10n.format("Continue as %@ · %@", accountName, reading)
    }

    /// One sentence for a reader who cannot glance at it, carrying the state and every answer
    /// on the row — login and reading included, and the wait where it is offered.
    private static func spokenLabel(for offer: Offer) -> String {
        guard offer.offersContinuation else { return sentence(for: offer) }

        var parts = [sentence(for: offer)]
        if offer.offersAccountEscape { parts.append(actionTitle(for: offer)) }
        if offer.offersWaitForReset { parts.append(LimitEscapeStripStrings.waitToolTip) }
        return parts.joined(separator: ". ")
    }

    // MARK: - Actions

    /// One button, two acts, chosen by whose limit stopped this. A provider refusal's Continue
    /// moves the conversation to another login; a park's Continue Anyway leaves it exactly where
    /// it is and stands the user's own rule down for this turn of the window.
    @objc private func continuePressed() {
        if offer?.source == .ownLimit {
            onContinueAnyway?()
        } else {
            onContinue?()
        }
    }

    @objc private func waitPressed() { onWaitForReset?() }

    // MARK: - Pointer

    /// An opaque plate over a terminal or a transcript, both of which claim an I-beam over the
    /// whole of themselves. Saying so is what stops the two answers offering to select text that
    /// is behind the strip. See `PointerClaiming`.
    var restingPointer: NSCursor? { .arrow }

    override func resetCursorRects() {
        registerPointerClaims()
    }

    override func layout() {
        super.layout()
        refreshPointerClaims()
    }

    // MARK: - Accessibility

    /// A container rather than an element, like the scheduled strip beside it: the mark states
    /// the condition and the two controls state their own actions, so nothing here has to be
    /// reached *through* a summary.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        guard let offer else { return L10n.string("Usage limit suggestion") }
        return Self.spokenLabel(for: offer)
    }
}

// MARK: - Limit Escape Strip Defaults

@MainActor
enum LimitEscapeStripDefaults {

    /// The scheduled strip's own row height, so the two strips that can stand together above one
    /// composer read as the same kind of row.
    static let rowHeight = ScheduledStripDefaults.rowHeight

    /// Ink-to-edge distance inside the plate.
    static let contentInset: CGFloat = Design.Spacing.small

    /// Below the controls', so a narrow column truncates the sentence rather than squashing the
    /// button that answers it. `PaneNoticeView`'s number, for the same reason it has one.
    static let sentencePriority = NSLayoutConstraint.Priority(249)

    static let identifier = "composer.limit-escape"
    static let continueIdentifier = "composer.limit-escape.continue"
    static let waitIdentifier = "composer.limit-escape.wait"
    static let dismissIdentifier = "composer.limit-escape.dismiss"
}

// MARK: - Strings

/// The wait offer's words.
///
/// **Imperative, and deliberately not the context menu's wording for the same behaviour.** The
/// two were identical at first, on the reasoning that two names for one behaviour reads as two
/// behaviours. That was wrong: a checkbox is a standing state and a button is an act performed
/// now, so the menu's "Continue at Reset" — correct as an option — turned into a mode name when
/// it appeared on a strip whose first two words are "Limit reached". It read as *switch the
/// setting on*, over a session where the setting could no longer change anything, rather than as
/// *do this to the refusal in front of you*.
///
/// The reset instant is not repeated on the button: it is already in the sentence beside it, and
/// two clocks on one row invite a comparison that means nothing. What the wait leads to is in the
/// tooltip and in the spoken label.
enum LimitEscapeStripStrings {

    static var waitForReset: String { L10n.string("Wait for Reset") }

    static var waitingBusy: String { L10n.string("Scheduling…") }

    static var waitToolTip: String {
        L10n.string("Stop here and continue when the usage window resets")
    }
}
