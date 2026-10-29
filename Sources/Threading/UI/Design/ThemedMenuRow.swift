import AppKit

// MARK: - Row

/// Measures a menu's columns and row heights once before either presenter mounts its rows.
/// Both presenters keep ownership of their viewport, highlight, and dismissal behavior.
@MainActor
struct ThemedMenuRowPlan {
    let heights: [CGFloat]

    private let entries: [ThemedMenuEntry]
    private let selectedEntryIndex: Int?
    private let checkColumn: ThemedMenuMetrics.CheckColumn
    private let hasImageColumn: Bool
    private let hasPreviewColumn: Bool
    private let hasSubmenuColumn: Bool
    private let hasAccessoryColumn: Bool
    private let shortcutColumnWidth: CGFloat
    private let metricPlan: ThemedMenuMetricPlan

    init(entries: [ThemedMenuEntry], selectedEntryIndex: Int? = nil) {
        self.entries = entries
        self.selectedEntryIndex = selectedEntryIndex
        checkColumn = ThemedMenuMetrics.checkColumn(
            entries,
            selectedEntryIndex: selectedEntryIndex
        )
        hasImageColumn = ThemedMenuMetrics.hasImageColumn(entries)
        hasPreviewColumn = ThemedMenuMetrics.hasPreviewColumn(entries)
        hasSubmenuColumn = ThemedMenuMetrics.hasSubmenuColumn(entries)
        hasAccessoryColumn = ThemedMenuMetrics.hasAccessoryColumn(entries)
        shortcutColumnWidth = ThemedMenuMetrics.shortcutColumnWidth(entries)
        metricPlan = ThemedMenuMetrics.metricPlan(entries)
        heights = ThemedMenuMetrics.heights(for: entries)
    }

    func row(at index: Int) -> ThemedMenuRowView? {
        guard entries.indices.contains(index), case .item(let item) = entries[index] else {
            return nil
        }
        return ThemedMenuRowView(
            entryIndex: index,
            item: item,
            isSelected: item.isSelected || index == selectedEntryIndex,
            checkColumn: checkColumn,
            hasImageColumn: hasImageColumn,
            hasPreviewColumn: hasPreviewColumn,
            hasSubmenuColumn: hasSubmenuColumn,
            hasAccessoryColumn: hasAccessoryColumn,
            shortcutColumnWidth: shortcutColumnWidth,
            preferredHeight: heights[index],
            metricPlan: metricPlan
        )
    }
}

final class ThemedMenuRowView: ThemedControl {

    let entryIndex: Int
    /// The row as its caller built it. `item` is what it says *now*, which differs only while an
    /// alternate's chord is held — and every path that reads the row (choosing, filtering, the
    /// tooltip, VoiceOver) reads `item`, so none of them can act on a name the row is not showing.
    let authoredItem: ThemedMenuItem
    private(set) var item: ThemedMenuItem
    private(set) var showsAlternate = false
    let preferredHeight: CGFloat

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onHighlight: ((Int) -> Void)?
    /// Reported before the row decides anything of its own, and reported by a disabled row too:
    /// a sweep that begins on an unavailable row still chooses the enabled one it ends on.
    var onPressBegan: ((NSEvent) -> Void)?
    var isKeyboardHighlighted = false {
        didSet {
            guard isKeyboardHighlighted != oldValue else { return }
            needsDisplay = true
            reportHighlight(isKeyboardHighlighted)
        }
    }
    /// The row does not match what is being typed. It dims rather than hides, so the menu
    /// keeps its shape while the filter narrows.
    var isFilteredOut = false {
        didSet {
            needsDisplay = true
            applyPreviewInk()
        }
    }

    private let selected: Bool
    /// How *the menu* carries its marks — not whether this row is marked. A column belongs to
    /// the panel, so an unmarked row in a menu of markable ones still starts after it.
    private let checkColumn: ThemedMenuMetrics.CheckColumn
    private let hasImageColumn: Bool
    private let hasPreviewColumn: Bool
    private let hasSubmenuColumn: Bool
    /// Again the *menu's* answer rather than this row's: a row with no accessory in a menu that
    /// has them still starts its trailing columns after the slot, or the titles either side of it
    /// would end at two different places.
    private let hasAccessoryColumn: Bool
    private let shortcutColumnWidth: CGFloat
    /// The menu's shared meter block, so this row puts its `7d` where every other row puts its
    /// `7d` — including the rows that have no `7d` and leave the line empty.
    private let metricPlan: ThemedMenuMetricPlan
    /// Whether this row's *run* keeps a second line — not whether this row fills it. See
    /// `firstLineCenterY`.
    private let reservesSubtitleLine: Bool
    private var pressed = false { didSet { needsDisplay = true } }
    /// The pointer is on a row that cannot be chosen. It answers with a wash far fainter
    /// than the hover fill — feedback that the hover was seen, not an invitation.
    private var isDisabledHover = false { didSet { needsDisplay = true } }

    /// The pointer is on the accessory in particular, rather than merely on the row carrying it.
    /// A revealed control that does not answer its own hover is a picture of a button.
    private var isAccessoryHovered = false {
        didSet {
            guard isAccessoryHovered != oldValue else { return }
            needsDisplay = true
            updateToolTip()
        }
    }
    /// A press that began on the accessory. Held separately from `pressed` because the two mean
    /// opposite things on release: this one runs the accessory and leaves the menu standing,
    /// while `pressed` chooses the row and closes it.
    private var accessoryPressed = false { didSet { needsDisplay = true } }
    /// A second area over the accessory's own rectangle. `ThemedControl` owns the row's, and the
    /// row's cannot answer this question: the pointer moving from a title onto the glyph beside
    /// it crosses nothing the row can see.
    private var accessoryTrackingArea: NSTrackingArea?

    /// The open panel this row fathered, while it is open. It keeps the row drawing the
    /// menu-path highlight — the parent stays lit wherever the pointer is in its chain, as
    /// the platform's own menus stay lit — and it is what accessibility descends into.
    private(set) weak var openSubmenuSurface: NSView?

    /// A preview in the title's slot is the row's name, so the row draws no text of its own.
    private var drawsTitle: Bool { item.preview?.placement != .title }

    /// The axis **everything on a row's first line** is placed on: the checkmark, the mark, the
    /// title and its qualifier, the first meter line, the submenu chevron.
    ///
    /// Each of those used to be centred on the row instead, which is right for a single-line row
    /// and wrong for every row beside one. A title with a subtitle is placed as a centred *block*,
    /// so its own line sits above the row's middle — while the mark next to it, centred on the
    /// row, sank to between the two lines, and a neighbouring row with no subtitle put its title
    /// where this row's ink is not. Down a column of logins that reads as rows nudged out of
    /// alignment at random, which is exactly what it looked like.
    ///
    /// So the line is computed from the slot the *run* reserves rather than from what this row
    /// happens to carry: a row with no subtitle in a run that has them keeps its title on its
    /// neighbours' line and leaves the second line empty, the way a table leaves a cell empty.
    private var firstLineCenterY: CGFloat {
        ThemedMenuMetrics.firstLineCenter(
            inRowOf: bounds.height,
            reservesSubtitleLine: reservesSubtitleLine
        )
    }

    /// The bottom edges of the title's and the subtitle's line boxes: the two lines placed as one
    /// block whose top line is `firstLineCenterY`. See `draw(_:)` for why they are one block.
    private var lineOrigins: (title: CGFloat, subtitle: CGFloat) {
        let titleHeight = Design.Typography.lineHeight(of: ThemedMenuMetrics.titleFont)
        let subtitleHeight = Design.Typography.lineHeight(of: Design.Typography.detail())
        let title = firstLineCenterY - titleHeight / 2 + ThemedMenuMetrics.titleBaselineOffset
        return (title, title - ThemedMenuMetrics.subtitleGap - subtitleHeight)
    }

    /// Everything reserved at the trailing edge before the readings begin: the chevron column
    /// and the accessory column, each present only if some row in this menu carries one.
    private var trailingColumnsWidth: CGFloat {
        (hasSubmenuColumn ? ThemedMenuMetrics.submenuChevronSlot : 0)
            + (hasAccessoryColumn ? ThemedMenuMetrics.accessorySlot : 0)
    }

    private var shortcutReservation: CGFloat {
        shortcutColumnWidth > 0 ? ThemedMenuMetrics.shortcutGap + shortcutColumnWidth : 0
    }

    /// What the meter block takes out of this row's width. Zero on a row with nothing to meter:
    /// plain actions do not belong to the readings table, and a shared reservation here hid
    /// their titles too when another provider contributed a metric line.
    private var meterReservation: CGFloat {
        guard !item.metrics.isEmpty else { return 0 }
        return ThemedMenuMetrics.metricReservation(metricPlan)
    }

    /// One meter line of this row, in the row's own coordinates.
    struct MeterLine {
        let metric: ThemedMenuMetric
        let labelRect: NSRect
        let barRect: NSRect
        let tickRect: NSRect?
        let valueRect: NSRect
        let detailRect: NSRect?
    }

    /// This row's meters as they are drawn — the one computation `draw(_:)` and the reference
    /// fixture both read, so a test aims at the pixels the row puts down rather than at a second
    /// copy of the arithmetic that would pass when both copies are wrong the same way.
    ///
    /// The block is anchored to the trailing edge, so it lands in the same place on every row
    /// whatever its name is, and each line keeps the plan's label — `5h` on the title's line,
    /// `7d` under it, on every row. A line this row has no reading for is left empty rather than
    /// closed up: a weekly reading moving up beside the name on the one row without a 5-hour
    /// window is exactly the drift the stacked plan exists to stop.
    var meterLines: [MeterLine] {
        guard !item.metrics.isEmpty, !metricPlan.isEmpty else { return [] }
        let plan = metricPlan
        let textHeight = Design.Typography.lineHeight(of: ThemedMenuMetrics.metricFont)
        let barHeight = ThemedMenuMetrics.metricBarHeight
        let origins = lineOrigins
        let centers = [
            origins.title + Design.Typography.lineHeight(of: ThemedMenuMetrics.titleFont) / 2,
            origins.subtitle + Design.Typography.lineHeight(of: Design.Typography.detail()) / 2
        ]
        let originX = bounds.maxX - ThemedMenuMetrics.contentInset - trailingColumnsWidth
            - shortcutReservation - plan.width
        let barX = originX + plan.labelWidth + plan.innerGap
        let valueX = barX + plan.barWidth + plan.innerGap
        let detailX = valueX + plan.valueWidth + plan.detailGap

        return zip(centers, plan.lines).compactMap { centerY, label -> MeterLine? in
            guard let metric = item.metrics.first(where: { $0.label == label }) else { return nil }
            let textY = centerY - textHeight / 2
            // On whole device pixels, like the tick: a line's centre is wherever its font's line
            // height puts it, and a 4pt bar on a fractional y draws soft top and bottom edges
            // that read as a smudge beside crisp digits.
            let bar = backingAlignedRect(
                NSRect(
                    x: barX, y: centerY - barHeight / 2, width: plan.barWidth, height: barHeight
                ),
                options: .alignAllEdgesNearest
            )
            let hasDetail = plan.detailWidth > 0 && metric.detail?.isEmpty == false
            return MeterLine(
                metric: metric,
                labelRect: NSRect(x: originX, y: textY, width: plan.labelWidth, height: textHeight),
                barRect: bar,
                tickRect: metric.timeMark.map { tickRect(at: $0, across: bar) },
                valueRect: NSRect(x: valueX, y: textY, width: plan.valueWidth, height: textHeight),
                detailRect: hasDetail
                    ? NSRect(x: detailX, y: textY, width: plan.detailWidth, height: textHeight)
                    : nil
            )
        }
    }

    /// The clock's tick for `mark`, standing proud of `bar` at both ends and kept inside its
    /// length, on whole device pixels so a 2pt line stays two crisp pixels rather than three
    /// soft ones.
    private func tickRect(at mark: Double, across bar: NSRect) -> NSRect {
        let width = ThemedMenuMetrics.metricTickWidth
        let overhang = ThemedMenuMetrics.metricTickOverhang
        let centre = bar.minX + bar.width * CGFloat(min(max(mark, 0), 1))
        return backingAlignedRect(
            NSRect(
                x: min(max(centre - width / 2, bar.minX), bar.maxX - width),
                y: bar.minY - overhang,
                width: width,
                height: bar.height + overhang * 2
            ),
            options: .alignAllEdgesNearest
        )
    }

    init(
        entryIndex: Int,
        item: ThemedMenuItem,
        isSelected: Bool,
        checkColumn: ThemedMenuMetrics.CheckColumn,
        hasImageColumn: Bool,
        hasPreviewColumn: Bool,
        hasSubmenuColumn: Bool,
        hasAccessoryColumn: Bool = false,
        shortcutColumnWidth: CGFloat,
        /// The menu's, not the row's: `ThemedMenuMetrics.heights(for:)` decides it from the run
        /// this row sits in, so neighbours stacked against each other keep one rhythm.
        preferredHeight: CGFloat,
        metricPlan: ThemedMenuMetricPlan = .empty
    ) {
        self.entryIndex = entryIndex
        authoredItem = item
        self.item = item
        selected = isSelected
        self.checkColumn = checkColumn
        self.hasImageColumn = hasImageColumn
        self.hasPreviewColumn = hasPreviewColumn
        self.hasSubmenuColumn = hasSubmenuColumn
        self.hasAccessoryColumn = hasAccessoryColumn
        self.shortcutColumnWidth = shortcutColumnWidth
        self.metricPlan = metricPlan
        self.preferredHeight = preferredHeight
        reservesSubtitleLine = preferredHeight >= ThemedMenuMetrics.subtitleRowHeight
        super.init(frame: .zero)
        updateToolTip()
        installPreview()
    }

    /// What the row says when the pointer rests on it.
    ///
    /// Explicit help wins because it explains the consequence the visible title cannot. Without
    /// it, the whole reading wins over the subtitle alone: once the numbers are columns and a
    /// drawn bar, a tooltip carrying only the leftover line would name less than the row shows.
    /// On the accessory it becomes the accessory's own name instead — a glyph that appeared under
    /// the pointer has no other way to say what it does, and while the pointer is on it the row's
    /// reading is not the question being asked.
    private func updateToolTip() {
        if isAccessoryHovered, let accessory = item.accessory {
            toolTip = accessory.title
            return
        }
        if let help = item.help, !help.isEmpty {
            toolTip = help
        } else {
            toolTip = item.metrics.isEmpty ? item.subtitle : item.spokenSummary
        }
    }

    // MARK: - Alternate

    func showAlternate(holding modifiers: NSEvent.ModifierFlags) {
        let showsAlternate = authoredItem.showsAlternate(holding: modifiers)
        guard showsAlternate != self.showsAlternate else { return }
        self.showsAlternate = showsAlternate
        item = authoredItem.resolved(holding: modifiers)
        updateToolTip()
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .titleChanged)
    }

    /// Chooses the alternate whatever is held — the accessibility action's route, which no key
    /// can reach.
    @discardableResult
    func performAlternate() -> Bool {
        guard authoredItem.isEnabled, let alternate = authoredItem.alternate,
              authoredItem.showsAlternate(holding: alternate.modifiers) else { return false }
        onChoose?(entryIndex, authoredItem.resolved(holding: alternate.modifiers))
        return true
    }

    // MARK: - Submenu

    func submenuDidOpen(_ surface: NSView) {
        openSubmenuSurface = surface
        surface.setAccessibilityParent(self)
        needsDisplay = true
    }

    func submenuDidClose() {
        guard openSubmenuSurface != nil else { return }
        openSubmenuSurface = nil
        needsDisplay = true
    }

    // MARK: - Preview

    /// Places the caller's live view in the column its placement names.
    ///
    /// Constraints rather than a frame set in `layout()`: the view arrives from the design
    /// system with an Auto Layout interior of its own — the orb pinned inside its tint wrapper,
    /// the morphing label inside its clip — and a row that reached in to set frames would be
    /// laying out somebody else's subtree. The row is frame-placed by the document view, which
    /// is what lets constraints from its own edges resolve.
    private func installPreview() {
        guard let preview = item.preview else { return }

        preview.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview.view)

        switch preview.placement {
        case .leading:
            // Own every constraint at the row, including the two single-item size constraints.
            // `activate` would otherwise install those two on the caller-owned preview itself.
            // Motion previews are intentionally reused when the menu reopens; a 16pt classic
            // row followed by a 20pt modern row would then leave both required sizes attached to
            // the orb. Removing the old row must remove the whole placement model with it.
            addConstraints([
                preview.view.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: ThemedMenuMetrics.previewInset(
                        checkColumn: checkColumn,
                        hasImageColumn: hasImageColumn
                    )
                ),
                preview.view.centerYAnchor.constraint(equalTo: centerYAnchor),
                preview.view.widthAnchor.constraint(
                    equalToConstant: ThemedMenuMetrics.previewSize
                ),
                preview.view.heightAnchor.constraint(
                    equalToConstant: ThemedMenuMetrics.previewSize
                )
            ])
        case .title:
            // Pinned to both edges of the title column rather than sized to its text: a label
            // whose width followed the name it is morphing *into* would resize under its own
            // animation, and the transition would read as the row twitching.
            let trailing = preview.view.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -ThemedMenuMetrics.contentInset
            )
            // The document owns the row's frame. While AppKit first attaches its zero-width
            // document view, the temporary autoresizing-mask width must be allowed to win;
            // once the document lays out, this equality becomes satisfiable and resumes its
            // ordinary job. Making the row itself constraint-driven loses that manual frame.
            trailing.priority = NSLayoutConstraint.Priority(999)
            NSLayoutConstraint.activate([
                preview.view.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: ThemedMenuMetrics.titleInset(
                        checkColumn: checkColumn,
                        hasImageColumn: hasImageColumn,
                        hasPreviewColumn: hasPreviewColumn
                    )
                ),
                trailing,
                preview.view.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        applyPreviewInk()
    }

    /// The dimming a drawn row applies to its text, applied to a hosted view instead — a
    /// disabled or filtered-out row cannot be dimmed by the alpha in `draw(_:)` if its name is
    /// a subview.
    private func applyPreviewInk() {
        guard let preview = item.preview else { return }
        preview.view.alphaValue = contentAlpha
    }

    /// A closing menu takes its previews with it. Nothing else reports the end of a highlight
    /// when the overlay is torn down — the surface deliberately stops moving the highlight once
    /// it is closing — so this is what stops a demonstration the user has walked away from.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, isKeyboardHighlighted {
            isKeyboardHighlighted = false
        }
        if newWindow == nil {
            // Detachment produces no pointer exit, and a retained row must not come back holding
            // a lit accessory or a half-finished press. `ThemedControl` says the same about the
            // row's own hover.
            isAccessoryHovered = false
            accessoryPressed = false
        }
    }

    /// Reports to the preview, unless this row no longer speaks for it.
    ///
    /// A preview is a view the caller owns and the row borrows, and a dropdown reopened while the
    /// previous panel is still fading hands the same view to a *new* row. The old row's teardown
    /// would then cancel a demonstration the new row had already started, leaving the menu
    /// looking as though the feature had stopped working.
    private func reportHighlight(_ isHighlighted: Bool) {
        guard let preview = item.preview, preview.view.superview === self else { return }
        preview.highlightChanged?(isHighlighted)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    /// A row's hover is the menu's highlight, so it is reported rather than drawn — and for a row
    /// that cannot be chosen it is the faint wash instead.
    override func hoverDidChange() {
        super.hoverDidChange()
        guard item.isEnabled else {
            isDisabledHover = isHovered
            return
        }
        if isHovered { onHighlight?(entryIndex) }
    }

    override func mouseDown(with event: NSEvent) {
        // Reported first and unconditionally, exactly as before: the held-press tracking this
        // arms belongs to the menu, and a press that turns out to be an audition is still a
        // press the menu has to know about.
        onPressBegan?(event)
        guard item.isEnabled else { return }
        if hitsAccessory(event) {
            accessoryPressed = true
            return
        }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard item.isEnabled else { return }
        // A drag off the glyph disarms the audition rather than promoting it to a choice. A
        // press that began on a control and ended somewhere else does nothing, which is what
        // every button on the platform does and is the escape hatch from a mispress.
        if accessoryPressed {
            accessoryPressed = hitsAccessory(event)
            return
        }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        if accessoryPressed {
            accessoryPressed = false
            if hitsAccessory(event) {
                performAccessory()
            }
            // Never falls through to the choice. The menu is still standing and the setting is
            // still whatever it was, which is the entire contract of an audition.
            return
        }
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            _ = performPrimaryAction()
        }
    }

    override func performPrimaryAction() -> Bool {
        guard item.isEnabled else { return false }
        onChoose?(entryIndex, item)
        return true
    }

    // MARK: - Accessory

    /// The glyph's own rectangle, on the row's first line like everything else trailing.
    private var accessoryRect: NSRect {
        NSRect(
            x: bounds.maxX - ThemedMenuMetrics.contentInset - ThemedMenuMetrics.accessorySize,
            y: firstLineCenterY - ThemedMenuMetrics.accessorySize / 2,
            width: ThemedMenuMetrics.accessorySize,
            height: ThemedMenuMetrics.accessorySize
        )
    }

    /// What a press has to land in, which is larger than what is drawn — and clamped to the row,
    /// so padding a small glyph never quietly claims part of the row above or below it.
    var accessoryHitRect: NSRect {
        accessoryRect
            .insetBy(
                dx: -ThemedMenuMetrics.accessoryHitPadding,
                dy: -ThemedMenuMetrics.accessoryHitPadding
            )
            .intersection(bounds)
    }

    private func hitsAccessory(_ event: NSEvent) -> Bool {
        guard item.accessory != nil else { return false }
        return accessoryHitRect.contains(convert(event.locationInWindow, from: nil))
    }

    /// The pointer's two states, for the fixture that has no pointer. See
    /// `ThemedMenuReferenceFixture.setAccessoryPointerState`.
    func setAccessoryPointerState(hovering: Bool, pressed: Bool) {
        isAccessoryHovered = hovering
        accessoryPressed = pressed
    }

    /// Runs the accessory. The one entry point, so the pointer, the right arrow and VoiceOver
    /// cannot end up doing three slightly different things.
    @discardableResult
    func performAccessory() -> Bool {
        guard item.isEnabled, let accessory = item.accessory else { return false }
        accessory.action()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let accessoryTrackingArea {
            removeTrackingArea(accessoryTrackingArea)
            self.accessoryTrackingArea = nil
        }
        guard item.accessory != nil else {
            isAccessoryHovered = false
            return
        }

        // An explicit rectangle rather than `.inVisibleRect`, which would snap the area to the
        // whole visible row and answer for the title as well as the glyph.
        let area = NSTrackingArea(
            rect: accessoryHitRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        accessoryTrackingArea = area

        // Tracking is rebuilt exactly when this row's geometry changed — a scroll, a resize —
        // which is the one moment a hover can have gone stale with the pointer never moving.
        // `ThemedControl` does this for the row; the sub-rect is ours to answer for.
        if isAccessoryHovered, !accessoryHitRect.contains(
            convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        ) {
            isAccessoryHovered = false
        }
    }

    /// Both areas report here, and only one of them is the row's.
    ///
    /// Passing an accessory crossing to `super` would be the bug this split exists to avoid: the
    /// pointer moving from the title onto the glyph beside it exits nothing, but the second area's
    /// *entry* would set the row's hover a second time and its exit — fired while the pointer is
    /// still well inside the row — would clear it, so a row would go dark as the pointer arrived
    /// at the control it was reaching for.
    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === accessoryTrackingArea {
            isAccessoryHovered = true
            return
        }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === accessoryTrackingArea {
            isAccessoryHovered = false
            accessoryPressed = false
            return
        }
        // Leaving the row leaves everything on it. The sub-area fires its own exit for an
        // ordinary crossing, but not when the row is removed from under a still pointer.
        isAccessoryHovered = false
        accessoryPressed = false
        super.mouseExited(with: event)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    /// The whole row, not its name. A login whose readings are columns and a drawn bar says
    /// nothing at all to VoiceOver if only its title is announced — and "identifiable without
    /// colour alone" is not met by a bar whose severity is a hue.
    override func accessibilityTitle() -> String? { item.spokenSummary }
    override func accessibilityHelp() -> String? {
        guard let help = item.help, !help.isEmpty else { return nil }
        return help
    }
    override func accessibilityValue() -> Any? { selected }
    override func isAccessibilityEnabled() -> Bool { item.isEnabled }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    /// "Show menu" is honest only on a row that has one; pressing a parent row opens it, so
    /// the two actions meet in the same place.
    override func accessibilityPerformShowMenu() -> Bool {
        guard item.submenu != nil else { return false }
        return performPrimaryAction()
    }

    /// A menu item is a leaf whatever it is drawn from — a hosted preview is how this row
    /// shows its own title, not a second thing to navigate to — with one exception: the
    /// submenu it has opened is its child, exactly as the platform models an item's menu.
    override func accessibilityChildren() -> [Any]? {
        openSubmenuSurface.map { [$0] } ?? []
    }

    /// The accessory, offered as an action on the row rather than as an element inside it.
    ///
    /// This is what keeps the rule above true. A second focusable thing in a menu item would put
    /// an element between a menu and its items where the platform models none, and every consumer
    /// that walks a menu expecting rows would find one row wearing a button. An action is the
    /// platform's own answer for "this element can do a second thing", it is announced with the
    /// row rather than found by hunting inside it, and it reaches exactly the same code the
    /// pointer does.
    ///
    /// The alternate is offered the same way, and for a stronger reason: its only other route is
    /// a held key, which VoiceOver's own keys are already chorded with. Offered only while the row
    /// is not already showing it, since pressing the row does that.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard item.isEnabled else { return nil }
        var actions: [NSAccessibilityCustomAction] = []
        if let accessory = item.accessory {
            actions.append(NSAccessibilityCustomAction(name: accessory.title) { [weak self] in
                self?.performAccessory() ?? false
            })
        }
        if !showsAlternate, let alternate = authoredItem.alternate, authoredItem.submenu == nil {
            actions.append(NSAccessibilityCustomAction(name: alternate.title) { [weak self] in
                self?.performAlternate() ?? false
            })
        }
        return actions.isEmpty ? nil : actions
    }

    // MARK: - Drawing

    /// How strongly the row states its content: full, dimmed for a row that cannot be chosen,
    /// dimmed again for one the filter has excluded. Read by `draw(_:)` for the text it inks
    /// and by `applyPreviewInk` for the text it hosts, so the two cannot disagree.
    private var contentAlpha: CGFloat {
        var alpha = item.isEnabled ? 1 : ThemedMenuMetrics.disabledDimming
        if isFilteredOut {
            alpha *= ThemedMenuMetrics.filteredOutDimming
        }
        return alpha
    }

    /// A text role at `contentAlpha`, **scaling** the role's own alpha rather than replacing it.
    ///
    /// `withAlphaComponent` sets alpha outright, so calling it with the 1 an ordinary enabled row
    /// reports did not leave the colour alone — it overwrote whatever transparency the role
    /// carried. Every label tier below `label` is defined *as* an alpha: `tertiaryLabel` is the
    /// label colour at 0.45 in a styled theme and `NSColor.tertiaryLabelColor` at roughly 0.26
    /// under the system one. Both arrived at the drawing call as fully opaque, so a menu's
    /// subtitle was painted in exactly the title's black and the pair had only 1pt of size and
    /// one weight step between them. That is most of why a subtitle row read as two titles.
    ///
    /// Multiplying also keeps a *dimmed* row dimmer than an enabled one, which replacing did not:
    /// at `disabledDimming` the old call pushed a 0.26 subtitle up to 0.45.
    private func ink(_ base: NSColor, _ alpha: CGFloat) -> NSColor {
        guard alpha < 1 else { return base }
        guard let resolved = base.usingColorSpace(.sRGB) else {
            return base.withAlphaComponent(alpha)
        }
        return resolved.withAlphaComponent(resolved.alphaComponent * alpha)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Every fill takes the same silhouette: one shape, drawn at two strengths. The inset
        // is what keeps a filled row off the one stacked against it.
        let fillRect: NSRect
        if ThemedMenuMetrics.appearance == .windows98 {
            // The native band starts one pixel inside the document's leading/top edge. Its
            // trailing/bottom edges remain flush, producing the measured 20px band in a 21px
            // row rather than a modern symmetrically inset capsule.
            fillRect = NSRect(
                x: bounds.minX + 1,
                y: bounds.minY,
                width: max(0, bounds.width - 2),
                height: max(0, bounds.height - 1)
            )
        } else {
            fillRect = bounds.insetBy(dx: 0, dy: ThemedMenuMetrics.fillInset)
        }

        // **A checked row is not a filled row.** The check states what is on; the fill states
        // where the pointer or the keyboard is, and only one row can be that at a time. Painting
        // both meant a menu of toggles came up three-quarters filled before it had been touched —
        // and the role it filled with, `selection`, is the ground behind selected *text*: at
        // Win98's solid navy or the System theme's accent it read as three highlighted rows
        // fighting the one the pointer was actually on.
        //
        // The open-submenu fill is the menu path: the parent stays lit while the pointer is
        // anywhere in the chain it opened, which is what keeps a three-panel menu readable.
        let isHighlighted = isKeyboardHighlighted || pressed || openSubmenuSurface != nil
        let selection = isHighlighted && ThemedMenuMetrics.usesClassicGrammar
            ? SelectionSurface.stated(over: ThemedMenuMetrics.panelFill)
            : nil
        if let selection {
            // A Win32 menu highlight is a flat COLOR_HIGHLIGHT band, not another raised
            // pushbutton. `bevel: .none` is load-bearing under hard-relief materials.
            ThemedSurface.draw(
                fillRect,
                fill: selection.fill,
                radius: 0,
                bevel: .none
            )
        } else if isHighlighted {
            ThemedSurface.draw(
                fillRect,
                fill: Design.Surface.controlHover,
                // Fitted, like every other row-shaped fill in the window — a sidebar row's hover
                // and a list row's selection both take this. The unfitted token is a corner the
                // theme states for a control of *any* size: Botanical's is 24, which on a 26pt
                // row is wider than the row is tall, and the fill came out as a taper.
                radius: Design.Radius.control(fitting: fillRect.size)
            )
        } else if isDisabledHover {
            // Resolve, then multiply — `withAlphaComponent` replaces the alpha outright,
            // and the hover fill is already translucent by design.
            let hover = Design.Surface.controlHover
            let resolved = hover.usingColorSpace(.sRGB) ?? hover
            ThemedSurface.draw(
                fillRect,
                fill: resolved.withAlphaComponent(
                    resolved.alphaComponent * ThemedMenuMetrics.disabledHoverWash
                ),
                radius: Design.Radius.control(fitting: fillRect.size)
            )
        }

        let alpha = contentAlpha
        let selectionLabel = selection != nil && ThemedMenuMetrics.appearance == .windows98
            ? Design.Surface.bevelHighlight
            : selection?.ink.label
        let label = ink(selectionLabel ?? Design.Text.label, alpha)
        // `secondary` rather than `tertiary`, deliberately. A subtitle here is not decoration —
        // it is the sentence that says what a permission mode will *do* — and rendered against
        // these titles `tertiary` read as disabled rather than as support. The separation the
        // pair was missing comes from `ink` no longer flattening this role to opaque black, and
        // from the rhythm, not from taking the copy down another tier.
        let secondary = ink(selection?.ink.secondary ?? Design.Text.secondary, alpha)
        // What a row's leading mark is drawn in. The historical grammars keep theirs at full
        // ink: a Win32 menu bitmap and a Platinum icon are artwork at the label's weight, and
        // dimming them would be a modern idea applied to a reconstruction.
        let glyph = ThemedMenuMetrics.usesClassicGrammar ? label : secondary

        let lineY = firstLineCenterY

        if selected {
            drawCheckMark(
                in: NSRect(
                    x: ThemedMenuMetrics.contentInset,
                    y: lineY - ThemedMenuMetrics.checkSize / 2,
                    width: ThemedMenuMetrics.checkSize,
                    height: ThemedMenuMetrics.checkSize
                ),
                color: label
            )
        }

        if hasImageColumn, let image = item.image {
            let imageRect = NSRect(
                x: ThemedMenuMetrics.markInset(checkColumn: checkColumn),
                y: lineY - ThemedMenuMetrics.imageSize / 2
                    + ThemedMenuMetrics.imageBaselineOffset,
                width: ThemedMenuMetrics.imageSize,
                height: ThemedMenuMetrics.imageSize
            )
            // **A row's mark is quieter than its name.** A menu whose glyphs are inked as loudly
            // as the words doubles the number of things competing for the first glance, and the
            // words are what is being chosen between. `secondary` is also what keeps a column of
            // icons reading as a column rather than as a second column of content. Non-template
            // artwork — an app's own icon, an account's mark — ignores the tint and keeps its
            // colours, which is right: those *are* content.
            draw(image, in: imageRect, tint: glyph)
        }

        // The accessory owns the outermost trailing column, so a chevron steps inward by its
        // slot — measured off the menu's answer, not this row's, or a chevron would sit at two
        // different x positions down one panel.
        let accessoryColumn = hasAccessoryColumn ? ThemedMenuMetrics.accessorySlot : 0

        if item.submenu != nil {
            drawChevron(
                in: NSRect(
                    x: bounds.maxX - ThemedMenuMetrics.submenuTrailingInset
                        - ThemedMenuMetrics.submenuChevronSize - accessoryColumn,
                    y: lineY - ThemedMenuMetrics.submenuChevronSize / 2,
                    width: ThemedMenuMetrics.submenuChevronSize,
                    height: ThemedMenuMetrics.submenuChevronSize
                ),
                color: label
            )
        }

        drawAccessory(label: label, secondary: secondary)

        guard drawsTitle else { return }

        let x = ThemedMenuMetrics.titleInset(
            checkColumn: checkColumn,
            hasImageColumn: hasImageColumn,
            hasPreviewColumn: hasPreviewColumn
        )
        let titleFont = ThemedMenuMetrics.titleFont
        // The **line box**, not `boundingRectForFont`. That rect carries the family's glyph
        // extremes, `draw(in:)` sets its line down from the rect's top, and the difference is
        // dead air above the words: under SF the two heights all but coincide and this read as
        // centred, while under Platinum — whose Charcoal falls back to Geneva, 24.4pt of
        // bounding rect around a 16pt line — every title sat 4pt above the checkmark and the
        // icon in its own row, which are placed against `midY`. It also disagreed with a
        // *hosted* preview in the title column, which is centred by constraint.
        let titleHeight = Design.Typography.lineHeight(of: titleFont)
        let subtitleFont = Design.Typography.detail()
        let subtitleHeight = Design.Typography.lineHeight(of: subtitleFont)
        let hasSubtitle = item.subtitle?.isEmpty == false
        // The two lines are placed as **one block, centred** — not each against `midY`
        // separately, which is what this did before. Independently, they sat 4pt apart inside a
        // row whose neighbours it touches edge to edge, so the gap to the *next row's* title came
        // out barely wider than the gap to a title's own subtitle: ~18pt against ~24pt. At that
        // ratio proximity states nothing and the menu reads as one evenly stacked column of
        // alternating weights rather than as pairs.
        //
        // The block's top line is `firstLineCenterY`, which every other part of the row is placed
        // against too — so the title, the mark beside it and the meter across from it share one
        // axis, and a row without a subtitle keeps its title on that same axis instead of sliding
        // down to the middle of its slot.
        let (titleY, subtitleY) = lineOrigins
        let trailingColumns = trailingColumnsWidth
        // The meters are fixed and the name is elastic — the inversion of the line this
        // replaced, where the name set the numbers' positions and the countdown lost its digits.
        // One meter on each of the row's two lines, on the same axes as the title and subtitle.
        let metricReservation = meterReservation
        drawMetricLines(selection: selection, alpha: alpha, secondary: secondary)
        let textWidth = max(
            0,
            bounds.maxX - ThemedMenuMetrics.contentInset - trailingColumns
                - shortcutReservation - metricReservation - x
        )
        // Win98's GDI text, Platinum's QuickDraw menu face, and Workbench's Topaz menu strike
        // are indexed bitmaps. Letting CoreGraphics smooth a fallback produces the right
        // outline under a gray veil, but does not reproduce the source pixels. Keep this
        // deliberately narrower than the whole theme so ordinary prose remains readable.
        let drawsIndexedText = ThemedMenuMetrics.appearance == .windows98
            || ThemedMenuMetrics.appearance == .platinum
            || ThemedMenuMetrics.appearance == .amiga
        if drawsIndexedText {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
            NSGraphicsContext.current?.cgContext.setAllowsAntialiasing(false)
            NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
            NSGraphicsContext.current?.cgContext.setAllowsFontSmoothing(false)
        }
        let drewPlatinumBitmap = ThemedMenuMetrics.appearance == .platinum
            && DesignSettings.current.chromeFontFamily == nil
            && titleFont.familyName?.caseInsensitiveCompare("Charcoal") != .orderedSame
            && !hasSubtitle
            // The bitmap strike draws one ink. A title carrying a quieter qualifier after it is
            // two, and drawing it here would silently drop the qualifier rather than tone it.
            && item.titleDetail?.isEmpty != false
            && PlatinumBitmapFont.draw(
                item.title,
                penX: x + 1,
                baselineFromTop: PlatinumBitmapFont.centeredBaseline(
                    in: bounds,
                    offset: -1
                ) ?? 0,
                in: bounds,
                ink: label
            )
        // An ellipsis rather than a hard clip when the panel's width cap wins: a menu is
        // entitled to cut a line short — `ThemedMenuLayout.maximumWidth` exists — but a row
        // sliced mid-word reads as a rendering fault, and `7d resets in` with the number gone
        // is a sentence claiming to be complete. The mark is what says the line continues.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        if !drewPlatinumBitmap {
            let titleLine = NSMutableAttributedString(string: item.title, attributes: [
                .font: titleFont, .foregroundColor: label, .paragraphStyle: truncating
            ])
            if let detail = item.titleDetail, !detail.isEmpty {
                // Quieter than the name and in the same line box: it identifies the row without
                // competing with what the row is called. A classic band flattens it to the
                // band's own label ink for the reason every other tone does.
                titleLine.append(NSAttributedString(
                    string: ThemedMenuMetrics.titleDetailGap + detail,
                    attributes: [
                        .font: titleFont,
                        .foregroundColor: selection == nil
                            ? ink(Design.Text.tertiary, alpha)
                            : label,
                        .paragraphStyle: truncating
                    ]
                ))
            }
            titleLine.draw(
                in: NSRect(x: x, y: titleY, width: textWidth, height: titleHeight)
            )
        }

        if let shortcut = item.resolvedShortcut, shortcutColumnWidth > 0 {
            let shortcutX = bounds.maxX - ThemedMenuMetrics.contentInset - trailingColumns
                - shortcutColumnWidth
            drawShortcut(
                shortcut,
                in: NSRect(
                    x: shortcutX,
                    y: lineY - titleHeight / 2 + ThemedMenuMetrics.titleBaselineOffset,
                    width: shortcutColumnWidth,
                    height: titleHeight
                ),
                font: titleFont,
                color: label
            )
        }

        if let subtitle = item.subtitle, !subtitle.isEmpty {
            let line = NSMutableAttributedString()
            // Toned runs are resolved to colours *here*, per draw, so a theme switch under an
            // open menu re-inks the next frame — the same reason the row reads `Design` roles
            // instead of caching them. A classic selection band flattens every run to the
            // band's own subtitle ink: that authored pair is the only ink measured against the
            // band's solid fill, and a status hue or a quaternary grey over Win98 navy is
            // exactly the unmeasured contrast the pair exists to prevent. The tint is a
            // second signal, never the only one — the numbers say the same thing in any ink.
            let runs = selection == nil ? item.subtitleSegments : nil
            for segment in runs ?? [ThemedMenuSubtitleSegment(subtitle)] {
                let tone: NSColor
                switch segment.tone {
                case .standard: tone = secondary
                case .muted: tone = ink(Design.Text.tertiary, alpha)
                case .warning: tone = ink(Design.Status.warning, alpha)
                case .critical: tone = ink(Design.Status.negative, alpha)
                }
                line.append(NSAttributedString(string: segment.text, attributes: [
                    .font: subtitleFont, .foregroundColor: tone, .paragraphStyle: truncating
                ]))
            }
            // Short of the meter block, which owns the trailing end of this line too: the second
            // meter sits on it. A row whose readings went into these words has no block, and the
            // line has the row's whole width.
            line.draw(
                in: NSRect(
                    x: x,
                    y: subtitleY,
                    width: max(
                        0,
                        bounds.maxX - ThemedMenuMetrics.contentInset - trailingColumns
                            - metricReservation - x
                    ),
                    height: subtitleHeight
                )
            )
        }
        if drawsIndexedText {
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Draws this row's readings into the menu's shared meter block, at `meterLines`.
    ///
    /// The old side-by-side columns put the reading in two places: when the panel could not fit
    /// both beside a name, the second fell into the subtitle under it, so the same window was
    /// read beside one name and under the next. Stacked, the block is one meter wide and fits.
    private func drawMetricLines(
        selection: SelectionSurface?,
        alpha: CGFloat,
        secondary: NSColor
    ) {
        let lines = meterLines
        guard !lines.isEmpty else { return }

        let font = ThemedMenuMetrics.metricFont
        // A band flattens every tone to its own authored ink, text, bar and tick alike: a status
        // hue over a solid classic selection is exactly the unmeasured contrast the pair prevents.
        let banded = selection?.ink.label
        let muted = banded ?? ink(Design.Text.tertiary, alpha)

        func toned(_ tone: ThemedMenuSubtitleSegment.Tone) -> NSColor {
            if let banded { return banded }
            switch tone {
            case .standard: return secondary
            case .muted: return muted
            case .warning: return ink(Design.Status.warning, alpha)
            case .critical: return ink(Design.Status.negative, alpha)
            }
        }

        for line in lines {
            let metric = line.metric
            (metric.label as NSString).draw(
                in: line.labelRect,
                withAttributes: [.font: font, .foregroundColor: muted]
            )
            drawMetricBar(
                metric,
                in: line.barRect,
                tick: line.tickRect,
                fill: banded ?? metricBarFill(metric.tone, alpha: alpha),
                // `tertiary`, not `quaternary`. The fainter role is right for a ring drawn
                // *around* a glyph and wrong here: at this height on an elevated panel it
                // disappeared, and a fill with no visible track behind it reads as a coloured
                // dash floating in the row rather than as a part of a whole — which is the one
                // thing a bar says that the number beside it does not.
                track: banded?.withAlphaComponent(
                    ThemedMenuMetrics.metricTrackOpacity
                ) ?? ink(Design.Text.tertiary, alpha * ThemedMenuMetrics.metricTrackOpacity),
                // The label's own ink: the tick is the one mark on the bar that is not a
                // reading, and it has to stay legible over the fill, the track and the hover
                // pill alike — which only the row's strongest ink is measured against.
                tickInk: banded ?? ink(Design.Text.label, alpha)
            )
            draw(metric.value, rightAlignedIn: line.valueRect, font: font, color: toned(metric.tone))
            if let detail = metric.detail, let detailRect = line.detailRect {
                draw(detail, rightAlignedIn: detailRect, font: font, color: toned(metric.detailTone))
            }
        }
    }

    /// A calm bar is the same ink as the number beside it, not the accent.
    ///
    /// The accent was tried first and is what the standalone `UsageBarView` uses, but in a menu
    /// it is wrong twice over. It breaks the rule the *values* already keep — calm is the absence
    /// of a signal, not a third colour — so a row would have said "nothing to see" in text and
    /// painted a saturated blue rod beside it. And the accent in this surface is already spoken
    /// for by the selection, so six of them down a menu argue with the one row the pointer is on.
    /// Neutral until it matters leaves the two orange and red bars as the only colour in the
    /// panel, which is the entire reason for drawing lengths at all.
    private func metricBarFill(
        _ tone: ThemedMenuSubtitleSegment.Tone,
        alpha: CGFloat
    ) -> NSColor {
        switch tone {
        case .standard, .muted: return ink(Design.Text.secondary, alpha)
        case .warning: return ink(Design.Status.warning, alpha)
        case .critical: return ink(Design.Status.negative, alpha)
        }
    }

    /// Track, fill, and the clock's tick across both.
    ///
    /// The tick is cut *through* the bar rather than painted on it: the track and fill are one
    /// transparency layer, and a hairline either side of the tick is cleared out of it before the
    /// tick is drawn. A gap painted in a background colour would have to know what is under the
    /// bar — the panel, the hover pill, a classic band — and the clear knows none of them. Without
    /// the cut, a tick over a fill of nearly its own ink merged into it, which is exactly where
    /// the reading needs it: spend running level with time.
    private func drawMetricBar(
        _ metric: ThemedMenuMetric,
        in rect: NSRect,
        tick tickRect: NSRect?,
        fill: NSColor,
        track: NSColor,
        tickInk: NSColor
    ) {
        let radius = ThemedMenuMetrics.usesClassicGrammar ? 0 : rect.height / 2
        let context = NSGraphicsContext.current?.cgContext
        context?.beginTransparencyLayer(auxiliaryInfo: nil)
        // The full track is always drawn, so a window with no readable number still reads as a
        // window rather than as a line this row forgot.
        track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        if let fraction = metric.fraction {
            // Below the floor the fill is shorter than its own cap and draws as a dot at the
            // track's head; the floor is the honest picture of "barely touched". Same rule, same
            // reason, as `AccountMarkImage`'s meter.
            let visible = max(ThemedMenuMetrics.metricMinimumFraction, min(fraction, 1))
            fill.setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: max(rect.height, rect.width * CGFloat(visible)),
                    height: rect.height
                ),
                xRadius: radius,
                yRadius: radius
            ).fill()
        }
        if let tickRect, let context {
            context.saveGState()
            context.setBlendMode(.clear)
            context.fill(knockout(around: tickRect, in: rect))
            context.restoreGState()
        }
        context?.endTransparencyLayer()

        guard let tickRect else { return }
        let tickRadius = ThemedMenuMetrics.usesClassicGrammar ? 0 : tickRect.width / 2
        tickInk.setFill()
        NSBezierPath(roundedRect: tickRect, xRadius: tickRadius, yRadius: tickRadius).fill()
    }

    /// The cut either side of the tick — and, where it leaves less bar beyond it than the bar's
    /// own height, that sliver too. A few pixels of fill or track past a tick near either end
    /// drew as a stray dot rather than as the rest of a window; without them the bar ends (or
    /// begins) at the tick, which is what the clock is saying, and the countdown has the minutes.
    private func knockout(around tick: NSRect, in bar: NSRect) -> NSRect {
        var cut = tick.insetBy(dx: -ThemedMenuMetrics.metricTickKnockout, dy: 0)
        if cut.minX - bar.minX < bar.height {
            cut = NSRect(x: bar.minX, y: cut.minY, width: cut.maxX - bar.minX, height: cut.height)
        }
        if bar.maxX - cut.maxX < bar.height {
            cut.size.width = bar.maxX - cut.minX
        }
        return cut
    }

    private func draw(
        _ text: String,
        rightAlignedIn rect: NSRect,
        font: NSFont,
        color: NSColor
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byClipping
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style
            ]
        )
    }

    /// The trailing accessory, drawn only where the row is current — under the pointer, or under
    /// the keyboard highlight so the right arrow is offering something visible.
    ///
    /// Three states, and the step between each is **ink only**: `secondary` where the row is
    /// merely current, `label` with the pointer on the glyph, and `label` dimmed while it is held
    /// down. That is the rule `ChipView` keeps, for the same reason — anything that changes a
    /// control's size or weight under the pointer moves the row while it is being aimed at — and
    /// the dim is the answer `ThemedButton` gives a press.
    ///
    /// A plate behind the glyph was drawn here first and was invisible: this only ever appears on
    /// a row that is already filled with `controlHover`, so the press painted the hover fill over
    /// itself. The render is what said so.
    ///
    /// Both inks arrive resolved, including the flattening a classic selection band does to
    /// everything drawn over it, so this cannot state a colour the rest of the row disagrees with.
    private func drawAccessory(label: NSColor, secondary: NSColor) {
        guard item.isEnabled,
              let accessory = item.accessory,
              // The pointer being on the glyph is the pointer being on the row; the third term
              // only matters to a fixture that sets one without the other.
              isKeyboardHighlighted || isHovered || isAccessoryHovered,
              let image = ThemedMenuIcon.accessorySymbol(accessory.symbolName)
        else { return }

        var tint = isAccessoryHovered || accessoryPressed ? label : secondary
        if accessoryPressed {
            // Resolve, then multiply: `withAlphaComponent` replaces an alpha outright, and every
            // label tier below `label` is defined *as* one.
            let resolved = tint.usingColorSpace(.sRGB) ?? tint
            tint = resolved.withAlphaComponent(
                resolved.alphaComponent * ThemedMenuMetrics.accessoryPressedDimming
            )
        }
        draw(image, in: accessoryRect, tint: tint)
    }

    private func drawShortcut(
        _ shortcut: KeyboardShortcut,
        in rect: NSRect,
        font: NSFont,
        color: NSColor
    ) {
        if ThemedMenuMetrics.usesAmigaCommandCap(shortcut) {
            // The Workbench manual does not spell "Amiga" in this column: it uses the black
            // Amiga-key cap followed by one Topaz character. Keep the cap as indexed geometry
            // so it remains exact even when the user's font override lacks a logo glyph.
            let key = KeyboardShortcut.keyDisplay(shortcut.key)
            let keyWidth = ceil(key.size(withAttributes: [.font: font]).width)
            let contentWidth = ThemedMenuMetrics.amigaCommandCapWidth
                + ThemedMenuMetrics.amigaCommandCapGap + keyWidth
            let cap = NSRect(
                x: rect.maxX - contentWidth,
                y: rect.midY - ThemedMenuMetrics.amigaCommandCapWidth / 2,
                width: ThemedMenuMetrics.amigaCommandCapWidth,
                height: ThemedMenuMetrics.amigaCommandCapWidth
            ).integral
            color.setFill()
            cap.fill()
            let capInk = ThemedMenuMetrics.panelFill
            ("A" as NSString).draw(
                in: NSRect(x: cap.minX + 2, y: cap.minY, width: 10, height: 13),
                withAttributes: [.font: font, .foregroundColor: capInk]
            )
            (key as NSString).draw(
                in: NSRect(x: cap.maxX + 2, y: rect.minY, width: rect.maxX - cap.maxX - 2, height: rect.height),
                withAttributes: [.font: font, .foregroundColor: color]
            )
            return
        }

        draw(
            ThemedMenuMetrics.shortcutText(shortcut),
            rightAlignedIn: rect,
            font: font,
            color: color
        )
    }

    private func draw(_ image: NSImage, in rect: NSRect, tint: NSColor) {
        TemplateImageDrawing.draw(image, in: rect, tint: tint)
    }

    private func drawCheckMark(in rect: NSRect, color: NSColor) {
        if ThemedMenuMetrics.usesClassicGrammar {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX + rect.width * 0.36, y: rect.minY + 1))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - 1))
            path.lineWidth = 1.5
            path.lineCapStyle = .square
            path.lineJoinStyle = .miter
            color.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.midY))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.38, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// The submenu chevron: `›`, drawn with the checkmark's own stroke so the two glyph
    /// columns read as one hand. Symmetric about the row's midline, so flip cannot skew it.
    private func drawChevron(in rect: NSRect, color: NSColor) {
        if ThemedMenuMetrics.usesClassicGrammar {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: rect.minX + 1, y: rect.minY))
            triangle.line(to: NSPoint(x: rect.maxX - 1, y: rect.midY))
            triangle.line(to: NSPoint(x: rect.minX + 1, y: rect.maxY))
            triangle.close()
            color.setFill()
            triangle.fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + rect.width * 0.3, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - rect.width * 0.2, y: rect.midY))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}
