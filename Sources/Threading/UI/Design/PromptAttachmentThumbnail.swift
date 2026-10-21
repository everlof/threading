import AppKit

private enum PromptAttachmentTileDefaults {
    /// The plate under a movie poster's play mark has the size of a small control.
    static let playMarkDiameter = Design.Size.chipHeight
    static let playMarkSymbol = "play.fill"
    static let playMarkIdentifier = "composer.attachment.play"
}

// MARK: - Prompt Image Attachment

/// One file waiting in the strip, and the picture standing in for it.
struct PromptMediaAttachment {

    /// What the picture is *of*: the file itself, or the first frame of a movie.
    enum Kind: Equatable {
        case image
        case movie
    }

    let id = UUID()
    let path: String
    let kind: Kind
    /// The image decoded to thumbnail size — or, for a movie, its poster frame.
    let image: NSImage

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// What the lightbox opens this as. Main-actor because the registry it asks is.
    #if !os(Linux)
    @MainActor
    var inspectorContent: MediaInspectorItemContent {
        switch kind {
        case .image:
            return .image
        case .movie:
            return MediaDocumentRendererRegistry.supports(.video)
                ? .media(format: .video)
                : .document
        }
    }
    #endif
}

/// One recognisable image with its removal control over the corner, matching the attachment
/// treatment in the chat composer rather than exposing a temporary path as if it were prose.
///
/// A movie is drawn as its poster frame under a play mark. A poster is a picture of a moment
/// and so is a screenshot — at 80 points nothing else says which of the two tiles in the strip
/// can be played, and the mark is the same answer the attachments pane gives its rows.
final class PromptAttachmentThumbnail: ThemedControl {

    private let attachment: PromptMediaAttachment
    private let removeButton: PromptAttachmentRemoveButton
    /// Present for a movie only. A subview rather than ink in `draw`, so a test can find the
    /// mark the way it finds the pane's, and so the glyph stays a configured symbol rather than
    /// a scaled render.
    private let playMark: NSImageView?
    private var isPressed = false { didSet { needsDisplay = true } }
    private var menuSession: AnyObject?

    var onRemove: (() -> Void)?
    var onComment: (() -> Void)?
    #if os(Linux)
    var onInspect: (() -> Bool)?
    var onShowMenu: ((ThemedMenuAnchor) -> Bool)?
    var id: UUID { attachment.id }
    var path: String { attachment.path }
    var removeVisibleRect: NSRect { convert(removeButton.visibleRect, from: removeButton) }
    #else
    var inspectorSelectionProvider: (() -> MediaInspectorSelection?)?
    #endif

    init(attachment: PromptMediaAttachment) {
        self.attachment = attachment
        removeButton = PromptAttachmentRemoveButton(
            accessibility: "Remove \(attachment.name)"
        )
        playMark = attachment.kind == .movie ? Self.makePlayMark() : nil
        super.init(frame: .zero)
        setup()
    }

    private static func makePlayMark() -> NSImageView {
        let mark = NSImageView()
        let slot = Design.Symbol.slot(
            inControlOfHeight: PromptAttachmentTileDefaults.playMarkDiameter
        )
        mark.image = Design.Symbol.image(
            PromptAttachmentTileDefaults.playMarkSymbol,
            slot: slot,
            pointSize: Design.Symbol.pointSize(forSlot: slot),
            weight: .semibold
        )
        mark.setAccessibilityElement(false)
        mark.setAccessibilityIdentifier(PromptAttachmentTileDefaults.playMarkIdentifier)
        mark.translatesAutoresizingMaskIntoConstraints = false
        return mark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)

        removeButton.onPress = { [weak self] in self?.onRemove?() }
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Design.Size.promptAttachmentThumbnail),
            heightAnchor.constraint(equalToConstant: Design.Size.promptAttachmentThumbnail),
            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),
            removeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.tight
            )
        ])

        if let playMark {
            // Under the remove button in the hierarchy: the two never overlap, but the corner
            // control is the one that must win if a theme ever grows the mark towards it.
            addSubview(playMark, positioned: .below, relativeTo: removeButton)
            NSLayoutConstraint.activate([
                playMark.centerXAnchor.constraint(equalTo: centerXAnchor),
                playMark.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let radius = Design.Radius.control
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        let imageSize = attachment.image.size
        if imageSize.width > 0, imageSize.height > 0 {
            let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let destination = NSRect(
                x: bounds.midX - imageSize.width * scale / 2,
                y: bounds.midY - imageSize.height * scale / 2,
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            attachment.image.draw(
                in: destination,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        } else {
            Design.Surface.controlResting.setFill()
            path.fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        if let playMark { drawPlate(under: playMark) }

        let borderWidth = Design.Radius.border
        let borderPath = NSBezierPath(
            roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
            xRadius: max(0, radius - borderWidth / 2),
            yRadius: max(0, radius - borderWidth / 2)
        )
        let isHighlighted = isHovered || hasKeyboardFocus
        (isHighlighted ? Design.Surface.accent : Design.Surface.border).setStroke()
        borderPath.lineWidth = borderWidth
        borderPath.stroke()

        if isPressed {
            Design.Surface.controlHover.setFill()
            path.fill()
        }

        drawKeyboardFocus(
            around: ThemedSurface.Shape(rect: bounds, radius: radius),
            color: Design.Surface.accent
        )
    }

    /// The play mark floats over arbitrary pixels, so it stands on the same opaque themed plate
    /// the remove button does: a poster frame is as likely to be white as black under it, and a
    /// bare glyph in the label colour would vanish on half of them.
    private func drawPlate(under mark: NSImageView) {
        let diameter = PromptAttachmentTileDefaults.playMarkDiameter
        let plate = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let panel = Design.Surface.panel.composited(over: Design.Surface.ground)
        let fill = Design.Surface.elevated.composited(over: panel)
        let ink = Design.Text.on(fill)
        ThemedSurface.draw(
            plate,
            fill: fill,
            border: ink.border,
            radius: Design.Radius.pill(height: diameter)
        )
        mark.contentTintColor = isEnabled ? ink.label : ink.quaternary
    }

    /// A thumbnail in the tray is a picture you press, not a control's plate. See
    /// `PointerClaiming`.
    override var restingPointer: NSCursor? {
        #if os(Linux)
        return onInspect == nil ? nil : .pointingHand
        #else
        return .pointingHand
        #endif
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldPreview = isPressed
            && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldPreview { _ = performPrimaryAction() }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = presentContextMenu(at: .pointer(event.locationInWindow))
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    /// No pointer asked for this one, so it hangs from the thumbnail itself.
    override func accessibilityPerformShowMenu() -> Bool {
        presentContextMenu(at: .control)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { attachment.name }
    override func accessibilityHelp() -> String? {
        #if os(Linux)
        guard onInspect != nil else { return nil }
        #endif
        return L10n.format("Press to inspect %@", attachment.name)
    }

    /// What the picture is of, for a reader who cannot see the play mark.
    override func accessibilityValue() -> Any? {
        attachment.kind == .movie ? L10n.string("Movie") : nil
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        window?.makeFirstResponder(self)

        #if os(Linux)
        return onInspect?() ?? false
        #else

        let selection = inspectorSelectionProvider?()
            ?? existingFileURL.map {
                MediaInspectorSelection(
                    items: [MediaInspectorItem(
                        url: $0,
                        title: attachment.name,
                        image: attachment.image
                    )],
                    selectedIndex: 0
                )
            }
        guard let selection, MediaInspectorPresenter.present(selection, from: self) else {
            SystemAlert.refuse()
            return false
        }
        return true
        #endif
    }

    private func presentContextMenu(at anchor: ThemedMenuAnchor) -> Bool {
        #if os(Linux)
        return onShowMenu?(anchor) ?? false
        #else
        guard menuSession == nil else { return true }

        var entries: [ThemedMenuEntry] = [
            item("Inspect") { [weak self] in _ = self?.performPrimaryAction() }
        ]
        if onComment != nil {
            entries.append(item("Comment…") { [weak self] in self?.onComment?() })
        }
        entries += [
            item("Open in Default App") { [weak self] in self?.openInDefaultApp() },
            item("Reveal in Finder") { [weak self] in self?.revealInFinder() },
            .separator
        ]
        // A movie's poster is a frame the strip chose. The frame worth copying is the one the
        // user stops on, and that is the lightbox's Copy Frame.
        if attachment.kind == .image {
            entries.append(item("Copy Image") { [weak self] in self?.copyImage() })
        }
        entries += [
            item("Copy File Name") { [weak self] in self?.copyFileName() },
            item("Copy File Path") { [weak self] in self?.copyFilePath() },
            .separator,
            item("Open in System Quick Look") { [weak self] in self?.openQuickLook() },
            .separator,
            item("Remove Attachment") { [weak self] in self?.removeAttachment() }
        ]

        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 190),
            from: self,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
        return menuSession != nil
        #endif
    }

    #if !os(Linux)
    private func item(_ title: String, action: @escaping () -> Void) -> ThemedMenuEntry {
        .item(ThemedMenuItem(title: title, onChoose: action))
    }

    private func openQuickLook() {
        guard QuickLookPresenter.shared.present(existingFileURL) else {
            SystemAlert.refuse()
            return
        }
    }

    private func openInDefaultApp() {
        guard let url = existingFileURL, NSWorkspace.shared.open(url) else {
            SystemAlert.refuse()
            return
        }
    }

    private func revealInFinder() {
        guard let url = existingFileURL else {
            SystemAlert.refuse()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([attachment.image])
    }

    private func copyFileName() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(attachment.name, forType: .string)
    }

    private func copyFilePath() {
        guard let url = existingFileURL else {
            SystemAlert.refuse()
            return
        }

        // Keep the string useful in a terminal while the URL lets Finder and document apps
        // treat the same paste as a file.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.path, forType: .string)
    }

    private func removeAttachment() {
        onRemove?()
    }

    private var existingFileURL: URL? {
        guard FileManager.default.fileExists(atPath: attachment.path) else { return nil }
        return URL(fileURLWithPath: attachment.path)
    }
    #endif
}

/// The close affordance floats over arbitrary pixels, so its fill is flattened to an opaque
/// themed colour before drawing. A translucent control surface here lets the screenshot change
/// the button's contrast from one attachment to the next.
private final class PromptAttachmentRemoveButton: ThemedControl {

    private let iconView = NSImageView()
    private let accessibilityName: String
    private var isPressed = false { didSet { needsDisplay = true } }

    var onPress: (() -> Void)?

    init(accessibility: String) {
        accessibilityName = accessibility
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(
            systemSymbolName: DesignSymbols.removeAttachment,
            accessibilityDescription: nil
        )
        iconView.symbolConfiguration = Design.Symbol.configuration(
            Design.Symbol.control,
            weight: .medium
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Design.Size.inlineButtonTarget),
            heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonTarget),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Design.Symbol.control),
            iconView.heightAnchor.constraint(equalToConstant: Design.Symbol.control)
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Design.Size.inlineButtonTarget,
            height: Design.Size.inlineButtonTarget
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let panel = Design.Surface.panel.composited(over: Design.Surface.ground)
        let resting = Design.Surface.elevated.composited(over: panel)
        let fill = isPressed || isHovered
            ? Design.Surface.controlHover.composited(over: resting)
            : resting
        let ink = Design.Text.on(fill)
        let shape = ThemedSurface.draw(
            bounds,
            fill: fill,
            border: ink.border,
            radius: Design.Radius.pill(height: bounds.height)
        )
        drawKeyboardFocus(around: shape, color: ink.label)
        iconView.contentTintColor = isEnabled ? ink.label : ink.quaternary
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldFire = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldFire { performPress() }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool { performPress() }
    override func performPrimaryAction() -> Bool { performPress() }

    @discardableResult
    private func performPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}
