import AppKit

// MARK: - Scheduled Message Strip

/// What is waiting to be sent later, drawn above the composer that will send it.
///
/// **Deliberately not rows in `ConversationOutboxRailView`.** That rail's whole model is a queue
/// whose order the user controls: it computes a drag's index across every pending row and hands
/// it to `ConversationOutbox.movePending`, which counts in outbox terms — so scheduled rows mixed
/// in would silently shift every drag by however many of them sat above, because `movePending`
/// clamps rather than refuses. Its `Row.id` is a `ConversationMessageID`, and one flag gates
/// draggability, removal *and* editing together, so "store-ordered, still removable" is
/// not a state it can express. A separate strip costs one small view and keeps both models
/// honest — and the draft view, which has no rail at all, needed exactly this view anyway.
///
/// One direction only, like the rail: the store is the truth, this is drawn from it, and gestures
/// are reported back as intentions.
final class ScheduledMessageStripView: NSView, ThemedComponent {

    // MARK: - Row

    /// One waiting send, already resolved by the owner. Not a `ScheduledMessage`, for the reason
    /// the rail's `Row` is not an outbox item: a view that took the model would have to know
    /// which of its states are the user's business.
    struct Row: Equatable {
        let id: ScheduledMessageID
        let summary: String
        /// What releases it, already written — "Tomorrow at 09:00", "When Build finishes".
        let timing: String
        /// Set when the send needs a decision rather than a wait.
        let problem: String?
        /// Set while a composer holds this row open for editing, so the strip can say where
        /// the words went instead of offering to open them a second time.
        let isEditing: Bool

        init(
            id: ScheduledMessageID,
            summary: String,
            timing: String,
            problem: String?,
            isEditing: Bool = false
        ) {
            self.id = id
            self.summary = summary
            self.timing = timing
            self.problem = problem
            self.isEditing = isEditing
        }

        var needsAttention: Bool { problem != nil }
    }

    // MARK: - Properties

    var onRemove: ((ScheduledMessageID) -> Void)?
    var onEdit: ((ScheduledMessageID) -> Void)?
    /// Send it now — the answer a missed or failed row is waiting for.
    var onSendNow: ((ScheduledMessageID) -> Void)?

    private let stack = NSStackView()
    private var rows: [Row] = []

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        // Never a reason for the column it sits in to be wider or narrower than the pane says.
        // A strip whose summaries resisted compression pushed the composer's column past a
        // narrow pane — the measurement `ComposerWindowFitTests` exists to hold — so it yields
        // horizontally in both directions and lets its rows truncate instead.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        isHidden = true
    }

    // MARK: - Public Methods

    func setRows(_ rows: [Row]) {
        guard rows != self.rows else { return }
        self.rows = rows

        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for row in rows {
            let view = ScheduledMessageRowView(row: row)
            view.onRemove = { [weak self] in self?.onRemove?(row.id) }
            view.onEdit = { [weak self] in self?.onEdit?(row.id) }
            view.onSendNow = { [weak self] in self?.onSendNow?(row.id) }
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        isHidden = rows.isEmpty
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        L10n.string("Messages scheduled to be sent later")
    }
}

// MARK: - Row View

/// One waiting send: when it goes, what it says, and the two ways to change your mind.
final class ScheduledMessageRowView: ThemedControl {

    // MARK: - Properties

    var onRemove: (() -> Void)?
    var onEdit: (() -> Void)?
    var onSendNow: (() -> Void)?

    private let row: ScheduledMessageStripView.Row
    private let timingLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")

    /// A theme states colours these labels read once, so a live switch has to reach them —
    /// `ThemedControl`'s own redraw covers what this view draws, not AppKit's text fields.
    private let appEvents = AppEventObservations()

    private lazy var removeButton = ThemedIconButton(
        symbolName: DesignSymbols.removeAttachment,
        accessibility: L10n.string("Unschedule this message"),
        target: .inline
    )
    private lazy var sendNowButton = ThemedButton(
        title: L10n.string("Send now"),
        target: self,
        action: #selector(sendNowTapped)
    )

    // MARK: - Initialization

    init(row: ScheduledMessageStripView.Row) {
        self.row = row
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        timingLabel.stringValue = row.isEditing
            ? L10n.string("Editing")
            : row.problem ?? row.timing
        timingLabel.applyFont(.caption, in: .chrome)
        timingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timingLabel.setContentHuggingPriority(.required, for: .horizontal)

        summaryLabel.stringValue = row.summary
        summaryLabel.applyFont(.body, in: .conversation)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.usesSingleLineMode = true
        summaryLabel.toolTip = row.summary
        // The one thing on the row that may lose characters: what it says is recoverable by
        // opening it, and when it goes is the fact the row exists to state.
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [timingLabel, summaryLabel])
        stack.orientation = .horizontal
        stack.spacing = Design.Spacing.small
        stack.alignment = .firstBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        var trailing: NSView = removeButton
        addSubview(removeButton)
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        // Offered only where there is a decision to make. A row that is simply waiting needs no
        // "send now" — the trigger is doing what it was asked to.
        if row.needsAttention {
            addSubview(sendNowButton)
            sendNowButton.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                sendNowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                sendNowButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
                sendNowButton.trailingAnchor.constraint(
                    equalTo: removeButton.leadingAnchor,
                    constant: -Design.Spacing.small
                )
            ])
            trailing = sendNowButton
        }

        // The floor states what a row may never be squeezed below; the preferred height beside
        // it states what a row *is*. With only the floor, the row's height was a free variable,
        // and the composer's column has another one: the hero region above it soaks up whatever
        // the pane does not need. Two free heights is an ambiguous layout, and the engine parked
        // the pane's slack in whichever it liked — a scheduled row hundreds of points tall,
        // drawing its labels over the chip row above while its remove button floated below them.
        // The `.defaultHigh` preference makes stretching this row cost something and growing the
        // hero region cost nothing, so the slack has one home. The required top pins are what
        // lets genuinely taller content — the Send-now button — still raise the row honestly.
        let preferredHeight = heightAnchor.constraint(
            equalToConstant: ScheduledStripDefaults.rowHeight
        )
        preferredHeight.priority = .defaultHigh
        let summaryInkCenterFromBaseline = (summaryLabel.font?.capHeight ?? 0) / 2

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailing.leadingAnchor,
                constant: -Design.Spacing.small
            ),
            // Align the mark with the body text's ink rather than either view's abstract frame.
            // A label frame includes the font's descender and line-leading space, so its centre
            // is not the centre of the letters the user sees. The first baseline plus half the
            // cap height is that visible centre and remains correct when a theme changes fonts.
            removeButton.centerYAnchor.constraint(
                equalTo: summaryLabel.firstBaselineAnchor,
                constant: -summaryInkCenterFromBaseline
            ),
            removeButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            removeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.small
            ),
            heightAnchor.constraint(
                greaterThanOrEqualToConstant: ScheduledStripDefaults.rowHeight
            ),
            preferredHeight
        ])

        removeButton.onPress = { [weak self] in self?.onRemove?() }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
        applyTheme()
    }

    // MARK: - Theme

    private func applyTheme() {
        // A row needing a decision takes the status role rather than a colour of its own, so a
        // theme that redefines "something is wrong" redefines this too. A row open for editing
        // takes the accent — it is the one the composer below is currently about.
        timingLabel.textColor = row.isEditing
            ? Design.Surface.accent
            : row.needsAttention ? Design.Status.warning : Design.Text.tertiary
        summaryLabel.textColor = Design.Text.label
    }

    // MARK: - Actions

    @objc private func sendNowTapped() { onSendNow?() }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return super.mouseUp(with: event) }
        guard !removeButton.frame.contains(point),
              !(row.needsAttention && sendNowButton.frame.contains(point)) else { return }
        onEdit?()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        L10n.format(
            "%@ — %@",
            row.isEditing ? L10n.string("Editing") : row.problem ?? row.timing,
            row.summary
        )
    }

    /// The row's primary action is the one its click performs. A themed control that states a
    /// role without exposing the action behind it is unusable from assistive technology, which
    /// is why `ThemeBoundaryAudit` fails the build over it rather than leaving it to review.
    override func accessibilityPerformPress() -> Bool {
        onEdit?()
        return true
    }
}

// MARK: - Defaults

enum ScheduledStripDefaults {
    static let removeSymbol = "xmark"
    static let rowHeight: CGFloat = 26
}
