import AppKit
import LabelMorph

/// The app-owned boundary around LabelMorph's layer-backed single-line label.
///
/// The package owns glyph layout and animation. This wrapper owns Threading's
/// semantic colour, Reduce Motion behavior, clipping, accessibility, and the
/// user-selected preset. Timing and intensity stay deliberately internal.
public final class MorphingTitleLabel: NSView, ThemedComponent {

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

    /// The surface the glyphs are smoothed against, stated the same way and for
    /// the same reason as the ink.
    ///
    /// Only its *polarity* against the ink is load-bearing, which is why this is
    /// one structural role rather than each row's exact fill: font smoothing's
    /// coverage measures identical against white and against any other light
    /// ground, and likewise on the dark side. What it must not get wrong is which
    /// side of the contrast the label sits on — dark ink on a light ground is
    /// dilated, light ink on a dark one is thinned, and applying the wrong one
    /// leaves the text visibly the wrong weight on a 1x display.
    private var groundProvider: () -> NSColor = { Design.Surface.background }

    /// `nil` follows the app setting. Previews can pin a style without changing
    /// the global preference before their selector action has committed it.
    public var morphStyleOverride: ChatNameMorphStyle? {
        didSet { applyEffect(morphingTo: stringValue) }
    }

    public var stringValue: String { label.text }

    public var font: NSFont {
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

    public var textColor: NSColor {
        get { label.textColor }
        set { setTextColor { newValue } }
    }

    public var alignment: NSTextAlignment {
        get { label.alignment }
        set { label.alignment = newValue }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        // This wrapper is a design-system control, so its hosts constrain it just as they do an
        // NSTextField. Leaving the autoresizing mask on minted a zero-height, leading-edge pair
        // of constraints when sidebar rows installed it, fighting the row's explicit centre and
        // trailing constraints on every layout pass.
        translatesAutoresizingMaskIntoConstraints = false
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

        // **From the leading edge, not centred in whatever slot the host gave us.** The package
        // defaults to `.center`, which suits the one large title its showcase demonstrates and
        // nothing here: every title this wraps is a name that follows an icon, and a name is read
        // from where it begins. Slots are wider than their line more often than they look — the
        // toolbar's page tab is held to a minimum width, a settings row stretches whichever view
        // hugs least, and a *truncated* line lands on a character boundary and so falls up to one
        // character short of the room it was offered. Centred, half of all that became a leading
        // indent that moved with the length of the name, and the other half a gap before whatever
        // followed the title: the tab strip's × stood 19pt off a title it was told to stand 10
        // from, and by a different amount on each tab.
        label.alignment = .left
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
        applyEffect(morphingTo: stringValue)

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.refreshTextColor()
        }
    }

    public override var intrinsicContentSize: NSSize {
        label.intrinsicContentSize
    }

    /// How wide the line will be **once drawn** in a slot `available` points wide: the whole
    /// title, or the ellipsized head it truncates to.
    ///
    /// `intrinsicContentSize` answers what the title wants, which is the right answer for a host
    /// that grows to fit one. A host with a *cap* needs this one instead: truncation lands on a
    /// character boundary, so the line that arrives is up to a character narrower than the slot,
    /// and a host that sizes to the slot holds that difference as space it never chose.
    public func width(fitting available: CGFloat) -> CGFloat {
        label.width(fitting: available)
    }

    /// How wide this label *would* be holding `candidate`, in the font it is set in now.
    ///
    /// `intrinsicContentSize` answers for the title it holds. A host that has to settle its
    /// geometry before starting a morph — `MorphingMultilineTitleLabel`, whose lines share one
    /// width and must not resize under their own glyphs — asks about the title to come.
    public func naturalWidth(of candidate: String) -> CGFloat {
        label.naturalWidth(of: candidate)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTextColor()
    }

    public override func accessibilityValue() -> Any? {
        stringValue
    }

    /// Updates the title. Callers decide whether this is a rename worth
    /// animating or merely a reused/configured view that should land directly.
    public func setStringValue(_ value: String, animated: Bool) {
        let shouldAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Only a morph reads the effect, and a sidebar of these is reconfigured constantly
        // while an agent works — so the setting is not consulted on every pass.
        if shouldAnimate {
            applyEffect(morphingTo: value)
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
    public func morphSettleDuration(to value: String) -> TimeInterval {
        guard !Design.Motion.reducesMotion, let preset = currentPreset else { return 0 }
        let characters = max(stringValue.count, value.count)
        let timing = Self.timing(for: preset, characters: characters)
        return timing.duration + timing.stagger * Double(max(0, characters - 1))
    }

    /// States the ink as a rule to be re-asked, rather than a colour to be kept.
    ///
    /// Use this wherever the answer depends on something that moves — the row's selection
    /// or dormancy, the app theme — so a change re-resolves rather than leaving the glyphs
    /// holding the colour they were built with.
    public func setTextColor(_ provider: @escaping () -> NSColor) {
        inkProvider = provider
        refreshTextColor()
    }

    /// Returns to the design-system label colour after a caller-specific ink
    /// (such as the toolbar backdrop's contrast colour) is no longer needed.
    public func useAutomaticTextColor() {
        setTextColor { Design.Text.label }
    }

    /// States the surface behind the glyphs, for a caller whose ground is not the
    /// app's structural one — a label over a filled banner or a coloured chip.
    public func setRasterizationGround(_ provider: @escaping () -> NSColor) {
        groundProvider = provider
        refreshTextColor()
    }

    /// Re-asks both providers, for a caller whose own state has just moved.
    public func refreshTextColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            label.textColor = inkProvider()
            label.rasterizationBackground = groundProvider()
        }
    }

    private var currentPreset: MorphPreset? {
        let style = morphStyleOverride ?? DesignSettings.current.chatNameMorphStyle
        return MorphPreset(rawValue: style.rawValue)
    }

    private func applyEffect(morphingTo value: String) {
        guard let preset = currentPreset else { return }

        label.effect = preset.makeEffect(intensity: Defaults.intensity)
        label.timing = Self.timing(for: preset,
                                   characters: max(stringValue.count, value.count))
    }

    /// The preset's recommended timing brought to this app's tempo, for a line `characters` long.
    ///
    /// Two adjustments, and the second is the one that matters. The package recommends a
    /// duration that shows an effect off; `Design.Motion.nameMorphTempo` scales it to the tempo
    /// the rest of the app moves at. The stagger is then held to a *total* rather than a step,
    /// because a per-character delay is multiplied by the name: at the default preset's 45ms
    /// every session title long enough to be a sentence took over a second and a half to
    /// settle, and the cascade — not the character animation — was nearly all of it. Below the
    /// budget a short name still cascades exactly as the preset asked.
    private static func timing(for preset: MorphPreset, characters: Int) -> MorphTiming {
        var timing = preset.recommendedTiming
        timing.duration *= Design.Motion.nameMorphTempo
        let steps = Double(max(1, characters - 1))
        timing.stagger = min(timing.stagger * Design.Motion.nameMorphTempo,
                             Design.Motion.nameMorphCascade / steps)
        return timing
    }
}
