import AppKit

/// A choice offered by a themed menu control.
///
/// Feature code describes meaning and state; `ThemedMenuPresenter` draws the complete dropdown
/// from app roles. Keeping presentation details out of this type means both `ChipView` and
/// `ThemedPopUp` share one visual and behavioral contract.
struct ThemedMenuItem {
    let title: String
    var subtitle: String?
    var image: NSImage?
    var preview: ThemedMenuPreview?
    var representedValue: Any?
    var isSelected: Bool
    var isEnabled: Bool
    var onChoose: (() -> Void)?

    init(
        title: String,
        subtitle: String? = nil,
        image: NSImage? = nil,
        preview: ThemedMenuPreview? = nil,
        representedValue: Any? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        onChoose: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.image = image
        self.preview = preview
        self.representedValue = representedValue
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.onChoose = onChoose
    }
}

/// A live view standing in for a choice, so a menu of animations can be watched rather than
/// read one selection at a time.
///
/// An image would not do: what these rows are choosing between *is* movement, and a still of an
/// animation says only that there is one. The view is the caller's, made once and handed over,
/// which is also what keeps a preview honest — the working indicator's row draws the same
/// `WorkingOrbView` the conversation status draws, and a name transition's row the same
/// `MorphingTitleLabel` the sidebar morphs, rather than a second rendering of either.
struct ThemedMenuPreview {

    enum Placement {
        /// A fixed slot before the title, which still draws beside it.
        case leading
        /// The title's own place. The row draws no title of its own, because the preview *is*
        /// the name — which is the only way a text transition can be shown at all.
        case title
    }

    let placement: Placement
    let view: NSView

    /// The row's highlight arrived or left, by pointer or by arrow key.
    ///
    /// The row reports it; the preview decides what it means. An orb runs whether or not it is
    /// pointed at — a dropdown of animations is a comparison, and a comparison needs them all
    /// moving — while eleven names morphing at once is unreadable, so a name transition plays
    /// only where the highlight is.
    ///
    /// `false` is also delivered when the row leaves the window, so a menu dismissed
    /// mid-demonstration ends it rather than leaving something stepping against a view nobody
    /// can see.
    var highlightChanged: ((Bool) -> Void)?
}

enum ThemedMenuEntry {
    case item(ThemedMenuItem)
    case separator
}

/// The semantic payload handed to menu-presentation test seams.
struct ThemedMenuPresentation {
    let entries: [ThemedMenuEntry]
    let minimumWidth: CGFloat
}

// MARK: - Presentation

/// Presents a completely app-owned dropdown above the window's content.
///
/// An overlay rather than `NSMenu`, `NSPopover`, or a borderless panel is deliberate:
///
/// - every visible pixel comes from the active app theme;
/// - the dropdown escapes any scroll view that contains its source;
/// - no second window steals key status or introduces system material;
/// - one surface owns outside-click dismissal and keyboard navigation.
///
/// The returned object is an opaque retention token. A control holds it for as long as the menu
/// is open and releases it from `onDismiss`; callers never depend on the implementation class.
@MainActor
enum ThemedMenuPresenter {

    @discardableResult
    static func present(
        _ presentation: ThemedMenuPresentation,
        from source: NSView,
        selectedEntryIndex: Int?,
        onChoose: @escaping (Int, ThemedMenuItem) -> Void,
        onDismiss: @escaping () -> Void
    ) -> AnyObject? {
        guard let window = source.window,
              let root = window.contentView,
              presentation.entries.contains(where: \.isItem)
        else { return nil }

        return ThemedMenuSession(
            presentation: presentation,
            source: source,
            root: root,
            window: window,
            selectedEntryIndex: selectedEntryIndex,
            onChoose: onChoose,
            onDismiss: onDismiss
        )
    }

    static func dismiss(_ token: AnyObject?) {
        (token as? ThemedMenuSession)?.close()
    }

    /// The press-drag-release idiom: the button went down on the source control and is still
    /// down while the pointer moves over the open menu. The source forwards its drag here so
    /// rows highlight under the pointer, exactly as a held `NSMenu` tracks.
    static func dragUpdated(_ token: AnyObject?, event: NSEvent) {
        (token as? ThemedMenuSession)?.dragUpdated(event)
    }

    /// The held press ends. Over an enabled row it chooses; back over the source it goes
    /// sticky (the ordinary click-then-browse open); anywhere else it lets the menu go.
    static func dragEnded(_ token: AnyObject?, event: NSEvent) {
        (token as? ThemedMenuSession)?.dragEnded(event)
    }
}

/// Where a press-drag-release ended, as the overlay reports it to the session.
private enum ThemedMenuDragTarget {
    case row(Int, ThemedMenuItem)
    /// On the panel, but not on anything choosable — a separator, padding, a disabled row.
    case surface
    case outside
}

private extension ThemedMenuEntry {
    var isItem: Bool {
        if case .item = self { return true }
        return false
    }
}

// MARK: - Geometry

enum ThemedMenuLayout {
    static let gap: CGFloat = Design.Spacing.tight
    static let screenInset: CGFloat = Design.Spacing.small
    static let maximumHeight: CGFloat = 360
    static let maximumWidth: CGFloat = 440

    static func frame(
        anchor: NSRect,
        desiredSize: NSSize,
        in bounds: NSRect,
        flipped: Bool
    ) -> NSRect {
        let width = min(desiredSize.width, max(0, bounds.width - screenInset * 2))
        let x = min(
            max(anchor.minX, bounds.minX + screenInset),
            max(bounds.minX + screenInset, bounds.maxX - screenInset - width)
        )

        let roomBefore: CGFloat
        let roomAfter: CGFloat
        if flipped {
            roomBefore = anchor.minY - bounds.minY - gap - screenInset
            roomAfter = bounds.maxY - anchor.maxY - gap - screenInset
        } else {
            roomBefore = bounds.maxY - anchor.maxY - gap - screenInset
            roomAfter = anchor.minY - bounds.minY - gap - screenInset
        }

        let opensAfter = roomAfter >= min(desiredSize.height, maximumHeight)
            || roomAfter >= roomBefore
        let available = max(0, opensAfter ? roomAfter : roomBefore)
        let height = min(desiredSize.height, maximumHeight, available)

        let y: CGFloat
        if flipped {
            y = opensAfter ? anchor.maxY + gap : anchor.minY - gap - height
        } else {
            y = opensAfter ? anchor.minY - gap - height : anchor.maxY + gap
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Session

@MainActor
private final class ThemedMenuSession: NSObject {

    private weak var source: NSView?
    private weak var window: NSWindow?
    private let overlay: ThemedMenuOverlayView
    private let onChoose: (Int, ThemedMenuItem) -> Void
    private let onDismiss: () -> Void
    private var isClosed = false

    init(
        presentation: ThemedMenuPresentation,
        source: NSView,
        root: NSView,
        window: NSWindow,
        selectedEntryIndex: Int?,
        onChoose: @escaping (Int, ThemedMenuItem) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.source = source
        self.window = window
        self.onChoose = onChoose
        self.onDismiss = onDismiss

        let menuWidth = ThemedMenuMetrics.width(
            for: presentation.entries,
            minimum: presentation.minimumWidth
        )
        let menuHeight = ThemedMenuMetrics.height(for: presentation.entries)
        let anchor = source.convert(source.bounds, to: root)
        let menuFrame = ThemedMenuLayout.frame(
            anchor: anchor,
            desiredSize: NSSize(width: menuWidth, height: menuHeight),
            in: root.bounds,
            flipped: root.isFlipped
        )
        overlay = ThemedMenuOverlayView(
            frame: root.bounds,
            menuFrame: menuFrame,
            entries: presentation.entries,
            selectedEntryIndex: selectedEntryIndex
        )

        super.init()

        overlay.onDismiss = { [weak self] in self?.closeFromUser() }
        overlay.onChoose = { [weak self] index, item in self?.choose(index: index, item: item) }
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay, positioned: .above, relativeTo: nil)
        // The surface is constructed before the overlay joins the source's view tree. A
        // window-local appearance (the gallery's Light/Dark preview) may therefore differ from
        // the app appearance under which its layer-backed fill first resolved. Re-resolve once
        // attached so menu fill, rows, and text all use the source window's appearance.
        AppThemeRefresh.repaint(overlay)
        window.makeFirstResponder(overlay)
        overlay.animateIn()

        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didResizeNotification
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowChanged),
                name: name,
                object: window
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowChanged() {
        close()
    }

    private func choose(index: Int, item: ThemedMenuItem) {
        guard !isClosed else { return }
        finish(exit: .confirm(index))
        onChoose(index, item)
    }

    /// Programmatic dismissal — the window changed under the menu, or the source is leaving.
    /// Instant, because the anchor the animation would play against is already gone.
    func close() {
        finish(exit: .instant)
    }

    func dragUpdated(_ event: NSEvent) {
        guard !isClosed else { return }
        overlay.dragHighlight(atWindowPoint: event.locationInWindow)
    }

    func dragEnded(_ event: NSEvent) {
        guard !isClosed else { return }
        let point = event.locationInWindow
        if let source, source.bounds.contains(source.convert(point, from: nil)) {
            // Released back on the control: the plain click-to-open. The menu stays for
            // browsing, which is the other half of how platform menus track a press.
            return
        }
        switch overlay.dragTarget(atWindowPoint: point) {
        case .row(let index, let item):
            choose(index: index, item: item)
        case .surface:
            break
        case .outside:
            closeFromUser()
        }
    }

    /// The user let the menu go without choosing: Escape, or a click outside it.
    private func closeFromUser() {
        finish(exit: .fade)
    }

    /// Everything observable ends here, synchronously — observers, first responder, the
    /// accessibility tree, hit testing, `onDismiss`. Only pixels outlive this call: an
    /// animated exit fades what is already, by contract, gone.
    private func finish(exit: ThemedMenuExit) {
        guard !isClosed else { return }
        isClosed = true
        NotificationCenter.default.removeObserver(self)
        if let window, window.firstResponder === overlay, let source {
            window.makeFirstResponder(source)
        }
        overlay.tearDown(exit: exit)
        onDismiss()
    }
}

/// How a closing menu leaves the screen. Every path has already ended the session; this only
/// names the pixels' exit.
enum ThemedMenuExit {
    case instant
    case fade
    /// The classic confirmation blink: the chosen row flickers once, then the panel fades.
    case confirm(Int)
}

// MARK: - Overlay

private final class ThemedMenuOverlayView: ThemedControl {

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onDismiss: (() -> Void)?

    private let menuSurface: ThemedMenuSurfaceView
    /// A plain chassis under the surface carrying the elevation shadow. Separate on purpose:
    /// the surface's own layer belongs to `applySurface`, whose theme glow clears and rewrites
    /// layer shadow state on every repaint — a shadow set there would not survive the first
    /// theme refresh. It is also what the appear animation scales, so the shadow arrives with
    /// the panel instead of sitting full-strength under a panel still growing.
    private let menuHost = NSView()
    private var highlightedIndex: Int?
    private var isTearingDown = false

    /// What has been typed since the menu opened. Letters filter: matching rows keep their
    /// ink, the rest dim, and the highlight lands on the first match — the menu keeps its
    /// shape rather than reflowing under the pointer on every keystroke.
    private var filterQuery = "" {
        didSet {
            guard filterQuery != oldValue, !isTearingDown else { return }
            menuSurface.applyFilter(filterQuery)
            let indices = activeIndices
            if let highlightedIndex, indices.contains(highlightedIndex) { return }
            setHighlight(indices.first)
        }
    }

    /// The rows arrow keys and Return may land on — every enabled row, narrowed to the
    /// matches while a filter is active.
    private var activeIndices: [Int] {
        menuSurface.selectableIndices(matching: filterQuery)
    }

    init(
        frame: NSRect,
        menuFrame: NSRect,
        entries: [ThemedMenuEntry],
        selectedEntryIndex: Int?
    ) {
        menuSurface = ThemedMenuSurfaceView(
            frame: NSRect(origin: .zero, size: menuFrame.size),
            entries: entries,
            selectedEntryIndex: selectedEntryIndex
        )
        super.init(frame: frame)

        setAccessibilityElement(false)
        menuHost.frame = menuFrame
        menuHost.wantsLayer = true
        menuHost.layer?.masksToBounds = false
        // A fixed neutral on purpose — the same exception the icon backplates carry. A shadow
        // exists to separate the panel from whatever the theme drew behind it, and every
        // themed colour follows that ground.
        menuHost.applyLayerShadow(NSColor.black)
        menuHost.layer?.shadowOpacity = ThemedMenuMotion.shadowOpacity
        menuHost.layer?.shadowRadius = ThemedMenuMotion.shadowRadius
        menuHost.layer?.shadowOffset = .zero
        addSubview(menuHost)
        menuSurface.autoresizingMask = [.width, .height]
        menuHost.addSubview(menuSurface)
        menuSurface.onChoose = { [weak self] index, item in self?.onChoose?(index, item) }
        menuSurface.onHighlight = { [weak self] index in self?.setHighlight(index) }

        let initial = menuSurface.selectableIndices.contains(selectedEntryIndex ?? -1)
            ? selectedEntryIndex
            : menuSurface.selectableIndices.first
        setHighlight(initial)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityPerformPress() -> Bool {
        onDismiss?()
        return true
    }

    /// A closing menu takes no more events. Hit testing alone does not cover tracking areas,
    /// which is why the row handlers also check `isTearingDown` before acting.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isTearingDown ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    // MARK: - Motion

    /// The dropdown materialises: a quick fade with a subtle grow from centre. Decorative
    /// only — the model values are already final, so nothing here can be left half-arrived.
    func animateIn() {
        let duration = Design.Motion.appear
        guard duration > 0, let layer = menuHost.layer else { return }

        // Composed about the layer's visual centre whatever its anchor point, so the maths
        // holds under AppKit's own layer geometry rather than assuming it.
        let anchor = layer.anchorPoint
        let centre = CGPoint(
            x: (0.5 - anchor.x) * menuHost.bounds.width,
            y: (0.5 - anchor.y) * menuHost.bounds.height
        )
        var from = CATransform3DIdentity
        from = CATransform3DTranslate(from, centre.x, centre.y, 0)
        from = CATransform3DScale(from, ThemedMenuMotion.appearScale, ThemedMenuMotion.appearScale, 1)
        from = CATransform3DTranslate(from, -centre.x, -centre.y, 0)

        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: from)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = Design.Motion.appear
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: ThemedMenuMotion.appearAnimationKey)
    }

    /// Ends the overlay's participation in the window now, and lets the pixels leave by
    /// `exit`. Synchronous whatever the exit: accessibility stops being a menu, events stop
    /// landing, and only the fade is deferred — captured strongly, so removal does not
    /// depend on the session outliving it.
    func tearDown(exit: ThemedMenuExit) {
        guard !isTearingDown else { return }
        isTearingDown = true
        menuSurface.setAccessibilityRole(nil)

        let duration = Design.Motion.vanish
        let fadeOut = {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Design.Motion.vanish
                self.animator().alphaValue = 0
            }, completionHandler: {
                self.removeFromSuperview()
            })
        }

        switch exit {
        case .instant:
            removeFromSuperview()
        case .fade where duration <= 0, .confirm where duration <= 0:
            removeFromSuperview()
        case .fade:
            fadeOut()
        case .confirm(let index):
            let beat = Design.Motion.confirmBeat
            guard beat > 0, let row = menuSurface.row(at: index) else {
                fadeOut()
                return
            }
            row.isKeyboardHighlighted = false
            DispatchQueue.main.asyncAfter(deadline: .now() + beat) {
                row.isKeyboardHighlighted = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + beat * 2, execute: fadeOut)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            escape()
        case 125:
            moveHighlight(by: 1)
        case 126:
            moveHighlight(by: -1)
        case 36:
            chooseHighlighted()
        case 51:
            if filterQuery.isEmpty {
                super.keyDown(with: event)
            } else {
                filterQuery.removeLast()
            }
        case 49:
            // Space chooses, as it always has — unless a filter is being typed, where it is
            // an ordinary character ("new work…").
            if filterQuery.isEmpty {
                chooseHighlighted()
            } else {
                filterQuery += " "
            }
        default:
            if let character = filterCharacter(from: event) {
                filterQuery += character
            } else if event.charactersIgnoringModifiers == "\u{1b}" {
                escape()
            } else if event.charactersIgnoringModifiers == "\r" {
                chooseHighlighted()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Escape backs out one layer at a time: first the filter, then the menu — clearing a
    /// half-typed query should not cost the menu too.
    private func escape() {
        if filterQuery.isEmpty {
            onDismiss?()
        } else {
            filterQuery = ""
        }
    }

    /// A key that belongs in the filter: one visible character, unchorded. Arrows and other
    /// function keys arrive as private-use scalars and stay navigation.
    private func filterCharacter(from event: NSEvent) -> String? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .function]),
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(Int(scalar.value))
        else { return nil }
        return characters
    }

    // MARK: - Press-Drag-Release Tracking

    func dragHighlight(atWindowPoint point: NSPoint) {
        guard !isTearingDown else { return }
        if let row = menuSurface.row(underWindowPoint: point), row.item.isEnabled {
            setHighlight(row.entryIndex)
        }
    }

    func dragTarget(atWindowPoint point: NSPoint) -> ThemedMenuDragTarget {
        guard !isTearingDown else { return .outside }
        if let row = menuSurface.row(underWindowPoint: point), row.item.isEnabled {
            return .row(row.entryIndex, row.item)
        }
        let inSurface = menuSurface.bounds.contains(menuSurface.convert(point, from: nil))
        return inSurface ? .surface : .outside
    }

    override func performPrimaryAction() -> Bool {
        chooseHighlighted()
    }

    private func setHighlight(_ index: Int?) {
        // Tracking areas keep firing while the closed menu fades — hit testing does not
        // silence them — and a highlight moving on a menu that has already answered reads
        // as the menu still being open.
        guard !isTearingDown else { return }
        highlightedIndex = index
        menuSurface.highlight(index)
        if let row = menuSurface.row(at: index) {
            NSAccessibility.post(element: row, notification: .focusedUIElementChanged)
        }
    }

    private func moveHighlight(by delta: Int) {
        let indices = activeIndices
        guard !indices.isEmpty else { return }
        guard let highlightedIndex,
              let position = indices.firstIndex(of: highlightedIndex)
        else {
            setHighlight(delta > 0 ? indices.first : indices.last)
            return
        }
        let next = min(max(position + delta, 0), indices.count - 1)
        setHighlight(indices[next])
    }

    @discardableResult
    private func chooseHighlighted() -> Bool {
        guard let highlightedIndex,
              let row = menuSurface.row(at: highlightedIndex)
        else { return false }
        return row.performPrimaryAction()
    }
}

// MARK: - Surface and Scrolling

/// The dropdown's column geometry. Internal rather than file-private so the columns can be
/// pinned by a test: a preview hosted in a row and a title drawn in one have to start at the
/// same place, and that is an arithmetic claim rather than something a render shows.
enum ThemedMenuMetrics {
    /// Between the panel's edge and its rows, so a highlighted row's capsule floats inside
    /// the panel instead of grazing its border.
    static let outerInset: CGFloat = Design.Spacing.small
    static let rowHeight: CGFloat = 28
    static let subtitleRowHeight: CGFloat = 42
    /// A separator's slot. Sized so the gap it opens between two rows' text reads as the
    /// ordinary inter-row rhythm plus the rule — at the old 9pt the rule crowded whichever
    /// row's fill it sat against and the spacing read as unequal.
    static let separatorHeight: CGFloat = 13
    /// The strip across the top echoing what has been typed while the menu is open.
    static let filterHeaderHeight: CGFloat = 22
    /// How far a filtered-out row's ink drops. Dimmed rather than hidden, so the menu keeps
    /// its shape while the user types and nothing moves under the pointer.
    static let filteredOutDimming: CGFloat = 0.4
    /// A row that cannot be chosen at all.
    static let disabledDimming: CGFloat = 0.45
    /// The wash a *disabled* row shows under the pointer — feedback that the hover was
    /// seen, well short of the fill that says "choosable".
    static let disabledHoverWash: CGFloat = 0.4
    /// A row's own leading and trailing padding — also where the checkmark sits, which was
    /// previously drawn 4pt from the row's edge and read as pinned to the panel's side.
    static let contentInset: CGFloat = Design.Spacing.medium
    static let checkSize: CGFloat = 10
    /// The checkmark column: glyph plus the gap to whatever follows it.
    static let leadingSlot: CGFloat = checkSize + Design.Spacing.small
    static let imageSize: CGFloat = 14
    static let imageSlot: CGFloat = 18
    /// A live preview's column. The orb is the widest thing that goes in it and states its own
    /// 20pt footprint, so the slot is that plus the gap to whatever follows — the same shape as
    /// the image column one size up, rather than a second guess at it.
    static let previewSize: CGFloat = 20
    static let previewSlot: CGFloat = previewSize + Design.Spacing.tight

    /// The image column is reserved only when some item actually carries an image. Reserving
    /// it always left an 18pt hole between checkmark and title in every icon-less menu.
    static func hasImageColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.image != nil
        }
    }

    /// Reserved on the same terms as the image column, and only for a preview that sits *beside*
    /// a title — one placed in the title's own slot occupies a column that already exists.
    static func hasPreviewColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.preview?.placement == .leading
        }
    }

    /// Where a row's content begins, per column, so a *drawn* title and a *hosted* preview land
    /// in the same place. A preview replaces the text rather than joining it, and a column of
    /// names that shifted sideways when one of them animated would read as a layout bug in the
    /// menu rather than as the transition it is demonstrating.
    static var imageInset: CGFloat { contentInset + leadingSlot }

    static func previewInset(hasImageColumn: Bool) -> CGFloat {
        imageInset + (hasImageColumn ? imageSlot : 0)
    }

    static func titleInset(hasImageColumn: Bool, hasPreviewColumn: Bool) -> CGFloat {
        previewInset(hasImageColumn: hasImageColumn) + (hasPreviewColumn ? previewSlot : 0)
    }

    static func height(for entries: [ThemedMenuEntry]) -> CGFloat {
        entries.reduce(outerInset * 2) { total, entry in
            switch entry {
            case .separator:
                return total + separatorHeight
            case .item(let item):
                return total + (item.subtitle?.isEmpty == false ? subtitleRowHeight : rowHeight)
            }
        }
    }

    static func width(for entries: [ThemedMenuEntry], minimum: CGFloat) -> CGFloat {
        let text = entries.compactMap { entry -> CGFloat? in
            guard case .item(let item) = entry else { return nil }
            let title = ceil(item.title.size(
                withAttributes: [.font: Design.Typography.control()]
            ).width)
            let subtitle = ceil((item.subtitle ?? "").size(
                withAttributes: [.font: Design.Typography.detail()]
            ).width)
            return max(title, subtitle)
        }.max() ?? 0

        let imageColumn = hasImageColumn(entries) ? imageSlot : 0
        let previewColumn = hasPreviewColumn(entries) ? previewSlot : 0
        let content = outerInset * 2 + contentInset * 2
            + leadingSlot + imageColumn + previewColumn + text
        return min(max(minimum, content), ThemedMenuLayout.maximumWidth)
    }
}

/// How the menu moves. File-local because no other surface animates this way yet; a second
/// one promotes these to `Design`.
enum ThemedMenuMotion {
    static let appearScale: CGFloat = 0.97
    static let appearAnimationKey = "skalman.menu.appear"
    static let shadowOpacity: Float = 0.28
    static let shadowRadius: CGFloat = 16
}

private final class ThemedMenuSurfaceView: NSView, ThemedComponent {

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onHighlight: ((Int) -> Void)?

    let selectableIndices: [Int]

    private let scrollView = ThemedScrollView()
    private let document: ThemedMenuDocumentView
    private let rows: [Int: ThemedMenuRowView]
    /// Echoes what has been typed, in the strip the filter opens across the panel's top —
    /// without it, typing visibly does nothing until a row happens to dim.
    private let filterLabel = NSTextField(labelWithString: "")

    init(
        frame: NSRect,
        entries: [ThemedMenuEntry],
        selectedEntryIndex: Int?
    ) {
        var madeRows: [Int: ThemedMenuRowView] = [:]
        var views: [NSView] = []
        var selectable: [Int] = []
        let hasImageColumn = ThemedMenuMetrics.hasImageColumn(entries)
        let hasPreviewColumn = ThemedMenuMetrics.hasPreviewColumn(entries)

        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                views.append(ThemedMenuSeparatorView())
            case .item(let item):
                let row = ThemedMenuRowView(
                    entryIndex: index,
                    item: item,
                    isSelected: item.isSelected || index == selectedEntryIndex,
                    hasImageColumn: hasImageColumn,
                    hasPreviewColumn: hasPreviewColumn
                )
                madeRows[index] = row
                views.append(row)
                if item.isEnabled { selectable.append(index) }
            }
        }

        rows = madeRows
        selectableIndices = selectable
        document = ThemedMenuDocumentView(views: views)
        super.init(frame: frame)

        applySurface(
            fill: Design.Surface.elevated,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller =
            document.naturalHeight > frame.height - ThemedMenuMetrics.outerInset * 2
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        addSubview(scrollView)

        filterLabel.applyFont(.detail())
        filterLabel.textColor = Design.Text.secondary
        filterLabel.lineBreakMode = .byTruncatingHead
        filterLabel.isHidden = true
        addSubview(filterLabel)

        for row in rows.values {
            row.onChoose = { [weak self] index, item in self?.onChoose?(index, item) }
            row.onHighlight = { [weak self] index in self?.onHighlight?(index) }
        }
        setAccessibilityRole(.menu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let inset = ThemedMenuMetrics.outerInset
        var content = bounds.insetBy(dx: inset, dy: inset)
        if !filterLabel.isHidden {
            let header = ThemedMenuMetrics.filterHeaderHeight
            let labelHeight = ceil(filterLabel.font?.boundingRectForFont.height ?? header)
            filterLabel.frame = NSRect(
                x: content.minX + ThemedMenuMetrics.contentInset,
                y: content.maxY - header + (header - labelHeight) / 2,
                width: max(0, content.width - ThemedMenuMetrics.contentInset * 2),
                height: labelHeight
            )
            content.size.height -= header
        }
        scrollView.frame = content
        document.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.contentSize.width,
            height: max(document.naturalHeight, scrollView.contentSize.height)
        )
        document.needsLayout = true
    }

    func highlight(_ index: Int?) {
        for (entryIndex, row) in rows {
            row.isKeyboardHighlighted = entryIndex == index
        }
        if let row = row(at: index) {
            row.scrollToVisible(row.bounds)
        }
    }

    func row(at index: Int?) -> ThemedMenuRowView? {
        index.flatMap { rows[$0] }
    }

    /// The row under a point given in window coordinates — the press-drag-release lookup.
    /// Per-row conversion, so a scrolled document answers correctly.
    func row(underWindowPoint point: NSPoint) -> ThemedMenuRowView? {
        rows.values.first { row in
            row.bounds.contains(row.convert(point, from: nil))
        }
    }

    // MARK: - Filtering

    func applyFilter(_ query: String) {
        for row in rows.values {
            row.isFilteredOut = !query.isEmpty && !Self.matches(row.item, query)
        }
        filterLabel.stringValue = L10n.format("Filter: %@", query)
        filterLabel.isHidden = query.isEmpty
        needsLayout = true
    }

    func selectableIndices(matching query: String) -> [Int] {
        guard !query.isEmpty else { return selectableIndices }
        return selectableIndices.filter { index in
            guard let row = rows[index] else { return false }
            return Self.matches(row.item, query)
        }
    }

    private static func matches(_ item: ThemedMenuItem, _ query: String) -> Bool {
        item.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

private final class ThemedMenuDocumentView: NSView {

    let naturalHeight: CGFloat
    private let views: [NSView]

    override var isFlipped: Bool { true }

    init(views: [NSView]) {
        self.views = views
        naturalHeight = views.reduce(0) { total, view in
            total + ((view as? ThemedMenuRowView)?.preferredHeight
                ?? ThemedMenuMetrics.separatorHeight)
        }
        super.init(frame: .zero)
        for view in views { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for view in views {
            let height = (view as? ThemedMenuRowView)?.preferredHeight
                ?? ThemedMenuMetrics.separatorHeight
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }
}

private final class ThemedMenuSeparatorView: NSView, ThemedComponent {
    override func draw(_ dirtyRect: NSRect) {
        let height = Design.Radius.border
        // Inset to the rows' own content padding, so the rule reads as part of the column
        // of text it divides rather than a wall-to-wall strut.
        let rect = NSRect(
            x: ThemedMenuMetrics.contentInset,
            y: bounds.midY - height / 2,
            width: max(0, bounds.width - ThemedMenuMetrics.contentInset * 2),
            height: height
        )
        Design.Surface.divider.setFill()
        rect.fill()
    }
}

// MARK: - Row

private final class ThemedMenuRowView: ThemedControl {

    let entryIndex: Int
    let item: ThemedMenuItem
    let preferredHeight: CGFloat

    var onChoose: ((Int, ThemedMenuItem) -> Void)?
    var onHighlight: ((Int) -> Void)?
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
    private let hasImageColumn: Bool
    private let hasPreviewColumn: Bool
    private var pressed = false { didSet { needsDisplay = true } }
    /// The pointer is on a row that cannot be chosen. It answers with a wash far fainter
    /// than the hover fill — feedback that the hover was seen, not an invitation.
    private var isDisabledHover = false { didSet { needsDisplay = true } }

    /// A preview in the title's slot is the row's name, so the row draws no text of its own.
    private var drawsTitle: Bool { item.preview?.placement != .title }

    init(
        entryIndex: Int,
        item: ThemedMenuItem,
        isSelected: Bool,
        hasImageColumn: Bool,
        hasPreviewColumn: Bool
    ) {
        self.entryIndex = entryIndex
        self.item = item
        selected = isSelected
        self.hasImageColumn = hasImageColumn
        self.hasPreviewColumn = hasPreviewColumn
        preferredHeight = item.subtitle?.isEmpty == false
            ? ThemedMenuMetrics.subtitleRowHeight
            : ThemedMenuMetrics.rowHeight
        super.init(frame: .zero)
        toolTip = item.subtitle
        installPreview()
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
            NSLayoutConstraint.activate([
                preview.view.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: ThemedMenuMetrics.previewInset(hasImageColumn: hasImageColumn)
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
            NSLayoutConstraint.activate([
                preview.view.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: ThemedMenuMetrics.titleInset(
                        hasImageColumn: hasImageColumn,
                        hasPreviewColumn: hasPreviewColumn
                    )
                ),
                preview.view.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -ThemedMenuMetrics.contentInset
                ),
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
        guard item.isEnabled else { return }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard item.isEnabled else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
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

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    override func accessibilityTitle() -> String? { item.title }
    override func accessibilityValue() -> Any? { selected }
    override func isAccessibilityEnabled() -> Bool { item.isEnabled }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    /// A menu item is a leaf whatever it is drawn from. A hosted preview is how this row shows
    /// its own title and status, not a second thing inside it to navigate to, and `item.title`
    /// already says in words what the preview says in movement.
    override func accessibilityChildren() -> [Any]? { [] }

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

    override func draw(_ dirtyRect: NSRect) {
        if isKeyboardHighlighted || pressed {
            ThemedSurface.draw(
                bounds,
                fill: Design.Surface.controlHover,
                radius: Design.Radius.control
            )
        } else if selected {
            ThemedSurface.draw(
                bounds,
                fill: Design.Surface.selection,
                radius: Design.Radius.control
            )
        } else if isDisabledHover {
            // Resolve, then multiply — `withAlphaComponent` replaces the alpha outright,
            // and the hover fill is already translucent by design.
            let hover = Design.Surface.controlHover
            let resolved = hover.usingColorSpace(.sRGB) ?? hover
            ThemedSurface.draw(
                bounds,
                fill: resolved.withAlphaComponent(
                    resolved.alphaComponent * ThemedMenuMetrics.disabledHoverWash
                ),
                radius: Design.Radius.control
            )
        }

        let alpha = contentAlpha
        let label = Design.Text.label.withAlphaComponent(alpha)
        let secondary = Design.Text.secondary.withAlphaComponent(alpha)

        if selected {
            drawCheckMark(
                in: NSRect(
                    x: ThemedMenuMetrics.contentInset,
                    y: bounds.midY - ThemedMenuMetrics.checkSize / 2,
                    width: ThemedMenuMetrics.checkSize,
                    height: ThemedMenuMetrics.checkSize
                ),
                color: label
            )
        }

        if hasImageColumn, let image = item.image {
            let imageRect = NSRect(
                x: ThemedMenuMetrics.imageInset,
                y: bounds.midY - ThemedMenuMetrics.imageSize / 2,
                width: ThemedMenuMetrics.imageSize,
                height: ThemedMenuMetrics.imageSize
            )
            draw(image, in: imageRect, tint: label)
        }

        guard drawsTitle else { return }

        let x = ThemedMenuMetrics.titleInset(
            hasImageColumn: hasImageColumn,
            hasPreviewColumn: hasPreviewColumn
        )
        let titleFont = Design.Typography.control()
        let titleHeight = ceil(titleFont.boundingRectForFont.height)
        let hasSubtitle = item.subtitle?.isEmpty == false
        let titleY = hasSubtitle
            ? bounds.midY + Design.Spacing.hairline
            : bounds.midY - titleHeight / 2
        let textWidth = max(0, bounds.maxX - ThemedMenuMetrics.contentInset - x)
        (item.title as NSString).draw(
            in: NSRect(x: x, y: titleY, width: textWidth, height: titleHeight),
            withAttributes: [.font: titleFont, .foregroundColor: label]
        )

        if let subtitle = item.subtitle, !subtitle.isEmpty {
            let font = Design.Typography.detail()
            let height = ceil(font.boundingRectForFont.height)
            (subtitle as NSString).draw(
                in: NSRect(
                    x: x,
                    y: bounds.midY - height - Design.Spacing.hairline,
                    width: textWidth,
                    height: height
                ),
                withAttributes: [.font: font, .foregroundColor: secondary]
            )
        }
    }

    private func draw(_ image: NSImage, in rect: NSRect, tint: NSColor) {
        guard image.isTemplate else {
            image.draw(in: rect)
            return
        }
        // Tinted inside its own transparent image, where `.sourceAtop` can only touch the
        // glyph. In the row's context the destination under the rect is whatever the row
        // already drew — the highlight fill, the panel — so tinting in place floods the
        // whole slot with the label colour and the icon reads as a solid square.
        let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds)
            tint.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }

    private func drawCheckMark(in rect: NSRect, color: NSColor) {
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
}
