import AppKit

// MARK: - Virtual Content Rows

/// A fixed-height, single-line cell whose label survives reuse and streaming updates.
/// Frame layout avoids installing constraints for every line of a live table. The table still
/// owns selection, scrolling, accessibility and the lifetime of offscreen cells.
public final class ThemedTableTextCell: NSTableCellView {
    public let label = NSTextField(labelWithString: "")
    public var horizontalInset: CGFloat = Design.Spacing.tight {
        didSet { needsLayout = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.applyFont(.compactCode)
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = true
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: horizontalInset, dy: 0)
    }
}

/// A recycled table-cell shell for content whose height comes from Auto Layout.
///
/// AppKit does not state a view-based table cell's column width while asking Auto Layout for its
/// height. Without the explicit width below, a wrapping settings or transcript row solves at its
/// narrowest legal width, reports a very tall height, and only later gets stretched by the table.
/// The host owns that one piece of table plumbing so virtualized feature lists do not each grow a
/// subtly different copy.
public final class ThemedVirtualTableCell: NSTableCellView {
    private lazy var columnWidth: NSLayoutConstraint = {
        let constraint = widthAnchor.constraint(equalToConstant: 0)
        constraint.priority = NSLayoutConstraint.Priority(999)
        return constraint
    }()

    public func install(
        _ content: NSView,
        columnWidth width: CGFloat,
        horizontalInset: CGFloat = 0,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0
    ) {
        subviews.forEach { $0.removeFromSuperview() }
        setColumnWidth(width)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset)
        ])
    }

    public func setColumnWidth(_ width: CGFloat) {
        guard width > 0 else {
            columnWidth.isActive = false
            return
        }
        guard !columnWidth.isActive || abs(columnWidth.constant - width) > 0.5 else { return }
        columnWidth.constant = width
        columnWidth.isActive = true
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        subviews.forEach { $0.removeFromSuperview() }
    }
}

/// A run of virtual rows that reads as one settings card.
///
/// `topInset` and `bottomInset` belong to the first and last row hosts respectively. Repeating
/// them here keeps the painted panel behind the content rather than behind the inter-section
/// breathing room carried by those rows.
public struct ThemedTableCardDecoration: Equatable {
    public let rows: ClosedRange<Int>
    public var topInset: CGFloat = 0
    public var bottomInset: CGFloat = 0
}

/// A virtual table that paints grouped settings-card surfaces behind row runs.
///
/// The surface belongs to the table, not to a retained container around all of its rows. AppKit
/// can therefore recycle every offscreen cell while the group still reads as one continuous card;
/// only the cheap row range survives outside the viewport.
public final class ThemedGroupedTableView: ThemedTableView {
    public var cardDecorations: [ThemedTableCardDecoration] = [] {
        didSet { needsDisplay = true }
    }

    public override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)

        for decoration in cardDecorations where decoration.rows.lowerBound >= 0
            && decoration.rows.upperBound < numberOfRows {
            let first = rect(ofRow: decoration.rows.lowerBound)
            let last = rect(ofRow: decoration.rows.upperBound)
            var cardRect = first.union(last).insetBy(dx: Design.Size.glowGutter, dy: 0)
            cardRect.origin.y += decoration.topInset
            cardRect.size.height -= decoration.topInset + decoration.bottomInset
            guard cardRect.width > 0, cardRect.height > 0,
                  cardRect.insetBy(dx: -Design.Size.glowGutter, dy: -Design.Size.glowGutter)
                    .intersects(clipRect) else { continue }

            drawCard(in: cardRect)
            drawDividers(in: decoration, cardRect: cardRect, clipRect: clipRect)
        }
    }

    private func drawCard(in rect: NSRect) {
        let radius = Design.Radius.panel
        let silhouette = ThemedSurface.Shape(rect: rect, radius: radius)
        if let glow = AppThemePalette.current.material.glow {
            if let highlight = glow.highlight {
                drawShadow(
                    around: silhouette,
                    color: AppThemePalette.current.resolved(highlight.role),
                    radius: highlight.radius,
                    opacity: highlight.opacity,
                    offset: NSSize(width: highlight.offsetX, height: highlight.offsetY)
                )
            }
            drawShadow(
                around: silhouette,
                color: AppThemePalette.current.resolved(glow.role),
                radius: glow.radius,
                opacity: glow.opacity,
                offset: NSSize(width: glow.offsetX, height: glow.offsetY)
            )
        }

        ThemedSurface.draw(
            rect,
            fill: Design.Surface.panel,
            border: Design.Surface.border,
            radius: radius,
            borderWidth: Design.Radius.border
        )
    }

    /// `NSShadow` needs a caster as well as a path. Painting the panel colour makes the caster
    /// disappear into the final panel pass while leaving only the authored outer shadow visible.
    private func drawShadow(
        around shape: ThemedSurface.Shape,
        color: NSColor,
        radius: CGFloat,
        opacity: Double,
        offset: NSSize
    ) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(CGFloat(opacity))
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = offset
        shadow.set()
        Design.Surface.panel.setFill()
        shape.path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDividers(
        in decoration: ThemedTableCardDecoration,
        cardRect: NSRect,
        clipRect: NSRect
    ) {
        guard decoration.rows.lowerBound < decoration.rows.upperBound else { return }
        let visible = rows(in: clipRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        let firstVisible = max(decoration.rows.lowerBound, visible.location)
        let lastVisibleBoundary = min(
            decoration.rows.upperBound,
            visible.location + visible.length
        )
        guard firstVisible < lastVisibleBoundary else { return }

        Design.Surface.border.setFill()
        for row in firstVisible..<lastVisibleBoundary {
            let boundary = rect(ofRow: row).maxY
            NSRect(
                x: cardRect.minX + Design.Spacing.inset,
                y: boundary,
                width: max(0, cardRect.maxX - cardRect.minX - Design.Spacing.inset),
                height: 1
            ).fill()
        }
    }
}

// MARK: - Row

/// The row a themed list is selected in, replacing the plain `NSTableRowView` AppKit builds for
/// a list whose delegate hands back none.
///
/// AppKit's selection is the **system** accent — blue on nearly every Mac, and read from the
/// user's settings rather than from the window — so a list that says nothing lights a stock blue
/// bar in the middle of a themed pane. Reported against the attachments pane, whose lavender
/// window had a Finder-blue row in it; nothing there had claimed selection, and nothing had to
/// for the blue to appear. Every list that leaves the question alone has the same defect, which
/// is why the answer is a component rather than a fix at one call site.
///
/// The fill is the theme's `selection` role — the accent held far enough back that the row's own
/// label tiers still read over it, so a row states its selection without restating its contents.
/// That is deliberately *not* the sidebar's answer — `SidebarHoverRowView` fills with the accent
/// at full strength, because the selected session is the window's subject and a list inside a pane
/// answering at the same strength would put two selections in one window with equal weight.
///
/// **"Held far enough back" was a description, and is now a construction.** It was true of every
/// theme that happened to author a wash and false of the two that authored a near-opaque fill:
/// Windows 98's 90% navy put the chrome's near-black label on it at 1.47:1, Platinum's 88% blue at
/// 3.70:1. Nothing caught it because the row draws the fill and the *cells* are feature code —
/// nine view controllers inking themselves from `Design.Text`, as anything on the chrome's ground
/// should. `SelectionSurface.quiet` is the strength a surface takes when it cannot reach the ink
/// of what it contains: it holds the authored fill back until that ink reads, and leaves themes
/// that already kept the promise exactly as they were authored.
///
/// Under **System** it defers to `super` entirely, so the stock selection — the user's own
/// accent, its emphasized and unemphasized strengths, its vibrancy — is untouched.
public class ThemedTableRowView:
    NSTableRowView,
    ThemedComponent,
    OutlineDisclosureInkProviding {

    /// The interactive cell currently asking this row to draw its hover/press plate.
    ///
    /// Selection already belongs to the row. Keeping an adjacent cell's hover inside the cell
    /// produces two subtly different silhouettes: inset-style tables hold the row plate in from
    /// the list while the cell is inset again, and the cell's full-height fill can meet the
    /// selected row beside it. The row therefore owns both states through one path. The source is
    /// weak so AppKit's reuse queue cannot be kept alive by presentation state.
    private weak var interactionHighlightSource: NSView?
    private var interactionHighlightInkSource: InkSource?

    /// A drag is over this row and would land on it.
    ///
    /// **On the row, not on the cell inside it, and that is the whole reason it lives here.** A
    /// list's cell view is inset within its row — the inset table style pads it by about eight
    /// points on each side — so a host that draws its own drop feedback from the cell draws a
    /// plate visibly narrower than the selection stacked directly above it while standing exactly
    /// as tall: read as a hover that had lost its edges. Drawn here it is the *same* silhouette
    /// selection uses, by construction rather than by two call sites agreeing.
    public var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            needsDisplay = true
        }
    }

    /// A demotion is believed only if the list this row is in asks for one. See
    /// `ListSelectionStrength` for the rule, and why a hook at the draw could not hold it.
    public override var isEmphasized: Bool {
        get { super.isEmphasized }
        set { super.isEmphasized = listSelectionStrength(insteadOf: newValue) }
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        adoptListSelectionStrength()
    }

    public override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)

        if let source = interactionHighlightSource,
           source.isDescendant(of: self),
           let interactionHighlightInkSource
        {
            interactionHighlightInkSource.ink.surface.setFill()
            platePath.fill()
        }

        guard isDropTarget else { return }

        Design.Surface.dropTarget.setFill()
        platePath.fill()
    }

    /// Lets an interactive cell borrow the row's plate without exposing row geometry to the
    /// cell. A later cell cannot be cleared by an earlier reused one: only the source that owns
    /// the current claim may release it.
    public func setInteractionHighlight(
        _ highlighted: Bool,
        from source: NSView,
        inkSource: InkSource
    ) {
        if highlighted {
            // A cell may claim only the row that actually contains it. This keeps a delayed
            // callback from a reused view from painting whichever row it used to belong to.
            guard source.isDescendant(of: self) else { return }
            interactionHighlightSource = source
            interactionHighlightInkSource = inkSource
        } else if interactionHighlightSource === source {
            interactionHighlightSource = nil
            interactionHighlightInkSource = nil
        } else {
            return
        }
        needsDisplay = true
    }

    public var interactionHighlightIsActiveForTesting: Bool {
        guard let source = interactionHighlightSource else { return false }
        return source.isDescendant(of: self)
    }

    public var plateRectForTesting: NSRect { platePath.bounds }

    public override func drawSelection(in dirtyRect: NSRect) {
        guard !AppThemeLibrary.current.isSystem else {
            return super.drawSelection(in: dirtyRect)
        }
        guard isSelected else { return }

        // The ground is measured rather than assumed: the same row class is drawn in the
        // attachments pane, in Git Review's file list and inside a settings sheet, and how far the
        // fill has to be held back depends on what is under it. `resolvedGround` is the walk that
        // already answers this for every other derived colour in the app.
        SelectionSurface.quiet(over: resolvedGround()).fill.setFill()
        selectionPath.fill()
    }

    /// **The ink that reads on whatever this row actually painted.**
    ///
    /// `SelectionSurface.quiet` exists so a cell does not *have* to ask — it holds the fill back
    /// until `Design.Text.label` reads on it, which is the promise a row can keep for cells it
    /// cannot reach. That promise covers tier one. It does not cover the tiers below it, and it
    /// does not cover **System** at all, where the four lines above hand the highlight back to
    /// AppKit and an opaque accent lands under cells still inking themselves from the chrome's
    /// ground. Measured on the attachments pane: a row's timestamp at `Design.Text.quaternary`
    /// drew at 1.20:1 the moment the row was selected, against 1.34:1 unselected — so selecting a
    /// row made its own metadata *less* legible.
    ///
    /// A cell that wants the rest of the ladder asks for it here rather than working out which of
    /// those two worlds it is in. That is the whole point: the row is the only thing that knows
    /// what it painted, so the row is what says so — the same argument `Design.Ink.primaryAction`
    /// makes one control further in.
    ///
    /// Returns the chrome's own ink for an unselected row.
    ///
    /// **Measured against the painted ground even where `quiet` hands back the chrome's ink.**
    /// Those two answers differ only for the two themes `quiet` has to hold back — Windows 98 and
    /// Platinum — and there the chrome's ink is the right answer for a cell that *cannot* ask and
    /// the wrong one for a cell that has: it keeps tier one legible and leaves the rest where they
    /// were. Windows 98's quaternary on its held-back navy measured 1.18:1. A cell that took the
    /// trouble to ask gets the ladder measured on what is actually under it.
    public var contentInk: Design.Ink {
        guard let ground = selectionGround else { return .chrome }
        return Design.Text.on(ground)
    }

    /// The marker shares the row's actual ink ladder, including System's native selection and
    /// authored quiet selection surfaces that had to be held back to keep their contents legible.
    public var outlineDisclosureInk: NSColor { contentInk.tertiary }

    /// The opaque colour a **selected** row ends up showing, or `nil` when it is not selected.
    ///
    /// Also the answer a test asserts against, so the fixture and the row cannot disagree about
    /// which of the two selection strengths was in force — `isEmphasized` is not simply what it
    /// was set to (see `ListSelectionStrength`), and a test that recomputed the fill by hand was
    /// measuring ink against a ground the row had not painted.
    public var selectionGround: NSColor? {
        guard isSelected else { return nil }
        guard AppThemeLibrary.current.isSystem else {
            return SelectionSurface.quiet(over: resolvedGround()).ground
        }
        // AppKit's own fill, at the strength AppKit is drawing it — a selected row in a window
        // that is not in front is a pale grey, and ink measured against the emphasized blue would
        // be white on it.
        let fill = isEmphasized
            ? Design.Surface.selectionFill
            : Design.Surface.selectionFillUnemphasized
        return fill.composited(over: resolvedGround())
    }

    /// The theme's control corner, inset just off the row's edges so the fill reads as a surface
    /// the row is sitting on rather than as a band ruled across the list — and so a rounded
    /// theme's corner has somewhere to turn. The same silhouette rule the sidebar's rows follow,
    /// at a list's scale rather than a source list's.
    private var selectionPath: NSBezierPath { path(insetBy: ThemedTableRowDefaults.selectionInsetX) }

    /// Any plate this row draws that is *not* the selection — today the drop wash — in the
    /// geometry the selection actually has.
    ///
    /// **Which is not always ours.** Under a styled theme `drawSelection` draws `selectionPath`
    /// and the two agree by construction. Under **System** the selection is AppKit's own, and an
    /// inset-style table pads its plate `systemInsetStylePadding` in from the row while our path
    /// stops one hairline in — so a wash drawn from `selectionPath` ran the full width of the list
    /// directly under a selection that did not, and the pair read as two different kinds of
    /// object. (Drawing it from the *cell* instead is worse in the mirror image: the cell is inset
    /// further still, so the plate stood as tall as the selection and visibly narrower than it.)
    private var platePath: NSBezierPath {
        guard AppThemeLibrary.current.isSystem else { return selectionPath }
        switch (superview as? NSTableView)?.effectiveStyle {
        case .inset, .sourceList:
            return path(insetBy: ThemedTableRowDefaults.systemInsetStylePadding)
        default:
            return selectionPath
        }
    }

    private func path(insetBy padding: CGFloat) -> NSBezierPath {
        let shape = bounds.insetBy(dx: padding, dy: ThemedTableRowDefaults.selectionInsetY)
        let radius = Design.Radius.control(fitting: shape.size)
        return NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius)
    }
}

public enum ThemedTableRowDefaults {
    /// Enough to keep the fill off the list's edges without pulling it in from the row's
    /// content, which starts one `small` step in.
    public static let selectionInsetX: CGFloat = Design.Spacing.hairline
    /// The same 1pt the sidebar's rows leave, so two consecutive selected rows read as two.
    public static let selectionInsetY: CGFloat = Design.Spacing.hairline / 2

    /// How far AppKit holds an inset-style table's selection in from the row, under **System**,
    /// where the selection is its plate and not ours.
    ///
    /// Not published by AppKit, so it is *measured* rather than trusted: `ThemedTableRowView`
    /// draws anything of its own on this inset, and `testTheDropWashTakesTheSelectionsOwnShape`
    /// reads both plates off drawn pixels and fails if they ever stop agreeing — which is what a
    /// macOS release changing this number should produce, rather than a list whose drop
    /// affordance quietly grew wider than its selection.
    public static let systemInsetStylePadding: CGFloat = Design.Spacing.medium

    /// AppKit's own key for a list's row view, held here because its Swift binding was obsoleted
    /// in Swift 3 while the constant itself was not: `NSTableView.h` still declares
    /// `NSTableViewRowViewKey` and still pins it to this string.
    public static let rowViewKey = NSUserInterfaceItemIdentifier("NSTableViewRowViewKey")

    /// **Every list in this app selects through `ThemedTableRowView`, including the lists that
    /// never say so.**
    ///
    /// A row view is *created*, not asked for: a delegate that returns nothing from
    /// `rowViewForRow:` — or a list whose delegate has no such method at all — is handed a plain
    /// `NSTableRowView`, which fills its selected row with the **system** accent. That was live
    /// in four panes at once (see `ThemedTableRowView`), and not one of them contained a line to
    /// review: the defect was the absence of one, which is the single thing a source lint cannot
    /// see and a reviewer cannot read.
    ///
    /// So the answer is taken away from the call sites. AppKit asks
    /// `makeView(withIdentifier:owner:)` for `rowViewKey` before falling back to its own class,
    /// and `ThemedTableView`/`ThemedOutlineView` are provably every list in the app — subclassing
    /// `NSTableView` or `NSOutlineView` anywhere else fails `scripts/check_theme_boundaries.sh`.
    /// A delegate that *does* state a row still wins, because AppKit asks it first and only lands
    /// here when it declines; that is what leaves the sidebar's louder row (`SidebarHoverRowView`)
    /// alone while its unselectable headings quietly take this one.
    ///
    /// `recycling` is `super`'s answer, taken first so the reuse queue keeps working: after the
    /// first screenful it hands back the rows this list already made, which are these.
    ///
    /// **A recycled view is also brought back to the theme in force here**, for the same reason
    /// the row above is constructed here: the defect has no call site. A view in the reuse queue
    /// is in no window, and `AppThemeRefresh.repaintEverything` walks windows — so the sweep that
    /// re-resolves recorded font roles, surfaces and layer colours reaches every row on screen
    /// and none of the ones waiting behind them. Nothing re-applies any of it afterwards either:
    /// `applyFont` runs once, where the cell is built. So the pooled view comes back out wearing
    /// whichever theme was current when it went in, beside neighbours wearing the new one.
    ///
    /// That shipped. After a switch to Tiger, a sidebar session row vended from the queue was
    /// still set in SF 12 while the rows around it had taken Lucida Grande 10.8 — Tiger states
    /// both a family and a `textScale` of 0.90, so the stale row was a different face *and* a
    /// tenth larger. Only its font was wrong, which is the clue that names the mechanism: a
    /// `MorphingTitleLabel` holds its colour as a rule it re-asks from `AppThemeDidChange`, which
    /// a detached view still receives, and its font as a value the sweep pushes, which a detached
    /// view does not.
    ///
    /// `repaintIfNeeded` is generation-stamped, so a view already current costs one associated
    /// object read per vend, and the repaint itself runs once per view per theme change.
    public static func vendedView(
        for identifier: NSUserInterfaceItemIdentifier,
        recycling recycled: NSView?
    ) -> NSView? {
        if let recycled {
            // `assumeIsolated` for the reason `validateProposedFirstResponder` gives: AppKit
            // calls the override above on the main thread and says so nowhere in its types.
            MainActor.assumeIsolated { AppThemeRefresh.repaintIfNeeded(recycled) }
            return recycled
        }
        guard identifier == rowViewKey else { return nil }

        let row = ThemedTableRowView()
        row.identifier = identifier
        return row
    }
}

// MARK: - Row Controls

/// Which of a row's subviews may have the click that landed on it.
///
/// `NSTableView` decides that in `validateProposedFirstResponder(_:for:)`, and its default answer
/// for a row that is **not already selected** is no: the table takes the click itself and selects
/// the row, so acting on the control needs a second one. That is the right gesture for a text
/// field — click to select the row, click again to edit — and the wrong one for a button, which
/// is why AppKit exempts its own `NSButton`s and why nothing about this was visible until this
/// app started building row buttons out of `ThemedControl`.
///
/// What it looked like: a session row's archive box did nothing at all, and its `⋯` opened "only
/// sometimes" — the sometimes being the row that happened to be selected already. Both clicks
/// were landing on the button, drawing its hover fill, and then being spent selecting the row
/// underneath, which also switched the session on screen and moved the sidebar's focus ring. The
/// three reports were one bug.
///
/// Stated as a rule about *controls that act on their own click*, not a list of classes: every
/// `ThemedControl` in this app is one (button, toggle, chip, pop-up, recorder — no text editor
/// among them), and `NSButton` covers AppKit's own, including the disclosure triangle an outline
/// view inserts. A label, an image or the row's ground is none of these, so clicking a row
/// anywhere else still selects it — "anywhere else" meaning outside every such control, the glyphs
/// and labels *inside* one included, for the reason `takesItsOwnClick` states.
@MainActor
public enum RowControls {

    /// Whether the click that landed on `responder` belongs to a control rather than to the row.
    ///
    /// **AppKit asks about the deepest view under the pointer**, and that is the whole subtlety:
    /// what it hit is not what the user aimed at. `ThemedIconButton` draws its glyph in a child
    /// view (a `GlyphView`; an `NSImageView` when this was found), so the proposed responder over
    /// an archive box is that child — which AppKit does not exempt — and the table went on vetoing the click in the
    /// middle of a button it had just been taught to allow. What survived was the four-point
    /// padding ring around the glyph, which is why this was reported twice and differently: the `⋯`
    /// "worked, but nowhere near always" because an ellipsis is 9 points tall in a 20-point target
    /// and leaves live bands above and below it, while the archive box was "basically impossible"
    /// because `archivebox` is 12×16 and fills nearly all of the same target. Both are one glyph
    /// in the way, measured as a 16-point-wide dead centre.
    ///
    /// So the question is not *is this a control* but *is it inside one*: a control's glyph, label
    /// or chip is part of the target it draws, and a click landing on one is a click on the
    /// control. Letting it through is enough — the press then reaches the control the way it
    /// already does outside a list, an `NSImageView` with no action of its own forwarding it up the
    /// responder chain.
    public static func takesItsOwnClick(_ responder: NSResponder) -> Bool {
        guard let view = responder as? NSView else { return false }
        return owner(of: view) != nil
    }

    /// The nearest control at or above `view` that acts on its own click.
    ///
    /// The walk stops at the row, so nothing the list is nested *inside* can claim a click that
    /// landed within it — the rule answers about one row's contents and no further.
    private static func owner(of view: NSView) -> NSView? {
        for node in sequence(first: view, next: { $0.superview }) {
            if node is ThemedControl || node is NSButton { return node }
            if node is NSTableRowView || node is NSTableView { return nil }
        }
        return nil
    }
}

/// The ink an outline row gives the disclosure control AppKit inserts beside it.
///
/// The control is system-owned, but its ground is not: a selected sidebar row paints the
/// theme's accent while an ordinary themed table row paints its quieter selection surface.
/// AppKit cannot infer either authored ground, so the row that owns it supplies the matching
/// semantic ink and `ThemedOutlineView` keeps the contained control up to date.
@MainActor
public protocol OutlineDisclosureInkProviding: AnyObject {
    var outlineDisclosureInk: NSColor { get }
}

/// `ThemedTableView`'s rule again, one class up: `NSOutlineView` inherits `NSTableView`,
/// so the two-line duplication here is what lets both keep their real superclass.
public class ThemedOutlineView:
    NSOutlineView,
    ThemedComponent,
    SystemChromeBoundary,
    SoleColumnFitting,
    SelectionStrengthStating {

    /// See `SoleColumnFitting`.
    public var soleColumnFillsBoundsExactly = false

    /// A secondary click (or an accessibility "show menu") landed on a row — `-1` for the
    /// empty stretch below the last one. Reported rather than handled, with the anchor the
    /// gesture carries: what a row's menu holds is the host's knowledge, not the outline's.
    /// Answers whether a menu actually opened, so the accessibility route can say so honestly.
    ///
    /// This replaces `menu(for:)`/`.menu`: the host presents an app-owned dropdown instead of
    /// an `NSMenu`, so the outline's part shrinks to resolving the row under the gesture.
    public var onContextMenu: ((Int, ThemedMenuAnchor) -> Bool)?

    /// Starts every row's content at one leading edge, whatever its depth.
    ///
    /// `indentationPerLevel` stays untouched — zeroing it is the obvious route, and it leaves
    /// AppKit computing marker and cell frames from degenerate geometry nobody documents.
    /// Instead the normal indented frames are asked for and re-placed: the cell keeps its
    /// right edge and takes `cellLeading` as its left one, and the disclosure chevron drops
    /// into a fixed gutter at `markerLeading`. Depth is then the host's to say some other way
    /// — the sidebar says it with type and vertical rhythm.
    ///
    /// The host owns relayout: rows already built keep their old frames until the next
    /// `reloadData()`, so flipping this mid-list without one shows both geometries at once.
    public struct FlattenedIndentation {
        public let cellLeading: CGFloat
        public let markerLeading: CGFloat

        public init(cellLeading: CGFloat, markerLeading: CGFloat) {
            self.cellLeading = cellLeading
            self.markerLeading = markerLeading
        }
    }

    /// Nil draws the ordinary indented tree.
    public var flattenedIndentation: FlattenedIndentation?

    /// How far to either side of a row's disclosure chevron a press still folds the row.
    ///
    /// AppKit's chevron already spans its row's full height, but it is 13pt wide (measured on
    /// macOS 26) — so a press a few points beside the mark selected the row instead, which is
    /// what "the chevron's hitbox is small" meant. Widening the button itself is the obvious
    /// route, and it moves what the button draws: the system triangle and the authored marker
    /// (which takes the button's frame) both re-centre in the wider frame. So the button keeps
    /// its frame and its pixels, and `mouseDown` hands a press in the band around it to that
    /// same button — expansion then takes AppKit's own route, including `shouldExpandItem`,
    /// Option-click folding descendants, and the notifications hosts persist collapse from.
    ///
    /// **How far is the host's to say**, because the trailing side reaches into the cell and only
    /// the host knows where its row's content begins. So that side is measured from the cell's
    /// leading edge, not the chevron's trailing one: the two need not meet — the compact tree
    /// leaves a point between them — and a reach stated from the chevron stopped that point short
    /// of the content it was measured against. Zero — every list but the one that opts in —
    /// leaves AppKit's own target exactly as it was.
    public struct DisclosureHitOutsets: Equatable, Sendable {
        /// Points before the chevron's leading edge.
        public let beforeChevron: CGFloat
        /// Points past the leading edge of the row's cell; the target never ends before the
        /// chevron does.
        public let intoCell: CGFloat

        public static let zero = DisclosureHitOutsets(beforeChevron: 0, intoCell: 0)

        public init(beforeChevron: CGFloat, intoCell: CGFloat) {
            self.beforeChevron = beforeChevron
            self.intoCell = intoCell
        }
    }

    public var disclosureHitOutsets: DisclosureHitOutsets = .zero

    /// The disclosure a press at `point`, in this view's coordinates, belongs to: the chevron of
    /// the row under it, widened by `disclosureHitOutsets` and clipped to that row. Nil for a row
    /// with nothing to disclose, and for every point while the outsets are zero.
    func disclosureButton(forPressAt point: NSPoint) -> NSButton? {
        guard disclosureHitOutsets != .zero else { return nil }

        let row = row(at: point)
        guard row >= 0,
              let rowView = rowView(atRow: row, makeIfNecessary: false),
              let button = disclosureButton(in: rowView),
              !button.isHidden, button.isEnabled
        else { return nil }

        let rowFrame = convert(rowView.bounds, from: rowView)
        let marker = convert(button.frame, from: rowView)
        let cellLeading = outlineTableColumn
            .flatMap { column in tableColumns.firstIndex { $0 === column } }
            .map { frameOfCell(atColumn: $0, row: row).minX }
            ?? marker.maxX
        let minX = max(rowFrame.minX, marker.minX - disclosureHitOutsets.beforeChevron)
        let maxX = min(
            rowFrame.maxX,
            max(marker.maxX, cellLeading + disclosureHitOutsets.intoCell)
        )
        guard point.x >= minX, point.x < maxX,
              point.y >= rowFrame.minY, point.y < rowFrame.maxY
        else { return nil }
        return button
    }

    private let disclosureEvents = AppEventObservations()
    private let disclosureWindowEvents = AppEventObservations()

    /// Points of the style's own trailing padding handed back to the cells.
    ///
    /// `.inset` — what `.automatic` resolves to — keeps 16pt past every cell's trailing edge, and
    /// that band is where a narrow list's last reclaimable space is: the row's own gutter is a
    /// couple of points, while this is sixteen. Measured on macOS 26 at every width; the same
    /// number appears in `SoleColumnFitting`, which meets it from the column's side.
    ///
    /// Widening only, and never past the row's trailing edge. **How far is the host's to say**,
    /// because what bounds it is the shape that host draws: content moving out into this band has
    /// to stay inside the silhouette a selected row fills, and only the host knows where that is.
    /// See `SidebarDefaults.tightTrailingCellReclaim`.
    public var trailingCellReclaim: CGFloat = 0

    /// Only the outline column indents, and this list has only that column — so the override
    /// applies wherever the frame came back indented rather than guessing at column indexes.
    public override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        guard tableColumns.indices.contains(column),
              tableColumns[column] === outlineTableColumn, !frame.isEmpty else { return frame }

        if let flattened = flattenedIndentation {
            let trailingEdge = frame.maxX
            frame.origin.x = flattened.cellLeading
            frame.size.width = max(0, trailingEdge - flattened.cellLeading)
        }

        if trailingCellReclaim > 0 {
            let reclaimed = min(trailingCellReclaim, max(0, bounds.width - frame.maxX))
            frame.size.width += reclaimed
        }
        return frame
    }

    /// AppKit answers `.zero` for a row with nothing to disclose; that answer stands.
    public override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard let flattened = flattenedIndentation, !frame.isEmpty else { return frame }

        frame.origin.x = flattened.markerLeading
        return frame
    }

    /// Moves the rows the outline already owns to the geometry it would build them at now.
    ///
    /// `indentationPerLevel` and `flattenedIndentation` are read when a row is *built*, and
    /// nothing re-reads them afterwards: measured on macOS 26, a change followed by
    /// `layoutSubtreeIfNeeded`, `tile()` or `noteHeightOfRows` leaves every mounted cell and
    /// chevron exactly where it was, while `frameOfCell` already answers the new place. Only
    /// `reloadData()` re-places them — which discards and rebuilds the whole list, and a
    /// continuous divider drag cannot pay that per frame. `reloadData(forRowIndexes:…)` is no
    /// help either: it rebuilds the cell and leaves the chevron behind.
    ///
    /// So the placement is applied directly, to both halves of a row, for the rows the table
    /// currently has views for — `enumerateAvailableRowViews`, which is the viewport plus
    /// AppKit's own margin, never the whole tree. Rows built later take the same geometry from
    /// `frameOfCell`/`frameOfOutlineCell` on their own, so scrolling in stays consistent.
    ///
    /// The chevron is AppKit's own button, added as a direct subview of the row view and stamped
    /// with `NSOutlineView.disclosureButtonIdentifier` — the identifier the framework documents
    /// for exactly this, so the marker is named rather than guessed at by position or class.
    public func refitIndentedRows() {
        guard let column = outlineTableColumn,
              let columnIndex = tableColumns.firstIndex(where: { $0 === column })
        else { return }

        // **Only the horizontal half is taken.** Both `frameOfCell` and `frameOfOutlineCell`
        // answer in the *table's* coordinates, and a cell and a chevron live in their row
        // view's — where a row's own content sits at y 0. Assigning either frame whole moves
        // every row's content down by the row's offset in the list, out of the row it belongs
        // to: the first render of this showed a column with one clipped project row and nothing
        // under it. Indentation is horizontal; nothing else here is this method's to move.
        func slide(_ subview: NSView, toX x: CGFloat, width: CGFloat) {
            var frame = subview.frame
            frame.origin.x = x
            frame.size.width = width
            subview.frame = frame
        }

        enumerateAvailableRowViews { rowView, row in
            if let cell = view(atColumn: columnIndex, row: row, makeIfNecessary: false) {
                let target = frameOfCell(atColumn: columnIndex, row: row)
                slide(cell, toX: target.minX, width: target.width)
            }

            let markerFrame = frameOfOutlineCell(atRow: row)
            guard !markerFrame.isEmpty,
                  let marker = disclosureButton(in: rowView)
            else { return }
            slide(marker, toX: markerFrame.minX, width: markerFrame.width)
        }

        refreshDisclosureInks()
    }

    private lazy var selectionStrength = ListSelectionStrength(self)

    /// See `SoleColumnFitting`.
    public var soleColumnFitWidth: CGFloat = -1

    /// See `SelectionStrengthStating` — asked by this list's own rows as AppKit demotes them,
    /// which in the sidebar is every time a click hands focus to the session it just opened.
    public var drawsSelectionAtFullStrength: Bool { selectionStrength.drawsAsKey }

    /// See `ListSelectionStrength.fixtureIsKey`.
    public var fixtureIsKey: Bool? {
        get { selectionStrength.fixtureIsKey }
        set { selectionStrength.fixtureIsKey = newValue }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundColor = .clear
        disclosureEvents.observe(
            NSTableView.selectionDidChangeNotification,
            object: self
        ) { [weak self] in
            self?.refreshDisclosureInks()
        }
        for name in [
            NSOutlineView.itemDidExpandNotification,
            NSOutlineView.itemDidCollapseNotification,
        ] {
            disclosureEvents.observe(name, object: self) { [weak self] in
                self?.refreshDisclosureInks()
            }
        }
        disclosureEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.refreshDisclosureInks()
        }
        disclosureEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.refreshDisclosureInks()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewWillDraw() {
        super.viewWillDraw()
        fitSoleColumnToWidth()
        selectionStrength.apply()
        refreshDisclosureInks()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selectionStrength.followWindow()
        followWindowForDisclosureInk()
        refreshDisclosureInks()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDisclosureInks()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        _ = fitExactSoleColumn(to: newSize.width)
        super.setFrameSize(newSize)
        fitSoleColumnToWidth()
    }

    public override func layout() {
        super.layout()
        fitSoleColumnToWidth()
        refreshDisclosureInks()
    }

    /// AppKit's disclosure is a direct child of the row rather than of the cell, so it never
    /// receives the cell's `interiorBackgroundStyle` update that correctly re-inks the title
    /// and trailing controls. `contentTintColor` does not affect the private disclosure cell's
    /// pixels either. Under an authored theme, keep that button as the hit target but make it
    /// transparent and draw the semantic mark immediately behind it; System keeps AppKit's
    /// pixels untouched. Work stays bounded to the mounted viewport rows, and resolution happens
    /// inside the button's appearance for adaptive themes and offscreen fixtures.
    private func refreshDisclosureInks() {
        enumerateAvailableRowViews { rowView, row in
            guard let button = disclosureButton(in: rowView) else { return }
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard !AppThemePalette.current.isSystem else {
                    button.isTransparent = false
                    disclosureMarker(in: rowView)?.removeFromSuperview()
                    return
                }

                let marker = disclosureMarker(in: rowView) ?? makeDisclosureMarker(
                    in: rowView,
                    behind: button
                )
                let expanded = item(atRow: row).map(isItemExpanded) ?? false
                let identifier = expanded
                    ? Self.expandedDisclosureMarkerIdentifier
                    : Self.collapsedDisclosureMarkerIdentifier
                if marker.identifier != identifier {
                    marker.identifier = identifier
                    marker.setSymbol(
                        expanded ? "chevron.down" : "chevron.right",
                        role: .chevron,
                        weight: .semibold
                    )
                }
                marker.frame = button.frame
                marker.tint =
                    (rowView as? OutlineDisclosureInkProviding)?.outlineDisclosureInk
                    ?? Design.Text.tertiary
                button.isTransparent = true
            }
            button.needsDisplay = true
        }
    }

    private static let collapsedDisclosureMarkerIdentifier = NSUserInterfaceItemIdentifier(
        "ThemedOutlineView.collapsedDisclosureMarker"
    )
    private static let expandedDisclosureMarkerIdentifier = NSUserInterfaceItemIdentifier(
        "ThemedOutlineView.expandedDisclosureMarker"
    )

    private func disclosureMarker(in rowView: NSTableRowView) -> GlyphView? {
        rowView.subviews.first(where: {
            $0.identifier == Self.collapsedDisclosureMarkerIdentifier
                || $0.identifier == Self.expandedDisclosureMarkerIdentifier
        }) as? GlyphView
    }

    private func makeDisclosureMarker(
        in rowView: NSTableRowView,
        behind button: NSButton
    ) -> GlyphView {
        let marker = GlyphView()
        marker.translatesAutoresizingMaskIntoConstraints = true
        rowView.addSubview(marker, positioned: .below, relativeTo: button)
        return marker
    }

    private func disclosureButton(in rowView: NSTableRowView) -> NSButton? {
        rowView.subviews.first(where: {
            $0.identifier == NSOutlineView.disclosureButtonIdentifier
        }) as? NSButton
    }

    /// Selection strength follows the window rather than list focus. The row's fill changes on
    /// those two transitions, so the system control sitting on that fill has to move with it.
    private func followWindowForDisclosureInk() {
        disclosureWindowEvents.removeAll()
        guard let window else { return }

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            disclosureWindowEvents.observe(name, object: window) { [weak self] in
                self?.refreshDisclosureInks()
            }
        }
    }

    /// See `ThemedTableRowDefaults.vendedView(for:recycling:)` — this is where a list that says
    /// nothing about selection still gets the theme's row, and where a view coming back out of
    /// the reuse queue is brought up to the theme in force.
    public override func makeView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        owner: Any?
    ) -> NSView? {
        ThemedTableRowDefaults.vendedView(
            for: identifier,
            recycling: super.makeView(withIdentifier: identifier, owner: owner)
        )
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let onContextMenu else {
            super.rightMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        _ = onContextMenu(row(at: point), .pointer(event.locationInWindow))
    }

    /// The pointerless route to the same menu, anchored to the selected row itself.
    public override func accessibilityPerformShowMenu() -> Bool {
        guard let onContextMenu, selectedRow >= 0 else {
            return super.accessibilityPerformShowMenu()
        }
        return onContextMenu(selectedRow, .control)
    }

    /// A press on the chevron itself never arrives here — the button is hit first. This is the
    /// band around it; see `disclosureHitOutsets`.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let button = disclosureButton(forPressAt: point) {
            button.performClick(nil)
            return
        }
        super.mouseDown(with: event)
    }

    /// Disclosure triangles are controls AppKit inserts into outline rows after the data source
    /// returns them. Permit only that identified system control; an ordinary button anywhere in
    /// a cell remains a runtime violation.
    public func permitsSystemChrome(_ view: NSView) -> Bool {
        guard let button = view as? NSButton else { return false }
        return button.identifier == NSOutlineView.disclosureButtonIdentifier
    }

    /// The sidebar's own case of `RowControls`, and the one the reports were about.
    public override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        if MainActor.assumeIsolated({
            RowControls.takesItsOwnClick(responder)
        }) {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

/// The containment seam for the one header the app has, replacing `NSTableHeaderView`.
///
/// Unlike AppKit's header cells, this draws both its surface and titles from semantic roles.
/// Mouse tracking and divider resizing remain `NSTableHeaderView` behavior; only its pixels are
/// replaced.
public class ThemedTableHeaderView: NSTableHeaderView, ThemedComponent {

    private var themeRedraw: ThemeRedraw?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func draw(_ dirtyRect: NSRect) {
        // The floating-surface rule (`ImageCompareView`, `ThemedTabItemView`): a fill that stands
        // over moving content is flattened over its ground, because `controlResting` is
        // deliberately below full opacity — 5% under Swiss Minimalist and most palette themes, and
        // only opaque under a few. That is right for a control on a panel and wrong for the one
        // surface in a table whose whole job is to hide what is behind it.
        //
        // Nothing opaque is behind it to help: `ThemedScrollView` turns its own background off in
        // `init`, and its `tile()` turns the header clip's off too. This fill is the only occluder
        // there is, which is why the log rows were legible straight through the column titles.
        Design.Surface.controlResting.composited(over: InkSource.chrome.ground).setFill()
        bounds.fill()

        guard let tableView else { return }

        for index in tableView.tableColumns.indices {
            let column = tableView.tableColumns[index]
            let rect = headerRect(ofColumn: index)
            let titleRect = rect.insetBy(dx: Design.Spacing.small, dy: Design.Spacing.tight)
            // A column states which edge its content is set against — a name reads from the
            // leading edge, a figure from the trailing one — and a heading that ignores it
            // stands over the wrong end of its own column. `NSTableColumn` already carries that
            // answer; taking it here is what keeps a caller from re-stating alignment twice.
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = column.headerCell.alignment
            paragraph.lineBreakMode = .byTruncatingTail
            (column.title as NSString).draw(
                in: titleRect,
                withAttributes: [
                    .font: Design.Typography.caption(),
                    .foregroundColor: Design.Text.secondary,
                    .paragraphStyle: paragraph
                ]
            )

            if index < tableView.tableColumns.count - 1 {
                Design.Surface.divider.setFill()
                NSRect(
                    x: rect.maxX - Design.Radius.border,
                    y: rect.minY,
                    width: Design.Radius.border,
                    height: rect.height
                ).fill()
            }
        }

        Design.Surface.divider.setFill()
        NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: Design.Radius.border
        ).fill()
    }
}
