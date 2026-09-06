import AppKit

/// Tables that start transparent, replacing `NSTableView` and `NSOutlineView`.
///
/// The stock background is `controlBackgroundColor` — a system surface that stays
/// system-white or system-charcoal on a page that has gone neon. Every table in the app
/// sits on a pane the theme already painted, so transparent is not a preference here, it
/// is the only value any call site ever wanted; the ones that forgot were bugs waiting
/// for a styled theme to expose them.
///
/// Selection is not claimed *here*, because a list's rows are the only thing that can draw it:
/// see `ThemedTableRowView`, which a list hands back from `rowViewForRow:` and the sidebar
/// answers its own way. How *strongly* they draw it is this file's, and every list's:
/// `ListSelectionStrength`.
public class ThemedTableView: NSTableView, ThemedComponent, SoleColumnFitting, SelectionStrengthStating {

    private lazy var selectionStrength = ListSelectionStrength(self)

    /// See `SoleColumnFitting`.
    public var soleColumnFitWidth: CGFloat = -1

    /// See `SelectionStrengthStating` — asked by this list's own rows as AppKit demotes them.
    public var drawsSelectionAtFullStrength: Bool { selectionStrength.drawsAsKey }

    /// See `ListSelectionStrength.fixtureIsKey`. Restated on both classes rather than shared,
    /// for the reason `ThemedOutlineView` gives: `NSOutlineView` is already an `NSTableView`.
    public var fixtureIsKey: Bool? {
        get { selectionStrength.fixtureIsKey }
        set { selectionStrength.fixtureIsKey = newValue }
    }

    /// A secondary click (or an accessibility "show menu") landed on a row — `-1` for the empty
    /// stretch below the last one. `ThemedOutlineView`'s hook, restated here for the same reason
    /// its own comment gives, and with the same contract: reported rather than handled, with the
    /// anchor the gesture carries, answering whether a menu actually opened.
    public var onContextMenu: ((Int, ThemedMenuAnchor) -> Bool)?

    /// Space over a row, and the trackpad's preview gesture on one — Finder's preview keys,
    /// answered here by the app's own inspector rather than the system panel.
    ///
    /// Reported rather than handled, on the same contract as `onContextMenu`: the host decides
    /// whether that row holds anything worth inspecting, and a `false` answer leaves the event
    /// with AppKit, so a list that has nothing to preview keeps type-select and the system
    /// gesture it would otherwise have swallowed.
    public var onQuickLook: ((Int) -> Bool)?

    /// A drag left this list without landing in it — the pointer went outside, or the whole drag
    /// ended.
    ///
    /// AppKit tells the *view* about both and the delegate about neither, which is fine while the
    /// list draws AppKit's own drop feedback and a problem the moment it draws its own: nothing
    /// else in the drop protocol ever fires, so a host's highlight would be left on the last row
    /// the pointer crossed. `draggingEnded` is included deliberately — a cancelled drag exits
    /// nothing.
    public var onDraggingExited: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewWillDraw() {
        super.viewWillDraw()
        fitSoleColumnToWidth()
        selectionStrength.apply()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selectionStrength.followWindow()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitSoleColumnToWidth()
    }

    public override func layout() {
        super.layout()
        fitSoleColumnToWidth()
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

    /// Bare Space on the selected row. A modifier makes it something else — Command-Space is
    /// Spotlight's — so only the unmodified key is claimed, and even then only if the host
    /// answers it.
    public override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " ",
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let onQuickLook,
              selectedRow >= 0,
              onQuickLook(selectedRow) else {
            super.keyDown(with: event)
            return
        }
    }

    /// The trackpad's preview gesture — three-finger tap, or a force click — on the row under
    /// the pointer rather than the selected one, because that is the row it was aimed at. The
    /// same route `ThemedImagePreview` takes for the same gesture.
    public override func quickLook(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard let onQuickLook, row >= 0, onQuickLook(row) else {
            super.quickLook(with: event)
            return
        }
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDraggingExited?()
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        onDraggingExited?()
    }
}

// MARK: - Virtual Content Rows

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

// MARK: - Column Fit

/// **A one-column list's column is as wide as the list.** Stated here because AppKit states it
/// nowhere, and the gap is invisible right up until it is catastrophic.
///
/// A programmatically built `NSTableColumn` starts at 100pt, and `columnAutoresizingStyle` only
/// redistributes width when the table's *frame* changes while the column is installed. A table
/// handed to a scroll view that already has its final size therefore never sees a frame change to
/// divide up and keeps the 100pt — and since `frameOfCell(atColumn:row:)` measures the *column*,
/// every cell is laid out 100pt wide inside a list hundreds of points wider. Nothing warns: the
/// constraints inside each cell are satisfiable at that width, so the row just wraps its content
/// into a ribbon and leaves the rest of the pane empty.
///
/// **This is how Git Review shipped broken.** Its diff arrives from a background git read, so
/// `documentView = fileTableView` happens long after the pane was laid out; a document-view swap
/// deep inside a scroll view does not lay out the *controller's* root view, so the pane's
/// `viewDidLayout` — the only thing calling `sizeLastColumnToFit()` — never ran. Every file card
/// came out 76pt wide in a 900pt pane, wrapping source three characters to a line. The repair
/// belongs to the list, because the list is what changed width: a host that has to remember to
/// call `sizeLastColumnToFit` is a host that will forget, and did.
///
/// Only for a *single* column. With two or more, which column absorbs the slack is a real
/// decision, and `NSTableColumn.resizingMask` is how a list states it.
///
/// A protocol rather than a helper object, because the hooks that drive it — `setFrameSize` above
/// all — run *during* `NSTableView.init`, before a subclass's stored properties would exist. A
/// property with a default value is initialized in phase one, so it is the one piece of state that
/// is always there to read.
@MainActor
public protocol SoleColumnFitting: NSTableView {

    /// The list width the sole column was last fitted to; negative until it has been.
    ///
    /// **Keyed on the list's width, not on the column's.** Asking only "is the column as wide as
    /// the list yet?" reads as the obvious test and never settles: `sizeLastColumnToFit()` is
    /// AppKit's own accounting, and under `.inset` — what `.automatic` resolves to — it
    /// deliberately keeps 16pt at each side, so the column it produces is 32pt short of the list
    /// by design. That test alone would be true forever, re-fitting on every frame and every draw.
    ///
    /// It is also the re-entry guard: `sizeLastColumnToFit()` re-tiles, which comes straight back
    /// through `setFrameSize`, and this is recorded *before* the call.
    var soleColumnFitWidth: CGFloat { get set }
}

@MainActor
extension SoleColumnFitting {

    public func fitSoleColumnToWidth() {
        guard bounds.width > 0, tableColumns.count == 1,
              let column = tableColumns.first else { return }

        // A column already standing exactly on the list's width is owed nothing, and is left
        // alone even the first time. **This is not an optimization.** `sizeLastColumnToFit()`
        // would subtract the style's own padding from it, and a list that had *stated* its column
        // — the sidebar's fixture does, and so does any list whose autoresizing works — would
        // have its cells pulled 32pt in under a row that stayed the same width. The trailing
        // buttons then hang outside the cell that hit-tests them, which is a defect this app has
        // already shipped once (`SidebarRowClickRoutingTests`).
        guard abs(column.width - bounds.width) > 0.5,
              abs(bounds.width - soleColumnFitWidth) > 0.5 else { return }

        soleColumnFitWidth = bounds.width
        sizeLastColumnToFit()
    }
}

// MARK: - Selection Strength

/// A list that states how strongly its selected rows draw, for the row that is about to be told
/// otherwise. See `ListSelectionStrength`, which holds the answer, and
/// `NSTableRowView.listSelectionStrength(insteadOf:)`, which asks it.
@MainActor
public protocol SelectionStrengthStating: AnyObject {

    /// Whether this list's selection draws at full strength right now.
    var drawsSelectionAtFullStrength: Bool { get }
}

extension NSTableRowView {

    /// The strength this row's list demands, or AppKit's own answer for a row that is not in one
    /// of ours.
    ///
    /// **The shared half of an override that cannot be shared.** `isEmphasized` is a property, so
    /// the override has to be restated in each row class — but the decision behind it is one, and
    /// it is here. A row's `superview` *is* its table, so there is nothing to wire up and nothing
    /// to keep in sync: a row asks the list it is in, or it is in no list of ours and AppKit's
    /// answer stands.
    public func listSelectionStrength(insteadOf appKitsAnswer: Bool) -> Bool {
        (superview as? SelectionStrengthStating)?.drawsSelectionAtFullStrength ?? appKitsAnswer
    }

    /// Take the list's strength now, for the one moment the refusal cannot cover: AppKit sets a
    /// row's emphasis while building it, *before* it has a superview to ask — measured, not
    /// assumed. Landing in the list is the first moment there is anything to ask.
    public func adoptListSelectionStrength() {
        let strength = listSelectionStrength(insteadOf: isEmphasized)
        guard isEmphasized != strength else { return }
        isEmphasized = strength
    }
}

/// **A list draws its selection at the strength of its window, never of the focus inside it.**
///
/// AppKit's rule is the other one: `NSTableRowView.isEmphasized` follows the *first responder*,
/// so a list that does not hold focus shows the quiet fill — a flat grey under **System**, and
/// whatever each theme holds back for `accentMuted` elsewhere. That is right for an app where a
/// click leaves focus in the list it landed in, and this is not one. Selecting a session attaches
/// its controller and calls `focusTerminal`, so the row a click had just selected was demoted a
/// turn later, into a fill a hair from the hover wash; the second click selected nothing new,
/// presented no session, took no focus, and was the one that appeared to work. *First tap hovers,
/// second tap selects*, for a pane that had been showing the right session since the first.
///
/// It is the second report of one defect. `ThemedIconButton.mouseDown` used to take first
/// responder, which recoloured a **different** row's selection and read as random (see
/// `design-system.md`); that was fixed by having one control stop taking focus, which left every
/// other way of taking it — the terminal, the composer, a web view, the next thing — still able
/// to reintroduce it. So the rule is stated where it cannot be missed instead of defended at each
/// place focus moves.
///
/// **The rule lives on the list; the refusal has to live on the row.** `ThemedTableView` and
/// `ThemedOutlineView` are provably every list in the app — subclassing `NSTableView` or
/// `NSOutlineView` anywhere else fails `scripts/check_theme_boundaries.sh` — so this is where the
/// answer is decided, once. It is *applied* in two places, because one of them does not fire when
/// it matters:
///
/// - `apply()`, from `viewWillDraw`, catches the rows AppKit builds demoted. It has to: a row is
///   given its emphasis before it has a superview to ask, so it cannot refuse anything yet.
/// - `NSTableRowView.listSelectionStrength(insteadOf:)`, from each row class's `isEmphasized`,
///   catches every demotion after that — by declining it where it arrives.
///
/// **The second exists because the first was measured not to run.** The rule shipped as
/// `viewWillDraw` alone and the defect was reported again against the built app, with every test
/// still passing: the tests draw through `cacheDisplay`, which forces a recursive draw from the
/// host and therefore always reaches the list. Nothing in a running window does. Every window is
/// layer-backed on modern macOS, so a demoted row repaints from its *own* layer and the list it
/// sits in is never asked to draw at all — probed directly, `viewWillDraw` fires once for the
/// first paint and not once more as focus comes and goes. A hook at the draw cannot hold a rule
/// the draw skips.
///
/// So the row is asked as AppKit sets it, which is the true last point and needs no draw, no
/// notification and no ordering. Rows stay nearly dumb: they read `isEmphasized` and draw, and
/// the one thing they know is which list to ask before believing a demotion.
@MainActor
public final class ListSelectionStrength {

    /// Key state stated by a fixture. An unshown test window is never key, and the emphasized
    /// selection is the state worth asserting, so without this the rule is unrenderable outside
    /// a window ordered on screen — which `Threading-Fast` is built to avoid.
    public var fixtureIsKey: Bool? {
        didSet { apply() }
    }

    private weak var table: NSTableView?
    private let windowStateObservations = AppEventObservations()

    public init(_ table: NSTableView) {
        self.table = table
    }

    /// Re-asserted from `viewWillDraw`, which is the last moment before any row of this list
    /// paints and therefore the one place that covers every way a row can arrive demoted: AppKit
    /// lowering all of them when the list resigns, and a row built later while scrolling. Rows
    /// already holding the right answer are left alone, so this costs a comparison per visible
    /// row and no invalidation.
    public func apply() {
        guard let table else { return }

        let emphasized = drawsAsKey
        table.enumerateAvailableRowViews { row, _ in
            guard row.isEmphasized != emphasized else { return }
            row.isEmphasized = emphasized
        }
    }

    /// The window's own transitions, which nothing else would repaint: to AppKit an unfocused
    /// list is unemphasized before and after its window comes back, so it has no change to report
    /// and no row to invalidate. Applied directly rather than by invalidating the list, because
    /// raising a row's emphasis is what marks that row for display.
    public func followWindow() {
        windowStateObservations.removeAll()

        defer { apply() }
        guard let window = table?.window else { return }

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification
        ] {
            windowStateObservations.observe(name, object: window) { [weak self] in
                self?.apply()
            }
        }
    }

    /// A list with no window yet draws its key form, the same answer `WindowChromeButton` gives:
    /// a fixture is not a background window.
    ///
    /// Read by the list's `drawsSelectionAtFullStrength`, which is what a row about to be demoted
    /// asks — so this is the single answer both halves of the rule are applying.
    public var drawsAsKey: Bool {
        guard let window = table?.window else { return fixtureIsKey ?? true }
        return fixtureIsKey ?? window.isKeyWindow
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

/// A selectable document table whose cell geometry is known when it is built.
///
/// Markdown tables previously nested one vertical stack, one horizontal stack per row, one
/// wrapper per cell and six constraints per value. A table in a transcript is already one
/// semantic block and never edits its column structure, so asking Auto Layout to rediscover that
/// grid on every scroll tick is pure overhead. This component measures the attributed cell text
/// once, places the labels directly, and draws header/separator surfaces from live design roles.
public final class ThemedDocumentTableView: NSView, ThemedComponent {
    private let scrollView = ThemedScrollView()
    private let canvas: ThemedDocumentTableCanvas
    private var themeRedraw: ThemeRedraw?

    public init(
        headers: [NSAttributedString],
        rows: [[NSAttributedString]],
        alignments: [NSTextAlignment],
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat
    ) {
        canvas = ThemedDocumentTableCanvas(
            headers: headers,
            rows: rows,
            alignments: alignments,
            availableWidth: availableWidth,
            minimumColumnWidth: minimumColumnWidth
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)
        applySurface(
            // The panel role already states its intended strength. Replacing its alpha here
            // amplified System's deliberately quiet 5% label wash to 45%, producing the same
            // heavy mid-gray slab in light and dark appearances.
            fill: Design.Surface.panel,
            radius: .control
        )

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollHandoff = .always
        scrollView.documentView = canvas
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged, newSize.width > 0 else { return }
        if canvas.updateAvailableWidth(newSize.width) {
            invalidateIntrinsicContentSize()
        }
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: canvas.frame.height)
    }
}

/// The fixed document inside `ThemedDocumentTableView`. Labels remain ordinary selectable text;
/// only the cell wrappers and constraint graph disappear.
private final class ThemedDocumentTableCanvas: NSView, ThemedComponent {
    private struct Cell {
        let field: NSTextField
        let column: Int
    }

    /// Everything the immutable grid needs before the `NSView` exists.
    ///
    /// Keeping this work out of the subclass initializer is not cosmetic. Swift 6.3's
    /// ownership optimizer loses the initializer's `self` lifetime when the pre-`super`
    /// path contains the former nested `map`/key-path normalization and aborts every Release
    /// build in `OSSACompleteLifetime`. The direct pass also avoids cloning the complete
    /// attributed-string matrix merely to pad ragged rows; missing cells are materialized only
    /// where the finished grid actually needs one.
    private struct PreparedGrid {
        let cellsByRow: [[Cell]]
        let rowHeights: [CGFloat]
        let columnCount: Int
        let columnWidth: CGFloat
        let documentWidth: CGFloat
        let documentHeight: CGFloat
    }

    private let cellsByRow: [[Cell]]
    private let columnCount: Int
    private let minimumColumnWidth: CGFloat
    private var rowHeights: [CGFloat]
    private var columnWidth: CGFloat
    private let cellInset = Design.Spacing.small
    private let separatorWidth = Design.Radius.border
    private var themeRedraw: ThemeRedraw?

    override var isFlipped: Bool { true }

    init(
        headers: [NSAttributedString],
        rows: [[NSAttributedString]],
        alignments: [NSTextAlignment],
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat
    ) {
        let prepared = Self.prepareGrid(
            headers: headers,
            rows: rows,
            alignments: alignments,
            availableWidth: availableWidth,
            minimumColumnWidth: minimumColumnWidth
        )
        cellsByRow = prepared.cellsByRow
        rowHeights = prepared.rowHeights
        columnCount = prepared.columnCount
        self.minimumColumnWidth = minimumColumnWidth
        columnWidth = prepared.columnWidth
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: prepared.documentWidth,
            height: prepared.documentHeight
        ))
        themeRedraw = ThemeRedraw(self)
        setAccessibilityRole(.table)

        for row in cellsByRow {
            for cell in row { addSubview(cell.field) }
        }
        placeCells()
    }

    private static func prepareGrid(
        headers: [NSAttributedString],
        rows: [[NSAttributedString]],
        alignments: [NSTextAlignment],
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat
    ) -> PreparedGrid {
        var widestRow = headers.count
        for values in rows {
            widestRow = max(widestRow, values.count)
        }
        let columnCount = max(widestRow, 1)
        let documentWidth = max(availableWidth, CGFloat(columnCount) * minimumColumnWidth)
        let columnWidth = documentWidth / CGFloat(columnCount)
        var builtRows: [[Cell]] = []
        var heights: [CGFloat] = []
        builtRows.reserveCapacity(rows.count + 1)
        heights.reserveCapacity(rows.count + 1)

        for rowIndex in 0...rows.count {
            let values = rowIndex == 0 ? headers : rows[rowIndex - 1]
            var builtCells: [Cell] = []
            var rowHeight: CGFloat = 0
            builtCells.reserveCapacity(columnCount)

            for column in 0..<columnCount {
                let source = column < values.count
                    ? values[column]
                    : NSAttributedString(string: "")
                let attributed: NSAttributedString
                if rowIndex == 0 {
                    let emphasized = NSMutableAttributedString(attributedString: source)
                    emphasized.addAttribute(
                        .foregroundColor,
                        value: Design.Text.label,
                        range: NSRange(location: 0, length: emphasized.length)
                    )
                    attributed = emphasized
                } else {
                    attributed = source
                }

                let field = NSTextField(labelWithAttributedString: attributed)
                field.isSelectable = true
                field.lineBreakMode = .byWordWrapping
                field.maximumNumberOfLines = 0
                field.alignment = column < alignments.count ? alignments[column] : .left
                builtCells.append(Cell(field: field, column: column))

                let textWidth = max(1, columnWidth - Design.Spacing.small * 2)
                let textBounds = attributed.boundingRect(
                    with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                let fontHeight: CGFloat
                if attributed.length > 0,
                   let font = attributed.attribute(
                       .font,
                       at: 0,
                       effectiveRange: nil
                   ) as? NSFont {
                    fontHeight = ceil(font.ascender - font.descender + font.leading)
                } else {
                    fontHeight = 0
                }
                rowHeight = max(rowHeight, ceil(textBounds.height), fontHeight)
            }

            builtRows.append(builtCells)
            heights.append(rowHeight + Design.Spacing.small * 2)
        }

        let separators = CGFloat(max(0, heights.count - 1)) * Design.Radius.border
        return PreparedGrid(
            cellsByRow: builtRows,
            rowHeights: heights,
            columnCount: columnCount,
            columnWidth: columnWidth,
            documentWidth: documentWidth,
            documentHeight: heights.reduce(0, +) + separators
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Reflows the fixed grid only when the pane's settled width changes. The old stack-based
    /// table received this through Auto Layout at considerable cost; direct placement still has
    /// to preserve that behavior so a pane resize cannot leave stale wrapping or row heights.
    @discardableResult
    func updateAvailableWidth(_ availableWidth: CGFloat) -> Bool {
        let documentWidth = max(
            availableWidth,
            CGFloat(columnCount) * minimumColumnWidth
        )
        guard abs(documentWidth - frame.width) > 0.5 else { return false }

        let previousHeight = frame.height
        columnWidth = documentWidth / CGFloat(columnCount)
        rowHeights = cellsByRow.map(measuredHeight)
        let separators = CGFloat(max(0, rowHeights.count - 1)) * separatorWidth
        frame.size = NSSize(
            width: documentWidth,
            height: rowHeights.reduce(0, +) + separators
        )
        placeCells()
        needsDisplay = true
        return abs(frame.height - previousHeight) > 0.5
    }

    private func measuredHeight(for row: [Cell]) -> CGFloat {
        var rowHeight: CGFloat = 0
        let textWidth = max(1, columnWidth - cellInset * 2)
        for cell in row {
            let attributed = cell.field.attributedStringValue
            let textBounds = attributed.boundingRect(
                with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let fontHeight: CGFloat
            if attributed.length > 0,
               let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                fontHeight = ceil(font.ascender - font.descender + font.leading)
            } else {
                fontHeight = 0
            }
            rowHeight = max(rowHeight, ceil(textBounds.height), fontHeight)
        }
        return rowHeight + cellInset * 2
    }

    private func placeCells() {
        var y: CGFloat = 0
        for (row, height) in zip(cellsByRow, rowHeights) {
            for cell in row {
                cell.field.frame = NSRect(
                    x: CGFloat(cell.column) * columnWidth + cellInset,
                    y: y + cellInset,
                    width: max(1, columnWidth - cellInset * 2),
                    height: max(1, height - cellInset * 2)
                )
            }
            y += height + separatorWidth
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let headerHeight = rowHeights.first {
            Design.Surface.controlHover.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight).fill()
        }

        Design.Surface.divider.setFill()
        var y: CGFloat = 0
        for height in rowHeights.dropLast() {
            y += height
            NSRect(x: 0, y: y, width: bounds.width, height: separatorWidth).fill()
            y += separatorWidth
        }
    }
}
