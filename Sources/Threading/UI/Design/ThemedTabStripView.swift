import AppKit

// MARK: - Tab Strip Item

/// One tab's worth of strip data, so a strip can draw itself without reaching into a tab's
/// live content.
struct TabStripItem {
    let id: UUID
    let title: String
    let symbolName: String
    let isActive: Bool

    /// What the title names, so a *rename* can be told from a chip being re-pointed at
    /// something else — only the first morphs. Defaults to the id: a tab that keeps its id and
    /// changes its title is renaming itself.
    let identity: AnyHashable?

    /// Overrides the strip's own answer for this one chip. Nil means "whatever the strip does",
    /// which is what every ordinary tab wants. A chip that *stands for* something rather than
    /// holding it — the proxy for a page now in a window of its own — sets `false`, because a ✕
    /// on it would have to mean something, and every honest meaning is either destructive from a
    /// misclick or inconsistent with the ✕ on every other chip.
    let showsClose: Bool?

    init(
        id: UUID,
        title: String,
        symbolName: String,
        isActive: Bool,
        identity: AnyHashable? = nil,
        showsClose: Bool? = nil
    ) {
        self.showsClose = showsClose
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.isActive = isActive
        self.identity = identity
    }
}

// MARK: - Tab Strip

/// The horizontal strip of tabs at the top of a tab-hosting pane, in the app's flat, quiet
/// style: the display panel's header and the drawer's are both this one component.
///
/// It was the display pane's private strip first, and the geometry a second pane would have had
/// to repeat — the scroll-not-shrink overflow, the clipped-edge fade, the chip spacing, the
/// reorder gesture — is exactly what the theme boundary says a component must own. The strip
/// owns no tab *state*: it draws the items it is handed and reports selection, closing and
/// reordering back to its host.
///
/// Chips are reused keyed by the item's id rather than rebuilt per update. That is load-bearing
/// three ways: a rename can morph only in a label that survives the update, a drag can only
/// continue in a chip that is not torn down mid-gesture, and reordering can only animate views
/// that persist across the change.
final class ThemedTabStripView: NSView {

    // MARK: - Geometry

    /// The band a tab strip sits in — one silhouette shared with every pane header, so strips
    /// in different panes land their hairlines on one line across the splits.
    static var bandHeight: CGFloat { PaneHeaderView.bandHeight }

    // MARK: - Callbacks

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    /// A chip was dragged to a new slot. Reports the tab and its position in the list as it
    /// stands after the move; the host mutates its model and re-renders.
    var onReorder: ((UUID, Int) -> Void)?

    /// What else can be done with a tab, offered on secondary click and through accessibility.
    /// The entries come from the host because they are model decisions — the strip only
    /// presents them.
    var contextEntries: ((UUID) -> [ThemedMenuEntry])?

    /// Asked while a drag travels, with the pointer in **window** coordinates: would a drop
    /// here — outside this strip — land the tab somewhere? Where else a tab could live is the
    /// window's knowledge, so the strip only asks. Non-nil wiring is also what lets a *lone*
    /// chip begin a drag at all: with one tab there is nothing to reorder, but still somewhere
    /// to go. The context menu's "Move to …" remains the pointerless twin of this gesture.
    var externalDropTarget: ((UUID, NSPoint) -> Bool)?

    /// The drag ended on a spot the last `externalDropTarget` said yes to. The host performs
    /// the move; the strip has already put its own geometry back.
    var onDropOut: ((UUID, NSPoint) -> Void)?

    /// Every drag's last word, dropped out or not — after `onDropOut`/`onReorder`. What lets
    /// the window settle anything it arranged for the drag's benefit (a pane sprung open, a
    /// destination highlight) without guessing when the gesture is over.
    var onDragEnded: ((UUID) -> Void)?

    /// Another strip's chip is travelling and would land here. Drawn as a quiet wash over the
    /// band — the resting surface fill, nothing louder: the dimmed traveller already says a
    /// move is happening, this only answers *where*.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            needsDisplay = true
        }
    }

    // MARK: - Configuration

    /// Widest a chip may grow before its title truncates. Applied to chips as they are made;
    /// hosts set it once at setup.
    var chipMaxWidth: CGFloat?

    /// Set by a host that pins **both** of the strip's edges, so the strip stretches to the room
    /// it is given instead of hugging its tabs.
    ///
    /// The default is the other arrangement — `intrinsicContentSize` plus `.defaultHigh` hugging,
    /// which is what lets a host place a control *after* the tabs and have it follow them. Pin
    /// both edges without saying this and that hugging becomes a **maximum on the host**: at 750
    /// it outranks the priority `NSSplitViewController` positions a pane with
    /// (`DisplayPaneDefaults.holdingPriority`, 260), so the display panel could not be dragged
    /// wider than its own tab titles — the divider stopped dead a few points past the `+`, and
    /// where it stopped moved with the length of the page's name. Below that priority the strip
    /// is stretched and the divider is the user's to place, which is the whole point of a strip
    /// that scrolls rather than shrinks.
    var fillsHostWidth = false {
        didSet {
            guard fillsHostWidth != oldValue else { return }
            setContentHuggingPriority(
                fillsHostWidth ? .defaultLow : .defaultHigh,
                for: .horizontal
            )
            invalidateIntrinsicContentSize()
        }
    }

    private let inkSource: InkSource
    private let showsClose: Bool

    /// Wraps a freshly made chip in a host-owned container — how the display panel keeps its
    /// extension slot around each tab without this component knowing extensions exist. The
    /// returned view is what the strip arranges; returning the chip itself is the default.
    var chipDecorator: ((ThemedTabItemView, UUID) -> NSView)?

    // MARK: - Views

    private let stack = NSStackView()
    private let scrollView = ThemedScrollView()
    private let contentAreaGuide = NSLayoutGuide()

    /// The row above the host's separator. Controls beside the strip use this anchor so a heavy
    /// rule cannot pull the tab and its neighbouring actions onto different centrelines.
    var contentCenterYAnchor: NSLayoutYAxisAnchor { contentAreaGuide.centerYAnchor }

    private lazy var contentBottomConstraint = contentAreaGuide.bottomAnchor.constraint(
        equalTo: bottomAnchor,
        constant: -Design.Radius.border
    )
    private let appEvents = AppEventObservations()
    private var appliedBandHeight: CGFloat?

    private struct Chip {
        let tab: ThemedTabItemView
        /// The view the stack arranges: the decorated container, or the tab itself.
        let arranged: NSView
    }

    private var chipsByID: [UUID: Chip] = [:]
    private var orderedIDs: [UUID] = []
    private var contextMenuSession: AnyObject?

    /// Fades the strip's clipped edge instead of cutting a tab off mid-label.
    ///
    /// The strip scrolls rather than shrinking its chips, so in a narrow pane a tab ends in a
    /// hard vertical slice against whatever sits beside it — which reads as a defect, not as
    /// "there is more". A short alpha ramp at whichever edge actually clips is the quiet
    /// version of a scroll affordance: it appears only while there is content beyond it, and
    /// only on that side. Alpha-only, so no theme owns it and no appearance can strand it.
    private let fadeMask = CAGradientLayer()
    private static let fadeLength: CGFloat = Design.Spacing.large

    // MARK: - Initialization

    init(inkSource: InkSource, showsClose: Bool = true) {
        self.inkSource = inkSource
        self.showsClose = showsClose
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // **Below `.fittingSizeCompression`, not merely below the default.** A strip squeezed for
        // room scrolls, so it must never be read as a measurement of its host — and 240 said that
        // only to *layout*. `fittingSize` resolves at priority 50, so at 240 the strip still
        // charged whoever asked the full width of its tabs: the display panel's fitting width was
        // its widest tab plus its own chrome, which is the window's minimum
        // (`DisplayPaneDefaults.slimmestWidth`). That is the same mistake the panel's caption and
        // placeholder were already fixed for — see `DisplayPaneController.setupContent` — and the
        // strip is the last thing in that pane still making it. It shows as a panel whose smallest
        // width moves with the name of the page open in it.
        setContentCompressionResistancePriority(
            Design.Priority.belowFittingSize,
            for: .horizontal
        )

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.tight
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: Design.Spacing.small,
            bottom: 0, right: Design.Spacing.small
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addLayoutGuide(contentAreaGuide)

        scrollView.wantsLayer = true
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        scrollView.layer?.mask = fadeMask

        // The fade follows the scroll position as well as the width: scrolling to the end must
        // take the trailing ramp with it, or the last tab would fade for nothing.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateFade),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NSLayoutConstraint.activate([
            contentAreaGuide.topAnchor.constraint(equalTo: topAnchor),
            contentBottomConstraint,
            contentAreaGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentAreaGuide.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: contentAreaGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentAreaGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // The document is as tall as the clip and only as wide as its chips, which is what
            // makes the overflow scroll sideways rather than the chips wrapping or squashing.
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor)
        ])

        applyMetrics()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyMetrics() }
    }

    // MARK: - Update

    /// Reconciles the chips against the given items: stale chips leave, new items get chips,
    /// surviving chips are updated in place and moved to their item's position.
    func update(items: [TabStripItem]) {
        // A model update mid-drag would rebuild the slots under the gesture; the drag's own
        // reorder lands when it ends, and the deferred items land right after.
        guard drag == nil else {
            pendingItems = items
            return
        }

        orderedIDs = items.map(\.id)
        let known = Set(orderedIDs)

        for (id, chip) in chipsByID where !known.contains(id) {
            if stack.arrangedSubviews.contains(chip.arranged) {
                stack.removeArrangedSubview(chip.arranged)
            }
            chip.arranged.removeFromSuperview()
            chipsByID.removeValue(forKey: id)
        }

        for (index, item) in items.enumerated() {
            let chip = chipsByID[item.id] ?? makeChip(for: item)
            chip.tab.update(
                title: item.title,
                symbolName: item.symbolName,
                showsClose: item.showsClose ?? showsClose,
                identity: item.identity ?? AnyHashable(item.id)
            )
            chip.tab.isSelected = item.isActive

            let inPlace = stack.arrangedSubviews.indices.contains(index)
                && stack.arrangedSubviews[index] === chip.arranged
            if !inPlace {
                if stack.arrangedSubviews.contains(chip.arranged) {
                    stack.removeArrangedSubview(chip.arranged)
                }
                stack.insertArrangedSubview(
                    chip.arranged,
                    at: min(index, stack.arrangedSubviews.count)
                )
            }
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The live chip for a tab, so a host can anchor something to it and tests can drive it.
    func chipView(for id: UUID) -> ThemedTabItemView? {
        chipsByID[id]?.tab
    }

    /// The slot a drop at this window point would take: how many resting chips the pointer
    /// has passed — the same midpoint rule the reorder gesture uses, so a cross-pane drop
    /// lands by the geometry a within-strip drag taught.
    func insertionIndex(forWindowPoint point: NSPoint) -> Int {
        let pointer = stack.convert(point, from: nil)
        return stack.arrangedSubviews.count { $0.frame.midX < pointer.x }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isDropTarget else { return }
        ThemedSurface.draw(
            bounds,
            fill: inkSource.ink.surface,
            border: nil,
            radius: Design.Radius.control
        )
    }

    private func makeChip(for item: TabStripItem) -> Chip {
        let id = item.id
        let tab = ThemedTabItemView(
            title: item.title,
            symbolName: item.symbolName,
            placement: .horizontal,
            showsClose: item.showsClose ?? showsClose,
            inkSource: inkSource
        )
        tab.onSelect = { [weak self] in self?.onSelect?(id) }
        tab.onClose = { [weak self] in self?.onClose?(id) }
        tab.onContextMenu = { [weak self] (anchor: ThemedMenuAnchor) -> Bool in
            guard let self else { return false }
            return self.presentContextMenu(for: id, at: anchor)
        }
        tab.onDrag = { [weak self] phase, event in
            self?.handleDrag(of: id, phase: phase, event: event)
        }
        if let chipMaxWidth {
            // Both: the constraint is the guarantee, and telling the tab its own cap is what
            // lets it size to the title it will *draw* rather than to the room the cap allows
            // — see `ThemedTabItemView.maxWidth`.
            tab.maxWidth = chipMaxWidth
            tab.widthAnchor.constraint(lessThanOrEqualToConstant: chipMaxWidth).isActive = true
        }

        let arranged = chipDecorator?(tab, id) ?? tab
        arranged.wantsLayer = true
        let chip = Chip(tab: tab, arranged: arranged)
        chipsByID[id] = chip
        return chip
    }

    // MARK: - Context Menu

    /// Answers whether a menu opened, which is what the chip's accessibility route reports.
    @discardableResult
    private func presentContextMenu(for id: UUID, at anchor: ThemedMenuAnchor) -> Bool {
        guard let entries = contextEntries?(id),
              entries.contains(where: { if case .item = $0 { true } else { false } }),
              let chip = chipsByID[id] else { return false }
        contextMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: chip.tab.bounds.width),
            from: chip.tab,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.contextMenuSession = nil }
        )
        return contextMenuSession != nil
    }

    // MARK: - Reorder

    private struct DragState {
        let id: UUID
        /// Pointer-to-chip-leading distance at the grab, in stack coordinates, so the chip
        /// stays under the fingers rather than snapping its edge to the pointer.
        let grabOffsetX: CGFloat
        let originalIndex: Int
        var currentIndex: Int
        /// The pointer is over another pane that would take this tab; the chip dims to say it
        /// is on its way out, and the drop hands it over instead of reordering.
        var isOverExternal = false
    }

    private var drag: DragState?

    /// Items that arrived while a drag was in flight, applied when it lands.
    private var pendingItems: [TabStripItem]?

    private func handleDrag(of id: UUID, phase: ThemedTabItemView.DragPhase, event: NSEvent) {
        switch phase {
        case .began: beginDrag(of: id, event: event)
        case .changed: continueDrag(event: event)
        case .ended: endDrag(event: event)
        }
    }

    private func beginDrag(of id: UUID, event: NSEvent) {
        // A drag needs somewhere to go: a second slot in this strip, or another pane that
        // takes drops. A lone tab with no wired destination stays a click.
        guard onReorder != nil || onDropOut != nil,
              orderedIDs.count > 1 || onDropOut != nil,
              let chip = chipsByID[id],
              let index = stack.arrangedSubviews.firstIndex(where: { $0 === chip.arranged })
        else { return }

        let pointer = stack.convert(event.locationInWindow, from: nil)
        drag = DragState(
            id: id,
            grabOffsetX: pointer.x - chip.arranged.frame.minX,
            originalIndex: index,
            currentIndex: index
        )
        // Above its siblings while it travels, so the lifted chip is never sliced by the
        // neighbour it is crossing — and opaque, so the neighbour does not show through it.
        chip.arranged.layer?.zPosition = 1
        chip.tab.isLifted = true
    }

    private func continueDrag(event: NSEvent) {
        guard var state = drag, let chip = chipsByID[state.id] else { return }
        let arranged = chip.arranged

        let overExternal = externalDropTarget?(state.id, event.locationInWindow) ?? false
        if overExternal != state.isOverExternal {
            state.isOverExternal = overExternal
            arranged.alphaValue = overExternal ? Design.Opacity.dragAway : 1
        }

        let pointer = stack.convert(event.locationInWindow, from: nil)
        let width = arranged.frame.width
        let desiredMinX = min(
            max(pointer.x - state.grabOffsetX, 0),
            max(stack.bounds.width - width, 0)
        )

        // The slot the travelling chip is over: how many resting chips its midpoint has
        // passed. Frozen while the pointer is over another pane — a chip about to leave has
        // no business rearranging the strip it is leaving.
        if !overExternal {
            let midX = desiredMinX + width / 2
            let target = stack.arrangedSubviews
                .filter { $0 !== arranged }
                .count { $0.frame.midX < midX }

            if target != state.currentIndex {
                stack.removeArrangedSubview(arranged)
                stack.insertArrangedSubview(arranged, at: target)
                state.currentIndex = target
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Design.Motion.quick
                    context.allowsImplicitAnimation = true
                    stack.layoutSubtreeIfNeeded()
                }
            }
        }
        drag = state

        // The transform, not the frame: layout still owns the slot, the gesture only borrows
        // the pixels. Actions are disabled so the chip tracks the pointer instead of easing
        // after it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arranged.layer?.setAffineTransform(
            CGAffineTransform(translationX: desiredMinX - arranged.frame.minX, y: 0)
        )
        CATransaction.commit()
    }

    private func endDrag(event: NSEvent) {
        guard let state = drag else { return }
        drag = nil

        if let chip = chipsByID[state.id] {
            // Landing over another pane restores the strip's geometry without ceremony — the
            // tab is about to leave it, and an eased return under a disappearing chip reads
            // as a refusal.
            if state.isOverExternal {
                chip.arranged.layer?.setAffineTransform(.identity)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Design.Motion.quick
                    context.allowsImplicitAnimation = true
                    chip.arranged.layer?.setAffineTransform(.identity)
                }
            }
            chip.arranged.layer?.zPosition = 0
            chip.arranged.alphaValue = 1
            chip.tab.isLifted = false
        }

        if state.isOverExternal {
            onDropOut?(state.id, event.locationInWindow)
        } else if state.currentIndex != state.originalIndex {
            onReorder?(state.id, state.currentIndex)
        }
        if let items = pendingItems {
            pendingItems = nil
            update(items: items)
        }
        onDragEnded?(state.id)
    }

    // MARK: - Sizing

    /// As wide as its chips want to be, so hosts that place things *after* the strip — a `+`,
    /// a usage pill — can follow its content. Compression is deliberately easy to win: a strip
    /// squeezed for room scrolls, it never squeezes its neighbours.
    ///
    /// A host that pins both edges says so with `fillsHostWidth`, and pinning is *not* enough on
    /// its own: the pins fix the strip's width against the **host's**, which leaves the hugging
    /// priority to argue with whatever places the host — see that property.
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(stack.fittingSize.width), height: Self.bandHeight)
    }

    // MARK: - Overflow Fade

    override func layout() {
        applyMetrics()
        super.layout()
        updateFade()
    }

    private func applyMetrics() {
        let height = Self.bandHeight
        guard appliedBandHeight != height else { return }
        appliedBandHeight = height
        contentBottomConstraint.constant = -Design.Radius.border
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func updateFade() {
        let clip = scrollView.contentView.bounds
        let content = stack.frame
        guard clip.width > 0 else { return }

        let clipsLeading = clip.minX > 0.5
        let clipsTrailing = content.maxX - clip.maxX > 0.5
        let ramp = min(Self.fadeLength / clip.width, 0.5)

        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor

        // Resizing a layer animates by default, and a mask that glides while the pane is
        // dragged leaves a visible band of half-faded tabs trailing the divider.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = scrollView.bounds
        fadeMask.colors = [
            clipsLeading ? clear : opaque,
            opaque,
            opaque,
            clipsTrailing ? clear : opaque
        ]
        fadeMask.locations = [0, NSNumber(value: ramp), NSNumber(value: 1 - ramp), 1]
        CATransaction.commit()
    }
}
