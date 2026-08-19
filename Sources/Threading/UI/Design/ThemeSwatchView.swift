import AppKit

/// One colour in a theme: a rounded chip that opens the colour picker when the theme allows
/// editing, and simply shows the colour when it does not.
///
/// It lives in `UI/Design/` because of what it *contains*: `NSColorWell` is the one stock control
/// the app still creates, and it is unavoidable — the thing it opens is the system colour panel,
/// which no amount of drawing replaces. The well is invisible here, laid over the chip purely to
/// catch the click, so what the page shows is the app's own swatch. This is a genuine system-panel
/// boundary; ordinary dropdowns do not need the exception and use `ThemedMenuPresenter`.
///
/// The ring matters more than it looks like it should. A theme's `black` on the settings
/// page's own dark card is very nearly the same colour as the card, so an unringed swatch
/// reads as a hole rather than as a value — and the ring is drawn by the layer's border,
/// which Core Animation paints *above* sublayers, so it survives the colour well filling the
/// chip underneath it.
final class ThemeSwatchView: NSView, ThemedComponent, SystemChromeBoundary {

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
        applySurface(
            fill: .clear,
            radius: .fixed(ThemeEditorLayout.swatchRadius),
            border: Design.Surface.border,
            clipsContent: true
        )

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
        // Through applySurface so the recorded surface *is* this colour: otherwise the app-theme
        // refresh sweep re-applies the `.clear` recorded at init and wipes every swatch to
        // transparent — which emptied the whole COLORS grid on a live theme switch.
        // `clipsContent` is restated because the surface owns it: `applySurface` assigns
        // `masksToBounds` on every call, so a swatch that clipped the well at init and then
        // took a colour would let the well's square corners back out past the chip's.
        applySurface(
            fill: newColor,
            radius: .fixed(ThemeEditorLayout.swatchRadius),
            border: Design.Surface.border,
            clipsContent: true
        )
        if well.color != newColor { well.color = newColor }
        toolTip = "\(name) · \(newColor.hexString)"
    }

    override func updateLayer() {
        super.updateLayer()
        // Border colours are resolved at assignment, so they do not follow an appearance change.
        applyLayerBorder(Design.Surface.border)
    }

    @objc private func wellChanged() {
        color = well.color
        applyLayerBackground(well.color)
        onChange?(well.color)
    }

    func permitsSystemChrome(_ view: NSView) -> Bool {
        view is NSColorWell
    }
}
