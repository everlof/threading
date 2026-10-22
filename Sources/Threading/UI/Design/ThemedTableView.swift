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

    /// Whether the sole column deliberately fills the table's complete bounds instead of
    /// preserving AppKit's table-style gutters. Embedded card tables opt in; being embedded is
    /// not itself the decision, because the sidebar outline is embedded too and its inset band
    /// is where narrow-width density reclaims space.
    public var soleColumnFillsBoundsExactly = false

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

    /// Edit ▸ Copy (⌘C) with this list focused, for a list whose rows hold their own selection —
    /// text chosen across several rows, say — rather than AppKit's row selection. Reported rather
    /// than handled, on `onContextMenu`'s contract; `canCopy` is what enables the menu item, so a
    /// list with nothing chosen does not offer to copy nothing.
    public var onCopy: (() -> Void)?
    public var canCopy: (() -> Bool)?

    /// Edit ▸ Select All (⌘A) for the same kind of list. Answering `false` leaves AppKit's own
    /// row selection to handle it.
    public var onSelectAll: (() -> Bool)?

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
        _ = fitExactSoleColumn(to: newSize.width)
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
        #if os(Linux)
        return super.makeView(withIdentifier: identifier, owner: owner)
        #else
        ThemedTableRowDefaults.vendedView(
            for: identifier,
            recycling: super.makeView(withIdentifier: identifier, owner: owner)
        )
        #endif
    }

    public override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        #if !os(Linux)
        if MainActor.assumeIsolated({
            RowControls.takesItsOwnClick(responder)
        }) {
            return true
        }
        #endif
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
        #if os(Linux)
        let command = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
        if command, event.charactersIgnoringModifiers == "c", canCopy?() == true {
            onCopy?()
            return
        }
        if command, event.charactersIgnoringModifiers == "a", onSelectAll?() == true {
            return
        }
        #endif
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

    #if !os(Linux)
    @objc
    #endif
    public func copy(_ sender: Any?) {
        onCopy?()
    }

    public override func selectAll(_ sender: Any?) {
        if onSelectAll?() == true { return }
        super.selectAll(sender)
    }

    /// Only `copy(_:)` is answered here: it is this class's own action, and a list that states
    /// no `canCopy` has nothing to copy. Everything else is AppKit's decision.
    #if !os(Linux)
    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return canCopy?() ?? false
        }
        return super.validateUserInterfaceItem(item)
    }
    #endif
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

    /// An explicit opt-in for a table whose cell is the complete embedded surface. AppKit's
    /// style padding remains load-bearing for ordinary lists, including the sidebar.
    var soleColumnFillsBoundsExactly: Bool { get set }
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
        if !fitExactSoleColumn(to: bounds.width) { sizeLastColumnToFit() }
    }

    /// Own an explicitly edge-to-edge column before AppKit commits a frame. A pending table tile
    /// can run on the first bounds read and restore the old column width, losing the requested
    /// size. The policy is explicit rather than inferred from the superview: both card tables and
    /// the sidebar outline are embedded, but only the former has no table-style gutter.
    func fitExactSoleColumn(to width: CGFloat) -> Bool {
        guard soleColumnFillsBoundsExactly, width > 0,
              tableColumns.count == 1, let column = tableColumns.first else { return false }
        guard abs(column.width - width) > 0.5 else { return true }
        soleColumnFitWidth = width
        column.width = width
        return true
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
