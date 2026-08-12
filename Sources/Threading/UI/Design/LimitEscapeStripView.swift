import AppKit

// MARK: - Limit Escape Strip

/// The offer over a session whose provider refused its turn for a spent usage limit: what
/// happened, one login to carry on under, and the way to be rid of the offer.
///
/// **One tap, and the button names its whole action.** `limit-recovery.md` refuses to migrate a
/// conversation automatically because that types into somebody's session and spends their quota
/// with nobody watching; here the press *is* the watching, so there is no second dialog to
/// confirm what the button already says on its face. The automatic policy stays unbuilt.
///
/// **Not a `PaneNoticeView`.** That band is a condition the *pane* found — it spans the pane, it
/// pushes the header apart from the content, and one of them at a time is chrome. This is a
/// condition of one conversation, drawn on that conversation's own column beside what is waiting
/// to be sent into it, which is where the answer to it belongs.
///
/// One direction, like `ScheduledMessageStripView`: the store is the truth, this draws what it is
/// handed, and both gestures are reported back as intentions.
final class LimitEscapeStripView: NSView, ThemedComponent {

    // MARK: - Offer

    /// What the strip says, already resolved by its owner. Not a `LimitEscapeSuggestion`, for the
    /// reason the scheduled strip's `Row` is not a `ScheduledMessage`: a view holding the model
    /// would have to decide which of its states are the user's business.
    struct Offer: Equatable {
        /// The login the button offers, named after the person.
        let accountName: String

        /// That login's compact reading — `5h 12% · 7d 40%`. Nil where it reports no windows.
        let reading: String?

        /// When the refused account comes back, in the provider's own words. Nil where the
        /// provider refused without saying, and then the clause is simply absent.
        let resetHint: String?

        /// Why the offer cannot be taken, when it cannot. It replaces the sentence and dims the
        /// button rather than naming a different login: another account is a *new* suggestion
        /// the user can press, not something to escalate to on their behalf.
        let problem: String?

        /// Whether the tap is already being carried out.
        let isBusy: Bool

        init(
            accountName: String,
            reading: String? = nil,
            resetHint: String? = nil,
            problem: String? = nil,
            isBusy: Bool = false
        ) {
            self.accountName = accountName
            self.reading = reading
            self.resetHint = resetHint
            self.problem = problem
            self.isBusy = isBusy
        }

        /// Whether there is anything left to press.
        var offersContinuation: Bool { problem == nil }
    }

    // MARK: - Properties

    /// Take the offer: migrate this conversation and carry on under the named login.
    var onContinue: (() -> Void)?

    /// Put the offer away until the next refusal.
    var onDismiss: (() -> Void)?

    /// The offer currently drawn, or nil while the strip has nothing to say.
    private(set) var offer: Offer?

    /// The button that takes the offer. Readable so a test presses the control the user presses
    /// rather than the closure behind it.
    var continueControl: ThemedButton { continueButton }

    /// The ✕.
    var dismissControl: ThemedIconButton { dismissButton }

    private let mark = ThemedWarningMark()
    private let messageLabel = NSTextField(labelWithString: "")
    private lazy var continueButton = ThemedButton(
        title: L10n.string("Continue"),
        target: self,
        action: #selector(continuePressed)
    )
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
        messageLabel.stringValue = Self.sentence(for: offer)
        messageLabel.toolTip = messageLabel.stringValue
        mark.setAccessibilityLabel(Self.sentence(for: offer))

        // The button keeps its title and its numbers when the offer cannot be taken, and is
        // dimmed instead of removed: what it would have done is still the clearest statement of
        // what the sentence beside it is about, and a control that leaves the row takes the
        // explanation's subject with it.
        continueButton.title = Self.actionTitle(for: offer)
        continueButton.isEnabled = offer.offersContinuation && !offer.isBusy
        continueButton.toolTip = continueButton.title

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

        messageLabel.applyFont(.caption, in: .chrome)
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
            LimitEscapeStripDefaults.sentencePriority,
            for: .horizontal
        )

        continueButton.emphasis = .secondary
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        continueButton.setContentHuggingPriority(.required, for: .horizontal)
        continueButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        continueButton.setAccessibilityIdentifier(LimitEscapeStripDefaults.continueIdentifier)

        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mark)
        addSubview(messageLabel)
        addSubview(continueButton)
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

            messageLabel.leadingAnchor.constraint(
                equalTo: mark.trailingAnchor,
                constant: Design.Spacing.small
            ),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            continueButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            continueButton.trailingAnchor.constraint(
                equalTo: dismissButton.leadingAnchor,
                constant: -Design.Spacing.small
            ),
            // The plate grows with its tallest member rather than clipping it: a material that
            // states a taller control height than the row's floor must not push the button
            // through the edge it is centred in.
            continueButton.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: Design.Spacing.tight
            ),
            continueButton.bottomAnchor.constraint(
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

        // Held apart at less than required so a pathologically narrow column collapses the
        // sentence rather than producing an unsatisfiable pair: at that width the label has no
        // ink left to overlap with, and a broken constraint is invisible where a broken layout
        // is not.
        let separation = messageLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: continueButton.leadingAnchor,
            constant: -Design.Spacing.medium
        )
        separation.priority = .defaultHigh
        separation.isActive = true

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
            ? Design.Text.secondary
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
            return L10n.string("Limit reached")
        }
        return L10n.format("Limit reached · resets %@", hint)
    }

    private static func actionTitle(for offer: Offer) -> String {
        if offer.isBusy { return L10n.string("Continuing…") }
        guard let reading = offer.reading, !reading.isEmpty else {
            return L10n.format("Continue as %@", offer.accountName)
        }
        return L10n.format("Continue as %@ · %@", offer.accountName, reading)
    }

    /// One sentence for a reader who cannot glance at it, carrying both halves — the state and
    /// the whole of what pressing would do, login and reading included.
    private static func spokenLabel(for offer: Offer) -> String {
        guard offer.offersContinuation else { return sentence(for: offer) }
        return L10n.format("%@. %@", sentence(for: offer), actionTitle(for: offer))
    }

    // MARK: - Actions

    @objc private func continuePressed() { onContinue?() }

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
    static let dismissIdentifier = "composer.limit-escape.dismiss"
}
