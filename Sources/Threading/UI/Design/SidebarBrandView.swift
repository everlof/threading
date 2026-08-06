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
/// One accessibility element. The mark is decorative and says so; the row reads as static
/// text carrying the brand's name — the app's own when the theme hides the wordmark, because
/// hiding the *drawn* name does not change what the row is.
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
    private let stack = NSStackView()
    private let appEvents = AppEventObservations()
    private var pointerTracking: NSTrackingArea?

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
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            mark.widthAnchor.constraint(equalToConstant: Layout.logoSide),
            mark.heightAnchor.constraint(equalToConstant: Layout.logoSide),
            customLogo.widthAnchor.constraint(equalToConstant: Layout.logoSide),
            customLogo.heightAnchor.constraint(equalToConstant: Layout.logoSide)
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
        mark.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        mark.setHovered(false)
    }

    /// The press turns the mark and does nothing else. The brand is a signature, not a control:
    /// it names the window rather than opening anything, and a logo that acknowledges being
    /// pressed is the whole of what was asked of it.
    override func mouseDown(with event: NSEvent) {
        mark.playPress()
    }

    // MARK: - Public Methods

    /// The launch flourish: the mark stitches itself in while the wordmark fades up under it.
    /// One-shot, host-invoked, and a no-op under Reduce Motion — the reduced launch is the
    /// finished row simply being there.
    func playLaunchAnimation() {
        guard !Design.Motion.reducesMotion else { return }

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
    }
}
