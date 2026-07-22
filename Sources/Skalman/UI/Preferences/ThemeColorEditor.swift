import AppKit

// MARK: - Swatch

/// One colour in a theme: a rounded chip that opens the colour picker when the theme allows
/// editing, and simply shows the colour when it does not.
///
/// The ring matters more than it looks like it should. A theme's `black` on the settings
/// page's own dark card is very nearly the same colour as the card, so an unringed swatch
/// reads as a hole rather than as a value — and the ring is drawn by the layer's border,
/// which Core Animation paints *above* sublayers, so it survives the colour well filling the
/// chip underneath it.
final class ThemeSwatchView: NSView {

    // MARK: Properties

    private let well = NSColorWell(style: .minimal)

    var onChange: ((NSColor) -> Void)?

    private(set) var color: NSColor = .black

    /// Whether the chip opens a picker. A built-in theme shows its colours and edits none of
    /// them — and it shows them at full strength rather than disabling the wells, since a
    /// dimmed swatch misreports the palette it is there to display.
    var isEditable: Bool = false {
        didSet { well.isHidden = !isEditable }
    }

    // MARK: Initialization

    init(size: CGFloat = ThemeEditorLayout.swatch) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: .clear, radius: ThemeEditorLayout.swatchRadius, border: Design.Surface.border)
        layer?.masksToBounds = true

        well.translatesAutoresizingMaskIntoConstraints = false
        well.target = self
        well.action = #selector(wellChanged)
        well.isHidden = true
        addSubview(well)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.bottomAnchor.constraint(equalTo: bottomAnchor),
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Content

    /// Sets the colour shown, without disturbing an edit in progress.
    ///
    /// The picker is shared and stays bound to whichever well opened it, so re-assigning a
    /// colour the well already holds would fight the panel the user is dragging in.
    func setColor(_ newColor: NSColor, name: String) {
        color = newColor
        layer?.backgroundColor = newColor.cgColor
        if well.color != newColor { well.color = newColor }
        toolTip = "\(name) · \(newColor.hexString)"
    }

    override func updateLayer() {
        super.updateLayer()
        // Border colours are resolved at assignment, so they do not follow an appearance change.
        layer?.borderColor = Design.Surface.border.cgColor
    }

    @objc private func wellChanged() {
        color = well.color
        layer?.backgroundColor = well.color.cgColor
        onChange?(well.color)
    }
}

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
        return stack
    }

    /// Name above, chip, hex below — the chip is what is being chosen, so it sits between the
    /// two labels rather than under both.
    private func mainColors() -> NSView {
        let columns = ThemeColorKey.main.map { key -> NSView in
            let name = NSTextField(labelWithString: key.displayName)
            name.font = Design.Typography.subheading()
            name.textColor = Design.Text.secondary

            let hex = NSTextField(labelWithString: "")
            hex.font = .monospacedSystemFont(ofSize: ThemeEditorLayout.hexFontSize, weight: .regular)
            hex.textColor = Design.Text.tertiary
            hexLabels[key] = hex

            let column = NSStackView(views: [name, makeSwatch(key), hex])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Design.Spacing.tight

            // A fixed column, so the four chips sit on a regular pitch. Sized to their own
            // labels they landed wherever "Background" happened to end, and four evenly
            // coloured squares at irregular intervals read as a mistake rather than a row.
            column.translatesAutoresizingMaskIntoConstraints = false
            column.widthAnchor.constraint(equalToConstant: ThemeEditorLayout.mainColumnWidth)
                .isActive = true
            return column
        }

        let row = NSStackView(views: columns)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Design.Spacing.small
        return row
    }

    /// Two labelled rows of eight. No column headings: a red chip says "red" better than the
    /// word does, the row labels carry the only distinction the colours cannot make
    /// themselves, and eight headings wide enough for "Magenta" would set the grid's spacing
    /// for it. The full name and hex live in each chip's tooltip.
    private func ansiGrid() -> NSView {
        let rows = [("Normal", ThemeColorKey.normal), ("Bright", ThemeColorKey.bright)]
            .map { title, keys -> NSView in
                let label = NSTextField(labelWithString: title)
                label.font = Design.Typography.subheading()
                label.textColor = Design.Text.secondary
                label.translatesAutoresizingMaskIntoConstraints = false
                label.widthAnchor.constraint(equalToConstant: ThemeEditorLayout.rowLabelWidth)
                    .isActive = true

                let chips = NSStackView(views: keys.map(makeSwatch))
                chips.orientation = .horizontal
                chips.spacing = ThemeEditorLayout.swatchGap

                let row = NSStackView(views: [label, chips])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = Design.Spacing.small
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
    static let rowLabelWidth: CGFloat = 52
    static let hexFontSize: CGFloat = 10
    /// Wide enough for "Background", so every main colour keeps the same pitch — and no wider,
    /// since four of these are what decides how narrow the palette card can go before the ANSI
    /// grid does.
    static let mainColumnWidth: CGFloat = 84
}
