import AppKit

/// One tool call and its result, as a single collapsible row on a quiet surface.
///
/// Collapsed by default, and the call and its result are one view rather than two: a directory
/// listing or a file read is usually far longer than everything said around it, and left open
/// it buries the conversation it was part of. What stays visible is the glyph, the tool, and
/// the one line that says what it did; the output is there when it is wanted.
///
/// An edit is the exception worth opening for: its body is a rendered diff, and its size line
/// reads `+7 −3` rather than a line count, because for an edit the change *is* the point.
final class ToolCallView: NSView {

    // MARK: - Properties

    private let tool: ToolIdentity
    private let diffLines: [DiffLine]?
    private let summary: String

    private lazy var glyphLabel = makeLabel(
        ToolGlyph.forTool(tool).symbol,
        role: .code(weight: .medium)
    )
    private lazy var titleLabel = makeLabel(ToolGlyph.forTool(tool).label, role: .caption)
    private lazy var detailLabel = makeLabel(summary, role: .code())
    private lazy var metaLabel = makeLabel(Self.runningText, role: .caption)
    private lazy var chevron: NSImageView = {
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: nil
        )
        image.contentTintColor = Design.Text.quaternary
        image.symbolConfiguration = Design.Symbol.configuration(
            Design.Symbol.chevron,
            weight: .semibold
        )
        image.isHidden = true
        return image
    }()

    /// Whichever body this row expands to show — a diff for an edit, plain text otherwise.
    /// A cold table jump can materialize a viewport of collapsed tools at once; building hidden
    /// diffs there made navigation pay for content the user had not asked to see.
    private var bodyView: NSView?
    private var textBody: NSTextField?
    private var resultText: String?
    private var resultOutcome: ToolOutcome?

    private var isExpanded = false
    private var canExpand = false
    private var isHovered = false

    private static var runningText: String { L10n.string("running") + "…" }

    /// Recyclable conversation rows persist this state in their controller and invalidate the
    /// table's cached height. Standalone renderers can leave it nil.
    var onExpansionChanged: ((Bool) -> Void)?

    // MARK: - Initialization

    init(tool: ToolIdentity, summary: String, diff: [DiffLine]? = nil) {
        self.tool = tool
        self.diffLines = diff
        self.summary = summary
        super.init(frame: .zero)
        setupViews(summary: summary)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews(summary: String) {
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Chat.toolRowResting, radius: .control)

        glyphLabel.textColor = Design.Text.secondary
        glyphLabel.alignment = .center

        titleLabel.textColor = Design.Text.secondary

        detailLabel.textColor = Design.Text.tertiary
        detailLabel.lineBreakMode = .byTruncatingMiddle
        // The subject arrives already flattened, but a label that *can* grow on a newline is a
        // row whose height depends on its content — belt and braces, since the whole treatment
        // rests on every collapsed row being the same height.
        detailLabel.usesSingleLineMode = true
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Reads while a call is still running, so the row is not blank until the result lands.
        metaLabel.textColor = Design.Text.tertiary
        [glyphLabel, titleLabel, detailLabel, metaLabel, chevron].forEach(addSubview)
        setupConstraints()

        // A diff is known from the call's arguments, so an edit is expandable at once — its
        // result only confirms the change went through.
        if let diffLines {
            let (added, removed) = EditDiff.counts(diffLines)
            metaLabel.stringValue = "+\(added) −\(removed)"
            enableExpansion()
        }

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggle)))
    }

    /// The body is decided by the tool: a diff for an edit, a scrollable text field otherwise.
    private func makeBody(summary: String) -> NSView {
        if let diffLines {
            // For an editing tool the one-line subject *is* the path, which is what says which
            // language the diff is in. Anything else fails the extension lookup and renders
            // plain, so a subject that is not a path costs nothing.
            return DiffView(lines: diffLines, path: summary)
        }

        let field = makeLabel("", role: .code())
        field.stringValue = resultText ?? ""
        field.textColor = resultOutcome == .failed
            ? Design.Status.negative
            : Design.Text.secondary
        field.isSelectable = true
        textBody = field
        return field
    }

    /// Every label in a tool row, carrying its **role** rather than a resolved font.
    ///
    /// A tool row is transcript, so its prose is set in the conversation's own font; the glyph
    /// and the command stay code, which neither a surface nor a theme moves. Taking an `NSFont`
    /// here was the bug: the sweep re-resolves a *recorded role*, and a font argument has none,
    /// so these four labels sat out every live theme switch.
    private func makeLabel(
        _ text: String,
        role: Design.FontRole,
        surface: Design.Typography.FontSurface = .conversation
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.applyFont(role, in: surface)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = text.isEmpty ? 0 : 1
        return label
    }

    private lazy var headerBottom = titleLabel.bottomAnchor.constraint(
        equalTo: bottomAnchor,
        constant: -Design.Spacing.small
    )
    private var bodyBottom: NSLayoutConstraint?

    private func setupConstraints() {
        let inset = Design.Spacing.small
        headerBottom.isActive = true

        NSLayoutConstraint.activate([
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyphLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            glyphLabel.widthAnchor.constraint(equalToConstant: Design.Chat.toolIconWidth),

            titleLabel.leadingAnchor.constraint(equalTo: glyphLabel.trailingAnchor, constant: inset),
            titleLabel.firstBaselineAnchor.constraint(equalTo: glyphLabel.firstBaselineAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: Design.Spacing.small),
            detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            metaLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: detailLabel.trailingAnchor,
                constant: Design.Spacing.small
            ),
            metaLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            chevron.leadingAnchor.constraint(equalTo: metaLabel.trailingAnchor, constant: Design.Spacing.small),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])

        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Public Methods

    /// Attaches the result once the tool has run — or marks the row stopped when the turn
    /// ended around a call that never reported back.
    ///
    /// Failure overrides the identity glyph with a destructive `✗`: the title still names the
    /// tool, and a row that went wrong is the one place per-row ink is relevant rather than
    /// noise. Success stays quiet — twenty check marks down a working turn would be exactly
    /// the slab-ink the resting-fill rule was written against.
    func setResult(_ text: String, outcome: ToolOutcome) {
        if outcome == .interrupted {
            metaLabel.stringValue = L10n.string("stopped")
            return
        }

        let failed = outcome == .failed
        let style = ToolGlyph.forTool(tool)
        let tint: NSColor = failed ? Design.Status.negative : Design.Text.secondary
        glyphLabel.stringValue = failed ? ToolGlyph.failureSymbol : style.symbol
        glyphLabel.textColor = tint
        titleLabel.textColor = tint
        titleLabel.stringValue = failed
            ? L10n.format("%@ · failed", style.label)
            : style.label

        // An edit already shows its diff and its `+/−` line; the result only settles whether
        // the change landed. A plain tool instead reveals its output here.
        if diffLines != nil {
            if failed { metaLabel.stringValue = L10n.string("failed") }
            return
        }

        resultText = text
        resultOutcome = outcome
        if let textBody {
            textBody.stringValue = text
            textBody.textColor = failed ? Design.Status.negative : Design.Text.secondary
        }

        let hasText = !text.isEmpty
        metaLabel.stringValue = hasText
            ? sizeSummary(text)
            : (failed ? L10n.string("failed") : L10n.string("done"))
        if hasText { enableExpansion() }
    }

    // MARK: - Private Methods

    private func sizeSummary(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines == 1
            ? L10n.string("1 line")
            : L10n.format("%lld lines", Int64(lines))
    }

    private func enableExpansion() {
        canExpand = true
        chevron.isHidden = false
    }

    func setExpanded(_ expanded: Bool, notifying: Bool = true) {
        guard canExpand, expanded != isExpanded else { return }
        if expanded { installBodyIfNeeded() }
        guard let bodyView, let bodyBottom else { return }

        isExpanded = expanded
        bodyView.isHidden = !isExpanded
        headerBottom.isActive = !isExpanded
        bodyBottom.isActive = isExpanded

        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        updateSurface()
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        if notifying { onExpansionChanged?(isExpanded) }
    }

    /// Installs expansion content only on the first open. The body remains with this materialized
    /// row for cheap close/reopen, then leaves with the row when the table recycles its host.
    private func installBodyIfNeeded() {
        guard bodyView == nil else { return }

        let body = makeBody(summary: summary)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.isHidden = true
        addSubview(body)

        let inset = Design.Spacing.small
        let bottom = body.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -inset
        )
        bodyView = body
        bodyBottom = bottom
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: inset),
            body.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        ])
    }

    @objc private func toggle() {
        setExpanded(!isExpanded)
    }

    // MARK: - Hover

    /// The row has no fill at rest, so hover is the only thing that says it can be clicked.
    /// Without it a collapsed row reads as text rather than as a control.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))

        // A transcript re-lays out constantly under a still pointer — a row that moved away
        // never heard it was left. See `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) {
            isHovered = false
            updateSurface()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateSurface()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateSurface()
    }

    private func updateSurface() {
        // An open row keeps its fill: it is holding content, which needs a surface to sit on
        // whether or not the pointer is still over it.
        let isActive = isHovered || isExpanded
        applyLayerBackground(isActive ? Design.Chat.toolRowActive : Design.Chat.toolRowResting)
    }
}

// MARK: - Tool Glyph

/// The symbol and label a tool row shows, so a call reads at a glance rather than by parsing
/// its name. Glyphs are drawn from the same vocabulary a terminal user already knows — `$` for
/// a shell, `→`/`←` for reading and writing — rather than invented.
enum ToolGlyph {

    struct Style {
        let symbol: String
        let label: String
    }

    /// Overrides the identity glyph when a call fails — t3code's destructive-✗ cascade. `✓`
    /// is not its counterpart here: it already means Todo in this column, and success stays
    /// quiet anyway.
    static let failureSymbol = "✗"

    static func forTool(_ name: String) -> Style {
        forTool(ToolIdentity(name))
    }

    /// Exhaustive on semantic identity so a newly understood tool cannot silently inherit the
    /// generic presentation. Only truly provider-defined names take the fallback row.
    static func forTool(_ tool: ToolIdentity) -> Style {
        switch tool {
        case .bash:
            return Style(symbol: "$", label: "Bash")
        case .read:
            return Style(symbol: "→", label: "Read")
        case .write:
            return Style(symbol: "←", label: "Write")
        case .edit, .multiEdit:
            return Style(symbol: "±", label: "Edit")
        case .glob:
            return Style(symbol: "✱", label: "Glob")
        case .grep:
            return Style(symbol: "✱", label: "Grep")
        case .webFetch:
            return Style(symbol: "%", label: "Fetch")
        case .webSearch:
            return Style(symbol: "◈", label: "Search")
        case .task:
            return Style(symbol: "⌘", label: "Task")
        case .todoWrite, .taskCreate, .taskUpdate:
            return Style(symbol: "✓", label: "Todo")
        case .taskList, .taskGet:
            return Style(symbol: "•", label: tool.rawName)
        case .mcp(let name):
            return Style(symbol: "◇", label: name.components(separatedBy: "__").last ?? name)
        case .notebookEdit, .notebookRead, .todoRead, .toolSearch, .plan:
            return Style(symbol: "•", label: tool.rawName)
        case .unknown(let name):
            return Style(symbol: "•", label: name)
        }
    }
}

// MARK: - Tool Call Defaults

enum ToolCallDefaults {
    static let fontSize: CGFloat = 11
}
