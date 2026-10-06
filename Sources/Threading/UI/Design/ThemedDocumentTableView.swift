import AppKit

/// A selectable document table whose cell geometry is known when it is built.
///
/// Markdown tables previously nested one vertical stack, one horizontal stack per row, one
/// wrapper per cell and six constraints per value. A table in a transcript is already one
/// semantic block and never edits its column structure, so asking Auto Layout to rediscover that
/// grid on every scroll tick is pure overhead. This component measures the attributed cell text
/// once, places the labels directly, and draws header/separator surfaces from live design roles.
public final class ThemedDocumentTableView: NSView, ThemedComponent {
    private let scrollView = ThemedScrollView()
    private let canvas: ThemedDocumentTableCanvas
    private var themeRedraw: ThemeRedraw?
    /// The width the grid was last offered: the one it was built for until it has a frame.
    private var offeredWidth: CGFloat

    public init(
        headers: [NSAttributedString],
        rows: [[NSAttributedString]],
        alignments: [NSTextAlignment],
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat
    ) {
        canvas = ThemedDocumentTableCanvas(
            headers: headers,
            rows: rows,
            alignments: alignments,
            availableWidth: availableWidth,
            minimumColumnWidth: minimumColumnWidth
        )
        offeredWidth = availableWidth
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)
        applySurface(
            // The panel role already states its intended strength. Replacing its alpha here
            // amplified System's deliberately quiet 5% label wash to 45%, producing the same
            // heavy mid-gray slab in light and dark appearances.
            fill: Design.Surface.panel,
            radius: .control
        )

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollHandoff = .always
        scrollView.documentView = canvas
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged, newSize.width > 0 else { return }
        let overflowed = overflowsHorizontally
        offeredWidth = newSize.width
        if canvas.updateAvailableWidth(newSize.width) || overflowsHorizontally != overflowed {
            invalidateIntrinsicContentSize()
        }
    }

    /// Known from the grid and the width it was offered, before any layout: the minimum column
    /// width is what makes a table wider than its pane, and only then is a scroller shown.
    private var overflowsHorizontally: Bool { canvas.frame.width > offeredWidth + 0.5 }

    public override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: scrollView.heightToFitContent(canvas.frame.height, overflowsHorizontally: overflowsHorizontally)
        )
    }
}

/// The fixed document inside `ThemedDocumentTableView`. Labels remain ordinary selectable text;
/// only the cell wrappers and constraint graph disappear.
private final class ThemedDocumentTableCanvas: NSView, ThemedComponent {
    private struct Cell {
        let field: NSTextField
        let column: Int
    }

    /// Everything the immutable grid needs before the `NSView` exists.
    ///
    /// Keeping this work out of the subclass initializer is not cosmetic. Swift 6.3's
    /// ownership optimizer loses the initializer's `self` lifetime when the pre-`super`
    /// path contains the former nested `map`/key-path normalization and aborts every Release
    /// build in `OSSACompleteLifetime`. The direct pass also avoids cloning the complete
    /// attributed-string matrix merely to pad ragged rows; missing cells are materialized only
    /// where the finished grid actually needs one.
    private struct PreparedGrid {
        let cellsByRow: [[Cell]]
        let rowHeights: [CGFloat]
        let columnCount: Int
        let columnWidth: CGFloat
        let documentWidth: CGFloat
        let documentHeight: CGFloat
    }

    private let cellsByRow: [[Cell]]
    private let columnCount: Int
    private let minimumColumnWidth: CGFloat
    private var rowHeights: [CGFloat]
    private var columnWidth: CGFloat
    private let cellInset = Design.Spacing.small
    private let separatorWidth = Design.Radius.border
    private var themeRedraw: ThemeRedraw?

    override var isFlipped: Bool { true }

    init(
        headers: [NSAttributedString],
        rows: [[NSAttributedString]],
        alignments: [NSTextAlignment],
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat
    ) {
        let prepared = Self.prepareGrid(
            headers: headers,
            rows: rows,
            alignments: alignments,
            availableWidth: availableWidth,
            minimumColumnWidth: minimumColumnWidth
        )
        cellsByRow = prepared.cellsByRow
        rowHeights = prepared.rowHeights
        columnCount = prepared.columnCount
        self.minimumColumnWidth = minimumColumnWidth
        columnWidth = prepared.columnWidth
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: prepared.documentWidth,
            height: prepared.documentHeight
        ))
        themeRedraw = ThemeRedraw(self)
        setAccessibilityRole(.table)

        for row in cellsByRow {
            for cell in row { addSubview(cell.field) }
        }
        placeCells()
    }

    private static func prepareGrid(
        headers: [NSAttributedString],
        rows: [[NSAttributedString]],
        alignments: [NSTextAlignment],
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat
    ) -> PreparedGrid {
        var widestRow = headers.count
        for values in rows {
            widestRow = max(widestRow, values.count)
        }
        let columnCount = max(widestRow, 1)
        let documentWidth = max(availableWidth, CGFloat(columnCount) * minimumColumnWidth)
        let columnWidth = documentWidth / CGFloat(columnCount)
        var builtRows: [[Cell]] = []
        var heights: [CGFloat] = []
        builtRows.reserveCapacity(rows.count + 1)
        heights.reserveCapacity(rows.count + 1)

        for rowIndex in 0...rows.count {
            let values = rowIndex == 0 ? headers : rows[rowIndex - 1]
            var builtCells: [Cell] = []
            var rowHeight: CGFloat = 0
            builtCells.reserveCapacity(columnCount)

            for column in 0..<columnCount {
                let source = column < values.count
                    ? values[column]
                    : NSAttributedString(string: "")
                let attributed: NSAttributedString
                if rowIndex == 0 {
                    let emphasized = NSMutableAttributedString(attributedString: source)
                    emphasized.addAttribute(
                        .foregroundColor,
                        value: Design.Text.label,
                        range: NSRange(location: 0, length: emphasized.length)
                    )
                    attributed = emphasized
                } else {
                    attributed = source
                }

                let field = NSTextField(labelWithAttributedString: attributed)
                field.isSelectable = true
                field.lineBreakMode = .byWordWrapping
                field.maximumNumberOfLines = 0
                field.alignment = column < alignments.count ? alignments[column] : .left
                builtCells.append(Cell(field: field, column: column))

                let textWidth = max(1, columnWidth - Design.Spacing.small * 2)
                let textBounds = attributed.boundingRect(
                    with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                let fontHeight: CGFloat
                if attributed.length > 0,
                   let font = attributed.attribute(
                       .font,
                       at: 0,
                       effectiveRange: nil
                   ) as? NSFont {
                    fontHeight = ceil(font.ascender - font.descender + font.leading)
                } else {
                    fontHeight = 0
                }
                rowHeight = max(rowHeight, ceil(textBounds.height), fontHeight)
            }

            builtRows.append(builtCells)
            heights.append(rowHeight + Design.Spacing.small * 2)
        }

        let separators = CGFloat(max(0, heights.count - 1)) * Design.Radius.border
        return PreparedGrid(
            cellsByRow: builtRows,
            rowHeights: heights,
            columnCount: columnCount,
            columnWidth: columnWidth,
            documentWidth: documentWidth,
            documentHeight: heights.reduce(0, +) + separators
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Reflows the fixed grid only when the pane's settled width changes. The old stack-based
    /// table received this through Auto Layout at considerable cost; direct placement still has
    /// to preserve that behavior so a pane resize cannot leave stale wrapping or row heights.
    @discardableResult
    func updateAvailableWidth(_ availableWidth: CGFloat) -> Bool {
        let documentWidth = max(
            availableWidth,
            CGFloat(columnCount) * minimumColumnWidth
        )
        guard abs(documentWidth - frame.width) > 0.5 else { return false }

        let previousHeight = frame.height
        columnWidth = documentWidth / CGFloat(columnCount)
        rowHeights = cellsByRow.map(measuredHeight)
        let separators = CGFloat(max(0, rowHeights.count - 1)) * separatorWidth
        frame.size = NSSize(
            width: documentWidth,
            height: rowHeights.reduce(0, +) + separators
        )
        placeCells()
        needsDisplay = true
        return abs(frame.height - previousHeight) > 0.5
    }

    private func measuredHeight(for row: [Cell]) -> CGFloat {
        var rowHeight: CGFloat = 0
        let textWidth = max(1, columnWidth - cellInset * 2)
        for cell in row {
            let attributed = cell.field.attributedStringValue
            let textBounds = attributed.boundingRect(
                with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let fontHeight: CGFloat
            if attributed.length > 0,
               let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                fontHeight = ceil(font.ascender - font.descender + font.leading)
            } else {
                fontHeight = 0
            }
            rowHeight = max(rowHeight, ceil(textBounds.height), fontHeight)
        }
        return rowHeight + cellInset * 2
    }

    private func placeCells() {
        var y: CGFloat = 0
        for (row, height) in zip(cellsByRow, rowHeights) {
            for cell in row {
                cell.field.frame = NSRect(
                    x: CGFloat(cell.column) * columnWidth + cellInset,
                    y: y + cellInset,
                    width: max(1, columnWidth - cellInset * 2),
                    height: max(1, height - cellInset * 2)
                )
            }
            y += height + separatorWidth
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let headerHeight = rowHeights.first {
            Design.Surface.controlHover.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight).fill()
        }

        Design.Surface.divider.setFill()
        var y: CGFloat = 0
        for height in rowHeights.dropLast() {
            y += height
            NSRect(x: 0, y: y, width: bounds.width, height: separatorWidth).fill()
            y += separatorWidth
        }
    }
}
