import AppKit

/// One press, and the other ways to take it, welded onto a single plate.
///
/// The pair this exists for is the pane header's Open In control: the target app's own icon opens
/// the checkout, and the chevron beside it chooses a different app. They were two
/// `ThemedIconButton`s in a `ToolbarButtonGroupView`, which is right for the session's actions —
/// four buttons acting on four different things — and wrong here, because these two act on
/// **one**. Spaced as siblings they read as an icon with an unrelated chevron floating beside it,
/// and hover made the split literal: each half raised its own rounded rect, so pointing at the
/// control cut it in two, with a seam down the middle that nothing in the design put there.
///
/// So the plate is drawn here, once, and the halves draw no surface of their own — see
/// `ThemedIconButton.drawsSurface`. A raised half is filled **inside** the plate's silhouette:
/// clipped to it, so the outer corners stay the plate's and the seam is a straight edge that
/// exists only while the pointer is on one side of it. Nothing is drawn between the halves at
/// rest, because the join *is* the control, and a rule down the middle would argue with it.
///
/// The halves are deliberately not the same width (`Design.Size.splitMenuWidth`): a press is the
/// whole point of the control and the chevron is the day the answer is different, so the two are
/// not offered as equals.
///
/// The titled counterpart on the pane's own ground is `SplitButtonView`, and the rule for which
/// pairs may weld at all — emphasis decides; a primary keeps its chevron beside it — is stated
/// there.
final class SplitIconButtonView: BackdropOverlay {

    // MARK: - Properties

    /// The press that acts — the reason the control is in the header at all.
    let action: ThemedIconButton

    /// The chevron that offers the other choices. Its `presentsMenu` and press belong to the
    /// caller; what belongs here is only that it is drawn as half of one thing.
    ///
    /// Named for the mark rather than for what it opens, because `NSView.menu` is already a
    /// property and a half of this control is not one.
    let chevron: ThemedIconButton

    /// How far inside the plate a raised half stops, so the plate's own edge survives underneath
    /// it rather than being painted over on three sides — which would leave a raised half looking
    /// like a tile sitting *on* the control instead of part of it.
    ///
    /// A bevelled theme's edge is its whole construction and wider than a hairline, so the inset
    /// is asked of the material rather than assumed to be one point.
    private var edgeInset: CGFloat {
        AppThemePalette.current.material.bevel?.width ?? Design.Radius.controlBorder
    }

    // MARK: - Initialization

    init(action: ThemedIconButton, chevron: ThemedIconButton) {
        self.action = action
        self.chevron = chevron
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Ink

    /// The plate is read from `ink` at draw time, so a theme or backdrop change is one redraw
    /// with nothing recorded to go stale.
    override func applyInk(_ ink: Design.Ink) {
        needsDisplay = true
    }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        for button in [action, chevron] {
            // The surface belongs to the plate. A half that also drew one would be the seam back
            // again, one hairline further in.
            button.drawsSurface = false
            button.surfaceStateDidChange = { [weak self] in self?.needsDisplay = true }
            addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        // Flush, with no spacing to state: the two halves share an edge, which is the whole
        // difference between this and a group of buttons.
        NSLayoutConstraint.activate([
            action.leadingAnchor.constraint(equalTo: leadingAnchor),
            chevron.leadingAnchor.constraint(equalTo: action.trailingAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let shape = ThemedSurface.draw(
            bounds,
            fill: ink.surface,
            border: ink.border,
            radius: Design.Radius.control(fitting: bounds.size)
        )

        guard let raised = [action, chevron].first(where: \.isRaised) else { return }

        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        // Clipped to the plate rather than rounded per half: the outer corners are the plate's
        // and the inner edge is straight, which is what makes a raised half read as part of the
        // control and not as a second control inside it.
        shape.inset(by: edgeInset).path.addClip()
        ink.surfaceHover.setFill()
        raised.frame.fill()
    }

    // MARK: - Accessibility

    /// The halves are the elements — each is a button with its own name, action and tooltip.
    /// Announcing the plate as well would report one control as three objects.
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}
