import AppKit

/// A sample of terminal output drawn in a theme's own colours.
///
/// Every colour a theme carries is chosen for how it looks *against the others*, so the
/// preview shows them in the arrangement they are actually used in — a prompt, a listing, a
/// warning, an error — rather than as a legend. Two of the four main colours have no reading
/// at all outside a running terminal, so both are staged deliberately: a word carrying the
/// selection fill, and a block cursor on the last line.
final class ThemePreviewView: NSView {

    // MARK: - Layout

    private enum Layout {
        static let height: CGFloat = 132
        static let fontSize: CGFloat = 11.5
        static let lineSpacing: CGFloat = 3
    }

    // MARK: - Properties

    private let label = NSTextField(labelWithString: "")

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: .clear, radius: .panel, border: Design.Surface.border)
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 0
        label.cell?.wraps = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Layout.height),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.inset),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Design.Spacing.inset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    func show(_ theme: TerminalTheme?) {
        guard let theme else {
            // Through applySurface, not a bare `layer.backgroundColor`: the app-theme refresh
            // sweep re-applies whatever surface was *recorded*, so a direct assignment here is
            // overwritten by the `.clear` this view recorded at init the next time the app
            // theme changes — which left the preview transparent and its white text invisible.
            applySurface(fill: Design.Surface.ground, radius: .panel, border: Design.Surface.border)
            label.stringValue = ""
            return
        }

        applySurface(fill: theme.background, radius: .panel, border: Design.Surface.border)
        label.attributedStringValue = sample(for: theme)
    }

    /// What the card is currently drawing.
    ///
    /// A seam for the tests that review the sample's own colours: the roles it stages have no
    /// reading outside a running terminal, so the alternative is a second copy of `sample` in
    /// the test and an assertion that proves nothing about what was installed.
    var renderedSample: NSAttributedString {
        label.attributedStringValue
    }

    override func updateLayer() {
        super.updateLayer()
        applyLayerBorder(Design.Surface.border)
    }

    // MARK: - Sample

    private func sample(for theme: TerminalTheme) -> NSAttributedString {
        let font = Design.Typography.previewCode()
        // Bold text is a weight *and* a colour, and the sample has to show both: drawn in the
        // regular face the role reads as an arbitrary tint on one word, and drawn in the body
        // colour the editor's "Bold Text" well changes nothing anybody can see.
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Layout.lineSpacing

        let output = NSMutableAttributedString()

        func append(
            _ text: String,
            _ color: NSColor,
            background: NSColor? = nil,
            face: NSFont? = nil
        ) {
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: face ?? font,
                .paragraphStyle: paragraph
            ]
            attributes[.backgroundColor] = background
            output.append(NSAttributedString(string: text, attributes: attributes))
        }

        append("user", theme.brightGreen)
        append("@", theme.foreground)
        append("mac", theme.green)
        append(" ", theme.foreground)
        append("~/projects", theme.brightBlue)
        append(" % ", theme.brightBlack)
        // The command the user typed, which is what an agent's headings look like too: SGR 1
        // over the default foreground, so it is drawn in the palette's bold text.
        append("git status\n", theme.boldForeground, face: boldFont)

        append("On branch ", theme.foreground)
        // The selection is staged on a word the eye is already reading, so it shows how text
        // survives the fill rather than how the fill looks on its own.
        append("main", theme.foreground, background: theme.selection)
        append(" · ", theme.brightBlack)
        append("2 modified", theme.yellow)
        append(", ", theme.foreground)
        append("1 untracked\n", theme.cyan)

        append("error", theme.brightRed)
        append(": could not read ", theme.foreground)
        append("config.toml\n", theme.magenta)

        append("warning", theme.brightYellow)
        append(": ", theme.foreground)
        append("3 issues", theme.yellow)
        append(" in ", theme.foreground)
        append("src/main.rs\n", theme.brightCyan)

        append("✓ build succeeded", theme.brightGreen)
        append("  1.24s\n", theme.brightBlack)

        append("% ", theme.brightBlack)
        // A block cursor: the caret colour as a fill, with the ground showing through it.
        append(" ", theme.background, background: theme.cursor)

        return output
    }
}
