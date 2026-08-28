import AppKit

// MARK: - Colour Editor

/// The palette of a theme: the four main colours, then the sixteen ANSI colours as a grid.
///
/// Structure is the whole point of this view. The colours were previously a row of pills and
/// two runs of sixteen chips four points apart, which read as one undifferentiated field of
/// circles — the eye could not find `bright blue` in it, and the two ANSI rows did not line up
/// into columns. Here the ANSI colours are a real grid, index-aligned so a colour sits directly
/// above its bright variant, and the four main colours carry their name and hex because those
/// four are the ones a person actually looks up.
final class ThemeColorEditor: NSView {

    // MARK: Properties

    var onChange: ((ThemeColorKey, NSColor) -> Void)?

    private var swatches: [ThemeColorKey: ThemeSwatchView] = [:]
    private var hexLabels: [ThemeColorKey: NSTextField] = [:]

    // MARK: Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let card = SettingsCard(rows: [
            SettingsUI.fullRow(group("Main", mainColors())),
            SettingsUI.fullRow(group("ANSI", ansiGrid()))
        ])

        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Content

    func show(_ theme: TerminalTheme, isEditable: Bool) {
        for (key, swatch) in swatches {
            swatch.setColor(theme[key], name: key.displayName)
            swatch.isEditable = isEditable
            hexLabels[key]?.stringValue = theme[key].hexString
        }
    }

    // MARK: Layout

    private func group(_ title: String, _ content: NSView) -> NSView {
        let stack = NSStackView(views: [SettingsUI.caption(title), content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        // `leading` alignment gives the colour grid its fitting width. Cap that fitting width at
        // the card instead of letting it enlarge the Settings scroll document; the grid's own
        // preferred columns yield evenly when the supported 420-point canvas is narrower.
        content.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor).isActive = true
        return stack
    }

    /// Name above, chip, hex below — the chip is what is being chosen, so it sits between the
    /// two labels rather than under both.
    private func mainColors() -> NSView {
        let columns = ThemeColorKey.main.map { key -> NSView in
            let name = NSTextField(labelWithString: key.displayName)
            name.applyFont(.subheading)
            name.textColor = Design.Text.secondary
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let hex = NSTextField(labelWithString: "")
            hex.applyFont(.compactCode)
            hex.textColor = Design.Text.tertiary
            hexLabels[key] = hex

            let column = NSStackView(views: [name, makeSwatch(key), hex])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Design.Spacing.tight

            // A preferred column, so the five chips sit on a regular pitch. Sized to their own
            // labels they landed wherever "Background" happened to end, and five evenly
            // coloured squares at irregular intervals read as a mistake rather than a row.
            column.translatesAutoresizingMaskIntoConstraints = false
            let preferredWidth = column.widthAnchor.constraint(
                equalToConstant: ThemeEditorLayout.mainColumnWidth
            )
            preferredWidth.priority = ThemeEditorLayout.preferredWidthPriority
            NSLayoutConstraint.activate([
                preferredWidth,
                name.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
                hex.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor)
            ])
            return column
        }

        let row = NSStackView(views: columns)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Design.Spacing.small
        // A narrow page spends the same amount from every role column, preserving the grid
        // instead of arbitrarily crushing whichever label Auto Layout encounters first.
        for column in columns.dropFirst() {
            column.widthAnchor.constraint(equalTo: columns[0].widthAnchor).isActive = true
        }
        return row
    }

    /// Two labelled rows of eight. No column headings: a red chip says "red" better than the
    /// word does, the row labels carry the only distinction the colours cannot make
    /// themselves, and eight headings wide enough for "Magenta" would set the grid's spacing
    /// for it. The full name and hex live in each chip's tooltip.
    ///
    /// Each label stands above its chips. Beside them it consumed another 60 points, making the
    /// grid wider than the 300 points left inside a card on the supported 420-point canvas. The
    /// chips themselves remain eight aligned columns at their measured ten-point pitch; only the
    /// furniture moves out of that horizontal measure.
    private func ansiGrid() -> NSView {
        let rows = [("Normal", ThemeColorKey.normal), ("Bright", ThemeColorKey.bright)]
            .map { title, keys -> NSView in
                let label = NSTextField(labelWithString: title)
                label.applyFont(.subheading)
                label.textColor = Design.Text.secondary

                let chips = NSStackView(views: keys.map(makeSwatch))
                chips.orientation = .horizontal
                chips.spacing = ThemeEditorLayout.swatchGap

                let row = NSStackView(views: [label, chips])
                row.orientation = .vertical
                row.alignment = .leading
                row.spacing = Design.Spacing.tight
                return row
            }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ThemeEditorLayout.swatchGap
        return stack
    }

    private func makeSwatch(_ key: ThemeColorKey) -> ThemeSwatchView {
        let swatch = ThemeSwatchView()
        swatch.onChange = { [weak self] color in
            self?.hexLabels[key]?.stringValue = color.hexString
            self?.onChange?(key, color)
        }
        swatches[key] = swatch
        return swatch
    }
}

// MARK: - Layout

enum ThemeEditorLayout {
    static let swatch: CGFloat = 28
    static let swatchRadius: CGFloat = 7
    /// Ten, not four. At four the chips merged into one band of colour and the two ANSI rows
    /// read as a single smear rather than as a grid with columns.
    static let swatchGap: CGFloat = Design.Spacing.medium
    /// Grid measures are wishes, below ordinary content compression for the same reason as the
    /// shared Settings controls: the scroll document must never grow past its clip view.
    static let preferredWidthPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultHigh.rawValue - 1
    )
    static let hexFontSize: CGFloat = 10
    /// Wide enough for "Background", so every main colour keeps the same pitch — and no wider,
    /// since five of these are what decides how narrow the palette card can go before the ANSI
    /// grid does.
    ///
    /// It was 84 while there were four. "Bold Text" made a fifth, and five at that pitch came to
    /// 468 points inside a pane that can be 420, which this card overflows rather than wraps:
    /// `ThemeSettingsRenderTests.testPaletteFitsTheNarrowSettingsPane` is what said so. 72 is
    /// the widest pitch that keeps five inside the narrow pane, and "Background" sets its floor
    /// at roughly 68.
    static let mainColumnWidth: CGFloat = 72
}
