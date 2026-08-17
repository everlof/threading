import AppKit
import ThreadingExtensionKit

/// Host-owned presentation of companion pixels.
///
/// The companion supplies bounded BGRA buffers, never an NSView, CALayer, IOSurface, event, or
/// callback. AppKit ownership and event normalization remain entirely in Threading.
@MainActor
final class ExtensionRemoteSurfaceView:
    NSView,
    ThemedComponent,
    ExtensionRemoteSurfaceConsumer
{
    private let statusLabel = NSTextField(
        labelWithString: L10n.string("Connecting…")
    )
    private var definition: ExtensionRemoteSurface?
    private var tracking: NSTrackingArea?
    private(set) var subscription: ExtensionRemoteSurfaceSubscription?
    private var isPresentationVisible = false
    private var framePixelSize: CGSize?

    var onDisconnect: ((String) -> Void)?

    override var acceptsFirstResponder: Bool {
        definition?.acceptsKeyboard == true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0),
            pattern: .backdrop
        )
        layer?.contentsGravity = .resizeAspect
        setAccessibilityRole(.image)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.applyFont(.detail())
        statusLabel.textColor = Design.Text.secondary
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setAccessibilityIdentifier("extension.remote-surface.status")
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: Design.Spacing.pane
            ),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.pane
            )
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppThemeRefresh.repaint(self)
    }

    func install(subscription: ExtensionRemoteSurfaceSubscription?) {
        self.subscription?.cancel()
        self.subscription = subscription
        if subscription == nil {
            statusLabel.stringValue = L10n.string("The remote surface is unavailable.")
        } else {
            if definition == nil {
                statusLabel.stringValue = L10n.string("Connecting…")
            }
            publishViewport()
        }
    }

    func setPresentationVisible(_ visible: Bool) {
        guard isPresentationVisible != visible else { return }
        isPresentationVisible = visible
        publishViewport()
    }

    override func layout() {
        super.layout()
        publishViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishViewport()
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        self.tracking = tracking
        super.updateTrackingAreas()
    }

    func remoteSurfaceDidConnect(definition: ExtensionRemoteSurface) {
        self.definition = definition
        setAccessibilityLabel(definition.accessibilityLabel)
        statusLabel.stringValue = L10n.format(
            "Waiting for %@…",
            definition.title
        )
        if definition.acceptsKeyboard {
            window?.makeFirstResponder(self)
        }
    }

    func remoteSurfaceDidReceive(_ frame: ExtensionRemoteSurfaceFrameValue) -> Bool {
        guard frame.metadata.pixelFormat == .bgra8Premultiplied,
              let provider = CGDataProvider(data: frame.pixels as CFData),
              let image = CGImage(
                  width: frame.metadata.width,
                  height: frame.metadata.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: frame.metadata.bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                  ).union(.byteOrder32Little),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return false
        }
        framePixelSize = CGSize(
            width: frame.metadata.width,
            height: frame.metadata.height
        )
        layer?.contents = image
        statusLabel.isHidden = true
        return window != nil && isPresentationVisible
    }

    func remoteSurfaceDidDisconnect(message: String) {
        subscription = nil
        definition = nil
        framePixelSize = nil
        layer?.contents = nil
        statusLabel.isHidden = false
        statusLabel.stringValue = message
        onDisconnect?(message)
    }

    override func mouseMoved(with event: NSEvent) {
        // A position under an open dropdown is the menu's, not the extension's — see
        // `NSView.uncoveredPointerLocation(in:)`.
        guard uncoveredPointerLocation(in: event) != nil else { return }
        sendPointer(event, kind: .pointerMoved)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(event, kind: .pointerDown)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointer(event, kind: .pointerUp)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(event, kind: .pointerDown)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointer(event, kind: .pointerUp)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointer(event, kind: .pointerDown)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendPointer(event, kind: .pointerUp)
    }

    override func scrollWheel(with event: NSEvent) {
        guard definition?.acceptsPointer == true,
              let subscription else {
            return
        }
        subscription.send(.init(
            presentationID: subscription.presentationID,
            kind: .scroll,
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            modifiers: modifiers(from: event.modifierFlags)
        ))
    }

    override func keyDown(with event: NSEvent) {
        sendKey(event, kind: .keyDown)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, kind: .keyUp)
    }

    private func sendPointer(
        _ event: NSEvent,
        kind: ExtensionRemoteSurfaceInputKind
    ) {
        guard definition?.acceptsPointer == true,
              let subscription,
              let contentRect = aspectFitContentRect(),
              contentRect.width > 0,
              contentRect.height > 0 else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard contentRect.contains(point) else { return }
        let x = min(1, max(
            0,
            Double((point.x - contentRect.minX) / contentRect.width)
        ))
        let y = min(1, max(
            0,
            1 - Double((point.y - contentRect.minY) / contentRect.height)
        ))
        subscription.send(.init(
            presentationID: subscription.presentationID,
            kind: kind,
            x: x,
            y: y,
            button: kind == .pointerMoved ? nil : event.buttonNumber,
            modifiers: modifiers(from: event.modifierFlags)
        ))
    }

    /// Matches `CALayerContentsGravity.resizeAspect` so normalized pointer coordinates describe
    /// the pixels the user can actually see, not any letterbox around a stale/resizing frame.
    private func aspectFitContentRect() -> CGRect? {
        guard let framePixelSize,
              framePixelSize.width > 0,
              framePixelSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return nil
        }
        let scale = min(
            bounds.width / framePixelSize.width,
            bounds.height / framePixelSize.height
        )
        let size = CGSize(
            width: framePixelSize.width * scale,
            height: framePixelSize.height * scale
        )
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func sendKey(
        _ event: NSEvent,
        kind: ExtensionRemoteSurfaceInputKind
    ) {
        guard definition?.acceptsKeyboard == true,
              let subscription else {
            return
        }
        subscription.send(.init(
            presentationID: subscription.presentationID,
            kind: kind,
            keyCode: Int(event.keyCode),
            characters: event.characters.map { String($0.prefix(32)) },
            modifiers: modifiers(from: event.modifierFlags)
        ))
    }

    private func publishViewport() {
        guard let subscription else { return }
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        subscription.updateViewport(
            width: Double(max(0, bounds.width)),
            height: Double(max(0, bounds.height)),
            scale: Double(scale),
            isVisible: isPresentationVisible && window != nil
        )
    }

    private func modifiers(
        from flags: NSEvent.ModifierFlags
    ) -> [ExtensionRemoteSurfaceModifier] {
        var result: [ExtensionRemoteSurfaceModifier] = []
        if flags.contains(.shift) { result.append(.shift) }
        if flags.contains(.control) { result.append(.control) }
        if flags.contains(.option) { result.append(.option) }
        if flags.contains(.command) { result.append(.command) }
        return result
    }
}
