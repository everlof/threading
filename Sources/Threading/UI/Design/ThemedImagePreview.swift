import AppKit

// MARK: - Themed Image Preview

/// An image shown at whatever size it is given, which the user can open in Quick Look.
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
///   look at properly — full size, zoomed, in Quick Look, which is where macOS keeps zoom,
///   rotate, share, Open With and full screen for free. Reaching that needs focus, a key, and
///   an accessibility action, which is what `ThemedControl` supplies.
///
/// Every route in lands on `performPrimaryAction`: click to focus and Space or Return, a
/// double-click, the trackpad's own Quick Look gesture, and VoiceOver's press.
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

    /// The file behind the picture, which is what Quick Look is given. Nil — or a path that has
    /// since been deleted — leaves the preview unavailable rather than opening an empty panel.
    var fileURL: URL? {
        didSet { toolTip = Self.tooltip(for: fileURL) }
    }

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

        image.draw(
            in: target,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        // Around the picture, not the view: the view is the whole content region and a ring at
        // its edge would read as the pane being focused rather than the image.
        drawKeyboardFocus(around: ThemedSurface.Shape(rect: target, radius: Design.Radius.control))
    }

    // MARK: - Activation

    override var acceptsFirstResponder: Bool { isEnabled && canPreview }

    /// The panel is not the key window when the pointer arrives, and a first click that only
    /// activated the window would make the picture feel dead. See `SidebarHoverRowView` for
    /// the same decision on the other pane.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, canPreview else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)

        // Double-click, not single: the picture fills the pane, and a system panel taking over
        // the screen because the user clicked the thing they were looking at is a jump scare.
        // The prompt's thumbnails open on one click for the opposite reason — a 40pt chip is
        // not something anyone is reading.
        if event.clickCount >= 2 {
            _ = performPrimaryAction()
        }
    }

    /// The trackpad's own Quick Look gesture — three-finger tap, or a force click — which is
    /// how many people reach it in Finder without ever pressing Space.
    override func quickLook(with event: NSEvent) {
        guard performPrimaryAction() else {
            super.quickLook(with: event)
            return
        }
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled, QuickLookPresenter.shared.present(fileURL) else { return false }
        return true
    }

    override func resetCursorRects() {
        guard canPreview else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func accessibilityLabel() -> String? {
        fileURL?.lastPathComponent ?? L10n.string("Image")
    }

    override func accessibilityHelp() -> String? {
        guard canPreview else { return nil }
        return L10n.string("Press to open in Quick Look")
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    // MARK: - Private Methods

    /// Whether there is anything to open. A picture with no file behind it — or one whose file
    /// has since been deleted — is still worth *looking* at, so it draws; it simply offers no
    /// preview, no pointer change and no place in the key loop.
    private var canPreview: Bool {
        image != nil && QuickLookPresenter.canPreview(fileURL)
    }

    private static func tooltip(for url: URL?) -> String? {
        guard QuickLookPresenter.canPreview(url) else { return nil }
        return L10n.string("Double-click or press Space to open in Quick Look")
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
