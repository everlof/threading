import AppKit

/// The sidebar's ground: the platform's own sidebar material under the identity theme, an
/// opaque themed surface under a style.
///
/// The material is what the sidebar *lost* when its split item stopped being
/// `sidebarWithViewController:` — that behaviour was declined for the floating inset panel it
/// forces on macOS 26, not for the material it drew, and the note that made the change
/// (`MainWindowController.setupSplitViewController`) names the material as one of the two things
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
final class SidebarBackdropView: NSView, ThemedComponent, SystemChromeBoundary {

    private let material = NSVisualEffectView()
    private let fill = ThemedSurfaceView()
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

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

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

    // MARK: - Appearance

    /// Shows the ground the current theme calls for.
    private func apply() {
        let isSystem = AppThemePalette.current.isSystem
        material.isHidden = !isSystem
        fill.isHidden = isSystem
        if !isSystem {
            fill.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        }
    }

    // MARK: - SystemChromeBoundary

    /// Only the effect view this component itself installed, and whatever AppKit expands
    /// inside it — a raw effect view *beside* it stays a violation.
    func permitsSystemChrome(_ view: NSView) -> Bool {
        view === material || view.isDescendant(of: material)
    }
}
