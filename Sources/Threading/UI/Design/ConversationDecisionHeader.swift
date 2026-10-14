import AppKit

/// Shared anatomy for an inline decision, while each owner keeps its distinct semantics.
final class ConversationDecisionHeader: NSView {
    init(title: String, detail: String, symbol: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let glyph = GlyphView()
        glyph.setSymbol(symbol, slot: Design.Symbol.control, role: .control, weight: .medium)
        glyph.tint = Design.Surface.accent
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.applyFont(.subheading, in: .conversation)
        heading.textColor = Design.Text.label
        let explanation = NSTextField(wrappingLabelWithString: detail)
        explanation.applyFont(.caption, in: .conversation)
        explanation.textColor = Design.Text.secondary
        let text = NSStackView(views: [heading, explanation])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.tight
        for view in [glyph, text] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: Design.Symbol.control),
            glyph.heightAnchor.constraint(equalToConstant: Design.Symbol.control),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.topAnchor.constraint(equalTo: text.topAnchor),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Design.Spacing.medium),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
            heading.widthAnchor.constraint(equalTo: text.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
