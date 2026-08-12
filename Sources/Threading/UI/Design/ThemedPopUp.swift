import AppKit

/// A pop-up drawn from the theme, replacing `NSPopUpButton`.
///
/// The same lesson as `ThemedToggle`, one control along: a stock pop-up brings the system's
/// bezel and its own idea of a control's height and corner, so a Swiss Minimalist page of hard
/// edges shows three softly-bezelled form fields in the middle of it. This draws the button
/// from `Design` — the theme's surface, its border width, its corner radius — and its chevron
/// as a stroke rather than as a system glyph.
///
/// Its dropdown is app-owned too: `ThemedMenuPresenter` draws the rows, selection, scrolling,
/// and elevation from the same theme roles as the closed control. Callers provide semantic
/// `ThemedMenuItem` values, so system menu chrome never leaks through this API.
final class ThemedPopUp: ThemedControl {

    // MARK: - Geometry

    private enum Layout {
        static let inset: CGFloat = Design.Spacing.medium
        static let chevronWidth: CGFloat = 9
        static let chevronHeight: CGFloat = 5
        static let chevronLineWidth: CGFloat = 1.5
        static let imageSize: CGFloat = 14
        static let gap: CGFloat = Design.Spacing.small
        static let disabledAlpha: CGFloat = 0.5
    }

    private var choiceMaterial: AppTheme.Material {
        AppThemePalette.current.material(for: effectiveAppearance)
    }

    private var choiceStyle: AppTheme.Material.ChoiceStyle { choiceMaterial.choiceStyle }

    private var contentInset: CGFloat {
        choiceStyle.isClassic ? ClassicChoiceDrawing.textInset : Layout.inset
    }

    private var imageSize: CGFloat {
        choiceStyle.isClassic
            ? min(Layout.imageSize, max(0, choiceMaterial.choiceHeight - 4))
            : Layout.imageSize
    }

    // MARK: - Configuration

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : Layout.disabledAlpha }
    }

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

    private var entries: [ThemedMenuEntry] = []

    /// Mirrors `NSPopUpButton.indexOfSelectedItem`. `-1` while there is nothing to select, which
    /// is the value AppKit reports for an empty pop-up.
    private(set) var indexOfSelectedItem: Int = -1

    var selectedItem: ThemedMenuItem? {
        pullsDown ? nil : item(at: indexOfSelectedItem)
    }

    var numberOfItems: Int { entries.count }

    /// What the button itself shows: the choice, or a pull-down's fixed first item.
    private var displayedItem: ThemedMenuItem? {
        pullsDown ? item(at: 0) : selectedItem
    }

    // MARK: - State

    private var menuSession: AnyObject?
    private var isPresentingMenu = false {
        didSet { needsDisplay = true }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            ThemedMenuPresenter.dismiss(menuSession)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: - Items

    func addItem(withTitle title: String) {
        addItem(ThemedMenuItem(title: title))
    }

    func addItem(_ item: ThemedMenuItem) {
        entries.append(.item(item))
        // AppKit selects the first item a pop-up is given, and call sites rely on it — a menu
        // built without an explicit `selectItem(at:)` still shows something.
        if indexOfSelectedItem < 0 { indexOfSelectedItem = 0 }
        itemsChanged()
    }

    func addSeparator() {
        entries.append(.separator)
        itemsChanged()
    }

    func item(at index: Int) -> ThemedMenuItem? {
        guard entries.indices.contains(index),
              case .item(let item) = entries[index]
        else { return nil }
        return item
    }

    /// Out-of-range is tolerated rather than trapped, the way `NSPopUpButton` tolerates it: the
    /// index most often comes from looking a stored value up in a list, and a value the list no
    /// longer holds should leave the control unselected rather than crash the settings window.
    func selectItem(at index: Int) {
        indexOfSelectedItem = item(at: index) == nil ? -1 : index
        needsDisplay = true
    }

    func removeAllItems() {
        entries.removeAll()
        indexOfSelectedItem = -1
        itemsChanged()
    }

    private func itemsChanged() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        var width = contentInset * 2
        if let image = displayedItem?.image, !image.size.equalTo(.zero) {
            width += imageSize + Layout.gap
        }
        if let title = displayedItem?.title, !title.isEmpty {
            let font = choiceStyle.isClassic
                ? Design.Typography.controlRegular()
                : Design.Typography.control()
            width += ceil(title.size(withAttributes: [.font: font]).width)
        }
        if isBordered {
            width += choiceStyle.isClassic
                ? ClassicChoiceDrawing.arrowWidth
                : Layout.gap + Layout.chevronWidth
        }
        return NSSize(width: width, height: choiceMaterial.choiceHeight)
    }

    // MARK: - Interaction

    /// Swallowed rather than passed on, which is what `NSPopUpButton` does.
    override func rightMouseDown(with event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        _ = performPrimaryAction()
    }

    // The press that opened the dropdown may still be held, and press-drag-release chooses the
    // item it is let go over — the way the stock pop-up this replaces always did. The open menu
    // tracks that press itself, so this control has nothing to forward.

    override func performPrimaryAction() -> Bool {
        presentMenu()
    }

    @discardableResult
    private func presentMenu() -> Bool {
        guard isEnabled, menuSession == nil, entries.contains(where: {
            if case .item = $0 { return true }
            return false
        }) else { return false }

        // A pull-down's first item is its fixed label, not an action. The custom dropdown omits
        // that display-only entry rather than showing an inert duplicate at the top.
        let entryOffset = pullsDown ? 1 : 0
        let presentedEntries = Array(entries.dropFirst(entryOffset))
        guard presentedEntries.contains(where: {
            if case .item = $0 { return true }
            return false
        }) else { return false }

        isPresentingMenu = true
        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: presentedEntries, minimumWidth: bounds.width),
            from: self,
            selectedEntryIndex: pullsDown ? nil : indexOfSelectedItem,
            onChoose: { [weak self] index, _ in
                self?.chooseItem(at: index + entryOffset)
            },
            onDismiss: { [weak self] in
                self?.menuSession = nil
                self?.isPresentingMenu = false
            }
        )
        if menuSession == nil {
            isPresentingMenu = false
            return false
        }
        return true
    }

    /// The single point at which a choice becomes the selection. Reachable from a test, which
    /// otherwise could only get here by opening a modal menu.
    func chooseItem(at index: Int) {
        guard let item = item(at: index), item.isEnabled else { return }
        if !pullsDown {
            indexOfSelectedItem = index
        }
        item.onChoose?()
        itemsChanged()
        NSAccessibility.post(element: self, notification: .valueChanged)
        if item.onChoose == nil {
            sendAction(action, to: target)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityValue() -> Any? { displayedItem?.title }
    override func accessibilityTitle() -> String? {
        accessibilityLabel() ?? displayedItem?.title
    }

    /// Both the press and the show-menu actions open the list, because assistive clients and UI
    /// scripts reach a pop-up through either one.
    override func accessibilityPerformPress() -> Bool { presentMenu() }
    override func accessibilityPerformShowMenu() -> Bool { presentMenu() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        var content = bounds.insetBy(dx: contentInset, dy: 0)

        if isBordered {
            drawSurface()
            if choiceStyle.isClassic {
                let arrow = ClassicChoiceDrawing.arrowRect(in: bounds, style: choiceStyle)
                if choiceStyle == .dropdown {
                    _ = ThemedSurface.draw(
                        arrow,
                        fill: Design.Surface.controlResting,
                        radius: 0,
                        bevel: isPresentingMenu ? .sunken : .automatic
                    )
                } else if choiceStyle == .aquaPopup {
                    ClassicChoiceDrawing.drawAquaArrowWell(
                        in: arrow,
                        pressed: isPresentingMenu
                    )
                } else {
                    ClassicChoiceDrawing.drawIntegratedSeparator(at: arrow.minX, in: bounds)
                }
                ClassicChoiceDrawing.drawIndicator(
                    choiceStyle,
                    in: arrow,
                    color: Design.Text.label
                )
                content.size.width = max(0, arrow.minX - content.minX - contentInset)
            } else {
                let chevron = NSRect(
                    x: content.maxX - Layout.chevronWidth,
                    y: content.midY - Layout.chevronHeight / 2,
                    width: Layout.chevronWidth,
                    height: Layout.chevronHeight
                )
                drawChevron(in: chevron)
                content.size.width -= Layout.chevronWidth + Layout.gap
            }
        }

        if let image = displayedItem?.image {
            let imageRect = NSRect(
                x: content.minX,
                y: content.midY - imageSize / 2,
                width: imageSize,
                height: imageSize
            )
            drawItemImage(image, in: imageRect)
            content.origin.x += imageSize + Layout.gap
            content.size.width -= imageSize + Layout.gap
        }

        drawTitle(in: content)
    }

    private func drawSurface() {
        let shape: ThemedSurface.Shape
        if choiceStyle == .dropdown {
            shape = ThemedSurface.draw(
                bounds,
                fill: Design.Surface.field,
                radius: 0,
                bevel: .sunken
            )
        } else if choiceStyle == .aquaPopup {
            shape = ThemedSurface.draw(
                bounds,
                fill: Design.Surface.controlResting,
                border: Design.Surface.border,
                radius: 5
            )
        } else if choiceStyle.isClassic {
            shape = ThemedSurface.draw(
                bounds,
                fill: Design.Surface.controlResting,
                radius: 0,
                bevel: isPresentingMenu ? .sunken : .automatic
            )
        } else {
            shape = ThemedSurface.draw(
                bounds,
                fill: (isHovered || isPresentingMenu) && isEnabled
                    ? Design.Surface.controlHover
                    : Design.Surface.controlResting,
                border: Design.Surface.border
            )
        }
        drawKeyboardFocus(around: shape)
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
        // This glyph is the control's only indication that another surface will open. Tertiary
        // ink landed below 2:1 on the System light field and nearly disappeared at catalogue
        // scale; secondary stays quiet beside the title while remaining an affordance.
        Design.Text.secondary.setStroke()
        path.stroke()
    }

    /// A template image is tinted to the label colour, so a symbol follows the theme the way the
    /// text beside it does; a coloured image — a theme swatch — is drawn as it is.
    private func drawItemImage(_ image: NSImage, in rect: NSRect) {
        TemplateImageDrawing.draw(image, in: rect, tint: Design.Text.label)
    }

    private func drawTitle(in rect: NSRect) {
        guard let title = displayedItem?.title, !title.isEmpty, rect.width > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let font = choiceStyle.isClassic
            ? Design.Typography.controlRegular()
            : Design.Typography.control()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Design.Text.label,
            .paragraphStyle: paragraph
        ]

        // The line box, so the selection reads on the same line as the image and the arrow
        // beside it — both centred on `midY`. `boundingRectForFont` is the family's glyph
        // extremes, which `draw(in:)` turns into dead air above the words: a point under SF,
        // four under a theme whose face reserves more (Platinum's Geneva fallback).
        let height = Design.Typography.lineHeight(of: font)
        let textRect = NSRect(
            x: rect.minX,
            y: rect.midY - height / 2,
            width: rect.width,
            height: height
        )
        (title as NSString).draw(in: textRect, withAttributes: attributes)
    }
}
