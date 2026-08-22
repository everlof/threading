import AppKit

/// The visible answer to an otherwise invisible screenshot drop target in the native titlebar.
///
/// The target belongs to `TitlebarActionWindow`, but its appearance belongs here: a quiet accent
/// wash keeps the toolbar underneath legible, and the sentence beside the traffic lights says
/// what the unfamiliar drop will do. The view never hit-tests, so it cannot turn feedback for a
/// drag into a new titlebar control or interfere with the window's double-click surface.
@MainActor
final class ScreenshotReportDropTargetView: NSView, ThemedComponent {

    private enum Layout {
        /// Clears the native traffic-light cluster and lands the sentence in the strip beside it.
        static let trafficLightClearance: CGFloat = 78
        static let glyphSlot: CGFloat = 16
        /// The one-shot arrival travels only far enough to be noticed as an answer to the drag.
        static let arrivalDistance: CGFloat = 6
    }

    private let glyph = GlyphView()
    private let caption = NSTextField(labelWithString: L10n.string("Drop screenshot to report"))
    private let content = NSStackView()
    private let appEvents = AppEventObservations()

    private(set) var isPresented = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = true

        glyph.setSymbol("photo", slot: Layout.glyphSlot, role: .control)

        caption.applyFont(.caption)
        caption.lineBreakMode = .byTruncatingTail
        caption.setAccessibilityElement(false)

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.addArrangedSubview(glyph)
        content.addArrangedSubview(caption)
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Layout.trafficLightClearance
            ),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        isHidden = true
        alphaValue = 0
        setAccessibilityElement(false)
        applyInk()

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyInk()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyInk()
    }

    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.dropTarget.setFill()
        bounds.intersection(dirtyRect).fill()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = 1 / scale
        Design.Surface.accent.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: width).fill()
    }

    /// Shows the accepted-drop sentence. Arrival moves once; the held state is still, and Reduce
    /// Motion receives the complete highlighted target without constructing either animation.
    func setPresented(_ presented: Bool, animated: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented

        layer?.removeAnimation(forKey: "screenshotDrop.arrival")
        content.layer?.removeAnimation(forKey: "screenshotDrop.captionArrival")

        guard presented else {
            alphaValue = 0
            isHidden = true
            return
        }

        isHidden = false
        alphaValue = 1
        guard animated, !Design.Motion.reducesMotion else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Design.Motion.quick
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: "screenshotDrop.arrival")

        let arrive = CABasicAnimation(keyPath: "transform.translation.x")
        arrive.fromValue = -Layout.arrivalDistance
        arrive.toValue = 0
        arrive.duration = Design.Motion.quick
        arrive.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.layer?.add(arrive, forKey: "screenshotDrop.captionArrival")
    }

    private func applyInk() {
        glyph.tint = Design.Surface.accent
        caption.textColor = Design.Surface.accent
        needsDisplay = true
    }
}
