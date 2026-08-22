import AppKit

// MARK: - Conversation Sticky Step

/// Which tool call you are currently inside, pinned to the top of the conversation.
///
/// A turn that ran forty tool calls is one mark on the rail and one very tall stretch of pane, so
/// scrolling through it loses the thing every other line is about: which call this output belongs
/// to. The header answers that in place — the call's glyph, its tool, and the one-line subject the
/// call already carries.
///
/// **It costs no width.** That is the point of choosing it over anything in the gutter: the rail
/// disappears in a narrow pane and Threading is a three-pane window, so the narrow pane is the
/// common case. One line across the top is the only affordance that survives it, which is why this
/// ships before the rail learns to subdivide.
///
/// It shows the *model's* subject rather than whatever a customized tool row drew, so an extension
/// that restyles a row and the header naming it can differ. That is deliberate: the header is
/// navigation, and navigation reads the timeline.
final class ConversationStickyStepView: NSView, PointerClaiming {

    // MARK: - Metrics

    private enum Metrics {
        /// The subject is the long part and truncates; the tool name in front of it must not.
        static let labelCompressionResistance: NSLayoutConstraint.Priority = .defaultHigh

        /// Enough to read as raised over text, short of reading as a dialog over a page.
        static let shadowAlpha: CGFloat = 0.18
        static let shadowRadius: CGFloat = 4
        static let shadowDrop: CGFloat = 1
    }

    // MARK: - Properties

    /// Called with the timeline row index of the pinned call, when the header is clicked.
    var onSelect: ((Int) -> Void)?

    private let glyphLabel = NSTextField(labelWithString: "")
    private let toolLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")
    /// The reading column, so the band's content lands on the same ink as the rows beneath it.
    private let column = NSLayoutGuide()

    /// The column's stated width — `layout()` keeps the constant at what the band can actually
    /// give, so the constraint never pulls on the band, and through the band's required pane-wide
    /// pins never on the pane. See `ConversationDefaults.statedColumnPriority`.
    private lazy var columnWidth: NSLayoutConstraint = {
        let constraint = column.widthAnchor.constraint(
            equalToConstant: Design.Size.readableWidth
        )
        constraint.priority = ConversationDefaults.statedColumnPriority
        return constraint
    }()

    private var rowIndex: Int?
    private var isHighlighted = false { didSet { updateInk() } }

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        // Opaque rather than the panel role straight: it floats over live text, and a translucent
        // strip over a moving transcript reads as a rendering fault rather than as chrome.
        //
        // **A band, not a card.** It was both at once — square corners like a band, but held to
        // the column's width like a card — and read as a transcript row that had drifted to the
        // top and lost its place. A band spans the pane; only its *content* stands on the column.
        //
        // The fill alone cannot carry it either: `Design.Surface.panel` over the conversation's
        // ground measures **1.15:1** in the light appearance, so the strip was invisible as a
        // surface and the only thing announcing it was the text it clipped.
        //
        // A hairline does not fix that. `SeparatorView` draws `Surface.divider`, which is tuned
        // for separating rows *inside* a surface, and at this contrast it says nothing about a
        // band floating over live text. Fill, rule and shadow would be three things doing one
        // job, so the rule is the one that goes: a shadow states "above" unambiguously in both
        // appearances and needs no token retuned. Same choice `ConversationTurnPreview` makes,
        // for the same reason, shallower because this one is attached to an edge rather than
        // hovering free.
        applySurface(fill: WindowBackdrop.opaque(Design.Surface.panel), radius: .fixed(0))
        shadow = NSShadow()
        applyLayerShadow(NSColor.black.withAlphaComponent(Metrics.shadowAlpha))
        layer?.shadowOpacity = 1
        layer?.shadowRadius = Metrics.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -Metrics.shadowDrop)

        glyphLabel.applyFont(.caption, in: .conversation)
        glyphLabel.textColor = Design.Text.tertiary
        glyphLabel.alignment = .center

        toolLabel.applyFont(.caption, in: .conversation)
        toolLabel.textColor = Design.Text.secondary
        toolLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        subjectLabel.applyFont(.caption, in: .conversation)
        subjectLabel.textColor = Design.Text.label
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.maximumNumberOfLines = 1
        subjectLabel.setContentCompressionResistancePriority(
            Metrics.labelCompressionResistance, for: .horizontal
        )

        let row = NSStackView(views: [glyphLabel, toolLabel, subjectLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Design.Spacing.small
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        addLayoutGuide(column)

        // The content stands on the column the transcript stands on, stated the way the reply
        // box states it: the cap and the inset floor are required, and `layout()` states the
        // width the band's current size leaves for the column. The band itself is pinned
        // pane-wide by its owner, which is exactly why the column may not reach for the band's
        // width with an equality — at `.defaultHigh` that pull, under the required cap, clamped
        // the whole conversation pane to the column and the divider would not move. See
        // `ConversationDefaults.statedColumnPriority`.
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Design.Size.readableWidth),
            column.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Design.Spacing.inset
            ),
            columnWidth,

            // Exactly `ToolCallView`'s leading structure, down to the padding, because the header
            // **is** a copy of the row it names: `Spacing.small`, a glyph column of
            // `toolIconWidth`, `Spacing.small`, then the labels. The transcript has two ink edges
            // — prose on the column, tool rows one glyph gutter in — and the header belongs on
            // the second. Held to its own inset inside a column-width plate it invented a third,
            // which is what made it look like a row that had lost its place.
            glyphLabel.widthAnchor.constraint(equalToConstant: Design.Chat.toolIconWidth),

            row.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small),
            row.leadingAnchor.constraint(
                equalTo: column.leadingAnchor, constant: Design.Spacing.small
            ),
            row.trailingAnchor.constraint(
                lessThanOrEqualTo: column.trailingAnchor, constant: -Design.Spacing.small
            ),
        ])
    }

    /// States the column for the band's current width before the pass lays it out — the plain
    /// view's `viewDidLayout`.
    override func layout() {
        let width = min(
            Design.Size.readableWidth,
            bounds.width - Design.Spacing.inset * 2
        )
        if width > 0, abs(columnWidth.constant - width) > 0.5 {
            columnWidth.constant = width
        }
        super.layout()
    }

    // MARK: - Public Methods

    /// Names the call the reader is currently inside, or nothing.
    ///
    /// Nil is not a failure state: the top of a turn, a fold, and a divider all legitimately have
    /// no step to name, and saying so by disappearing is quieter than naming the wrong one.
    func show(tool: ToolIdentity, subject: String, atRow index: Int) {
        let style = ToolGlyph.forTool(tool)
        glyphLabel.stringValue = style.symbol
        toolLabel.stringValue = style.label
        subjectLabel.stringValue = subject
        rowIndex = index
        setAccessibilityLabel("\(style.label) \(subject)")
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard let rowIndex else { return }
        onSelect?(rowIndex)
    }

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    /// The header is a line of the transcript you can press, so the hand — and stating it is
    /// what keeps the transcript's own I-beam from reaching a strip that is not text any more.
    /// It used to set the cursor by hand from a `.cursorUpdate` tracking area, which is a second
    /// mechanism answering the same question. See `PointerClaiming`.
    var restingPointer: NSCursor? { .pointingHand }

    override func resetCursorRects() {
        registerPointerClaims()
    }

    /// Hover answers in ink rather than in a plate: the strip already sits on the transcript's
    /// own surface, and a wash the width of the pane would read as a selected row.
    private func updateInk() {
        subjectLabel.textColor = isHighlighted ? Design.Surface.accent : Design.Text.label
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard let rowIndex else { return false }
        onSelect?(rowIndex)
        return true
    }
}
