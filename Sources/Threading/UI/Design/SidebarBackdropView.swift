import AppKit

/// The sidebar's ground: the platform's own sidebar material under the identity theme, an
/// opaque themed surface under a style — and, when the style says so, that surface dressed
/// with a gradient and an image.
///
/// The material is what the sidebar *lost* when its split item stopped being
/// `sidebarWithViewController:` — that behaviour was declined for the floating inset panel it
/// forces on macOS 26, not for the material it drew, and the note that made the change
/// (the window controller's split-view setup) names the material as one of the two things
/// to be replaced by hand. This is that replacement. Under System the sidebar is again the
/// frosted column every platform app has, which is also what separates it from the content pane
/// beside it: the two system grounds are otherwise the same colour, and a window whose sidebar
/// and pane share one flat grey reads as a single undivided surface.
///
/// Under a styled theme the material would be exactly wrong — a style states its own surface,
/// and frost over it would sample the desktop through a palette the theme never chose — so the
/// component shows an opaque `ThemedSurfaceView` instead. Which of the two is showing is this
/// component's own decision, taken from the palette the way `Design.Radius.pill` and
/// `Design.Text.selected` already decide: feature code says only "this is the sidebar's ground"
/// and never `if`s on a theme's identity.
///
/// The dressing (`SidebarStyle.Background`, resolved through `SidebarAppearance`) sits in its
/// own layer-backed view above the fill: gradient first, image over it — a tiled pattern at
/// full strength, a picture usually washed well below it. Both are `CGColor`/`contents`
/// territory and therefore frozen, so `apply()` restates them on every theme change and on
/// every effective-appearance flip, the same discipline `ThemedSpinner` keeps per redraw.
final class SidebarBackdropView: NSView, ThemedComponent, SystemChromeBoundary {

    private let material = NSVisualEffectView()
    private let fill = ThemedSurfaceView()
    /// Structural host for the two decoration layers, kept as a view so it stacks between the
    /// fill and the content the ordinary way.
    private let decor = NSView()
    private let gradientLayer = CAGradientLayer()
    private let imageLayer = CALayer()
    /// A fill or fit picture placed by its alignment inside `imageLayer`, which clips it — how
    /// an illustration stands on the column's foot at any window height.
    private let alignedImage = ThemeAlignedPictureLayer()
    private var motionView: ThemeBackdropMotionView?
    /// The theme's ambient particles over both — bubbles rising through the column.
    private let particleField = ThemeParticleFieldLayer()
    private let appEvents = AppEventObservations()

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)
        addSubview(fill)

        decor.translatesAutoresizingMaskIntoConstraints = false
        decor.wantsLayer = true
        gradientLayer.type = .axial
        decor.layer?.addSublayer(gradientLayer)
        imageLayer.masksToBounds = true
        imageLayer.addSublayer(alignedImage)
        decor.layer?.addSublayer(imageLayer)
        decor.layer?.addSublayer(particleField)
        addSubview(decor)

        for pane in [material, fill, decor] {
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: topAnchor),
                pane.bottomAnchor.constraint(equalTo: bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }

        apply()

        // Self-wired rather than left to the host: a ground that keeps the previous theme's
        // answer is invisible from every call site, which is the trap `BackdropOverlay` closes
        // the same way.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.apply() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = decor.bounds
        imageLayer.frame = decor.bounds
        alignedImage.place(in: imageLayer.bounds)
        particleField.frame = decor.bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A field decides whether it moves from its window; a move is a new answer.
        particleField.refresh()
    }

    /// The field, for a test asking which state it is in.
    var particles: ThemeParticleFieldLayer { particleField }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // An adaptive theme states its dressing per variant, and a system light/dark flip is
        // a variant change no theme notification fires for.
        apply()
    }

    // MARK: - Appearance

    /// Shows the ground the current theme calls for.
    private func apply() {
        let isSystem = AppThemePalette.current.isSystem
        material.isHidden = !isSystem
        fill.isHidden = isSystem
        if !isSystem {
            // A region ground is neither a plate nor a well. The project tree may state its
            // own edge through `SidebarStyle.navigatorWell`; raising the whole sidebar made
            // the Windows 98 column look like one giant button.
            fill.applySurface(
                fill: Design.Surface.background,
                radius: .fixed(0),
                bevel: .none
            )
        }

        let background = isSystem ? nil : SidebarAppearance.background(for: effectiveAppearance)
        decor.isHidden = background == nil
        applyGradient(background?.gradient)
        applyImage(background?.image)
        particleField.apply(background?.particles, host: self)
    }

    private func applyGradient(_ gradient: SidebarAppearance.Background.Gradient?) {
        guard let gradient else {
            motionView?.stop()
            motionView = nil
            gradientLayer.isHidden = true
            return
        }
        gradientLayer.isHidden = false
        // Frozen colours restated on every apply — never trusted to outlive a theme switch.
        gradientLayer.colors = gradient.colors.map(\.cgColor)
        gradientLayer.locations = gradient.locations.map { NSNumber(value: Double($0)) }

        // CSS angles: 0° flows toward the top, 90° toward the right. The layer's unit space
        // has its origin at the bottom-left here, so "toward the top" is +y.
        let radians = gradient.angleDegrees * .pi / 180
        let direction = CGPoint(x: sin(radians) / 2, y: cos(radians) / 2)
        gradientLayer.startPoint = CGPoint(x: 0.5 - direction.x, y: 0.5 - direction.y)
        gradientLayer.endPoint = CGPoint(x: 0.5 + direction.x, y: 0.5 + direction.y)
        if let drift = gradient.drift, drift.isValid {
            let observer = motionView ?? ThemeBackdropMotionView(gradient: gradientLayer)
            if observer.superview !== decor { decor.addSubview(observer) }
            motionView = observer
            observer.configure(angleDegrees: Double(gradient.angleDegrees), drift: drift)
        } else {
            motionView?.stop()
            motionView = nil
        }
    }

    private func applyImage(_ layer: SidebarAppearance.Background.ImageLayer?) {
        guard let layer else {
            imageLayer.isHidden = true
            imageLayer.contents = nil
            imageLayer.backgroundColor = nil
            alignedImage.show(nil, mode: .tile, alignment: .center)
            return
        }
        imageLayer.isHidden = false
        imageLayer.opacity = Float(layer.opacity)
        imageLayer.contents = nil
        alignedImage.contentsScale = window?.backingScaleFactor ?? 2

        switch layer.mode {
        case .tile:
            // A pattern colour is how Core Animation tiles at the image's own size; restated
            // per apply like every other frozen colour.
            alignedImage.show(nil, mode: .tile, alignment: layer.alignment)
            imageLayer.backgroundColor = NSColor(patternImage: layer.image).cgColor
        case .fill, .fit:
            imageLayer.backgroundColor = nil
            alignedImage.show(layer.image, mode: layer.mode, alignment: layer.alignment)
            needsLayout = true
        }
    }

    // MARK: - SystemChromeBoundary

    /// Only the effect view this component itself installed, and whatever AppKit expands
    /// inside it — a raw effect view *beside* it stays a violation.
    func permitsSystemChrome(_ view: NSView) -> Bool {
        view === material || view.isDescendant(of: material)
    }
}
