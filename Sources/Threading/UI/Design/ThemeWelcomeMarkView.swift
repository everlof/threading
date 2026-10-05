import AppKit

// MARK: - Theme Welcome Mark View

/// What stands above the new-session composer's greeting: the Threading mark, or — when the
/// theme's welcome says so (`ThemeWelcome.Mark`) — the theme's own logo, its mascot, or nothing.
///
/// **Every mark is one the app already draws.** The app's is `ThreadingMarkView`, with its
/// draw-in; the logo is the sidebar brand's picture in a `ThemeLogoView` held at rest (the
/// beats it answers in the sidebar are pointer gestures, and nothing here is pointed at); the
/// mascot is `ThemeMascotView` fed from `AgentMoodMonitor` — the sidebar mascot's own mood source
/// and events — so the figure over the greeting is in the same mood as the one at the column's
/// foot. A logo or mascot the theme cannot draw falls back to the app's mark rather than leaving
/// a hole (`ThemeWelcomeAppearance.mark(for:)`).
///
/// **The box is the theme's to size.** `markSize` is the side, held to
/// `ThemeWelcomeLimits.markSides`; a mascot keeps its own proportions at that height. `hidden`
/// hides the view, so the hero's stack closes up around the greeting.
///
/// Self-wired: a theme switch, an appearance flip and every mood change reach it without the
/// host. Decorative — the greeting beside it carries the words — so it is not an accessibility
/// element, and it answers no hit test.
final class ThemeWelcomeMarkView: NSView, ThemedComponent {

    // MARK: - Properties

    /// What is showing, for a host or a test asking without pixels.
    enum Shown: Equatable {
        case app
        case logo
        case mascot
        case hidden
    }

    /// The Threading mark — kept even while another mark shows, so a theme switch back to it
    /// needs nothing built.
    let appMark = ThreadingMarkView()
    private let logo = ThemeLogoView()
    private let mascot = ThemeMascotView()
    private let appEvents = AppEventObservations()
    private let defaultSide: CGFloat
    private var width: NSLayoutConstraint?
    private var height: NSLayoutConstraint?
    private(set) var shown: Shown = .app

    /// A mark to show in place of the theme's, at `previewSide` — for a preview that states one
    /// without installing a theme. Nil, the product's answer, reads the theme in force.
    var preview: ThemeWelcomeAppearance.Mark? {
        didSet { if preview != oldValue { apply() } }
    }
    var previewSide: CGFloat? {
        didSet { if previewSide != oldValue { apply() } }
    }

    // MARK: - Initialization

    /// `defaultSide` is the host's own size for the mark, used while the theme states none.
    init(defaultSide: CGFloat) {
        self.defaultSide = defaultSide
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)

        for mark in [appMark, logo, mascot] as [NSView] {
            mark.translatesAutoresizingMaskIntoConstraints = false
            mark.isHidden = true
            addSubview(mark)
            NSLayoutConstraint.activate([
                mark.topAnchor.constraint(equalTo: topAnchor),
                mark.bottomAnchor.constraint(equalTo: bottomAnchor),
                mark.leadingAnchor.constraint(equalTo: leadingAnchor),
                mark.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }
        let width = widthAnchor.constraint(equalToConstant: defaultSide)
        let height = heightAnchor.constraint(equalToConstant: defaultSide)
        NSLayoutConstraint.activate([width, height])
        self.width = width
        self.height = height

        apply()

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.apply() }
        appEvents.observe(AgentMoodDidChange.self) { [weak self] event in
            guard let self, self.shown == .mascot else { return }
            self.mascot.setMood(event.mood, fallbackMood: AgentMoodMonitor.shared.baseMood)
        }
        appEvents.observe(AgentIntensityDidChange.self) { [weak self] event in
            guard let self, self.shown == .mascot else { return }
            self.mascot.setWorkingIntensity(event.intensity.level(at: event.intensity.measuredAt))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// The mascot, for a test asking which pose it shows.
    var figure: ThemeMascotView { mascot }

    /// The side the mark is drawn at, in points.
    var side: CGFloat { height?.constant ?? defaultSide }

    /// The app mark's one-shot draw-in. Only the app's mark has one; a theme's logo or mascot
    /// simply arrives.
    func playDrawIn() {
        guard shown == .app else { return }
        appMark.playDrawIn()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // An adaptive theme states its welcome — and its logo and mascot — per variant.
        apply()
    }

    // MARK: - Private Methods

    /// Shows the mark the current theme's welcome states for this appearance.
    private func apply() {
        let appearance = effectiveAppearance
        let welcome = ThemeWelcomeAppearance.welcome(for: appearance)
        let resolved = preview ?? ThemeWelcomeAppearance.mark(welcome, appearance: appearance)
        let side = previewSide
            ?? ThemeWelcomeAppearance.markSide(welcome, default: defaultSide)
        height?.constant = side
        width?.constant = side

        // A mark that is not showing holds no picture and runs no loop.
        if case .logo(let image) = resolved {
            logo.configure(image: image, motion: nil)
        } else {
            logo.configure(image: nil, motion: nil)
        }
        if case .mascot(let figure) = resolved {
            // Started lazily, as the sidebar's mascot starts it: a theme without one costs nothing.
            let monitor = AgentMoodMonitor.shared
            monitor.start()
            width?.constant = (side * figure.aspectRatio).rounded()
            mascot.configure(figure, mood: monitor.mood, fallbackMood: monitor.baseMood)
            mascot.setWorkingIntensity(
                AgentWorkloadMonitor.shared.intensity.level(
                    at: AgentWorkloadMonitor.shared.intensity.measuredAt
                )
            )
        } else {
            mascot.configure(nil, mood: .resting, fallbackMood: .resting)
        }

        switch resolved {
        case .app: show(.app)
        case .logo: show(.logo)
        case .mascot: show(.mascot)
        case .hidden: show(.hidden)
        }
    }

    private func show(_ mark: Shown) {
        shown = mark
        appMark.isHidden = mark != .app
        logo.isHidden = mark != .logo
        mascot.isHidden = mark != .mascot
        isHidden = mark == .hidden
    }
}
