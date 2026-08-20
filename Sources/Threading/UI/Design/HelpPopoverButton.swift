import AppKit

/// What a "?" explains, as a value.
///
/// A page states the topic; the button owns how it is shown. Keeping the words here rather than
/// inside the view is what lets a test assert the explanation without opening a panel, and what
/// lets the button put the same words in its accessibility help — so the explanation is reachable
/// by a reader who never presses anything.
struct HelpTopic: Equatable {

    /// A question and its answer, printed as two columns.
    struct Line: Equatable {
        let term: String
        let detail: String

        init(term: String, detail: String) {
            self.term = term
            self.detail = detail
        }
    }

    /// What the popover is about. Also the button's accessibility name, so a screen reader says
    /// "Tailscale, help" rather than "help" four times down a page.
    let title: String

    /// The paired lines, in the order they are asked.
    let lines: [Line]

    /// The prose that is too long to stand on the page beside a control.
    let paragraphs: [String]

    init(title: String, lines: [Line] = [], paragraphs: [String] = []) {
        self.title = title
        self.lines = lines
        self.paragraphs = paragraphs
    }

    /// Everything the popover holds, as one spoken string.
    ///
    /// The whole point of moving prose behind a press is that the page stops shouting it; the
    /// point of *this* is that moving it must not take it away from anybody. A reader on
    /// VoiceOver hears the complete answer from the button, and the panel is the sighted route
    /// to the same words.
    var spokenSummary: String {
        var parts: [String] = []
        parts.append(contentsOf: lines.map { "\($0.term): \($0.detail)" })
        parts.append(contentsOf: paragraphs)
        return parts.joined(separator: ". ")
    }

    /// Whether there is anything to show. A topic with neither lines nor paragraphs is a button
    /// that would open an empty panel, so its host hides it instead.
    var isEmpty: Bool { lines.isEmpty && paragraphs.isEmpty }
}

/// The "?" beside a name, and the themed panel it opens.
///
/// It exists because a settings page's explanations are not decoration: the four questions every
/// remote way in answers are a promise the page makes, and the page still has to be readable at a
/// glance. A tooltip is the wrong answer to that (see `design-system.md`, "a dimmed glyph with its
/// reason on a tooltip is the same dead end, quieter") — it is pointer-only, it cannot be selected
/// or read by a screen reader, and it disappears while you are reading it. A press, a themed
/// panel, Escape, and the same words in the button's accessibility help is the answer that keeps
/// every route open.
///
/// The button is deliberately quiet at rest — a secondary-ink mark, no plate — and answers the
/// pointer by lifting to the label tier over a control fill, which is the same two-step every
/// other quiet control in the app uses.
final class HelpPopoverButton: ThemedControl, OpticalInsetProviding {

    // MARK: - Properties

    /// What this button explains. Setting it renames the button and re-makes the panel's content,
    /// so a page whose facts changed under an open panel shows the new ones.
    var topic: HelpTopic {
        didSet {
            guard topic != oldValue else { return }
            applyTopic()
            if isPresenting { presented?.contentViewController = makeContent() }
            presented?.reposition()
        }
    }

    /// Whether the panel is up. Read by a host that wants to keep a row highlighted under it.
    var isPresenting: Bool { presented?.isShown == true }

    private var presented: ThemedPopover?
    private let glyph = GlyphView()

    // MARK: - Initialization

    init(topic: HelpTopic) {
        self.topic = topic
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
        applyTopic()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        glyph.setSymbol(HelpPopoverMetrics.symbol, slot: HelpPopoverMetrics.glyph, role: .control)
        addSubview(glyph)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: HelpPopoverMetrics.target),
            heightAnchor.constraint(equalToConstant: HelpPopoverMetrics.target),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func applyTopic() {
        setAccessibilityLabel(L10n.format("%@, help", topic.title))
        setAccessibilityHelp(topic.spokenSummary)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: HelpPopoverMetrics.target, height: HelpPopoverMetrics.target)
    }

    // MARK: - Optical Insets

    /// The mark is smaller than the target it is pressed on, so a container aligning by ink has
    /// to subtract the difference rather than the frame — rule 9 of the theme boundary.
    var opticalHorizontalInset: CGFloat {
        max(0, (HelpPopoverMetrics.target - HelpPopoverMetrics.glyph) / 2)
    }

    func opticalVerticalInset(forFrameHeight frameHeight: CGFloat) -> CGFloat {
        max(0, (frameHeight - HelpPopoverMetrics.glyph) / 2)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let lifted = isHovered || hasKeyboardFocus || isPresenting
        let radius = Design.Radius.control(fitting: bounds.size)
        let shape: ThemedSurface.Shape
        if lifted {
            shape = ThemedSurface.draw(
                bounds,
                fill: Design.Surface.controlHover,
                radius: radius
            )
        } else {
            shape = ThemedSurface.Shape(rect: bounds, radius: radius)
        }
        glyph.tint = lifted ? Design.Text.label : Design.Text.tertiary
        glyph.alphaValue = isEnabled ? 1 : Design.Opacity.disabledControl
        drawKeyboardFocus(around: shape)
    }

    override func hoverDidChange() {
        super.hoverDidChange()
        needsDisplay = true
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        _ = performPrimaryAction()
    }

    override func performPrimaryAction() -> Bool {
        if isPresenting {
            dismiss()
        } else {
            present()
        }
        return true
    }

    /// Opens the panel. Safe to call with no window: a button that is not on screen has nothing
    /// to anchor to, and silently doing nothing is what every other anchored surface here does.
    func present() {
        guard !topic.isEmpty, window != nil else { return }
        let popover = HostPopoverFactory.make(.designHelp)
        popover.behavior = .transient
        let content = makeContent()
        popover.contentViewController = content
        // The panel takes the keyboard, because the whole point of this component is that the
        // explanation is reachable without a pointer: opening it and leaving focus behind would
        // put the words one press away for a mouse and nowhere at all for a keyboard. Escape and
        // the focus return are `ThemedPopover`'s.
        popover.initialFirstResponder = content.view
        popover.onClose = { [weak self] in
            self?.presented = nil
            self?.needsDisplay = true
        }
        presented = popover
        popover.show(
            relativeTo: bounds,
            of: self,
            preferredEdge: .maxY
        )
        needsDisplay = true
    }

    func dismiss() {
        presented?.close()
        presented = nil
        needsDisplay = true
    }

    /// The panel's body, on its own so a render test can photograph the words rather than trust
    /// that a panel somewhere is carrying them.
    func makeContent() -> NSViewController {
        HelpPopoverContentViewController(topic: topic)
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
}

// MARK: - Content

/// The panel's body: the title, the paired lines, then the prose.
///
/// Private because a caller hands this component a `HelpTopic` and never a view — the layout of
/// an explanation is the component's, which is the whole reason it is one.
private final class HelpPopoverContentViewController: NSViewController {

    private let topic: HelpTopic

    init(topic: HelpTopic) {
        self.topic = topic
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = HelpPopoverContentView()

        var blocks: [NSView] = [HelpPopoverText.title(topic.title)]
        if !topic.lines.isEmpty {
            blocks.append(HelpPopoverText.lines(topic.lines))
        }
        blocks.append(contentsOf: topic.paragraphs.map { HelpPopoverText.paragraph($0) })

        let stack = NSStackView(views: blocks)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: HelpPopoverMetrics.contentWidth),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // One element with the whole answer in it, so a screen reader is not made to walk eight
        // labels to hear four facts. The individual labels stay readable underneath.
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(topic.title)
        view.setAccessibilityHelp(topic.spokenSummary)
        view.setAccessibilityIdentifier(HelpPopoverMetrics.contentIdentifier)
    }
}

/// The panel's root. It takes the keyboard so Escape has somewhere to arrive from and so the
/// focus return has something to return *from*.
private final class HelpPopoverContentView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Text

/// The three shapes an explanation is printed in, in one place so the panel and any test that
/// measures it are reading the same layout.
@MainActor
enum HelpPopoverText {

    static func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.applyFont(.emphasizedBody)
        label.textColor = Design.Text.label
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func paragraph(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(.subheading)
        label.textColor = Design.Text.secondary
        // A wrapping label reports no width it is willing to argue for, so it takes whatever the
        // column leaves it. Saying so explicitly is not decoration: see `lines(_:)`.
        label.setContentHuggingPriority(HelpPopoverMetrics.wrappingHugging, for: .horizontal)
        return label
    }

    /// The paired lines: the terms share one column, as wide as the longest of them, and every
    /// detail starts immediately to its right.
    ///
    /// **The column's width has to be settled by a priority, not by a tie.** The guide is pulled
    /// narrow by a constraint the terms outrank, so it lands on the longest term by construction.
    /// That pull used to sit at `.defaultLow` — which is exactly the horizontal content hugging
    /// AppKit gives a *wrapping* label, and a detail here is one. Two constraints at 250 wanting
    /// opposite things is not a layout, it is a coin toss, and the layout engine spent it
    /// differently depending on how many passes the view had been through: a page laid out once
    /// in a detached fixture put the details beside their terms, and the same page in a window
    /// put the terms on the leading edge with a narrow ragged detail column hard against the
    /// trailing one. It shipped that way, and the render tests photographed the other outcome.
    ///
    /// So both halves are stated: the pull sits above `.defaultLow`, and a detail says outright
    /// that it has no opinion about its own width. Either alone would fix today's arrangement;
    /// together they leave nothing for a future layout pass to decide.
    static func lines(_ lines: [HelpTopic.Line]) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let column = NSLayoutGuide()
        container.addLayoutGuide(column)

        var constraints: [NSLayoutConstraint] = [
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ]
        let narrow = column.widthAnchor.constraint(equalToConstant: 0)
        narrow.priority = HelpPopoverMetrics.columnPull
        constraints.append(narrow)

        var previous: NSView?
        for line in lines {
            let term = NSTextField(labelWithString: line.term)
            term.applyFont(.subheading)
            term.textColor = Design.Text.tertiary
            term.translatesAutoresizingMaskIntoConstraints = false
            term.setContentCompressionResistancePriority(.required, for: .horizontal)

            let detail = NSTextField(wrappingLabelWithString: line.detail)
            detail.applyFont(.subheading)
            detail.textColor = Design.Text.secondary
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.setContentHuggingPriority(
                HelpPopoverMetrics.wrappingHugging,
                for: .horizontal
            )

            container.addSubview(term)
            container.addSubview(detail)
            constraints += [
                term.leadingAnchor.constraint(equalTo: column.leadingAnchor),
                term.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
                detail.leadingAnchor.constraint(
                    equalTo: column.trailingAnchor,
                    constant: Design.Spacing.medium
                ),
                detail.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                term.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor),
                detail.topAnchor.constraint(
                    equalTo: previous?.bottomAnchor ?? container.topAnchor,
                    constant: previous == nil ? 0 : Design.Spacing.small
                )
            ]
            previous = detail
        }
        if let previous {
            constraints.append(previous.bottomAnchor.constraint(equalTo: container.bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }
}

// MARK: - Metrics

enum HelpPopoverMetrics {

    /// The mark. `questionmark.circle` rather than a bare `?` so it reads as a control at a
    /// glance and never as punctuation left over from the sentence beside it.
    static let symbol = "questionmark.circle"

    /// The press target and the mark inside it. Both stated, because their difference is the
    /// optical inset a container has to subtract.
    static let target: CGFloat = Design.Size.inlineButtonTarget
    static let glyph: CGFloat = Design.Size.inlineButtonGlyph

    /// A reading measure for an explanation: wide enough that "Who can see the traffic" and its
    /// answer stand side by side, narrow enough to stay a panel rather than a second page.
    static let contentWidth: CGFloat = 340

    /// What a wrapping label in here says about its own width: nothing. See
    /// `HelpPopoverText.lines(_:)`.
    static let wrappingHugging = NSLayoutConstraint.Priority(1)

    /// The pull that settles the term column, above the 250 a wrapping label hugs at.
    static let columnPull = NSLayoutConstraint.Priority(260)

    /// The panel body, for a test that has to find it.
    static let contentIdentifier = "help-popover.content"
}
