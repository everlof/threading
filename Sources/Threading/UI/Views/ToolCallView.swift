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
final class ToolCallView: NSView, ThemedComponent {

    // MARK: - Properties

    private let diffLines: [DiffLine]?
    private let summary: String
    private let style: ToolGlyph.Style
    private var displayedGlyph: String
    private var displayedTitle: String
    private var displayedMeta: String
    private var hasFailed = false
    private var themeRedraw: ThemeRedraw?
    private var headerMetricsCache: HeaderMetrics?

    private struct HeaderMetrics {
        let glyphFont: NSFont
        let titleFont: NSFont
        let detailFont: NSFont
        let metaFont: NSFont
        let height: CGFloat
    }

    /// Whichever body this row expands to show — a diff for an edit, plain text otherwise.
    /// A cold table jump can materialize a viewport of collapsed tools at once; building hidden
    /// diffs there made navigation pay for content the user had not asked to see.
    private var bodyView: NSView?
    private var textBody: NSTextField?
    private var resultText: String?
    private var resultOutcome: ToolOutcome?
    private weak var contextDiff: DiffView?

    var onAddContextAttachment: ((ConversationContextAttachment) -> Void)? {
        didSet { contextDiff?.onAddContextAttachment = onAddContextAttachment }
    }
    var onRequestContextComment: ((ConversationContextAttachment, CodeContextPreview?) -> Void)? {
        didSet { contextDiff?.onRequestComment = onRequestContextComment }
    }

    private var isExpanded = false
    private var canExpand = false
    private var isHovered = false

    private static var runningText: String { L10n.string("running") + "…" }

    /// Recyclable conversation rows persist this state in their controller and invalidate the
    /// table's cached height. Standalone renderers can leave it nil.
    var onExpansionChanged: ((Bool) -> Void)?

    // MARK: - Initialization

    init(tool: ToolIdentity, summary: String, diff: [DiffLine]? = nil) {
        self.diffLines = diff
        self.summary = summary
        let style = ToolGlyph.forTool(tool)
        self.style = style
        self.displayedGlyph = style.symbol
        self.displayedTitle = style.label
        self.displayedMeta = Self.runningText
        super.init(frame: .zero)
        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(true)
        setupViews(summary: summary)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews(summary: String) {
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Chat.toolRowResting, radius: .control)

        // A diff is known from the call's arguments, so an edit is expandable at once — its
        // result only confirms the change went through.
        if let diffLines {
            let (added, removed) = EditDiff.counts(diffLines)
            displayedMeta = "+\(added) −\(removed)"
            enableExpansion()
        }

        let click = NSClickGestureRecognizer(target: self, action: #selector(toggle))
        click.delegate = self
        addGestureRecognizer(click)
    }

    /// The body is decided by the tool: a diff for an edit, a scrollable text field otherwise.
    private func makeBody(summary: String) -> NSView {
        if let diffLines {
            // For an editing tool the one-line subject *is* the path, which is what says which
            // language the diff is in. Anything else fails the extension lookup and renders
            // plain, so a subject that is not a path costs nothing.
            let diff = DiffView(lines: diffLines, path: summary)
            diff.onAddContextAttachment = onAddContextAttachment
            diff.onRequestComment = onRequestContextComment
            contextDiff = diff
            return diff
        }

        let field = NSTextField(labelWithString: "")
        field.applyFont(.code(), in: .conversation)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.maximumNumberOfLines = 0
        field.stringValue = resultText ?? ""
        field.textColor = resultOutcome == .failed
            ? Design.Status.negative
            : Design.Text.secondary
        field.isSelectable = true
        textBody = field
        return field
    }

    private var bodyTop: NSLayoutConstraint?
    private var bodyBottom: NSLayoutConstraint?

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
            displayedMeta = L10n.string("stopped")
            needsDisplay = true
            return
        }

        let failed = outcome == .failed
        hasFailed = failed
        displayedGlyph = failed ? ToolGlyph.failureSymbol : style.symbol
        displayedTitle = failed
            ? L10n.format("%@ · failed", style.label)
            : style.label

        // An edit already shows its diff and its `+/−` line; the result only settles whether
        // the change landed. A plain tool instead reveals its output here.
        if diffLines != nil {
            if failed { displayedMeta = L10n.string("failed") }
            needsDisplay = true
            return
        }

        resultText = text
        resultOutcome = outcome
        if let textBody {
            textBody.stringValue = text
            textBody.textColor = failed ? Design.Status.negative : Design.Text.secondary
        }

        let hasText = !text.isEmpty
        displayedMeta = hasText
            ? sizeSummary(text)
            : (failed ? L10n.string("failed") : L10n.string("done"))
        if hasText { enableExpansion() }
        needsDisplay = true
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
        needsDisplay = true
    }

    func setExpanded(_ expanded: Bool, notifying: Bool = true) {
        guard canExpand, expanded != isExpanded else { return }
        if expanded { installBodyIfNeeded() }
        guard let bodyView, let bodyBottom else { return }

        isExpanded = expanded
        bodyView.isHidden = !isExpanded
        bodyBottom.isActive = isExpanded
        updateSurface()
        invalidateIntrinsicContentSize()
        needsDisplay = true
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
        let top = body.topAnchor.constraint(
            equalTo: topAnchor,
            constant: headerHeight
        )
        bodyView = body
        bodyTop = top
        bodyBottom = bottom
        NSLayoutConstraint.activate([
            top,
            body.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: inset + Design.Chat.toolIconWidth + inset
            ),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        ])
    }

    @objc private func toggle() {
        setExpanded(!isExpanded)
    }

    // MARK: - Header Drawing

    /// A viewport of cold tool calls is the common case, so the collapsed header is drawn as
    /// one semantic element rather than solving five AppKit views and their constraint graph
    /// for every visible row. Expanded output remains ordinary selectable AppKit content.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: headerHeight)
    }

    override var isFlipped: Bool { true }

    private var headerMetrics: HeaderMetrics {
        if let headerMetricsCache { return headerMetricsCache }
        let glyph = Design.Typography.code(weight: .medium)
        let title = Design.Typography.caption(surface: .conversation)
        let detail = Design.Typography.code()
        let meta = Design.Typography.caption(surface: .conversation)
        let lineHeight = [glyph, title, detail, meta]
            .map(Design.Typography.lineHeight(of:))
            .max() ?? 0
        let metrics = HeaderMetrics(
            glyphFont: glyph,
            titleFont: title,
            detailFont: detail,
            metaFont: meta,
            height: lineHeight + Design.Spacing.small * 2
        )
        headerMetricsCache = metrics
        return metrics
    }

    private var headerHeight: CGFloat { headerMetrics.height }

    override func invalidateIntrinsicContentSize() {
        headerMetricsCache = nil
        super.invalidateIntrinsicContentSize()
    }

    override func layout() {
        let resolvedHeaderHeight = headerHeight
        if let bodyTop, abs(bodyTop.constant - resolvedHeaderHeight) > 0.5 {
            bodyTop.constant = resolvedHeaderHeight
        }
        super.layout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let inset = Design.Spacing.small
        let header = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        guard header.intersects(dirtyRect), header.width > inset * 2 else { return }

        let identityColor = hasFailed ? Design.Status.negative : Design.Text.secondary
        let metrics = headerMetrics
        let glyphFont = metrics.glyphFont
        let titleFont = metrics.titleFont
        let detailFont = metrics.detailFont
        let metaFont = metrics.metaFont

        let glyphRect = verticallyCenteredRect(
            x: inset,
            width: Design.Chat.toolIconWidth,
            font: glyphFont,
            in: header
        )
        drawText(
            displayedGlyph,
            in: glyphRect,
            font: glyphFont,
            color: identityColor,
            alignment: .center
        )

        let titleX = glyphRect.maxX + inset
        let titleWidth = ceil((displayedTitle as NSString).size(withAttributes: [
            .font: titleFont
        ]).width)
        let titleRect = verticallyCenteredRect(
            x: titleX,
            width: titleWidth,
            font: titleFont,
            in: header
        )
        drawText(
            displayedTitle,
            in: titleRect,
            font: titleFont,
            color: identityColor
        )

        let chevronWidth: CGFloat = canExpand ? Design.Symbol.chevron : 0
        if canExpand {
            drawChevron(in: NSRect(
                x: header.maxX - inset - chevronWidth,
                y: floor(header.midY - chevronWidth / 2),
                width: chevronWidth,
                height: chevronWidth
            ))
        }

        let metaWidth = ceil((displayedMeta as NSString).size(withAttributes: [
            .font: metaFont
        ]).width)
        let metaX = header.maxX - inset - chevronWidth
            - (canExpand ? inset : 0) - metaWidth
        let metaRect = verticallyCenteredRect(
            x: metaX,
            width: metaWidth,
            font: metaFont,
            in: header
        )
        drawText(
            displayedMeta,
            in: metaRect,
            font: metaFont,
            color: Design.Text.tertiary,
            alignment: .right
        )

        let detailX = titleRect.maxX + inset
        let detailWidth = max(0, metaRect.minX - inset - detailX)
        guard detailWidth > 0 else { return }
        let detailRect = verticallyCenteredRect(
            x: detailX,
            width: detailWidth,
            font: detailFont,
            in: header
        )
        drawText(
            summary,
            in: detailRect,
            font: detailFont,
            color: Design.Text.tertiary,
            lineBreak: .byTruncatingMiddle
        )
    }

    private func verticallyCenteredRect(
        x: CGFloat,
        width: CGFloat,
        font: NSFont,
        in container: NSRect
    ) -> NSRect {
        let height = Design.Typography.lineHeight(of: font)
        return NSRect(
            x: x,
            y: floor(container.midY - height / 2),
            width: width,
            height: height
        )
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        lineBreak: NSLineBreakMode = .byClipping
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreak
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }

    private func drawChevron(in rect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = max(1, Design.Radius.border)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if isExpanded {
            path.move(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.3))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY - rect.height * 0.3))
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.3))
        } else {
            path.move(to: NSPoint(x: rect.minX + rect.width * 0.3, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX - rect.width * 0.3, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY))
        }
        Design.Text.quaternary.setStroke()
        path.stroke()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        canExpand ? .button : .group
    }

    override func accessibilityLabel() -> String? {
        "\(displayedTitle), \(summary)"
    }

    override func accessibilityValue() -> Any? {
        displayedMeta
    }

    override func isAccessibilityExpanded() -> Bool { isExpanded }

    override func accessibilityPerformPress() -> Bool {
        guard canExpand else { return false }
        toggle()
        return true
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

// MARK: - Gesture Delegate

extension ToolCallView: NSGestureRecognizerDelegate {

    /// A click inside the opened body belongs to the body — it is selectable output or a diff
    /// with its own line actions, and a click that placed a caret also folded the row shut.
    /// Only the header line is the toggle; `GitReviewFileRow` holds the same rule.
    func gestureRecognizer(
        _ recognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard let bodyView, !bodyView.isHidden else { return true }
        return !bodyView.frame.contains(convert(event.locationInWindow, from: nil))
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
