import AppKit

// MARK: - Code Context Preview

/// A bounded, presentation-only slice of code around one or more target lines.
///
/// The source renderer supplies lines by index so a large diff is never copied just to open a
/// comment sheet. A normal target keeps two neighbours on either side. A target too large for
/// the sheet keeps its beginning and end with an explicit omission row, which makes the preview
/// O(visible) even when somebody selected a whole generated file.
struct CodeContextPreview: Equatable, Sendable {

    enum Change: Equatable, Sendable {
        case context
        case added
        case removed
    }

    struct SourceLine: Equatable, Sendable {
        let number: Int?
        let change: Change
        let text: String

        init(number: Int?, change: Change, text: String) {
            self.number = number
            self.change = change
            self.text = Self.bounded(text)
        }

        private static func bounded(_ text: String) -> String {
            guard text.count > CodeContextPreview.maximumLineCharacters else { return text }
            return String(text.prefix(CodeContextPreview.maximumLineCharacters - 1)) + "…"
        }
    }

    enum Row: Equatable, Sendable {
        case line(SourceLine, isTarget: Bool)
        case omission(Int)
    }

    let rows: [Row]

    /// Builds only the rows the preview can draw. `lineAt` is called at most ten times.
    static func make(
        totalLineCount: Int,
        target: ClosedRange<Int>,
        lineAt: (Int) -> SourceLine
    ) -> CodeContextPreview? {
        guard totalLineCount > 0,
              target.lowerBound >= 0,
              target.upperBound < totalLineCount else { return nil }

        let lower = max(0, target.lowerBound - contextRadius)
        let upper = min(totalLineCount - 1, target.upperBound + contextRadius)
        let candidateCount = upper - lower + 1

        let indices: [Int?]
        if candidateCount <= maximumVisibleLineRows {
            indices = Array(lower...upper).map(Optional.some)
        } else if target.count <= maximumVisibleLineRows {
            // The selection is what the sheet is about; only the neighbours are optional. Cutting
            // from the middle of the candidate range hid the selected lines themselves ("1 more
            // lines are not shown" inside a four-line comment), so context is shed first, from
            // whichever side has more of it.
            let spare = maximumVisibleLineRows - target.count
            let leading = min(target.lowerBound - lower, (spare + 1) / 2)
            let trailing = min(upper - target.upperBound, spare - leading)
            indices = Array((target.lowerBound - leading)...(target.upperBound + trailing))
                .map(Optional.some)
        } else {
            let leadingCount = maximumVisibleLineRows / 2
            let trailingCount = maximumVisibleLineRows - leadingCount
            let trailingStart = upper - trailingCount + 1
            indices = Array(lower..<(lower + leadingCount)).map(Optional.some)
                + [nil]
                + Array(trailingStart...upper).map(Optional.some)
        }

        var rows: [Row] = []
        rows.reserveCapacity(indices.count)
        for (position, index) in indices.enumerated() {
            if let index {
                rows.append(.line(lineAt(index), isTarget: target.contains(index)))
                continue
            }
            guard position > 0,
                  position + 1 < indices.count,
                  let before = indices[position - 1],
                  let after = indices[position + 1] else { continue }
            rows.append(.omission(max(after - before - 1, 0)))
        }
        return CodeContextPreview(rows: rows)
    }

    private static let contextRadius = 2
    private static let maximumVisibleLineRows = 10
    private static let maximumLineCharacters = 500
}

// MARK: - View

/// A small diff-shaped code surface for comment sheets.
///
/// Target rows take the theme's stated selection surface and carry a leading `›`, so the answer
/// never depends on colour alone. Non-target additions and removals retain the ordinary diff
/// washes and signs around them. The view is intentionally non-interactive: focus belongs in the
/// comment field immediately below it.
@MainActor
final class CodeContextPreviewView: NSView, ThemedComponent {
    private let preview: CodeContextPreview
    private let rowViews: [CodeContextPreviewRowView]
    private let appEvents = AppEventObservations()

    init(preview: CodeContextPreview) {
        self.preview = preview
        rowViews = preview.rows.map(CodeContextPreviewRowView.init)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rowViews.forEach { addSubview($0) }
        setAccessibilityRole(.list)
        applyTheme()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: CGFloat(rowViews.count) * Self.rowHeight + Design.Spacing.tight * 2
        )
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset = Design.Spacing.tight
        for (index, row) in rowViews.enumerated() {
            row.frame = NSRect(
                x: inset,
                y: inset + CGFloat(index) * Self.rowHeight,
                width: max(bounds.width - inset * 2, 0),
                height: Self.rowHeight
            )
        }
    }

    private func applyTheme() {
        applySurface(
            fill: Design.Surface.field,
            radius: .control,
            border: Design.Surface.border
        )
        layer?.masksToBounds = true
        rowViews.forEach { $0.applyTheme() }
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private static var rowHeight: CGFloat {
        Design.Typography.lineHeight(of: Design.Typography.code()) + Design.Spacing.tight
    }
}

// MARK: - Row

@MainActor
private final class CodeContextPreviewRowView: NSView, ThemedComponent {
    private let row: CodeContextPreview.Row
    private let targetLabel = NSTextField(labelWithString: "")
    private let numberLabel = NSTextField(labelWithString: "")
    private let changeLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")

    init(row: CodeContextPreview.Row) {
        self.row = row
        super.init(frame: .zero)
        [targetLabel, numberLabel, changeLabel, codeLabel].forEach {
            $0.applyFont(.code())
            $0.lineBreakMode = .byTruncatingTail
            addSubview($0)
        }
        configureCopy()
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let font = Design.Typography.code()
        let column = max(font.maximumAdvancement.width, 1)
        let lineHeight = Design.Typography.lineHeight(of: font)
        let y = (bounds.height - lineHeight) / 2
        let targetWidth = column * 2
        let numberWidth = column * CGFloat(Self.numberColumns)
        let changeWidth = column * 2

        targetLabel.frame = NSRect(x: 0, y: y, width: targetWidth, height: lineHeight)
        numberLabel.frame = NSRect(
            x: targetWidth,
            y: y,
            width: numberWidth,
            height: lineHeight
        )
        changeLabel.frame = NSRect(
            x: targetWidth + numberWidth,
            y: y,
            width: changeWidth,
            height: lineHeight
        )
        codeLabel.frame = NSRect(
            x: targetWidth + numberWidth + changeWidth,
            y: y,
            width: max(bounds.width - targetWidth - numberWidth - changeWidth, 0),
            height: lineHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let target = isTarget
        let selection = SelectionSurface.stated(over: Design.Surface.field)
        let diff = Design.Diff.on(Design.Surface.field)

        let fill: NSColor? = if target {
            selection.fill
        } else {
            switch change {
            case .added: diff.addedWash
            case .removed: diff.removedWash
            case .context, nil: nil
            }
        }
        if let fill {
            fill.setFill()
            dirtyRect.intersection(bounds).fill()
        }

        let primary = target ? selection.ink.label : Design.Text.label
        let secondary = target ? selection.ink.secondary : Design.Text.secondary
        let tertiary = target ? selection.ink.tertiary : Design.Text.tertiary
        targetLabel.textColor = target ? selection.ink.label : tertiary
        numberLabel.textColor = tertiary
        codeLabel.textColor = primary
        switch change {
        case .added: changeLabel.textColor = target ? secondary : diff.added
        case .removed: changeLabel.textColor = target ? secondary : diff.removed
        case .context, nil: changeLabel.textColor = tertiary
        }
    }

    func applyTheme() {
        needsDisplay = true
        needsLayout = true
    }

    private var isTarget: Bool {
        guard case .line(_, let isTarget) = row else { return false }
        return isTarget
    }

    private var change: CodeContextPreview.Change? {
        guard case .line(let line, _) = row else { return nil }
        return line.change
    }

    private func configureCopy() {
        switch row {
        case .line(let line, let isTarget):
            targetLabel.stringValue = isTarget ? "›" : ""
            numberLabel.stringValue = line.number.map(String.init) ?? ""
            changeLabel.stringValue = switch line.change {
            case .context: ""
            case .added: "+"
            case .removed: "−"
            }
            codeLabel.stringValue = line.text.isEmpty ? " " : line.text
            setAccessibilitySelected(isTarget)
            let anchor = line.number.map { "\($0)" } ?? ""
            let marker = changeLabel.stringValue
            setAccessibilityLabel([anchor, marker, line.text].filter { !$0.isEmpty }.joined(separator: " "))
        case .omission(let count):
            targetLabel.stringValue = ""
            numberLabel.stringValue = ""
            changeLabel.stringValue = "⋯"
            codeLabel.stringValue = count == 1
                ? L10n.string("1 more line is not shown.")
                : L10n.format("%lld more lines are not shown.", Int64(count))
            setAccessibilitySelected(false)
            setAccessibilityLabel(codeLabel.stringValue)
        }
    }

    private static let numberColumns = 5
}
