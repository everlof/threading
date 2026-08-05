import AppKit

/// Lays out a rendered markdown document as a vertical stack of block views.
///
/// One view per block rather than a single attributed string, because a code block wants its
/// own monospace surface and a list wants a hanging indent — things a lone `NSTextField`
/// cannot express. Text blocks are still plain labels, so selection and wrapping come for free.
final class MarkdownView: NSStackView {

    /// The style as an *expression* rather than a value, so `rebuild` re-resolves whatever the
    /// caller asked for instead of assuming `.assistant`. `MarkdownStyle.assistant` is a
    /// computed property that reads the current theme, so calling it again is the whole of
    /// following a switch; a caller that passes a stored style re-reads that same value, which
    /// is also what they asked for.
    private let style: () -> MarkdownStyle
    /// Kept so the document can be laid out again, which is the only way this surface can follow
    /// a theme — see `rebuild()`.
    private let markdown: String
    private let restyle = AppEventObservations()

    init(markdown: String, style: @autoclosure @escaping () -> MarkdownStyle = .assistant) {
        self.style = style
        self.markdown = markdown
        super.init(frame: .zero)

        orientation = .vertical
        alignment = .leading
        spacing = MarkdownDefaults.blockSpacing
        translatesAutoresizingMaskIntoConstraints = false

        build()

        // **Markdown does not follow the sweep, and cannot.** Its paragraphs are built
        // `NSAttributedString`s and its bullets and code blocks take a font from a `MarkdownStyle`
        // snapshot, so both freeze at construction the way any built string does — the sweep
        // re-resolves a *recorded role* on a view, and an attributed run has none.
        //
        // This is the surface the conversation font exists for, so leaving it stale would mean
        // the flagship case only applied to messages that had not arrived yet: a thread half in
        // one face and half in another. Re-laying the document out is cheap — the parse is a
        // scan over a string this view is already holding — and it is local, which a rebuild
        // driven from the controller would not be.
        restyle.observe(AppThemeDidChange.self) { [weak self] _ in self?.rebuild() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        let style = self.style()
        for block in Markdown.parse(markdown, style: style) {
            let view = Self.blockView(for: block, style: style)
            addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
    }

    private func rebuild() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        build()
    }

    // MARK: - Block Views

    /// Builds one already-parsed block without wrapping it in a complete document stack.
    /// Virtualized transcript surfaces use this seam so a long assistant answer can retain its
    /// cheap block model while AppKit owns only the block views around the viewport.
    static func blockView(for block: MarkdownBlock, style: MarkdownStyle) -> NSView {
        switch block {
        case .paragraph(let text), .heading(let text):
            return label(text)

        case .bullets(let items):
            return list(items, markers: items.map { _ in "•" }, style: style)

        case .ordered(let items):
            return list(items, markers: items.indices.map { "\($0 + 1)." }, style: style)

        case .code(let code):
            return codeBlock(code, style: style)

        case .quote(let text):
            return quote(text, style: style)

        case .table(let model):
            return table(model, style: style)
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
        scroll.forwardsVerticalScrollToAncestor = true

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

    /// A compact GFM table. Columns keep a readable width and the block scrolls horizontally
    /// when the detail pane cannot hold them, while vertical gestures continue scrolling the
    /// conversation.
    private static func table(_ model: MarkdownTable, style: MarkdownStyle) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.applySurface(
            fill: style.codeBackground.withAlphaComponent(0.45),
            radius: .control
        )

        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.forwardsVerticalScrollToAncestor = true

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false

        addTableRow(
            model.headers,
            alignments: model.alignments,
            style: style,
            isHeader: true,
            to: rows
        )
        for values in model.rows {
            let separator = SeparatorView()
            rows.addArrangedSubview(separator)
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: rows.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: rows.trailingAnchor)
            ])
            addTableRow(
                values,
                alignments: model.alignments,
                style: style,
                isHeader: false,
                to: rows
            )
        }

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        ])

        return container
    }

    private static func addTableRow(
        _ values: [NSAttributedString],
        alignments: [NSTextAlignment],
        style: MarkdownStyle,
        isHeader: Bool,
        to table: NSStackView
    ) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false

        for (index, value) in values.enumerated() {
            let cell = NSView()
            cell.translatesAutoresizingMaskIntoConstraints = false
            if isHeader {
                cell.applySurface(fill: Design.Surface.controlHover, radius: .fixed(0))
            }

            let text = label(value)
            text.alignment = alignments[index]
            if isHeader {
                text.textColor = Design.Text.label
            }
            cell.addSubview(text)

            let inset = Design.Spacing.small
            NSLayoutConstraint.activate([
                cell.widthAnchor.constraint(
                    greaterThanOrEqualToConstant: MarkdownDefaults.tableColumnWidth
                ),
                text.topAnchor.constraint(equalTo: cell.topAnchor, constant: inset),
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: inset),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -inset),
                text.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -inset)
            ])
            row.addArrangedSubview(cell)
        }

        table.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: table.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: table.trailingAnchor).isActive = true
    }
}
