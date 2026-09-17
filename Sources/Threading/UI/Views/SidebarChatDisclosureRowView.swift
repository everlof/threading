import AppKit

/// The row closing a project's chat preview: "Show 5 more", "Show remaining (12)", "Show fewer".
///
/// The whole row is one borderless `ThemedButton`, the list's own "show more" vocabulary (Git
/// Review's history ends in the same control). It draws no surface: the row view under it is a
/// `SidebarHoverRowView`, so the hover capsule is the sidebar's and matches every other row, and
/// `RowControls` lets the press through the outline instead of reading it as a row selection.
///
/// Its words line up with the session titles above it rather than with its own glyph, so the list
/// reads as one column of names ending in an offer to show more of them. What the hidden chats are
/// doing — the reason a folded chat might still matter — sits at the trailing edge, where a session
/// row's status mark sits.
final class SidebarChatDisclosureRowView: NSTableCellView {

    /// What the chats past the page are doing, counted over the running ones.
    struct HiddenActivity: Equatable {
        var attentionCount = 0
        var workingCount = 0

        var summary: String {
            [
                attentionCount == 0 ? nil
                    : attentionCount == 1 ? L10n.string("1 needs attention")
                    : L10n.format("%lld need attention", Int64(attentionCount)),
                workingCount == 0 ? nil : L10n.format("%lld working", Int64(workingCount)),
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
        }
    }

    // MARK: - Properties

    private let button = ThemedButton()
    private let activityLabel = MorphingTitleLabel()

    private var contentLeadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var hiddenActivity = HiddenActivity()

    /// Invoked when the row is pressed, by pointer, keyboard or assistive technology.
    var onPress: (() -> Void)?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    func configure(
        with preview: SidebarChatPreview,
        hiddenActivity: HiddenActivity,
        projectName: String
    ) {
        button.title = Self.title(for: preview)
        button.image = Self.chevron(isExpanded: preview.isExpanded)
        button.setAccessibilityHelp(L10n.format(
            preview.isExpanded ? "Show fewer chats in %@" : "Show more chats in %@",
            projectName
        ))

        self.hiddenActivity = hiddenActivity
        let summary = hiddenActivity.summary
        activityLabel.setStringValue(summary, animated: false)
        activityLabel.isHidden = summary.isEmpty
        activityLabel.refreshTextColor()
        toolTip = summary.isEmpty ? nil : summary
        button.setAccessibilityValue(summary.isEmpty ? nil : summary)
    }

    /// What the row says for one preview. Static, so a test states the wording without a view.
    static func title(for preview: SidebarChatPreview) -> String {
        if preview.isExpanded { return L10n.string("Show fewer") }
        if preview.nextStage == .all {
            return L10n.format("Show remaining (%lld)", Int64(preview.hiddenCount))
        }
        return L10n.format("Show %lld more", Int64(preview.nextRevealCount))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onPress = nil
    }

    // MARK: - Private Methods

    private func setupViews() {
        button.emphasis = .tertiary
        button.drawsSurface = false
        button.contentAlignment = .leading
        button.applyFont(.controlRegular)
        button.contentTintColor = Design.Text.secondary
        button.target = self
        button.action = #selector(buttonPressed)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(SidebarRowDefaults.stretchableHugging, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.setAccessibilityIdentifier("sidebar.chat-disclosure")

        activityLabel.applyFont(.numericDetail())
        activityLabel.setTextColor { [weak self] in
            (self?.hiddenActivity.attentionCount ?? 0) > 0
                ? Design.Status.warning
                : Design.Text.secondary
        }
        activityLabel.setContentHuggingPriority(.required, for: .horizontal)
        // The offer is the row's point; the summary is what gives way in a narrow column.
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityLabel.translatesAutoresizingMaskIntoConstraints = false
        activityLabel.setAccessibilityIdentifier("sidebar.chat-disclosure.activity")
        activityLabel.isHidden = true

        // The summary sits *under* the button: the button draws no surface, so the summary shows
        // through, and a press on it still lands on the button rather than on a label the
        // outline would read as a click on the row.
        addSubview(activityLabel)
        addSubview(button)

        let leading = button.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.buttonLeading(forRowLeadingInset: SidebarRowDefaults.leadingInset)
        )
        let trailing = activityLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -SidebarRowDefaults.trailingInset
        )
        contentLeadingConstraint = leading
        trailingConstraint = trailing

        NSLayoutConstraint.activate([
            leading,
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The press reaches under the summary: the whole row is the offer, and the summary
            // is part of what it is offering to show.
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            activityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: button.leadingAnchor,
                constant: ThemedButton.plainTitleLeadingInset
            ),
            trailing,
        ])
        setAccessibilityElement(false)
    }

    /// Where the button starts so its *title* lands on a session title's first letter: a session
    /// row puts its icon slot at the row's leading inset and the title one spacing after it, and
    /// a plain button draws its title `plainTitleLeadingInset` in from its own edge.
    private static func buttonLeading(forRowLeadingInset inset: CGFloat) -> CGFloat {
        inset
            + SidebarRowDefaults.iconSlotWidth
            + SidebarRowDefaults.horizontalSpacing
            - ThemedButton.plainTitleLeadingInset
    }

    private static func chevron(isExpanded: Bool) -> NSImage? {
        NSImage(
            systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
    }

    /// Deferred one turn: the press reshapes the list this row stands in, and a control that
    /// rebuilds its own container from inside its own mouse-up hands AppKit a row mid-event.
    @objc private func buttonPressed() {
        DispatchQueue.main.async { [weak self] in
            self?.onPress?()
        }
    }
}

// MARK: - Sidebar Density

extension SidebarChatDisclosureRowView: SidebarDensityAdopting {

    /// Restates the two gutters at the width the column now has, the way session rows do, so the
    /// title stays on the session titles' line as the column narrows.
    func applySidebarDensity(_ density: SidebarDensity) {
        contentLeadingConstraint?.constant = Self.buttonLeading(
            forRowLeadingInset: density.rowLeadingInset
        )
        trailingConstraint?.constant = -density.rowTrailingInset
    }
}
