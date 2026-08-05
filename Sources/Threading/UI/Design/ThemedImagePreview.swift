import AppKit

// MARK: - Themed Image Preview

/// An image shown at whatever size it is given, which the user can open in the media inspector.
///
/// Two things this is, that `NSImageView` is not:
///
/// - **It has no intrinsic content size.** `NSImageView` reports the picture's own dimensions,
///   so a 1320pt-wide screenshot asks for a 1320pt-wide pane. Flooring its content priorities
///   stops that *winning*, but the size is still in the layout and still what `fittingSize`
///   answers — measured: an 8×8 image gave the display panel a 155pt preferred width and a
///   1320×1100 one gave 228pt, for the same chrome and the same caption. Anything that reads a
///   preferred width — a split item settling after a drag, a window being resized down — has
///   been handed the picture's dimensions as an opinion it never should have had. Stating
///   `noIntrinsicMetric` removes the opinion rather than out-prioritising it, and the image
///   simply draws into whatever it is given.
/// - **It is a control.** An image the agent just produced is the thing the user most wants to
///   look at properly — full size, zoomed, panned, and beside the other images in its collection.
///   Reaching that needs focus, a key, and an accessibility action, which is what
///   `ThemedControl` supplies.
///
/// Every route in lands on `performPrimaryAction`: click, Space or Return, the trackpad's own
/// preview gesture, and VoiceOver's press.
final class ThemedImagePreview: ThemedControl {

    // MARK: - Properties

    /// The picture. Nil draws nothing and leaves the view out of the key loop — there is
    /// nothing to preview and nothing to look at.
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            // Clearing the picture clears the file with it, so a caller that only says
            // `image = nil` cannot leave the previous file previewable behind an empty view.
            if image == nil { fileURL = nil }
            resignIfEmpty()
            invalidateCursorRectsAndDisplay()
        }
    }

    /// The file behind the picture, which supplies actions and a stable collection identity.
    /// Nil — or a path that has since been deleted — leaves inspection unavailable.
    var fileURL: URL? {
        didSet { toolTip = Self.tooltip(for: fileURL) }
    }

    /// Supplies siblings and the clicked index where the image belongs to a collection. A plain
    /// display-pane image leaves this nil and receives the ordinary one-item inspector.
    var inspectorSelectionProvider: (() -> MediaInspectorSelection?)?

    private var isTrackingPress = false
    private var isPressArmed = false

    /// Where the image is actually drawn inside the view: scaled down to fit, never up, and
    /// pinned to the top edge. Read by the tests, and by the focus ring, which belongs around
    /// the picture rather than around the empty pane it floats in.
    var imageRect: NSRect {
        guard let image else { return .zero }
        return Self.fittedRect(for: image.size, in: bounds)
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    /// The whole point — see the type's note. A view that states no size cannot lend the pane
    /// the picture's dimensions.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Scales to fit and **never up**: a 16pt icon blown across the pane is not a better look
    /// at it, it is a blurry one. Centred across the width, pinned to the top — the pane is
    /// taller than most pictures, and one centred vertically floats with dead space above it,
    /// away from the header the eye is already at.
    static func fittedRect(for imageSize: NSSize, in bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }

        let scale = min(1, min(bounds.width / imageSize.width, bounds.height / imageSize.height))
        let size = NSSize(
            width: (imageSize.width * scale).rounded(.down),
            height: (imageSize.height * scale).rounded(.down)
        )

        return NSRect(
            x: bounds.minX + ((bounds.width - size.width) / 2).rounded(.down),
            y: bounds.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }

        let target = imageRect
        guard !target.isEmpty else { return }

        let shape = ThemedSurface.Shape(rect: target, radius: Design.Radius.control)

        image.draw(
            in: target,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        // The image is itself the control. A quiet themed wash makes that discoverable when the
        // pointer arrives, and holding the wash through mouse-down keeps the click from feeling
        // like it landed on inert content. No transform: Reduce Motion should not turn a basic
        // affordance into a different interaction.
        //
        // `imageHoverWash` rather than `controlHover`, because this fill lands *on top of* the
        // picture instead of under it — see the role's note. `controlHover` is opaque under
        // System and under half the stock themes, so it hid the image outright.
        if isHovered || isPressArmed {
            Design.Surface.imageHoverWash.setFill()
            shape.path.fill()
            Design.Surface.accent.setStroke()
            let hoverPath = shape.inset(by: Design.Radius.border / 2).path
            hoverPath.lineWidth = Design.Radius.border
            hoverPath.stroke()
        }

        // Around the picture, not the view: the view is the whole content region and a ring at
        // its edge would read as the pane being focused rather than the image.
        drawKeyboardFocus(around: shape)
    }

    // MARK: - Activation

    override var acceptsFirstResponder: Bool { isEnabled && canInspect }

    /// The panel is not the key window when the pointer arrives, and a first click that only
    /// activated the window would make the picture feel dead. See `SidebarHoverRowView` for
    /// the same decision on the other pane.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, canInspect else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        isTrackingPress = true
        isPressArmed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingPress else { return }
        let armed = bounds.contains(convert(event.locationInWindow, from: nil))
        guard armed != isPressArmed else { return }
        isPressArmed = armed
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let shouldInspect = isTrackingPress && isPressArmed
            && bounds.contains(convert(event.locationInWindow, from: nil))
        isTrackingPress = false
        isPressArmed = false
        needsDisplay = true
        if shouldInspect { _ = performPrimaryAction() }
    }

    /// The trackpad's preview gesture — three-finger tap, or a force click — follows the same
    /// in-window route as click and Space.
    override func quickLook(with event: NSEvent) {
        guard performPrimaryAction() else {
            super.quickLook(with: event)
            return
        }
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        if let selection = inspectorSelectionProvider?() {
            return MediaInspectorPresenter.present(selection, from: self)
        }
        guard let fileURL, let image else { return false }
        return MediaInspectorPresenter.present(
            MediaInspectorItem(url: fileURL, image: image),
            from: self
        )
    }

    override func resetCursorRects() {
        guard canInspect else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func accessibilityLabel() -> String? {
        fileURL?.lastPathComponent ?? L10n.string("Image")
    }

    override func accessibilityHelp() -> String? {
        guard canInspect else { return nil }
        return L10n.string("Press to inspect. Press Space again to close.")
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    // MARK: - Private Methods

    /// Whether there is anything to open. A picture with no file behind it — or one whose file
    /// has since been deleted — is still worth *looking* at, so it draws; it simply offers no
    /// preview, no pointer change and no place in the key loop.
    private var canInspect: Bool {
        image != nil && QuickLookPresenter.canPreview(fileURL)
    }

    private static func tooltip(for url: URL?) -> String? {
        guard QuickLookPresenter.canPreview(url) else { return nil }
        return L10n.string("Click or press Space to inspect")
    }

    private func resignIfEmpty() {
        guard image == nil, hasKeyboardFocus else { return }
        window?.makeFirstResponder(nil)
    }

    private func invalidateCursorRectsAndDisplay() {
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
}
