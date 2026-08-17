import AppKit

// MARK: - Storage Proposal Outline View

/// Draws a cleanup proposal as the outline `StorageCleanupOutline` folded it into: a heading per
/// checkout or scratch tier, and under each one the directories, indented by the path segments
/// they share.
///
/// **Drawn rather than stacked.** A proposal is externally sized — the scratch scope alone found
/// 170 session directories on this machine — so a view per row is a view count nobody bounded.
/// Every line here is one attributed-string draw inside a scrolling clip, and only the lines the
/// dirty rectangle touches are drawn at all. The sheet stays a decision surface: nothing is
/// hidden, capped or summarised away, because a person approving a delete has to be able to read
/// everything that is going.
///
/// The sizes read as a column because they are one: each line's size is drawn right-aligned in a
/// column measured from the widest of them, in the numeric role whose digits do not jitter.
@MainActor
final class StorageProposalOutlineView: NSView, ThemedComponent {

    // MARK: - Properties

    private let outline: StorageCleanupOutline
    private var themeRedraw: ThemeRedraw?

    /// Every drawable line, flattened once: the fold is the model's decision, not a per-draw one.
    private let lines: [Line]

    // MARK: - Initialization

    /// - Parameter accessibilityLabel: the one sentence this outline amounts to. Stated by the
    ///   caller, which is where the sheet's own wording lives; the drawn lines follow as the
    ///   accessibility value.
    init(outline: StorageCleanupOutline, accessibilityLabel: String) {
        self.outline = outline
        self.lines = Self.flatten(outline)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(outline.plainText())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(with: Metrics()))
    }

    /// The height this outline needs, which a host asks for before it has a width: every line is
    /// one line tall whatever the width, because a path truncates rather than wraps.
    func fittingHeight() -> CGFloat {
        height(with: Metrics())
    }

    private func height(with metrics: Metrics) -> CGFloat {
        lines.reduce(Layout.verticalInset * 2) { $0 + metrics.height(of: $1.kind) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // `cacheDisplay` hands an infinite rectangle on its first pass, so the visible band is
        // taken from the intersection with our own bounds and never from the dirty rect alone.
        let visible = dirtyRect.intersection(bounds)
        guard !visible.isEmpty, bounds.width > 0 else { return }

        let metrics = Metrics()
        let sizeColumn = min(
            Layout.maximumSizeColumn,
            lines.map { $0.size.width(in: metrics.font(for: $0.kind, column: .size)) }.max() ?? 0
        )
        let content = bounds.insetBy(dx: Layout.horizontalInset, dy: 0)

        var y = Layout.verticalInset
        for line in lines {
            let rowHeight = metrics.height(of: line.kind)
            defer { y += rowHeight }

            // The gap a heading opens a section with belongs *above* it, not under its own
            // baseline: sections that run together read as one list with a stray bold line in it.
            let gap = metrics.gapAbove(line.kind)
            let rect = NSRect(
                x: content.minX,
                y: y + gap,
                width: content.width,
                height: rowHeight - gap
            )
            guard rect.intersects(visible) else { continue }
            draw(line, in: rect, sizeColumn: sizeColumn, metrics: metrics)
        }
    }

    private func draw(_ line: Line, in rect: NSRect, sizeColumn: CGFloat, metrics: Metrics) {
        let font = metrics.font(for: line.kind, column: .label)

        var labelWidth = rect.width
        if !line.size.isEmpty {
            labelWidth -= sizeColumn + Design.Spacing.medium
            line.size.draw(
                in: NSRect(
                    x: rect.maxX - sizeColumn,
                    y: rect.minY,
                    width: sizeColumn,
                    height: rect.height
                ),
                font: metrics.font(for: line.kind, column: .size),
                color: metrics.color(for: line.kind, column: .size),
                alignment: .right,
                truncation: .byClipping
            )
        }

        // The note takes what it needs up to its share of the row, and never at the label's
        // expense past that: the path is what identifies the directory being deleted.
        if !line.note.isEmpty {
            let noteFont = metrics.font(for: line.kind, column: .note)
            let noteWidth = min(
                line.note.width(in: noteFont),
                max(0, labelWidth * Layout.noteShare)
            )
            if noteWidth > 0 {
                line.note.draw(
                    in: NSRect(
                        x: rect.minX + labelWidth - noteWidth,
                        y: rect.minY,
                        width: noteWidth,
                        height: rect.height
                    ),
                    font: noteFont,
                    color: metrics.color(for: line.kind, column: .note),
                    alignment: .right,
                    // A note is a path too — the tree a cache was built for — so it loses its
                    // middle rather than its extension.
                    truncation: .byTruncatingMiddle
                )
                labelWidth -= noteWidth + Design.Spacing.small
            }
        }

        let indent = CGFloat(line.depth) * Layout.indent
        line.label.draw(
            in: NSRect(
                x: rect.minX + indent,
                y: rect.minY,
                width: max(0, labelWidth - indent),
                height: rect.height
            ),
            font: font,
            color: metrics.color(for: line.kind, column: .label),
            alignment: .left,
            // A path truncates in the middle: its head says which project and its tail says
            // which directory, and a tail-truncated path is every path in the same checkout.
            truncation: line.kind == .directory || line.kind == .branch
                ? .byTruncatingMiddle
                : .byTruncatingTail
        )
    }

    // MARK: - Lines

    private enum LineKind: Equatable {
        case heading
        case subheading
        case directory
        case branch
    }

    private struct Line {
        let kind: LineKind
        let depth: Int
        let label: String
        let note: String
        let size: String
    }

    private static func flatten(_ outline: StorageCleanupOutline) -> [Line] {
        outline.sections.flatMap { section -> [Line] in
            [
                Line(
                    kind: .heading,
                    depth: 0,
                    label: section.heading,
                    note: "",
                    size: StorageCleanupOutline.size(section.byteCount)
                ),
                Line(kind: .subheading, depth: 0, label: section.subheading, note: "", size: "")
            ] + section.rows.map { row in
                Line(
                    kind: row.isDirectory ? .directory : .branch,
                    depth: row.depth + 1,
                    label: row.label,
                    note: row.note ?? "",
                    size: StorageCleanupOutline.size(row.byteCount)
                )
            }
        }
    }

    // MARK: - Metrics

    private enum Column {
        case label
        case note
        case size
    }

    /// The type and the colours this draw is using, resolved once per draw so a live theme
    /// switch is a repaint rather than a rebuild.
    @MainActor
    private struct Metrics {
        let heading = Design.FontRole.emphasizedBody.resolved()
        let subheading = Design.FontRole.caption.resolved()
        let row = Design.FontRole.body.resolved()
        let note = Design.FontRole.caption.resolved()
        let size = Design.FontRole.numericDetail().resolved()

        func font(for kind: LineKind, column: Column) -> NSFont {
            switch column {
            case .size: return kind == .heading ? Design.FontRole.numericBody.resolved() : size
            case .note: return note
            case .label:
                switch kind {
                case .heading: return heading
                case .subheading: return subheading
                case .directory, .branch: return row
                }
            }
        }

        func color(for kind: LineKind, column: Column) -> NSColor {
            switch column {
            case .note: return Design.Text.tertiary
            case .size: return kind == .heading ? Design.Text.label : Design.Text.secondary
            case .label:
                switch kind {
                case .heading: return Design.Text.label
                case .subheading: return Design.Text.tertiary
                case .directory: return Design.Text.label
                // A branch names no directory that is going: it is the shape of the paths under
                // it, and reads as the grouping it is.
                case .branch: return Design.Text.secondary
                }
            }
        }

        func height(of kind: LineKind) -> CGFloat {
            let font = self.font(for: kind, column: .label)
            return ceil(font.boundingRectForFont.height) + Layout.lineLeading + gapAbove(kind)
        }

        /// What a line opens with. Only a heading does: it is where one group ends and the next
        /// begins, and the first heading's gap is the view's own top inset.
        func gapAbove(_ kind: LineKind) -> CGFloat {
            kind == .heading ? Design.Spacing.medium : 0
        }
    }

    private enum Layout {
        static let horizontalInset: CGFloat = Design.Spacing.tight
        static let verticalInset: CGFloat = Design.Spacing.small
        static let lineLeading: CGFloat = Design.Spacing.hairline
        static let indent: CGFloat = Design.Spacing.inset
        static let maximumSizeColumn: CGFloat = 96

        /// How much of a row a note may take before the path it annotates starts paying for it.
        static let noteShare: CGFloat = 0.45
    }
}

// MARK: - Drawing Helpers

private extension String {

    func width(in font: NSFont) -> CGFloat {
        ceil((self as NSString).size(withAttributes: [.font: font]).width)
    }

    /// One line of text, in a role's font and a semantic colour, truncated rather than wrapped:
    /// every line in this outline is one line tall, whatever the sheet's width turns out to be.
    func draw(
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        truncation: NSLineBreakMode
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        // The paragraph style is where truncation lives. A cell's `lineBreakMode` is ignored the
        // moment text is drawn as an attributed string, which is how a path ends up clipped
        // mid-glyph with no ellipsis while every assertion about it passes.
        paragraph.lineBreakMode = truncation

        (self as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}
