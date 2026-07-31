import AppKit

// MARK: - Where a query landed

/// Where a query landed inside one string.
///
/// This is deliberately *not* "does this item match" — that question belongs to whoever owns the
/// list, and the settings catalogue answers it with two different rules on purpose. This answers
/// the presentation half: given a string that is already being shown, which of its characters
/// does the reader's query account for.
enum SearchTextMatch {

    /// How a query is compared, everywhere. One spelling of "contains", so a page that a filter
    /// kept cannot then be shown with nothing highlighted in it.
    ///
    /// Diacritic- and width-insensitive as well as case-insensitive: a reader searching `motion`
    /// should find `Motión` and a full-width transcript id should answer to the id as typed.
    static let comparisonOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive
    ]

    /// Every run of `text` that a token of `query` accounts for, in reading order and with
    /// overlaps merged.
    ///
    /// Two rules, and the second is the one worth knowing about:
    ///
    /// 1. Each whitespace-separated token is found everywhere it occurs. A two-word query lights
    ///    up both words rather than nothing, which is what a reader typing a phrase expects even
    ///    though the two words are nowhere adjacent.
    /// 2. **A token that contains the whole string matches all of it.** Pasting a full session id
    ///    into the import search is exactly this: the row shows the id's first characters, every
    ///    one of which the reader did type, and highlighting nothing there would say the row was
    ///    found for some other reason.
    static func ranges(in text: String, matching query: String) -> [Range<String.Index>] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !text.isEmpty, !tokens.isEmpty else { return [] }

        var found: [Range<String.Index>] = []
        for token in tokens {
            guard token.count <= text.count else {
                if token.range(of: text, options: comparisonOptions) != nil {
                    return [text.startIndex..<text.endIndex]
                }
                continue
            }
            occurrences(of: token, in: text, into: &found)
        }
        return merged(found)
    }

    // MARK: - Private Methods

    private static func occurrences(
        of token: String,
        in text: String,
        into found: inout [Range<String.Index>]
    ) {
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(
                  of: token,
                  options: comparisonOptions,
                  range: start..<text.endIndex
              ) {
            found.append(range)
            // An empty match cannot happen for a non-empty token, but a normalising comparison
            // is the framework's to define: stepping past the start rather than to the end is
            // what keeps this loop finite whatever it decides.
            start = range.isEmpty ? text.index(after: range.lowerBound) : range.upperBound
        }
    }

    /// Overlapping and touching runs become one. Two tokens landing on neighbouring characters
    /// should read as one found word, not as two grounds with a seam down the middle.
    private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<String.Index>] = []
        for range in sorted {
            guard let last = result.last, range.lowerBound <= last.upperBound else {
                result.append(range)
                continue
            }
            result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        }
        return result
    }
}

// MARK: - Search Match Label

/// A line of text that says which part of itself a search found.
///
/// **Highlighting is two signals, not one.** The matched run is set in its role's emphasized
/// weight *and* given a tinted ground. Weight alone is what survives Differentiate Without
/// Colour and a monochrome print of a screenshot; the ground is what makes a match findable by
/// glance down twenty rows, which weight on its own is not. Either signal alone has a reader it
/// fails.
///
/// **It rebuilds itself on a theme change**, which is the whole reason this is a component and
/// not a call to `NSTextField.label(attributed:)` at each site. An attributed string freezes its
/// fonts and its inks; `AppThemeRefresh`'s sweep re-resolves a *recorded role* on a label and a
/// recorded surface on a layer, and can reach inside neither. `ThemedTextField`'s placeholder
/// carries the same wiring for the same reason. The ground is a dynamic colour, so Increase
/// Contrast and an appearance flip resolve at draw time without any of this running.
///
/// The label truncates rather than wraps, and yields its width before its neighbours do: it is
/// used inside rows that also carry a control, and a long match should shorten the sentence
/// rather than push the way into the page off the row.
@MainActor
final class SearchMatchLabel: NSView, ThemedComponent {

    // MARK: - Properties

    private let role: Design.FontRole
    private let surface: Design.Typography.FontSurface
    private let ink: () -> NSColor

    private var text = ""
    private var query = ""
    private var field: NSTextField?
    private let themeEvents = AppEventObservations()

    // MARK: - Initialization

    /// - Parameters:
    ///   - role: The type the line is set in. Its `emphasized` counterpart draws the match.
    ///   - ink: The resting colour, held as a rule rather than a value so a rebuild after a
    ///     theme change resolves the caller's *decision* again rather than its stale answer.
    init(
        role: Design.FontRole = .body,
        in surface: Design.Typography.FontSurface = .chrome,
        ink: @escaping () -> NSColor = { Design.Text.label }
    ) {
        self.role = role
        self.surface = surface
        self.ink = ink
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        // Nothing to re-resolve until something has been shown, and building a field for an
        // empty string is the measured-empty trap `NSTextField.label(attributed:)` documents.
        themeEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            guard self?.field != nil else { return }
            self?.rebuild()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Shows `text`, lifting out whatever `query` accounts for. An empty query is not a search:
    /// the line is then exactly the plain label it would otherwise have been.
    func show(_ text: String, matching query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != self.text || query != self.query || field == nil else { return }
        self.text = text
        self.query = query
        rebuild()
    }

    /// The runs currently drawn as found. The attributed string is the truth and a test can read
    /// it, but "which words are lit up" is the question every caller's test actually has.
    var markedTextForTesting: [String] {
        SearchTextMatch.ranges(in: text, matching: query).map { String(text[$0]) }
    }

    // MARK: - Private Methods

    private func rebuild() {
        let content = attributedText()
        setAccessibilityValue(text)

        guard let field else {
            let field = NSTextField.label(attributed: content)
            // Truncation rather than wrapping, and the first view in its row to give up width:
            // see the type's note. `label(attributed:)` has already turned single-line mode on,
            // which is what gives the field a definite width to yield in the first place.
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // One element, not two: the container carries the accessible value so the same view
            // answers whether it is read as a row's label or reached on its own.
            field.setAccessibilityElement(false)
            addSubview(field)
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: topAnchor),
                field.bottomAnchor.constraint(equalTo: bottomAnchor),
                field.leadingAnchor.constraint(equalTo: leadingAnchor),
                field.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
            self.field = field
            return
        }

        // The font is assigned beside the string for the reason `label(attributed:)` documents:
        // the field lays its single line out on the *field's* metrics, not the string's.
        field.font = content.tallestFont ?? field.font
        field.attributedStringValue = content
        field.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
    }

    private func attributedText() -> NSAttributedString {
        let content = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: role.resolved(in: surface),
                .foregroundColor: ink()
            ]
        )

        let emphasis = role.emphasized.resolved(in: surface)
        let ground = Design.Surface.searchMatch
        for range in SearchTextMatch.ranges(in: text, matching: query) {
            content.addAttributes(
                [.font: emphasis, .backgroundColor: ground],
                range: NSRange(range, in: text)
            )
        }
        return content
    }
}
