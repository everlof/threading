import AppKit

// MARK: - Subagent Navigator Row

/// One child agent in the Subagents navigator: a **selectable row**, not a disclosure.
///
/// # Why a row and not a chevron
///
/// The navigator's rows were `ThemedButton`s carrying a `›`, and a `›` promises more of *this*
/// underneath. There was none: pressing one swapped the transcript further down the pane, the
/// row itself changed nothing but its mark, and the row already open answered a second press
/// with nothing at all. Three finished children were reported as "all agents just output to the
/// same space", because no row said which of the three the transcript belonged to.
///
/// A row that is *selected* says so. It paints the theme's selection under the child whose
/// transcript is on screen — the way the sidebar paints the session whose pane is — and a press
/// means "show this one". Hover and keyboard focus lift the row the way a tab lifts, so a row
/// that can be opened reads as pressable without a mark that lies about what pressing does. A
/// row that leads nowhere is disabled: it keeps its place and its facts, paints no plate, and
/// says in words why it does not open.
///
/// # Why the title is a label
///
/// A button's title follows the theme's display convention, and Cyberpunk's convention is
/// uppercase. That is right for "Apply" and wrong for a name: Codex reports every spawned child's
/// role as `default`, and three rows of DEFAULT read as one heading repeated rather than as three
/// agents. The title here is type, drawn as authored, and the theme's convention stays with the
/// controls it was written for.
final class SubagentNavigatorRowView: BackdropThemedControl {

    // MARK: - Layout

    private enum Layout {
        /// Rounded rect at the control corner — the silhouette every other small plate in the
        /// chrome takes, including the tab this row's states are modelled on.
        @MainActor static var radius: CGFloat { Design.Radius.control }

        /// How far the plate reaches past the ink on either side. Small on purpose: the plate is
        /// the row's state, not furniture, and the card holding the list already has its inset.
        static let horizontalInset = Design.Spacing.small
        static let verticalInset = Design.Spacing.small
        static let lineSpacing = Design.Spacing.hairline
        static let detailLineLimit = 2
    }

    /// Where a row's ink starts inside its plate. Published so the card's own header and the
    /// transcript heading below the card can line their words up with the rows' — a list is
    /// aligned by ink, and the plate is the one thing here that is not ink.
    static var inkInset: CGFloat { Layout.horizontalInset }

    // MARK: - Properties

    /// The row was pressed: show this child's transcript.
    var onSelect: (() -> Void)?

    /// The folder mark was pressed, for a child whose provider transcript is a file on disk.
    var onRevealTranscript: ((URL) -> Void)?

    /// The item this row currently shows.
    private(set) var item: SubagentSummaryItem?

    /// Whether this row's child is the one whose transcript is on screen.
    private(set) var isSelected = false

    /// The row's title as authored — the name the label shows and VoiceOver reads.
    var title: String { item?.title ?? "" }

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let revealButton: ThemedIconButton
    private let metaLabel = NSTextField(wrappingLabelWithString: "")
    private let promptLabel = NSTextField(wrappingLabelWithString: "")
    private let activityLabel = NSTextField(wrappingLabelWithString: "")
    private let unavailableLabel = NSTextField(
        wrappingLabelWithString: L10n.string("No transcript recorded.")
    )
    private let lines = NSStackView()

    private var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            needsDisplay = true
        }
    }

    // MARK: - Initialization

    init() {
        revealButton = ThemedIconButton(
            symbolName: "folder",
            accessibility: L10n.string("Reveal in Finder"),
            target: .inline,
            inkSource: .chrome
        )
        super.init(frame: .zero, inkSource: .chrome)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.applyFont(.detail())
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        revealButton.toolTip = L10n.string("Reveal in Finder")
        revealButton.onPress = { [weak self] in
            guard let self, let url = self.item?.transcriptAvailability.fileURL else { return }
            self.onRevealTranscript?(url)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let heading = NSStackView(views: [titleLabel, spacer, revealButton, statusLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = Design.Spacing.small
        heading.translatesAutoresizingMaskIntoConstraints = false

        for label in [metaLabel, promptLabel, activityLabel, unavailableLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.applyFont(.detail(), in: .conversation)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = Layout.detailLineLimit
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        unavailableLabel.maximumNumberOfLines = 1

        // One accessible element: the row speaks, its labels do not repeat it. The folder mark
        // stays its own control, because it does something else.
        for label in [titleLabel, statusLabel, metaLabel, promptLabel, activityLabel, unavailableLabel] {
            label.setAccessibilityElement(false)
        }

        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = Layout.lineSpacing
        lines.translatesAutoresizingMaskIntoConstraints = false
        lines.setViews([heading, metaLabel, promptLabel, activityLabel, unavailableLabel], in: .top)
        addSubview(lines)

        NSLayoutConstraint.activate([
            lines.topAnchor.constraint(equalTo: topAnchor, constant: Layout.verticalInset),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.verticalInset),
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.horizontalInset),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.horizontalInset),
            heading.leadingAnchor.constraint(equalTo: lines.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: lines.trailingAnchor)
        ])
        for label in [metaLabel, promptLabel, activityLabel, unavailableLabel] {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: lines.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: lines.trailingAnchor)
            ])
        }
    }

    // MARK: - Content

    /// Restates the row for an item and whether it is the child on screen.
    ///
    /// The facts drawn are the item's projections, in a fixed order: the name and state, then
    /// the role/configuration/progress/usage line, the delegated task, the latest distinct
    /// activity, and — for a row that cannot open — the reason. Lines with nothing to say are
    /// removed rather than left blank, so two rows with different facts still stack tight.
    func show(_ item: SubagentSummaryItem, isSelected: Bool) {
        self.item = item
        self.isSelected = isSelected
        isEnabled = item.transcriptAvailability.isOpenable

        titleLabel.stringValue = item.title
        titleLabel.applyFont(isSelected ? .control : .controlRegular)
        statusLabel.stringValue = item.state.displayText

        revealButton.isHidden = item.transcriptAvailability.fileURL == nil

        let meta = item.metaLine
        metaLabel.stringValue = meta ?? ""
        metaLabel.isHidden = meta == nil

        let prompt = item.subtitle.flatMap { $0.isEmpty ? nil : $0 }
        promptLabel.stringValue = prompt ?? ""
        promptLabel.isHidden = prompt == nil

        let activity = item.latestDistinctActivity
        activityLabel.stringValue = activity ?? ""
        activityLabel.isHidden = activity == nil

        unavailableLabel.isHidden = isEnabled

        setAccessibilityTitle(item.title)
        setAccessibilityValue(isSelected)
        setAccessibilityHelp(isEnabled ? prompt : unavailableLabel.stringValue)
        needsDisplay = true
    }

    // MARK: - Drawing

    /// The opaque colour a **selected** row ends up showing, or `nil` when it is not selected —
    /// what its labels are inked against, and what a test measures instead of recomputing the
    /// fill by hand.
    var selectionGround: NSColor? {
        guard isSelected else { return nil }
        return SelectionSurface.quiet(over: resolvedGround()).ground
    }

    override func applyInk(_ ink: Design.Ink) {
        refreshInk()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        if isSelected {
            // The theme's own value, held back until the chrome's label reads on it — the same
            // strength a themed list row paints, so the child on screen looks selected the way
            // everything else selected in the window does.
            fill = SelectionSurface.quiet(over: resolvedGround()).fill
        } else if isEnabled, isPressed || isHovered || hasKeyboardFocus {
            fill = ink.surface
        } else {
            fill = .clear
        }

        // No border in any state: the fill and the title weight carry selection, as they do on a
        // tab. A frame would make the open child the one outlined thing in the list. No bevel
        // either, under any material: a list row is a place, not a button, and Platinum's list
        // selection was a flat wash where its buttons were raised.
        let shape = ThemedSurface.draw(
            bounds,
            fill: fill,
            border: nil,
            radius: Layout.radius,
            bevel: .none
        )
        drawKeyboardFocus(around: shape)
        refreshInk()
    }

    /// Inks every label against what the row actually painted. On a selected row that is the
    /// selection's ground, measured; everywhere else the chrome's own ladder. The state's colour
    /// was measured against the chrome too, so on the plate it is moved along its own lightness
    /// until it reads there — still the theme's green, only lighter or darker.
    private func refreshInk() {
        let ground = selectionGround
        let ladder = ground.map(Design.Text.on) ?? ink
        titleLabel.textColor = ladder.label
        statusLabel.textColor = item.map { item in
            ground.map { item.state.color.legible(on: $0) } ?? item.state.color
        } ?? ladder.secondary
        metaLabel.textColor = ladder.tertiary
        promptLabel.textColor = ladder.secondary
        activityLabel.textColor = ladder.secondary
        unavailableLabel.textColor = ladder.tertiary
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        guard isEnabled, inside else { return }
        onSelect?()
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        onSelect?()
        return true
    }

    /// The labels make no claim on the pointer; the whole row is the target. The folder mark is
    /// the one part that answers differently, and it answers for itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        if !revealButton.isHidden,
           revealButton.convert(revealButton.bounds, to: self).contains(localPoint) {
            return revealButton
        }
        return self
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityTitle() -> String? { title }

    override func accessibilityValue() -> Any? { isSelected }

    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
}

// MARK: - Subagent Transcript Heading

/// The line that says whose transcript is on screen.
///
/// The navigator and the transcript are one document, stacked — and in a pane with a dozen
/// children the transcript starts a long way below the row that selected it. Without a name at
/// the seam the rows below read as a pool every child pours into. This band is the seam: the
/// word *Transcript*, the child's name, its state, and a rule, so the reader arriving at the
/// first row knows which agent is speaking.
final class SubagentTranscriptHeadingView: NSView, ThemedComponent {

    private enum Layout {
        /// Aligned by ink with the navigator card above: the card holds its content `inset`
        /// from its edge and its rows hold their words `inkInset` inside their plates.
        @MainActor static var horizontalInset: CGFloat {
            Design.Spacing.inset + SubagentNavigatorRowView.inkInset
        }
    }

    private let eyebrowLabel = NSTextField(labelWithString: L10n.string("Transcript"))
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let rule = SeparatorView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)

        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false
        eyebrowLabel.applyFont(.caption)
        eyebrowLabel.textColor = Design.Text.tertiary
        eyebrowLabel.setContentHuggingPriority(.required, for: .horizontal)
        eyebrowLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.applyFont(.subheading)
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.applyFont(.detail())
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let band = NSStackView(views: [eyebrowLabel, titleLabel, spacer, statusLabel])
        band.orientation = .horizontal
        band.alignment = .firstBaseline
        band.spacing = Design.Spacing.small
        band.translatesAutoresizingMaskIntoConstraints = false

        rule.translatesAutoresizingMaskIntoConstraints = false

        addSubview(band)
        addSubview(rule)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: topAnchor),
            band.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.horizontalInset),
            band.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.horizontalInset),
            rule.topAnchor.constraint(equalTo: band.bottomAnchor, constant: Design.Spacing.small),
            rule.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Names the child whose transcript follows, and how it stands.
    func update(title: String, state: SubagentSummaryItem.State) {
        titleLabel.stringValue = title
        statusLabel.stringValue = state.displayText
        statusLabel.textColor = state.color
        setAccessibilityLabel(L10n.format("Transcript of %@", title))
    }
}
