import AppKit

// MARK: - Sidebar Hover Row View

/// Row container that paints a soft highlight while the pointer is over it.
///
/// Selection is drawn by the outline view itself; this fills the gap between "nothing" and
/// "selected", so rows read as clickable before they are clicked. Group headings do not get
/// one — they only expand from their disclosure, and a highlight would promise more.
///
/// A `ThemedComponent` for the reason `ThemeBoundaryAudit` states about rows: a row that draws
/// theme colours has to be distinguishable from the plain one AppKit builds, which draws the
/// system's. This is the sidebar's louder answer to the question `ThemedTableRowView` answers
/// everywhere else.
final class SidebarHoverRowView: NSTableRowView, ThemedComponent {

    // MARK: - Properties

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
    /// Under **System** this defers to `super` entirely, so the stock source-list selection —
    /// the user's own accent, its vibrancy, its unemphasised grey — is untouched.
    override func drawSelection(in dirtyRect: NSRect) {
        guard !AppThemeLibrary.current.isSystem else {
            return super.drawSelection(in: dirtyRect)
        }
        guard isSelected else { return }

        // Full accent in the window in front, muted behind it — the same two strengths AppKit
        // distinguishes, but on the question `ListSelectionStrength` re-answers for every list
        // in the app: the *window's*, not the focus inside it. So a background window does not
        // shout and the front one does not whisper at the row a click just picked.
        let fill = isEmphasized ? Design.Surface.accent : AppThemePalette.color(.accentMuted)
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
            x: bounds.minX + SidebarRowDefaults.hoverHighlightInsetX,
            y: ruleY,
            width: bounds.width - SidebarRowDefaults.hoverHighlightInsetX * 2,
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
            dx: SidebarRowDefaults.hoverHighlightInsetX,
            dy: SidebarRowDefaults.hoverHighlightInsetY
        )
        let radius = highlightRadius
        return NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)
    }

    /// The theme's control corner, because that is what the selection above is drawn with and
    /// what every other small surface in the window takes.
    ///
    /// Under **System** the selection is AppKit's own and never reaches `highlightPath`, so
    /// there is no theme silhouette for hover to agree with — it keeps the fixed corner that
    /// was measured against the stock source list.
    private var highlightRadius: CGFloat {
        AppThemeLibrary.current.isSystem
            ? SidebarRowDefaults.systemHoverHighlightRadius
            : Design.Radius.control
    }
}
