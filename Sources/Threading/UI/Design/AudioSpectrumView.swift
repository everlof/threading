import AppKit

/// Eight measured frequency bands. The host owns capture, motion/visibility gates and bounds;
/// a theme chooses this presentation without gaining source or recording authority.
@MainActor
final class AudioSpectrumView: NSView, ThemedComponent, ThemeParticleHolding {
    private let demand: AudioSpectrumDemand
    private let service: AudioSpectrumService
    private let appEvents = AppEventObservations()
    private var spectrum: AudioSpectrum?
    private var frozen = false
    private var viewportObserver: AudioSpectrumViewportObserver?

    init(service: AudioSpectrumService = .shared) {
        self.service = service
        demand = AudioSpectrumDemand(service: service)
        spectrum = service.reading()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.string("Audio spectrum"))
        applySurface(fill: Design.Surface.field, radius: .control,
                     border: Design.Surface.border, bevel: .sunken)
        appEvents.observe(AudioSpectrumDidChange.self) { [weak self] event in
            guard let self, !self.frozen else { return }
            self.spectrum = event.spectrum
            if ThemeParticleHold.isSeen(self), AudioSpectrumViewportObserver.intersectsViewport(self) {
                self.needsDisplay = true
            }
        }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.needsDisplay = true }
        ThemeParticleHold.shared.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { Design.AudioSpectrum.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewportObserver = AudioSpectrumViewportObserver(view: self) { [weak self] in
            self?.refreshParticleMotion()
        }
        refreshParticleMotion()
    }
    override func viewDidHide() { super.viewDidHide(); refreshParticleMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshParticleMotion() }
    override func layout() { super.layout(); refreshParticleMotion() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func setPresented(_ presented: Bool) {
        isHidden = !presented
        refreshParticleMotion()
    }

    func refreshParticleMotion() {
        demand.setActive(!frozen && window != nil && !isHiddenOrHasHiddenAncestor
                         && ThemeParticleHold.motionAllowed && ThemeParticleHold.isSeen(self)
                         && AudioSpectrumViewportObserver.intersectsViewport(self))
        if !frozen, !ThemeParticleHold.motionAllowed { spectrum = nil }
        needsDisplay = true
    }

    override func accessibilityValue() -> Any? {
        guard let reading = frozen ? spectrum : service.reading() else {
            return L10n.string("Audio unavailable")
        }
        return L10n.format("Audio level %lld percent", Int64((reading.level * 100).rounded()))
    }

    /// Holds a genuine snapshot through the shipping view for deterministic rendered evidence.
    func freezePresentationForTesting(_ spectrum: AudioSpectrum?) {
        frozen = true
        self.spectrum = spectrum
        refreshParticleMotion()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let metrics = Design.AudioSpectrum.self
        let rect = bounds.insetBy(dx: metrics.inset, dy: metrics.inset)
        let width = (rect.width - metrics.bandGap * CGFloat(AudioSpectrum.bandCount - 1))
            / CGFloat(AudioSpectrum.bandCount)
        let height = (rect.height - metrics.cellGap * CGFloat(metrics.cellCount - 1))
            / CGFloat(metrics.cellCount)
        guard width > 0, height > 0 else { return }
        let bands = frozen ? spectrum?.bands : (ThemeParticleHold.motionAllowed ? service.reading()?.bands : nil)
        for band in 0..<AudioSpectrum.bandCount {
            // Drawn through the person's Reaction strength, like every music-driven decoration.
            let level = ThemeReactions.scaled(bands?[band] ?? 0)
            let count = Int((level * Double(metrics.cellCount)).rounded())
            for cell in 0..<metrics.cellCount {
                (cell < count ? Design.Surface.accent : Design.Surface.border).setFill()
                NSRect(x: rect.minX + CGFloat(band) * (width + metrics.bandGap),
                       y: rect.minY + CGFloat(cell) * (height + metrics.cellGap),
                       width: width, height: height).fill()
            }
        }
    }
}
