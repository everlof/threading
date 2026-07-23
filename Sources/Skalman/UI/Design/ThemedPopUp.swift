import AppKit

/// A pop-up drawn from the theme, replacing `NSPopUpButton`.
///
/// The same lesson as `ThemedToggle`, one control along: a stock pop-up brings the system's
/// bezel and its own idea of a control's height and corner, so a Swiss Minimalist page of hard
/// edges shows three softly-bezelled form fields in the middle of it. This draws the button
/// from `Design` — the theme's surface, its border width, its corner radius — and its chevron
/// as a stroke rather than as a system glyph.
///
/// A drop-in for the call sites it replaces: `addItem(withTitle:)`, `lastItem`,
/// `selectItem(at:)`, `selectedItem`, `indexOfSelectedItem` and `pullsDown` keep the names and
/// the behaviour `NSPopUpButton` gave them, so a call site changes its type and nothing else.
///
/// **The menu it opens is an unavoidably-system `NSMenu`, and this wrapper is where that is
/// contained.** A menu is drawn by the window server, outside any view this app owns, so its
/// chrome cannot be themed from here. Callers depend on `ThemedPopUp` rather than on the menu,
/// so replacing that dropdown with a custom popover later is a change to this file alone.
final class ThemedPopUp: ThemedControl {

    // MARK: - Geometry

    private enum Layout {
        static let height: CGFloat = Design.Size.chipHeight
        static let inset: CGFloat = Design.Spacing.medium
        static let chevronWidth: CGFloat = 9
        static let chevronHeight: CGFloat = 5
        static let chevronLineWidth: CGFloat = 1.5
        static let imageSize: CGFloat = 14
        static let gap: CGFloat = Design.Spacing.small
        static let disabledAlpha: CGFloat = 0.5
    }

    // MARK: - Configuration

    /// Mirrors `NSPopUpButton.pullsDown`: the first item is a fixed label rather than a choice,
    /// which is what an actions or gear button wants. No selection is recorded, and the button
    /// keeps showing item 0 whatever is picked.
    var pullsDown = false {
        didSet { needsDisplay = true }
    }

    /// Draws the surface and border, and with them the chevron.
    ///
    /// A borderless pop-up is an icon that happens to open a menu — the gear on the themes
    /// list — and a chevron beside a 14pt glyph in a bare slot reads as clutter rather than as
    /// a hint. So the two travel together rather than being separate knobs.
    var isBordered = true {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    // MARK: - Selection

    /// Mirrors `NSPopUpButton.indexOfSelectedItem`. `-1` while there is nothing to select, which
    /// is the value AppKit reports for an empty pop-up.
    private(set) var indexOfSelectedItem: Int = -1

    var selectedItem: NSMenuItem? {
        pullsDown ? nil : item(at: indexOfSelectedItem)
    }

    var lastItem: NSMenuItem? { menu?.items.last }

    var numberOfItems: Int { menu?.numberOfItems ?? 0 }

    /// What the button itself shows: the choice, or a pull-down's fixed first item.
    private var displayedItem: NSMenuItem? {
        pullsDown ? item(at: 0) : selectedItem
    }

    // MARK: - State

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    private var trackingArea: NSTrackingArea?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The inherited `menu` holds the items, so `popUp.menu?.addItem(…)` reads exactly as it
        // did against `NSPopUpButton`. `rightMouseDown` below stops it doubling as a context menu.
        menu = NSMenu()
    }

    // MARK: - Items

    func addItem(withTitle title: String) {
        menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        // AppKit selects the first item a pop-up is given, and call sites rely on it — a menu
        // built without an explicit `selectItem(at:)` still shows something.
        if indexOfSelectedItem < 0 { indexOfSelectedItem = 0 }
        itemsChanged()
    }

    func item(at index: Int) -> NSMenuItem? {
        guard let menu, index >= 0, index < menu.numberOfItems else { return nil }
        return menu.item(at: index)
    }

    /// Out-of-range is tolerated rather than trapped, the way `NSPopUpButton` tolerates it: the
    /// index most often comes from looking a stored value up in a list, and a value the list no
    /// longer holds should leave the control unselected rather than crash the settings window.
    func selectItem(at index: Int) {
        indexOfSelectedItem = item(at: index) == nil ? -1 : index
        needsDisplay = true
    }

    func removeAllItems() {
        menu?.removeAllItems()
        indexOfSelectedItem = -1
        itemsChanged()
    }

    private func itemsChanged() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        var width = Layout.inset * 2
        if let image = displayedItem?.image, !image.size.equalTo(.zero) {
            width += Layout.imageSize + Layout.gap
        }
        if let title = displayedItem?.title, !title.isEmpty {
            width += ceil(title.size(withAttributes: [.font: Design.Typography.control()]).width)
        }
        if isBordered {
            width += Layout.gap + Layout.chevronWidth
        }
        return NSSize(width: width, height: Layout.height)
    }

    // MARK: - Interaction

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
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Swallowed rather than passed on, which is what `NSPopUpButton` does. The items live in the
    /// inherited `menu`, so the default handling would open them as a *context* menu — before
    /// `mouseDown` has wired their targets, and so with nothing recording the choice.
    ///
    /// Deliberately not `menu(for:)`, which would shadow the `menu` property for unqualified
    /// lookup inside this type and break the very call sites the property exists to serve.
    override func rightMouseDown(with event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        presentMenu()
    }

    @discardableResult
    private func presentMenu() -> Bool {
        guard isEnabled, let menu, menu.numberOfItems > 0 else { return false }

        adoptUnclaimedItems()
        menu.minimumWidth = bounds.width
        // A pop-up opens with the current choice under the pointer, the way AppKit's does; a
        // pull-down drops below, since its first item is a label rather than a choice.
        return menu.popUp(
            positioning: selectedItem,
            at: NSPoint(x: 0, y: pullsDown ? bounds.height + Design.Spacing.tight : bounds.height),
            in: self
        )
    }

    /// An item that carries its own action keeps it — that is how a pull-down's entries work, and
    /// how the themes list's Duplicate and Rename reach their own methods. Everything else routes
    /// back here, so the choice is recorded before the target is told about it.
    ///
    /// Separate from `presentMenu` so the rule can be tested: popping the menu is modal, and a
    /// test that opened one would hang rather than fail.
    func adoptUnclaimedItems() {
        for item in menu?.items ?? [] where item.action == nil && !item.isSeparatorItem {
            item.target = self
            item.action = #selector(itemChosen(_:))
        }
    }

    /// The single point at which a choice becomes the selection. Reachable from a test, which
    /// otherwise could only get here by opening a modal menu.
    @objc func itemChosen(_ sender: NSMenuItem) {
        if !pullsDown, let index = menu?.index(of: sender), index >= 0 {
            indexOfSelectedItem = index
        }
        itemsChanged()
        sendAction(action, to: target)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityValue() -> Any? { displayedItem?.title }
    override func accessibilityTitle() -> String? { displayedItem?.title }

    /// Both the press and the show-menu actions open the list, because assistive clients and UI
    /// scripts reach a pop-up through either one.
    override func accessibilityPerformPress() -> Bool { presentMenu() }
    override func accessibilityPerformShowMenu() -> Bool { presentMenu() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        alphaValue = isEnabled ? 1 : Layout.disabledAlpha

        var content = bounds.insetBy(dx: Layout.inset, dy: 0)

        if isBordered {
            drawSurface()
            let chevron = NSRect(
                x: content.maxX - Layout.chevronWidth,
                y: content.midY - Layout.chevronHeight / 2,
                width: Layout.chevronWidth,
                height: Layout.chevronHeight
            )
            drawChevron(in: chevron)
            content.size.width -= Layout.chevronWidth + Layout.gap
        }

        if let image = displayedItem?.image {
            let imageRect = NSRect(
                x: content.minX,
                y: content.midY - Layout.imageSize / 2,
                width: Layout.imageSize,
                height: Layout.imageSize
            )
            drawItemImage(image, in: imageRect)
            content.origin.x += Layout.imageSize + Layout.gap
            content.size.width -= Layout.imageSize + Layout.gap
        }

        drawTitle(in: content)
    }

    private func drawSurface() {
        ThemedSurface.draw(
            bounds,
            fill: isHovered && isEnabled ? Design.Surface.controlHover : Design.Surface.controlResting,
            border: Design.Surface.border
        )
    }

    /// Stroked rather than set from `chevron.down`, so it takes the theme's own weight and needs
    /// no tinted copy of a template image per redraw.
    private func drawChevron(in rect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.midX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.lineWidth = Layout.chevronLineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        Design.Text.tertiary.setStroke()
        path.stroke()
    }

    /// A template image is tinted to the label colour, so a symbol follows the theme the way the
    /// text beside it does; a coloured image — a theme swatch — is drawn as it is.
    private func drawItemImage(_ image: NSImage, in rect: NSRect) {
        guard image.isTemplate else {
            image.draw(in: rect)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        image.draw(in: rect)
        Design.Text.label.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawTitle(in rect: NSRect) {
        guard let title = displayedItem?.title, !title.isEmpty, rect.width > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.control(),
            .foregroundColor: Design.Text.label,
            .paragraphStyle: paragraph
        ]

        let height = ceil(Design.Typography.control().boundingRectForFont.height)
        let textRect = NSRect(
            x: rect.minX,
            y: rect.midY - height / 2,
            width: rect.width,
            height: height
        )
        (title as NSString).draw(in: textRect, withAttributes: attributes)
    }
}
