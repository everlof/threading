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

    /// The label's ink stated as a rule rather than a value.
    ///
    /// The package freezes a `CGColor` per glyph, so a colour assigned once and never
    /// revisited still reads as the old theme's after a live switch. Holding the *decision*
    /// means a theme change, an appearance flip, or a caller whose own state moved
    /// (selection, dormancy) all resolve through one path.
    private var inkProvider: () -> NSColor = { Design.Text.label }

    /// `nil` follows the app setting. Previews can pin a style without changing
    /// the global preference before their selector action has committed it.
    var morphStyleOverride: ChatNameMorphStyle? {
        didSet { applyEffect() }
    }

    var stringValue: String { label.text }

    var font: NSFont {
        get { label.font }
        set {
            // Guarded like the package's own setters: a sidebar of these restates the font on
            // every configure pass, and only a real change moves the intrinsic size.
            guard newValue != label.font else { return }
            label.font = newValue
            // The package invalidates the *label's* intrinsic size, but the engine caches this
            // wrapper's separately — and a tab that swaps weight on selection grows a point or
            // two. Left stale, the emphasized line was laid out in the regular line's width,
            // and tail truncation cut two characters to fit an ellipsis into a one-point
            // shortfall: the settings sidebar read "Usage" as "Usa…" precisely while selected.
            invalidateIntrinsicContentSize()
        }
    }

    var textColor: NSColor {
        get { label.textColor }
        set { setTextColor { newValue } }
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

        // Every title this wraps sits in a slot narrower than some of the names it has to
        // carry. Without this the clip above cuts the line dead mid-glyph, with nothing to
        // say it was shortened — the one way this reads worse than the label it replaces.
        label.truncation = .tail
        addSubview(label)

        // The wrapper yields where an `NSTextField` label would, so a caller can drop it
        // into a row without restating the priority its own intrinsic width demands.
        setContentCompressionResistancePriority(.init(1), for: .horizontal)

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
            self?.refreshTextColor()
        }
    }

    override var intrinsicContentSize: NSSize {
        label.intrinsicContentSize
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTextColor()
    }

    override func accessibilityValue() -> Any? {
        stringValue
    }

    /// Updates the title. Callers decide whether this is a rename worth
    /// animating or merely a reused/configured view that should land directly.
    func setStringValue(_ value: String, animated: Bool) {
        let shouldAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Only a morph reads the effect, and a sidebar of these is reconfigured constantly
        // while an agent works — so the setting is not consulted on every pass.
        if shouldAnimate {
            applyEffect()
        }
        label.setText(value, animated: shouldAnimate)
        setAccessibilityLabel(value)
        invalidateIntrinsicContentSize()
    }

    /// How long a morph into `value` takes to settle: the effect's own duration plus the
    /// per-character stagger across the longer of the two names.
    ///
    /// A caller repeating a morph — a preview demonstrating what a transition looks like — waits
    /// for this rather than picking a period. The presets differ by more than a third of a
    /// second and cascade per character, so one fixed guess either cuts the last characters off
    /// mid-flight or leaves the row looking finished. Zero under Reduce Motion, where
    /// `setStringValue` does not animate at all.
    func morphSettleDuration(to value: String) -> TimeInterval {
        guard !Design.Motion.reducesMotion else { return 0 }
        let characters = max(stringValue.count, value.count)
        return label.timing.duration + label.timing.stagger * Double(max(0, characters - 1))
    }

    /// States the ink as a rule to be re-asked, rather than a colour to be kept.
    ///
    /// Use this wherever the answer depends on something that moves — the row's selection
    /// or dormancy, the app theme — so a change re-resolves rather than leaving the glyphs
    /// holding the colour they were built with.
    func setTextColor(_ provider: @escaping () -> NSColor) {
        inkProvider = provider
        refreshTextColor()
    }

    /// Returns to the design-system label colour after a caller-specific ink
    /// (such as the toolbar backdrop's contrast colour) is no longer needed.
    func useAutomaticTextColor() {
        setTextColor { Design.Text.label }
    }

    /// Re-asks the ink provider, for a caller whose own state has just moved.
    func refreshTextColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            label.textColor = inkProvider()
        }
    }

    private func applyEffect() {
        let style = morphStyleOverride ?? AppSettings.shared.chatNameMorphStyle
        guard let preset = MorphPreset(rawValue: style.rawValue) else { return }

        label.effect = preset.makeEffect(intensity: Defaults.intensity)
        label.timing = preset.recommendedTiming
    }
}
