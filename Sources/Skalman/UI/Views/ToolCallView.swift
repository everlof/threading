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

    private let toolName: String
    private let diffLines: [DiffLine]?

    private var glyphLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var metaLabel: NSTextField!
    private var chevron: NSImageView!

    /// Whichever body this row expands to show — a diff for an edit, plain text otherwise.
    private var bodyView: NSView!
    private var textBody: NSTextField?

    private var isExpanded = false
    private var canExpand = false

    // MARK: - Initialization

    init(toolName: String, summary: String, diff: [DiffLine]? = nil) {
        self.toolName = toolName
        self.diffLines = diff
        super.init(frame: .zero)
        setupViews(summary: summary)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews(summary: String) {
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Surface.controlResting, radius: Design.Radius.control)

        let glyph = ToolGlyph.forTool(toolName)

        glyphLabel = makeLabel(glyph.symbol, font: monospace(weight: .medium))
        glyphLabel.textColor = .secondaryLabelColor
        glyphLabel.alignment = .center

        titleLabel = makeLabel(glyph.label, font: Design.Typography.caption())
        titleLabel.textColor = .secondaryLabelColor

        detailLabel = makeLabel(summary, font: monospace(weight: .regular))
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Reads while a call is still running, so the row is not blank until the result lands.
        metaLabel = makeLabel("running…", font: Design.Typography.caption())
        metaLabel.textColor = .tertiaryLabelColor

        chevron = NSImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .quaternaryLabelColor
        chevron.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.chevron, weight: .semibold)
        chevron.isHidden = true

        bodyView = makeBody()
        bodyView.isHidden = true

        [glyphLabel, titleLabel, detailLabel, metaLabel, chevron, bodyView].forEach(addSubview)
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
    private func makeBody() -> NSView {
        if let diffLines {
            return DiffView(lines: diffLines)
        }

        let field = makeLabel("", font: monospace(weight: .regular))
        field.textColor = .secondaryLabelColor
        field.isSelectable = true
        textBody = field
        return field
    }

    private func makeLabel(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = text.isEmpty ? 0 : 1
        return label
    }

    private func monospace(weight: NSFont.Weight) -> NSFont {
        .monospacedSystemFont(ofSize: ToolCallDefaults.fontSize, weight: weight)
    }

    private var headerBottom: NSLayoutConstraint!
    private var bodyBottom: NSLayoutConstraint!

    private func setupConstraints() {
        let inset = Design.Spacing.small
        headerBottom = titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        headerBottom.isActive = true
        bodyBottom = bodyView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)

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
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            bodyView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: inset),
            bodyView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        ])

        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Public Methods

    /// Attaches the result once the tool has run.
    func setResult(_ text: String, isError: Bool) {
        let label = ToolGlyph.forTool(toolName).label
        let tint: NSColor = isError ? .systemRed : .secondaryLabelColor
        glyphLabel.textColor = tint
        titleLabel.textColor = tint
        titleLabel.stringValue = isError ? "\(label) · failed" : label

        // An edit already shows its diff and its `+/−` line; the result only settles whether
        // the change landed. A plain tool instead reveals its output here.
        if diffLines != nil {
            if isError { metaLabel.stringValue = "failed" }
            return
        }

        textBody?.stringValue = text
        textBody?.textColor = isError ? .systemRed : .secondaryLabelColor

        let hasText = !text.isEmpty
        metaLabel.stringValue = hasText ? sizeSummary(text) : (isError ? "failed" : "done")
        if hasText { enableExpansion() }
    }

    // MARK: - Private Methods

    private func sizeSummary(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines == 1 ? "1 line" : "\(lines) lines"
    }

    private func enableExpansion() {
        canExpand = true
        chevron.isHidden = false
    }

    @objc private func toggle() {
        guard canExpand else { return }

        isExpanded.toggle()
        bodyView.isHidden = !isExpanded
        headerBottom.isActive = !isExpanded
        bodyBottom.isActive = isExpanded

        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
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

    /// Glyphs drawn from the vocabulary a terminal user already knows, so nothing has to be
    /// learned to read a row.
    private static let known: [String: Style] = [
        "Bash": Style(symbol: "$", label: "Bash"),
        "Read": Style(symbol: "→", label: "Read"),
        "Write": Style(symbol: "←", label: "Write"),
        "Edit": Style(symbol: "±", label: "Edit"),
        "MultiEdit": Style(symbol: "±", label: "Edit"),
        "Glob": Style(symbol: "✱", label: "Glob"),
        "Grep": Style(symbol: "✱", label: "Grep"),
        "WebFetch": Style(symbol: "%", label: "Fetch"),
        "WebSearch": Style(symbol: "◈", label: "Search"),
        "Task": Style(symbol: "⌘", label: "Task"),
        "TodoWrite": Style(symbol: "✓", label: "Todo")
    ]

    static func forTool(_ name: String) -> Style {
        if let known = known[name] { return known }
        if name.hasPrefix("mcp__") {
            return Style(symbol: "◇", label: name.components(separatedBy: "__").last ?? name)
        }
        return Style(symbol: "•", label: name)
    }
}

// MARK: - Tool Call Defaults

enum ToolCallDefaults {
    static let fontSize: CGFloat = 11
}
