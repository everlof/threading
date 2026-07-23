import AppKit

/// Renders a line diff: removed lines on a red wash, added on green, each with a gutter sign.
///
/// One coloured row per line rather than a single attributed string, because a background that
/// runs the full width of the row — not just the width of the text — is what reads as a diff.
/// Long lines wrap rather than scroll; the pane is often narrow, and hiding half a changed line
/// off the right edge is worse than a wrapped one.
///
/// Two callers, one renderer: edit-tool rows feed `[DiffLine]` and draw exactly as they always
/// have, while the review pane feeds `[GitDiffLine]` and gains a line-number column. One
/// number, not two — the new side, falling back to the old for removed lines — because the
/// pane is narrow and a dual gutter spends its width on bookkeeping.
final class DiffView: NSStackView {

    /// What one row draws, whichever model it came from.
    private struct Row {
        let kind: DiffLine.Kind
        let text: String
        let number: String?
        /// Coloured runs into `text`, empty when the file's language is unknown.
        let tokens: [SyntaxToken]
    }

    private let showsNumbers: Bool

    /// Whether long lines wrap to the view's width or run off it. Off puts the diff in a
    /// horizontal scroller (arranged by the caller), so a row is sized to its content rather
    /// than to the pane; the default keeps every existing caller wrapping as it always has.
    private let wraps: Bool

    /// Whether this view resolved a language. It decides the *base* colour of every row, not
    /// just the coloured runs: highlighted code is drawn in label colour and left to the wash
    /// and the gutter to say what happened to it, where an unhighlighted diff still tints the
    /// whole line. Per view, not per row, so one file never mixes the two.
    private let isHighlighted: Bool

    // MARK: - Initialization

    /// An edit tool's diff: unnumbered, capped at the tool-row default. `path` is the file the
    /// tool is editing, which is the only thing that says what language its lines are in.
    convenience init(lines: [DiffLine], path: String? = nil, wraps: Bool = true) {
        let language = path.flatMap { Syntax.language(forPath: $0) }
        let tokens = Self.tokenize(lines.map { ($0.kind, $0.text) }, language: language)

        self.init(
            rows: zip(lines, tokens).map { line, tokens in
                Row(kind: line.kind, text: line.text, number: nil, tokens: tokens)
            },
            displayCap: DiffDefaults.displayCap,
            showsNumbers: false,
            isHighlighted: language != nil,
            wraps: wraps
        )
    }

    /// A git diff's lines: numbered, with the cap owned by the caller — the review pane
    /// budgets lines per file, not per hunk.
    convenience init(gitLines: [GitDiffLine], displayCap: Int, path: String? = nil, wraps: Bool = true) {
        let language = path.flatMap { Syntax.language(forPath: $0) }
        // Tokens index into the *capped* text, so the cap is applied before they are found.
        let texts = gitLines.map { Self.cappedText($0.text) }
        let tokens = Self.tokenize(zip(gitLines, texts).map { ($0.kind, $1) }, language: language)

        self.init(
            rows: zip(zip(gitLines, texts), tokens).map { pair, tokens in
                Row(
                    kind: pair.0.kind,
                    text: pair.1,
                    number: Self.number(for: pair.0),
                    tokens: tokens
                )
            },
            displayCap: displayCap,
            showsNumbers: true,
            isHighlighted: language != nil,
            wraps: wraps
        )
    }

    private init(rows: [Row], displayCap: Int, showsNumbers: Bool, isHighlighted: Bool, wraps: Bool) {
        self.showsNumbers = showsNumbers
        self.isHighlighted = isHighlighted
        self.wraps = wraps
        super.init(frame: .zero)

        orientation = .vertical
        alignment = .leading
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false

        let shown = rows.prefix(max(displayCap, 0))
        for row in shown {
            let view = makeRow(row)
            addArrangedSubview(view)
            view.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            // Pinning a row's trailing to the view's is what makes it wrap to the pane; without
            // it the row is as wide as its longest line and the caller's scroller reveals it.
            if wraps {
                view.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            }
        }

        if rows.count > shown.count {
            let more = makeNote("… \(rows.count - shown.count) more lines")
            addArrangedSubview(more)
            more.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            if wraps {
                more.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Rows

    private func makeRow(_ row: Row) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.applyLayerBackground(background(for: row.kind))

        let gutter = NSTextField(labelWithString: sign(for: row.kind))
        gutter.font = font()
        gutter.textColor = foreground(for: row.kind)
        gutter.alignment = .center
        gutter.translatesAutoresizingMaskIntoConstraints = false

        let string = row.text.isEmpty ? " " : row.text
        let text = wraps
            ? NSTextField(wrappingLabelWithString: string)
            : NSTextField(labelWithString: string)
        text.font = font()
        text.textColor = baseColor(for: row.kind)
        text.isSelectable = true
        text.translatesAutoresizingMaskIntoConstraints = false
        if wraps {
            text.lineBreakMode = .byCharWrapping
            text.maximumNumberOfLines = 0
        } else {
            // Sized to its own content and never squeezed, so the row's width is the line's and
            // the horizontal scroller has something to reveal.
            text.lineBreakMode = .byClipping
            text.usesSingleLineMode = true
            text.maximumNumberOfLines = 1
            text.setContentHuggingPriority(.required, for: .horizontal)
            text.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        if !row.tokens.isEmpty {
            text.attributedStringValue = attributed(row)
        }

        view.addSubview(gutter)
        view.addSubview(text)

        var gutterLeading = view.leadingAnchor
        if showsNumbers {
            let number = NSTextField(labelWithString: row.number ?? "")
            number.font = font()
            number.textColor = Design.Text.tertiary
            number.alignment = .right
            number.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(number)

            NSLayoutConstraint.activate([
                number.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                number.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
                number.widthAnchor.constraint(equalToConstant: GitReviewDefaults.lineNumberWidth)
            ])
            gutterLeading = number.trailingAnchor
        }

        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: gutterLeading),
            gutter.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
            gutter.widthAnchor.constraint(equalToConstant: DiffDefaults.gutterWidth),

            text.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: Design.Spacing.tight),
            text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.tight),
            text.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
            text.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -1)
        ])

        return view
    }

    private func makeNote(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = font()
        label.textColor = Design.Text.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Highlighting

    /// Tokenizes a whole diff, carrying block-comment state down each side separately.
    ///
    /// A diff interleaves the two versions of a file, so one running state would let a `/*`
    /// deleted from the old side comment out the new side's lines. Context lines belong to
    /// both and advance both.
    private static func tokenize(
        _ lines: [(DiffLine.Kind, String)],
        language: SyntaxLanguage?
    ) -> [[SyntaxToken]] {
        guard let language else { return Array(repeating: [], count: lines.count) }

        var newSide = Syntax.State()
        var oldSide = Syntax.State()

        return lines.map { kind, text in
            switch kind {
            case .added:
                return Syntax.tokens(in: text, language: language, state: &newSide)
            case .removed:
                return Syntax.tokens(in: text, language: language, state: &oldSide)
            case .context:
                var state = newSide
                let tokens = Syntax.tokens(in: text, language: language, state: &state)
                newSide = state
                oldSide = state
                return tokens
            }
        }
    }

    /// The line drawn as code: label colour underneath, the tokens' hues over it. The wrapping
    /// mode has to be restated, since an attributed value replaces the field's own paragraph
    /// style along with its text.
    private func attributed(_ row: Row) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // An attributed value carries its own paragraph style, so the wrap decision has to be
        // restated here or the field reverts to wrapping.
        paragraph.lineBreakMode = wraps ? .byCharWrapping : .byClipping

        let string = NSMutableAttributedString(string: row.text, attributes: [
            .font: font(),
            .foregroundColor: baseColor(for: row.kind),
            .paragraphStyle: paragraph
        ])

        for token in row.tokens {
            string.addAttribute(
                .foregroundColor,
                value: color(for: token.role),
                range: NSRange(token.range, in: row.text)
            )
        }
        return string
    }

    private func color(for role: SyntaxRole) -> NSColor {
        switch role {
        case .keyword: return Design.Syntax.keyword
        case .type: return Design.Syntax.type
        case .string: return Design.Syntax.string
        case .number: return Design.Syntax.number
        case .comment: return Design.Syntax.comment
        }
    }

    // MARK: - Style

    /// The new-side number names where the line lives now; a removed line only has an old home.
    private static func number(for line: GitDiffLine) -> String? {
        (line.newNumber ?? line.oldNumber).map(String.init)
    }

    /// A minified single-line source would wrap for screens; it is cut instead.
    private static func cappedText(_ text: String) -> String {
        guard text.count > GitReviewDefaults.lineCharacterCap else { return text }
        return text.prefix(GitReviewDefaults.lineCharacterCap) + "…"
    }

    private func font() -> NSFont {
        Design.Typography.code()
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
        case .added: return Design.Diff.added.withAlphaComponent(DiffDefaults.addedAlpha)
        case .removed: return Design.Diff.removed.withAlphaComponent(DiffDefaults.removedAlpha)
        case .context: return .clear
        }
    }

    /// What a row's text is drawn in before any token colours it. Highlighted code reads as
    /// code; an unhighlighted diff keeps tinting the whole line, which is what every caller
    /// drew before there was a highlighter.
    private func baseColor(for kind: DiffLine.Kind) -> NSColor {
        guard isHighlighted else {
            return kind == .context ? Design.Text.secondary : foreground(for: kind)
        }
        return kind == .context ? Design.Text.secondary : Design.Text.label
    }

    private func foreground(for kind: DiffLine.Kind) -> NSColor {
        switch kind {
        case .added: return Design.Diff.added
        case .removed: return Design.Diff.removed
        case .context: return Design.Text.secondary
        }
    }
}
