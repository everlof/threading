import AppKit

// MARK: - Sidebar Mascot View

/// The strip at the sidebar's foot where a theme's mascot stands, beneath the project list.
///
/// It owns everything the mascot needs from the app and nothing the list does: the theme's
/// mascot for the column's appearance, the app's mood from `AgentMoodMonitor`, and the agents'
/// intensity for a working pose's stream. It reports how much of the column's foot it occupies
/// (`onReservedHeightChange`), so the list can give its last row room to scroll clear of the
/// mascot rather than ending behind it — the one layout consequence a mascot has.
///
/// Self-wired like `SidebarBackdropView`: a theme switch, an adaptive variant flip and every
/// mood change reach it without the host remembering to tell it. Empty and zero-height while
/// the theme states no mascot, so a theme without one pays for a hidden view and nothing else.
final class SidebarMascotView: NSView {

    // MARK: - Properties

    private let mascotView = ThemeMascotView()
    private let appEvents = AppEventObservations()
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var placementConstraints: [NSLayoutConstraint] = []
    private(set) var mascot: SidebarAppearance.Mascot?
    private var reservedHeight: CGFloat = 0

    /// Told the height the list should keep clear at its foot whenever it changes.
    var onReservedHeightChange: ((CGFloat) -> Void)?

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(mascotView)
        let height = mascotView.heightAnchor.constraint(equalToConstant: 0)
        let width = mascotView.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            width,
            mascotView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small)
        ])
        heightConstraint = height
        widthConstraint = width
        setAccessibilityElement(false)

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.apply() }
        appEvents.observe(AgentMoodDidChange.self) { [weak self] event in
            guard let self else { return }
            self.mascotView.setMood(event.mood, fallbackMood: AgentMoodMonitor.shared.baseMood)
        }
        appEvents.observe(AgentIntensityDidChange.self) { [weak self] event in
            self?.mascotView.setWorkingIntensity(event.intensity.level(at: event.intensity.measuredAt))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// The mascot itself, for a test asking which pose it shows.
    var figure: ThemeMascotView { mascotView }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { apply() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // An adaptive theme states a mascot per variant; a system flip is a variant change.
        apply()
    }

    // MARK: - Private Methods

    /// Shows the mascot the current theme states for this appearance, or nothing.
    func apply() {
        let resolved = AppThemePalette.current.isSystem
            ? nil
            : SidebarAppearance.mascot(for: effectiveAppearance)
        mascot = resolved
        isHidden = resolved == nil

        guard let resolved else {
            mascotView.configure(nil, mood: .resting, fallbackMood: .resting)
            report(0)
            return
        }

        let monitor = AgentMoodMonitor.shared
        monitor.start()
        let height = CGFloat(resolved.spec.size)
        heightConstraint?.constant = height
        widthConstraint?.constant = (height * resolved.aspectRatio).rounded()
        place(resolved.spec.placement)
        mascotView.configure(resolved, mood: monitor.mood, fallbackMood: monitor.baseMood)
        mascotView.setWorkingIntensity(
            AgentWorkloadMonitor.shared.intensity.level(
                at: AgentWorkloadMonitor.shared.intensity.measuredAt
            )
        )
        report(height + Design.Spacing.small)
    }

    private func place(_ placement: ThemeMascot.Placement) {
        NSLayoutConstraint.deactivate(placementConstraints)
        let inset = Design.Spacing.medium
        switch placement {
        case .leading:
            placementConstraints = [
                mascotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset)
            ]
        case .center:
            placementConstraints = [mascotView.centerXAnchor.constraint(equalTo: centerXAnchor)]
        case .trailing:
            placementConstraints = [
                mascotView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
            ]
        }
        NSLayoutConstraint.activate(placementConstraints)
    }

    private func report(_ height: CGFloat) {
        guard height != reservedHeight else { return }
        reservedHeight = height
        onReservedHeightChange?(height)
    }
}
