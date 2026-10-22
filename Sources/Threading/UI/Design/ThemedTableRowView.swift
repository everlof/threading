import AppKit

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
        #if os(Linux)
        guard isSelected else { return }
        (isEmphasized ? Design.Surface.selectionFill
                       : Design.Surface.selectionFillUnemphasized).setFill()
        platePath.fill()
        #else
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
        #endif
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
        #if !os(Linux)
        guard AppThemeLibrary.current.isSystem else {
            return SelectionSurface.quiet(over: resolvedGround()).ground
        }
        #endif
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
        #if os(Linux)
        return (superview as? NSTableView)?.style == .inset
            ? path(insetBy: ThemedTableRowDefaults.systemInsetStylePadding)
            : selectionPath
        #else
        guard AppThemeLibrary.current.isSystem else { return selectionPath }
        switch (superview as? NSTableView)?.effectiveStyle {
        case .inset, .sourceList:
            return path(insetBy: ThemedTableRowDefaults.systemInsetStylePadding)
        default:
            return selectionPath
        }
        #endif
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
            #if !os(Linux)
            // `assumeIsolated` for the reason `validateProposedFirstResponder` gives: AppKit
            // calls the override above on the main thread and says so nowhere in its types.
            MainActor.assumeIsolated { AppThemeRefresh.repaintIfNeeded(recycled) }
            #endif
            return recycled
        }
        guard identifier == rowViewKey else { return nil }

        #if os(Linux)
        return MainActor.assumeIsolated {
            let row = ThemedTableRowView()
            row.identifier = identifier
            return row
        }
        #else
        let row = ThemedTableRowView()
        row.identifier = identifier
        return row
        #endif
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
