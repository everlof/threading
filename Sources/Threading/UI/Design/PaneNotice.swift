import AppKit

// MARK: - Pane Notice Action

/// One way to answer a notice: a title, how loudly it asks, and what it does.
struct PaneNoticeAction {

    let title: String
    let emphasis: ThemedButton.Emphasis
    let handler: () -> Void

    /// `secondary` by default — a band that appears unasked has no claim on a screen's one
    /// primary action, which belongs to whatever the user came to the pane to do.
    init(
        title: String,
        emphasis: ThemedButton.Emphasis = .secondary,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.emphasis = emphasis
        self.handler = handler
    }
}

// MARK: - Pane Notice View

/// A band across a pane saying one thing about the pane itself, with the ways to answer it and
/// the way to be rid of it on the same line.
///
/// The third of the pane's bands, and it exists for `PaneHeaderView`'s and `PaneFooterView`'s
/// reason: the height, the edge-to-edge rule, the insets and the align-by-ink rule are one
/// decision, and the second pane to need a message strip is where they start to drift.
///
/// **Not a `ToastView`, deliberately.** A toast is a receipt for something the user just did —
/// it is measured from a click, it leaves on its own clock, and a band with a way back on it
/// holds the pane while later receipts queue behind it. A notice is a *standing condition* the
/// pane found on its own: nobody clicked, there is no dwell that could be long enough for
/// somebody who has walked away, and an eternal toast would be a permanent stopper in a queue
/// other receipts have to get through. So this band waits, and only a press takes it away.
///
/// It **pushes** rather than covers. Placed between a pane's header and its content it moves
/// the content down by its own height, so nothing it has to say is said over something the user
/// is reading — the rule the git status card learned from the other direction
/// (see [`design-system.md`](../../../../docs/architecture/design-system.md)).
///
/// It draws its own ground. The pane behind it may be filled with the *terminal's* palette,
/// which the app theme knows nothing about, so a transparent band would put chrome ink on an
/// unknown colour; `Design.Surface.background` is the same structural fill the sidebar takes.
///
/// Escape is deliberately not taken. A notice is not a transient surface over the window — it
/// takes no focus, covers nothing, and blocks nothing — so claiming the key would take it from
/// the composer underneath. The ✕ is the dismissal, and it is an ordinary focusable control.
final class PaneNoticeView: NSView, ThemedComponent {

    // MARK: - Types

    /// What kind of thing the band is saying, which decides its mark's ink.
    ///
    /// The tone is never the *only* signal: the glyph's own shape differs, and the message says
    /// in words what happened. A band identifiable by hue alone fails the first viewer who
    /// cannot separate two of them.
    enum Tone {
        /// Something went wrong, or nearly did.
        case attention
        /// A fact worth stating once.
        case informational

        var symbol: String {
            switch self {
            case .attention: DesignSymbols.reportRefused
            case .informational: DesignSymbols.noticeInformational
            }
        }

        @MainActor
        var ink: NSColor {
            switch self {
            case .attention: Design.Status.warning
            case .informational: Design.Text.secondary
            }
        }
    }

    // MARK: - Properties

    /// What the band says, for a test and for the announcement it makes on arrival.
    let message: String

    private let tone: Tone
    private let glyph = GlyphView()
    private let messageLabel: NSTextField
    private let separator = SeparatorView()
    /// Kept beside the buttons rather than captured in them: a `ThemedControl` is an
    /// `NSControl`, so its press arrives as target/action and the sender's tag is what names
    /// which of the band's answers was pressed.
    private var handlers: [() -> Void] = []
    private var actionButtons: [ThemedButton] = []
    private var dismissButton: ThemedIconButton?
    private let appEvents = AppEventObservations()
    private var themeRedraw: ThemeRedraw?

    /// Whether the band has already told VoiceOver it arrived. A band moved between windows —
    /// which the pane does not do, but a fixture does — must not announce itself twice.
    private var hasAnnounced = false

    // MARK: - Initialization

    /// `onDismiss` is what the ✕ performs; a band without one carries no ✕ and the host owns
    /// when it leaves.
    init(
        tone: Tone,
        message: String,
        actions: [PaneNoticeAction],
        onDismiss: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.message = message
        messageLabel = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)

        setupViews(actions: actions, onDismiss: onDismiss)
        applyInk()

        // The ink is read from roles at draw and set on labels here, so a live theme switch has
        // to reach both halves — the fill follows `draw`, the label colours follow this.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyInk() }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.applyInk()
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(message)
        setAccessibilityIdentifier(PaneNoticeDefaults.identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// The band's actions, leading to trailing. Readable so a test presses the control the user
    /// would press rather than the closure behind it.
    var actionControls: [ThemedButton] { actionButtons }

    /// The ✕, when the band has one.
    var dismissControl: ThemedIconButton? { dismissButton }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Drawn rather than applied to the layer: a theme colour frozen into a `CGColor` keeps
        // the theme it was frozen under, and the band outlives a switch.
        Design.Surface.background.setFill()
        bounds.fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        announce()
    }

    // MARK: - Private Methods

    private func setupViews(actions: [PaneNoticeAction], onDismiss: (() -> Void)?) {
        glyph.image = Design.Symbol.image(
            tone.symbol,
            slot: PaneNoticeDefaults.glyphSlot,
            pointSize: Design.Symbol.pointSize(forSlot: PaneNoticeDefaults.glyphSlot)
        )

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.applyFont(.control)
        messageLabel.maximumNumberOfLines = PaneNoticeDefaults.maximumLines
        messageLabel.lineBreakMode = .byTruncatingTail
        // The sentence yields before the buttons do: a band too narrow for both wraps and then
        // truncates its own words rather than squeezing the control that answers it.
        messageLabel.setContentCompressionResistancePriority(
            PaneNoticeDefaults.messagePriority,
            for: .horizontal
        )
        messageLabel.setContentHuggingPriority(PaneNoticeDefaults.messagePriority, for: .horizontal)
        // Vertically it yields too, and for a stated reason: a pane's content may not decide how
        // tall the window is, and a wrapping label's own resistance is above the 500 at which
        // AppKit starts reading constraints as the window's minimum size.
        // See `window-chrome.md`, "a pane cannot be taller than its window".
        messageLabel.setContentCompressionResistancePriority(
            PaneNoticeDefaults.messageHeightPriority,
            for: .vertical
        )

        addSubview(glyph)
        addSubview(messageLabel)
        addSubview(separator)

        handlers = actions.map(\.handler)
        actionButtons = actions.enumerated().map { index, action in
            let button = ThemedButton(title: action.title, target: self, action: #selector(actionPressed))
            button.emphasis = action.emphasis
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            return button
        }

        if let onDismiss {
            let close = ThemedIconButton(
                symbolName: DesignSymbols.removeAttachment,
                accessibility: L10n.string("Dismiss"),
                target: .inline
            )
            close.onPress = onDismiss
            close.setAccessibilityIdentifier(PaneNoticeDefaults.dismissIdentifier)
            addSubview(close)
            dismissButton = close
        }

        installConstraints()
    }

    private func installConstraints() {
        // The band floors at the header's height so a pane's two chrome rows read as the same
        // kind of row, and grows only if the sentence needs a second line.
        let height = heightAnchor.constraint(equalToConstant: PaneNoticeDefaults.bandHeight)
        height.priority = .defaultLow

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: PaneNoticeDefaults.bandHeight),
            height,

            // Edge to edge, like every other rule a pane folds on.
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),

            glyph.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: PaneNoticeDefaults.contentInset
            ),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: PaneNoticeDefaults.glyphSlot),
            glyph.heightAnchor.constraint(equalToConstant: PaneNoticeDefaults.glyphSlot),

            messageLabel.leadingAnchor.constraint(
                equalTo: glyph.trailingAnchor,
                constant: Design.Spacing.small
            ),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: Design.Spacing.small
            ),
            messageLabel.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -Design.Spacing.small
            )
        ]

        // The trailing run, laid out from the edge inwards: the ✕ sits at the margin and the
        // actions queue to its leading side. Aligned by ink like the two bands beside it — a
        // glyph button's frame carries its click target, and its edge is not its mark.
        var trailingNeighbour: NSView?
        for view in ([dismissButton].compactMap { $0 } + actionButtons.reversed()) {
            constraints.append(view.centerYAnchor.constraint(equalTo: centerYAnchor))
            if let trailingNeighbour {
                constraints.append(view.trailingAnchor.constraint(
                    equalTo: trailingNeighbour.leadingAnchor,
                    constant: -Design.Spacing.small
                ))
            } else {
                constraints.append(view.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -(PaneNoticeDefaults.contentInset - opticalInset(of: view))
                ))
            }
            trailingNeighbour = view
        }

        // The sentence must not run under the controls answering it.
        if let firstTrailing = trailingNeighbour {
            constraints.append(messageLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: firstTrailing.leadingAnchor,
                constant: -Design.Spacing.medium
            ))
        } else {
            constraints.append(messageLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -PaneNoticeDefaults.contentInset
            ))
        }

        NSLayoutConstraint.activate(constraints)
    }

    @objc private func actionPressed(_ sender: NSControl) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }

    private func applyInk() {
        glyph.tint = tone.ink
        messageLabel.textColor = Design.Text.label
        needsDisplay = true
    }

    private func opticalInset(of view: NSView) -> CGFloat {
        (view as? OpticalInsetProviding)?.opticalHorizontalInset ?? 0
    }

    /// The band appears without being asked for and takes no focus, so without this it is
    /// invisible to the part of the audience that cannot glance at it — the reason `ToastView`
    /// and `SubmissionStatusView` announce themselves too.
    private func announce() {
        guard !hasAnnounced, let window, !message.isEmpty else { return }
        hasAnnounced = true
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

// MARK: - Pane Notice Defaults

enum PaneNoticeDefaults {

    /// The pane's own header height, so a notice under it reads as the same kind of row rather
    /// than as a second, differently proportioned strip.
    static let bandHeight: CGFloat = PaneHeaderView.bandHeight

    /// Ink-to-edge distance. The pane's inset rather than the corner-adapted region: this band
    /// is stacked between two pane-width surfaces and meets no window corner, which is
    /// `PaneBandMargin.paneEdge`'s rule stated for the one band that is always in that position.
    static let contentInset: CGFloat = Design.Spacing.medium

    static let glyphSlot: CGFloat = Design.Size.tabIconSlot

    /// Two lines, not unbounded: a sentence long enough to need a third belongs somewhere the
    /// reader can scroll, and the band's height is part of the window's minimum size.
    static let maximumLines = 2

    /// Below the controls', so a narrow pane wraps the sentence rather than squashing the button
    /// that answers it.
    static let messagePriority = NSLayoutConstraint.Priority(249)

    /// Below the 500 at which AppKit reads a constraint as the window's minimum content size —
    /// the rule `window-chrome.md` records after a preview grew the window off the screen.
    static let messageHeightPriority = NSLayoutConstraint.Priority(499)

    static let identifier = "pane.notice"
    static let dismissIdentifier = "pane.notice.dismiss"
}
