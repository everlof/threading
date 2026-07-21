import AppKit

/// Renders a line diff: removed lines on a red wash, added on green, each with a gutter sign.
///
/// One coloured row per line rather than a single attributed string, because a background that
/// runs the full width of the row — not just the width of the text — is what reads as a diff.
/// Long lines wrap rather than scroll; the pane is often narrow, and hiding half a changed line
/// off the right edge is worse than a wrapped one.
final class DiffView: NSStackView {

    init(lines: [DiffLine]) {
        super.init(frame: .zero)

        orientation = .vertical
        alignment = .leading
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false

        let shown = lines.prefix(DiffDefaults.displayCap)
        for line in shown {
            let row = makeRow(line)
            addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }

        if lines.count > shown.count {
            let more = makeNote("… \(lines.count - shown.count) more lines")
            addArrangedSubview(more)
            more.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            more.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Rows

    private func makeRow(_ line: DiffLine) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.backgroundColor = background(for: line.kind).cgColor

        let gutter = NSTextField(labelWithString: sign(for: line.kind))
        gutter.font = font()
        gutter.textColor = foreground(for: line.kind)
        gutter.alignment = .center
        gutter.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(wrappingLabelWithString: line.text.isEmpty ? " " : line.text)
        text.font = font()
        text.textColor = line.kind == .context ? .secondaryLabelColor : foreground(for: line.kind)
        text.isSelectable = true
        text.lineBreakMode = .byCharWrapping
        text.maximumNumberOfLines = 0
        text.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(gutter)
        row.addSubview(text)

        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            gutter.widthAnchor.constraint(equalToConstant: DiffDefaults.gutterWidth),

            text.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: Design.Spacing.tight),
            text.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Design.Spacing.tight),
            text.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            text.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -1)
        ])

        return row
    }

    private func makeNote(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = font()
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Style

    private func font() -> NSFont {
        .monospacedSystemFont(ofSize: DiffDefaults.fontSize, weight: .regular)
    }

    private func sign(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return ""
        }
    }

    private func background(for kind: DiffLine.Kind) -> NSColor {
        switch kind {
        case .added: return .systemGreen.withAlphaComponent(DiffDefaults.addedAlpha)
        case .removed: return .systemRed.withAlphaComponent(DiffDefaults.removedAlpha)
        case .context: return .clear
        }
    }

    private func foreground(for kind: DiffLine.Kind) -> NSColor {
        switch kind {
        case .added: return .systemGreen
        case .removed: return .systemRed
        case .context: return .secondaryLabelColor
        }
    }
}
