import AppKit

/// The play/pause target drawn over a movie canvas.
///
/// A video keeps its timeline below the picture, while the primary playback action sits where
/// the eye is already looking. Paused video keeps Play visible. While a video is running the
/// control gets out of the frame and returns when the pointer enters the canvas or keyboard focus
/// reaches it, showing Pause — the action a press will take, never the state as an inert badge.
///
/// The control spans the canvas only so its one tracking area can answer hover anywhere over the
/// movie. Hit testing stays bounded to the drawn target; the rest passes through to the canvas and
/// keeps its context menu. Keyboard and accessibility activation reach the same `onToggle` seam.
@MainActor
final class MediaPlaybackOverlayView: ThemedControl {

    enum Layout {
        /// Larger than a toolbar target because the video has no row extending its hit area.
        static let target: CGFloat = 48
        static let glyphSlot: CGFloat = 22
    }

    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            updateSemantics()
            needsDisplay = true
        }
    }

    var onToggle: (() -> Void)?
    var onShowContextMenu: ((ThemedMenuAnchor) -> Bool)?

    private(set) var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            needsDisplay = true
        }
    }
    private var isTrackingPress = false

    private var controlRect: NSRect {
        NSRect(
            x: bounds.midX - Layout.target / 2,
            y: bounds.midY - Layout.target / 2,
            width: Layout.target,
            height: Layout.target
        )
    }

    /// Internal so behavior and rendered-state tests can ask about the promise rather than
    /// reverse-engineering it from pixels.
    var isControlVisibleForTesting: Bool {
        isEnabled && (!isPlaying || isHovered || hasKeyboardFocus || isPressed)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("media.playback-overlay")
        updateSemantics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hit testing

    /// The canvas remains the canvas outside the one target actually drawn on it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isControlVisibleForTesting else { return nil }
        // AppKit already supplies `point` in the receiver's coordinates. Converting it again
        // would offset the target whenever the movie sits above a transport row.
        return controlRect.contains(point) ? self : nil
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, controlRect.contains(localPoint(for: event)) else { return }
        isTrackingPress = true
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, isTrackingPress else { return }
        isPressed = controlRect.contains(localPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, isTrackingPress else { return }
        let shouldToggle = controlRect.contains(localPoint(for: event))
        isTrackingPress = false
        isPressed = false
        if shouldToggle { onToggle?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard onShowContextMenu?(.pointer(event.locationInWindow)) == true else {
            super.rightMouseDown(with: event)
            return
        }
    }

    private func localPoint(for event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: - Keyboard and accessibility

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        onToggle?()
        return true
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    override func accessibilityPerformShowMenu() -> Bool {
        onShowContextMenu?(.control) == true
    }

    private func updateSemantics() {
        let action = isPlaying ? L10n.string("Pause") : L10n.string("Play")
        setAccessibilityTitle(action)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isControlVisibleForTesting else { return }
        DisabledControlDrawing.draw(isEnabled: isEnabled) {
            let fill = isPressed ? Design.Surface.controlHover : Design.Surface.elevated
            let shape = ThemedSurface.draw(
                controlRect,
                fill: fill,
                border: Design.Surface.border,
                radius: Design.Radius.control(fitting: controlRect.size),
                bevel: isPressed ? .sunken : .automatic
            )
            drawKeyboardFocus(around: shape, color: Design.Text.on(fill).label)
            drawGlyph(in: controlRect, tint: Design.Text.on(fill).label)
        }
    }

    private func drawGlyph(in rect: NSRect, tint: NSColor) {
        let name = isPlaying ? "pause.fill" : "play.fill"
        guard let image = Design.Symbol.image(
            name,
            slot: Layout.glyphSlot,
            pointSize: Layout.glyphSlot,
            weight: .semibold
        ) else { return }
        let slot = NSRect(
            x: rect.midX - Layout.glyphSlot / 2,
            y: rect.midY - Layout.glyphSlot / 2,
            width: Layout.glyphSlot,
            height: Layout.glyphSlot
        )
        TemplateImageDrawing.draw(image, in: slot, tint: tint)
    }
}
