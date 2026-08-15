import AppKit

// MARK: - Sidebar Hover Row View

/// Row container that paints a soft highlight while the pointer is over it.
///
/// Hover fills the gap between "nothing" and "selected", so rows read as clickable before they
/// are clicked. Group headings do not get one — they only expand from their disclosure, and a
/// highlight would promise more.
///
/// The **selection** under it is drawn here too, under every theme and at an inset that closes
/// as the column narrows (`SidebarDensityAdopting`) — the one thing AppKit's own capsule could
/// not do. See `drawSelection`.
///
/// The **selected** session's row can additionally wear the agent-activity beam — the same
/// breathing ring the composer has, on the selection capsule's own silhouette — while its
/// session loads or works. The sidebar controller stamps it (`setActivityBeam`), because only
/// the controller knows which row is the selected session and what that session is doing; the
/// ring is what keeps that row's activity visible while the pointer swaps its status mark for
/// the archive button, and it is bounded at one live host because only one row is selected.
///
/// A `ThemedComponent` for the reason `ThemeBoundaryAudit` states about rows: a row that draws
/// theme colours has to be distinguishable from the plain one AppKit builds, which draws the
/// system's. This is the sidebar's louder answer to the question `ThemedTableRowView` answers
/// everywhere else.
final class SidebarHoverRowView: NSTableRowView, ThemedComponent, SidebarDensityAdopting {

    // MARK: - Properties

    /// The gutters the column's current width states — read for `selectionInsetX`, which is the
    /// only one of them this view draws. `.relaxed` until a controller says otherwise, which is
    /// the right answer for the lists that never fit themselves to a divider.
    private var density = SidebarDensity.relaxed

    /// A heading keeps the class for the rule below without inheriting the wash: it only
    /// expands from its disclosure, and a highlight would promise more. Set at creation,
    /// before any tracking area exists, so there is no lit state to unwind.
    var isHoverEnabled = true

    /// Draws the compact tree's rule across the row's top — the line that says a new group
    /// begins here, standing in for the indentation the compact tree gave up. Stamped by the
    /// controller, which is the only thing that knows whether this row opens a group and
    /// whether another group stands above it.
    var showsGroupRule = false {
        didSet {
            guard showsGroupRule != oldValue else { return }
            needsDisplay = true
        }
    }

    /// A demotion is believed only if the list this row is in asks for one — which is what keeps
    /// the accent under the row a click just selected, after that click hands focus to the
    /// session it opened. This is the reported defect's last line of defence; see
    /// `ListSelectionStrength` for the rule and why the draw was the wrong place for it.
    override var isEmphasized: Bool {
        get { super.isEmphasized }
        set { super.isEmphasized = listSelectionStrength(insteadOf: newValue) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        adoptListSelectionStrength()
    }

    private var trackingArea: NSTrackingArea?

    /// Whether the row is drawing its hover wash. Readable so a row that declines the pointer can
    /// be asserted where it declines it, rather than by reading a picture for ink that is 6% of
    /// the ground it lies on.
    private(set) var isMouseInside = false {
        didSet { needsDisplay = true }
    }

    /// The row's activity ring; exists only after this row has actually been told to wear one,
    /// so a list of rows carries no retained SwiftUI hosts for a state almost none of them has.
    private var activityBeam: AgentActivityBeamView?

    /// The ring's two horizontal constraints, held because the capsule they trace narrows with
    /// the column.
    private var beamLeadingConstraint: NSLayoutConstraint?
    private var beamTrailingConstraint: NSLayoutConstraint?

    // MARK: - Density

    /// See `SidebarDensityAdopting`. The capsule is drawn rather than laid out, so a new density
    /// is a redraw — plus the beam's two constraints, which trace the same silhouette and are
    /// the only part of it that is a constraint at all.
    func applySidebarDensity(_ density: SidebarDensity) {
        guard density != self.density else { return }

        self.density = density
        beamLeadingConstraint?.constant = density.selectionInsetX
        beamTrailingConstraint?.constant = -density.selectionInsetX
        needsDisplay = true
    }

    // MARK: - Activity Beam

    /// Restates what the row's ring should draw. `.none` fades a mounted ring out — and costs
    /// nothing on the rows that never mounted one, which is every row but the selected.
    func setActivityBeam(workload: AgentWorkload) {
        guard workload != .none || activityBeam != nil else { return }
        beamForPresentation().update(workload: workload)
    }

    /// Pinned to the selection capsule's silhouette — the one rectangle `highlightPath` fills —
    /// so the ring reads as the selection working, not as a second shape over it. Above the
    /// cell views, because the ring's ink belongs on top of the row it describes; it takes no
    /// clicks (`AgentActivityBeamView.hitTest` answers nil), so nothing under it goes dead.
    private func beamForPresentation() -> AgentActivityBeamView {
        if let activityBeam { return activityBeam }

        let beam = AgentActivityBeamView(surface: .sidebarRow)
        addSubview(beam, positioned: .above, relativeTo: nil)
        let leading = beam.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: density.selectionInsetX
        )
        let trailing = beam.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -density.selectionInsetX
        )
        beamLeadingConstraint = leading
        beamTrailingConstraint = trailing
        NSLayoutConstraint.activate([
            leading,
            trailing,
            beam.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SidebarRowDefaults.hoverHighlightInsetY
            ),
            beam.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -SidebarRowDefaults.hoverHighlightInsetY
            )
        ])
        activityBeam = beam
        return beam
    }

    /// The judgement, not the pixels — mirrors `AgentActivityBeamView`'s own seams.
    var activityBeamForTesting: AgentActivityBeamView? { activityBeam }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area

        // The list scrolls and reloads under a still pointer, and a receipt rises over it — none
        // of the three delivers an exit. See `NSView.hoverIsStale` for the first two and
        // `NSView.isPointerCovered` for the third, which is asked here rather than shared because
        // a row washed under a card and a chip lit under a menu are not the same case.
        if hoverIsStale(isMouseInside) || (isMouseInside && isPointerCovered) {
            isMouseInside = false
        }
    }

    /// Lit only where the pointer is actually on the row.
    ///
    /// A tracking area reports crossings of a *rectangle*, so the row under the sidebar's
    /// floating receipt is told the pointer arrived while the band is what it is resting on —
    /// see `NSView.isPointerCovered(at:)`.
    override func mouseEntered(with event: NSEvent) {
        isMouseInside = isHoverEnabled && !isPointerCovered(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
    }

    // MARK: - Drawing

    /// Fills a selected row with the theme's accent.
    ///
    /// This is the single most identity-carrying surface in the window, and the first pass left
    /// it to AppKit — so a Swiss Minimalist app whose whole identity is "one red accent" showed
    /// a grey selection, and Cyberpunk's neon appeared nowhere at all. A style that recolours
    /// the backdrop and leaves every foreground cue neutral reads as the same app in a
    /// different tint, which is exactly what it was.
    ///
    /// Under **System** this used to defer to `super` entirely, leaving the stock source-list
    /// selection untouched — and with it the one thing about that shape a narrow column needs
    /// back. `.inset` hangs a plain view in the row at a fixed 10pt from each edge whatever the
    /// divider is doing, so at the narrowest column the app allows, a selected row still stood
    /// ten points off a seam six points away from everything else the list draws.
    ///
    /// So the shape is now the list's under every theme and only the *colour* still asks which
    /// one is in force: `Design.Surface.selectionFill` is the system's own selection colour
    /// under System and the theme's accent otherwise, so a System window keeps the user's accent,
    /// their unemphasised grey, and their Increase Contrast. What it gives up is AppKit's
    /// vibrant blend on that one fill, which is the price of a capsule that can move.
    ///
    /// Overriding without calling `super` is also what *removes* the stock capsule: measured on
    /// macOS 26, AppKit inserts its selection view only when the row's own `drawSelection`
    /// reaches it. Two capsules on one row was never a risk here.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }

        // Full strength in the window in front, muted behind it — the same two AppKit
        // distinguishes, but on the question `ListSelectionStrength` re-answers for every list
        // in the app: the *window's*, not the focus inside it. So a background window does not
        // shout and the front one does not whisper at the row a click just picked.
        let fill = isEmphasized
            ? Design.Surface.selectionFill
            : Design.Surface.selectionFillUnemphasized
        fill.setFill()
        highlightPath.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)

        drawGroupRuleIfNeeded()

        guard isMouseInside, !isSelected else { return }

        Design.Text.label
            .withAlphaComponent(SidebarRowDefaults.hoverHighlightAlpha)
            .setFill()
        highlightPath.fill()
    }

    /// The rule takes the selection capsule's own horizontal silhouette, so the line above a
    /// group and the fill behind its selected row agree about where the list's ink begins.
    /// See `SidebarDefaults.compactGroupRuleHeight` for why it is thinner than the theme's rule.
    private func drawGroupRuleIfNeeded() {
        guard showsGroupRule else { return }

        let ruleY = isFlipped
            ? bounds.minY + SidebarDefaults.compactGroupRuleOffset
            : bounds.maxY - SidebarDefaults.compactGroupRuleOffset
                - SidebarDefaults.compactGroupRuleHeight
        Design.Surface.divider.setFill()
        NSRect(
            x: bounds.minX + density.selectionInsetX,
            y: ruleY,
            width: bounds.width - density.selectionInsetX * 2,
            height: SidebarDefaults.compactGroupRuleHeight
        ).fill()
    }

    /// The one silhouette hover and selection are both painted into.
    ///
    /// Both used to build their own, which was the same rectangle and *two different corners*:
    /// hover took a fixed radius and selection took the theme's. They agreed under the themes
    /// this was written against and parted company as soon as one shipped with square controls
    /// — a hovered row rounded, the selected row directly under it a hard-edged block of accent,
    /// on identical geometry. Two strengths of one affordance cannot be two shapes.
    private var highlightPath: NSBezierPath {
        let shape = bounds.insetBy(
            dx: density.selectionInsetX,
            dy: SidebarRowDefaults.hoverHighlightInsetY
        )
        return ThemedSurface.Shape(
            rect: shape,
            radius: highlightRadius(fitting: shape.size)
        ).path
    }

    /// The theme's control corner, because that is what the selection above is drawn with and
    /// what every other small surface in the window takes.
    ///
    /// **Fitted to the row**, which is also what the selection does — `ThemedTableRowView` asks
    /// for the same token the same way. Unfitted, a theme stating a corner broader than a row is
    /// tall (Botanical's 24) drew hover as a taper under a selection that stayed a rounded rect:
    /// the two shapes this comment exists to prevent, arrived at from the opposite direction.
    ///
    /// Under **System** there is no theme corner to fit, because System states no `Design.Radius`
    /// of its own; both strengths take the corner AppKit rounds its source-list selection by,
    /// read off that view rather than guessed at.
    private func highlightRadius(fitting size: NSSize) -> CGFloat {
        AppThemeLibrary.current.isSystem
            ? SidebarRowDefaults.systemHoverHighlightRadius
            : Design.Radius.control(fitting: size)
    }
}
