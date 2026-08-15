import AppKit

/// The messages waiting to be sent, between the transcript and the composer.
///
/// **They belong here and nowhere else.** A queued message is not conversation — it has not
/// happened, and drawing it as a user bubble claims the agent has seen it. It is not composer
/// either — it is no longer being typed. The gap between the two is exactly what it is, and
/// putting it there means the eye finds it on the way from what was said to what is being
/// written.
///
/// A steered message never appears here. It goes straight into the transcript as a user bubble
/// inside the running turn, because that is where it went.
///
/// The rail knows nothing about transports or providers. It is handed rows and reports gestures.
final class ConversationOutboxRailView: NSView, ThemedComponent {

    // MARK: - Row Model

    /// One row, already resolved by the owner. Deliberately not `ConversationOutbox.Item`: the
    /// rail draws a title and a state, and giving it the prompt would let a future row reach for
    /// context attachments the composer has already accounted for.
    struct Row: Equatable {
        let id: ConversationMessageID
        let summary: String
        let state: MessageLifecycleState
    }

    // MARK: - Callbacks

    /// Reordering, in `pending` terms — the indices the user can actually see move.
    var onMove: ((Int, Int) -> Void)?
    var onRemove: ((ConversationMessageID) -> Void)?
    var onEdit: ((ConversationMessageID) -> Void)?

    // MARK: - Properties

    private let stack = NSStackView()
    private(set) var rows: [Row] = []

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let inset = OutboxRailDefaults.trayInset
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
        isHidden = true
        applyTheme()
    }

    // MARK: - Content

    func setRows(_ values: [Row]) {
        guard values != rows else { return }
        rows = values
        rebuild()
    }

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, row) in rows.enumerated() {
            let view = ConversationOutboxRowView(row: row, position: index + 1, of: rows.count)
            view.applyTheme()
            view.onRemove = { [weak self] in self?.onRemove?(row.id) }
            view.onEdit = { [weak self] in self?.onEdit?(row.id) }
            view.onMove = { [weak self] direction in
                guard let self, let from = self.pendingIndex(of: row.id) else { return }
                self.onMove?(from, from + direction)
            }
            view.onDrag = { [weak self] offset in
                guard let self, let from = self.pendingIndex(of: row.id) else { return }
                self.onMove?(from, from + offset)
            }
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        isHidden = rows.isEmpty
    }

    /// A row's position among the ones the user can still move, which is what the outbox's own
    /// reordering is stated in. Rows already handed over are drawn but do not take part.
    private func pendingIndex(of id: ConversationMessageID) -> Int? {
        rows.filter { $0.state.isPending }.firstIndex { $0.id == id }
    }

    // MARK: - ThemedComponent

    /// A tray, not three loose lines.
    ///
    /// Drawn from a fixture: with no container the rows floated between the transcript and the
    /// composer, and the space each one stretched across to put its remove at the trailing edge
    /// belonged to nothing — a sentence on the left, a glyph on the right, and a gap in between
    /// that read as a mistake. A quiet panel gives that space an owner and says these three
    /// things are one waiting list.
    ///
    /// `panel` rather than `field`: the composer below is a field, and two wells stacked read as
    /// two places to type. This is the shelf the composer stands on.
    func applyTheme() {
        applySurface(fill: Design.Surface.panel, radius: .panel)
        for case let row as ConversationOutboxRowView in stack.arrangedSubviews {
            row.applyTheme()
        }
    }
}

// MARK: - Row

/// One waiting message.
///
/// Quiet at rest and legible on hover, which is the design system's own rule and matters more
/// than usual here: the row carries three actions and none of them may shout over the sentence
/// the user wrote.
final class ConversationOutboxRowView: ThemedControl {

    var onRemove: (() -> Void)?
    var onEdit: (() -> Void)?

    /// Keyboard reordering: −1 up, +1 down.
    var onMove: ((Int) -> Void)?

    /// Pointer reordering, in rows moved from this one's own position.
    var onDrag: ((Int) -> Void)?

    private let row: ConversationOutboxRailView.Row
    private let position: Int
    private let total: Int

    /// Which message this row is, so a caller holding an id can find its view.
    var identity: ConversationMessageID { row.id }

    /// A theme states colours the labels here read once, so a live switch has to reach them.
    /// `ThemedControl`'s own redraw covers what this view *draws*; the text fields inside it are
    /// AppKit's and keep whatever colour they were last given.
    private let appEvents = AppEventObservations()

    private let handle = GlyphView()
    private let summary = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private lazy var remove = ThemedIconButton(
        symbolName: DesignSymbols.removeAttachment,
        accessibility: L10n.string("Remove from queue"),
        target: .inline
    )

    /// Where the pointer went down, so a drag can be measured in rows rather than in points at
    /// every event.
    private var dragOrigin: CGPoint?

    init(row: ConversationOutboxRailView.Row, position: Int, of total: Int) {
        self.row = row
        self.position = position
        self.total = total
        super.init(frame: .zero)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        isEnabled = row.state.isPending

        handle.setSymbol(OutboxRailDefaults.handleSymbol)
        handle.setAccessibilityLabel(L10n.string("Reorder"))
        // Required, or `.fill` hands the row's slack to the glyph — a plain view hugs at 250,
        // the same as nothing, so the grip became a spacer and pushed the whole row right.
        handle.setContentHuggingPriority(.required, for: .horizontal)
        remove.setContentHuggingPriority(.required, for: .horizontal)

        // No position number. A queue's order is which row is above which, and a column of
        // numbers beside sentences that already stack in order is a second way of saying one
        // thing — noise in a component whose whole job is to stay out of the way.
        summary.stringValue = row.summary
        summary.applyFont(.body, in: .conversation)
        summary.lineBreakMode = .byTruncatingTail
        summary.usesSingleLineMode = true
        summary.translatesAutoresizingMaskIntoConstraints = false
        // Takes the slack, so the state and the remove finish the row at its trailing edge
        // rather than trailing the sentence. Drawn from a fixture: with the label hugging its
        // text, a two-word message put its ✕ a third of the way across the pane and the rows
        // read as three different shapes instead of one list.
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.toolTip = row.summary

        stateLabel.stringValue = OutboxRailDefaults.stateName(row.state)
        stateLabel.applyFont(.caption, in: .chrome)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        // A pending row says nothing about its state: its state is that it is in the queue,
        // which the queue already says. Only a row that has left says where it went.
        stateLabel.isHidden = row.state.isPending

        remove.onPress = { [weak self] in self?.onRemove?() }

        // **Never `isHidden`, always alpha.** A stack detaches a hidden arranged view, so the
        // geometry moved every time one appeared: the row without a grip started a whole glyph's
        // width left of the others, and a remove that materialised on hover shortened the
        // sentence beside it as the pointer arrived. Invisible ink holds its place.
        //
        // And quiet until relevant, which is this design system's own rule: two controls drawn at
        // rest on every row of a waiting list shout over the sentences the list exists to show.
        // A row the transport already holds shows neither at any time, because neither is a
        // power we still have over it.
        let content = NSStackView(views: [handle, summary, stateLabel, remove])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        // `.fill`, not the default gravity packing: the slack has to go somewhere, and the
        // summary is the only view that asked for it. Packed by gravity every row ended at its
        // own sentence, so the removes formed a ragged edge down the middle of the tray.
        content.distribution = .fill
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.tight),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small),
            heightAnchor.constraint(greaterThanOrEqualToConstant: OutboxRailDefaults.rowHeight)
        ])
        updateControlVisibility()

        setAccessibilityRole(.row)
        setAccessibilityLabel(L10n.format("Queued message %lld of %lld", Int64(position), Int64(total)))
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
        applyTheme()
    }

    // MARK: - Theme

    /// A row has no fill at rest, and takes one on hover.
    ///
    /// The same rule the tool rows follow, for the same reason: with no fill, hover is the only
    /// thing saying the row can be dragged and clicked. A queue of five filled slabs under the
    /// composer would read as louder than the conversation it is waiting on.
    func applyTheme() {
        applySurface(
            fill: isHovered ? Design.Chat.toolRowActive : Design.Chat.toolRowResting,
            radius: .control
        )
        stateLabel.textColor = Design.Text.tertiary
        summary.textColor = row.state.isPending ? Design.Text.label : Design.Text.secondary
        handle.tint = Design.Text.tertiary
    }

    override func hoverDidChange() {
        super.hoverDidChange()
        updateControlVisibility()
        applyTheme()
    }

    private func updateControlVisibility() {
        let offered = row.state.isPending && isHovered
        handle.alphaValue = offered ? 1 : 0
        remove.alphaValue = offered ? 1 : 0
        // Alpha hides ink, not hit-testing: a remove nobody can see must not still be clickable.
        remove.isEnabled = offered
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilityTitle() -> String? { row.summary }
    override func accessibilityValue() -> Any? { OutboxRailDefaults.stateName(row.state) }

    /// The row's primary action is opening it for editing, which is what a click does.
    override func accessibilityPerformPress() -> Bool {
        guard row.state.isPending, let onEdit else { return false }
        onEdit()
        return true
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        guard row.state.isPending else { return }
        dragOrigin = convert(event.locationInWindow, from: nil)
    }

    /// Reordering by pointer, measured in whole rows.
    ///
    /// The offset is recomputed from the *original* press point every time rather than
    /// accumulated: the owner reorders the model and hands back a rebuilt rail, so this view is
    /// replaced mid-gesture and an accumulated delta would be lost with it. Measuring from a
    /// fixed origin makes each event independently correct.
    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin, row.state.isPending else { return }
        let point = convert(event.locationInWindow, from: nil)
        let travelled = dragOrigin.y - point.y
        let step = OutboxRailDefaults.rowHeight + Design.Spacing.tight
        let offset = Int((travelled / step).rounded())
        guard offset != 0 else { return }
        self.dragOrigin = nil
        onDrag?(offset)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        // A press that never became a drag is a click, and a click on a waiting message opens it
        // for editing — the row is the message, so the row is what you edit.
        guard let dragOrigin, row.state.isPending else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(dragOrigin.y - point.y) < OutboxRailDefaults.clickSlop else { return }
        onEdit?()
    }

    // MARK: - Keyboard

    /// Reordering and removal from the keyboard, so a queue is not a pointer-only feature.
    ///
    /// ⌘↑/⌘↓ rather than bare arrows, because bare arrows move the focus between rows and a list
    /// you cannot walk is a list you cannot reorder deliberately.
    override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case OutboxRailDefaults.upArrowKeyCode where event.modifierFlags.contains(.command):
            onMove?(-1)
        case OutboxRailDefaults.downArrowKeyCode where event.modifierFlags.contains(.command):
            onMove?(1)
        case OutboxRailDefaults.deleteKeyCode:
            onRemove?()
        default:
            super.keyDown(with: event)
        }
    }

    override func performPrimaryAction() -> Bool {
        guard row.state.isPending, let onEdit else { return false }
        onEdit()
        return true
    }
}

// MARK: - Defaults

enum OutboxRailDefaults {
    /// Matches the height a single line of body text needs plus its padding, so a rail of three
    /// reads as a list rather than as three separate cards.
    static let rowHeight: CGFloat = 24

    /// The tray's own padding around its rows. `tight` rather than `inset`, because the tray is
    /// a shelf holding single lines rather than a panel holding content: at 12 the three rows
    /// floated in the middle of a box half again their own height.
    static let trayInset: CGFloat = Design.Spacing.tight

    /// How far the pointer may travel and still count as a click rather than a drag.
    static let clickSlop: CGFloat = 3

    static let handleSymbol = "line.3.horizontal"

    static let upArrowKeyCode: UInt16 = 126
    static let downArrowKeyCode: UInt16 = 125
    static let deleteKeyCode: UInt16 = 51

    /// What a row says about itself once it has left the queue.
    ///
    /// A pending row says nothing — see `ConversationOutboxRowView`. These exist because a
    /// provider that reports lifecycle can say something truer than "sent", and a row that
    /// states the provider's own answer is the whole reason the identifier is carried.
    ///
    /// No trailing ellipses. Sitting at the trailing edge of a row whose sentence truncates with
    /// one, "Working…" read as a clipped word rather than a state — the picture said the label
    /// had run out of room when it had not.
    static func stateName(_ state: MessageLifecycleState) -> String {
        switch state {
        case .queued: L10n.string("Queued")
        case .handedOver: L10n.string("Sending")
        case .started: L10n.string("Working")
        case .completed: L10n.string("Done")
        case .cancelled: L10n.string("Cancelled")
        }
    }
}
