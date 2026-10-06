import AppKit
import ThreadingRemoteKit

/// Fixed-size, host-owned authoring controls. A drag changes the in-memory presentation only;
/// the released value crosses the same validator/store boundary as an MCP update.
///
/// **A drag owns one theme's stored document from its first tick to its release.** The document
/// is recorded when the preview starts; each later tick builds on the preview, and the release
/// saves it only while that preview is still the theme in force and the stored document is still
/// the one recorded. Anything else that moves the theme meanwhile — `set_app_theme`, an MCP
/// update, a theme command — wins: the rest of the drag does nothing rather than writing into whatever
/// theme happens to be current by then. Unrelated events (another theme's library edit, an
/// appearance-activation refresh) leave the drag alone.
@MainActor
final class CurrentThemeTuningControls: NSObject {
    enum Knob: String, CaseIterable {
        case density, speed, opacity, driftDuration, pictureOpacity, glowRadius, glowOpacity
        case panelRadius, controlRadius

        var title: String {
            switch self {
            case .density: "Particle density"
            case .speed: "Particle speed"
            case .opacity: "Particle opacity"
            case .driftDuration: "Gradient cycle"
            case .pictureOpacity: "Picture opacity"
            case .glowRadius: "Terminal glow radius"
            case .glowOpacity: "Terminal glow opacity"
            case .panelRadius: "Panel corner radius"
            case .controlRadius: "Control corner radius"
            }
        }

        /// The validator's bounds — or, for an ambient particle field, the renderer's ceiling
        /// beneath them, so no stretch of the track moves nothing on screen.
        var range: ClosedRange<Double> {
            switch self {
            case .density: ThemeParticleLimits.densityRange
            case .speed: ThemeParticleLimits.speedRange
            case .opacity: ThemeParticleLimits.opacityRange.lowerBound...ThemeParticleLimits.ambientOpacityCeiling
            case .pictureOpacity: AppThemeMaterialLimits.imageOpacityRange
            case .driftDuration: ThemeGradientDrift.durationRange
            case .glowRadius: Self.points(TerminalGlow.radiusRange)
            case .glowOpacity: TerminalGlow.opacityRange
            case .panelRadius: Self.points(AppThemeMaterialLimits.panelRadiusRange)
            case .controlRadius: Self.points(AppThemeMaterialLimits.controlRadiusRange)
            }
        }

        private static func points(_ range: ClosedRange<CGFloat>) -> ClosedRange<Double> {
            Double(range.lowerBound)...Double(range.upperBound)
        }

        var reading: Reading {
            switch self {
            case .density, .opacity, .pictureOpacity, .glowOpacity: .percent
            case .speed: .multiplier
            case .driftDuration: .seconds
            case .glowRadius, .panelRadius, .controlRadius: .points
            }
        }

        /// A hard bevel is rectilinear: the validator refuses any corner but zero beneath one.
        var isCornerRadius: Bool { self == .panelRadius || self == .controlRadius }

        /// A picture or a full-colour sprite under text: a released change is worth sampling.
        var affectsImageLegibility: Bool { self == .opacity || self == .pictureOpacity }

        /// What a tick of this knob has to repaint. Glow lives in the terminal profile, which
        /// terminals re-read from their own observers; everything else is a recorded surface.
        var previewScope: AppThemeLibrary.LivePreviewScope {
            self == .glowRadius || self == .glowOpacity ? .terminalPalette : .everything
        }

        func value(in variant: AppTheme.Variant) -> Double? {
            switch self {
            case .density: variant.material.backdrop?.particles?.density
            case .speed: variant.material.backdrop?.particles?.speed
            case .opacity: variant.material.backdrop?.particles?.opacity
            case .driftDuration: variant.material.backdrop?.gradient?.drift?.duration
            case .pictureOpacity: variant.material.backdrop?.image?.opacity
            case .glowRadius: variant.terminalPalette.glow.map { Double($0.radius) }
            case .glowOpacity: variant.terminalPalette.glow?.opacity
            case .panelRadius: Double(variant.material.panelRadius)
            case .controlRadius: Double(variant.material.controlRadius)
            }
        }

        func applying(_ value: Double, to variant: AppTheme.Variant) -> AppTheme.Variant {
            var material = variant.material
            var terminal = variant.terminalPalette
            switch self {
            case .density: material.backdrop?.particles?.density = value
            case .speed: material.backdrop?.particles?.speed = value
            case .opacity: material.backdrop?.particles?.opacity = value
            case .driftDuration:
                let distance = material.backdrop?.gradient?.drift?.distance ?? ThemeGradientDrift.defaultDistance
                material.backdrop?.gradient?.drift = ThemeGradientDrift(duration: value,
                    distance: distance)
            case .pictureOpacity: material.backdrop?.image?.opacity = value
            case .glowRadius: terminal.glow?.radius = CGFloat(value)
            case .glowOpacity: terminal.glow?.opacity = value
            case .panelRadius: material.panelRadius = CGFloat(value)
            case .controlRadius: material.controlRadius = CGFloat(value)
            }
            return variant.replacing(terminalPalette: terminal, material: material)
        }
    }

    /// How a knob's value is written beside its track and spoken by VoiceOver: in its own unit,
    /// with the person's decimal separator — never `%g`, which wrote 120 seconds as "1.2e+02".
    enum Reading {
        case percent, multiplier, seconds, points

        func text(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
            switch self {
            case .percent: Self.percent(value, locale: locale)
            case .multiplier: L10n.format("%@×", Self.number(value, digits: 2, locale: locale), locale: locale)
            case .seconds: Self.seconds(value, width: .abbreviated, locale: locale)
            case .points: L10n.format("%@ pt", Self.number(value, digits: 1, locale: locale), locale: locale)
            }
        }

        func spoken(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
            switch self {
            case .percent: Self.percent(value, locale: locale)
            case .multiplier: L10n.format("%@ times", Self.number(value, digits: 2, locale: locale), locale: locale)
            case .seconds: Self.seconds(value, width: .wide, locale: locale)
            case .points: L10n.format("%@ points", Self.number(value, digits: 1, locale: locale), locale: locale)
            }
        }

        private static func number(_ value: Double, digits: Int, locale: Locale) -> String {
            value.formatted(.number.precision(.fractionLength(0...digits)).locale(locale))
        }

        private static func percent(_ value: Double, locale: Locale) -> String {
            value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        }

        private static func seconds(
            _ value: Double,
            width: Measurement<UnitDuration>.FormatStyle.UnitWidth,
            locale: Locale
        ) -> String {
            Measurement(value: value, unit: UnitDuration.seconds).formatted(
                .measurement(width: width, usage: .asProvided,
                             numberFormatStyle: .number.precision(.fractionLength(0)))
                    .locale(locale)
            )
        }
    }

    /// One preview in flight: the stored document it started from and what is on screen.
    private struct Drag {
        let base: AppTheme
        var pending: AppTheme
        var touchesLegibility: Bool
    }

    var onError: ((String) -> Void)?
    /// A sampled-legibility advisory for the tuned variant after a released opacity change;
    /// an empty string withdraws the previous one.
    var onAdvisory: ((String) -> Void)?
    private var theme: AppTheme?
    private var kind: AppTheme.VariantKind = .light
    private var drag: Drag?
    /// Set when another owner took the theme mid-drag; cleared by the release.
    private var refusesUntilRelease = false
    private var advisoryGeneration = 0
    /// A scramble alphabet survives a trip through another style while this page lives.
    private var setAsideAlphabets: [String: String] = [:]
    private var sliders: [Knob: ThemedScrubber] = [:]
    private var readings: [Knob: NSTextField] = [:]
    private var readingWidths: [NSLayoutConstraint] = []
    private let drift = ThemedToggle()
    private let glow = ThemedToggle()
    private let tinted = ThemedToggle()
    private let morph = ThemedPopUp()
    private let styles = ChatNameMorphStyle.allCases.filter { $0 != .automatic }
    private static let sliderWidth: CGFloat = 140
    private static let readingWidth: CGFloat = 44
    /// Fractions of each track whose readings are measured for the numeric column's width.
    private static let measuredFractions: [Double] = [0, 0.55, 1]

    /// Whether an unsaved preview is on screen. The paired phone and anything else that should
    /// not run per tick reads `AppThemeDidChange.isLivePreview` instead.
    var hasPreviewInFlight: Bool { drag != nil }

    func section() -> NSView {
        let rows = Knob.allCases.map { knob in
            let slider = ThemedScrubber(frame: .zero)
            slider.widthAnchor.constraint(equalToConstant: Self.sliderWidth).isActive = true
            slider.setAccessibilityIdentifier("current-theme.tune.\(knob.rawValue)")
            slider.setAccessibilityLabel(L10n.string(knob.title))
            slider.onChange = { [weak self] fraction in self?.preview(knob, fraction: fraction) }
            slider.onScrubEnd = { [weak self] _ in self?.commit() }
            let reading = SettingsUI.note("", localizes: false)
            // A wrapping note has no intrinsic width. Bound the numeric column so the
            // trailing control group can hug its contents and all nine tracks align.
            let width = reading.widthAnchor.constraint(equalToConstant: Self.readingWidth)
            width.isActive = true
            readingWidths.append(width)
            reading.maximumNumberOfLines = 1
            reading.setAccessibilityElement(false)
            reading.setAccessibilityIdentifier("current-theme.tune.\(knob.rawValue).reading")
            sliders[knob] = slider
            readings[knob] = reading
            return SettingsUI.row(title: knob.title, control: SettingsUI.controlGroup([slider, reading]))
        }
        drift.target = self; drift.action = #selector(driftChanged)
        glow.target = self; glow.action = #selector(glowChanged)
        tinted.target = self; tinted.action = #selector(tintedChanged)
        for style in styles { morph.addItem(ThemedMenuItem(title: style.displayName, representedValue: style)) }
        morph.target = self; morph.action = #selector(morphChanged)
        drift.setAccessibilityIdentifier("current-theme.tune.drift")
        glow.setAccessibilityIdentifier("current-theme.tune.glow")
        tinted.setAccessibilityIdentifier("current-theme.tune.tinted")
        morph.setAccessibilityIdentifier("current-theme.tune.morph")
        return SettingsUI.section("Tune", SettingsCard(rows: [
            SettingsUI.row(title: "Gradient drift", control: drift),
            SettingsUI.row(title: "Terminal glow", control: glow),
            SettingsUI.row(title: "Tint identity marks", control: tinted),
            SettingsUI.row(title: "Title morph", control: morph)
        ] + rows))
    }

    func show(_ theme: AppTheme, kind: AppTheme.VariantKind) {
        guard !AppThemeLibrary.isPublishingLivePreview else { return }
        if let drag {
            if Self.owns(drag) {
                if drag.base.id == theme.id, kind == self.kind {
                    // Something else changed — another theme, an activation refresh — and the
                    // preview is still the one on screen. Keep the drag.
                    refresh()
                    return
                }
                // The page is leaving a preview it still owns (the appearance flipped and took
                // the inspected variant with it): save it as the release would have.
                commit()
            } else {
                // Another owner moved the theme in force or replaced the stored document. What
                // is on screen is theirs now.
                self.drag = nil
            }
            // Either way the rest of this pointer drag must not start writing somewhere else.
            refusesUntilRelease = true
        }
        // The document `update` stored, not a value that happens to be on screen: during a
        // drag `AppThemeLibrary.current` is the unsaved preview.
        self.theme = Self.stored(theme.id) ?? theme
        self.kind = kind
        measureReadingColumn()
        refresh()
    }

    func preview(_ knob: Knob, fraction: Double) {
        guard fraction.isFinite else { return }
        let range = knob.range
        let value = range.lowerBound + min(max(fraction, 0), 1) * (range.upperBound - range.lowerBound)
        change(touchesLegibility: knob.affectsImageLegibility, scope: knob.previewScope) {
            knob.applying(value, to: $0)
        }
    }

    /// The release: save the preview once, or settle the window back on the stored document.
    func commit() {
        refusesUntilRelease = false
        guard let drag else { return }
        self.drag = nil
        guard Self.owns(drag) else {
            refresh()
            return
        }
        guard drag.pending != drag.base else {
            // Dragged back to where it started. Nothing to save, but the ticks still need their
            // settle so an observer waiting out the preview hears the durable value.
            AppThemeLibrary.installResolved(drag.base)
            refresh()
            return
        }
        do {
            try AppThemeLibrary.update(drag.pending)
            theme = drag.pending
            if drag.touchesLegibility { checkLegibility(of: drag.pending, kind: kind) }
        } catch {
            AppThemeLibrary.installResolved(drag.base)
            onError?(error.localizedDescription)
        }
        refresh()
    }

    // MARK: - Private Methods

    private static func stored(_ id: AppThemeID) -> AppTheme? {
        AppThemeLibrary.custom.first { $0.id == id }
    }

    /// The drag's preview is still in force over the document it started from.
    private static func owns(_ drag: Drag) -> Bool {
        AppThemeLibrary.current == drag.pending && stored(drag.base.id) == drag.base
    }

    private func change(touchesLegibility: Bool = false,
                        scope: AppThemeLibrary.LivePreviewScope = .everything,
                        _ transform: (AppTheme.Variant) -> AppTheme.Variant) {
        guard !refusesUntilRelease, let theme, AppThemeLibrary.isCustom(theme) else { return }
        let base: AppTheme
        let source: AppTheme
        if let drag {
            guard Self.owns(drag) else {
                // Superseded without a reload reaching this page first.
                self.drag = nil
                refusesUntilRelease = true
                refresh()
                return
            }
            base = drag.base
            source = drag.pending
        } else {
            guard AppThemeLibrary.current.id == theme.id, let stored = Self.stored(theme.id) else { return }
            base = stored
            source = stored
        }
        guard let variant = source.variant(kind) else { return }
        var variants = source.variants
        variants[kind] = transform(variant)
        do {
            let updated = try AppThemeEditing.assemble(id: base.id, name: base.name,
                mode: base.mode, summary: base.summary, variants: variants)
            drag = Drag(base: base, pending: updated,
                        touchesLegibility: (drag?.touchesLegibility ?? false) || touchesLegibility)
            // These controls cannot change asset or font references; no inventory scan is
            // needed at pointer cadence. The committed update prepares resources normally.
            AppThemeLibrary.installLivePreview(updated, scope: scope)
            refresh()
        } catch { onError?(error.localizedDescription); refresh() }
    }

    private func refresh() {
        guard let theme, let variant = (drag?.pending ?? theme).variant(kind) else {
            for slider in sliders.values { slider.isEnabled = false }
            for reading in readings.values { reading.stringValue = "—" }
            drift.isEnabled = false; glow.isEnabled = false; tinted.isEnabled = false
            morph.isEnabled = false
            return
        }
        let editable = AppThemeLibrary.isCustom(theme)
        let squareCorners = variant.material.bevel.map { $0.style != .soft } ?? false
        for knob in Knob.allCases {
            let value = knob.value(in: variant)
            sliders[knob]?.isEnabled = editable && value != nil && !(knob.isCornerRadius && squareCorners)
            if let value {
                let range = knob.range
                sliders[knob]?.value = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                sliders[knob]?.spokenValue = knob.reading.spoken(value)
                readings[knob]?.stringValue = knob.reading.text(value)
            } else {
                sliders[knob]?.spokenValue = nil
                readings[knob]?.stringValue = "—"
            }
        }
        drift.isEnabled = editable && variant.material.backdrop?.gradient != nil
        drift.state = variant.material.backdrop?.gradient?.drift == nil ? .off : .on
        glow.isEnabled = editable
        glow.state = variant.terminalPalette.glow == nil ? .off : .on
        tinted.isEnabled = editable
        tinted.state = variant.material.identityMarks == .tinted ? .on : .off
        morph.isEnabled = editable && variant.titleMorph != nil
        morph.selectItem(at: styles.firstIndex(of: variant.titleMorph?.style ?? .shapeMorph) ?? 0)
    }

    /// The numeric column fits the widest reading any knob can show in this locale and type.
    /// Measured on a theme event, not per tick: the theme's typeface is what can change it.
    private func measureReadingColumn() {
        let font = Design.Typography.subheading()
        var widest = Self.readingWidth
        for knob in Knob.allCases {
            let range = knob.range
            for fraction in Self.measuredFractions {
                let text = knob.reading.text(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
                widest = max(widest, ceil((text as NSString).size(withAttributes: [.font: font]).width))
            }
        }
        for width in readingWidths { width.constant = widest }
    }

    /// Off the main actor and after the release only: at most the tuned variant's backdrop
    /// picture and sprites, each sampled at 64×64.
    private func checkLegibility(of theme: AppTheme, kind: AppTheme.VariantKind) {
        advisoryGeneration &+= 1
        let generation = advisoryGeneration
        onAdvisory?("")
        Task { [weak self] in
            let findings = await ThemeImageLegibility.findings(for: theme, kinds: [kind])
            guard let self, generation == self.advisoryGeneration,
                  Self.stored(theme.id) == theme else { return }
            self.onAdvisory?(Self.advisory(findings))
        }
    }

    /// Only what Tune can fix: the pane backdrop's picture and its particles.
    static func advisory(_ findings: [ThemeImageLegibility.Finding]) -> String {
        findings.filter { $0.region == .backdrop }.map { finding in
            let ratio = finding.ratio.formatted(.number.precision(.fractionLength(1)))
            let opacity = finding.suggestedOpacity.formatted(.percent.precision(.fractionLength(0)))
            if let sprite = finding.sprite {
                return L10n.format(
                    "The “%@” particles leave text at %@:1 contrast in places. Try %@ opacity or less.",
                    sprite, ratio, opacity
                )
            }
            return L10n.format(
                "The backdrop picture leaves text at %@:1 contrast in places. Try %@ opacity or less.",
                ratio, opacity
            )
        }.joined(separator: "\n")
    }

    @objc private func driftChanged() {
        let enabled = drift.state == .on
        change { variant in
            var material = variant.material
            material.backdrop?.gradient?.drift = enabled ? ThemeGradientDrift() : nil
            return variant.replacing(material: material)
        }
        commit()
    }

    @objc private func glowChanged() {
        let enabled = glow.state == .on
        change { variant in
            var terminal = variant.terminalPalette
            terminal.glow = enabled ? .standard : nil
            return variant.replacing(terminalPalette: terminal)
        }
        commit()
    }

    @objc private func tintedChanged() {
        let enabled = tinted.state == .on
        change { variant in
            var material = variant.material
            material.identityMarks = enabled ? .tinted : .natural
            return variant.replacing(material: material)
        }
        commit()
    }

    @objc private func morphChanged() {
        guard let style = morph.selectedItem?.representedValue as? ChatNameMorphStyle,
              let theme else { return }
        let key = "\(theme.id.rawValue).\(kind.rawValue)"
        change { variant in
            var value = variant.titleMorph
            if style == .scramble {
                let alphabet = value?.characters ?? setAsideAlphabets[key]
                value?.characters = alphabet
            } else if let alphabet = value?.characters {
                // An alphabet only means something to a scramble, and the validator refuses one
                // on any other style; it waits here in case the person comes back to scramble.
                setAsideAlphabets[key] = alphabet
                value?.characters = nil
            }
            value?.style = style
            return variant.replacingTitleMorph(value)
        }
        commit()
    }
}
