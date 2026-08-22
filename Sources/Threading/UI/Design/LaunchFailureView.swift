import AppKit

// MARK: - Launch Failure Action

/// One way to answer a failed launch.
struct LaunchFailureAction {

    let title: String
    let emphasis: ThemedButton.Emphasis
    let handler: () -> Void

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

// MARK: - Launch Failure View

/// The pane surface for a session whose agent died on the way up: what happened, what it
/// printed, and the ways out.
///
/// It replaces the dormant placeholder rather than sitting beside it, for the reason
/// `showRecoveryState` already states about the recovery band — a surface and a placeholder
/// saying the same thing bury the one sentence that matters. A failed launch is not a dormant
/// session with a footnote; it is a different condition, and it gets the pane.
///
/// **The output well is the point of the whole component.** Everything else here could have been
/// a placeholder with an extra button. What could not was keeping the words: an agent that
/// refuses to start prints its reason to a terminal that Threading then tears down, and on the
/// specimen this was built against — Codex refusing a rollout whose final record had no ordinal
/// — the message was legible in a single frame of a 60fps screen recording. So the well is
/// selectable, scrollable and monospaced, the text arrives already bounded by
/// `SessionLaunchFailure`, and no route off this surface can send it anywhere the user has not
/// read it first.
///
/// The well is *not* a terminal. It has no colour, no cursor and no scrollback, and it is not
/// trying to be: what survived is the tail of one screen, which is all a process that lived
/// under a second ever wrote.
final class LaunchFailureView: NSView, ThemedComponent {

    // MARK: - Properties

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let outputWell = ThemedSurfaceView()
    private let outputScroll = ThemedTextView.scrolling()
    private let actionRow = NSStackView()

    /// Held so the tag-indexed target/action can find the handler it belongs to — the wiring
    /// `PaneNoticeView` uses, for its reason: a stack of closures on the buttons themselves
    /// would retain this view through every one of them.
    private var actions: [LaunchFailureAction] = []
    private lazy var wellHeight = outputWell.heightAnchor.constraint(
        equalToConstant: LaunchFailureDefaults.wellHeight
    )

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Draws one failure. Passing no captured output hides the well rather than showing an
    /// empty box, because a preflight refusal has nothing to quote and an empty well reads as
    /// output that was lost.
    func configure(
        title: String,
        summary: String,
        output: [String],
        actions: [LaunchFailureAction]
    ) {
        iconView.image = NSImage(
            systemSymbolName: DesignSymbols.reportRefused,
            accessibilityDescription: title
        )
        titleLabel.stringValue = title
        summaryLabel.stringValue = summary

        let text = output.joined(separator: "\n")
        outputWell.isHidden = text.isEmpty
        wellHeight.isActive = !text.isEmpty
        outputScroll.textView.string = text

        setActions(actions)
        setAccessibility(title: title, summary: summary, output: text)
    }

    // MARK: - Private Methods

    private func setupViews() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = Design.Status.warning

        // **Full ink, unlike the dormant placeholder this replaces.** That surface is quiet
        // because nothing is wrong — it is an empty state, and `Text.secondary` over
        // `Text.tertiary` is right for one. Reusing those roles here put the sentence naming
        // the failure at the contrast of a caption: the render showed a headline you had to
        // hunt for, on the one surface whose entire job is to be read.
        titleLabel.applyFont(.placeholderTitle)
        titleLabel.textColor = Design.Text.label
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 0

        summaryLabel.applyFont(.subheading)
        summaryLabel.textColor = Design.Text.secondary
        summaryLabel.alignment = .center
        summaryLabel.maximumNumberOfLines = 0

        setupOutputWell()

        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = Design.Spacing.small

        let announcement = NSStackView(views: [titleLabel, summaryLabel])
        announcement.orientation = .vertical
        announcement.alignment = .centerX
        announcement.spacing = Design.Placeholder.line

        let stack = NSStackView(views: [iconView, announcement, outputWell, actionRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Placeholder.line
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(Design.Placeholder.afterIcon, after: iconView)
        stack.setCustomSpacing(Design.Placeholder.section, after: announcement)
        stack.setCustomSpacing(Design.Placeholder.section, after: outputWell)

        addSubview(stack)

        // **The column needs a definite width, not a cap.** A vertical `NSStackView` aligned
        // `.centerX` gives each arranged view its *fitting* width, so a well constrained only
        // "no wider than the pane" comes out as wide as whichever sibling happens to be widest
        // — the settings section that shipped at a third of its pane made exactly this mistake
        // (see design-system.md). So the column is pulled out to the pane and capped, and the
        // well and the wrapping labels are held to it.
        let columnWidth = stack.widthAnchor.constraint(
            equalTo: widthAnchor,
            constant: -PlaceholderDefaults.horizontalInset
        )
        columnWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: Design.Spacing.pane
            ),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            columnWidth,
            stack.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor,
                constant: -PlaceholderDefaults.horizontalInset
            ),
            stack.widthAnchor.constraint(
                lessThanOrEqualToConstant: LaunchFailureDefaults.wellMaximumWidth
            ),
            outputWell.widthAnchor.constraint(equalTo: stack.widthAnchor),
            announcement.widthAnchor.constraint(equalTo: stack.widthAnchor),
            wellHeight
        ])
    }

    private func setupOutputWell() {
        outputWell.applySurface(
            fill: Design.Surface.field,
            radius: .panel,
            border: Design.Surface.border
        )

        let textView = outputScroll.textView
        textView.isEditable = false
        // Selectable but not editable: the words must be copyable — that is most of the point —
        // and an editable well would offer to let the user change a record of what happened.
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.applyFont(.previewCode)
        textView.textColor = Design.Text.label
        // No wrapping. A wrapped stack trace stops looking like the thing the terminal showed,
        // and a horizontal scroller inside its own container is the Scaling Gate's answer for
        // content whose width comes from outside.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        outputScroll.hasHorizontalScroller = true

        outputScroll.translatesAutoresizingMaskIntoConstraints = false
        outputWell.addSubview(outputScroll)
        NSLayoutConstraint.activate([
            outputScroll.topAnchor.constraint(
                equalTo: outputWell.topAnchor,
                constant: Design.Spacing.small
            ),
            outputScroll.bottomAnchor.constraint(
                equalTo: outputWell.bottomAnchor,
                constant: -Design.Spacing.small
            ),
            outputScroll.leadingAnchor.constraint(
                equalTo: outputWell.leadingAnchor,
                constant: Design.Spacing.medium
            ),
            outputScroll.trailingAnchor.constraint(
                equalTo: outputWell.trailingAnchor,
                constant: -Design.Spacing.medium
            )
        ])
    }

    private func setActions(_ actions: [LaunchFailureAction]) {
        for view in actionRow.arrangedSubviews {
            actionRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        self.actions = actions
        for (index, action) in actions.enumerated() {
            let button = ThemedButton(
                title: action.title,
                target: self,
                action: #selector(actionPressed)
            )
            button.emphasis = action.emphasis
            button.isProminent = action.emphasis == .primary
            button.tag = index
            button.setContentHuggingPriority(.required, for: .horizontal)
            actionRow.addArrangedSubview(button)
        }
    }

    @objc private func actionPressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].handler()
    }

    /// One element that reads the whole condition, so the surface is not a silent picture to a
    /// screen reader that cannot see the well.
    private func setAccessibility(title: String, summary: String, output: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        outputScroll.textView.setAccessibilityLabel(
            L10n.string("What the agent printed before it stopped")
        )
        summaryLabel.setAccessibilityLabel(summary)
    }
}

// MARK: - Defaults

enum LaunchFailureDefaults {

    /// Tall enough for the specimen this was built against — a four-line Codex refusal — plus
    /// room to see that there is more, and short enough that the actions stay above the fold in
    /// a half-height pane.
    static let wellHeight: CGFloat = 132

    /// Beyond this the well stops being a quotation and starts being a document.
    static let wellMaximumWidth: CGFloat = 720
}
