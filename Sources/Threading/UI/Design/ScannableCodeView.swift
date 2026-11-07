import AppKit

// MARK: - Scannable Code View

/// A QR code someone scans with a phone's camera, with one line under it that says what it is.
///
/// The code is `PairingCodeImage`'s — the app's own geometry with the full quiet zone — drawn at
/// the side it is shown at, because a resampled module edge is the one thing a scan cannot spare.
/// The caption is replaceable, so the owner can say what just happened ("Link copied") without
/// rebuilding the sheet. Fixed size: one code and a short wrapped line.
///
/// The plate and ink take the theme's accent hue, so the code is drawn again when the theme or
/// the appearance changes rather than keeping the colours it was opened with.
@MainActor
final class ScannableCodeView: NSView, ThemedComponent {
    private let code = NSImageView()
    private let label: NSTextField
    private let payload: String
    private let side: CGFloat
    private let appEvents = AppEventObservations()

    var caption: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    /// Whether a code could be drawn for the payload; an oversized payload draws none.
    var hasCode: Bool { code.image != nil }

    init(payload: String, caption: String, side: CGFloat, accessibilityLabel: String) {
        label = NSTextField(wrappingLabelWithString: caption)
        self.payload = payload
        self.side = side
        super.init(frame: .zero)
        drawCode()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.drawCode() }
        code.imageScaling = .scaleNone
        code.setAccessibilityLabel(accessibilityLabel)
        label.applyFont(.subheading)
        label.textColor = Design.Text.secondary
        label.alignment = .center
        label.preferredMaxLayoutWidth = side
        let stack = NSStackView(views: [code, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            code.widthAnchor.constraint(equalToConstant: side),
            code.heightAnchor.constraint(equalToConstant: side),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawCode()
    }

    private func drawCode() {
        code.image = PairingCodeImage.make(for: payload, side: side)
    }
}
