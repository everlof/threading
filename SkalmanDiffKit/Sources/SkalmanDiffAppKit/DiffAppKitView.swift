#if canImport(AppKit)
import AppKit
import SkalmanDiffCore

public struct DiffAppKitConfiguration {
    public let displayCap: Int
    public let showsNumbers: Bool
    public let wraps: Bool
    public let lineCharacterLimit: Int
    public let numberWidth: CGFloat
    public let gutterWidth: CGFloat
    public let verticalInset: CGFloat

    public init(
        displayCap: Int,
        showsNumbers: Bool,
        wraps: Bool,
        lineCharacterLimit: Int,
        numberWidth: CGFloat,
        gutterWidth: CGFloat,
        verticalInset: CGFloat
    ) {
        self.displayCap = displayCap
        self.showsNumbers = showsNumbers
        self.wraps = wraps
        self.lineCharacterLimit = lineCharacterLimit
        self.numberWidth = numberWidth
        self.gutterWidth = gutterWidth
        self.verticalInset = verticalInset
    }
}

public struct DiffAppKitTheme {
    public let font: NSFont
    public let label: NSColor
    public let secondaryLabel: NSColor
    public let tertiaryLabel: NSColor
    public let added: NSColor
    public let removed: NSColor
    public let addedBackground: NSColor
    public let removedBackground: NSColor
    public let syntaxKeyword: NSColor
    public let syntaxType: NSColor
    public let syntaxString: NSColor
    public let syntaxNumber: NSColor
    public let syntaxComment: NSColor

    public init(
        font: NSFont,
        label: NSColor,
        secondaryLabel: NSColor,
        tertiaryLabel: NSColor,
        added: NSColor,
        removed: NSColor,
        addedBackground: NSColor,
        removedBackground: NSColor,
        syntaxKeyword: NSColor,
        syntaxType: NSColor,
        syntaxString: NSColor,
        syntaxNumber: NSColor,
        syntaxComment: NSColor
    ) {
        self.font = font
        self.label = label
        self.secondaryLabel = secondaryLabel
        self.tertiaryLabel = tertiaryLabel
        self.added = added
        self.removed = removed
        self.addedBackground = addedBackground
        self.removedBackground = removedBackground
        self.syntaxKeyword = syntaxKeyword
        self.syntaxType = syntaxType
        self.syntaxString = syntaxString
        self.syntaxNumber = syntaxNumber
        self.syntaxComment = syntaxComment
    }
}

/// AppKit renderer for one contiguous set of diff lines.
///
/// The host owns scrolling, file cards and actions. This view owns the expensive repeatable
/// part: syntax tokenization, wrapping, line-number gutters and full-width change washes.
open class DiffAppKitView: NSStackView {
    private struct Row {
        let line: DiffLine
        let tokens: [DiffSyntaxToken]
    }

    private let configuration: DiffAppKitConfiguration
    private let theme: DiffAppKitTheme
    private let isHighlighted: Bool

    public init(
        lines: [DiffLine],
        path: String? = nil,
        configuration: DiffAppKitConfiguration,
        theme: DiffAppKitTheme
    ) {
        self.configuration = configuration
        self.theme = theme
        isHighlighted = path.flatMap(DiffSyntax.language(forPath:)) != nil

        let capped = lines.map {
            DiffLine(
                kind: $0.kind,
                text: Self.cap($0.text, at: configuration.lineCharacterLimit),
                oldNumber: $0.oldNumber,
                newNumber: $0.newNumber
            )
        }
        let tokens = DiffSyntax.tokens(for: capped, path: path)
        let rows = zip(capped, tokens).map(Row.init)

        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false

        let shown = rows.prefix(max(configuration.displayCap, 0))
        for row in shown {
            let rowView = makeRow(row)
            addArrangedSubview(rowView)
            rowView.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            if configuration.wraps {
                rowView.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            }
        }

        if rows.count > shown.count {
            let note = makeNote("… \(rows.count - shown.count) more lines")
            addArrangedSubview(note)
            note.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            if configuration.wraps {
                note.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            }
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeRow(_ row: Row) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = background(for: row.line.kind).cgColor

        let gutter = NSTextField(labelWithString: sign(for: row.line.kind))
        gutter.font = theme.font
        gutter.textColor = foreground(for: row.line.kind)
        gutter.alignment = .center
        gutter.translatesAutoresizingMaskIntoConstraints = false

        let value = row.line.text.isEmpty ? " " : row.line.text
        let text = configuration.wraps
            ? NSTextField(wrappingLabelWithString: value)
            : NSTextField(labelWithString: value)
        text.font = theme.font
        text.textColor = baseColor(for: row.line.kind)
        text.isSelectable = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = configuration.wraps ? .byCharWrapping : .byClipping
        text.maximumNumberOfLines = configuration.wraps ? 0 : 1
        text.usesSingleLineMode = !configuration.wraps
        if !configuration.wraps {
            text.setContentHuggingPriority(.required, for: .horizontal)
            text.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        if !row.tokens.isEmpty {
            text.attributedStringValue = attributed(row)
        }

        container.addSubview(gutter)
        container.addSubview(text)

        var gutterLeading = container.leadingAnchor
        if configuration.showsNumbers {
            let number = NSTextField(labelWithString: row.line.displayNumber.map(String.init) ?? "")
            number.font = theme.font
            number.textColor = theme.tertiaryLabel
            number.alignment = .right
            number.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(number)
            NSLayoutConstraint.activate([
                number.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                number.topAnchor.constraint(
                    equalTo: container.topAnchor,
                    constant: configuration.verticalInset
                ),
                number.widthAnchor.constraint(equalToConstant: configuration.numberWidth),
            ])
            gutterLeading = number.trailingAnchor
        }

        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: gutterLeading),
            gutter.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: configuration.verticalInset
            ),
            gutter.widthAnchor.constraint(equalToConstant: configuration.gutterWidth),

            text.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            text.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: configuration.verticalInset
            ),
            text.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -configuration.verticalInset
            ),
        ])
        return container
    }

    private func attributed(_ row: Row) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = configuration.wraps ? .byCharWrapping : .byClipping

        let value = NSMutableAttributedString(string: row.line.text, attributes: [
            .font: theme.font,
            .foregroundColor: baseColor(for: row.line.kind),
            .paragraphStyle: paragraph,
        ])
        for token in row.tokens {
            value.addAttribute(
                .foregroundColor,
                value: syntaxColor(for: token.role),
                range: NSRange(token.range, in: row.line.text)
            )
        }
        return value
    }

    private func makeNote(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = theme.font
        label.textColor = theme.tertiaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func syntaxColor(for role: DiffSyntaxRole) -> NSColor {
        switch role {
        case .keyword: return theme.syntaxKeyword
        case .type: return theme.syntaxType
        case .string: return theme.syntaxString
        case .number: return theme.syntaxNumber
        case .comment: return theme.syntaxComment
        }
    }

    private func background(for kind: DiffLine.Kind) -> NSColor {
        switch kind {
        case .added: return theme.addedBackground
        case .removed: return theme.removedBackground
        case .context: return .clear
        }
    }

    private func baseColor(for kind: DiffLine.Kind) -> NSColor {
        guard isHighlighted else {
            return kind == .context ? theme.secondaryLabel : foreground(for: kind)
        }
        return kind == .context ? theme.secondaryLabel : theme.label
    }

    private func foreground(for kind: DiffLine.Kind) -> NSColor {
        switch kind {
        case .added: return theme.added
        case .removed: return theme.removed
        case .context: return theme.secondaryLabel
        }
    }

    private func sign(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return ""
        }
    }

    private static func cap(_ text: String, at limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
#endif
