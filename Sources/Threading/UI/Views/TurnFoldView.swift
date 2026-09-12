import AppKit

/// The one-line fold a settled turn collapses behind — "Worked for 42s".
///
/// t3code's turn fold, drawn in this app's quiet-row language: once a turn has settled,
/// everything between its user message and its final assistant reply is hidden behind this
/// line, so a conversation reads as its exchanges rather than as the work that carried them
/// out. A presentation owner can handle disclosure through the callback (the virtualized
/// conversation does); simpler standalone callers may still toggle an existing group of views.
final class TurnFoldView: NSView {

    // MARK: - Properties

    private let label: String
    private let foldedViews: [NSView]
    private let onExpansionChanged: ((TurnFoldView, Bool) -> Void)?

    private lazy var disclosure: ThemedDisclosureRow = {
        let title = NSTextField(labelWithString: label)
        title.applyFont(.caption, in: .conversation)
        title.textColor = Design.Text.tertiary
        let control = ThemedDisclosureRow(content: title, isExpanded: isExpanded, density: .conversation)
        control.setAccessibilityLabel(label)
        control.setAccessibilityIdentifier("conversation.work-disclosure")
        control.onToggle = { [weak self] expanded in self?.setExpanded(expanded) }
        return control
    }()
    private var isExpanded = false

    // MARK: - Initialization

    /// `duration` is the turn's measured length, when its terminal event carried one.
    /// `outcome` decides the verb — t3code's rule, so an abandoned turn does not claim to have
    /// worked, and a broken one does not claim the user abandoned it.
    init(
        duration: TimeInterval?,
        outcome: TurnOutcome,
        folding views: [NSView],
        expanded: Bool = false,
        onExpansionChanged: ((TurnFoldView, Bool) -> Void)? = nil
    ) {
        self.foldedViews = views
        self.onExpansionChanged = onExpansionChanged
        self.label = Self.title(duration: duration, outcome: outcome)
        self.isExpanded = expanded
        super.init(frame: .zero)
        setupViews()
    }

    /// A semantic disclosure for another already-ordered run, such as adjacent tool calls in a
    /// child transcript. The caller owns the label because this fold does not describe a turn.
    init(
        label: String,
        folding views: [NSView],
        expanded: Bool = false,
        onExpansionChanged: ((TurnFoldView, Bool) -> Void)? = nil
    ) {
        self.foldedViews = views
        self.onExpansionChanged = onExpansionChanged
        self.label = label
        self.isExpanded = expanded
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosure)
        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor),
            disclosure.trailingAnchor.constraint(equalTo: trailingAnchor),
            disclosure.topAnchor.constraint(equalTo: topAnchor),
            disclosure.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Private Methods

    /// Three readings, not two. A turn the user stopped and a turn that broke both end early,
    /// and while the fold carried one `stopped` flag they were drawn identically — a network
    /// fault said "Stopped after 42s", which reads as something the user did.
    ///
    /// "for" against "after" is the whole distinction between a turn that spent its time and one
    /// whose time simply elapsed before it was cut short.
    private static func title(duration: TimeInterval?, outcome: TurnOutcome) -> String {
        let verb = switch outcome {
        case .completed: "Worked"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
        guard let duration else { return verb }
        return outcome == .completed
            ? "\(verb) for \(TurnStatusText.duration(duration))"
            : "\(verb) after \(TurnStatusText.duration(duration))"
    }

    /// Disclosure state stays with the transcript identity across recycled row hosts.
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        disclosure.isExpanded = expanded
        if let onExpansionChanged {
            onExpansionChanged(self, expanded)
        } else {
            foldedViews.forEach { $0.isHidden = !expanded }
        }
    }
}
