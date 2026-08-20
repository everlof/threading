import AppKit

// MARK: - Sidebar Brand View

/// The brand row at the sidebar's top: the Threading mark beside the app's name — unless the
/// current theme's `SidebarStyle.Brand` says otherwise, in which case it is whatever that
/// says: another logo, another name, another face, or a logo standing alone.
///
/// Self-wired to `AppThemeDidChange` the way `SidebarBackdropView` is, and for the same
/// reason: a brand row still wearing the previous chrome's wordmark is invisible from every
/// call site. The wordmark is a `MorphingTitleLabel`, so a theme switch that renames the row
/// morphs it — the same character-by-character transition every session title makes, which is
/// what makes changing chromes feel like the app changing clothes rather than flickering.
///
/// A spectrum material replaces those identity pixels with the app-wide workload analyzer. The
/// selection is thematic, but the facts remain host-owned: exact working count, recent semantic
/// activity, and whether any worker is at the top of its provider's effort ladder.
///
/// One accessibility element. Every child is decorative; the row reads as the brand in ordinary
/// materials and states the workload in a spectrum material.
final class SidebarBrandView: NSView, ThemedComponent {

    // MARK: - Properties

    private enum Layout {
        /// The logo slot, sized to the band it lives in.
        ///
        /// 24 rather than 20: the mark is six strands and a hexagonal rim inside its own box,
        /// so it carries more detail per point than an SF Symbol does, and at 20 its strokes
        /// came out barely a point wide — thin enough that the whole thing read as soft even
        /// once it was rasterising at the right scale. Four points is the difference between
        /// a logo and a smudge, and the band has the room.
        static let logoSide: CGFloat = 24
    }

    /// Weave is the compact treatment: its dots stay on the actual shield and thread paths,
    /// so the 24pt mark remains recognisable while the whole row is under the pointer.
    private let mark = ThreadingMarkView(particleMotion: .weave)
    /// A theme-supplied logo. Frameless and content-only — structural AppKit.
    private let customLogo = NSImageView()
    private let wordmark = MorphingTitleLabel()
    private let workloadAnalyzer = AgentWorkloadAnalyzerView()
    private let stack = NSStackView()
    private let appEvents = AppEventObservations()
    private var pointerTracking: NSTrackingArea?
    private var workloadIntensity = AgentWorkloadMonitor.shared.intensity

    /// What the row currently shows, kept so a theme change that moves nothing skips the
    /// morph — `AppThemeDidChange` also fires for font-override sweeps, and a wordmark that
    /// re-morphs its own unchanged name on those reads as a tic.
    private var shownTitle: String?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        customLogo.imageScaling = .scaleProportionallyUpOrDown
        customLogo.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(mark)
        stack.addArrangedSubview(customLogo)
        stack.addArrangedSubview(wordmark)
        stack.addArrangedSubview(workloadAnalyzer)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            mark.widthAnchor.constraint(equalToConstant: Layout.logoSide),
            mark.heightAnchor.constraint(equalToConstant: Layout.logoSide),
            customLogo.widthAnchor.constraint(equalToConstant: Layout.logoSide),
            customLogo.heightAnchor.constraint(equalToConstant: Layout.logoSide),
            workloadAnalyzer.widthAnchor.constraint(equalToConstant: Design.WorkloadAnalyzer.size.width),
            workloadAnalyzer.heightAnchor.constraint(equalToConstant: Design.WorkloadAnalyzer.size.height)
        ])

        mark.setAccessibilityElement(false)
        customLogo.setAccessibilityElement(false)
        wordmark.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)

        configure(animated: false)

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.configure(animated: true)
        }
        appEvents.observe(AgentIntensityDidChange.self) { [weak self] event in
            guard let self else { return }
            self.workloadIntensity = event.intensity
            self.updateAccessibility()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // An adaptive theme may state different brands per appearance; a light/dark flip is
        // a brand change the theme notification never fires for.
        configure(animated: false)
    }

    // MARK: - Pointer

    /// The whole row is the target, not the logo alone: a 24pt mark is a hard thing to put a
    /// pointer on deliberately, and the name beside it is part of the same signature. The
    /// tracking area is rebuilt on every layout because the row's width follows the sidebar's.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking {
            removeTrackingArea(pointerTracking)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        guard workloadAnalyzer.isHidden else { return }
        mark.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard workloadAnalyzer.isHidden else { return }
        mark.setHovered(false)
    }

    /// The press turns the mark and does nothing else. The brand is a signature, not a control:
    /// it names the window rather than opening anything, and a logo that acknowledges being
    /// pressed is the whole of what was asked of it.
    override func mouseDown(with event: NSEvent) {
        guard workloadAnalyzer.isHidden else { return }
        mark.playPress()
    }

    // MARK: - Public Methods

    /// A stable held-hover frame for the product-shell evidence catalogue. Pointer interaction
    /// still owns production state; this only lets a render show the real 24pt mark after its
    /// dwell without racing Core Animation's clock.
    func setHoverPresentation(weavePhase: CGFloat, heldHoverPhase: CGFloat) {
        mark.setParticlePresentation(
            phase: weavePhase,
            heldHoverPhase: heldHoverPhase
        )
    }

    /// The launch flourish: the mark stitches itself in while the wordmark fades up under it.
    /// One-shot, host-invoked, and a no-op under Reduce Motion — the reduced launch is the
    /// finished row simply being there.
    func playLaunchAnimation() {
        guard workloadAnalyzer.isHidden, !Design.Motion.reducesMotion else { return }

        mark.playDrawIn()

        wordmark.alphaValue = 0
        let delay = Design.Motion.brandOutlineDraw * 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Design.Motion.brandStrandDraw
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.wordmark.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Private Methods

    private func configure(animated: Bool) {
        let brand = SidebarAppearance.brand(for: effectiveAppearance)
        let showsWorkloadAnalyzer = Design.Chart.style == .spectrum

        workloadAnalyzer.setPresented(showsWorkloadAnalyzer)

        if showsWorkloadAnalyzer {
            mark.isHidden = true
            mark.setHovered(false)
            customLogo.isHidden = true
            customLogo.image = nil
            wordmark.isHidden = true
            updateAccessibility()
            return
        }

        switch brand.logo {
        case .mark:
            mark.isHidden = false
            customLogo.isHidden = true
            customLogo.image = nil
        case .image(let image):
            mark.isHidden = true
            customLogo.isHidden = false
            customLogo.image = image
        case .hidden:
            mark.isHidden = true
            customLogo.isHidden = true
            customLogo.image = nil
        }

        wordmark.isHidden = brand.title == nil
        wordmark.applyFont(brand.titleRole)
        if let title = brand.title, title != shownTitle {
            wordmark.setStringValue(title, animated: animated && shownTitle != nil)
        }
        shownTitle = brand.title

        // The row is the brand whichever parts of it are drawn.
        setAccessibilityLabel(brand.title ?? AppInfo.name)
        setAccessibilityValue(nil)
        toolTip = nil
    }

    private func updateAccessibility() {
        guard Design.Chart.style == .spectrum else { return }

        let count = workloadIntensity.workload.workingCount
        let countSummary: String
        switch count {
        case 0:
            countSummary = L10n.string("No agents working")
        case 1:
            countSummary = L10n.string("One agent working")
        default:
            countSummary = L10n.format("%lld agents working", Int64(count))
        }
        let summary = workloadIntensity.workload.anyAtTopEffort
            ? L10n.format("%@, top effort active", countSummary)
            : countSummary

        setAccessibilityLabel(AppInfo.name)
        setAccessibilityValue(summary)
        toolTip = summary
    }
}
