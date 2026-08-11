import AppKit

/// What a control adopts to be welded into a split plate: it stops drawing its own surface,
/// answers whether its half should be raised, and reports when the plate must redraw.
///
/// The members already existed on `ThemedIconButton` for `SplitIconButtonView`; the protocol
/// names them so a plate can hold a titled press and an icon chevron as halves of one thing
/// without knowing which is which.
@MainActor
protocol SplitControlHalf where Self: NSView {
    var drawsSurface: Bool { get set }
    var isRaised: Bool { get }
    var surfaceStateDidChange: (() -> Void)? { get set }
}

extension ThemedIconButton: SplitControlHalf {}
extension ThemedButton: SplitControlHalf {}

/// A titled press, and the other ways to take it, welded onto a single plate — the attachments
/// footer's Copy Path with its menu chevron.
///
/// `SplitIconButtonView` states the construction — one silhouette, halves that draw no surface
/// of their own, a raise filled *inside* the plate — for the toolbar's icon pair, on the window
/// backdrop. This is the same control on the pane's own ground for a press with a title: the
/// plate draws exactly what a secondary `ThemedButton` would (its material's resting fill,
/// hairline and depth), so a welded pair reads as one member of the button family rather than
/// as a new kind of thing.
///
/// **Welding follows emphasis, not the pairing.** Two neutral secondaries can share a plate,
/// because nothing is drawn between them at rest. An accent-filled primary cannot: the join
/// against a neutral chevron would be a permanent colour seam, which is the one thing this
/// construction exists to remove. That is why the composer's Start Session keeps its clock
/// *beside* it (`ThemedIconButton.Target.besidePrimary`) — the spread form is the primary's
/// ranking, not a missing weld.
///
/// The halves are deliberately not the same width (`Design.Size.splitMenuWidth`), for the
/// ranking both split plates draw: the press is the point of the control and the chevron is
/// the day the answer is different, so the two are not offered as equals.
final class SplitButtonView: NSView, ThemedComponent {

    // MARK: - Properties

    /// The press that acts — the reason the control is in the band at all. Its title stays the
    /// caller's to set and re-set: a "last used wins" press is retitled by its own menu.
    let action: ThemedButton

    /// The chevron that offers the other choices. Its `presentsMenu` and press belong to the
    /// caller; what belongs here is only that it is drawn as half of one thing.
    let chevron: ThemedIconButton

    private var themeRedraw: ThemeRedraw?

    /// How far inside the plate a raised half stops, so the plate's own edge survives underneath
    /// it — the same measure `SplitIconButtonView` takes from the material.
    private var edgeInset: CGFloat {
        AppThemePalette.current.material.bevel?.width ?? Design.Radius.controlBorder
    }

    private var halves: [any SplitControlHalf] { [action, chevron] }

    // MARK: - Initialization

    init(action: ThemedButton, chevron: ThemedIconButton) {
        // Welding follows emphasis — see the type's documentation. A primary press against a
        // neutral chevron would hold the permanent seam this plate exists to remove.
        assert(
            action.emphasis != .primary,
            "a primary press cannot share a plate — keep the pair beside each other instead"
        )
        self.action = action
        self.chevron = chevron
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        // The plate carries the pair's depth (`applyThemeControlGlow`), which needs a layer to
        // shadow; the halves must not carry one each, or the join casts a line of its own.
        wantsLayer = true
        themeRedraw = ThemeRedraw(self)

        for half in halves {
            // Stated for both halves even though the icon button already states its own: the
            // titled button leaves it to whoever places it, and an autoresizing half fights
            // the plate's pins with constraints made from its empty frame.
            half.translatesAutoresizingMaskIntoConstraints = false
            // The surface belongs to the plate. A half that also drew one would be the seam back
            // again, one hairline further in.
            half.drawsSurface = false
            half.surfaceStateDidChange = { [weak self] in self?.needsDisplay = true }
            addSubview(half)
            NSLayoutConstraint.activate([
                half.topAnchor.constraint(equalTo: topAnchor),
                half.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        // Flush, with no spacing to state: the two halves share an edge, which is the whole
        // difference between this and a pair of siblings. The height is the chevron's stated
        // base (`Target.titledSplitMenu`), which the press adopts by being pinned to the plate.
        NSLayoutConstraint.activate([
            action.leadingAnchor.constraint(equalTo: leadingAnchor),
            chevron.leadingAnchor.constraint(equalTo: action.trailingAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    // MARK: - Drawing

    /// The plate reads its material at draw time, so a theme switch is one redraw with nothing
    /// recorded to go stale — `ThemeRedraw` asks, the material answers.
    override func draw(_ dirtyRect: NSRect) {
        let material = AppThemePalette.current.material(for: effectiveAppearance)
        let style = material.buttonStyle
        let corner = Design.Radius.control(fitting: bounds.size)

        // The resting secondary depth, exactly as `ThemedButton` states it — a welded pair must
        // not read flatter than the buttons it stands with. Collapsed under the pointer only
        // where the material says a lifted control sets down when reached for.
        let shadow: AppTheme.Glow?
        switch style.secondaryShadow {
        case .control: shadow = material.controlGlow
        case .panel: shadow = material.glow
        case .none: shadow = nil
        }
        let collapses = style.collapseShadowOnHover && halves.contains { $0.isRaised }
        applyThemeControlGlow(collapses ? nil : shadow, radius: corner)

        let shape = ThemedSurface.draw(
            bounds,
            fill: AppThemePalette.color(style.secondaryRole),
            border: Design.Surface.border,
            radius: corner
        )

        guard let raised = halves.first(where: { $0.isRaised }) else { return }

        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        // Clipped to the plate rather than rounded per half: the outer corners are the plate's
        // and the inner edge is straight, which is what makes a raised half read as part of the
        // control and not as a second control inside it.
        shape.inset(by: edgeInset).path.addClip()
        AppThemePalette.color(style.secondaryHoverRole).setFill()
        raised.frame.fill()
    }

    /// Under the System theme the material's roles are dynamic colours, so a light/dark flip
    /// changes what they resolve to while the theme object stays exactly as it was.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Accessibility

    /// The halves are the elements — each is a button with its own name, action and tooltip.
    /// Announcing the plate as well would report one control as three objects.
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}
