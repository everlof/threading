import AppKit

/// Lays out a rendered markdown document as a vertical stack of block views.
///
/// One view per block rather than a single attributed string, because a code block wants its
/// own monospace surface and a list wants a hanging indent — things a lone `NSTextField`
/// cannot express. Text blocks are still plain labels, so selection and wrapping come for free.
final class MarkdownView: NSStackView {

    private let style: MarkdownStyle

    init(markdown: String, style: MarkdownStyle = .assistant) {
        self.style = style
        super.init(frame: .zero)

        orientation = .vertical
        alignment = .leading
        spacing = MarkdownDefaults.blockSpacing
        translatesAutoresizingMaskIntoConstraints = false

        for block in Markdown.parse(markdown, style: style) {
            let view = makeView(for: block)
            addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Block Views

    private func makeView(for block: MarkdownBlock) -> NSView {
        switch block {
        case .paragraph(let text), .heading(let text):
            return label(text)

        case .bullets(let items):
            return list(items, markers: items.map { _ in "•" })

        case .ordered(let items):
            return list(items, markers: items.indices.map { "\($0 + 1)." })

        case .code(let code):
            return codeBlock(code)

        case .quote(let text):
            return quote(text)
        }
    }

    private func label(_ text: NSAttributedString) -> NSTextField {
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
    private func list(_ items: [NSAttributedString], markers: [String]) -> NSView {
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

    private func codeBlock(_ code: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.applySurface(fill: style.codeBackground, radius: Design.Radius.control)

        // Horizontally scrollable, so a long line neither wraps mid-token nor forces the whole
        // conversation wider than the pane.
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed

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

    private func quote(_ text: NSAttributedString) -> NSView {
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
