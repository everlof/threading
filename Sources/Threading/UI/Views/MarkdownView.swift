import AppKit

/// How a rendered document is set. The parser and block views are shared; only rhythm and the
/// heading hierarchy differ.
enum MarkdownPresentation {
    /// An answer in a transcript: one quiet heading step and the conversation's tight rhythm.
    case conversation
    /// A standalone document read on its own: distinct heading levels and air above sections.
    case document

    @MainActor var blockSpacing: CGFloat {
        switch self {
        case .conversation: MarkdownDefaults.blockSpacing
        case .document: Design.Spacing.medium
        }
    }

    /// What a heading stands clear of the block before it, beyond the ordinary rhythm.
    @MainActor var headingLeading: CGFloat? {
        switch self {
        case .conversation: nil
        case .document: Design.Spacing.large
        }
    }

    @MainActor func style(_ style: MarkdownStyle, headingLevel level: Int) -> MarkdownStyle {
        guard self == .document else { return style }
        var leveled = style
        leveled.headingFont = Design.Typography.documentHeading(
            level: level, from: style.font, surface: .conversation
        )
        return leveled
    }
}

/// Lays out a rendered markdown document as a vertical stack of block views.
///
/// One view per block on the active bounded page rather than a single attributed string, because
/// a code block wants its own monospace surface and a list wants a hanging indent — things a lone
/// `NSTextField` cannot express. Text blocks are still plain labels, so selection and wrapping
/// come for free.
final class MarkdownView: NSStackView {

    /// The style as an *expression* rather than a value, so `rebuild` re-resolves whatever the
    /// caller asked for instead of assuming `.assistant`. `MarkdownStyle.assistant` is a
    /// computed property that reads the current theme, so calling it again is the whole of
    /// following a switch; a caller that passes a stored style re-reads that same value, which
    /// is also what they asked for.
    private let style: () -> MarkdownStyle
    /// Cheap source blocks are the complete document model. Only one bounded page is parsed,
    /// styled and turned into AppKit views at a time; keeping a giant answer as one virtual table
    /// row must not recreate an unbounded view/constraint tree inside that row.
    private let blockPages: [[String]]
    private let presentation: MarkdownPresentation
    private let restyle = AppEventObservations()
    private weak var pagedContent: MarkdownPagedContentView?

    /// The page on screen, which a theme rebuild keeps rather than returning to the first.
    var currentPage: Int { pagedContent?.pageIndex ?? 0 }

    convenience init(markdown: String, style: @autoclosure @escaping () -> MarkdownStyle = .assistant) {
        self.init(preparedPages: Self.preparePages(markdown), style: style())
    }

    /// The editor prepares source boundaries on its bounded worker; only the active page is
    /// styled and mounted here, through the same renderer used by native conversations.
    init(
        preparedPages: [[String]],
        initialPage: Int = 0,
        presentation: MarkdownPresentation = .conversation,
        style: @autoclosure @escaping () -> MarkdownStyle = .assistant
    ) {
        self.style = style
        blockPages = preparedPages
        self.presentation = presentation
        super.init(frame: .zero)

        orientation = .vertical
        alignment = .leading
        spacing = presentation.blockSpacing
        translatesAutoresizingMaskIntoConstraints = false

        build(page: initialPage)

        // **Markdown does not follow the sweep, and cannot.** Its paragraphs are built
        // `NSAttributedString`s and its bullets and code blocks take a font from a `MarkdownStyle`
        // snapshot, so both freeze at construction the way any built string does — the sweep
        // re-resolves a *recorded role* on a view, and an attributed run has none.
        //
        // This is the surface the conversation font exists for, so leaving it stale would mean
        // the flagship case only applied to messages that had not arrived yet: a thread half in
        // one face and half in another. Re-laying the active bounded page is local, which a
        // rebuild driven from the controller would not be.
        restyle.observe(AppThemeDidChange.self) { [weak self] _ in self?.rebuild() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(page initialPage: Int) {
        let style = self.style()
        let pages = blockPages
        let presentation = self.presentation

        let document = MarkdownPagedContentView(
            pageCount: pages.count,
            initialPage: initialPage,
            pageDescription: { page in
                return L10n.format(
                    "Page %lld of %lld",
                    Int64(page + 1),
                    Int64(pages.count)
                )
            },
            makePage: { page in
                let pageStack = NSStackView()
                pageStack.orientation = .vertical
                pageStack.alignment = .leading
                pageStack.spacing = presentation.blockSpacing
                pageStack.translatesAutoresizingMaskIntoConstraints = false

                var previous: NSView?
                for source in pages[page] {
                    let level = presentation == .document ? Markdown.headingLevel(ofSource: source) : nil
                    let blockStyle = level.map { presentation.style(style, headingLevel: $0) } ?? style
                    for block in Markdown.parse(source, style: blockStyle) {
                        let view = Self.blockView(for: block, style: blockStyle)
                        if level != nil, let previous, let leading = presentation.headingLeading {
                            pageStack.setCustomSpacing(leading, after: previous)
                        }
                        pageStack.addArrangedSubview(view)
                        NSLayoutConstraint.activate([
                            view.leadingAnchor.constraint(equalTo: pageStack.leadingAnchor),
                            view.trailingAnchor.constraint(equalTo: pageStack.trailingAnchor)
                        ])
                        previous = view
                    }
                }
                return pageStack
            }
        )
        pagedContent = document
        addArrangedSubview(document)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: leadingAnchor),
            document.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    /// A second budget prevents nested limits from multiplying: 48 independently capped tables
    /// must not all become the first page merely because each one is a single Markdown block.
    /// Source-line counting is a byte scan (newline is ASCII), so page planning creates no styled
    /// strings or AppKit objects for content outside the active page.
    nonisolated static func preparePages(_ markdown: String) -> [[String]] {
        sourcePages(Markdown.sourceBlocks(markdown))
    }

    /// The same plan plus the page holding source `line`, so an editor's preview follows the
    /// text being typed instead of returning to the first page whenever the source changes.
    nonisolated static func preparePages(_ markdown: String, showingLine line: Int) -> (pages: [[String]], page: Int) {
        let blocks = Markdown.sourceBlockLines(markdown)
        let pages = sourcePages(blocks.map(\.source))
        var page = 0
        var firstBlock = 0
        for (index, sources) in pages.enumerated() {
            guard firstBlock < blocks.count, blocks[firstBlock].line <= line else { break }
            page = index
            firstBlock += sources.count
        }
        return (pages, page)
    }

    nonisolated private static func sourcePages(_ sources: [String]) -> [[String]] {
        guard !sources.isEmpty else { return [[]] }

        let maximumBlocks = MarkdownDefaults.maximumBlocksPerPage
        let maximumLines = MarkdownDefaults.maximumSourceLinesPerPage
        var pages: [[String]] = []
        var page: [String] = []
        var pageLines = 0

        for source in sources {
            var sourceLines = 1
            for byte in source.utf8 where byte == 0x0A && sourceLines < maximumLines {
                sourceLines += 1
            }

            if !page.isEmpty,
               page.count >= maximumBlocks || pageLines + sourceLines > maximumLines {
                pages.append(page)
                page.removeAll(keepingCapacity: true)
                pageLines = 0
            }

            page.append(source)
            pageLines += sourceLines

            if page.count >= maximumBlocks || pageLines >= maximumLines {
                pages.append(page)
                page.removeAll(keepingCapacity: true)
                pageLines = 0
            }
        }

        if !page.isEmpty { pages.append(page) }
        return pages
    }

    private static func pageCount(itemCount: Int, pageSize: Int) -> Int {
        max(1, (itemCount + pageSize - 1) / pageSize)
    }

    private static func pageRange(itemCount: Int, pageSize: Int, page: Int) -> Range<Int> {
        let start = min(page * pageSize, itemCount)
        return start..<min(start + pageSize, itemCount)
    }

    private static func pagedList(
        _ items: [NSAttributedString],
        ordered: Bool,
        style: MarkdownStyle
    ) -> NSView {
        let pageSize = MarkdownDefaults.maximumListItemsPerPage
        let pageCount = pageCount(itemCount: items.count, pageSize: pageSize)
        return MarkdownPagedContentView(
            pageCount: pageCount,
            pageDescription: { page in
                let range = pageRange(itemCount: items.count, pageSize: pageSize, page: page)
                return L10n.format(
                    "%lld–%lld of %lld items",
                    Int64(range.lowerBound + 1),
                    Int64(range.upperBound),
                    Int64(items.count)
                )
            },
            makePage: { page in
                let range = pageRange(itemCount: items.count, pageSize: pageSize, page: page)
                let values = Array(items[range])
                let markers = ordered
                    ? range.map { "\($0 + 1)." }
                    : values.map { _ in "•" }
                return list(values, markers: markers, style: style)
            }
        )
    }

    private static func pagedTable(
        _ model: MarkdownTable,
        availableWidth: CGFloat?
    ) -> NSView {
        let columnCount = max(
            1,
            max(
                model.headers.count,
                max(
                    model.alignments.count,
                    model.rows.lazy.map(\.count).max() ?? 0
                )
            )
        )
        let rowSize = MarkdownDefaults.maximumTableRowsPerPage
        let columnSize = MarkdownDefaults.maximumTableColumnsPerPage
        let rowPageCount = pageCount(itemCount: model.rows.count, pageSize: rowSize)
        let columnPageCount = pageCount(itemCount: columnCount, pageSize: columnSize)
        let totalPageCount = rowPageCount * columnPageCount
        let tableWidth = availableWidth.flatMap { $0 > 0 ? $0 : nil }
            ?? Design.Size.readableWidth

        return MarkdownPagedContentView(
            pageCount: totalPageCount,
            pageDescription: { page in
                let rowPage = page / columnPageCount
                let columnPage = page % columnPageCount
                let rows = pageRange(
                    itemCount: model.rows.count,
                    pageSize: rowSize,
                    page: rowPage
                )
                let columns = pageRange(
                    itemCount: columnCount,
                    pageSize: columnSize,
                    page: columnPage
                )
                return L10n.format(
                    "Rows %lld–%lld of %lld · columns %lld–%lld of %lld",
                    Int64(rows.lowerBound + 1),
                    Int64(rows.upperBound),
                    Int64(model.rows.count),
                    Int64(columns.lowerBound + 1),
                    Int64(columns.upperBound),
                    Int64(columnCount)
                )
            },
            makePage: { page in
                let rowPage = page / columnPageCount
                let columnPage = page % columnPageCount
                let rowRange = pageRange(
                    itemCount: model.rows.count,
                    pageSize: rowSize,
                    page: rowPage
                )
                let columnRange = pageRange(
                    itemCount: columnCount,
                    pageSize: columnSize,
                    page: columnPage
                )
                let empty = NSAttributedString(string: "")
                let headers = columnRange.map { index in
                    index < model.headers.count ? model.headers[index] : empty
                }
                let alignments = columnRange.map { index in
                    index < model.alignments.count ? model.alignments[index] : .left
                }
                let rows = rowRange.map { rowIndex in
                    let source = model.rows[rowIndex]
                    return columnRange.map { columnIndex in
                        columnIndex < source.count ? source[columnIndex] : empty
                    }
                }
                return ThemedDocumentTableView(
                    headers: headers,
                    rows: rows,
                    alignments: alignments,
                    availableWidth: tableWidth,
                    minimumColumnWidth: MarkdownDefaults.tableColumnWidth
                )
            }
        )
    }

    private func rebuild() {
        let page = currentPage
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        build(page: page)
    }

    // MARK: - Block Views

    /// Builds one already-parsed block without wrapping it in a complete document stack.
    /// Virtualized transcript surfaces use this seam so a long assistant answer can retain its
    /// cheap block model while AppKit owns only the block views around the viewport.
    static func blockView(for block: MarkdownBlock, style: MarkdownStyle) -> NSView {
        blockView(for: block, style: style, availableWidth: nil)
    }

    /// Width-aware virtual rows can hand a table its settled readable width up front. The
    /// design component then lays out its fixed grid directly instead of building a nested
    /// Auto Layout tree to rediscover the same geometry on every scroll tick.
    static func blockView(
        for block: MarkdownBlock,
        style: MarkdownStyle,
        availableWidth: CGFloat?
    ) -> NSView {
        switch block {
        case .paragraph(let text), .heading(let text):
            return label(text)

        case .bullets(let items):
            return pagedList(items, ordered: false, style: style)

        case .ordered(let items):
            return pagedList(items, ordered: true, style: style)

        case .code(let code):
            return codeBlock(code, style: style)

        case .quote(let text):
            return quote(text, style: style)

        case .table(let model):
            return pagedTable(model, availableWidth: availableWidth)
        }
    }

    private static func label(_ text: NSAttributedString) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isSelectable = true
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// A bullet or numbered list, each row a fixed-width marker beside wrapping content, so
    /// wrapped lines hang under the text rather than under the marker.
    private static func list(
        _ items: [NSAttributedString],
        markers: [String],
        style: MarkdownStyle
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (item, marker) in zip(items, markers) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = Design.Spacing.small
            row.translatesAutoresizingMaskIntoConstraints = false

            let bullet = NSTextField(labelWithString: marker)
            bullet.font = style.font
            bullet.textColor = style.secondaryColor
            bullet.translatesAutoresizingMaskIntoConstraints = false
            bullet.widthAnchor.constraint(equalToConstant: MarkdownDefaults.listIndent).isActive = true
            bullet.alignment = .right

            row.addArrangedSubview(bullet)
            row.addArrangedSubview(label(item))

            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        return stack
    }

    private static func codeBlock(_ code: String, style: MarkdownStyle) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.applySurface(fill: style.codeBackground, radius: .control)

        // Horizontally scrollable, so a long line neither wraps mid-token nor forces the whole
        // conversation wider than the pane.
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollHandoff = .always

        let field = NSTextField(labelWithString: code)
        field.font = style.codeFont
        field.textColor = style.codeColor
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byClipping
        field.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(field)
        scroll.documentView = document
        scroll.fittedDocumentHeight = field.intrinsicContentSize.height
        scroll.setContentHuggingPriority(.required, for: .vertical)
        scroll.setContentCompressionResistancePriority(.required, for: .vertical)
        container.addSubview(scroll)

        let pad = MarkdownDefaults.codePadding
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),

            field.topAnchor.constraint(equalTo: document.topAnchor),
            field.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        ])

        return container
    }

    private static func quote(_ text: NSAttributedString, style: MarkdownStyle) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.applyLayerBackground(style.secondaryColor.withAlphaComponent(0.4))

        let content = label(text)
        content.textColor = style.secondaryColor

        container.addSubview(bar)
        container.addSubview(content)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: MarkdownDefaults.quoteBarWidth),

            content.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: Design.Spacing.medium),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

}

/// A complete content model with a bounded AppKit footprint. The pager itself is native,
/// host-owned document navigation; extension customization still receives the assistant message
/// atomically and does not gain control over conversation ordering or content availability.
private final class MarkdownPagedContentView: NSStackView {
    private let pageCount: Int
    private let pageDescription: (Int) -> String
    private let makePage: (Int) -> NSView
    private(set) var pageIndex: Int

    init(
        pageCount: Int,
        initialPage: Int = 0,
        pageDescription: @escaping (Int) -> String,
        makePage: @escaping (Int) -> NSView
    ) {
        self.pageCount = max(pageCount, 1)
        pageIndex = min(max(initialPage, 0), self.pageCount - 1)
        self.pageDescription = pageDescription
        self.makePage = makePage
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = MarkdownDefaults.blockSpacing
        translatesAutoresizingMaskIntoConstraints = false
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func rebuild() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let page = makePage(pageIndex)
        addArrangedSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        guard pageCount > 1 else { return }

        let previous = ThemedButton(
            title: L10n.string("Previous"),
            target: self,
            action: #selector(showPreviousPage)
        )
        previous.emphasis = .tertiary
        previous.isEnabled = pageIndex > 0

        let position = NSTextField(labelWithString: pageDescription(pageIndex))
        position.applyFont(.detail())
        position.textColor = Design.Text.tertiary
        position.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let next = ThemedButton(
            title: L10n.string("Next"),
            target: self,
            action: #selector(showNextPage)
        )
        next.emphasis = .tertiary
        next.isEnabled = pageIndex + 1 < pageCount

        let pager = NSStackView(views: [previous, position, spacer, next])
        pager.orientation = .horizontal
        pager.alignment = .centerY
        pager.spacing = Design.Spacing.small
        pager.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(pager)
        NSLayoutConstraint.activate([
            pager.leadingAnchor.constraint(equalTo: leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @objc private func showPreviousPage() {
        guard pageIndex > 0 else { return }
        pageIndex -= 1
        rebuildAndRemeasure()
    }

    @objc private func showNextPage() {
        guard pageIndex + 1 < pageCount else { return }
        pageIndex += 1
        rebuildAndRemeasure()
    }

    private func rebuildAndRemeasure() {
        rebuild()
        invalidateIntrinsicContentSize()
        needsLayout = true

        var ancestor = superview
        while let view = ancestor {
            view.invalidateIntrinsicContentSize()
            view.needsLayout = true
            if let table = view as? NSTableView {
                let row = table.row(for: self)
                if row >= 0 {
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                }
                break
            }
            ancestor = view.superview
        }
    }
}
