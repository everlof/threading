import AppKit
import LabelMorph

/// The app-owned boundary around LabelMorph's layer-backed single-line label.
///
/// The package owns glyph layout and animation. This wrapper owns Skalman's
/// semantic colour, Reduce Motion behavior, clipping, accessibility, and the
/// user-selected preset. Timing and intensity stay deliberately internal.
final class MorphingTitleLabel: NSView, ThemedComponent {

    private enum Defaults {
        static let intensity = 0.72
    }

    private let label = MorphingLabel()
    private let appEvents = AppEventObservations()
    private var usesAutomaticTextColor = true

    /// `nil` follows the app setting. Previews can pin a style without changing
    /// the global preference before their selector action has committed it.
    var morphStyleOverride: ChatNameMorphStyle? {
        didSet { applyEffect() }
    }

    var stringValue: String { label.text }

    var font: NSFont {
        get { label.font }
        set { label.font = newValue }
    }

    var textColor: NSColor {
        get { label.textColor }
        set {
            usesAutomaticTextColor = false
            label.textColor = newValue
        }
    }

    var alignment: NSTextAlignment {
        get { label.alignment }
        set { label.alignment = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        label.setAccessibilityElement(false)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        useAutomaticTextColor()
        applyEffect()

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.refreshAutomaticTextColor()
        }
    }

    override var intrinsicContentSize: NSSize {
        label.intrinsicContentSize
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAutomaticTextColor()
    }

    override func accessibilityValue() -> Any? {
        stringValue
    }

    /// Updates the title. Callers decide whether this is a rename worth
    /// animating or merely a reused/configured view that should land directly.
    func setStringValue(_ value: String, animated: Bool) {
        applyEffect()
        let shouldAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        label.setText(value, animated: shouldAnimate)
        setAccessibilityLabel(value)
        invalidateIntrinsicContentSize()
    }

    /// Returns to the design-system label colour after a caller-specific ink
    /// (such as the toolbar backdrop's contrast colour) is no longer needed.
    func useAutomaticTextColor() {
        usesAutomaticTextColor = true
        refreshAutomaticTextColor()
    }

    private func refreshAutomaticTextColor() {
        guard usesAutomaticTextColor else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            label.textColor = Design.Text.label
        }
    }

    private func applyEffect() {
        let style = morphStyleOverride ?? AppSettings.shared.chatNameMorphStyle
        guard let preset = MorphPreset(rawValue: style.rawValue) else { return }

        label.effect = preset.makeEffect(intensity: Defaults.intensity)
        label.timing = preset.recommendedTiming
    }
}
